# Architecture

`Accessibility` (read only) → `RawSnapshot` → `SnapshotNormalizer` → `LLMProvider` → `CommandValidator` → preview → `CommandExecutor` → fresh scan → `DiffEngine`.

All concrete DAW work is behind protocols (`DAWAnalyzer`, `CommandExecutor`). Add a DAW by implementing those protocols; add an LLM by implementing `LLMProvider`. `SessionStore` persists immutable artefacts under Application Support/AI Mix Assistant Data/projects/<session>.

Logic Pro has no public, complete semantic automation API for these channel-strip operations. AX data is collected as evidence, not treated as a documented Logic model. A live adapter must be action-specific, use an allowed interaction mechanism, re-read the result, and be separately tested before registration.
