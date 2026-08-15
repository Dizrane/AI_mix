# Architecture

`Accessibility` (read only) → `RawSnapshot` → `SnapshotNormalizer` → `LLMProvider` → `CommandValidator` → preview → `CommandExecutor` → fresh scan → `DiffEngine`.

All concrete DAW work is behind protocols (`DAWAnalyzer`, `CommandExecutor`). Add a DAW by implementing those protocols; add an LLM by implementing `LLMProvider`. `SessionStore` persists exactly one current analysis under `Data/current`, next to the application bundle. That location is deliberate: the whole product lives in one self-contained folder, so deleting that folder (Settings → Delete AI Mix Assistant) removes the app and every trace of its data, and nothing is scattered into `~/Library`.

Logic Pro has no public, complete semantic automation API for these channel-strip operations. AX data is collected as evidence, not treated as a documented Logic model. A live adapter must be action-specific, use an allowed interaction mechanism, re-read the result, and be separately tested before registration. The first such adapter is `LogicChannelStripAdapter` (volume, pan, mute, solo — see `EXECUTOR.md`); `SafeExecutor` routes validator-approved actions to registered adapters in LIVE mode only, and every unadapted action keeps failing safely.
