#!/usr/bin/env python3
"""Long-lived Fastmail IMAP IDLE watcher for OmaFMail.

Connects once, selects the configured mailbox read-only, and then loops
issuing IMAP IDLE, waking on server push and re-issuing IDLE before the
~29 minute server timeout. Emits one JSON object per line on stdout; the
Quickshell service consumes it with a line-based process reader and
restarts this script (with backoff) if it exits.

Never touches message flags: SELECT is read-only and all fetches use
BODY.PEEK[], so watching mail here never marks it as read.
"""

from __future__ import annotations

import email
import email.header
import email.utils
import html
import imaplib
import json
import re
import socket
import ssl
import subprocess
import sys

IDLE_TIMEOUT_SECONDS = 25 * 60  # re-issue IDLE before the ~29 min server timeout
CONNECT_TIMEOUT_SECONDS = 15
DRAIN_TIMEOUT_SECONDS = 0.5  # short window to catch batched push lines (EXISTS + RECENT)
SNIPPET_CHARS = 220


def emit(event: dict) -> None:
    print(json.dumps(event, separators=(",", ":")), flush=True)


def fail(kind: str, message: str) -> None:
    emit({"type": "error", "kind": kind, "message": message})


class IMAP4Idle(imaplib.IMAP4_SSL):
    def idle_start(self) -> bytes:
        tag = self._new_tag()
        self.send(b"%s IDLE\r\n" % tag)
        resp = self.readline()
        if not resp.startswith(b"+"):
            raise RuntimeError("server rejected IDLE: " + resp.decode(errors="replace"))
        return tag

    def idle_wait(self, timeout: float) -> list:
        self.sock.settimeout(timeout)
        lines = []
        try:
            line = self.readline()
            if not line:
                raise RuntimeError("connection closed during IDLE")
            lines.append(line)
        except socket.timeout:
            self.sock.settimeout(None)
            return lines
        self.sock.settimeout(DRAIN_TIMEOUT_SECONDS)
        try:
            while True:
                line = self.readline()
                if not line:
                    break
                lines.append(line)
        except socket.timeout:
            pass
        finally:
            self.sock.settimeout(None)
        return lines

    def idle_done(self, tag: bytes) -> None:
        self.send(b"DONE\r\n")
        while True:
            line = self.readline()
            if not line or line.startswith(tag):
                break


def load_password(service: str, account: str) -> str:
    result = subprocess.run(
        ["secret-tool", "lookup", "service", service, "account", account],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0 or not result.stdout:
        raise RuntimeError(
            "no secret found for service=%r account=%r; store one with: "
            "secret-tool store --label=\"OmaFMail: %s\" service %s account %s"
            % (service, account, account, service, account)
        )
    return result.stdout.rstrip("\n")


def decode_header_value(raw: str) -> str:
    if not raw:
        return ""
    decoded = []
    for text, charset in email.header.decode_header(raw):
        if isinstance(text, bytes):
            decoded.append(text.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(text)
    return "".join(decoded).strip()


def decode_payload(payload: bytes, charset: str) -> str:
    try:
        return payload.decode(charset or "utf-8", errors="replace")
    except (LookupError, UnicodeDecodeError):
        return payload.decode("utf-8", errors="replace")


def extract_part(msg: email.message.Message, content_type: str) -> str | None:
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == content_type and not part.get_filename():
                payload = part.get_payload(decode=True)
                if payload is None:
                    continue
                return decode_payload(payload, part.get_content_charset())
        return None
    if msg.get_content_type() != content_type:
        return None
    payload = msg.get_payload(decode=True)
    if payload is None:
        return None
    return decode_payload(payload, msg.get_content_charset())


def html_to_text(raw_html: str) -> str:
    text = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", raw_html)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    return html.unescape(text)


def plain_text_snippet(msg: email.message.Message) -> str:
    body = extract_part(msg, "text/plain")
    if body is None:
        raw_html = extract_part(msg, "text/html")
        if raw_html is not None:
            body = html_to_text(raw_html)
    body = re.sub(r"\s+", " ", body or "").strip()
    return body[:SNIPPET_CHARS]


def connect(host: str, port: int, account: str, password: str) -> IMAP4Idle:
    imap = IMAP4Idle(host, port, timeout=CONNECT_TIMEOUT_SECONDS)
    imap.login(account, password)
    return imap


def fetch_unseen(imap: IMAP4Idle, limit: int) -> list:
    status, data = imap.uid("search", None, "UNSEEN")
    if status != "OK":
        raise RuntimeError("UNSEEN search failed")
    uids = data[0].split()
    if limit:
        uids = uids[-limit:]

    messages = []
    for uid in uids:
        status, data = imap.uid("fetch", uid, "(BODY.PEEK[])")
        if status != "OK" or not data or not data[0]:
            continue
        raw = data[0][1]
        msg = email.message_from_bytes(raw)

        name, addr = email.utils.parseaddr(decode_header_value(msg.get("From", "")))
        try:
            received_at = int(email.utils.parsedate_to_datetime(msg.get("Date", "")).timestamp() * 1000)
        except (TypeError, ValueError):
            received_at = 0

        messages.append({
            "id": uid.decode(),
            "fromName": name or addr or "(unknown sender)",
            "fromAddress": addr,
            "subject": decode_header_value(msg.get("Subject", "")) or "(no subject)",
            "receivedAt": received_at,
            "snippet": plain_text_snippet(msg),
        })

    messages.sort(key=lambda m: (m["receivedAt"], int(m["id"])), reverse=True)
    return messages


def run(config: dict) -> int:
    host = str(config["host"])
    port = int(config.get("port", 993))
    mailbox = str(config.get("mailbox", "INBOX"))
    account = str(config["account"])
    secret_service = str(config.get("secretService", "mailnotifier"))
    fetch_limit = int(config.get("fetchLimit", 20))

    try:
        password = load_password(secret_service, account)
    except Exception as error:
        fail("auth", str(error))
        return 1

    try:
        imap = connect(host, port, account, password)
    except imaplib.IMAP4.error as error:
        fail("auth", "login failed: %s" % error)
        return 1
    except (OSError, ssl.SSLError, socket.timeout) as error:
        fail("network", str(error))
        return 1

    try:
        status, _ = imap.select(mailbox, readonly=True)
        if status != "OK":
            fail("config", "cannot select mailbox %r" % mailbox)
            return 2

        emit({"type": "status", "state": "connected"})

        while True:
            try:
                messages = fetch_unseen(imap, fetch_limit)
            except (OSError, ssl.SSLError, socket.timeout, imaplib.IMAP4.error) as error:
                fail("network", "fetch failed: %s" % error)
                return 1

            emit({"type": "snapshot", "unreadCount": len(messages), "messages": messages})

            tag = imap.idle_start()
            lines = imap.idle_wait(IDLE_TIMEOUT_SECONDS)
            imap.idle_done(tag)
            if not lines:
                continue  # keepalive cycle only, nothing changed
    except (OSError, ssl.SSLError, socket.timeout, imaplib.IMAP4.error) as error:
        fail("network", str(error))
        return 1
    finally:
        try:
            imap.logout()
        except Exception:
            pass


def main() -> int:
    if len(sys.argv) != 2:
        fail("config", "usage: idle_watcher.py <config-json-path>")
        return 2

    try:
        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            config = json.load(handle)
        if "host" not in config or "account" not in config:
            raise ValueError("config needs at least 'host' and 'account'")
    except Exception as error:
        fail("config", "invalid config: %s" % error)
        return 2

    return run(config)


if __name__ == "__main__":
    raise SystemExit(main())
