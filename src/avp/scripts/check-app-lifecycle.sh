#!/bin/bash
# Exercise production AppModel and the real host engine without ARKit or a headset.
# Build/package CLammps first, then run this script on macOS with Swift 6.
set -euo pipefail
atomify_dir="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$atomify_dir/Packages/AtomifyKit"
swift build --package-path "$package_dir"
bin_dir="$(swift build --package-path "$package_dir" --show-bin-path)"
headers_dir="$(python3 - "$package_dir/Frameworks/CLammps.xcframework" <<'PY'
import pathlib, plistlib, sys
framework = pathlib.Path(sys.argv[1])
info = plistlib.loads((framework / 'Info.plist').read_bytes())
for library in info['AvailableLibraries']:
    if library.get('SupportedPlatform') == 'macos':
        print(framework / library['LibraryIdentifier'] / library['HeadersPath'])
        break
else:
    raise SystemExit('CLammps is missing its macOS slice')
PY
)"
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
# Xcode 27's Swift Build backend publishes modules and the static product
# directly in Products/Debug; older SwiftPM uses Modules and object files.
module_dir="$bin_dir/Modules"
if [[ -d "$bin_dir/AtomifyKit.swiftmodule" && -f "$bin_dir/libAtomifyKit.a" ]]; then
    module_dir="$bin_dir"
    package_objects=("$bin_dir/libAtomifyKit.a")
else
    package_objects=("$bin_dir"/AtomifyKit.build/*.swift.o)
fi
swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.5" \
    -I "$module_dir" -I "$headers_dir" \
    "$atomify_dir/Atomify/App/AppModel.swift" "$atomify_dir/Tests/AppModelLifecycleProbe.swift" \
    "${package_objects[@]}" "$bin_dir/libCLammps.a" -lc++ -o "$probe_dir/check"
"$probe_dir/check" "$atomify_dir/Demos"
