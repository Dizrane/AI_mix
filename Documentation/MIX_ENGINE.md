# MixEngine — offline mixing prototype

`MixEngine` proves that the app can mix OUTSIDE Logic Pro: it loads the user's installed Audio Unit plugins itself, configures them programmatically, and renders a summed mix through its own bus graph — no Logic process, no UI scripting, no Accessibility writes anywhere on this path. It is a prototype: it exists to prove programmatic AU control and honest offline summing, not to replace a DAW. The inputs are the same full-timeline WAVs the app's export produces (every file starts at t=0, silence included), so alignment is positional by construction and the graph carries no start offsets.

## MixGraph schema (version 1.0)

A `MixGraph` is a small, versioned Codable JSON document — designed so an LLM can generate it, which is why every field has a one-sentence meaning (see the doc comments in `Sources/MixGraph.swift`, which are the schema's normative description). Top level: `schemaVersion` (exact string, anything unknown is a named refusal), `tracks`, `buses`, `master`.

- **Track**: `name` (unique, used in reports and errors), `file` (WAV path, absolute or relative to the render folder), `gainDB` (post-insert gain, default 0), `pan` (−1…+1, default 0), `inserts` (ordered AU effects), `sends` (post-fader sends into buses).
- **Send**: `bus` (a name defined in `buses` — an unknown name is a named error), `levelDB` (required), `pan` (default 0, applied to the sent copy only).
- **Bus**: `name` (unique), `gainDB` (applied after the bus inserts), `inserts`. Every bus feeds the master sum.
- **Master**: `inserts` process the complete sum of all tracks and buses; `gainDB` is applied AFTER the master chain as a final trim, so a limiter's ceiling still holds.
- **Insert**: identified by `component` — the FourCC identifier `"type/subtype/manufacturer"` (e.g. `"aufx/pmeq/appl"`), the same form `PluginInventory` publishes — or, as a fallback, by `name` matched case-insensitively against the installed effect list (`"AUParametricEQ"`, `"FabFilter: Pro-Q 4"` and the bare `"Pro-Q 4"` all match); a name matching zero or more than one installed effect is a named error. `parameters` maps a parameter key to the value to set: the key is resolved against the unit's `AUParameterTree` by identifier first, then by numeric address as a string, then by display name (which must match exactly one parameter).

Example:

```json
{
  "schemaVersion": "1.0",
  "tracks": [
    { "name": "Kick", "file": "audio_track_001.wav", "gainDB": -2,
      "inserts": [{ "component": "aufx/pmeq/appl", "parameters": { "0": 90, "2": 3 } }],
      "sends": [{ "bus": "verb", "levelDB": -12 }] }
  ],
  "buses": [
    { "name": "verb", "inserts": [{ "component": "aufx/mrev/appl", "parameters": { "0": 100 } }] }
  ],
  "master": { "gainDB": -1, "inserts": [{ "component": "aufx/lmtr/appl" }] }
}
```

## Render pipeline

The engine (`Sources/MixEngine.swift`) renders through AVAudioEngine in **manual rendering mode (offline)**, enabled before any node is attached so no connection ever consults audio hardware — the render behaves identically on a Mac with no output device (CI included).

1. **Validation first.** Schema version, non-empty track list, unique track/bus names and resolvable send destinations are checked before any file or plugin is touched.
2. **Inputs.** Each track is an `AVAudioFile` scheduled on its own `AVAudioPlayerNode` at t=0. The mix sample rate is the first file's rate; a file at any other rate is a named error — this prototype never resamples. Mono and stereo inputs are accepted (a mono source is upmixed by the mixer node's own pan law).
3. **Inserts.** Each insert resolves against `AVAudioUnitComponentManager` (missing plugin = hard named error), instantiates synchronously for v2 units and through the async out-of-process API with a hard timeout for v3, and is connected in chain order. Parameters are set through `AUParameterTree`, each value read back immediately; the result carries the full write/read-back report, and a key that resolves to nothing fails the render by name, listing the parameters the unit really exposes — nothing is skipped silently.
4. **Track stage.** The insert chain feeds a per-track `AVAudioMixerNode` whose `outputVolume` is the track gain and `pan` the track pan.
5. **Sends.** AVAudioEngine's connection API has no per-connection gain, so a send is a dedicated `AVAudioMixerNode`: the track mixer's output fans out in one `connect(_:to:fromBus:format:)` call with multiple `AVAudioConnectionPoint`s — one into the master sum, one into each send mixer — and the send mixer's `outputVolume` implements the send level, its `pan` the send pan, its output feeding the bus collector. Sends are therefore post-fader and post-pan by construction.
6. **Buses and master.** Each bus is collector mixer → inserts → gain mixer → master sum. The master sum runs the master inserts, then the master gain as a final trim, into the engine's output node.
7. **Render.** The engine pulls `renderOffline` in ≤4096-frame blocks for the longest input's length plus `tailSeconds` (so reverb/delay tails are captured) and writes `mix.wav` as float32 or 24-bit PCM at the input sample rate.
8. **Measurement.** The finished file is measured by the same local `AudioMetricsAnalyzer` the app uses for exported WAVs (BS.1770-4 LUFS, true peak, sample peak, clipped-sample count, spectrum…); `MixRenderResult` carries the numbers and the insert reports. The engine only reports facts — what is acceptable is the caller's judgement. Bus outputs can additionally be measured through render taps, explicitly best-effort: manual-rendering taps carry no delivery guarantee, so a bus is either measured or named unavailable in `notes`, never guessed.

Known prototype limits, stated rather than hidden: insert latency is not compensated (a look-ahead limiter shifts the render by its latency); mixer nodes apply their own pan/upmix law, not Logic's; sample-rate mismatches are refusals, not resampling.

## Lab bench (debug builds only)

```sh
swift run "AI Mix Assistant" mix-render <wav-folder> <mixgraph.json> [--tail <seconds>] [--int24] [--no-bus-metrics]
```

Renders `mix.wav` next to the input WAVs and prints the insert parameter reports plus the measured facts. The subcommand is compiled into DEBUG builds only and is a lab bench, not product UI.

## What the tests prove

CI runners have only Apple's built-in AUs, so the suite (`Tests/MixEngineTests.swift`) proves the engine on AUParametricEQ, AUMatrixReverb and AUPeakLimiter: exact arithmetic summing with positional alignment, parameter roundtrip through the tree plus a real spectral change in the cut band, an audible reverb tail through the send topology, zero clipped samples through a master limiter on a deliberately clipping sum, and named errors for missing plugins, unresolved parameters, mismatched sample rates and unknown buses. Rendering a project's exported WAVs through third-party AUs (FabFilter etc.) exercises the same code paths but must be smoke-tested on a real Mac with those plugins installed.
