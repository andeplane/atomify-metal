# Atomify for Mac on the Mac App Store

Preparation started November 15, 2026. This is a new listing for the simple
Mac app (`src/macos/Atomify`, the iPhone and iPad app in a Mac window). It
does not replace or change the existing Atomify listing, which stays as it is
until Atomify LAMMPS Pro is ready to take its place.

Nothing has been uploaded. Uploading and submitting are separate steps that
wait for Anders.

| Field | Value |
| --- | --- |
| Bundle ID | `com.compphys.atomify.mac` (proposed; set in `src/macos/Atomify/Config/AppStore.xcconfig`) |
| Team | `4XKET6P69R` |
| Version | 3.0 (1), the same version as the iPhone and iPad app |
| Minimum macOS | 15.0 |
| Architecture | Apple silicon (arm64) only; `CLammps.xcframework` has no Intel slice |
| Category | Education (`public.app-category.education`) |
| Sandbox | App Sandbox on, no further entitlements |
| Hardened runtime | On |
| Encryption | `ITSAppUsesNonExemptEncryption` is false |
| Privacy manifest | `PrivacyInfo.xcprivacy`, the same file as on iOS |
| Privacy policy | https://github.com/andeplane/atomify-metal/blob/main/docs/app-store/privacy.md |

## Why the sandbox needs nothing more

- Simulations run in the app's own temporary folder (`FileManager.default.temporaryDirectory`, which is inside the container when sandboxed).
- Examples are read from the app bundle.
- Settings are in the app's own `UserDefaults`.
- The app makes no network connections. Links (LAMMPS, source code, privacy policy) open in the browser.
- LAMMPS and LLVM's OpenMP runtime are static libraries inside the app's one executable, so there are no embedded dylibs or frameworks to sign separately.

## Build, archive and export

```sh
xcodegen generate --spec src/macos/Atomify/project.yml

xcodebuild -project src/macos/Atomify/Atomify.xcodeproj -scheme Atomify \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/macos-appstore \
  -archivePath build/app-store/mac-3.0/Atomify-3.0-1.xcarchive \
  -xcconfig src/macos/Atomify/Config/AppStore.xcconfig \
  ATOMIFY_SOURCE_REVISION="$(git rev-parse HEAD)" \
  -allowProvisioningUpdates archive

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin xcodebuild -exportArchive \
  -archivePath build/app-store/mac-3.0/Atomify-3.0-1.xcarchive \
  -exportPath build/app-store/mac-3.0/export \
  -exportOptionsPlist src/macos/Atomify/Config/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates
```

The export options say `destination: export`, so this writes a signed `.pkg`
and uploads nothing. `-allowProvisioningUpdates` registers the bundle ID in
the developer account the first time, so the bundle ID must be final before
the first archive with that flag.

The default build (no `-xcconfig`) stays the ad hoc signed development app
`no.uio.atomify.mac.dev`, also sandboxed and hardened, so everyday builds run
under the same rules as the store build.

## Store listing draft

### Name

"Atomify" is taken by the existing listing, and App Store names must be
unique, so the new listing needs its own name. The name under the icon and in
the menu bar stays "Atomify".

Anders chose "Atomify: Atoms and molecules in motion" (November 15, 2026).
That is 38 characters and the limit is 30, so it is split over the name and
the subtitle:

**Atomify: Atoms in Motion**

### Subtitle (30 characters at most)

Atoms and molecules in motion

### Promotional text (170 characters at most)

Real molecular dynamics on your Mac. Pick a simulation, press play, and watch water, crystals, flows and explosions unfold atom by atom.

### Description

Atomify runs real molecular dynamics simulations on your Mac and shows every atom while it happens.

Pick one of 34 ready-made simulations and watch it live in 3D: water molecules tumbling, ice melting, gas hydrates, a shock wave tearing through a crystal, a droplet splashing on a surface, flow past an obstacle, polymers, nanotubes, and chemical reactions such as a hydrogen explosion.

The physics is not an animation. Atomify runs LAMMPS, the simulator researchers use on supercomputers, right on your Mac, and draws the atoms with a fast Metal renderer as the numbers come out.

WATCH
• Rotate, pan and zoom around the system while it runs
• Click any atom to inspect it
• Slow the simulation down or speed it up
• Hide the controls and let it fill the window

