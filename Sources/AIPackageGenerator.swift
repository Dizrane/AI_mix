import Foundation
import AppKit

/// What the reader actually receives. "Copy for AI" hands over this Markdown alone — no JSON, no WAV files — while Save Package
/// ships them next to it. The document states the one mode it was generated for instead of describing every possibility and then
/// telling the reader to open files that are not there.
enum PackageDelivery: Sendable { case markdownOnly, fullPackage }

/// Provider-neutral export of normalized, evidence-based DAW facts for any external LLM.
struct AIPackageGenerator: Sendable {
    static let schemaVersion = "2.25"
    func make(snapshot: NormalizedSnapshot, sessionID: String, audio: [AudioAsset] = [], plugins: [PluginInventoryItem] = [], probes: [ProbeType] = ProbeType.allCases, delivery: PackageDelivery = .fullPackage, exportSettings: ExportSettingsFacts? = nil, mix: MixBounceAsset? = nil) -> String {
        let readiness = PackageReadiness.evaluate(snapshot: snapshot, assets: audio)
        var out: [String] = []
        out += ["# AI Mix Analysis", ""]
        out += primaryInstruction(delivery)
        out += ["", "## Package", "", "- Package schema: `\(Self.schemaVersion)`", "- Analysis ID: `\(sessionID)`", "- Generated: `\(ISO8601DateFormatter().string(from: Date()))`", "- Project: \(render(snapshot.project.name))", "- Logical tracks: \(snapshot.tracks.count)", "- Audio assets: \(audio.count)", "- Exported: \(readiness.audioExported)", "- Requires export: \(audio.count - readiness.audioExported)"]
        out += purposeAndRules(delivery)
        out += ["", "## Project metadata", "", fact("Project name", snapshot.project.name), fact("Tempo", snapshot.project.tempo, unit: " BPM"), fact("Time signature", snapshot.project.timeSignature), fact("Key signature", snapshot.project.keySignature), fact("Sample rate", snapshot.project.sampleRate, unit: " Hz"), fact("Transport", snapshot.project.transportState), fact("Snapshot completeness", snapshot.completeness)]
        out += readinessSection(readiness)
        out += trackLinkingSection(snapshot)
        out += signalFlowSection(snapshot)
        out += audioAssetsSection(audio, delivery: delivery, exportSettings: exportSettings, mix: mix)
        out += mixSection(mix, delivery: delivery, assets: audio)
        out += provenanceSection(audio)
        out += missingAudioSection(audio)
        out += pluginSections(plugins)
        out += ["", "## Logic on-screen meters (AX)", "", "Live meter values Logic exposes on screen, not measurements of the audio files: Logic publishes no numeric meter readings over Accessibility, so these stay `unavailable`. Loudness, peak, RMS and the rest of the measured numbers are per exported file under Audio Assets → Audio metrics.", "", fact("Peak", snapshot.audio.peak), fact("RMS", snapshot.audio.rms), fact("LUFS", snapshot.audio.lufs), fact("Gain reduction", snapshot.audio.gainReduction), fact("Input level", snapshot.audio.inputLevel), fact("Output level", snapshot.audio.outputLevel), "", "## Unknown and unavailable data", "", "Every fact carries a state. `unknown` — the analyzer could not determine a value; `unavailable` — no supported evidence was exposed; `requires_probe` — a targeted read-only probe is needed. No missing field implies a musical assumption.", "", "### Current limitations", ""]
        out += snapshot.limitations.map { "- \($0)" }
        out += externalAIInstructions(delivery)
        out += currentControlValuesSection(snapshot)
        out += mixPlanSchemaSection(snapshot)
        return out.joined(separator: "\n") + "\n"
    }
    /// The delivery mode is a fact the app knows, so the document asserts it. Everything after it — which files to open, whether
    /// listening is possible at all, what counts as evidence — follows from that one statement instead of a menu of possibilities.
    private func primaryInstruction(_ delivery: PackageDelivery) -> [String] {
        let opening: [String]
        switch delivery {
        case .fullPackage:
            opening = ["When this package (or its ZIP) is provided to an AI system, THIS document is the authoritative task specification for the package. The AI must NOT require a separate user prompt to begin — handing over the whole package is enough. The standard workflow is: the user gives you this package (typically the ZIP) and you start immediately.", "", "DELIVERY: FULL PACKAGE. This document ships together with `logic_snapshot.json`, `audio_manifest.json`, `manifest.json` and the exported WAV files in `audio/`.", "", "MIXED DELIVERY: the user may paste the text-only variant of this document (produced by Copy for AI; its delivery line claims the analysis text was handed over alone) next to this package. When both arrive together, THIS document is the one that matches what you actually received — the audio IS delivered — so this document's rules govern and the other variant's delivery claims are void. The two variants differ only in their delivery preambles; every fact in them is identical.", "", "The AI must:", "1. read this document first;", "2. inspect the package contents — `AI_MIX_ANALYSIS.md`, `logic_snapshot.json`, `audio_manifest.json`, `manifest.json`, and the `audio/` folder;", "3. listen to ALL available WAV audio assets in `audio/`;", "4. use `logic_snapshot.json` and `audio_manifest.json` as factual/project context and provenance;", "5. use only facts marked `known` as factual evidence;", "6. follow the External AI Instructions and the response format defined below;", "7. open the first paragraph of the ANALYSIS section with one explicit line declaring your audio mode — either that you actually listened to the WAV files, or that your platform cannot process audio and you are working from the measured metrics and written facts alone; vague wording like \u{201C}I checked the files\u{201D} is NOT such a declaration;", "8. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "9. not create a final Mix Plan before the required analysis, interpretation, questions and user-confirmation stages are completed.", "", "Everything needed is inside the package — you do not need the user to tell you what to read, where the WAVs are, what this file is, or in what order to work. This document defines that workflow.", "", "If your platform cannot process audio files at all, say so plainly, skip the listening steps, work from the written facts and the measured audio metrics below, and ask the user targeted questions where only listening could decide."]
        case .markdownOnly:
            opening = ["This document is the authoritative task specification for the analysis. The AI must NOT require a separate user prompt to begin — receiving this document is enough: start immediately.", "", "DELIVERY: THIS DOCUMENT ONLY. You received the analysis text alone. `logic_snapshot.json`, `audio_manifest.json`, `manifest.json` and the WAV files in `audio/` are NOT part of this delivery and you cannot open them, so there is nothing to look for and nothing to wait for.", "", "MIXED DELIVERY: if, despite the line above, the package ZIP (or its extracted `audio/` folder and JSON files) actually arrived alongside this text, then the audio WAS delivered: follow the FULL PACKAGE rules in the ZIP's own `AI_MIX_ANALYSIS.md` — they take priority over this document's delivery claims, including the rule below never to state that you listened. The two variants differ only in their delivery preambles; every fact in them is identical.", "", "The AI must:", "1. read this document first;", "2. treat the Logic facts and the locally measured audio metrics in it as the complete evidence base — the metrics under each audio asset were computed by the application from the real WAV files, so quantitative statements about loudness, peaks, dynamics, tonal balance, stereo image and silence are fully supported here;", "3. never state or imply that it listened to the audio: the audio was not delivered, and claiming otherwise is fabrication;", "4. open the first paragraph of the ANALYSIS section with one explicit line stating that the audio was not delivered and you are working from the measured metrics and written facts; vague wording like \u{201C}I checked the files\u{201D} is NOT such a declaration;", "5. use only facts marked `known` as factual evidence;", "6. follow the External AI Instructions and the response format defined below;", "7. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "8. not create a final Mix Plan before the required analysis, interpretation, questions and user-confirmation stages are completed.", "", "Where a conclusion genuinely requires hearing the material (timbre, performance quality, intelligibility, musical role), name the asset and the question and ask the user for the full package — Save Package in the application produces a ZIP with the WAV files. Do not stall the rest of the analysis waiting for it."]
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
        // The declaration the ANALYSIS section must open with names the delivery's real options: with the WAVs both
        // modes exist; Markdown alone leaves only the measurements — offering "listened" there would invite fabrication.
        let declaration = delivery == .fullPackage
            ? "(you listened to the files, or you cannot listen and work from the measurements and facts)"
            : "(the audio was not delivered — you work from the measured metrics and written facts)"
        return ["", "## External AI Instructions", ""] + inputs + ["", metrics, "", "Rules for interpretation:", "- Do not draw conclusions from a track name alone. The name is context; the primary evidence of a musical role is the audio evidence plus Logic metadata.", "- If they conflict, state it explicitly: \"Track name suggests X, but the audio evidence suggests Y.\"", "- Several Logic tracks may form one musical element (e.g. layered leads); or same-named tracks may be different parts. Decide from the evidence, not the names.", "", "Plugins:", "- `Available Plugins` = the catalogue of tools actually installed on this Mac. When you propose a NEW plug-in, choose ONLY from this list. If the tool you want is not there, tell the user and suggest an available alternative — never invent a plug-in.", "- Plug-in recommendations are PROSE for the user, never Mix Plan actions: the machine-validated plan has NO action that adds a plug-in, and `set_plugin_bypass` / `set_plugin_parameter` validate only against plug-in facts captured in this document. Name the plug-in, the track and the intended settings in your text for the user to insert manually (in stage 6 that text belongs in MANUAL STEPS); when no plug-in facts are captured above, the executable plan is limited to volume, pan, mute and solo.", "- The project's CURRENT plug-in chains appear only as captured facts: a strip's loaded insert slots are listed under its Plugins subsection (name always; bypass stays requires_probe — the slot exposes no bypass state; parameters only when an open plug-in window was matched to the slot). A strip showing `Plugins: unavailable` has no captured chain — many users deliberately analyse a clean project — so do not assume any plug-in state beyond what is captured: build your proposals from the captured facts, the audio evidence and the Available Plugins catalogue.", "", "Workflow (human-in-the-loop — do NOT jump straight to a mix plan):", "1. ANALYSIS — report what the evidence shows; its FIRST paragraph opens with the one-line audio-mode declaration required above \(declaration).", "2. INTERPRETATION — how you read the project structure.", "3. ISSUES — problems found.", "4. QUESTIONS — what you need the user to confirm.", "5. USER CONFIRMATION — wait for the user.", "6. MIX PLAN — only after confirmation.", "", "Respond in Markdown a human will read, in the language the user writes to you in (keep the section headings, track identifiers and the JSON exactly as specified, in English — with ONE exception inside the JSON: each action's `reason` is written in the user's language, see the Mix Plan schema below). Stages 1–4 are for the user: report the analysis, your interpretation (roles, groupings, confidence — a separate layer that never overwrites the Logic facts above), the issues you found, and the questions the user must answer. Nothing in these stages is parsed by software, so no JSON envelope — structure them as the four sections ANALYSIS / INTERPRETATION / ISSUES / QUESTIONS. Number the questions and propose a concrete default for each, so the user can confirm everything in one short reply; the user answering the questions (or telling you to proceed) IS the confirmation of stage 5.", "", "Two replies, strictly separated: your FIRST reply delivers stages 1–4 only and contains NO `MIX PLAN` JSON block — a plan in the first reply skips the user's confirmation and violates this workflow, even as a draft. Once the user has confirmed (stage 5), deliver stage 6 alone — `MIX PLAN` + `MANUAL STEPS` — without repeating the analysis; where the user's answers changed something, the plan follows the answers, not your earlier defaults, and an answer that removes the need for an action removes the action.", "", "Stage 6 — the Mix Plan — is the deliverable this package exists for, and its format is fixed. Deliver it as two sections:", "1. `MIX PLAN` — exactly one JSON code block conforming to the Mix Plan schema below: no prose inside the block, no extra keys, only the machine-validated actions.", "2. `MANUAL STEPS` — a numbered list of every recommendation the schema cannot encode: plug-in insertions with their concrete initial settings (chosen from Available Plugins only), send levels, automation moves, re-recording or editing advice. Each step names the exact Logic track (real name + logicalTrackID), states precisely what to do in Logic, and cites the evidence it rests on. When nothing manual is needed, write \u{201C}MANUAL STEPS: none\u{201D}.", "", "How the plan is used — write it accordingly. The user pastes the JSON into the application's Review screen, which validates every action technically against the facts in this document (the target exists, the value is typed and inside its control's range) but executes nothing — the application never modifies Logic. The user then applies the plan by hand in Logic: the JSON actions plus your MANUAL STEPS are their complete working instructions, read top to bottom. So every `parameters.value` must be an absolute target setting (never a relative change), at a precision the user can actually set on Logic's controls (volume to 0.1 dB, pan as an integer); every volume/pan action must also restate the track's current known value in `parameters.current` and the signed move in `parameters.delta` — the application validates the arithmetic, so an action whose stated direction contradicts its value is rejected before the user sees it; and every `reason` must be one self-contained sentence naming the current known value, the absolute target, the direction of the move and the evidence — the user reads it next to each move as its justification.", "", "Plan composition rules:", "- Account for every ISSUE: each problem you reported under ISSUES must be traceable in the final answer — resolved by a Mix Plan action, handled by a MANUAL STEPS item, or explicitly closed by one MANUAL STEPS line saying it is deliberately left as is and why (the user's decision is pending, the needed tool is not installed, the fix needs re-recording). An issue that silently disappears between ISSUES and the plan leaves the instructions incomplete.", "- `set_solo` is a monitoring control for the user's own checking, never a mixing decision: a delivered Mix Plan contains no `set_solo` action unless the user explicitly asked for a track to be soloed. Muting a track (`set_mute`) can be a real mix decision; leaving a track soloed never is.", "- A track whose Volume or Pan fact is not `known` (the Current control values table shows a state instead of a number) cannot get a `set_volume`/`set_pan` action yet: `parameters.current` must never be guessed. Ask in QUESTIONS for the value Logic's channel strip shows for that track; the user's answer then becomes `parameters.current`. Until it is answered, keep the recommendation in MANUAL STEPS, telling the user to read the current value off the strip first."]
    }
    /// Emits normalized logical tracks (one entity per Logic object) plus an explicit unresolved/unlinked group, so the LLM never sees the header/channel duplicates.
    private func trackLinkingSection(_ snapshot: NormalizedSnapshot) -> [String] {
        let link = snapshot.linking
        var out: [String] = ["## Track linking diagnostics", "", "- Track-header candidates (raw): \(link.trackHeaderCandidates)", "- Channel-strip candidates (raw): \(link.channelCandidates)", "- Confirmed links (header + channel merged): \(link.confirmedLinks)", "- Unresolved header-only tracks: \(link.unresolvedHeaders)", "- Unresolved channel-only strips: \(link.unresolvedChannels)", "- Ambiguous (shared name, not merged): \(link.ambiguous)", "- Logical tracks (final): \(link.logicalTracks)", "", fact("Track discovery", snapshot.tracksStatus), "", "A logical track is one Logic object. `header` facts come from the arrange Tracks area; `channel` facts from the Mixer strip. Match status: `confirmed` (unique 1:1 name link), `unresolved` (only one view exists), `ambiguous` (name shared, not merged).", "", "Routing: Logic exposes an EMPTY send slot, the output slot and an aux's input slot as identically shaped buttons that only name a destination (\"Bus 1\", \"St Out\"), so slots are classified purely by documented structure. An OCCUPIED send has its own shape (a destination-captioned group holding a bypass checkbox) and is the only thing published under Sends; the output slot is the destination button directly after the group pop-up; the input slot directly follows the channel-mode button. A destination button matching no rule is listed under \"Routing buttons (slot kind unclassified)\" with `requires_probe` — never read such a button as a send: it may equally be the track's output or an aux's input. Every destination additionally carries its KIND, derived from Logic's own caption grammar: `bus` (\"Bus N\", an internal bus), `stereo_output` (\"St Out\" / \"Stereo Out\"), `hardware_output` (\"Output\" / \"Output N-M\"), `hardware_input` (\"Input N-M\"), `not_connected` (\"No Output\" / \"No Input\") — so an output to the stereo bus and an output into a bus are never conflated.", "", "Per strip below, empty subsections compress to one line each, stated once here instead of on every track: `Sends: none` is a fact, not missing data — an occupied send is structurally unmistakable; `Routing buttons (slot kind unclassified): none` means no destination button was left unclassified; `Plugins: unavailable` means no plug-in facts were captured for that strip.", "", "## Logical tracks", ""]
        if snapshot.tracks.isEmpty { out += ["- No logical tracks are reliably available in the current normalized snapshot (`requires_probe`)."] }
        for track in snapshot.tracks {
            out += ["", "### Logical track `\(track.logicalTrackID)` — match: \(track.matchStatus.rawValue)", "- Logic Track Name: \(render(track.name))", fact("Type", track.type), "- AX header path: \(track.axPaths.header ?? "none") • AX channel path: \(track.axPaths.channel ?? "none")"]
            out += track.linkEvidence.map { "- Link evidence: \($0)" }
            if let header = track.header {
                out += ["", "#### Header facts (Tracks area)"] + compact([entry("Track number", header.ordinal)] + flagEntries([("Mute", header.mute), ("Solo", header.solo), ("Record", header.record), ("Monitoring", header.monitoring), ("Selected", header.selected)]) + [entry("Volume (raw fader units)", header.volumeRaw)])
            } else { out += ["", "#### Header facts (Tracks area)", "- unavailable: no Tracks-area header linked to this object"] }
            if let channel = track.channel {
                out += ["", "#### Channel facts (Mixer strip)"] + compact([entry("Volume", channel.volumeDB, unit: " dB"), entry("Pan", channel.pan)] + flagEntries([("Mute", channel.mute), ("Solo", channel.solo), ("Record", channel.record), ("Monitoring", channel.monitoring), ("EQ enabled", channel.eqEnabled)]) + [entry("Automation", channel.automation), entry("Channel mode", channel.channelMode), entry("Group", channel.group), entry("Input gain", channel.inputGain)])
                out += ["", "##### Routing"] + compact([routingEntry("Input", channel.input), routingEntry("Output", channel.output)])
                out += channel.sends.isEmpty ? ["- Sends: none"] : ["", "##### Sends"] + channel.sends.flatMap { ["- Send `\($0.id)`", "  - Destination: \(render($0.destination))\(kindSuffix($0.destination))", "  - Bypass: \(render($0.bypass))", "  - Level: requires_probe (the send knob exposes only a unitless raw value)", "  - Pan: requires_probe (no send pan control is exposed)"] }
                out += channel.routingButtons.isEmpty ? ["- Routing buttons (slot kind unclassified): none"] : ["", "##### Routing buttons (slot kind unclassified)"] + channel.routingButtons.flatMap { ["- Routing button `\($0.id)`", "  - Destination: \(render($0.destination))\(kindSuffix($0.destination))", "  - Slot kind (send / output / aux input): requires_probe"] }
                out += channel.plugins.isEmpty ? ["- Plugins: unavailable"] : ["", "##### Plugins"] + channel.plugins.flatMap { plugin in
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
    /// The project's bus wiring, DERIVED: every edge is the pure join of two facts already proven in Logical tracks
    /// above — the feeder's known bus output or send destination, and the receiver's known bus input on the same
    /// caption — and cites both sources. Incomplete buses stay incomplete: the one known end is published, never
    /// completed by a guess, so the model can ask for the missing end instead of inventing it.
    private func signalFlowSection(_ snapshot: NormalizedSnapshot) -> [String] {
        let graph = SignalFlowGraph.build(tracks: snapshot.tracks)
        let names = Dictionary(snapshot.tracks.map { ($0.logicalTrackID, $0.name.value ?? $0.logicalTrackID) }, uniquingKeysWith: { first, _ in first })
        func label(_ id: String) -> String { "`\(id)` \u{201C}\(names[id] ?? id)\u{201D}" }
        var out = ["", "## Signal flow (derived)", "", "Bus edges derived by this application from the routing facts above — no new Logic data and no interpretation. An edge exists only where two `known` facts name the same internal bus (captions compared case-insensitively): the feeder's output slot or occupied send, and the receiver's input slot; each edge cites both facts' sources. A bus fans out legitimately, so one bus feeding several inputs yields one edge per receiver. Nothing is derived from `requires_probe` routing buttons, and an output to the stereo output is a terminal, not an edge. Each edge cites the AX paths of its two facts; the structural rules those slots were classified by are stated once, in the Routing paragraph under Track linking diagnostics."]
        if let terminal = graph.terminal { out += ["", "- Terminal node: \(label(terminal.trackID)) — the project's stereo output."] }
        out += ["", "### Bus edges", ""]
        if graph.edges.isEmpty { out += ["- none: no bus has both a proven feeder and a proven receiver in this snapshot."] }
        else {
            // The source strings carry "<AX path>: <classification rule>"; the rule is already stated once in the legend,
            // so each edge cites only the path — repeating the same sentence per edge is noise, not extra evidence.
            func shortSource(_ source: String?) -> String { source.map { $0.components(separatedBy: ": ").first ?? $0 } ?? "unknown source" }
            out += graph.edges.flatMap { edge in ["- \(label(edge.from)) → (\(edge.kind.rawValue), \(edge.viaBus)) → \(label(edge.to))", "  - Derived from: \(edge.kind.rawValue) fact at \(shortSource(edge.fromSource)) + input fact at \(shortSource(edge.toSource))"] }
        }
        out += ["", "### Unresolved buses (one known end only — published, never guessed)", ""]
        out += graph.unresolvedBuses.isEmpty ? ["- none: every proven bus fact has both ends in this snapshot."] : graph.unresolvedBuses.map { "- \($0)" }
        return out
    }
    /// Exact provenance mapping audioID → logicalTrackID → Logic track/regions. The program does not interpret the audio; roles (lead/double/backing/beat/…) are for the LLM and user to decide by listening.
    private func audioAssetsSection(_ assets: [AudioAsset], delivery: PackageDelivery, exportSettings: ExportSettingsFacts?, mix: MixBounceAsset?) -> [String] {
        var out: [String] = ["", "## Audio Assets", "", "Export unit is one WAV per Logic AUDIO track (Aux, Bus, Master, Output and other channel-only objects are not audio assets and have no WAV). The exported WAV represents the whole track on the project timeline (positions and gaps preserved), and every region of that track lives inside it — regions are named here as provenance only and are never separate files. Each exported asset carries DSP metrics measured locally from that exact file. This section carries no musical interpretation.", "", "Logic exposes region positions only as zoom-relative pixel coordinates, never as time, so they are not published as timing" + (delivery == .fullPackage ? " (the raw pixel values stay in `audio_manifest.json`)" : "") + ": they cannot be converted to seconds and would invite false conclusions. The silence map in each asset's metrics is the real timing evidence, measured from the WAV itself. A file may also run past its material — Logic can export or bounce beyond the last region, e.g. to the project end marker — so a measured silent range reaching the file's end is named per asset as trailing silence, and every duration comparison in this document uses the audible content, never the file length."]
        if assets.isEmpty { out += ["", "- No audio assets prepared. Run Prepare Audio Export after a read-only analysis."]; return out }
        let regionTotal = assets.reduce(0) { $0 + $1.regions.count }
        out += ["", "- Logic audio tracks: \(assets.count) • Audio regions: \(regionTotal) • Assets (WAV targets): \(assets.count)", "- Exported: \(assets.filter { $0.status == .exported }.count) • Requires user export: \(assets.filter { $0.status == .requiresUserExport }.count) • Failed: \(assets.filter { $0.status == .failed }.count)"]
        // Whether the WAVs are level evidence hinges on Logic's export Normalize: the automation reads the dialog's own
        // controls, switches a level-rewriting Normalize to Off itself (verified by re-reading the control) and cancels
        // the export only when that switch fails, so a known value here is always level-preserving. An export the app
        // did not launch (or observe) is stated as exactly that — never assumed to have been safe.
        if let s = exportSettings {
            out += [fact("Export dialog format", s.format), fact("Export dialog bit depth", s.bitDepth), fact("Export dialog Normalize", s.normalize)]
            if let from = s.normalizeSwitchedFrom.value { out += ["- Normalize showed \u{201C}\(from)\u{201D} when the dialog opened; the app switched it to Off and verified the switch before exporting."] }
            out += s.normalize.value.map { ["- Normalize was read as \($0) from Logic's own export dialog (a level-rewriting value is switched to Off by the app, and an unswitchable one cancels the export), so the WAVs carry the project's real relative levels."] } ?? ["- Normalize was not readable on the dialog, so whether the exported levels were rewritten is unverified — treat relative loudness between the WAVs with care."]
        } else {
            out += ["- Export dialog settings: unavailable — this session did not observe Logic's export dialog (the WAVs were exported manually, or the app was restarted since), so whether Normalize altered the exported levels is unverified."]
        }
        out += technicalFaultsDigest(assets, mix: mix)
        for asset in assets {
            out += ["", "### Audio Asset \(asset.audioID)", "- logicalTrackID: known: \(asset.logicalTrackID)", "- Logic Track Name: \(render(asset.trackName))", "- WAV file: \(render(asset.actualExportedPath))", "- Expected export path: known: \(asset.expectedExportPath)", "- Status: known: \(asset.status.rawValue)"]
            if let reason = asset.statusReason { out += ["- Status note: \(reason)"] }
            out += ["- Duration: \(render(asset.durationSeconds, unit: " s"))", "- Sample rate: \(render(asset.sampleRate, unit: " Hz"))", "- Channels: \(render(asset.channels))", "- Bit depth: \(render(asset.bitDepth))", "- Format: \(render(asset.format))"]
            out += metricsLines(asset.metrics)
            out += trailingSilenceLine(duration: asset.durationSeconds.value, metrics: asset.metrics, subject: "the track's material")
            out += ["- Regions (\(asset.regionCount)): " + (asset.regions.isEmpty ? "unavailable: no regions captured" : asset.regions.map { "`\($0.regionID)` \u{201C}\($0.name.value ?? "unnamed")\u{201D}" }.joined(separator: ", "))]
        }
        return out
    }
    /// The bounced Stereo Out: the one file where overall loudness, tonal balance, stereo width and masking are real,
    /// measurable properties — no per-track WAV contains the master chain or the sum. Its absence is a stated limitation
    /// the model must respect, never paper over with per-track extrapolation.
    private func mixSection(_ mix: MixBounceAsset?, delivery: PackageDelivery, assets: [AudioAsset]) -> [String] {
        var out: [String] = ["", "## Mix (Stereo Out)", "", "The bounced sum of the project through the whole master chain (Logic's File \u{25B8} Bounce) — the reference the per-track WAVs are judged against: overall loudness, tonal balance, stereo image and masking exist only in the sum, and no per-track WAV contains the master-chain processing."]
        guard let mix else {
            out += ["", "- No bounced mix exists in this analysis. Every audio fact above is per-track only; statements about the finished mix (its loudness, overall balance, how the tracks sit together) are NOT supported by measurements here — name them as requiring the bounced mix instead of asserting them."]
            return out
        }
        out += ["", "- File: known: \(mix.relativePath)" + (delivery == .fullPackage ? "" : " (the file is not part of this delivery — the measurements below are the mix evidence available to you)"), "- Duration: \(render(mix.durationSeconds, unit: " s"))", "- Sample rate: \(render(mix.sampleRate, unit: " Hz"))", "- Channels: \(render(mix.channels))", "- Bit depth: \(render(mix.bitDepth))", "- Format: \(render(mix.format))"]
        if let s = mix.bounceSettings {
            out += [fact("Bounce dialog format", s.format), fact("Bounce dialog bit depth", s.bitDepth), fact("Bounce dialog Normalize", s.normalize), fact("Cycle mode at bounce", s.cycle)]
            if let from = s.cycleSwitchedFrom.value { out += ["- Logic's transport Cycle showed \u{201C}\(from)\u{201D} before the bounce; the app switched it Off and verified the switch before opening the bounce dialog."] }
            out += s.cycle.value.map { ["- Cycle was read as \($0) from Logic's transport before the bounce dialog opened (Cycle constrains Logic's bounce to the cycle section, so the app switches it off), so no cycle range constrained this bounce. A region selection can still shorten a bounce; the duration check below is the proof either way."] } ?? ["- Cycle mode was not readable before the bounce, so whether a cycle range constrained the bounced span is unverified — the duration check below is the evidence."]
            if let from = s.normalizeSwitchedFrom.value { out += ["- Normalize showed \u{201C}\(from)\u{201D} when the dialog opened; the app switched it to Off and verified the switch before the bounce."] }
            if let row = s.pcmFormatCheckedByApp.value { out += ["- The format table opened with no uncompressed PCM format checked; the app checked \u{201C}\(row)\u{201D} and verified the check before the bounce."] }
            if let rows = s.formatsUncheckedByApp.value { out += ["- The format table also had \(rows.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")) checked; the app unchecked \(rows.count == 1 ? "it" : "them") and verified before the bounce, so exactly one PCM mix file was written."] }
            if let formats = s.formats.value { out += ["- Bounce dialog formats (read from Logic's own format table; the app sets the table to uncompressed PCM alone, cancelling only when checking the PCM row fails): known: \(formats.caption)"] }
            out += s.normalize.value.map { ["- Normalize was read as \($0) from Logic's own bounce dialog (a level-rewriting value is switched to Off by the app, and an unswitchable one cancels the bounce), so the file carries the mix's real level."] } ?? ["- Normalize was not readable on the bounce dialog, so whether the bounced level was rewritten is unverified."]
        } else {
            out += ["- Bounce dialog settings: unavailable — this session did not observe Logic's bounce dialog for this file, so whether Normalize altered its level is unverified."]
        }
        out += mix.metrics == nil ? ["- Audio metrics: unavailable — the file could not be analyzed"] : metricsLines(mix.metrics)
        out += trailingSilenceLine(duration: mix.durationSeconds.value, metrics: mix.metrics, subject: "the mix's material")
        // Exports preserve timeline positions, so a bounce whose audible content ends before the longest exported
        // track's content PROVABLY does not cover the whole project (a cycle range or a partial bounce) — mix and
        // per-track metrics then span different time windows, and the document must say so instead of presenting the
        // mix as the reference of the full song. Both sides are compared by measured content, never file length: an
        // export or bounce that ran past the material into silence does not stretch the project it is compared to.
        if let mixDuration = mix.durationSeconds.value, let longest = assets.compactMap({ asset in asset.durationSeconds.value.map { (name: asset.trackName.value ?? asset.logicalTrackID, seconds: contentEnd(duration: $0, metrics: asset.metrics)) } }).max(by: { $0.seconds < $1.seconds }) {
            let mixContent = contentEnd(duration: mixDuration, metrics: mix.metrics)
            if mixContent + 0.5 < longest.seconds {
                out += ["- Duration check: the bounce's audible content ends at \(decimalString(mixContent)) s while the longest exported track's content (\u{201C}\(longest.name)\u{201D}) ends at \(decimalString(longest.seconds)) s — exports preserve timeline positions and trailing measured silence is excluded on both sides, so the bounce demonstrably does NOT cover the whole project (a cycle range or a partial bounce was active). Its metrics describe only the bounced span; comparisons against per-track metrics cross different time windows — name this under ISSUES instead of treating the mix as the full-song reference."]
            } else {
                out += ["- Duration check: the bounce's audible content (\(decimalString(mixContent)) s) spans at least the longest exported track's content (\(decimalString(longest.seconds)) s); trailing measured silence is excluded on both sides, so a file that ran past its material does not distort this check."]
            }
        }
        if delivery == .fullPackage { out += ["", "Listen to this file (`" + mix.relativePath + "`) first for the overall picture, then to the per-track WAVs in `audio/`, and cross-check what you hear against the measured metrics."] }
        return out
    }
    /// Locally computed DSP measurements of one exported WAV — facts about that file (BS.1770-4 loudness and true peak,
    /// levels, spectrum, stereo, silence map, technical flags), never musical judgements. Values are rounded for reading
    /// (LUFS/dB to 0.1, percent to 1, centroid to 1 Hz); the JSON manifests keep full precision. States render honestly:
    /// an `unavailable` metric (e.g. stereo correlation of a mono file, dB level of digital silence) stays visible as such.
    private func metricsLines(_ metrics: AudioMetrics?) -> [String] {
        guard let m = metrics else { return [] }
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
    /// Measured technical faults surfaced once, up front: an inter-sample peak over full scale, digital clipping, or a notable
    /// DC offset is exactly what the reader must not have to dig out of ten per-asset metric blocks — least of all the bounced
    /// mix's faults, which are the finished product's faults. Full numbers stay per asset and in the Mix section.
    private func technicalFaultsDigest(_ assets: [AudioAsset], mix: MixBounceAsset?) -> [String] {
        func faultList(_ m: AudioMetrics) -> [String] {
            var found: [String] = []
            if let peak = m.truePeakDBTP.value, peak >= 0.05 { found.append("true peak +\(rounded(peak, digits: 1)) dBTP over full scale") }
            if let clipped = m.clippedSampleCount.value, clipped > 0 { found.append(plural(clipped, "clipped sample")) }
            if let dc = m.dcOffsetMean.value, abs(dc) >= 0.001 { found.append("DC offset \(rounded(dc, digits: 6))") }
            return found
        }
        var faults = assets.compactMap { asset -> String? in
            guard let m = asset.metrics else { return nil }
            let found = faultList(m)
            return found.isEmpty ? nil : "- `\(asset.logicalTrackID)` \u{201C}\(asset.trackName.value ?? asset.audioID)\u{201D}: \(found.joined(separator: " • "))"
        }
        let mixMeasured = mix?.metrics != nil
        if let mix, let m = mix.metrics { let found = faultList(m); if !found.isEmpty { faults.append("- Mix (Stereo Out) `\(mix.relativePath)`: \(found.joined(separator: " • ")) — faults of the finished sum itself") } }
        guard assets.contains(where: { $0.metrics != nil }) || mixMeasured else { return [] }
        let scope = "Technical faults measured from the exported files" + (mixMeasured ? " and the bounced mix" : "")
        if faults.isEmpty { return ["", scope + ": none — no digital clipping, no true peak above 0 dBTP, no notable DC offset."] }
        return ["", scope + " (full numbers under each asset" + (mixMeasured ? " and under Mix (Stereo Out)" : "") + "):", ""] + faults
    }
    /// The end of the audible material, from the measured silence map; the file length when no metrics or no trailing
    /// silent range prove otherwise. All duration comparisons in the document go through this, never raw file length.
    private func contentEnd(duration: Double, metrics: AudioMetrics?) -> Double {
        guard let silence = metrics?.silenceIntervals.value else { return duration }
        return AudioMetrics.contentEndSeconds(duration: duration, silence: silence)
    }
    /// One honest line naming a file that provably runs past its material: the export/bounce wrote measured silence to
    /// the file's end (Logic can run to the project end marker), so the file length overstates the content. Silent
    /// tails of a second or less are ordinary release/reverb room and are not called out.
    private func trailingSilenceLine(duration: Double?, metrics: AudioMetrics?, subject: String) -> [String] {
        guard let duration, let silence = metrics?.silenceIntervals.value else { return [] }
        let end = AudioMetrics.contentEndSeconds(duration: duration, silence: silence)
        guard duration - end > 1.0 else { return [] }
        return ["- Trailing silence: known: the audible content ends at \(decimalString(end)) s and the remaining \(decimalString(duration - end)) s to the file's end are measured silence — the file ran past \(subject), so its length overstates the content. Duration comparisons in this document already exclude this tail."]
    }
    private func metric(_ label: String, _ value: Fact<Double>, digits: Int, unit: String) -> String { guard let number = value.value else { return "  - \(label): \(value.state.rawValue)" }; return "  - \(label): known: \(rounded(number, digits: digits))\(unit)" }
    /// A value that rounds to zero prints as zero: "-0.0 dBTP" reads like a measurement error rather than a peak just under full scale.
    private func rounded(_ number: Double, digits: Int) -> String { let text = String(format: "%.\(digits)f", number); return text.allSatisfy { $0 == "-" || $0 == "0" || $0 == "." } ? String(format: "%.\(digits)f", 0.0) : text }
    /// Shares below 10 % keep a decimal: a band or a silence share that really is 0.4 % must not read as a flat "0%" while its
    /// silence ranges are listed right next to it.
    private func percent(_ value: Double) -> String { rounded(value, digits: value < 9.95 ? 1 : 0) + "%" }
    /// Two distinct facts: the catalogue of tools installed on this Mac (what COULD be used) and the plugins actually on tracks in the current project (real state). Neither is tied to a musical role.
    private func pluginSections(_ available: [PluginInventoryItem]) -> [String] {
        var out: [String] = ["", "## Available Plugins", "", "Audio processing tools actually installed and registered on this Mac (Audio Units, read-only inventory — no parameters, presets, or state). When recommending a plug-in, choose ONLY from this list; do not assume a plugin exists because it is popular. Recommendations are prose for the user — the machine-validated Mix Plan has no action that adds a plug-in. Entries typed \u{201C}Music Device\u{201D} are instruments (sound generators), not mixing inserts."]
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
    /// A routing fact plus its destination KIND (`· kind: bus`), derived from Logic's own caption grammar. A caption the
    /// grammar does not know gets no kind — the verbatim destination is still the fact, the kind is simply not claimed.
    private func routingEntry(_ label: String, _ value: Fact<String>) -> (label: String, line: String?) { let base = entry(label, value); guard let line = base.line else { return base }; return (base.label, line + kindSuffix(value)) }
    private func kindSuffix(_ value: Fact<String>) -> String { value.value.flatMap(RoutingDestinationKind.classify).map { " · kind: \($0.rawValue)" } ?? "" }
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
    /// The channel facts a Mix Plan's `parameters.current` must restate, collected into one table instead of scattered
    /// across the per-track sections: the model copies `current` from here, so a mismatch against the known fact (which
    /// the validator rejects) stops being a transcription error. States render honestly — a non-known value is named,
    /// never blanked and never guessed.
    private func currentControlValuesSection(_ snapshot: NormalizedSnapshot) -> [String] {
        var out = ["", "## Current control values (source for `parameters.current`)", "", "One row per logical track, restating the Volume / Pan / Mute / Solo channel facts from Track linking diagnostics above in one place. When writing a `set_volume` or `set_pan` action, copy the track's `parameters.current` from this table exactly — the validator rejects a `current` that does not match the known fact. Volume is in dB on Logic's fader scale (\u{2212}96\u{2026}+6), Pan in Logic's pan units (\u{2212}64\u{2026}+63, 0 = centre). A cell that is not a number or boolean names the fact's state; such a value is not evidence and must never be guessed into `parameters.current`."]
        guard !snapshot.tracks.isEmpty else { out += ["", "- No logical tracks in this snapshot."]; return out }
        func cell<T>(_ fact: Fact<T>?) -> String { guard let fact else { return "unavailable" }; guard let value = fact.value else { return fact.state.rawValue }; return display(value) }
        out += ["", "| logicalTrackID | Logic track name | Volume (dB) | Pan | Mute | Solo |", "| --- | --- | --- | --- | --- | --- |"]
        out += snapshot.tracks.map { track in
            let channel = track.channel
            let name = track.name.value.map { "\u{201C}\($0)\u{201D}" } ?? track.name.state.rawValue
            return "| `\(track.logicalTrackID)` | \(name) | \(cell(channel?.volumeDB)) | \(cell(channel?.pan)) | \(cell(channel?.mute)) | \(cell(channel?.solo)) |"
        }
        return out
    }
    /// The exact JSON contract the app's Review screen decodes and validates (`MixPlan` / `MixCommand`). The document must
    /// spell it out, or the model invents its own shape and the user's paste fails with "Invalid MixPlan JSON".
    private func mixPlanSchemaSection(_ snapshot: NormalizedSnapshot) -> [String] {
        ["", "## Mix Plan schema (machine-validated)", "", "The application validates the pasted Mix Plan technically against the current snapshot — targets must exist in the facts above, every action must carry its typed `parameters.value` inside its control's range, ids must be unique and reasons non-empty. It never judges musical merit, and nothing is written to Logic Pro: the validated plan is the user's instruction sheet to apply by hand.", "", "- `version` is `\"1.0\"` and `status` is `\"ready\"` — a Mix Plan is delivered only after the user confirmed (workflow stage 5).", "- Every field shown in the example is required on every action, and every action carries a `parameters.value` — always the absolute target setting, never a change relative to the current value.", "- Every action `id` must be unique within the plan; a duplicated id is rejected as invalid.", "- `reason` must be one non-empty factual sentence naming the current known value, the absolute target, the direction of the move (up or down) and the evidence; an empty reason is rejected as invalid. Write `reason` in the language the user writes to you in — it is the human-readable justification the Review screen shows the user under each action, the only free text inside the JSON. Everything else in the JSON (keys, action names, ids, track identifiers, numeric values) is machine-matched against the facts and stays exactly as this document states them.", "- `action` must be one of: `set_volume`, `set_pan`, `set_mute`, `set_solo`, `set_plugin_bypass`, `set_plugin_parameter`. No other action is implemented; anything else is rejected as unsupported. In particular there is NO action that adds a plug-in — plug-in recommendations stay prose for the user to apply manually (put them in MANUAL STEPS).", "- `set_volume` and `set_pan` take a numeric `parameters.value`: `set_volume` in dB, the same scale as the Volume channel facts above, within Logic's fader range \u{2212}96\u{2026}+6 dB (to silence a track use `set_mute`, not a huge negative volume); `set_pan` in Logic's pan units as shown in the Pan facts (0 = centre, negative = left, positive = right), within \u{2212}64\u{2026}+63. `set_mute` and `set_solo` take a boolean `parameters.value`; `set_solo` belongs in a delivered plan only when the user explicitly asked for a solo (see the plan composition rules above). A missing, mistyped or out-of-range value is rejected as invalid.", "- `set_volume` and `set_pan` additionally require `parameters.current` — the track's current known value, copied exactly from the Current control values table above — and `parameters.delta` = target \u{2212} current, signed. The validator checks the arithmetic (current + delta = value) and checks `current` against the known channel fact; either mismatch is rejected as invalid. This is the direction proof: a target below `current` makes the track QUIETER, a target above makes it LOUDER. The LUFS/RMS/peak numbers in the audio metrics are measurements of the exported files, never fader positions — never copy a loudness value into `parameters.value`.", "- Target a track with `target.trackID` = the `logicalTrackID` used throughout this document, or `target.trackName` = the exact Logic track name.", "- `set_plugin_bypass` (boolean `parameters.value`) and `set_plugin_parameter` additionally need `target.pluginID` or `target.pluginName`, and `set_plugin_parameter` needs `target.parameterID` or `target.parameterName` plus a numeric `parameters.value` inside the parameter's reported range. When no plug-in facts were captured for the track, these validate as `requires_probe`, not as executable actions.", "", "The example below is built from this document's own facts where the snapshot proves them: a real `logicalTrackID` with its real `current` values and exact delta arithmetic. The `reason` texts are teaching templates — every real action replaces them with the factual sentence described above, in the user's language.", "", "```json", exampleJSON(for: snapshot), "```", "", "### Pre-delivery checklist (stage 6)", "", "Check your drafted answer against every line immediately before sending stage 6 — one failed line means the Review screen rejects the action or the user gets an unusable instruction sheet:", "", "1. Under `MIX PLAN` there is exactly one fenced `json` code block, holding nothing but the JSON object: no prose, no comments, no trailing commas, every number a plain JSON number.", "2. `version` is `\"1.0\"`, `status` is `\"ready\"`, every action carries every field of the example, and every `id` is unique within the plan.", "3. Every `target.trackID` is a `logicalTrackID` that exists in this document, copied exactly (the Current control values table lists them all).", "4. Every `set_volume` value lies within \u{2212}96\u{2026}+6 dB at 0.1 dB precision; every `set_pan` value is an integer within \u{2212}64\u{2026}+63; `set_mute` / `set_solo` / `set_plugin_bypass` values are JSON booleans.", "5. On every volume/pan action `parameters.current` is copied unchanged from the Current control values table (or from the user's answer when the table showed no number), `parameters.delta` equals `value` \u{2212} `current`, and the sign of `delta` matches the direction the `reason` states. `parameters.value` is a fader or pan setting — never a LUFS/RMS/peak measurement.", "6. Every `reason` is one self-contained factual sentence naming the current value, the absolute target, the direction and the evidence.", "7. No `set_solo` action exists unless the user explicitly asked for a solo, and no action adds a plug-in — plug-in work lives in `MANUAL STEPS`, chosen only from Available Plugins.", "8. Every ISSUE from your analysis is traceable: resolved by a plan action, handled by a `MANUAL STEPS` item, or explicitly closed with the reason it stays as is.", "9. Each `MANUAL STEPS` item names the exact track (real name + logicalTrackID), the exact operation to perform in Logic and the evidence it rests on — or the section reads \u{201C}MANUAL STEPS: none\u{201D}."]
    }
    /// Models copy the example verbatim, so a placeholder trackID teaches a plan the validator can only answer with
    /// `requires_probe`. When the snapshot itself proves a track with known Volume AND Pan (the same facts the Current
    /// control values table restates), the example targets that real track with its real `current` values and exact
    /// `delta` arithmetic, targets kept inside Logic's control ranges by flipping the move's direction near an edge.
    /// Numbers render through `decimalString`, the same formatting as the table, so `current` matches it verbatim.
    /// A snapshot without such a track falls back to the static example.
    private func exampleJSON(for snapshot: NormalizedSnapshot) -> String {
        guard let track = snapshot.tracks.first(where: { $0.channel?.volumeDB.value != nil && $0.channel?.pan.value != nil }), let channel = track.channel, let volume = channel.volumeDB.value, let pan = channel.pan.value else { return Self.mixPlanExampleJSON }
        let volumeDelta: Double = volume - 1 >= CommandValidator.volumeRangeDB.lowerBound ? -1 : 1
        let panDelta: Double = pan - 20 >= CommandValidator.panRange.lowerBound ? -20 : 20
        let reason = "One factual sentence naming the current known value, the absolute target, the direction of the move and the evidence above, in the user's language"
        return """
{
  "version": "1.0",
  "status": "ready",
  "actions": [
    {
      "id": "action_001",
      "target": { "trackID": "\(track.logicalTrackID)" },
      "action": "set_volume",
      "parameters": { "value": \(decimalString(volume + volumeDelta)), "current": \(decimalString(volume)), "delta": \(decimalString(volumeDelta)) },
      "reason": "\(reason)"
    },
    {
      "id": "action_002",
      "target": { "trackID": "\(track.logicalTrackID)" },
      "action": "set_pan",
      "parameters": { "value": \(decimalString(pan + panDelta)), "current": \(decimalString(pan)), "delta": \(decimalString(panDelta)) },
      "reason": "\(reason)"
    }
  ]
}
"""
    }
    static let mixPlanExampleJSON = """
{
  "version": "1.0",
  "status": "ready",
  "actions": [
    {
      "id": "action_001",
      "target": { "trackID": "track_2" },
      "action": "set_volume",
      "parameters": { "value": -3.0, "current": -2.0, "delta": -1.0 },
      "reason": "One factual sentence naming the current known value, the absolute target, the direction of the move and the evidence above"
    },
    {
      "id": "action_002",
      "target": { "trackID": "track_2" },
      "action": "set_pan",
      "parameters": { "value": -20, "current": 0, "delta": -20 },
      "reason": "One factual sentence naming the current known value, the absolute target, the direction of the move and the evidence above"
    }
  ]
}
"""
}
