#!/bin/bash
# Takes the gallery thumbnails of the bundled examples with the app itself,
# in the iOS Simulator: each example opens bare (no welcome, no controls,
# see AppModel.captureArgument), runs for a while, and the screen is cropped
# to the gallery's 16:10 cards.
#
# Usage: capture_thumbnails.sh [ID[:SECONDS] ...]
#   With no IDs, every example in src/ios/Examples/examples.json, using the
#   waits in thumbnail-waits.txt (default $WAIT seconds).
#
# Environment:
#   DEVICE   simulator name or UDID (default: booted), in landscape
#   APP      the built Atomify.app for the simulator
#            (default: build/ios-sim/Build/Products/Release-iphonesimulator/Atomify.app)
#   BUNDLE   bundle id (default: no.uio.atomify.dev)
#   WAIT     seconds to run before the picture (default: 8)
#   WIDTH    thumbnail width in pixels (default: 960; height is 10/16 of it)
#
# Writes src/ios/tools/thumbnails/<id>.jpg (the port script copies these into
# Examples) and src/ios/Examples/<group>/<id>/<id>.jpg.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
examples="$root/src/ios/Examples"
DEVICE="${DEVICE:-booted}"
APP="${APP:-$root/build/ios-sim/Build/Products/Release-iphonesimulator/Atomify.app}"
BUNDLE="${BUNDLE:-no.uio.atomify.dev}"
WAIT="${WAIT:-8}"
WIDTH="${WIDTH:-960}"
HEIGHT=$((WIDTH * 10 / 16))
mkdir -p "$here/thumbnails"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -d "$APP" ]]; then
    xcrun simctl install "$DEVICE" "$APP"
fi

# id<TAB>folder for every example, in catalog order.
catalog="$(python3 -c '
import json, sys
for e in json.load(open(sys.argv[1]))["examples"]:
    script = next(f["url"] for f in e["files"] if f["fileName"] == e["inputScript"])
    print(e["id"] + "\t" + script.rsplit("/", 1)[0])
' "$examples/examples.json")"

wait_for() {
    local id="$1"
    if [[ -f "$here/thumbnail-waits.txt" ]]; then
        local value
        value="$(awk -v id="$id" '$1 == id { print $2 }' "$here/thumbnail-waits.txt")"
        if [[ -n "$value" ]]; then echo "$value"; return; fi
    fi
    echo "$WAIT"
}

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
    while IFS=$'\t' read -r id _; do targets+=("$id"); done <<< "$catalog"
fi

for target in "${targets[@]}"; do
    id="${target%%:*}"
    seconds="$(wait_for "$id")"
    [[ "$target" == *:* ]] && seconds="${target#*:}"
    folder="$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' <<< "$catalog")"
    if [[ -z "$folder" ]]; then
        echo "unknown example: $id" >&2
        exit 1
    fi
    xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$DEVICE" "$BUNDLE" -AtomifyCapture "$id" > /dev/null
    sleep "$seconds"
    xcrun simctl io "$DEVICE" screenshot --type=png "$tmp/screen.png" > /dev/null 2>&1
    # Landscape screen: keep the full height and the middle 16:10 of the width.
    height="$(sips -g pixelHeight "$tmp/screen.png" | awk '/pixelHeight/ { print $2 }')"
    width="$(sips -g pixelWidth "$tmp/screen.png" | awk '/pixelWidth/ { print $2 }')"
    if (( width < height )); then
        echo "the simulator is in portrait; rotate it to landscape" >&2
        exit 1
    fi
    sips --cropToHeightWidth "$height" $((height * 16 / 10)) "$tmp/screen.png" --out "$tmp/crop.png" > /dev/null
    sips -z "$HEIGHT" "$WIDTH" -s format jpeg -s formatOptions 85 "$tmp/crop.png" \
        --out "$here/thumbnails/$id.jpg" > /dev/null
    cp "$here/thumbnails/$id.jpg" "$examples/$folder/$id.jpg"
    echo "$id: ${seconds}s -> $folder/$id.jpg"
done
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