MEASURE
• Live dashboard with temperature, pressure, energy and other quantities plotted while the run goes
• Simulation details: number of atoms, time step, speed

LEARN
• Every simulation comes with a short explanation
• Read the actual LAMMPS input script behind each one
• Simulations across fluids, solids, chemistry, materials and statistical physics

Atomify is for students, teachers and anyone curious about what matter looks like at the scale of atoms. It needs no account, shows no ads, and collects no data. Everything runs on your Mac.

Atomify is open source. LAMMPS is developed at Sandia National Laboratories and distributed under the GPL.

### Keywords (100 characters at most)

molecular dynamics,LAMMPS,atoms,molecules,physics,chemistry,simulation,science,water,materials

### Other fields

| Field | Value |
| --- | --- |
| Primary category | Education |
| Secondary category | none (or Developer Tools if a second one is wanted) |
| Price | Free |
| Age rating | 4+ (no ads, purchases, web access, user content or mature themes) |
| Copyright | 2026 Anders Hafreager |
| Support URL | https://github.com/andeplane/atomify-metal/issues |
| Marketing URL | https://github.com/andeplane/atomify-metal |
| Privacy policy URL | https://github.com/andeplane/atomify-metal/blob/main/docs/app-store/privacy.md |

### App privacy answers

Data collection: **No, we do not collect data from this app.** The app has no
network code, no analytics, no accounts and no third-party SDKs that collect
data. The privacy manifest declares no tracking, no collected data, and one
required-reason API: `UserDefaults` with reason `CA92.1` (the app's own
settings).

### Export compliance

Uses no encryption. `ITSAppUsesNonExemptEncryption` is false in Info.plist, so
App Store Connect does not ask on each upload.

### Notes for App Review

Atomify needs no account or sign in. It opens straight into a running water
simulation with a welcome card. Close the card, then drag to rotate, scroll to
zoom, and click an atom to inspect it. Choose Simulation > Simulations
(Command-L) to open the library and start any of the 34 bundled simulations.
Simulation > Dashboard (Command-D) shows live plots.

