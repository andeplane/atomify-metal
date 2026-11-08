# Atomify for iPhone and iPad

A SwiftUI app that runs the bundled Atomify examples with the shared engine and draws them with the Metal renderer.
It opens straight into a running simulation (Single water molecule): drag to rotate, two fingers to pan, pinch to zoom, tap an atom to inspect it, double tap to frame the system again, and tap empty space to hide the controls.
A glass toolbar opens the examples, restarts, plays or pauses, and opens the view options and the dashboard as sheets.

The app is a thin shell.
The engine, renderer, catalog and run lifecycle are the shared packages in the root `Package.swift` (AtomifyKit with AtomifyEngine and AtomifyRender), the same ones the Mac app uses.
The examples are the Mac app's folder, `src/macos/AtomifyMac/Examples`, copied into the app at build time.

## Build

An iOS app needs an Xcode project with signing, so this folder holds an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec, `project.yml`, instead of a committed project.
You need Xcode with the iOS platform, CMake 3.28 or newer, and XcodeGen.

1. Build LAMMPS once (and again after changing `src/shared/lammps/`).
   The default builds every slice, including `ios` and `ios-simulator`; to build only what the Mac and iOS apps need:

   ```sh
   SLICES="macos ios ios-simulator" src/shared/lammps/build-xcframework.sh
   ```

2. Generate the project:

   ```sh
   brew install xcodegen          # once
   xcodegen generate --spec src/ios/project.yml
   ```

   This writes `src/ios/Atomify.xcodeproj` (git-ignored). Generate again after pulling changes to `project.yml` or adding files.

3. Choose a signing team.
   Either copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` (it survives regenerating), or pass it to `xcodebuild` as below.
   The bundle id defaults to `no.uio.atomify.dev`, so the build sits next to the App Store app; set `ATOMIFY_BUNDLE_ID` to change it.

4. Build and install on a connected iPhone:

   ```sh
   xcodebuild -project src/ios/Atomify.xcodeproj -scheme Atomify -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath build/ios \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     DEVELOPMENT_TEAM=ABCDE12345 build

   xcrun devicectl list devices
   xcrun devicectl device install app --device <device id> build/ios/Build/Products/Release-iphoneos/Atomify.app
   xcrun devicectl device process launch --device <device id> no.uio.atomify.dev
   ```

   Or open `src/ios/Atomify.xcodeproj` in Xcode, pick the Atomify scheme and the phone, and run.
   Use the Release configuration for large systems; Debug draws the same picture but builds scenes more slowly.

The first launch on a phone may ask you to trust the developer in Settings › General › VPN & Device Management.

## License

The app links LAMMPS (GPLv2) and bundles the Atomify web app's examples (GPLv3), so it is distributed under the GPL.
