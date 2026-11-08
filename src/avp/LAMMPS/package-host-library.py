#!/usr/bin/env python3
"""Package the real host build for Swift tests on Macs with only CLT.

Run build-host.sh first. This creates a macOS-only xcframework; it never
replaces an existing framework with visionOS slices. The full distribution
framework still requires build-xcframework.sh and Xcode.
"""
import pathlib
import platform
import plistlib
import shutil

here = pathlib.Path(__file__).resolve().parent
archive = here / 'build/host/liblammps.a'
output = here.parent / 'Packages/AtomifyKit/Frameworks/CLammps.xcframework'
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
