#!/usr/bin/env sh
# Opens the user's default mail client's main window.
#
# We deliberately do NOT use `xdg-open mailto:` or pass any mailto: URL,
# because that asks the mail client to open a *compose* window. Instead we
# look up which .desktop file is registered as the default handler for the
# mailto: URI scheme, read its Exec= line, strip the %u/%U/%f/... field
# codes (which is what would normally carry a mailto: URL and trigger
# compose mode), and launch the bare command. That opens the app's main
# window/inbox instead.
#
# Falls back to opening Fastmail's web inbox if no default handler can be
# resolved or the .desktop file can't be found/parsed.

FALLBACK_URL="https://app.fastmail.com/mail/Inbox"

fallback() {
  xdg-open "$FALLBACK_URL" >/dev/null 2>&1 &
  exit 0
}

command -v xdg-mime >/dev/null 2>&1 || fallback

desktop_id="$(xdg-mime query default x-scheme-handler/mailto 2>/dev/null)"
[ -n "$desktop_id" ] || fallback

desktop_file=""
for dir in \
  "$HOME/.local/share/applications" \
  "/usr/local/share/applications" \
  "/usr/share/applications" \
  "/var/lib/flatpak/exports/share/applications" \
  "$HOME/.local/share/flatpak/exports/share/applications"
do
  if [ -f "$dir/$desktop_id" ]; then
    desktop_file="$dir/$desktop_id"
    break
  fi
done

[ -n "$desktop_file" ] || fallback

exec_line="$(grep -m1 '^Exec=' "$desktop_file" | sed 's/^Exec=//')"
[ -n "$exec_line" ] || fallback

# Strip desktop-entry field codes (%f %F %u %U %i %c %k etc.) - these are
# where a mailto: URL would be substituted in, triggering compose mode.
clean_cmd="$(printf '%s' "$exec_line" | sed -E 's/%[a-zA-Z%]//g')"
[ -n "$clean_cmd" ] || fallback

eval "$clean_cmd" >/dev/null 2>&1 &
exit 0
