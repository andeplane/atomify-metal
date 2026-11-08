#!/usr/bin/env python3
"""Package the host build for Swift tests on Macs with only Command Line Tools.

Run build-host.sh first (on the Mac). This creates a macOS-only
Frameworks/CLammps.xcframework from build/host/liblammps.a; it never replaces
a framework that has other slices. The full distribution framework still
requires build-xcframework.sh and Xcode.
"""
import pathlib
import platform
import plistlib
import shutil
import sys

here = pathlib.Path(__file__).resolve().parent
archive = here / 'build/host/liblammps.a'
output = here / 'Frameworks/CLammps.xcframework'
if sys.platform != 'darwin':
    raise SystemExit('The host framework is for macOS; build-host.sh alone runs the bridge tests here.')
if not archive.exists():
    raise SystemExit(f'{archive} is missing; run build-host.sh first.')
identifier = 'macos-' + platform.machine()
info = output / 'Info.plist'
if info.exists():
    existing = plistlib.loads(info.read_bytes())
    if any(lib['SupportedPlatform'] != 'macos' for lib in existing['AvailableLibraries']):
        raise SystemExit('Existing distribution framework preserved; use its macOS slice for tests.')
destination = output / identifier
(destination / 'Headers').mkdir(parents=True, exist_ok=True)
shutil.copy2(archive, destination / 'libCLammps.a')
for source in (here / 'bridge/include').iterdir():
    if source.is_file():
        shutil.copy2(source, destination / 'Headers' / source.name)
info.write_bytes(plistlib.dumps({
    'CFBundlePackageType': 'XFWK', 'XCFrameworkFormatVersion': '1.0',
    'AvailableLibraries': [{
        'LibraryIdentifier': identifier, 'LibraryPath': 'libCLammps.a', 'HeadersPath': 'Headers',
        'SupportedArchitectures': [platform.machine()], 'SupportedPlatform': 'macos'
    }]
}))
print(f'Host-only Swift test framework: {output}')
