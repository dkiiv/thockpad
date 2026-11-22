#!/bin/sh
# Assembles build/Thockpad.app around a freshly built ./build/thockpad.
#
#   ./scripts/make-app.sh            build/thockpad → build/Thockpad.app (ad-hoc signed, stable identifier)
#   ./scripts/make-app.sh --zip      …and dist/Thockpad.zip, ready to upload to a GitHub release
#
# The bundle matters beyond looks: Input Monitoring is granted per *code identity*, and a bare binary has no
# bundle identifier of its own. Thockpad.app/Contents/Info.plist pins com.dkiiv.thockpad, and the binary is
# signed with it, so the grant survives rebuilds and the app appears with a proper name in the settings list.
#
# It is NOT notarized (that needs a Developer ID + notary credentials, upstream nospeaker's release flow):
# a downloaded build/Thockpad.zip opens with a right-click → Open the first time, because macOS doesn't
# recognise the ad-hoc signature. The README release notes say so.
set -e
cd "$(dirname "$0")/.."

BIN="build/thockpad"
APP="build/Thockpad.app"
IDENT="com.dkiiv.thockpad"
VERSION="${VERSION:-1.0}"

[ -x "$BIN" ] || { printf '  no %s — run ./build.sh first.\n' "$BIN" >&2; exit 1; }
codesign -dvv "$BIN" 2>&1 | grep -q "Identifier=$IDENT" || {
    printf '  %s is not signed with %s — ./build.sh does that; re-run it.\n' "$BIN" "$IDENT" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/thockpad"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>              <string>thockpad</string>
    <key>CFBundleIdentifier</key>              <string>$IDENT</string>
    <key>CFBundleName</key>                    <string>Thockpad</string>
    <key>CFBundleDisplayName</key>             <string>Thockpad</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>CFBundleShortVersionString</key>      <string>$VERSION</string>
    <key>CFBundleVersion</key>                 <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>          <string>12.0</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>NSHumanReadableCopyright</key>        <string>MIT · fork of nospeaker by Cody Collier (a90.com)</string>
</dict>
</plist>
PLIST
# No LSUIElement on purpose: the app shows a Dock icon while its window is open and demotes itself to the
# menu bar (NSApplication.setActivationPolicy(.accessory)) when the window is closed.

# Touch the bundle so its (cdhash-based) signature is computed over what's inside, then sign the app folder.
codesign --force --deep --sign - --identifier "$IDENT" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
printf '  built %s (identifier %s, ad-hoc signed — right-click → Open the first time)\n' "$APP" "$IDENT"

[ "$1" = "--zip" ] || exit 0
mkdir -p dist
rm -f dist/Thockpad.zip
ditto -c -k --keepParent "$APP" "dist/Thockpad-$VERSION.zip"
ln -sf "Thockpad-$VERSION.zip" dist/Thockpad-latest.zip
printf '  zipped dist/Thockpad-%s.zip — upload it to the GitHub release (see README).\n' "$VERSION"
