# AI Mix Assistant

macOS SwiftUI application foundation for a safe, LLM-directed Logic Pro mixing workflow. It is deliberately not a mixing expert system: musical judgement belongs to an external LLM; the app captures facts, validates a plan and executes only verified adapters.

## Install (prebuilt app)

Download the latest `AI-Mix-Assistant-*.zip` from this repository's **Releases** page and unzip it: you get one folder `AI_Mix_<version>` with the app inside. Move the whole folder anywhere and always run the app from inside it — the folder is the program's closed shell: every piece of data the app creates (`Data/`) lives next to the `.app`, and deleting the folder removes the program completely. The app refuses to start its storage when the `.app` is dropped directly into a shared folder like Downloads or Desktop, so it never scatters files. On first launch right-click `AI Mix Assistant.app` → Open → Open (the app is ad-hoc signed, not notarized). Because the download is quarantined, macOS may run that first launch from a temporary read-only copy (App Translocation) and the app will report that its data storage is unavailable — click **Fix and Relaunch** in that message: it removes the quarantine attribute from the app's own folder only and restarts the app from wherever you placed it. Requires macOS 14+ and Logic Pro running with the English UI. After the first install the app keeps itself current: it checks this repository's latest release at launch and, when a newer version exists, offers a one-click in-place update (sidebar button or Settings → Updates) that swaps the `.app` inside your folder, leaves `Data/` untouched, renames the folder itself to the new version when it still carries the release's `AI_Mix_<version>` name (a folder you renamed yourself is never touched) and relaunches. An install whose folder name was left behind by an older updater is caught up the same way on the next launch. Releases are built automatically by the `Release` GitHub Actions workflow (run it manually from the Actions tab, or push a `v*` tag). The release notes' "Что нового" section is taken from the Russian `CHANGELOG.md` — add a `## v<version>` section there before releasing; without it the notes fall back to a raw commit list.

## Build and run

```sh
swift test
swift run
```

Open the package in Xcode on a Mac with full Xcode installed to Archive/sign a distributable `.app`. The current environment provides Command Line Tools only, so an Archive cannot be produced here.

The test target uses Swift Testing (`import Testing`), which ships with the Swift 6 toolchain. Running `swift test` still requires a full Xcode developer directory (`sudo xcode-select -s /Applications/Xcode.app`); with Command Line Tools alone the platform test runner is unavailable. The same suite also runs in CI on every pull request.

## Safety contract

- Analyzer and probes only call AX read APIs.
- Unknown data remains `unknown`, `unavailable`, or `requires_probe`.
- Default mode is READ ONLY. DRY RUN never mutates Logic.
- LIVE executes only what is verified: the four channel-strip actions (`set_volume`, `set_pan`, `set_mute`, `set_solo`) through documented AX mechanisms — AXPress for the switches, AXValue writes for the faders — each write calibrated against the strip's own displayed value (Logic's fader publishes raw units, so the scale is proven per control, never assumed), re-read afterwards and rolled back when it does not verify. LIVE requires an explicit mode choice plus a per-run confirmation; only validator-approved actions run; a failed action halts the queue and a fresh scan shows what really changed. Every other action still fails safely: no unverified write adapter exists.

See `Documentation/` for the architecture and schemas.
