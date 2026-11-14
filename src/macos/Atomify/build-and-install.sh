#!/bin/bash
# Builds Atomify for Mac (Release) and installs it in /Applications.
#   src/macos/Atomify/build-and-install.sh
# Needs CLammps.xcframework with a macOS slice (src/shared/lammps/build-xcframework.sh)
# and XcodeGen (brew install xcodegen).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
xcodegen generate --spec src/macos/Atomify/project.yml --quiet
xcodebuild -project src/macos/Atomify/Atomify.xcodeproj -scheme Atomify -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/macos build -quiet
APP=build/macos/Build/Products/Release/Atomify.app
osascript -e 'tell application id "no.uio.atomify.mac.dev" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/Atomify.app
cp -R "$APP" /Applications/
echo "Installed /Applications/Atomify.app"
