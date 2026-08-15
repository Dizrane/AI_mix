import Foundation

// MARK: - Plan-target verification against a fresh post-apply scan

/// The three honest outcomes of checking one applied action against the re-read facts. `unverifiable` is a first-class
/// outcome, not a soft failure: a fact the fresh scan does not prove is stated as such and never guessed into a result —
/// no check can turn a non-known fact into a false known.
enum PlanCheckOutcome: String, Codable, Sendable { case matched, mismatched, unverifiable }

/// One applied plan action compared with the fact a fresh read-only scan captured for the same control: the plan's
/// absolute target against the re-read known value, tolerance 0.05 — the validator's own.
struct PlanTargetCheck: Codable, Identifiable, Sendable {
    var actionID: String
    var action: String
    var trackLabel: String
    var planValue: String
    var rereadValue: String
    var outcome: PlanCheckOutcome
    var note: String
    var id: String { actionID }
}

/// Verifies a validated plan against a POST-APPLY snapshot: which targets the fresh known facts now match. Pure —
/// it reads two in-memory structures and writes nothing, so the same arithmetic is testable without Logic.
struct PlanVerifier: Sendable {
    /// The one tolerance across the product: the validator's 0.05, matching the 0.1 precision of Logic's controls.
    static let tolerance = 0.05
    /// Only actions the validator marked `valid` are checked — they are the ones the user (or the live adapter) was
    /// instructed to apply; everything else never became an instruction.
    func verify(_ commands: [ValidatedCommand], against snapshot: NormalizedSnapshot) -> [PlanTargetCheck] {
        commands.filter { $0.status == .valid }.map { check($0.command, snapshot: snapshot) }
    }
    private func check(_ command: MixCommand, snapshot: NormalizedSnapshot) -> PlanTargetCheck {
        let label = command.target.trackName ?? command.target.trackID ?? "—"
        func result(plan: String, reread: String, outcome: PlanCheckOutcome, note: String = "") -> PlanTargetCheck {
            .init(actionID: command.id, action: command.action.rawValue, trackLabel: label, planValue: plan, rereadValue: reread, outcome: outcome, note: note)
        }
        guard let track = snapshot.tracks.first(where: { $0.id == command.target.trackID || ($0.name.value != nil && $0.name.value == command.target.trackName) }) else {
            return result(plan: planValueText(command), reread: "—", outcome: .unverifiable, note: "the track is not present in the fresh scan")
        }
        switch command.action {
        case .setVolume: return numeric(command, fact: track.channel?.volumeDB, factName: "Volume", unit: " dB", label: trackLabel(track))
        case .setPan: return numeric(command, fact: track.channel?.pan, factName: "Pan", unit: "", label: trackLabel(track))
        case .setMute: return boolean(command, fact: track.channel?.mute, factName: "Mute", label: trackLabel(track))
        case .setSolo: return boolean(command, fact: track.channel?.solo, factName: "Solo", label: trackLabel(track))
        case .setSendLevel:
            // A send is re-identified across scans only by its Destination fact (send ids embed AX paths, which shift);
            // an absent or ambiguous destination is stated as such — never guessed into a comparison.
            guard let destination = command.target.sendDestination else {
                return .init(actionID: command.id, action: command.action.rawValue, trackLabel: trackLabel(track), planValue: planValueText(command), rereadValue: "—", outcome: .unverifiable, note: "the action names no target.sendDestination to re-identify the send by")
            }
            let matches = (track.channel?.sends ?? []).filter { $0.destination.value?.localizedCaseInsensitiveCompare(destination) == .orderedSame }
            guard matches.count == 1 else {
                return .init(actionID: command.id, action: command.action.rawValue, trackLabel: trackLabel(track), planValue: planValueText(command), rereadValue: "—", outcome: .unverifiable, note: matches.isEmpty ? "no occupied send to \u{2018}\(destination)\u{2019} exists in the fresh scan" : "the fresh scan shows \(matches.count) sends to \u{2018}\(destination)\u{2019} — ambiguous, not guessed")
            }
            return numeric(command, fact: matches[0].level, factName: "Send level", unit: matches[0].levelScale == .decibels ? " dB" : "", label: trackLabel(track))
        default:
            return .init(actionID: command.id, action: command.action.rawValue, trackLabel: trackLabel(track), planValue: planValueText(command), rereadValue: "—", outcome: .unverifiable, note: "no re-readable channel fact exists for this action; verify it by hand")
        }
    }
    private func numeric(_ command: MixCommand, fact: Fact<Double>?, factName: String, unit: String, label: String) -> PlanTargetCheck {
        let plan = command.parameters["value"]?.numberValue
        let planText = plan.map { decimalString($0) + unit } ?? "—"
        func result(_ reread: String, _ outcome: PlanCheckOutcome, _ note: String = "") -> PlanTargetCheck {
            .init(actionID: command.id, action: command.action.rawValue, trackLabel: label, planValue: planText, rereadValue: reread, outcome: outcome, note: note)
        }
        guard let plan else { return result("—", .unverifiable, "the action carries no numeric parameters.value") }
        guard let fact, let value = fact.value else {
            return result(fact.map { $0.state.rawValue } ?? "unavailable", .unverifiable, "\(factName) is not a known fact in the fresh scan — stated as such, never guessed")
        }
        let matched = abs(value - plan) <= Self.tolerance
        return result(decimalString(value) + unit, matched ? .matched : .mismatched, matched ? "" : "the re-read fact differs from the plan's target by \(decimalString(abs(value - plan)))\(unit)")
    }
    private func boolean(_ command: MixCommand, fact: Fact<Bool>?, factName: String, label: String) -> PlanTargetCheck {
        let plan = command.parameters["value"]?.boolValue
        let planText = plan.map { $0 ? "on" : "off" } ?? "—"
        func result(_ reread: String, _ outcome: PlanCheckOutcome, _ note: String = "") -> PlanTargetCheck {
            .init(actionID: command.id, action: command.action.rawValue, trackLabel: label, planValue: planText, rereadValue: reread, outcome: outcome, note: note)
        }
        guard let plan else { return result("—", .unverifiable, "the action carries no boolean parameters.value") }
        guard let fact, let value = fact.value else {
            return result(fact.map { $0.state.rawValue } ?? "unavailable", .unverifiable, "\(factName) is not a known fact in the fresh scan — stated as such, never guessed")
        }
        return result(value ? "on" : "off", value == plan ? .matched : .mismatched, value == plan ? "" : "the re-read state is not the plan's target")
    }
    private func planValueText(_ command: MixCommand) -> String {
        if let number = command.parameters["value"]?.numberValue { return decimalString(number) }
        if let flag = command.parameters["value"]?.boolValue { return flag ? "on" : "off" }
        return "—"
    }
    private func trackLabel(_ track: TrackFacts) -> String { track.name.value.map { "\u{201C}\($0)\u{201D} (`\(track.logicalTrackID)`)" } ?? "`\(track.logicalTrackID)`" }
    private func decimalString(_ number: Double) -> String { var text = String(format: "%.2f", number); while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() }; return text == "-0" ? "0" : text }
}

