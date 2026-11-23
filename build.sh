#!/bin/sh
# Builds thockpad (and the nospeaker it's built on) as one program for this Mac.
#
#   ./build.sh              build ./build/thockpad and ./build/nospeaker (this Mac)
#   ./build.sh universal    the same, fat arm64 + x86_64 (needs both SDK targets)
#
# Each build is signed ad-hoc with a stable identifier — that is only for tidiness (a named binary in
# spctl/codesign output). thockpad needs NO macOS permission: it polls key state instead of tapping events,
# so there is no grant to survive. Upstream's notarized-release flow lives in the nospeaker repo; this fork
# builds locally and runs the binary from ./build.
#
# Two binaries from one engine: nospeaker/engine.swift holds only declarations, so it compiles with either
# entry point — main.swift (thockpad) or nospeaker/main.swift (the original show).
set -e
cd "$(dirname "$0")"

fail() { printf '\n  thockpad: %s\n\n' "$1" >&2; exit 1; }

# Read the mode now: the Swift version check below uses `set --` and overwrites the positional parameters.
mode="${1:-build}"

[ "$(uname -s)" = "Darwin" ] || fail "this builds on macOS only (it drives a Mac's trackpad)."
{ xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; } || fail "Swift isn't installed: xcode-select --install"

version=$(swiftc --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
set -- $version
[ "${1:-0}" -ge 5 ] && { [ "$1" -gt 5 ] || [ "${2:-0}" -ge 7 ]; } || fail "needs Swift 5.7 or newer (found ${1:-?}.${2:-?})."

mkdir -p build
ENGINE="nospeaker/engine.swift"
THOCK="clicks.swift keys.swift settings.swift gui.swift main.swift"

build_for() {   # build_for <target> <out-suffix> [extra swiftc flags…]
    target="$1"; suffix="$2"; shift 2
    echo "building thockpad ($target)…"
    swiftc -O -target "$target" $ENGINE $THOCK -o "build/thockpad-$suffix" "$@"
    echo "building nospeaker ($target)…"
    swiftc -O -target "$target" $ENGINE nospeaker/main.swift -o "build/nospeaker-$suffix" "$@"
}

case "$mode" in
build)
    build_for arm64-apple-macos12 arm64
    mv -f build/thockpad-arm64 build/thockpad
    mv -f build/nospeaker-arm64 build/nospeaker
    ;;
universal)
    build_for arm64-apple-macos12 arm64
    build_for x86_64-apple-macos13 x86_64
    lipo -create build/thockpad-arm64 build/thockpad-x86_64 -output build/thockpad
    lipo -create build/nospeaker-arm64 build/nospeaker-x86_64 -output build/nospeaker
    rm -f build/*-arm64 build/*-x86_64
    ;;
*)
    fail "unknown mode \"$mode\" (build, universal, release)."
    ;;
esac

# An ad-hoc signature with a fixed identifier (cosmetic: names the binary in codesign output). No
# permission depends on it — thockpad asks macOS for nothing.
codesign --force --sign - --identifier com.dkiiv.thockpad build/thockpad 2>/dev/null || true
codesign --force --sign - --identifier com.dkiiv.nospeaker build/nospeaker 2>/dev/null || true

# The app bundle around the thockpad binary (Info.plist + stable signature), so `open build/Thockpad.app`
# works straight after a build; ./scripts/make-app.sh --zip adds dist/*.zip for a GitHub release.
./scripts/make-app.sh

printf '\n  built ./build/thockpad + ./build/Thockpad.app (%s) and ./build/nospeaker (%s)\n' "$(lipo -archs build/thockpad)" "$(lipo -archs build/nospeaker)"
printf '  open the app:  open build/Thockpad.app      (right-click → Open the first time)\n'
printf '  or the CLI:    ./build/thockpad --selftest  then  ./build/thockpad --cli\n'
