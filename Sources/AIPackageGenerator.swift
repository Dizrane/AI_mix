import Foundation
import AppKit

/// What the reader actually receives. "Copy for AI" hands over this Markdown alone — no JSON, no WAV files — while Save Package
/// ships them next to it, and the Assistant sends the API variant over the Capy API where the recipient's replies are parsed by
/// a program. The document states the one mode it was generated for instead of describing every possibility and then telling
/// the reader to open files that are not there.
enum PackageDelivery: Sendable { case markdownOnly, fullPackage, apiDelivery }

/// Provider-neutral export of normalized, evidence-based DAW facts for any external LLM.
struct AIPackageGenerator: Sendable {
    static let schemaVersion = "2.32"
    func make(snapshot: NormalizedSnapshot, sessionID: String, audio: [AudioAsset] = [], plugins: [PluginInventoryItem] = [], probes: [ProbeType] = ProbeType.allCases, delivery: PackageDelivery = .fullPackage, exportSettings: ExportSettingsFacts? = nil, mix: MixBounceAsset? = nil, postApply: PostApplyReport? = nil) -> String {
        let readiness = PackageReadiness.evaluate(snapshot: snapshot, assets: audio)
        var out: [String] = []
        out += ["# AI Mix Analysis", ""]
        out += primaryInstruction(delivery, mix: mix)
        out += ["", "## Package", "", "- Package schema: `\(Self.schemaVersion)`", "- Analysis ID: `\(sessionID)`", "- Generated: `\(ISO8601DateFormatter().string(from: Date()))`", "- Project: \(render(snapshot.project.name))", "- Logical tracks: \(snapshot.tracks.count)", "- Audio assets: \(audio.count)", "- Exported: \(readiness.audioExported)", "- Requires export: \(audio.count - readiness.audioExported)", "- Post-apply snapshot: " + (postApply != nil ? "yes — captured after the previous Mix Plan was applied (see Post-apply verification)" : "no — no plan has been applied and verified in this analysis")]
        out += purposeAndRules(delivery)
        out += ["", "## Project metadata", "", fact("Project name", snapshot.project.name), fact("Tempo", snapshot.project.tempo, unit: " BPM"), fact("Time signature", snapshot.project.timeSignature), fact("Key signature", snapshot.project.keySignature), fact("Sample rate", snapshot.project.sampleRate, unit: " Hz"), fact("Transport", snapshot.project.transportState), fact("Snapshot completeness", snapshot.completeness)]
        out += readinessSection(readiness)
        out += postApplySection(postApply)
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
        // Every delivery teaches the same deliverable: a MixGraph for the application's own offline render. The Mix
        // Plan contract (the hidden Review screen's live path) stays in code below but ships in no document — teaching
        // both would invite the model to deliver the wrong one, and the UI exposes only the offline render.
        out += mixGraphSchemaSection(assets: audio, plugins: plugins)
        return out.joined(separator: "\n") + "\n"
    }
    /// The delivery mode is a fact the app knows, so the document asserts it. Everything after it — which files to open, whether
    /// listening is possible at all, what counts as evidence — follows from that one statement instead of a menu of possibilities.
    private func primaryInstruction(_ delivery: PackageDelivery, mix: MixBounceAsset?) -> [String] {
        let opening: [String]
        switch delivery {
        case .fullPackage:
            let mixContents = mix == nil ? "" : ", and the bounced Stereo Out mix in `mix/`"
            let inspectMix = mix == nil ? "" : ", and the `mix/` folder"
            let listeningStep = mix == nil
                ? "3. listen to ALL available track WAV assets in `audio/`;"
                : "3. listen first to the bounced Stereo Out mix in `mix/` for the overall picture; then listen to ALL track WAV assets in `audio/`; finally return to the mix to judge the summed balance, masking, stereo image and master-chain result — never infer those properties from isolated tracks;"
            opening = ["When this package (or its ZIP) is provided to an AI system, THIS document is the authoritative task specification for the package. The AI must NOT require a separate user prompt to begin — handing over the whole package is enough. The standard workflow is: the user gives you this package (typically the ZIP) and you start immediately.", "", "DELIVERY: FULL PACKAGE. This document ships together with `logic_snapshot.json`, `audio_manifest.json`, `manifest.json`, the exported track WAV files in `audio/`\(mixContents).", "", "MIXED DELIVERY: the user may paste the text-only variant of this document (produced by Copy for AI; its delivery line claims the analysis text was handed over alone) next to this package. When both arrive together, THIS document is the one that matches what you actually received — the audio IS delivered — so this document's rules govern and the other variant's delivery claims are void. The delivery variants differ only in their preambles and response contracts; every fact in them is identical.", "", "THE FINAL DELIVERABLE IS A MIXGRAPH. After the user\u{2019}s confirmation you deliver exactly one fenced json code block containing a MixGraph object (see the MixGraph response contract at the end of this document): the user pastes your reply into the application\u{2019}s Render screen, which extracts the LAST fenced json block, dry-validates it and renders `mix.wav` with the application\u{2019}s own offline engine over the exported WAVs — outside Logic, and only when the user explicitly presses Render.", "", "The AI must:", "1. read this document first;", "2. inspect the package contents — `AI_MIX_ANALYSIS.md`, `logic_snapshot.json`, `audio_manifest.json`, `manifest.json`, the `audio/` folder\(inspectMix);", listeningStep, "4. use `logic_snapshot.json` and `audio_manifest.json` as factual/project context and provenance;", "5. use only facts marked `known` as factual evidence;", "6. follow the External AI Instructions and the MixGraph response contract defined below;", "7. open the first paragraph of the ANALYSIS section with one explicit line declaring your audio mode — either that you actually listened to the WAV files, or that your platform cannot process audio and you are working from the measured metrics and written facts alone; vague wording like \u{201C}I checked the files\u{201D} is NOT such a declaration;", "8. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "9. not deliver the final MixGraph before the required analysis, interpretation, questions and user-confirmation stages are completed — the first reply contains NO fenced json code block at all;", "10. after the user\u{2019}s confirmation, deliver EXACTLY ONE fenced json code block containing the MixGraph and nothing else machine-readable — prose around it is shown to the user but never parsed.", "", "Everything needed is inside the package — you do not need the user to tell you what to read, where the WAVs are, what this file is, or in what order to work. This document defines that workflow.", "", "If your platform cannot process audio files at all, say so plainly, skip the listening steps, work from the written facts and the measured audio metrics below, and ask the user targeted questions where only listening could decide."]
        case .markdownOnly:
            opening = ["This document is the authoritative task specification for the analysis. The AI must NOT require a separate user prompt to begin — receiving this document is enough: start immediately.", "", "DELIVERY: THIS DOCUMENT ONLY. You received the analysis text alone. `logic_snapshot.json`, `audio_manifest.json`, `manifest.json`, the track WAV files in `audio/` and any bounced Stereo Out mix in `mix/` are NOT part of this delivery and you cannot open them, so there is nothing to look for and nothing to wait for.", "", "MIXED DELIVERY: if, despite the line above, the package ZIP (or its extracted `audio/` / `mix/` folders and JSON files) actually arrived alongside this text, then the audio WAS delivered: follow the FULL PACKAGE rules in the ZIP's own `AI_MIX_ANALYSIS.md` — they take priority over this document's delivery claims, including the rule below never to state that you listened. The delivery variants differ only in their preambles and response contracts; every fact in them is identical.", "", "THE FINAL DELIVERABLE IS A MIXGRAPH. After the user\u{2019}s confirmation you deliver exactly one fenced json code block containing a MixGraph object (see the MixGraph response contract at the end of this document): the user pastes your reply into the application\u{2019}s Render screen, which extracts the LAST fenced json block, dry-validates it and renders `mix.wav` with the application\u{2019}s own offline engine over the exported WAVs — outside Logic, and only when the user explicitly presses Render.", "", "The AI must:", "1. read this document first;", "2. treat the Logic facts and the locally measured audio metrics in it as the complete evidence base — the metrics under each audio asset were computed by the application from the real WAV files, so quantitative statements about loudness, peaks, dynamics, tonal balance, stereo image and silence are fully supported here;", "3. never state or imply that it listened to the audio: the audio was not delivered, and claiming otherwise is fabrication;", "4. open the first paragraph of the ANALYSIS section with one explicit line stating that the audio was not delivered and you are working from the measured metrics and written facts; vague wording like \u{201C}I checked the files\u{201D} is NOT such a declaration;", "5. use only facts marked `known` as factual evidence;", "6. follow the External AI Instructions and the MixGraph response contract defined below;", "7. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "8. not deliver the final MixGraph before the required analysis, interpretation, questions and user-confirmation stages are completed — the first reply contains NO fenced json code block at all;", "9. after the user\u{2019}s confirmation, deliver EXACTLY ONE fenced json code block containing the MixGraph and nothing else machine-readable — prose around it is shown to the user but never parsed.", "", "Where a conclusion genuinely requires hearing the material (timbre, performance quality, intelligibility, musical role), name the asset and the question and ask the user for the full package — Save Package in the application produces a ZIP with the WAV files. Do not stall the rest of the analysis waiting for it."]
        case .apiDelivery:
            opening = ["This document is the authoritative task specification for the analysis. It was sent into this thread PROGRAMMATICALLY by the AI Mix Assistant application over the Capy API — begin immediately; no separate user prompt will come. Your replies are shown to the user as prose, but the machine-readable deliverable is parsed by a program, so its format rules below are absolute.", "", "DELIVERY: API (TEXT ONLY). You received the analysis text alone. `logic_snapshot.json`, `audio_manifest.json`, `manifest.json`, the track WAV files in `audio/` and any bounced Stereo Out mix in `mix/` are NOT part of this delivery and you cannot open them, so there is nothing to look for and nothing to wait for. Work from the Logic facts and the measured audio metrics in this document.", "", "MIXED DELIVERY: if, despite the line above, the package ZIP (or its extracted `audio/` / `mix/` folders and JSON files) actually arrived alongside this text, then the audio WAS delivered: follow the FULL PACKAGE rules in the ZIP's own `AI_MIX_ANALYSIS.md` — they take priority over this document's delivery claims, including the rule below never to state that you listened. The delivery variants differ only in their preambles and response contracts; every fact in them is identical.", "", "THE FINAL DELIVERABLE IS A MIXGRAPH, NOT A MIX PLAN. After the user's confirmation you deliver exactly one fenced json code block containing a MixGraph object (see the MixGraph response contract at the end of this document): the application extracts the LAST fenced json block of the transcript, dry-validates it and hands it to its own offline mix engine, which renders `mix.wav` outside Logic only when the user explicitly presses Render.", "", "The AI must:", "1. read this document first;", "2. treat the Logic facts and the locally measured audio metrics in it as the complete evidence base — the metrics under each audio asset were computed by the application from the real WAV files, so quantitative statements about loudness, peaks, dynamics, tonal balance, stereo image and silence are fully supported here;", "3. never state or imply that it listened to the audio: the audio was not delivered, and claiming otherwise is fabrication;", "4. open the first paragraph of the ANALYSIS section with one explicit line stating that the audio was not delivered and you are working from the measured metrics and written facts; vague wording like \u{201C}I checked the files\u{201D} is NOT such a declaration;", "5. use only facts marked `known` as factual evidence;", "6. follow the External AI Instructions and the MixGraph response contract defined below;", "7. not invent missing information (`unknown` / `unavailable` / `requires_probe` is not evidence);", "8. not deliver the final MixGraph before the required analysis, interpretation, questions and user-confirmation stages are completed — the first reply contains NO fenced json code block at all;", "9. after the user's confirmation, deliver EXACTLY ONE fenced json code block containing the MixGraph and nothing else machine-readable — prose around it is shown to the user but never parsed.", "", "Where a conclusion genuinely requires hearing the material (timbre, performance quality, intelligibility, musical role), name the asset and the question under QUESTIONS instead of guessing. Do not stall the rest of the analysis waiting for it."]
        }
        return ["## THIS FILE IS THE PRIMARY INSTRUCTION FOR THE AI", ""] + opening + ["", "Facts vs AI interpretation — keep them strictly separate. Logic FACTS (real track names, logicalTrackID, track/channel facts, audio-asset mapping, the measured audio metrics, the plugin inventory, provenance) are given here and must NEVER be rewritten or altered. Musical INTERPRETATION (musical role, track purpose, vocal/instrument assessment, processing recommendations, the final MixGraph) is yours to produce and lives in a separate layer.", "", "If the user additionally provides their own task or context, honour it as long as it does not contradict the Critical Rules or the response format below."]
    }
    private func purposeAndRules(_ delivery: PackageDelivery) -> [String] {
        let purpose = delivery == .fullPackage
            ? "This package contains factual information extracted read-only from Logic Pro, the corresponding exported track WAVs, the bounced Stereo Out mix when present, and objective DSP measurements of those files. The external AI must listen to every provided track and separately to the mix, then combine what it hears with the measurements and these Logic facts. This application performs no musical interpretation of its own."
            : "This document contains factual information extracted read-only from Logic Pro plus objective DSP measurements the application computed from the exported tracks and the bounced Stereo Out mix when present. The audio files themselves are not part of this delivery, so the measurements are the audio evidence available to you. This application performs no musical interpretation of its own."
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
    /// The second-round marker and its evidence. The section exists only when a previously delivered plan was really
    /// applied and verified by a fresh scan; it never speculates about what a plan "should" have done — every line is
    /// either a re-read fact, a diff of two real snapshots, or a measurement of a real file.
    private func postApplySection(_ report: PostApplyReport?) -> [String] {
        guard let report else { return [] }
        var out = ["", "## Post-apply verification (previous plan)", "", "THIS IS A POST-APPLY SNAPSHOT: a previously delivered Mix Plan was applied " + (report.executedLive ? "by the application (LIVE execution with per-write readback)" : "by the user by hand") + " and every fact in this document was captured by a fresh read-only scan AFTER that (verified \(ISO8601DateFormatter().string(from: report.verifiedAt))). Treat this package as the SECOND ROUND of the workflow: first assess what the applied plan actually achieved, using the verification below together with the fresh facts and metrics, then run the standard workflow (stages 1\u{2013}6) on this document alone. Do not re-deliver the previous plan; every `parameters.current` in a new plan must come from THIS document's Current control values table, and only moves the fresh evidence still justifies belong in it.", "", "Each applied action's absolute target was checked against the re-read known fact (tolerance 0.05, the validator's own): `matched` — the fresh fact equals the target; `mismatched` — it does not (both values shown; investigate before planning on top of it); `unverifiable` — the fresh scan exposes no known fact for the control, which is stated honestly and never guessed into a result.", ""]
        out += report.checks.isEmpty ? ["- No valid actions were available to verify."] : report.checks.map { check in
            "- `\(check.actionID)` \(check.action) on \(check.trackLabel): plan \(check.planValue) vs re-read \(check.rereadValue) — \(check.outcome.rawValue)" + (check.note.isEmpty ? "" : " (\(check.note))")
        }
        out += ["", "Track diff against the pre-apply snapshot: \(report.diff.changed.count) changed, \(report.diff.unchanged.count) unchanged" + (report.diff.changed.isEmpty ? "." : ": " + report.diff.changed.joined(separator: "; ") + ".")]
        out += ["", "### Audio metrics before / after", ""]
        if report.metricDeltas.isEmpty {
            out += ["- No before/after comparison is available: no pre-apply measurement matches a currently measured file. Re-export the tracks and re-bounce the mix, then regenerate this package to compare LUFS / true peak / clipping against the pre-apply state."]
        } else {
            out += ["\u{201C}Before\u{201D} numbers are the measurements of the files as they stood when the plan was verified; \u{201C}after\u{201D} are the current files'. Identical numbers mean the file was NOT re-exported after the plan was applied — control moves change the audio only after a new export/bounce, so judge the plan's sonic effect only from rows that were really re-measured.", ""]
            out += report.metricDeltas.map { delta in
                func pair(_ label: String, _ before: Double?, _ after: Double?, unit: String) -> String {
                    guard let before, let after else { return "\(label) \(before.map { decimalString($0) + unit } ?? "unavailable") \u{2192} \(after.map { decimalString($0) + unit } ?? "unavailable")" }
                    let deltaValue = after - before
                    return "\(label) \(decimalString(before)) \u{2192} \(decimalString(after))\(unit) (\u{0394} \(deltaValue >= 0 ? "+" : "")\(decimalString(deltaValue)))"
                }
                let clipped = "clipped \(delta.clippedBefore.map(String.init) ?? "unavailable") \u{2192} \(delta.clippedAfter.map(String.init) ?? "unavailable")"
                return "- \(delta.label): " + [pair("LUFS", delta.lufsBefore, delta.lufsAfter, unit: ""), pair("true peak", delta.truePeakBefore, delta.truePeakAfter, unit: " dBTP"), clipped].joined(separator: " \u{00B7} ") + (delta.changed ? "" : " — unchanged file")
            }
        }
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
            ? ["You are the decision-maker for this mixing analysis. Work from five inputs: (1) the Logic facts in this document, (2) the measured audio metrics under each audio asset, (3) the real track WAV files in `audio/`, (4) the bounced Stereo Out mix in `mix/` when the Mix section names one, and (5) the provenance mapping above.", "", "First, analyse the audio yourself. When the bounced Stereo Out mix is present, listen to it first for the overall picture. Then listen to every track WAV to determine: what is the beat; which tracks are vocals; vocal type; lead / double / backing / adlib / additional layers; instrumental elements; relationships between tracks; recording issues; dynamics; stereo placement; tonal balance; audible noise or artefacts; performance characteristics. Finally return to the mix: it is the evidence for the summed balance, masking/conflicts, overall tonal balance and stereo image, and the master-chain result — never substitute an inference from isolated tracks for listening to the sum."]
            : ["You are the decision-maker for this mixing analysis. Work from three inputs: (1) the Logic facts in this document, (2) the measured audio metrics under each audio asset, and (3) the provenance mapping above. You did not receive the audio, so listening is not part of this pass — do not simulate it.", "", "Start from what the measurements settle objectively: relative loudness and level balance between tracks (integrated LUFS, RMS, true peak), dynamics and density (crest factor, silence map and its ranges), tonal balance and likely masking between tracks that share the same bands (spectral shares, centroid), stereo image (correlation, mid/side ratio), and technical faults (clipping counts, DC offset, inter-sample peaks above 0 dBTP). Then state plainly which questions only hearing can answer — vocal type, performance quality, timbre, musical role, intelligibility — and put them into the QUESTIONS section instead of guessing."]
        let metrics = "Measured audio metrics: every exported audio asset carries an \u{201C}Audio metrics\u{201D} subsection with objective numbers this application computed locally from that exact WAV file (ITU-R BS.1770-4 integrated loudness and true peak, sample peak, RMS, crest factor, spectral band energy shares, spectral centroid, stereo correlation, mid/side energy ratio, silence map, DC offset, clipping counts). They are measured facts about the audio files, not musical judgements, and they are the primary quantitative evidence for level balance, dynamics, tonal balance and the stereo image — especially where hearing is unreliable (differences of a couple of dB, masking, resonances)." + (delivery == .fullPackage ? " If your listening impression conflicts with these numbers, report the conflict explicitly instead of silently trusting either side." : "")
        // The declaration the ANALYSIS section must open with names the delivery's real options: with the WAVs both
        // modes exist; Markdown alone leaves only the measurements — offering "listened" there would invite fabrication.
        let declaration = delivery == .fullPackage
            ? "(you listened to the files, or you cannot listen and work from the measurements and facts)"
            : "(the audio was not delivered — you work from the measured metrics and written facts)"
        // One instruction set for every delivery: the deliverable is always a MixGraph the application's offline
        // engine renders itself — so plug-in INSERTS are real machine actions (chosen from the installed
        // catalogue, set through AUParameterTree), never prose recommendations. The Mix Plan instruction set (the
        // hidden Review screen's live path) is no longer shipped; its schema lives on in mixPlanSchemaSection below.
        return ["", "## External AI Instructions", ""] + inputs + ["", metrics, "", "Rules for interpretation:", "- Do not draw conclusions from a track name alone. The name is context; the primary evidence of a musical role is the audio evidence plus Logic metadata.", "- If they conflict, state it explicitly: \"Track name suggests X, but the audio evidence suggests Y.\"", "- Several Logic tracks may form one musical element (e.g. layered leads); or same-named tracks may be different parts. Decide from the evidence, not the names.", "", "Plugins:", "- `Available Plugins` = the catalogue of Audio Units actually installed on this Mac; every entry names its exact FourCC component identifier. Choose inserts ONLY from this list, and only from entries whose identifier starts with `aufx/` — the engine loads audio effects exclusively, so a Music Effect (`aumf/\u{2026}`) or an instrument (`aumu/\u{2026}`) is rejected by validation even though it is installed (many plug-ins register both types; pick the `aufx` variant). If the tool you want is not there, say so and use an available alternative — never invent a plug-in.", "- The offline render engine CAN insert plug-ins: a MixGraph insert names an installed effect by its `component` FourCC identifier copied exactly from Available Plugins (preferred, exact) or by its exact installed name (it must match exactly one installed effect), and the engine loads the real Audio Unit, sets every value in `parameters` through its AUParameterTree and reads each write back — an unresolvable plug-in or parameter is a named render failure, never a silent skip.", "- The project's CURRENT plug-in chains appear only as captured facts under each strip's Plugins subsection; a strip showing `Plugins: unavailable` has no captured chain. The offline render starts from the exported WAVs, which already carry any processing Logic printed into them — your MixGraph describes only the processing the engine itself applies on top.", "", "Workflow (human-in-the-loop — do NOT jump straight to the mix graph):", "1. ANALYSIS — report what the evidence shows; its FIRST paragraph opens with the one-line audio-mode declaration required above \(declaration).", "2. INTERPRETATION — how you read the project structure.", "3. ISSUES — problems found.", "4. QUESTIONS — what you need the user to confirm.", "5. USER CONFIRMATION — wait for the user.", "6. MIX GRAPH — only after confirmation.", "", "Respond in Markdown a human will read, in the language the user writes to you in (keep the section headings, track identifiers, file names and the JSON exactly as specified, in English). Stages 1\u{2013}4 are for the user: structure them as the four sections ANALYSIS / INTERPRETATION / ISSUES / QUESTIONS, number the questions and propose a concrete default for each, so the user can confirm everything in one short reply; the user's next message — their answers, or an explicit instruction to proceed with your defaults — IS the confirmation of stage 5.", "", "Two replies, strictly separated: your FIRST reply delivers stages 1\u{2013}4 only and contains NO fenced json code block at all — a graph in the first reply skips the user's confirmation and violates this workflow, even as a draft. Once the user has confirmed (stage 5), deliver stage 6: any prose commentary you need, plus EXACTLY ONE fenced json code block containing the MixGraph. The application extracts the LAST fenced json block it is given (the Assistant reads the whole thread transcript; on the manual path the user pastes your reply on the Render screen) and dry-validates it — schema version, unique names, file names against the really exported WAVs, send buses against the defined buses, pan ranges, insert identities against the installed catalogue. When that validation rejects the graph, you will receive one message listing the named errors (on the manual path the user sends them to you); reply with exactly one corrected fenced json block. The render itself runs offline in the application's own engine and starts only when the user explicitly presses Render — nothing renders automatically.", "", "Graph composition rules:", "- Account for every ISSUE: each problem you reported under ISSUES must be traceable in the final answer — addressed by the graph (a gain, a pan, a send, an insert) or explicitly closed in your stage-6 prose, saying why it is deliberately left as is.", "- `file` names the exported WAV exactly as the asset's `WAV file` line under Audio Assets states it — never a track name, never an invented path; a file the export did not produce cannot be mixed.", "- Every gain move is justified by the measured metrics: your prose names the measured value (integrated LUFS, true peak, RMS) the move rests on, never a hunch about how the file probably sounds.", "- The master `gainDB` is a final trim, not a remedy: a sum that clips is fixed at the tracks or with a limiter insert on the master, never by trimming the master gain until the numbers happen to fit."]
    }
    /// Emits normalized logical tracks (one entity per Logic object) plus an explicit unresolved/unlinked group, so the LLM never sees the header/channel duplicates.
    private func trackLinkingSection(_ snapshot: NormalizedSnapshot) -> [String] {
        let link = snapshot.linking
        var out: [String] = ["## Track linking diagnostics", "", "- Track-header candidates (raw): \(link.trackHeaderCandidates)", "- Channel-strip candidates (raw): \(link.channelCandidates)", "- Confirmed links (header + channel merged): \(link.confirmedLinks)", "- Unresolved header-only tracks: \(link.unresolvedHeaders)", "- Unresolved channel-only strips: \(link.unresolvedChannels)", "- Ambiguous (shared name, not merged): \(link.ambiguous)", "- Logical tracks (final): \(link.logicalTracks)", "", fact("Track discovery", snapshot.tracksStatus), "", "A logical track is one Logic object. `header` facts come from the arrange Tracks area; `channel` facts from the Mixer strip. Match status: `confirmed` (unique 1:1 name link), `unresolved` (only one view exists), `ambiguous` (name shared, not merged).", "", "Routing: Logic exposes an EMPTY send slot, the output slot and an aux's input slot as identically shaped buttons that only name a destination (\"Bus 1\", \"St Out\"), so slots are classified purely by documented structure. An OCCUPIED send has its own shape (a destination-captioned group holding a bypass checkbox) and is the only thing published under Sends; the output slot is the destination button directly after the group pop-up; the input slot directly follows the channel-mode button. A destination button matching no rule is listed under \"Routing buttons (slot kind unclassified)\" with `requires_probe` — never read such a button as a send: it may equally be the track's output or an aux's input. Every destination additionally carries its KIND, derived from Logic's own caption grammar: `bus` (\"Bus N\", an internal bus), `stereo_output` (\"St Out\" / \"Stereo Out\"), `hardware_output` (\"Output\" / \"Output N-M\"), `hardware_input` (\"Input N-M\"), `not_connected` (\"No Output\" / \"No Input\") — so an output to the stereo bus and an output into a bus are never conflated. A send's Level is a fact only on the scale the knob itself proves: its AXValueDescription displaying dB, or the knob's numeric AXValue bounded by its own AXMinValue\u{2026}AXMaxValue (explicitly unitless raw units, never sold as dB); a knob proving neither keeps Level `requires_probe`, and `set_send_level` stays unsupported for that send. No send pan control is exposed at all, so send Pan is always `requires_probe` and `set_send_pan` is never executable.", "", "Per strip below, empty subsections compress to one line each, stated once here instead of on every track: `Sends: none` is a fact, not missing data — an occupied send is structurally unmistakable; `Routing buttons (slot kind unclassified): none` means no destination button was left unclassified; `Plugins: unavailable` means no plug-in facts were captured for that strip.", "", "## Logical tracks", ""]
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
                out += channel.sends.isEmpty ? ["- Sends: none"] : ["", "##### Sends"] + channel.sends.flatMap { ["- Send `\($0.id)`", "  - Destination: \(render($0.destination))\(kindSuffix($0.destination))", "  - Bypass: \(render($0.bypass))", "  - Level: \(sendLevelLine($0))", "  - Pan: requires_probe (no send pan control is exposed over AX)"] }
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
        if delivery == .fullPackage { out += ["", "Listen to this file (`" + mix.relativePath + "`) first for the overall picture, then to the per-track WAVs in `audio/`, then return to this mix and cross-check what you hear against the measured metrics."] }
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
        var out: [String] = ["", "## Available Plugins", "", "Audio processing tools actually installed and registered on this Mac (Audio Units, read-only inventory — no parameters, presets, or state). When recommending a plug-in, choose ONLY from this list; do not assume a plugin exists because it is popular. Only entries whose component identifier starts with `aufx/` are audio effects the offline render engine can load as MixGraph inserts; entries typed \u{201C}Music Effect\u{201D} (`aumf/\u{2026}`) and \u{201C}Music Device\u{201D} (instruments, `aumu/\u{2026}`) are never usable as inserts."]
        if available.isEmpty { out += ["", "- No Audio Units were discovered (inventory not run or none available)."] }
        else {
            let manufacturers = Set(available.map { $0.manufacturer }).count
            out += ["", "- Total: \(available.count) plugins across \(manufacturers) manufacturers."]
            for (manufacturer, plugins) in PluginInventory().groupedByManufacturer(available) {
                out += ["", "### \(manufacturer)"]
                // The FourCC identifier ships in every delivery so the catalogue facts stay identical between
                // variants; the API delivery's MixGraph inserts copy it verbatim as `component`.
                out += plugins.map { "- \($0.name) (\($0.type)) — component `\($0.identifier)`" }
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
    /// A send level is stated only on the scale the knob itself proved, with the proven range next to it: dB when the
    /// knob's AXValueDescription displays dB, the knob's own raw units otherwise — explicitly named, never sold as dB.
    /// An unproven scale keeps the honest requires_probe line: `set_send_level` stays unsupported for that send.
    private func sendLevelLine(_ send: SendFacts) -> String {
        guard let value = send.level.value, let scale = send.levelScale else { return "\(send.level.state.rawValue) (the knob proves no scale — no dB AXValueDescription and no bounded numeric AXValue)" }
        let unit = scale == .decibels ? " dB" : " (raw knob units — the knob's own position on its proven AX scale; Logic exposes no dB for this knob)"
        let range = send.levelRange.map { " · proven range: \(decimalString($0.lowerBound))\u{2026}\(decimalString($0.upperBound))" } ?? ""
        return "known: \(decimalString(value))\(unit)\(range)"
    }
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
    /// The Volume / Pan / Mute / Solo channel facts collected into one table instead of scattered across the
    /// per-track sections: the mix state Logic showed at scan time, in one place the model can read the project
    /// from. States render honestly — a non-known value is named, never blanked and never guessed.
    private func currentControlValuesSection(_ snapshot: NormalizedSnapshot) -> [String] {
        var out = ["", "## Current control values", "", "One row per logical track, restating the Volume / Pan / Mute / Solo channel facts from Track linking diagnostics above in one place — the mix state Logic showed at scan time. Volume is in dB on Logic's fader scale (\u{2212}96\u{2026}+6), Pan in Logic's pan units (\u{2212}64\u{2026}+63, 0 = centre). These values are context for reading the project; the exported WAVs already carry whatever Logic printed into them, so never restate a row as a MixGraph gain without evidence from the measured metrics. A cell that is not a number or boolean names the fact's state; such a value is not evidence and must never be guessed."]
        guard !snapshot.tracks.isEmpty else { out += ["", "- No logical tracks in this snapshot."]; return out }
        func cell<T>(_ fact: Fact<T>?) -> String { guard let fact else { return "unavailable" }; guard let value = fact.value else { return fact.state.rawValue }; return display(value) }
        out += ["", "| logicalTrackID | Logic track name | Volume (dB) | Pan | Mute | Solo |", "| --- | --- | --- | --- | --- | --- |"]
        out += snapshot.tracks.map { track in
            let channel = track.channel
            let name = track.name.value.map { "\u{201C}\($0)\u{201D}" } ?? track.name.state.rawValue
            return "| `\(track.logicalTrackID)` | \(name) | \(cell(channel?.volumeDB)) | \(cell(channel?.pan)) | \(cell(channel?.mute)) | \(cell(channel?.solo)) |"
        }
        let sendRows = snapshot.tracks.flatMap { track in (track.channel?.sends ?? []).map { (track: track, send: $0) } }
        if !sendRows.isEmpty {
            out += ["", "### Send levels", "", "One row per occupied send in the current project — Logic's own send state at scan time, context only. The Scale column names the scale the knob itself proved — `dB`, or `raw knob units` when Logic exposes no dB for that knob (the number is the knob's own position, not decibels). A Level cell that names a state instead of a number means the knob's scale is unproven. MixGraph sends are unrelated to these controls: the engine's buses are defined inside your graph, and their `levelDB` is always dB.", "", "| logicalTrackID | Send destination | Level | Scale | Proven range |", "| --- | --- | --- | --- | --- |"]
            out += sendRows.map { track, send in
                let destination = send.destination.value ?? send.destination.state.rawValue
                let level = send.level.value.map(display) ?? send.level.state.rawValue
                let scale = send.levelScale.map { $0 == .decibels ? "dB" : "raw knob units" } ?? "unproven"
                let range = send.levelRange.map { "\(decimalString($0.lowerBound))\u{2026}\(decimalString($0.upperBound))" } ?? "unavailable"
                return "| `\(track.logicalTrackID)` | \(destination) | \(level) | \(scale) | \(range) |"
            }
        }
        return out
    }
    /// The exact JSON contract the Review screen decodes and validates (`MixPlan` / `MixCommand`). Retained for the
    /// live path, which is currently hidden from the UI: no delivery ships this section — every document teaches the
    /// MixGraph contract instead — but the schema stays here so re-enabling the Review stage restores the teaching.
    private func mixPlanSchemaSection(_ snapshot: NormalizedSnapshot) -> [String] {
        ["", "## Mix Plan schema (machine-validated)", "", "The application validates the pasted Mix Plan technically against the current snapshot — targets must exist in the facts above, every action must carry its typed `parameters.value` inside its control's range, ids must be unique and reasons non-empty. It never judges musical merit. By default (DRY RUN) nothing is written to Logic Pro; the user may explicitly execute valid `set_volume` / `set_pan` / `set_mute` / `set_solo` / `set_send_level` actions LIVE, where the application verifies every write against Logic's own controls and re-scans afterwards — everything else remains the user's instruction sheet to apply by hand.", "", "- `version` is `\"1.0\"` and `status` is `\"ready\"` — a Mix Plan is delivered only after the user confirmed (workflow stage 5).", "- Every field shown in the example is required on every action, and every action carries a `parameters.value` — always the absolute target setting, never a change relative to the current value.", "- Every action `id` must be unique within the plan; a duplicated id is rejected as invalid.", "- `reason` must be one non-empty factual sentence naming the current known value, the absolute target, the direction of the move (up or down) and the evidence; an empty reason is rejected as invalid. Write `reason` in the language the user writes to you in — it is the human-readable justification the Review screen shows the user under each action, the only free text inside the JSON. Everything else in the JSON (keys, action names, ids, track identifiers, numeric values) is machine-matched against the facts and stays exactly as this document states them.", "- `action` must be one of: `set_volume`, `set_pan`, `set_mute`, `set_solo`, `set_send_level`, `set_plugin_bypass`, `set_plugin_parameter`. No other action is implemented; anything else is rejected as unsupported. In particular there is NO action that adds a plug-in — plug-in recommendations stay prose for the user to apply manually (put them in MANUAL STEPS). `set_send_pan` exists in the vocabulary but always validates as unsupported: Logic exposes no send pan control over Accessibility, so its scale can never be proven — send pan changes belong in MANUAL STEPS.", "- `set_volume` and `set_pan` take a numeric `parameters.value`: `set_volume` in dB, the same scale as the Volume channel facts above, within Logic's fader range \u{2212}96\u{2026}+6 dB (to silence a track use `set_mute`, not a huge negative volume); `set_pan` in Logic's pan units as shown in the Pan facts (0 = centre, negative = left, positive = right), within \u{2212}64\u{2026}+63. `set_mute` and `set_solo` take a boolean `parameters.value`; `set_solo` belongs in a delivered plan only when the user explicitly asked for a solo (see the plan composition rules above). A missing, mistyped or out-of-range value is rejected as invalid.", "- `set_volume` and `set_pan` additionally require `parameters.current` — the track's current known value, copied exactly from the Current control values table above — and `parameters.delta` = target \u{2212} current, signed. The validator checks the arithmetic (current + delta = value) and checks `current` against the known channel fact; either mismatch is rejected as invalid. This is the direction proof: a target below `current` makes the track QUIETER, a target above makes it LOUDER. The LUFS/RMS/peak numbers in the audio metrics are measurements of the exported files, never fader positions — never copy a loudness value into `parameters.value`.", "- Target a track with `target.trackID` = the `logicalTrackID` used throughout this document, or `target.trackName` = the exact Logic track name.", "- `set_send_level` additionally needs `target.sendDestination` — the send's Destination fact copied exactly (e.g. \u{201C}Bus 1\u{201D}; a track with two sends to the same destination is rejected as ambiguous). It is executable only for a send whose Level above is a `known` fact: the value, `parameters.current` (copied exactly from the Send levels table) and `parameters.delta` = value \u{2212} current are all on the send's PROVEN scale — dB when the Scale column says dB, the knob's raw units otherwise (raw units are the knob's position, never decibels — do not write dB numbers on a raw-scale send) — and the value must sit inside the send's proven range where one is published. A send whose Level is not `known` validates as unsupported: recommend it in MANUAL STEPS instead.", "- `set_plugin_bypass` (boolean `parameters.value`) and `set_plugin_parameter` additionally need `target.pluginID` or `target.pluginName`, and `set_plugin_parameter` needs `target.parameterID` or `target.parameterName` plus a numeric `parameters.value` inside the parameter's reported range. When no plug-in facts were captured for the track, these validate as `requires_probe`, not as executable actions.", "", "The example below is built from this document's own facts where the snapshot proves them: a real `logicalTrackID` with its real `current` values and exact delta arithmetic. The `reason` texts are teaching templates — every real action replaces them with the factual sentence described above, in the user's language.", "", "```json", exampleJSON(for: snapshot), "```", "", "### Pre-delivery checklist (stage 6)", "", "Check your drafted answer against every line immediately before sending stage 6 — one failed line means the Review screen rejects the action or the user gets an unusable instruction sheet:", "", "1. Under `MIX PLAN` there is exactly one fenced `json` code block, holding nothing but the JSON object: no prose, no comments, no trailing commas, every number a plain JSON number.", "2. `version` is `\"1.0\"`, `status` is `\"ready\"`, every action carries every field of the example, and every `id` is unique within the plan.", "3. Every `target.trackID` is a `logicalTrackID` that exists in this document, copied exactly (the Current control values table lists them all).", "4. Every `set_volume` value lies within \u{2212}96\u{2026}+6 dB at 0.1 dB precision; every `set_pan` value is an integer within \u{2212}64\u{2026}+63; every `set_send_level` targets a send whose Level fact is `known`, carries `target.sendDestination` copied exactly, and its value sits on the send's proven scale inside its proven range; `set_mute` / `set_solo` / `set_plugin_bypass` values are JSON booleans.", "5. On every volume/pan/send-level action `parameters.current` is copied unchanged from the Current control values table (for sends — from the Send levels table; or from the user's answer when the table showed no number), `parameters.delta` equals `value` \u{2212} `current`, and the sign of `delta` matches the direction the `reason` states. `parameters.value` is a control setting — never a LUFS/RMS/peak measurement.", "6. Every `reason` is one self-contained factual sentence naming the current value, the absolute target, the direction and the evidence.", "7. No `set_solo` action exists unless the user explicitly asked for a solo, no `set_send_pan` action exists (it is never executable — send pan is manual), and no action adds a plug-in — plug-in work lives in `MANUAL STEPS`, chosen only from Available Plugins.", "8. Every ISSUE from your analysis is traceable: resolved by a plan action, handled by a `MANUAL STEPS` item, or explicitly closed with the reason it stays as is.", "9. Each `MANUAL STEPS` item names the exact track (real name + logicalTrackID), the exact operation to perform in Logic and the evidence it rests on — or the section reads \u{201C}MANUAL STEPS: none\u{201D}."]
    }
    /// Every delivery's response contract: the exact JSON shape the Assistant (and the manual Render-screen paste)
    /// extracts, dry-validates and hands to the offline `MixEngine` (`MixGraph` 1.0). The document must spell it out,
    /// or the model invents its own shape and the extraction fails with named validation errors instead of a render.
    private func mixGraphSchemaSection(assets: [AudioAsset], plugins: [PluginInventoryItem]) -> [String] {
        ["", "## MixGraph response contract (machine-validated)", "", "The final deliverable: exactly one fenced json code block containing one MixGraph object. The application dry-validates it — structure, file names against the really exported WAVs, send buses, pan ranges, insert identities against Available Plugins — and its own offline engine renders `mix.wav` from the exported files only when the user explicitly presses Render. It never judges musical merit.", "", "- `schemaVersion` is `\"1.0\"` — the engine refuses any other version by name.", "- `tracks`: one entry per WAV you mix. `name` — a unique human-readable label; `file` — the exported WAV's exact file name from Audio Assets; `gainDB` — track gain in dB applied after the insert chain (0 = unity); `pan` — \u{2212}1\u{2026}+1 (0 = centre); `inserts` — Audio Unit effects in processing order; `sends` — post-fader sends into named buses.", "- `sends`: `bus` names a bus defined in `buses` (an unknown name is a named error); `levelDB` — send level in dB (0 = the track's post-fader signal at unity); `pan` — \u{2212}1\u{2026}+1 applied to the sent copy only.", "- `buses`: named effect buses; each sums the sends addressed to it, runs its `inserts`, applies its `gainDB` and feeds the master sum.", "- `master`: `inserts` process the complete sum, then `gainDB` trims the result — applied AFTER the chain, so a limiter's ceiling still holds.", "- Insert identity: `component` — the FourCC identifier `type/subtype/manufacturer` copied exactly from Available Plugins (preferred, exact; its type MUST be `aufx` — the engine loads audio effects only, so `aumf`/`aumu` entries are named validation errors) — or `name`, the installed component name exactly as listed (it must match exactly one installed effect). `parameters` maps a parameter identifier (or its numeric address as a string, or its display name) to a number; every value is set through the unit's AUParameterTree and read back.", "- Every exported WAV covers the timeline from t=0, so alignment is positional by construction: there are no start offsets, and there is no resampling — a sample-rate mismatch between files is a named error, never a silent conversion.", "", "Example (built from this analysis's really exported files" + (assets.contains(where: { $0.actualExportedPath.value != nil }) ? "" : " — none are exported yet, so the honest example is empty") + (plugins.isEmpty ? "; no plugin catalogue was captured, so the example carries no inserts" : "") + "):", "", "```json", exampleMixGraphJSON(assets: assets, plugins: plugins), "```", "", "Checklist before sending the stage-6 reply:", "- Exactly one fenced json code block in the reply — the application takes the LAST one, so a second block would replace your graph.", "- `schemaVersion` is \"1.0\"; every track name and every bus name is unique.", "- Every `file` is copied exactly from an asset's `WAV file` line under Audio Assets.", "- Every send's `bus` is defined in `buses`; every `pan` is within \u{2212}1\u{2026}+1.", "- Every insert's `component` is copied exactly from the Available Plugins catalogue and starts with `aufx/`."]
    }
    /// The example must survive the same dry validation the real reply gets, so it is built only from files that were
    /// really exported (their actual file names) and an insert only from the really installed effect catalogue; with
    /// nothing exported the honest example is empty rather than a fabricated file the render would reject.
    private func exampleMixGraphJSON(assets: [AudioAsset], plugins: [PluginInventoryItem]) -> String {
        let exported = assets.compactMap { asset in asset.actualExportedPath.value.map { (name: asset.trackName.value ?? asset.logicalTrackID, file: ($0 as NSString).lastPathComponent) } }
        guard let first = exported.first else { return Self.emptyMixGraphExampleJSON }
        let insert = plugins.first { $0.identifier.hasPrefix("aufx/") }
        let insertJSON = insert.map { " { \"component\": \"\($0.identifier)\", \"parameters\": {} } " } ?? ""
        var tracks = ["""
    {
      "name": "\(first.name)",
      "file": "\(first.file)",
      "gainDB": 0,
      "pan": 0,
      "inserts": [\(insertJSON)],
      "sends": []
    }
"""]
        if let second = exported.dropFirst().first(where: { $0.name != first.name && $0.file != first.file }) {
            tracks.append("""
    {
      "name": "\(second.name)",
      "file": "\(second.file)",
      "gainDB": -1.5,
      "pan": 0,
      "inserts": [],
      "sends": [ { "bus": "Reverb", "levelDB": -12, "pan": 0 } ]
    }
""")
        }
        let buses = tracks.count > 1 ? " { \"name\": \"Reverb\", \"gainDB\": 0, \"inserts\": [] } " : ""
        return """
{
  "schemaVersion": "1.0",
  "tracks": [
\(tracks.joined(separator: ",\n"))
  ],
  "buses": [\(buses)],
  "master": { "gainDB": 0, "inserts": [] }
}
"""
    }
    static let emptyMixGraphExampleJSON = """
{
  "schemaVersion": "1.0",
  "tracks": [],
  "buses": [],
  "master": { "gainDB": 0, "inserts": [] }
}
"""
    /// Models copy the example verbatim, so every sample action must target a real track and use a current value from
    /// this snapshot. Include whichever of Volume and Pan are proven for the first usable track; if neither control is
    /// known anywhere, an empty action list is the only honest valid example. Numbers use the table's formatter.
    private func exampleJSON(for snapshot: NormalizedSnapshot) -> String {
        guard let track = snapshot.tracks.first(where: { $0.channel?.volumeDB.value != nil || $0.channel?.pan.value != nil }), let channel = track.channel else { return Self.emptyMixPlanExampleJSON }
        let reason = "One factual sentence naming the current known value, the absolute target, the direction of the move and the evidence above, in the user's language"
        var actions: [String] = []
        if let volume = channel.volumeDB.value {
            let delta: Double = volume - 1 >= CommandValidator.volumeRangeDB.lowerBound ? -1 : 1
            actions.append("""
    {
      "id": "action_001",
      "target": { "trackID": "\(track.logicalTrackID)" },
      "action": "set_volume",
      "parameters": { "value": \(decimalString(volume + delta)), "current": \(decimalString(volume)), "delta": \(decimalString(delta)) },
      "reason": "\(reason)"
    }
""")
        }
        if let pan = channel.pan.value {
            let delta: Double = pan - 20 >= CommandValidator.panRange.lowerBound ? -20 : 20
            actions.append("""
    {
      "id": "action_\(String(format: "%03d", actions.count + 1))",
      "target": { "trackID": "\(track.logicalTrackID)" },
      "action": "set_pan",
      "parameters": { "value": \(decimalString(pan + delta)), "current": \(decimalString(pan)), "delta": \(decimalString(delta)) },
      "reason": "\(reason)"
    }
""")
        }
        return """
{
  "version": "1.0",
  "status": "ready",
  "actions": [
\(actions.joined(separator: ",\n"))
  ]
}
"""
    }
    static let emptyMixPlanExampleJSON = """
{
  "version": "1.0",
  "status": "ready",
  "actions": []
}
"""
}