All simulations are bundled and computed on the Mac by LAMMPS
(https://www.lammps.org), which is compiled into the app. The app makes no
network connections. It runs in the App Sandbox with no additional
entitlements and writes only temporary simulation files inside its container.

The app is open source under the GPL:
https://github.com/andeplane/atomify-metal. This is a separate app from our
existing "Atomify" listing, with a different purpose: this one is a simple
viewer of ready-made simulations, while the other is a full editor.

### Screenshots

The Mac App Store takes 1 to 10 screenshots at 1280 × 800, 1440 × 900,
2560 × 1600 or 2880 × 1800. The set is six RGB PNGs at 2880 × 1800 (the app
window at 1440 × 900 points, 2x), made offscreen from the real app: each
example runs for a few seconds, its atoms are rendered with the app's
renderer, camera and view settings, and the window's controls are drawn on
top. No window is shown. Reduced JPEG copies for review are in
[`mac-3.0-screenshots/`](mac-3.0-screenshots/).

1. `01-gas_hydrates`: gas hydrates running, with the controls.
2. `02-singlewater-dashboard`: the water molecule with the live dashboard (the angle plot has data).
3. `03-gallery`: the simulation library.
4. `04-sica_sheet_melt-detail`: the SiC nanosheet's page with its description.
5. `05-h2_explosion-view`: the hydrogen explosion coloured by kinetic energy, with the view options.
6. `06-flow_pois`: Poiseuille flow, with the controls.

The window is never key, so the window buttons are grey and toolbar items
(the detail page's title and Run button) draw in their inactive look; the
controls over the simulation look as in the app.

```sh
xcodegen generate --spec src/macos/Atomify/project.yml
xcodebuild -project src/macos/Atomify/Atomify.xcodeproj -scheme AtomifySnapshots \
  -derivedDataPath build/macos-dd build
build/macos-dd/Build/Products/Debug/AtomifySnapshots.app/Contents/MacOS/AtomifySnapshots \
  --store build/app-store/mac-3.0/screenshots
for f in build/app-store/mac-3.0/screenshots/*.png; do
  sips -s format jpeg -s formatOptions 80 -z 900 1440 "$f" \
    --out docs/app-store/mac-3.0-screenshots/"$(basename "$f" .png)".jpg
done
```

The PNGs under `build/` are the ones to upload; they are not committed.
Pass a name prefix after the folder (for example `05`) to remake one.

## Validation, November 15, 2026

Checked on the Mac without launching the app or opening a window, and without
uploading anything.

- Release build with the sandbox and the hardened runtime: passed.
- `codesign --verify --deep --strict`: passed. The archive carries the sandbox
  entitlement only. The local ad hoc build also has `get-task-allow`, which
  Xcode adds for running locally and which does not reach the archive.
- Info.plist in the archive: `com.compphys.atomify.mac`, 3.0 (1), minimum
  macOS 15.0, Education, encryption false, `AtomifySourceRevision` set to the
  commit, icon `MacAppIcon`.
- `PrivacyInfo.xcprivacy` is in `Contents/Resources`. `Assets.car` has every
  Mac icon size from 16 to 1024 at 1x and 2x.
- The executable is arm64 only and links only system frameworks and
  `/usr/lib/swift`. No embedded frameworks or dylibs. The app is 30 MB.
- No private API. LAMMPS links `popen`, sockets and `dlopen` for its shell,
  socket and plugin commands; no bundled example uses them and the sandbox
  refuses them.
- LAMMPS inside the sandbox: `atomify-check-examples --continue` was wrapped
  in a small app signed with `Config/Atomify.entitlements` and the hardened
  runtime, and run with no window. All 34 bundled examples ran 100 steps or
  more with their scratch files in the sandbox container: 34 ok, 0 failed,
  0 timed out. Reading the repository's `Examples` folder from the same
  wrapper was refused, which shows the sandbox was on.
- Archive with the App Store identity (no `-allowProvisioningUpdates`):
  succeeded, signed with Apple Development for team `4XKET6P69R`.
- Export for the store: blocked on signing that only the account owner can
  set up. There is no Mac Installer Distribution or Apple Distribution
  certificate on the Mac, no App ID or Mac App Store profile for
  `com.compphys.atomify.mac`, and Xcode's saved Apple account needs signing
  in again.
- `swift test`: 319 passed. 7 failed (6 in `SimulationSessionTests`, 1 in
  `PlaybackRateTests`) waiting for the display link while the displays were
  asleep at night; they do not touch the changed code and need a rerun with
  the display awake.

## Signed package, November 15, 2026

Anders approved the bundle ID `com.compphys.atomify.mac` and its
registration. The archive and export ran from `686e89d` with
`-allowProvisioningUpdates` and produced
`build/app-store/mac-3.0/export/Atomify.pkg` (14 MB, not committed). Nothing
was uploaded.

- Package: signed by "3rd Party Mac Developer Installer: Anders Hafreager
  (4XKET6P69R)", chained to Apple's root.
- App inside: signed by the cloud-managed "Apple Distribution" certificate
  with the hardened runtime. Entitlements are the application identifier,
  the team identifier and the App Sandbox, with no `get-task-allow`.
  `codesign --verify --deep --strict` passes. The Mac Team Store profile is
  embedded.
- Info.plist: `com.compphys.atomify.mac`, 3.0 (1), `AtomifySourceRevision`
  `686e89d80cce6c444d00bf2fd56ab255b8a20334`.
- Created in the developer account: the App ID, its Mac App Store profile
  and a Mac Installer Distribution certificate.
- Not validated against Apple: there is no App Store Connect API key on the
  Mac.
- If export reports `No Accounts` while Xcode shows the account, the saved
  login is missing from where `xcodebuild` reads it. Signing out and in
  again in Xcode's Apple Accounts settings and quitting Xcode once fixes it.
- With the display awake, the display-link tests pass. `runsAnExampleEndToEnd`
  times out waiting for plots, also on main before this work; it is a
  separate bug.

## Submission

- App Store Connect record: "Atomify: Atoms in Motion", app id 6835061561,
  SKU `atomify-mac`, bundle id `com.compphys.atomify.mac`. It is a new
  listing; the Qt Mac app (app id 1192327034) is untouched.
- Build 3.0 (1) was uploaded and selected on version 3.0 on 2026-11-15.
- Listing as drafted above, six 2880x1800 screenshots, category Education,
  age rating 4+, free in all countries, privacy "Data Not Collected"
  (published), no sign-in needed for review.
- Submitted for App Review on 2026-11-15; status Waiting for Review.

## Still to do

- Wait for Apple's review result and handle any feedback.
