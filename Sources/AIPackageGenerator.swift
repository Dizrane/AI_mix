import Foundation
import AppKit

/// What the reader actually receives. "Copy for AI" hands over this Markdown alone — no JSON, no WAV files — while Save Package
/// ships them next to it. The document states the one mode it was generated for instead of describing every possibility and then
/// telling the reader to open files that are not there.
enum PackageDelivery: Sendable { case markdownOnly, fullPackage }

/// Provider-neutral export of normalized, evidence-based DAW facts for any external LLM.
struct AIPackageGenerator: Sendable {
    static let schemaVersion = "2.4"
    func make(snapshot: NormalizedSnapshot, sessionID: String, audio: [AudioAsset] = [], plugins: [PluginInventoryItem] = [], probes: [ProbeType] = ProbeType.allCases, delivery: PackageDelivery = .fullPackage) -> String {
        let readiness = PackageReadiness.evaluate(snapshot: snapshot, assets: audio)
        var out: [String] = []
        out += ["# AI Mix Analysis", ""]
        out += primaryInstruction(delivery)
        out += ["", "## Package", "", "- Package schema: `\(Self.schemaVersion)`", "- Analysis ID: `\(sessionID)`", "- Generated: `\(ISO8601DateFormatter().string(from: Date()))`", "- Project: \(render(snapshot.project.name))", "- Logical tracks: \(snapshot.tracks.count)", "- Audio assets: \(audio.count)", "- Exported: \(readiness.audioExported)", "- Requires export: \(audio.count - readiness.audioExported)"]
        out += purposeAndRules(delivery)
        out += ["", "## Project metadata", "", fact("Project name", snapshot.project.name), fact("Tempo", snapshot.project.tempo, unit: " BPM"), fact("Time signature", snapshot.project.timeSignature), fact("Key signature", snapshot.project.keySignature), fact("Sample rate", snapshot.project.sampleRate, unit: " Hz"), fact("Transport", snapshot.project.transportState), fact("Snapshot completeness", snapshot.completeness)]
        out += readinessSection(readiness)
        out += trackLinkingSection(snapshot)
        out += audioAssetsSection(audio, delivery: delivery)
        out += provenanceSection(audio)
        out += missingAudioSection(audio)
        out += pluginSections(plugins)
        out += ["", "## Logic on-screen meters (AX)", "", "Live meter values Logic exposes on screen, not measurements of the audio files: Logic publishes no numeric meter readings over Accessibility, so these stay `unavailable`. Loudness, peak, RMS and the rest of the measured numbers are per exported file under Audio Assets → Audio metrics.", "", fact("Peak", snapshot.audio.peak), fact("RMS", snapshot.audio.rms), fact("LUFS", snapshot.audio.lufs), fact("Gain reduction", snapshot.audio.gainReduction), fact("Input level", snapshot.audio.inputLevel), fact("Output level", snapshot.audio.outputLevel), "", "## Unknown and unavailable data", "", "Every fact carries a state. `unknown` — the analyzer could not determine a value; `unavailable` — no supported evidence was exposed; `requires_probe` — a targeted read-only probe is needed. No missing field implies a musical assumption.", "", "### Current limitations", ""]
        out += snapshot.limitations.map { "- \($0)" }
        out += externalAIInstructions(delivery)
        out += mixPlanSchemaSection()
        return out.joined(separator: "\n") + "\n"
    }
    /// The delivery mode is a fact the app knows, so the document asserts it. Everything after it — which files to open, whether
    /// listening is possible at all, what counts as evidence — follows from that one statement instead of a menu of possibilities.
    private func primaryInstruction(_ delivery: PackageDelivery) -> [String] {
        let opening: [String]
        switch delivery {
        case .fullPackage:
            opening = ["When this package (or its ZIP) is provided to an AI system, THIS document is the authoritative task specification for the package. The AI must NOT require a separate user prompt to begin — handing over the whole package is enough. The standard workflow is: the user gives you this package (typically the ZIP) and you start immediately.", "", "DELIVERY: FULL PACKAGE. This document ships together with `logic_snapshot.json`, `audio_manifest.json`, `manifest.json` and the exported WAV files in `audio/`.", "", "The AI must:", "1. read this document first;", "2. inspect the package contents — `AI_MIX_ANALYSIS.md`, `logic_snapshot.json`, `audio_manifest.json`, `manifest.json`, and the `audio/` folder;", "3. listen to ALL available WAV audio assets in `audio/`;", "4. use `logic_snapshot.json` and `audio_manifest.json` as factual/project context and provenance;", "5. use only facts marked `known` as factual evidence;", "6. follow the External AI Instructions and the response format defined below;", "7. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "8. not create a final Mix Plan before the required analysis, interpretation, questions and user-confirmation stages are completed.", "", "Everything needed is inside the package — you do not need the user to tell you what to read, where the WAVs are, what this file is, or in what order to work. This document defines that workflow.", "", "If your platform cannot process audio files at all, say so plainly, skip the listening steps, work from the written facts and the measured audio metrics below, and ask the user targeted questions where only listening could decide."]
        case .markdownOnly:
            opening = ["This document is the authoritative task specification for the analysis. The AI must NOT require a separate user prompt to begin — receiving this document is enough: start immediately.", "", "DELIVERY: THIS DOCUMENT ONLY. You received the analysis text alone. `logic_snapshot.json`, `audio_manifest.json`, `manifest.json` and the WAV files in `audio/` are NOT part of this delivery and you cannot open them, so there is nothing to look for and nothing to wait for.", "", "The AI must:", "1. read this document first;", "2. treat the Logic facts and the locally measured audio metrics in it as the complete evidence base — the metrics under each audio asset were computed by the application from the real WAV files, so quantitative statements about loudness, peaks, dynamics, tonal balance, stereo image and silence are fully supported here;", "3. never state or imply that it listened to the audio: the audio was not delivered, and claiming otherwise is fabrication;", "4. use only facts marked `known` as factual evidence;", "5. follow the External AI Instructions and the response format defined below;", "6. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "7. not create a final Mix Plan before the required analysis, interpretation, questions and user-confirmation stages are completed.", "", "Where a conclusion genuinely requires hearing the material (timbre, performance quality, intelligibility, musical role), name the asset and the question and ask the user for the full package — Save Package in the application produces a ZIP with the WAV files. Do not stall the rest of the analysis waiting for it."]
        }
        return ["## THIS FILE IS THE PRIMARY INSTRUCTION FOR THE AI", ""] + opening + ["", "Facts vs AI interpretation — keep them strictly separate. Logic FACTS (real track names, logicalTrackID, track/channel facts, audio-asset mapping, the measured audio metrics, the plugin inventory, provenance) are given here and must NEVER be rewritten or altered. Musical INTERPRETATION (musical role, track purpose, vocal/instrument assessment, processing recommendations, the Mix Plan) is yours to produce and lives in a separate layer.", "", "If the user additionally provides their own task or context, honour it as long as it does not contradict the Critical Rules or the response format below."]
    }
    private func purposeAndRules(_ delivery: PackageDelivery) -> [String] {
        let purpose = delivery == .fullPackage
            ? "This package contains factual information extracted read-only from Logic Pro, the paths of the corresponding exported audio tracks, and objective DSP measurements of those files. The external AI must listen to the provided WAV files and combine what it hears with the measurements and these Logic facts. This application performs no musical interpretation of its own."
            : "This document contains factual information extracted read-only from Logic Pro plus objective DSP measurements the application computed from the exported audio tracks. The audio files themselves are not part of this delivery, so the measurements are the audio evidence available to you. This application performs no musical interpretation of its own."
        let audioRule = delivery == .fullPackage
            ? "- Audio interpretation must be based on the actual WAV and the measurements of it, never on names."
            : "- Every statement about how something sounds must rest on the measurements below; anything that needs actual hearing must be marked as requiring the audio, not asserted."
        return ["", "## Purpose", "", purpose, "", "## Critical Rules", "", "- Use actual Logic Track names as factual identifiers only.", "- Do not assume a musical role from a track name.", "- Do not assume that one Logic Track equals one musical role.", "- Multiple Logic Tracks may belong to the same musical element.", "- One Logic AUDIO track corresponds to one full-track WAV export asset. Aux, Bus, Master, Output and other channel-only objects are not audio export assets and do not require WAV files.", "- All of an audio track's regions stay inside that single full-track WAV; regions are provenance only and are never exported as separate WAV files.", "- Do not invent unavailable Logic data.", audioRule, "- If the audio evidence and Logic metadata conflict, explicitly report the conflict.", "- Do not propose destructive changes without user confirmation."]
    }
    private func readinessSection(_ r: PackageReadiness) -> [String] {
        func flag(_ ok: Bool) -> String { ok ? "READY" : "INCOMPLETE" }
        var out = ["", "## Package readiness", "", "- Logic analysis: \(flag(r.logicAnalysis))", "- Track discovery: \(flag(r.trackDiscovery))", "- Audio assets: \(r.audioTotal == 0 ? "INCOMPLETE (none prepared)" : "\(r.audioExported)/\(r.audioTotal) exported")", "- Provenance: \(flag(r.provenanceOK))", "- AI Package: \(r.overall.rawValue.uppercased())", "", "Audio readiness counts ONLY Logic audio tracks that are audio export assets. When the package is ready, every Logic audio track represented in Audio Assets has a real, readable WAV; Aux / Bus / Master / Output channel-only objects are not audio assets and never block readiness."]
        if r.audioTotal > 0 && r.audioExported < r.audioTotal { out += ["", "Audio analysis incomplete — \(plural(r.audioTotal - r.audioExported, "WAV file")) missing. Export the missing tracks and Refresh Export Status for a complete analysis."] }
        if !r.errors.isEmpty { out += ["", "Integrity errors (do not rely on this package until fixed):"] + r.errors.map { "- \($0)" } }
        return out
    }
    private func provenanceSection(_ assets: [AudioAsset]) -> [String] {
        var out = ["", "## Audio ↔ Logic provenance", "", "Each WAV maps unambiguously to one Logic audio track (via logicalTrackID) and its exact Logic name. Only audio tracks have WAVs; Aux/Bus/Master/Output channel-only objects do not appear here. Region names and IDs are listed once, under each asset in Audio Assets."]
        if assets.isEmpty { out += ["", "- No audio assets prepared."]; return out }
        out += [""] + assets.map { asset in
            let wav = asset.actualExportedPath.value ?? "\(asset.expectedExportPath) (expected — not yet exported)"
            return "- \(wav) ← `\(asset.logicalTrackID)` \u{201C}\(asset.trackName.value ?? "unknown")\u{201D} • \(plural(asset.regionCount, "region"))"
        }
        return out
    }
    private func missingAudioSection(_ assets: [AudioAsset]) -> [String] {
        let missing = assets.filter { $0.status != .exported }
        var out = ["", "## Missing Audio", "", "Only Logic AUDIO tracks that are audio export assets are checked here. Aux, Bus, Master, Output and other channel-only objects are not audio assets and are never listed as missing."]
        if missing.isEmpty { out += ["", "- None. Every Logic audio track represented in Audio Assets has a real, readable exported WAV."]; return out }
        out += ["", "Audio analysis is incomplete. The following audio tracks have no readable WAV yet:", ""]
        out += missing.map { "- \($0.logicalTrackID) — \($0.trackName.value ?? $0.audioID) (\($0.status.rawValue))" }
        return out
    }
    private func externalAIInstructions(_ delivery: PackageDelivery) -> [String] {
        let inputs = delivery == .fullPackage
            ? ["You are the decision-maker for this mixing analysis. Work from four inputs: (1) the Logic facts in this document, (2) the measured audio metrics under each audio asset, (3) the real WAV files in `audio/`, and (4) the provenance mapping above.", "", "First, analyse the audio yourself. From the actual WAV files determine: what is the beat; which tracks are vocals; vocal type; lead / double / backing / adlib / additional layers; instrumental elements; relationships between tracks; recording issues; balance issues; possible masking/conflicts; dynamics; stereo placement; tonal balance; audible noise or artefacts; performance characteristics."]
            : ["You are the decision-maker for this mixing analysis. Work from three inputs: (1) the Logic facts in this document, (2) the measured audio metrics under each audio asset, and (3) the provenance mapping above. You did not receive the audio, so listening is not part of this pass — do not simulate it.", "", "Start from what the measurements settle objectively: relative loudness and level balance between tracks (integrated LUFS, RMS, true peak), dynamics and density (crest factor, silence map and its ranges), tonal balance and likely masking between tracks that share the same bands (spectral shares, centroid), stereo image (correlation, mid/side ratio), and technical faults (clipping counts, DC offset, inter-sample peaks above 0 dBTP). Then state plainly which questions only hearing can answer — vocal type, performance quality, timbre, musical role, intelligibility — and put them into the QUESTIONS section instead of guessing."]
        let metrics = "Measured audio metrics: every exported audio asset carries an \u{201C}Audio metrics\u{201D} subsection with objective numbers this application computed locally from that exact WAV file (ITU-R BS.1770-4 integrated loudness and true peak, sample peak, RMS, crest factor, spectral band energy shares, spectral centroid, stereo correlation, mid/side energy ratio, silence map, DC offset, clipping counts). They are measured facts about the audio files, not musical judgements, and they are the primary quantitative evidence for level balance, dynamics, tonal balance and the stereo image — especially where hearing is unreliable (differences of a couple of dB, masking, resonances)." + (delivery == .fullPackage ? " If your listening impression conflicts with these numbers, report the conflict explicitly instead of silently trusting either side." : "")
        return ["", "## External AI Instructions", ""] + inputs + ["", metrics, "", "Rules for interpretation:", "- Do not draw conclusions from a track name alone. The name is context; the primary evidence of a musical role is the audio evidence plus Logic metadata.", "- If they conflict, state it explicitly: \"Track name suggests X, but the audio evidence suggests Y.\"", "- Several Logic tracks may form one musical element (e.g. layered leads); or same-named tracks may be different parts. Decide from the evidence, not the names.", "", "Plugins:", "- `Available Plugins` = the catalogue of tools actually installed on this Mac. When you propose a NEW plug-in, choose ONLY from this list. If the tool you want is not there, tell the user and suggest an available alternative — never invent a plug-in.", "- The current Logic plug-in chains are NOT provided and are NOT analysed. The user deliberately prepares a clean source project and manually removes any existing plug-in processing chain before analysis, so the project's current inserts are not part of the source data. Do not ask about or assume any existing plug-in state — build your proposals from the audio evidence and the Available Plugins catalogue.", "", "Workflow (human-in-the-loop — do NOT jump straight to a mix plan):", "1. ANALYSIS — report what the evidence shows.", "2. INTERPRETATION — how you read the project structure.", "3. ISSUES — problems found.", "4. QUESTIONS — what you need the user to confirm.", "5. USER CONFIRMATION — wait for the user.", "6. MIX PLAN — only after confirmation.", "", "Respond in Markdown a human will read. Stages 1–4 are for the user: report the analysis, your interpretation (roles, groupings, confidence — a separate layer that never overwrites the Logic facts above), the issues you found, and the questions the user must answer. Nothing in these stages is parsed by software, so no JSON envelope — structure them as the four sections ANALYSIS / INTERPRETATION / ISSUES / QUESTIONS. The Mix Plan (stage 6, only after the user confirms) is different: the user pastes it into the application's Review screen, which validates it mechanically, so deliver it as exactly one JSON code block conforming to the Mix Plan schema below — no prose inside the block, no extra keys."]
    }
    /// Emits normalized logical tracks (one entity per Logic object) plus an explicit unresolved/unlinked group, so the LLM never sees the header/channel duplicates.
    private func trackLinkingSection(_ snapshot: NormalizedSnapshot) -> [String] {
        let link = snapshot.linking
        var out: [String] = ["## Track linking diagnostics", "", "- Track-header candidates (raw): \(link.trackHeaderCandidates)", "- Channel-strip candidates (raw): \(link.channelCandidates)", "- Confirmed links (header + channel merged): \(link.confirmedLinks)", "- Unresolved header-only tracks: \(link.unresolvedHeaders)", "- Unresolved channel-only strips: \(link.unresolvedChannels)", "- Ambiguous (shared name, not merged): \(link.ambiguous)", "- Logical tracks (final): \(link.logicalTracks)", "", fact("Track discovery", snapshot.tracksStatus), "", "A logical track is one Logic object. `header` facts come from the arrange Tracks area; `channel` facts from the Mixer strip. Match status: `confirmed` (unique 1:1 name link), `unresolved` (only one view exists), `ambiguous` (name shared, not merged).", "", "## Logical tracks", ""]
        if snapshot.tracks.isEmpty { out += ["- No logical tracks are reliably available in the current normalized snapshot (`requires_probe`)."] }
        for track in snapshot.tracks {
            out += ["", "### Logical track `\(track.logicalTrackID)` — match: \(track.matchStatus.rawValue)", "- Logic Track Name: \(render(track.name))", fact("Type", track.type), "- AX header path: \(track.axPaths.header ?? "none") • AX channel path: \(track.axPaths.channel ?? "none")"]
            out += track.linkEvidence.map { "- Link evidence: \($0)" }
            if let header = track.header {
                out += ["", "#### Header facts (Tracks area)"] + compact([entry("Track number", header.ordinal)] + flagEntries([("Mute", header.mute), ("Solo", header.solo), ("Record", header.record), ("Monitoring", header.monitoring), ("Selected", header.selected)]) + [entry("Volume (raw fader units)", header.volumeRaw)])
            } else { out += ["", "#### Header facts (Tracks area)", "- unavailable: no Tracks-area header linked to this object"] }
            if let channel = track.channel {
                out += ["", "#### Channel facts (Mixer strip)"] + compact([entry("Volume", channel.volumeDB, unit: " dB"), entry("Pan", channel.pan)] + flagEntries([("Mute", channel.mute), ("Solo", channel.solo), ("Record", channel.record), ("Monitoring", channel.monitoring), ("EQ enabled", channel.eqEnabled)]) + [entry("Automation", channel.automation), entry("Channel mode", channel.channelMode), entry("Group", channel.group), entry("Input gain", channel.inputGain)])
                out += ["", "##### Routing"] + compact([entry("Input", channel.input), entry("Output", channel.output)]) + ["", "##### Sends"]
                out += channel.sends.isEmpty ? ["- unavailable: no send facts captured"] : channel.sends.flatMap { ["- Send `\($0.id)`", "  - Destination: \(render($0.destination))", "  - Level: \(render($0.levelDB, unit: " dB"))", "  - Pan: \(render($0.pan))"] }
                out += ["", "##### Plugins"]
                out += channel.plugins.isEmpty ? ["- unavailable: no plug-in facts captured"] : channel.plugins.flatMap { plugin in
                    var lines = ["- Slot \(plugin.slot), ID `\(plugin.id)`", "  - Name: \(render(plugin.name))", "  - Manufacturer: \(render(plugin.manufacturer))", "  - Bypass: \(render(plugin.bypass))", "  - Parameters:"]
                    lines += plugin.parameters.isEmpty ? ["    - unavailable: no parameter facts captured"] : plugin.parameters.map { parameter in "    - `\(parameter.id)` / \(parameter.name): \(render(parameter.value, unit: parameter.unit.map { " \($0)" } ?? "")); range: \(parameter.range.map { "\(decimalString($0.lowerBound))...\(decimalString($0.upperBound))" } ?? "unavailable")" }
                    return lines
                }
            } else { out += ["", "#### Channel facts (Mixer strip)", "- unavailable: no Mixer channel strip linked to this object"] }
        }
        let unresolved = snapshot.tracks.filter { $0.matchStatus != .confirmed }
        out += ["", "## Unresolved / unlinked objects", ""]
        out += unresolved.isEmpty ? ["- None. Every logical track has a confirmed header↔channel link."] : unresolved.map { "- `\($0.logicalTrackID)` (\($0.name.value ?? "unnamed")) — \($0.matchStatus.rawValue): \(($0.axPaths.header == nil ? "channel-only" : "header-only"))" }
        return out
    }
    /// Exact provenance mapping audioID → logicalTrackID → Logic track/regions. The program does not interpret the audio; roles (lead/double/backing/beat/…) are for the LLM and user to decide by listening.
    private func audioAssetsSection(_ assets: [AudioAsset], delivery: PackageDelivery) -> [String] {
        var out: [String] = ["", "## Audio Assets", "", "Export unit is one WAV per Logic AUDIO track (Aux, Bus, Master, Output and other channel-only objects are not audio assets and have no WAV). The exported WAV represents the whole track on the project timeline (positions and gaps preserved), and every region of that track lives inside it — regions are named here as provenance only and are never separate files. Each exported asset carries DSP metrics measured locally from that exact file. This section carries no musical interpretation.", "", "Logic exposes region positions only as zoom-relative pixel coordinates, never as time, so they are not published as timing" + (delivery == .fullPackage ? " (the raw pixel values stay in `audio_manifest.json`)" : "") + ": they cannot be converted to seconds and would invite false conclusions. The silence map in each asset's metrics is the real timing evidence, measured from the WAV itself."]
        if assets.isEmpty { out += ["", "- No audio assets prepared. Run Prepare Audio Export after a read-only analysis."]; return out }
        let regionTotal = assets.reduce(0) { $0 + $1.regions.count }
        out += ["", "- Logic audio tracks: \(assets.count) • Audio regions: \(regionTotal) • Assets (WAV targets): \(assets.count)", "- Exported: \(assets.filter { $0.status == .exported }.count) • Requires user export: \(assets.filter { $0.status == .requiresUserExport }.count) • Failed: \(assets.filter { $0.status == .failed }.count)"]
        for asset in assets {
            out += ["", "### Audio Asset \(asset.audioID)", "- logicalTrackID: known: \(asset.logicalTrackID)", "- Logic Track Name: \(render(asset.trackName))", "- WAV file: \(render(asset.actualExportedPath))", "- Expected export path: known: \(asset.expectedExportPath)", "- Status: known: \(asset.status.rawValue)"]
            if let reason = asset.statusReason { out += ["- Status note: \(reason)"] }
            out += ["- Duration: \(render(asset.durationSeconds, unit: " s"))", "- Sample rate: \(render(asset.sampleRate, unit: " Hz"))", "- Channels: \(render(asset.channels))", "- Bit depth: \(render(asset.bitDepth))", "- Format: \(render(asset.format))"]
            out += metricsLines(asset)
            out += ["- Regions (\(asset.regionCount)): " + (asset.regions.isEmpty ? "unavailable: no regions captured" : asset.regions.map { "`\($0.regionID)` \u{201C}\($0.name.value ?? "unnamed")\u{201D}" }.joined(separator: ", "))]
        }
        return out
    }
    /// Locally computed DSP measurements of one exported WAV — facts about that file (BS.1770-4 loudness and true peak,
    /// levels, spectrum, stereo, silence map, technical flags), never musical judgements. Values are rounded for reading
    /// (LUFS/dB to 0.1, percent to 1, centroid to 1 Hz); the JSON manifests keep full precision. States render honestly:
    /// an `unavailable` metric (e.g. stereo correlation of a mono file, dB level of digital silence) stays visible as such.
    private func metricsLines(_ asset: AudioAsset) -> [String] {
        guard let m = asset.metrics else { return [] }
        var out = ["- Audio metrics (computed locally, facts):", metric("Integrated loudness (BS.1770-4)", m.integratedLoudnessLUFS, digits: 1, unit: " LUFS"), metric("True peak (BS.1770-4, 4× oversampled)", m.truePeakDBTP, digits: 1, unit: " dBTP"), metric("Sample peak", m.samplePeakDBFS, digits: 1, unit: " dBFS"), metric("RMS", m.rmsDBFS, digits: 1, unit: " dBFS"), metric("Crest factor", m.crestFactorDB, digits: 1, unit: " dB")]
        if let bands = m.spectralBands.value {
            out += ["  - Spectral energy share: known: sub 20–60 Hz \(percent(bands.subPercent)) · bass 60–250 Hz \(percent(bands.bassPercent)) · low-mid 250–500 Hz \(percent(bands.lowMidPercent)) · mid 500–2000 Hz \(percent(bands.midPercent)) · high-mid 2000–6000 Hz \(percent(bands.highMidPercent)) · high 6000–20000 Hz \(percent(bands.highPercent))"]
        } else { out += ["  - Spectral energy share: \(m.spectralBands.state.rawValue)"] }
        out += [metric("Spectral centroid", m.spectralCentroidHz, digits: 0, unit: " Hz"), metric("Stereo correlation L/R", m.stereoCorrelation, digits: 2, unit: ""), metric("Mid/side energy ratio", m.midSideRatioDB, digits: 1, unit: " dB")]
        if let intervals = m.silenceIntervals.value {
            let share = m.silencePercent.value.map(percent) ?? m.silencePercent.state.rawValue
            out += ["  - Silence map (100 ms windows, RMS < −60 dBFS): known: \(share) silent" + (intervals.isEmpty ? "" : "; ranges: " + intervals.map { String(format: "%.1f–%.1f s", $0.start, $0.end) }.joined(separator: ", "))]
        } else { out += ["  - Silence map: \(m.silenceIntervals.state.rawValue)"] }
        out += [metric("DC offset (mean of channel means)", m.dcOffsetMean, digits: 6, unit: ""), m.clippedSampleCount.value.map { "  - Clipped samples (|x| ≥ 1 − 1e-4, runs ≥ 3): known: \($0)" } ?? "  - Clipped samples: \(m.clippedSampleCount.state.rawValue)"]
        return out
    }
    private func metric(_ label: String, _ value: Fact<Double>, digits: Int, unit: String) -> String { guard let number = value.value else { return "  - \(label): \(value.state.rawValue)" }; return "  - \(label): known: \(rounded(number, digits: digits))\(unit)" }
    /// A value that rounds to zero prints as zero: "-0.0 dBTP" reads like a measurement error rather than a peak just under full scale.
    private func rounded(_ number: Double, digits: Int) -> String { let text = String(format: "%.\(digits)f", number); return text.allSatisfy { $0 == "-" || $0 == "0" || $0 == "." } ? String(format: "%.\(digits)f", 0.0) : text }
    /// Shares below 10 % keep a decimal: a band or a silence share that really is 0.4 % must not read as a flat "0%" while its
    /// silence ranges are listed right next to it.
    private func percent(_ value: Double) -> String { rounded(value, digits: value < 9.95 ? 1 : 0) + "%" }
    /// Two distinct facts: the catalogue of tools installed on this Mac (what COULD be used) and the plugins actually on tracks in the current project (real state). Neither is tied to a musical role.
    private func pluginSections(_ available: [PluginInventoryItem]) -> [String] {
        var out: [String] = ["", "## Available Plugins", "", "Audio processing tools actually installed and registered on this Mac (Audio Units, read-only inventory — no parameters, presets, or state). When proposing a future MixPlan you may suggest ONLY plugins from this list; do not assume a plugin exists because it is popular."]
        if available.isEmpty { out += ["", "- No Audio Units were discovered (inventory not run or none available)."] }
        else {
            let manufacturers = Set(available.map { $0.manufacturer }).count
            out += ["", "- Total: \(available.count) plugins across \(manufacturers) manufacturers."]
            for (manufacturer, plugins) in PluginInventory().groupedByManufacturer(available) {
                out += ["", "### \(manufacturer)"]
                out += plugins.map { "- \($0.name) (\($0.type))" }
            }
        }
        return out
    }
    private func fact<T>(_ label: String, _ fact: Fact<T>, unit: String = "") -> String { "- \(label): \(render(fact, unit: unit))" }
    private func render<T>(_ fact: Fact<T>, unit: String = "") -> String { guard let value = fact.value else { return "\(fact.state.rawValue)" }; return "known: \(display(value))\(unit)" }
    /// Numbers stay facts but render human-readable: a raw Double description leaks binary noise ("135.85066666666665 s"), so doubles show at most two decimals with trailing zeros dropped.
    private func display<T>(_ value: T) -> String { (value as? Double).map(decimalString) ?? String(describing: value) }
    private func decimalString(_ number: Double) -> String { var text = String(format: "%.2f", number); while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() }; return text == "-0" ? "0" : text }
    /// Always-`unavailable` fields used to repeat one boilerplate bullet per track; they compress into a single "Unavailable: …" line. `known`, `unknown` and `requires_probe` facts keep their own lines — any state other than pure absence is informative.
    private func entry<T>(_ label: String, _ value: Fact<T>, unit: String = "") -> (label: String, line: String?) { (label, value.state == .unavailable ? nil : fact(label, value, unit: unit)) }
    private func compact(_ entries: [(label: String, line: String?)]) -> [String] {
        let unavailable = entries.filter { $0.line == nil }.map(\.label)
        return entries.compactMap(\.line) + (unavailable.isEmpty ? [] : ["- Unavailable: \(unavailable.joined(separator: ", "))"])
    }
    /// Known boolean flags merge into one `Flags:` line per facts block: fourteen tracks of separate `Mute: known: false`
    /// bullets carry no more information than one line each. Any other state stays a separate honest line (or joins "Unavailable").
    private func flagEntries(_ pairs: [(String, Fact<Bool>)]) -> [(label: String, line: String?)] {
        let known = pairs.compactMap { pair in pair.1.state == .known ? pair.1.value.map { "\(pair.0) \($0)" } : nil }
        let merged: [(label: String, line: String?)] = known.isEmpty ? [] : [("Flags", "- Flags: known: \(known.joined(separator: " · "))")]
        return merged + pairs.filter { $0.1.state != .known }.map { entry($0.0, $0.1) }
    }
    /// The exact JSON contract the app's Review screen decodes and validates (`MixPlan` / `MixCommand`). The document must
    /// spell it out, or the model invents its own shape and the user's paste fails with "Invalid MixPlan JSON".
    private func mixPlanSchemaSection() -> [String] {
        ["", "## Mix Plan schema (machine-validated)", "", "The application validates the pasted Mix Plan technically against the current snapshot — targets must exist in the facts above, values must sit inside reported ranges. It never judges musical merit, and nothing is written to Logic Pro.", "", "- Every field shown in the example is required on every action; `parameters` may be `{}` only when the action truly takes none.", "- `action` must be one of: `set_volume`, `set_pan`, `set_mute`, `set_solo`, `set_plugin_bypass`, `set_plugin_parameter`. No other action is implemented; anything else is rejected as unsupported.", "- Target a track with `target.trackID` = the `logicalTrackID` used throughout this document, or `target.trackName` = the exact Logic track name.", "- `set_plugin_bypass` and `set_plugin_parameter` additionally need `target.pluginID` or `target.pluginName`, and `set_plugin_parameter` needs `target.parameterID` or `target.parameterName` plus a numeric `parameters.value`. When no plug-in facts were captured for the track, these validate as `requires_probe`, not as executable actions.", "", "```json", Self.mixPlanExampleJSON, "```"]
    }
    static let mixPlanExampleJSON = """
{
  "version": "1.0",
  "status": "ready_for_mixplan",
  "actions": [
    {
      "id": "action_001",
      "target": { "trackID": "track_2" },
      "action": "set_volume",
      "parameters": { "value": -3.0 },
      "reason": "One factual sentence tying the change to the evidence above"
    },
    {
      "id": "action_002",
      "target": { "trackID": "track_2" },
      "action": "set_pan",
      "parameters": { "value": -20 },
      "reason": "One factual sentence tying the change to the evidence above"
    }
  ]
}
"""
}
