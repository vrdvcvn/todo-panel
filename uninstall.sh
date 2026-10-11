#!/usr/bin/env bash
#
# Removes todo entirely: app bundle, Spotlight index entry and saved data.
#
#   ./uninstall.sh            remove the app, keep your todos
#   ./uninstall.sh --purge    also delete todos.json and the log

set -uo pipefail

APP_NAME="todo"
BUNDLE_ID="com.arda.todo"
APP="/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/$APP_NAME"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Stopping $APP_NAME"
    pkill -x "$APP_NAME"
    sleep 0.5
fi

if [[ -d "$APP" ]]; then
    rm -rf "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$APP" >/dev/null 2>&1 || true
    bold "Removed $APP"
else
    echo "$APP is not installed"
fi

if [[ "$PURGE" == "1" ]]; then
    rm -rf "$SUPPORT"
    bold "Removed $SUPPORT"
else
    echo "Kept your todos at $SUPPORT"
    echo "Pass --purge to delete them too."
fi

echo
echo "If the app still shows up in Spotlight, give Spotlight a moment to"
echo "notice the removal, or restart it from Activity Monitor."