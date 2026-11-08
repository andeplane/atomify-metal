# Atomify for iPhone and iPad

A SwiftUI app that runs the bundled Atomify examples with the shared engine and draws them with the Metal renderer.
It runs in landscape only and opens, as Atomify 2 did, on the Water molecule example already running, with the welcome over it (on every launch; the close button or a tap dismisses it): drag to rotate, two fingers to pan, pinch to zoom, tap an atom to inspect it, double tap to frame the system again, and tap empty space to hide the controls.
A glass toolbar opens the examples gallery (pausing the run until you return to it), restarts, plays or pauses, and opens the view options and the dashboard as sheets; the speed pill plays at ¼× to 10× the example's own speed, or as fast as the device can.
The gallery has a row of cards per topic as in Atomify 2; a card shows the example's description, script and files, and Run starts it. Its gear opens Settings (playback speed, performance overlay, about and acknowledgements).

The app is a thin shell.
The engine, renderer, catalog and run lifecycle are the shared packages in the root `Package.swift` (AtomifyKit with AtomifyEngine and AtomifyRender), the same ones the Mac app uses.
The examples are the App Store app's: the iOS gallery of Atomify 2 (the Qt app), ported into `Examples` with the same sections, scripts, thumbnails, colors, starting cameras and speeds.

## Examples

`Examples/examples.json` is generated from a checkout of [ovilab/atomify](https://github.com/ovilab/atomify) at branch `mobile_5.6` (commit 7828e89), the source of the App Store build:

```sh
git clone --branch mobile_5.6 https://github.com/ovilab/atomify.git /tmp/atomify2
python3 src/ios/tools/port_atomify2_examples.py /tmp/atomify2
```

The script copies the scripts unchanged except for file paths and three LAMMPS renames since 2017, and swaps in the files under `tools/atomify2-replacements` (a restart file regenerated with current LAMMPS); each change is listed per example under `atomifyMetal.changes`. It reads each simulation's QML metadata into `atomifyMetal` options: `dialect: atomify2` (the old element colors and radii), `stepsPerFrame: 1` (one timestep per frame, changed by the scripts' `#/speed` lines), the starting `camera` and the `dashboard` panels.
Check that every example runs with `src/shared/lammps/check-examples.sh --examples src/ios/Examples`.

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
