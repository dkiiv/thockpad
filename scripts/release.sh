#!/bin/sh
# Publish build/Thockpad.app to a GitHub release (github.com/dkiiv/thockpad).
#
#   VERSION=1.0 ./scripts/release.sh          create/refresh release v1.0 with dist/Thockpad-1.0.zip
#
# Needs: the GitHub token from your git credential store (or GH_TOKEN) with the repo scope, and curl.
# The zip is rebuilt from the current source first, so what you publish is what is committed.
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.0 ./scripts/release.sh}"
REPO="dkiiv/thockpad"
TAG="v$VERSION"
ZIP="dist/Thockpad-$VERSION.zip"

token="${GH_TOKEN:-$(python3 - "$HOME/.git-credentials" <<'PY'
import sys
for line in open(sys.argv[1]):
    if 'github.com' in line:
        print(line.strip().split('//')[1].split('@')[0].split(':')[1]); break
PY
)}"

command -v gh >/dev/null 2>&1 || true   # not required; we use the API directly

./build.sh
VERSION="$VERSION" ./scripts/make-app.sh --zip
[ -f "$ZIP" ] || { printf '  missing %s\n' "$ZIP" >&2; exit 1; }
printf '  zip sha256: %s\n' "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# Create or update the release (idempotent: an existing tag is reused, not re-created).
release_id=$(curl -sf -H "Authorization: Bearer $token" \
    "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -z "$release_id" ]; then
    release_id=$(curl -sf -X POST -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/releases" \
        -d "{\"tag_name\":\"$TAG\",\"name\":\"thockpad $TAG\",\"body\":\"Thockpad.app for Apple Silicon Macs with a Force Touch trackpad (macOS 12+). Download, unzip, right-click → Open (the build is ad-hoc signed, not notarized — see README).\",\"target_commitish\":\"main\",\"draft\":false,\"prerelease\":false}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    printf '  created release %s (id %s)\n' "$TAG" "$release_id"
else
    printf '  using existing release %s (id %s)\n' "$TAG" "$release_id"
fi

# Upload the asset (delete any stale one with the same name first).
asset_id=$(curl -sf -H "Authorization: Bearer $token" \
    "https://api.github.com/repos/$REPO/releases/$release_id/assets" \
    | python3 -c 'import json,sys
data=json.load(sys.stdin)
for a in data:
    if a["name"] == "Thockpad.zip": print(a["id"]); break' 2>/dev/null || true)
[ -n "$asset_id" ] && curl -sf -X DELETE -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases/assets/$asset_id" >/dev/null && printf '  removed previous asset\n'

curl -sf -X POST -H "Authorization: Bearer $token" \
    -H "Content-Type: application/zip" \
    --data-binary "@$ZIP" \
    "https://uploads.github.com/repos/$REPO/releases/$release_id/assets?name=Thockpad.zip" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  uploaded:", d["name"], d["browser_download_url"])'
printf '  done: https://github.com/%s/releases/tag/%s\n' "$REPO" "$TAG"
