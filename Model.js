.pragma library

function positiveInteger(value, fallback) {
  var parsed = Number(value)
  if (!isFinite(parsed) || parsed <= 0) return fallback
  return Math.round(parsed)
}

function normalizeConfig(raw) {
  if (!raw || typeof raw !== "object") throw new Error("config must be an object")

  var account = String(raw.account || "").trim()
  if (!account || account.indexOf("@") === -1) throw new Error("config needs a valid 'account' email address")

  var host = String(raw.host || "").trim()
  if (!host) throw new Error("config needs a 'host' (e.g. imap.fastmail.com)")

  var secretService = String(raw.secretService || "omafmail").trim()
  if (!secretService) throw new Error("'secretService' cannot be empty")

  return {
    account: account,
    host: host,
    port: positiveInteger(raw.port, 993),
    mailbox: String(raw.mailbox || "INBOX").trim() || "INBOX",
    secretService: secretService,
    fetchLimit: positiveInteger(raw.fetchLimit, 20)
  }
}

function relativeTime(timestamp, now) {
  if (!timestamp) return ""
  var seconds = Math.max(0, Math.round((now - timestamp) / 1000))
  if (seconds < 5) return "just now"
  if (seconds < 60) return seconds + "s ago"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}

function errorSummary(error) {
  if (!error) return ""
  if (error.kind === "auth") return "Sign-in failed — check the stored app password"
  if (error.kind === "config") return "Configuration problem"
  if (error.kind === "network") return "Connection lost — retrying"
  return error.message || "Unknown error"
}
