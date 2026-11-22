#!/bin/sh
# Downloads the latest nospeaker release and plays it.
#
#   curl -fsSL a90.com/nospeaker | sh
#
# It installs one file, ~/.local/bin/nospeaker. Delete that file to uninstall.
set -e

fail() {
    printf '\n  nospeaker: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "this runs on macOS only (it plays through a Mac's trackpad)."

url="https://github.com/os6/nospeaker/releases/latest/download/nospeaker.zip"
dest="$HOME/.local/bin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading nospeaker…"
curl -fsSL "$url" -o "$tmp/nospeaker.zip" \
    || fail "the download failed. Check your connection, or get it from github.com/os6/nospeaker/releases"
ditto -x -k "$tmp/nospeaker.zip" "$tmp"
mkdir -p "$dest"
mv -f "$tmp/nospeaker" "$dest/nospeaker"
echo "installed ~/.local/bin/nospeaker"

# Piped into sh, stdin is the script itself, so give the show the keyboard back.
"$dest/nospeaker" "$@" </dev/tty
