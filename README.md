# Wi-Fi Mesh Planner: LiDAR Scan

Scan your home with LiDAR, mark where the router is, and see the estimated Wi-Fi signal in every room. The app suggests the best positions for the router and mesh satellites and shows the signal map on the floor in augmented reality. On the home screen it is called **Mesh Planner**.

- Website: https://wifi-mesh-planner.sney.eu
- Privacy policy: https://wifi-mesh-planner.sney.eu/privacy/
- Support: https://wifi-mesh-planner.sney.eu/support/

The app is English-only. It is open source under the [MIT License](LICENSE).

## Contents

- [What the app does](#what-the-app-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Building locally](#building-locally)
- [Running on a device](#running-on-a-device)
- [Tests](#tests)
- [Screenshots](#screenshots)
- [Release archive and App Store upload](#release-archive-and-app-store-upload)
- [Scripts reference](#scripts-reference)
- [Repository layout](#repository-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## What the app does

- **Whole-home scan (RoomPlan):** room by room in the same AR session, merged with `StructureBuilder`; supports multiple floors. During the scan, the "I'm next to the router" button records the real router position.
- **RF-ready floor plan:** the plan is aligned to the axes, corners are closed, walls are cut at doors, windows and openings, and objects (refrigerator, cabinets, bathtub and so on) become obstacles. Materials follow the construction profile (masonry, drywall or concrete) and can be corrected wall by wall or in bulk.
- **Single propagation model:** free space + per-wall loss (higher at an angle) + first-order reflections + floor slab between stories. The map, coverage, rooms, measurement point and optimizer all use the same calculation.
- **Realistic speed:** noise by channel width, MCS by Wi-Fi standard (5/6/6E/7), real throughput (~60% of PHY rate) limited by satellite backhaul and the internet plan.
- **Mesh:** backhaul tree (each satellite links to the router or another satellite), Ethernet option, tri-band kit.
- **Best placement:** optimizes the router and satellites together inside the home, away from walls and furniture, with backhaul ≥ −70 dBm; recommends how many satellites are needed; preview on the map, apply and undo.
- **Calibration:** real measurements (AirPort Utility or the router's app) tune the model.
- **Augmented reality:** relocalizes with the environment map saved at the end of the scan and projects the heatmap on the floor, with live signal where the phone is.
- **Projects:** multiple projects, bounded backups, `.signalsim` files to share and import, PDF report, export to the web simulator.
- **Accessibility:** VoiceOver actions and menus for moving the router, walls and the measurement point, Dynamic Type, Reduce Motion, color-blind-friendly palette.
- **Privacy:** no account, no analytics, no tracking. Scans and projects stay on the device unless you export them.

## Requirements

| What | Version |
| :--- | :--- |
| macOS | One that runs Xcode 26 or newer |
| Xcode | **26 or newer**, with the **iOS 26 SDK** (required for App Store submissions; the scripts check this) |
| XcodeGen | Any recent version (`brew install xcodegen`; `bootstrap.sh` installs it) |
| Homebrew | Only needed if XcodeGen is not installed yet |
| Python 3 + Pillow | Only for composed screenshots (`pip3 install pillow`) |
| Device | iOS 17+. Scanning needs an iPhone Pro or iPad Pro with LiDAR. The demo project, import and map work everywhere, including the simulator. |

Make sure the full Xcode is selected, not the Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version
```

## Quick start

```bash
git clone https://github.com/sneycampos/wifi-mesh-planner.git
cd wifi-mesh-planner
./scripts/bootstrap.sh          # checks Xcode 26+, installs XcodeGen, generates the Xcode project
./scripts/test.sh               # unit tests on macOS
./scripts/build.sh --run --demo # builds, boots a simulator and opens the demo apartment
```

No signing, Apple account or secrets are needed for any of these.

## Building locally

The Xcode project is generated from `project.yml` with XcodeGen. Edit `project.yml` rather than the `.xcodeproj`, then regenerate. Every build script regenerates the project unless you pass `--no-generate`.

```bash
./scripts/build.sh                      # Debug, iOS Simulator, unsigned
./scripts/build.sh --release            # Release, iOS Simulator
./scripts/build.sh --device             # generic iOS device, unsigned (compile check only)
./scripts/build.sh --run                # build, boot the first available iPhone simulator, install and launch
./scripts/build.sh --run --demo         # same, opening the built-in demo apartment (Debug only)
SIMULATOR="iPhone 17 Pro" ./scripts/build.sh --run
```

Build output goes to `./build/DerivedData` (override with `DERIVED_DATA=/path`). The full log of the last build is `./build/build.log`; on failure the script prints the first errors.

Without the scripts:

```bash
xcodegen generate
xcodebuild -project MeshPlanner.xcodeproj -scheme MeshPlanner \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To work in Xcode, run `./scripts/bootstrap.sh` and open the generated `.xcodeproj`.

## Running on a device

LiDAR scanning and AR need a real device.

1. Open the generated project in Xcode.
2. In the app target's *Signing & Capabilities*, choose your own team and, if needed, change the bundle identifier to one you own.
3. Pick your device and press Run.

Don't commit your personal team or bundle identifier changes.

## Tests

```bash
./scripts/test.sh               # fast: swift test core unit tests (Swift Testing) on macOS
./scripts/test.sh --runner      # also the command-line verification and benchmark runner
./scripts/test.sh --build-app   # also compile the iOS app, which swift test does not build
./scripts/ui-test.sh            # full end-to-end XCUITest suite in the iOS Simulator (opens Simulator.app)
./scripts/ui-test.sh --headless # run XCUITests without opening the Simulator app window
```

Use `./scripts/test.sh` (or `swift test`) for fast inner-loop checks of `MeshPlannerCore`. Run `./scripts/ui-test.sh` for full end-to-end UI verification of `MeshPlannerUI` and `SignalApp` in the simulator (opens Simulator visibly by default; pass `--headless` to skip opening the Simulator window). Test fixtures are synthetic; never add real scans or photos of a home to the repository.

## Screenshots

```bash
./scripts/screenshots.sh              # raw + composed EN/pt-PT marketing frames in ./build/screenshots
./scripts/screenshots.sh --raw-only   # raw captures only
IPHONE_SIM="iPhone 17 Pro Max" IPAD_SIM="iPad Pro 13-inch (M5)" ./scripts/screenshots.sh
```

The script launches the demo apartment on an iPhone and an iPad simulator, sets a clean status bar, and captures each screen once the UI has stopped changing. Composition uses `scripts/screenshots/compose.py` (set `FONT` to override the font).

## Release archive and App Store upload

Only needed by the maintainer. It requires an Apple Developer account signed in to Xcode.

```bash
./scripts/archive.sh                          # signed Release archive + App Store .ipa in ./build/ipa-<timestamp>
./scripts/archive.sh --output ~/Desktop/ipa   # a new or empty directory
TEAM_ID=XXXXXXXXXX ./scripts/archive.sh       # override the team in project.yml
ASC_KEY_ID=... ASC_ISSUER_ID=... ./scripts/archive.sh --upload
```

- Each run writes to new directories under `./build` and never deletes anything. `--output` refuses a directory that already has files in it.
- `--upload` uses `xcrun altool` with an App Store Connect API key. The key file `AuthKey_<ASC_KEY_ID>.p8` must be in a folder altool searches (such as `~/.appstoreconnect/private_keys/`) or in `ASC_KEY_DIR`. Keys and credentials are never stored in the repository.
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` before uploading a new build.

## Scripts reference

All scripts use `set -euo pipefail`, accept `--help`, are safe to rerun, and contain no credentials.

| Script | Purpose |
| :--- | :--- |
| `scripts/bootstrap.sh` | Checks Xcode 26+ and the iOS 26 SDK, installs XcodeGen with Homebrew if missing, generates the Xcode project. |
| `scripts/build.sh` | Simulator or device build (unsigned), Debug or Release, optional run in the simulator with the demo. |
| `scripts/test.sh` | `swift test`, optionally the verification runner and an app build. |
| `scripts/ui-test.sh` | End-to-end XCUITest suite (`MeshPlannerUITests`) in the iOS Simulator (`--headless` skips opening Simulator). |
| `scripts/screenshots.sh` | App Store screenshots from the demo project, raw and composed. |
| `scripts/archive.sh` | Signed archive, App Store `.ipa` export, optional upload. |
| `scripts/common.sh` | Shared helpers, sourced by the others. |

## Repository layout

| Folder | Contents |
| :--- | :--- |
| `Sources/MeshPlannerCore` | Platform-independent core: models, propagation engine, signal field, optimizer, backhaul, calibration, RoomPlan converter, persistence and view model. |
| `Sources/MeshPlannerUI` | SwiftUI interface (iOS): projects, scan, map, sheets, AR and report. |
| `Sources/SignalApp` | App entry point. |
| `Sources/SignalTestRunner` | Command-line verification and benchmark. |
| `Tests/MeshPlannerCoreTests` | Core tests (Swift Testing). |
| `Tests/MeshPlannerUITests` | End-to-end iOS UI tests (XCUITest). |
| `Resources/` | Assets and the privacy manifest. |
| `scripts/` | One-shot build, test, screenshot and release scripts. |
| `site/` | Static website (landing, privacy, support). |
| `docs/` | Technical documentation (architecture, scan pipeline, propagation, materials, UI, AR, storage, testing, optimizer), the review and plan, and App Store material. Start at [docs/README.md](docs/README.md). |
| `project.yml` | XcodeGen source of the Xcode project. |

The Xcode project, scheme, and modules are named MeshPlanner. The home-screen name stays Mesh Planner.

## Troubleshooting

- **"xcode-select points to the Command Line Tools"**: run `sudo xcode-select -s /Applications/Xcode.app`.
- **"Xcode 26 or newer is required" / "iOS 26 SDK"**: update Xcode from the App Store and install the iOS platform in *Xcode > Settings > Components*.
- **"No iPhone simulator available"**: install an iOS simulator runtime in *Xcode > Settings > Components*, or set `SIMULATOR` to an existing one (`xcrun simctl list devices available`).
- **Build failed**: read `./build/build.log`. Remove `./build/DerivedData` for a clean build.
- **Export failed in `archive.sh`**: accept any pending agreement at developer.apple.com and check that Xcode is signed in to the team.
- **Scanning is unavailable**: the device has no LiDAR. Use the demo project or import a `.signalsim` file.

## License

MIT. See [LICENSE](LICENSE).
