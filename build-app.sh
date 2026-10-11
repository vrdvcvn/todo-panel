#!/usr/bin/env bash
#
# Builds todo.app.
#
# There is no Xcode project on purpose: this Mac has Command Line Tools but not
# Xcode, and a full Xcode install is a multi-gigabyte download to produce the
# same binary. Swift Package Manager compiles the code; this script assembles
# the .app bundle around it and ad-hoc signs the result.
#
#   ./build-app.sh            build into ./build
#   ./build-app.sh --install  build, then copy to /Applications

set -euo pipefail

APP_NAME="todo"
BUNDLE_ID="com.arda.todo"
# Deliberately not "$BUNDLE_ID.something" by accident of naming: the watcher has
# to be a *different* bundle id, or AppKit and LaunchServices cannot tell it
# apart from the app it is supposed to be launching.
KEEPER_BUNDLE_ID="com.arda.todo-keep"
VERSION="1.0.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
BINARY="$ROOT/.build/release/$APP_NAME"
KEEPER="$ROOT/.build/release/todo-keep"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

command -v swift >/dev/null || die "swift not found (install Command Line Tools: xcode-select --install)"

bold "▸ Compiling"
swift build --package-path "$ROOT" -c release

[[ -f "$BINARY" ]] || die "expected binary at $BINARY but it is not there"
[[ -f "$KEEPER" ]] || die "expected todo-keep at $KEEPER but it is not there"

bold "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Spotlight indexes ~/Desktop, so without this the working copy in build/ shows
# up next to the installed one and "todo" returns two identical results.
# This file is the documented way to tell Spotlight to skip a directory.
touch "$BUILD_DIR/.metadata_never_index"

cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# The watcher that holds the shortcut while the app is closed.
#
# It gets a bundle of its own, nested inside todo.app, and that is not
# cosmetic. Sharing todo.app's identity makes the watcher indistinguishable
# from the real app: UserDefaults resolves the two to one domain, and
# LaunchServices "launching" todo activates the watcher instead of starting it.
# A separate CFBundleIdentifier is what lets the watcher hold the shortcut and
# actually start the app, rather than endlessly mistaking itself for it.
KEEPER_APP="$APP/Contents/Library/LoginItems/todo-keep.app"
# Resources is empty but has to exist: `codesign --deep` refuses a bundle whose
# signature promises resources it cannot find, and it fails the whole app.
mkdir -p "$KEEPER_APP/Contents/MacOS" "$KEEPER_APP/Contents/Resources"
cp "$KEEPER" "$KEEPER_APP/Contents/MacOS/todo-keep"
chmod +x "$KEEPER_APP/Contents/MacOS/todo-keep"

cat > "$KEEPER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>todo-keep</string>
	<key>CFBundleIdentifier</key>
	<string>$KEEPER_BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>todo-keep</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<!-- A watcher with no windows. It must never appear in the Dock. -->
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

if [[ -f "$ROOT/Resources/todo.icns" ]]; then
    cp "$ROOT/Resources/todo.icns" "$APP/Contents/Resources/$APP_NAME.icns"
else
    echo "  regenerating icon"
    (cd "$ROOT" && swift Tools/make-icon.swift)
    iconutil -c icns "$ROOT/Resources/todo.iconset" -o "$APP/Contents/Resources/$APP_NAME.icns"
    rm -rf "$ROOT/Resources/todo.iconset"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<!-- Agent app: no Dock icon, no menu bar item. Still indexed by Spotlight. -->
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

bold "▸ Signing (ad-hoc)"
# Ad-hoc is sufficient and correct for a locally built, personally used app:
# there is no quarantine attribute on it, so Gatekeeper never prompts.
# Inside-out. The nested bundle has to be signed before the app that contains
# it: signing the outer app alone leaves the outer signature claiming resources
# the inner bundle does not have, and `codesign --verify` then rejects the whole
# thing with "code has no resources but signature indicates they must be
# present".
codesign --force --sign - --timestamp=none "$KEEPER_APP" >/dev/null 2>&1 \
    || die "codesign failed for todo-keep"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || die "codesign failed"
codesign --verify --deep --strict "$APP" && echo "  signature valid"

if [[ "${1:-}" == "--install" ]]; then
    bold "▸ Installing to /Applications"
    if pgrep -x "$APP_NAME" >/dev/null; then
        pkill -x "$APP_NAME" || true
        sleep 0.5
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    # Make sure Launch Services and Spotlight pick up the new bundle.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "/Applications/$APP_NAME.app" >/dev/null 2>&1 || true
    # Drop the working copy. Leaving it around means Spotlight indexes two
    # identical "todo" entries and the user has to guess which to pick.
    rm -rf "$APP"
    bold "Installed /Applications/$APP_NAME.app"
    echo "Run it with Spotlight: press ⌘Space, type \"$APP_NAME\", press Return."
else
    bold "Built $APP"
    echo "Add --install to copy it into /Applications."
fi