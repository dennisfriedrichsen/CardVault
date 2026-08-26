#!/bin/bash
# Regenerates Docs/ui-states/ from the shipping UI.
#
# The app is sandboxed and cannot write into the repository, so the DEBUG-only
# capture mode writes into its own container and prints where; this collects the
# result. See Docs/ui-state-capture.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:-$repo_root/Docs/ui-states}"

cd "$repo_root"
xcodebuild -project CardVault.xcodeproj -scheme CardVault \
    -destination 'platform=macOS' -configuration Debug build >/dev/null

products="$(xcodebuild -project CardVault.xcodeproj -scheme CardVault \
    -destination 'platform=macOS' -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')"

output="$("$products/CardVault.app/Contents/MacOS/CardVault" --capture-ui-states \
    | awk -F'=' '/^CARDVAULT_UI_STATES_DIR=/{print $2}')"

if [ -z "$output" ] || [ ! -d "$output" ]; then
    echo "capture produced no output directory" >&2
    exit 1
fi

mkdir -p "$destination"
rm -f "$destination"/*.png
cp "$output"/*.png "$destination"/
echo "collected $(ls -1 "$destination"/*.png | wc -l | tr -d ' ') screenshots into $destination"
