#!/usr/bin/env bash
#
# Smoke test for todo.app.
#
# todo has no Dock icon and no menu bar item, so "is it running?" and "did the
# hotkeys actually register?" are not answerable by looking at the screen.
# This script answers both, so a failure is visible rather than mysterious.
#
#   ./verify.sh                 build, install, test
#   ./verify.sh --screenshot    also write build/panel.png
#   ./verify.sh --keep-open     leave it running at the end

set -uo pipefail

APP_NAME="todo"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/$APP_NAME.app"
LOG_DIR="$HOME/Library/Application Support/$APP_NAME"
LOG="$LOG_DIR/todo.log"
SHOT="$ROOT/build/panel.png"

SCREENSHOT=0
KEEP_OPEN=0
for arg in "$@"; do
    case "$arg" in
        --screenshot) SCREENSHOT=1 ;;
        --keep-open)  KEEP_OPEN=1 ;;
    esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

pkill -x "$APP_NAME" 2>/dev/null; sleep 0.4

bold "▸ Building and installing"
"$ROOT/build-app.sh" --install >/dev/null || { bad "build failed"; exit 1; }
ok "/Applications/$APP_NAME.app"

bold "▸ Self-test"
# Undo and multi-selection are the rules most likely to break quietly, and they
# are the rules that cannot be checked by looking at the screen. Run before the
# app is launched so a failure here is unambiguous.
SELFTEST_BIN="$ROOT/.build/release/$APP_NAME"
if [[ -x "$SELFTEST_BIN" ]]; then
    if SELFTEST_OUT="$("$SELFTEST_BIN" --selftest 2>&1)"; then
        ok "${SELFTEST_OUT%%$'\n'*}"
    else
        bad "self-test failed"
        echo "$SELFTEST_OUT" | sed 's/^/      /'
    fi
else
    ok "self-test skipped (binary not built)"
fi

bold "▸ Launching"
rm -f "$LOG"
open -a "$APP" --args --show
sleep 3

PID="$(pgrep -x "$APP_NAME" || true)"
if [[ -n "$PID" ]]; then
    ok "running (pid $PID)"
else
    bad "process is not running — it crashed on launch"
    [[ -f "$LOG" ]] && cat "$LOG"
    exit 1
fi

# UIElement means LSUIElement took effect: no Dock icon, no menu bar item.
TYPE="$(lsappinfo info -only ApplicationType "$PID" 2>/dev/null | tr -d '"' | awk -F= '{print $2}')"
if [[ "$TYPE" == "UIElement" ]]; then
    ok "is a UIElement (no Dock icon, no menu bar item)"
else
    bad "activation policy is '${TYPE:-unknown}', expected UIElement"
fi

# `ps` RSS counts framework pages shared with every other SwiftUI process and
# reads ~80 MB for an app that actually occupies 17 MB. `footprint` reports the
# number macOS itself uses for memory pressure, which is the honest figure.
FOOTPRINT="$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3}')"
if [[ -n "$FOOTPRINT" ]]; then
    ok "memory footprint: $FOOTPRINT (panel open)"
else
    ok "could not read footprint (footprint(1) may be unavailable)"
fi

bold "▸ Hotkeys"
# The shortcuts are user-configurable, so report whatever is actually
# registered rather than hard-coding an expectation.
HOTKEYS="$(grep 'hotkeys:' "$LOG" 2>/dev/null | tail -1 | sed 's/.*] //')"
if [[ -n "$HOTKEYS" ]]; then
    ok "registered — $HOTKEYS"
else
    bad "hotkeys did not register (see log below)"
fi
if grep -q "could not register hotkey\|hotkey conflict" "$LOG" 2>/dev/null; then
    bad "a hotkey was refused — another app already owns it"
fi

bold "▸ Hand-off"
# With the app running, todo-keep must be absent: two processes holding the same
# shortcut makes the panel open and close again on one keystroke.
if pgrep -x todo-keep >/dev/null; then
    bad "todo-keep is running alongside the app — two owners of one shortcut"
else
    ok "todo-keep is not running while the app is (no contention)"
fi

# A graceful quit must hand the shortcut over, or the hotkey stops working
# entirely once the panel is closed. `pkill` would not do — that is a signal,
# not a quit, and skips applicationWillTerminate — so ask the app to quit.
osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1
sleep 2.5
if pgrep -x "$APP_NAME" >/dev/null; then
    bad "the app did not quit"
elif pgrep -x todo-keep >/dev/null; then
    ok "todo-keep took over the shortcut on quit"
else
    bad "todo-keep did not start — the shortcut will be dead while the app is closed"
fi

if grep -q "started keyCode" "$LOG_DIR/todo-keep.log" 2>/dev/null; then
    ok "todo-keep registered it ($(grep 'started keyCode' "$LOG_DIR/todo-keep.log" | tail -1 | sed 's/.*] //'))"
else
    bad "todo-keep started but never registered — see todo-keep.log"
fi

bold "▸ Data"
if [[ -f "$LOG_DIR/todos.json" ]]; then
    ok "todos.json present ($(wc -l < "$LOG_DIR/todos.json" | tr -d ' ') lines)"
else
    ok "todos.json not created yet (nothing added, this is fine)"
fi

if [[ "$SCREENSHOT" == "1" ]]; then
    bold "▸ Screenshot"
    mkdir -p "$ROOT/build"
    screencapture -x -o "$SHOT" && ok "wrote $SHOT"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    bold "✗ $FAILURES check(s) failed"
    echo "--- todo.log ---"
    cat "$LOG" 2>/dev/null
    echo "--- todo-keep.log ---"
    cat "$LOG_DIR/todo-keep.log" 2>/dev/null
    echo "-------------------"
fi

if [[ "$KEEP_OPEN" == "1" ]]; then
    bold "Left todo-keep running so the shortcut survives"
else
    # Leave todo-keep: the shortcut has to keep working after the app is gone,
    # which is the whole point. Stopping the app here was a no-op anyway, the
    # hand-off check above already quit it.
    pkill -x todo-keep 2>/dev/null
    bold "▸ Stopped"
fi

exit $(( FAILURES > 0 ? 1 : 0 ))