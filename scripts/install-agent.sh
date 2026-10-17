#!/bin/bash
# Builds inkrelay, installs it to ~/.local/bin and runs `inkrelay watch` as a login agent.
#   scripts/install-agent.sh              install or update
#   scripts/install-agent.sh --uninstall  stop and remove the agent (keeps config and state)
set -euo pipefail

LABEL="io.github.urazalievf.inkrelay"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/InkRelay"
DOMAIN="gui/$(id -u)"

stop_agent() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    stop_agent
    rm -f "$PLIST" "$BIN_DIR/inkrelay"
    echo "Removed the agent and binary. Config and state are still in ~/Library/Application Support/InkRelay."
    exit 0
fi

cd "$(dirname "$0")/.."
swift build -c release
mkdir -p "$BIN_DIR" "$LOG_DIR" "$(dirname "$PLIST")"
install -m 755 .build/release/inkrelay "$BIN_DIR/inkrelay"

"$BIN_DIR/inkrelay" status >/dev/null || {
    echo "Fix the config first (see the message above), then run this again." >&2
    exit 1
}

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/inkrelay</string>
        <string>watch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>60</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>INKRELAY_LOG</key>
        <string>$LOG_DIR/inkrelay.log</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/inkrelay.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/inkrelay.log</string>
</dict>
</plist>
PLIST

stop_agent
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "InkRelay is running in the background. Logs: $LOG_DIR/inkrelay.log"
echo "If Apple Notes is a destination, macOS will ask once to let inkrelay control Notes."
