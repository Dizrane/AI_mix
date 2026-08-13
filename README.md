# AI Mix Assistant

macOS SwiftUI application foundation for a safe, LLM-directed Logic Pro mixing workflow. It is deliberately not a mixing expert system: musical judgement belongs to an external LLM; the app captures facts, validates a plan and executes only verified adapters.

## Install (prebuilt app)

Download the latest `AI-Mix-Assistant-*.zip` from this repository's **Releases** page, unzip it, and on first launch right-click `AI Mix Assistant.app` → Open → Open (the app is ad-hoc signed, not notarized). Requires macOS 14+ and Logic Pro running with the English UI. Releases are built automatically by the `Release` GitHub Actions workflow (run it manually from the Actions tab, or push a `v*` tag).

## Build and run

```sh
swift test
swift run
```

Open the package in Xcode on a Mac with full Xcode installed to Archive/sign a distributable `.app`. The current environment provides Command Line Tools only, so an Archive cannot be produced here.

The included test target uses XCTest. If `swift test` reports that XCTest is unavailable, select a full Xcode developer directory (`sudo xcode-select -s /Applications/Xcode.app`) and run it again; this is an incomplete local developer-tool installation, not an application dependency.

## Safety contract

- Analyzer and probes only call AX read APIs.
- Unknown data remains `unknown`, `unavailable`, or `requires_probe`.
- Default mode is READ ONLY. DRY RUN never mutates Logic.
- LIVE currently fails safely: no undocumented Logic write adapter ships in this foundation.

See `Documentation/` for the architecture and schemas.
