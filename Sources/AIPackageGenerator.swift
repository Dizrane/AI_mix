import Foundation
import AppKit

/// Provider-neutral export of normalized, evidence-based DAW facts for any external LLM.
struct AIPackageGenerator: Sendable {
    static let schemaVersion = "2.0"
    func make(snapshot: NormalizedSnapshot, sessionID: String, audio: [AudioAsset] = [], plugins: [PluginInventoryItem] = [], probes: [ProbeType] = ProbeType.allCases) -> String {
        let readiness = PackageReadiness.evaluate(snapshot: snapshot, assets: audio)
        var out: [String] = []
        out += ["# AI Mix Analysis", "", "## Package", "", "- Package schema: `\(Self.schemaVersion)`", "- Analysis ID: `\(sessionID)`", "- Generated: `\(ISO8601DateFormatter().string(from: Date()))`", "- Project: \(render(snapshot.project.name))", "- Logical tracks: \(snapshot.tracks.count)", "- Audio assets: \(audio.count)", "- Exported: \(readiness.audioExported)", "- Requires export: \(audio.count - readiness.audioExported)", "- Package readiness: `\(readiness.overall.rawValue)`"]
        out += purposeAndRules()
        out += ["", "## Project metadata", "", fact("Project name", snapshot.project.name), fact("Tempo", snapshot.project.tempo, unit: " BPM"), fact("Time signature", snapshot.project.timeSignature), fact("Key signature", snapshot.project.keySignature), fact("Sample rate", snapshot.project.sampleRate, unit: " Hz"), fact("Transport", snapshot.project.transportState), fact("Snapshot completeness", snapshot.completeness)]
        out += readinessSection(readiness)
        out += trackLinkingSection(snapshot)
        out += audioAssetsSection(audio)
        out += provenanceSection(audio)
        out += missingAudioSection(audio)
        out += pluginSections(snapshot, plugins)
        out += ["", "## Audio / meter data", "", fact("Peak", snapshot.audio.peak), fact("RMS", snapshot.audio.rms), fact("LUFS", snapshot.audio.lufs), fact("Gain reduction", snapshot.audio.gainReduction), fact("Input level", snapshot.audio.inputLevel), fact("Output level", snapshot.audio.outputLevel), "", "## Unknown and unavailable data", "", "Every fact carries a state. `unknown` — the analyzer could not determine a value; `unavailable` — no supported evidence was exposed; `requires_probe` — a targeted read-only probe is needed. No missing field implies a musical assumption.", "", "### Current limitations", ""]
        out += snapshot.limitations.map { "- \($0)" }
        out += externalAIInstructions()
        out += ["", "## Response schema (analysis, v2.0)", "", "```json", responseSchemaV2, "```"]
        return out.joined(separator: "\n") + "\n"
    }
    private func purposeAndRules() -> [String] {
        ["", "## Purpose", "", "This package contains factual information extracted read-only from Logic Pro plus the paths of the corresponding exported audio tracks. The external AI must listen to the provided WAV files and combine audio evidence with these Logic facts. This application performs no musical interpretation of its own.", "", "## Critical Rules", "", "- Use actual Logic Track names as factual identifiers only.", "- Do not assume a musical role from a track name.", "- Do not assume that one Logic Track equals one musical role.", "- Multiple Logic Tracks may belong to the same musical element.", "- One Logic Track corresponds to one full-track WAV.", "- Regions are provenance only and are never separate audio assets.", "- Do not invent unavailable Logic data.", "- Audio interpretation must be based on the actual WAV.", "- If audio and Logic metadata conflict, explicitly report the conflict.", "- Do not propose destructive changes without user confirmation."]
    }
    private func readinessSection(_ r: PackageReadiness) -> [String] {
        func flag(_ ok: Bool) -> String { ok ? "READY" : "INCOMPLETE" }
        var out = ["", "## Package readiness", "", "- Logic analysis: \(flag(r.logicAnalysis))", "- Track discovery: \(flag(r.trackDiscovery))", "- Audio assets: \(r.audioTotal == 0 ? "INCOMPLETE (none prepared)" : "\(r.audioExported)/\(r.audioTotal) exported")", "- Provenance: \(flag(r.provenanceOK))", "- AI Package: \(r.overall.rawValue.uppercased())"]
        if r.audioTotal > 0 && r.audioExported < r.audioTotal { out += ["", "Audio analysis incomplete — \(r.audioTotal - r.audioExported) WAV file(s) missing. Export the missing tracks and Refresh Export Status for a complete analysis."] }
        if !r.errors.isEmpty { out += ["", "Integrity errors (do not rely on this package until fixed):"] + r.errors.map { "- \($0)" } }
        return out
    }
    private func provenanceSection(_ assets: [AudioAsset]) -> [String] {
        var out = ["", "## Audio ↔ Logic provenance", "", "Each WAV maps unambiguously to one logical track (via logicalTrackID) and its exact Logic name. Regions are context only, never separate files."]
        if assets.isEmpty { out += ["", "- No audio assets prepared."]; return out }
        for asset in assets {
            let wav = asset.actualExportedPath.value ?? "\(asset.expectedExportPath) (expected — not yet exported)"
            out += ["", "- \(wav)", "  - logicalTrackID: \(asset.logicalTrackID)", "  - Logic Track Name: \(asset.trackName.value ?? "unknown")", "  - Regions (\(asset.regionCount)): \(asset.regionIDs.isEmpty ? "none" : asset.regionIDs.joined(separator: ", "))"]
        }
        return out
    }
    private func missingAudioSection(_ assets: [AudioAsset]) -> [String] {
        let missing = assets.filter { $0.status != .exported }
        var out = ["", "## Missing Audio", ""]
        if missing.isEmpty { out += ["- None. Every logical track has a real, readable exported WAV."]; return out }
        out += ["Audio analysis is incomplete. The following tracks have no readable WAV yet:", ""]
        out += missing.map { "- \($0.logicalTrackID) — \($0.trackName.value ?? $0.audioID) (\($0.status.rawValue))" }
        return out
    }
    private func externalAIInstructions() -> [String] {
        ["", "## External AI Instructions", "", "You are the decision-maker for this mixing analysis. Work from three inputs: (1) the Logic facts in this document, (2) the real WAV files in `audio/`, and (3) the provenance mapping above.", "", "First, analyse the audio yourself. From the actual WAV files determine: what is the beat; which tracks are vocals; vocal type; lead / double / backing / adlib / additional layers; instrumental elements; relationships between tracks; recording issues; balance issues; possible masking/conflicts; dynamics; stereo placement; tonal balance; audible noise or artefacts; performance characteristics.", "", "Rules for interpretation:", "- Do not draw conclusions from a track name alone. The name is context; the primary evidence of a musical role is the actual WAV plus Logic metadata.", "- If they conflict, state it explicitly: \"Track name suggests X, but audio evidence suggests Y.\"", "- Several Logic tracks may form one musical element (e.g. layered leads); or same-named tracks may be different parts. Decide from the audio, not the names.", "", "Workflow (human-in-the-loop — do NOT jump straight to a mix plan):", "1. ANALYSIS — report what you heard.", "2. INTERPRETATION — how you read the project structure.", "3. ISSUES — problems found.", "4. QUESTIONS — what you need the user to confirm.", "5. USER CONFIRMATION — wait for the user.", "6. MIX PLAN — only after confirmation.", "", "Return your first response as JSON conforming to the analysis schema below. Your interpretation (roles, groupings, confidence) is a separate layer and must never overwrite the Logic facts above. When status becomes `ready_for_mixplan` after user confirmation, provide `mix_plan` actions targeting `target.trackID = logicalTrackID` (set_volume / set_pan / set_mute / set_solo / set_plugin_bypass / set_plugin_parameter)."]
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
                out += ["", "#### Header facts (Tracks area)", fact("Track number", header.ordinal), fact("Mute", header.mute), fact("Solo", header.solo), fact("Record", header.record), fact("Monitoring", header.monitoring), fact("Volume (raw fader units)", header.volumeRaw), fact("Selected", header.selected)]
            } else { out += ["", "#### Header facts (Tracks area)", "- unavailable: no Tracks-area header linked to this object"] }
            if let channel = track.channel {
                out += ["", "#### Channel facts (Mixer strip)", fact("Volume", channel.volumeDB, unit: " dB"), fact("Pan", channel.pan), fact("Mute", channel.mute), fact("Solo", channel.solo), fact("Record", channel.record), fact("Monitoring", channel.monitoring), fact("Automation", channel.automation), fact("Channel mode", channel.channelMode), fact("EQ enabled", channel.eqEnabled), fact("Group", channel.group), fact("Input gain", channel.inputGain), "", "##### Routing", fact("Input", channel.input), fact("Output", channel.output), "", "##### Sends"]
                out += channel.sends.isEmpty ? ["- unavailable: no send facts captured"] : channel.sends.flatMap { ["- Send `\($0.id)`", "  - Destination: \(render($0.destination))", "  - Level: \(render($0.levelDB, unit: " dB"))", "  - Pan: \(render($0.pan))"] }
                out += ["", "##### Plugins"]
                out += channel.plugins.isEmpty ? ["- unavailable: no plug-in facts captured"] : channel.plugins.flatMap { plugin in
                    var lines = ["- Slot \(plugin.slot), ID `\(plugin.id)`", "  - Name: \(render(plugin.name))", "  - Manufacturer: \(render(plugin.manufacturer))", "  - Bypass: \(render(plugin.bypass))", "  - Parameters:"]
                    lines += plugin.parameters.isEmpty ? ["    - unavailable: no parameter facts captured"] : plugin.parameters.map { parameter in "    - `\(parameter.id)` / \(parameter.name): \(render(parameter.value, unit: parameter.unit.map { " \($0)" } ?? "")); range: \(parameter.range.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unavailable")" }
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
    private func audioAssetsSection(_ assets: [AudioAsset]) -> [String] {
        var out: [String] = ["", "## Audio Assets", "", "Export unit is one WAV per Logic track. Regions are listed only as provenance and are never split into separate files. The exported WAV represents the whole track on the project timeline (positions and gaps preserved). This section carries no musical interpretation."]
        if assets.isEmpty { out += ["", "- No audio assets prepared. Run Prepare Audio Export after a read-only analysis."]; return out }
        let regionTotal = assets.reduce(0) { $0 + $1.regions.count }
        out += ["", "- Logic audio tracks: \(assets.count) • Audio regions: \(regionTotal) • Assets (WAV targets): \(assets.count)", "- Exported: \(assets.filter { $0.status == .exported }.count) • Requires user export: \(assets.filter { $0.status == .requiresUserExport }.count) • Failed: \(assets.filter { $0.status == .failed }.count)"]
        for asset in assets {
            out += ["", "### Audio Asset \(asset.audioID)", "- logicalTrackID: known: \(asset.logicalTrackID)", "- Logic Track Name: \(render(asset.trackName))", "- WAV file: \(render(asset.actualExportedPath))", "- Expected export path: known: \(asset.expectedExportPath)", "- Status: known: \(asset.status.rawValue)"]
            if let reason = asset.statusReason { out += ["- Status note: \(reason)"] }
            out += ["- Duration: \(render(asset.durationSeconds, unit: " s"))", "- Sample rate: \(render(asset.sampleRate, unit: " Hz"))", "- Channels: \(render(asset.channels))", "- Bit depth: \(render(asset.bitDepth))", "- Format: \(render(asset.format))", "- Region count: \(asset.regionCount)", "- Regions:"]
            out += asset.regions.isEmpty ? ["  - unavailable: no regions captured"] : asset.regions.map { region in "  - `\(region.regionID)`: \(render(region.name)) (timeline x: \(render(region.timelinePixelX, unit: " px")), width: \(render(region.timelinePixelWidth, unit: " px")); start/duration in seconds: requires_probe)" }
        }
        return out
    }
    /// Two distinct facts: the catalogue of tools installed on this Mac (what COULD be used) and the plugins actually on tracks in the current project (real state). Neither is tied to a musical role.
    private func pluginSections(_ snapshot: NormalizedSnapshot, _ available: [PluginInventoryItem]) -> [String] {
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
        out += ["", "## Plugins currently present in Logic", "", "Plugins actually discovered on tracks in the CURRENT project (facts from the read-only snapshot). This is separate from the catalogue above and is never linked to a musical role."]
        let tracksWithPlugins = snapshot.tracks.filter { !($0.channel?.plugins.isEmpty ?? true) }
        if tracksWithPlugins.isEmpty { out += ["", "- None discovered in the current snapshot. Plugin slots may be empty, or plugin names require an `inspect_plugin` probe."] }
        else { for track in tracksWithPlugins {
            let names = (track.channel?.plugins ?? []).map { $0.name.value ?? "unknown" }
            out += ["- `\(track.logicalTrackID)` (\(track.name.value ?? "unnamed")): \(names.joined(separator: ", "))"]
        } }
        return out
    }
    private func fact<T>(_ label: String, _ fact: Fact<T>, unit: String = "") -> String { "- \(label): \(render(fact, unit: unit))" }
    private func render<T>(_ fact: Fact<T>, unit: String = "") -> String { guard let value = fact.value else { return "\(fact.state.rawValue)" }; return "known: \(String(describing: value))\(unit)" }
    private var responseSchemaV2: String { """
{
  "version": "2.0",
  "status": "analysis | needs_user_input | ready_for_mixplan",
  "project_understanding": {},
  "track_interpretation": [
    {
      "logicalTrackIDs": ["track_7", "track_8"],
      "interpretedRole": "string, e.g. lead_vocal_group — AI interpretation layer only, never a Logic fact",
      "confidence": 0.0,
      "evidence": ["audio evidence from the WAV", "Logic track names as context"]
    }
  ],
  "audio_findings": [],
  "mixing_issues": [],
  "questions_for_user": [],
  "proposed_changes": [],
  "mix_plan": null
}
""" }
}
