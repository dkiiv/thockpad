#!/bin/sh
# thockpad needs Input Monitoring to hear the keyboard. This makes that grant survive rebuilding.
#
#   ./scripts/permissions.sh            sign the build with a stable identity (run after every build.sh)
#   ./scripts/permissions.sh --check    is it trusted right now?
#   ./scripts/permissions.sh --reset    forget thockpad's old grants (stale entries from before the signing)
#
# Why: macOS ties the grant to the binary's code identity. A plain swiftc output is ad-hoc signed with a
# fresh cdhash every compile, so every rebuild looks like a different program and the prompt comes back —
# which is what "it keeps asking" actually is. Signing with a fixed identifier makes the grant survive
# recompiles (verified on macOS 27: rebuilt binary, new cdhash, still trusted).
#
# Note a grant only takes effect in a *newly started* process: tick the box, then restart thockpad.
set -e
cd "$(dirname "$0")/.."

IDENT="com.dkiiv.thockpad"
BIN="build/thockpad"

[ -f "$BIN" ] || { printf '  no %s — run ./build.sh first.\n' "$BIN" >&2; exit 1; }

case "${1:-sign}" in
--check)
    if codesign -dvv "$BIN" 2>&1 | grep -q "Identifier=$IDENT"; then
        printf '  signed: yes (%s)\n' "$IDENT"
    else
        printf '  signed: no — run ./scripts/permissions.sh\n'
    fi
    if "$BIN" --selftest >/dev/null 2>&1; then
        printf '  trusted: yes (self-test clicked)\n'
    else
        printf '  trusted: no — start %s once, allow it under Input Monitoring, then start it again.\n' "$BIN"
    fi
    ;;
--reset)
    tccutil reset ListenEvent "$IDENT" && printf '  reset. Start ./build/thockpad and allow it once.\n'
    ;;
sign)
    codesign --force --sign - --identifier "$IDENT" "$BIN"
    codesign --verify "$BIN" && printf '  signed and verified: %s (%s)\n' "$BIN" "$IDENT"
    printf '  the grant now survives rebuilds, as long as you build with ./build.sh (it signs the same way).\n'
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    ;;
*)
    printf 'usage: %s [--check|--reset]\n' "$0" >&2; exit 64
    ;;
esac
