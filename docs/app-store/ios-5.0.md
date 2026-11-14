# Atomify 5.0 for iPhone and iPad

Release preparation started November 14, 2026. Use the existing App Store app;
do not create a replacement listing.

| Field | Value |
| --- | --- |
| App Store app | Atomify, Apple ID `934441274` |
| Bundle ID | `com.compphys.atomify` |
| Team | `4XKET6P69R` |
| Previous published version | 2.10 |
| Candidate | 5.0 (1), iOS 18.0 or later, iPhone and iPad, landscape |
| App Store Connect | https://appstoreconnect.apple.com/apps/934441274/distribution/ios/version/inflight |
| Privacy policy | https://github.com/andeplane/atomify-metal/blob/main/docs/app-store/privacy.md |

## Build and export

Generate `src/ios/Atomify.xcodeproj` with `xcodegen generate --spec
src/ios/project.yml`. The default bundle remains the separate development app.
Use the production override explicitly for a release:

```sh
xcodebuild -project src/ios/Atomify.xcodeproj -scheme Atomify \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios \
  -archivePath build/app-store/5.0/Atomify-5.0-1.xcarchive \
  -xcconfig src/ios/Config/AppStore.xcconfig \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath build/app-store/5.0/Atomify-5.0-1.xcarchive \
  -exportPath build/app-store/5.0/export \
  -exportOptionsPlist src/ios/Config/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates
```

An archive succeeding is not an App Store upload. Verify export, upload,
Apple processing and selected build separately. The first export reported
`No Accounts` and no App Store profile; the Apple account in Xcode needs a
fresh sign-in. No credentials belong in this repository.

## Store media

Generated assets are under the ignored `build/app-store/5.0/`, never committed.
Both required device classes have six screenshots and a 24-second preview.

| Asset | Dimensions / format |
| --- | --- |
| iPhone medium screenshots | 2622 × 1206, RGB PNG |
| iPhone large screenshots (additional source set) | 2868 × 1320, RGB PNG |
| iPad 13-inch screenshots | 2752 × 2064, RGB PNG |
| iPhone preview | 1920 × 886, H.264 High Level 4.0, 30 fps |
| iPad preview | 1600 × 1200, H.264 High Level 4.0, 30 fps |
| Preview audio | Silent AAC stereo, 48 kHz |
| Product-page header | 3840 × 1646, RGB PNG |

The screenshots show gas hydrates, water with its live dashboard, Poiseuille
flow, ice, a silicon carbide sheet, and the real simulation library. Captions
sit outside the full captured app screen. Preview footage shows gas hydrates,
the water dashboard and flow at their recorded speed. No simulated app UI,
stock science animations or unlicensed music are used.

To reproduce, build the Release simulator app with `ARCHS=arm64
ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`; the local LAMMPS xcframework
contains the arm64 simulator slice. Then run:

```sh
python3 src/ios/tools/capture_app_store.py --device <UDID> --family iphone --video
python3 src/ios/tools/capture_app_store.py --device <UDID> --family ipad --video
python3 src/ios/tools/build_app_preview.py build/app-store/5.0/iphone
python3 src/ios/tools/build_app_preview.py build/app-store/5.0/ipad --ipad
```

`-AtomifyCapture <example id> -AtomifyScreen play` opens the real interface
without the welcome; use `-AtomifyScreen dashboard` for the live dashboard,
`-AtomifyScreen gallery` for the library, or `-AtomifyScreen settings` for
release QA. Normal launches retain their existing behavior.

## Validation and outstanding steps

- Release simulator build and production-identity archive passed.
- `swift test --enable-code-coverage --jobs 2` passed: 122 XCTest tests and
  313 Swift Testing tests, 435 total, with no failures.
- All 34 bundled iOS simulations passed `atomify-check-examples --examples
  src/ios/Examples --steps 100 --timeout 120` with no failures or skips.
- Both home Macs timed out over SSH before remote execution. The package
  checks ran locally with two build jobs; simulator and signing checks use
  the local Apple SDKs.
- All 18 generated screenshots were checked for device dimensions and RGB
  encoding. Both final videos passed assertions for dimensions, 30 fps,
  24-second duration and Apple's 500 MB limit.
- Media were visually reviewed together in `review.html` and
  `contact-sheet.jpg`. The browser capture `release-media-review.png` is
  PR evidence, generated headlessly with agent-browser.
- `PrivacyInfo.xcprivacy` declares no tracking or collected data and the
  app-local UserDefaults reason `CA92.1`. Settings links to the policy and
  the current source repository.
- App Store Connect 5.0 draft, refreshed description, release notes,
  keywords, support URL and review instructions are saved. Both required
  screenshot sets and previews have been uploaded and shown in the UI.
- Finish App Store signing/export and upload after Xcode authentication,
  wait for Apple processing, select the processed build, and resolve any
  remaining validation before submission. Record actual submission status;
  preparation is not approval or publication.
