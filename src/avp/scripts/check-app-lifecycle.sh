#!/bin/bash
# Exercise production AppModel and the real host engine without ARKit or a headset.
# Needs src/shared/lammps/Frameworks/CLammps.xcframework with its macOS slice
# (src/shared/lammps/build-xcframework.sh); run on macOS with Swift 6.
set -euo pipefail
atomify_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$atomify_dir/../.." && pwd)"
package_dir="$atomify_dir/Packages/AtomifyVision"
swift build --package-path "$package_dir"
bin_dir="$(swift build --package-path "$package_dir" --show-bin-path)"
headers_dir="$(python3 - "$repo_dir/src/shared/lammps/Frameworks/CLammps.xcframework" <<'PY'
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
# Xcode 27's Swift Build backend publishes modules, one object per dependency
# and the static product directly in Products/Debug; older SwiftPM uses
# Modules and per-target build folders.
if [[ -d "$bin_dir/AtomifyVision.swiftmodule" && -f "$bin_dir/libAtomifyVision.a" ]]; then
    module_dir="$bin_dir"
    package_objects=("$bin_dir/libAtomifyVision.a" "$bin_dir/AtomifyEngine.o")
else
    module_dir="$bin_dir/Modules"
    package_objects=("$bin_dir"/AtomifyVision.build/*.swift.o "$bin_dir"/AtomifyEngine.build/*.swift.o)
fi
swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macosx15.5" \
    -I "$module_dir" -I "$headers_dir" \
    "$atomify_dir/Atomify/App/AppModel.swift" "$atomify_dir/Tests/AppModelLifecycleProbe.swift" \
    "${package_objects[@]}" "$bin_dir/libCLammps.a" -lc++ -o "$probe_dir/check"
"$probe_dir/check" "$atomify_dir/Demos"