// MARK: - Before/after audio metrics comparison

/// The measurements of one file frozen when the verification cycle started — the pre-apply state the new exports are
/// compared against. `id` is the asset's logicalTrackID, or "mix" for the bounced Stereo Out.
struct MetricsBaselineEntry: Codable, Sendable { var id: String; var label: String; var metrics: AudioMetrics }

/// One before/after row of the metrics the plan is judged by: integrated loudness, true peak, clipping. Both sides are
/// real measurements of real files (the metrics cache keys by file identity, so an unchanged file keeps its numbers and
/// a re-exported one is honestly re-measured); nothing here extrapolates what a fader move "should" have done.
struct MetricsDelta: Codable, Identifiable, Sendable {
    var id: String
    var label: String
    var lufsBefore: Double?; var lufsAfter: Double?
    var truePeakBefore: Double?; var truePeakAfter: Double?
    var clippedBefore: Int?; var clippedAfter: Int?
    /// True when any compared pair differs beyond the display precision — i.e. the file was really re-measured as changed.
    var changed: Bool
}

/// Pure join of the frozen baseline with the current assets' metrics, by identity: rows exist only where BOTH sides
/// were really measured. A missing after-side (the file disappeared or was never re-analyzed) yields no row rather
/// than a fabricated one.
enum MetricsComparison {
    static func compare(baseline: [MetricsBaselineEntry], assets: [AudioAsset], mix: MixBounceAsset?) -> [MetricsDelta] {
        var after: [String: (label: String, metrics: AudioMetrics)] = [:]
        for asset in assets { if let metrics = asset.metrics { after[asset.logicalTrackID] = (asset.trackName.value ?? asset.logicalTrackID, metrics) } }
        if let mix, let metrics = mix.metrics { after["mix"] = ("Mix (Stereo Out)", metrics) }
        return baseline.compactMap { entry in
            guard let current = after[entry.id] else { return nil }
            func differs(_ a: Double?, _ b: Double?) -> Bool { switch (a, b) { case (nil, nil): false; case let (x?, y?): abs(x - y) > 0.05; default: true } }
            let old = entry.metrics; let new = current.metrics
            let changed = differs(old.integratedLoudnessLUFS.value, new.integratedLoudnessLUFS.value)
                || differs(old.truePeakDBTP.value, new.truePeakDBTP.value)
                || old.clippedSampleCount.value != new.clippedSampleCount.value
            return MetricsDelta(id: entry.id, label: entry.label,
                                lufsBefore: old.integratedLoudnessLUFS.value, lufsAfter: new.integratedLoudnessLUFS.value,
                                truePeakBefore: old.truePeakDBTP.value, truePeakAfter: new.truePeakDBTP.value,
                                clippedBefore: old.clippedSampleCount.value, clippedAfter: new.clippedSampleCount.value,
                                changed: changed)
        }
    }
}

// MARK: - Everything the post-apply AI package states about the cycle

/// The record the second-round AI package is built from: the previous plan was applied (LIVE or by hand), a fresh scan
/// re-read the facts, and these are the verification results. The package marks itself as a post-apply snapshot so the
/// model runs a second circle on the fresh evidence instead of re-analyzing a stale state.
struct PostApplyReport: Sendable {
    var verifiedAt: Date
    var executedLive: Bool
    var checks: [PlanTargetCheck]
    var diff: SnapshotDiff
    var metricDeltas: [MetricsDelta]
}
