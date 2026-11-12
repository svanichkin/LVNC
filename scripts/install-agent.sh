#!/bin/bash
# Run once in the session that should be controlled (as that user, not root).
# Installs a LaunchAgent that starts LVNC Agent at login and keeps it running.
#
#   install-agent.sh <user allowed to connect>[,<user>...]
#   install-agent.sh --uninstall
set -euo pipefail

LABEL="local.lvnc.agent"
APP="/Applications/LVNC Agent.app"
EXE="$APP/Contents/MacOS/lvnc-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG="/Users/Shared/lvnc/logs/agent-$(id -un).log"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "LVNC Agent removed from login."
    exit 0
fi

ALLOW="${1:?usage: install-agent.sh <user allowed to connect>[,<user>...] | --uninstall}"
[ "$(id -u)" -ne 0 ] || { echo "run as the user whose screen is shared, not root" >&2; exit 1; }
[ -x "$EXE" ] || { echo "not found: $EXE (run scripts/install.sh first)" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" /Users/Shared/lvnc/logs 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXE</string>
        <string>--allow</string>
        <string>$ALLOW</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "LVNC Agent installed for $(id -un), allowed: $ALLOW"
echo "Log: $LOG"
echo
echo "Grant 'LVNC Agent' both permissions in the System Settings panes that open now:"
echo "  - Screen & System Audio Recording"
echo "  - Accessibility"
echo "(If it is not listed yet, connect once with the viewer, or add it with '+' from /Applications.)"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
