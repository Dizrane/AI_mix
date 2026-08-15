import Foundation
import ApplicationServices
import AppKit

// MARK: - Pure, testable calibration math

/// The scale a Logic channel slider was PROVEN to use at execution time, decided from same-moment evidence: the
/// slider's own AXValue against the dB the strip's "volume fader level" text displays. A real Logic dump shows the
/// fader publishing raw units (AXValue 173 while the level text reads 0.0 dB), so the scale is never assumed — a
/// slider whose AXValue equals the displayed dB (within the app-wide 0.05 tolerance) is on the dB scale and can be
/// written directly; anything else is `raw` and every write must go through the measured servo calibration below.
enum FaderScale: Equatable, Sendable {
    case decibels, raw
    static let tolerance = 0.05
    static func detect(sliderValue: Double, displayedDB: Double) -> FaderScale {
        abs(sliderValue - displayedDB) <= tolerance ? .decibels : .raw
    }
}

/// The dB↔raw mapping for a raw-scale fader, built from measurements instead of a guessed formula: Logic documents no
/// AXValue curve for its fader, so the only honest mapping is the one measured on the very control being written.
/// `step` is a pure function deciding the next raw position from the (raw, displayed dB) pairs measured so far — a
/// secant iteration on the measured points, bounded and capped — and it converges only when the control itself
/// displays the target dB within tolerance. Every reading the caller feeds in must be a real re-read; the function
/// never extrapolates a result it did not measure, and it gives up with a named reason instead of oscillating.
struct FaderServoMath {
    enum Step: Equatable, Sendable { case converged; case move(raw: Double); case failed(reason: String) }
    /// The displayed level text quantizes to 0.1 dB, so two nearby raw positions can legally display the same dB; a
    /// slope is therefore computed only from a pair of points whose displayed values actually differ.
    static func step(points: [(raw: Double, db: Double)], targetDB: Double, range: ClosedRange<Double>, tolerance: Double = 0.05, maxMeasurements: Int = 12) -> Step {
        guard let last = points.last else { return .failed(reason: "no measurement was taken before stepping") }
        if abs(last.db - targetDB) <= tolerance { return .converged }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return .failed(reason: "the slider reports an empty AXMinValue…AXMaxValue range") }
        if points.count >= maxMeasurements { return .failed(reason: "the fader did not reach \(targetDB) dB within \(maxMeasurements) verified measurements (last displayed value: \(last.db) dB)") }
        let minimalMove = span * 0.001
        // A fader whose displayed dB never changed across real raw travel is not behaving like a fader — stop instead
        // of walking it further.
        let allRaw = points.map { $0.raw }; let allDB = points.map { $0.db }
        if points.count >= 3, (allRaw.max()! - allRaw.min()!) >= span * 0.05, allDB.allSatisfy({ $0 == last.db }) {
            return .failed(reason: "the displayed dB did not respond while the raw value travelled \(allRaw.max()! - allRaw.min()!) units — the control does not behave like a fader")
        }
        // Local secant: the nearest earlier point whose displayed dB genuinely differs from the latest reading.
        let partner = points.dropLast()
            .filter { abs($0.raw - last.raw) > minimalMove && abs($0.db - last.db) >= tolerance }
            .min(by: { abs($0.raw - last.raw) < abs($1.raw - last.raw) })
        if let partner {
            let slope = (last.db - partner.db) / (last.raw - partner.raw)
            var next = last.raw + (targetDB - last.db) / slope
            let maxJump = span * 0.25 // a locally flat curve must not fling the fader across its travel
            next = min(max(next, last.raw - maxJump), last.raw + maxJump)
            next = min(max(next, range.lowerBound), range.upperBound)
            if abs(next - last.raw) <= minimalMove {
                return .failed(reason: "the servo stalled at raw \(last.raw) (displayed \(last.db) dB) without reaching \(targetDB) dB — the target may lie outside the fader's travel")
            }
            return .move(raw: next)
        }
        // No usable slope yet: probe with a small, reversible step. Direction assumes dB grows with raw — the very
        // next measurement either confirms it or gives the secant a real slope to correct with.
        let direction: Double = targetDB > last.db ? 1 : -1
        var next = min(max(last.raw + direction * span * 0.02, range.lowerBound), range.upperBound)
        if abs(next - last.raw) <= minimalMove { next = min(max(last.raw - direction * span * 0.02, range.lowerBound), range.upperBound) } // pinned at a bound: probe the other way
        if abs(next - last.raw) <= minimalMove { return .failed(reason: "the slider cannot move in either direction from raw \(last.raw)") }
        return .move(raw: next)
    }
}

/// The caption grammar of the channel-strip controls this adapter is allowed to touch, verified against a real Logic
/// mixer dump: the strip's direct children are captioned exactly "mute", "solo", "volume fader", "volume fader level"
/// and "pan". Strict whole-caption equality on purpose — a caption merely containing the word ("input monitoring"
/// contains no "pan", but a hypothetical "expand" does) must never be pressed or written.
struct StripControlGrammar {
    static func matches(_ caption: String?, _ expected: String) -> Bool {
        guard let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else { return false }
        return caption.localizedCaseInsensitiveCompare(expected) == .orderedSame
    }
    /// The same tolerant decimal parsing the normalizer applies to Logic's level texts ("volume fader level, -1,5 dB"):
    /// comma decimals normalized, the first parseable number wins.
    static func decimal(_ text: String?) -> Double? {
        guard let text else { return nil }
        return text.replacingOccurrences(of: ",", with: ".").split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).compactMap { Double($0) }.first
    }
    /// Logic publishes switch positions as "1"/"on" and "0"/"off" — the same grammar the normalizer trusts for facts.
    static func boolValue(_ value: String?) -> Bool? {
        guard let value else { return nil }
        if value == "1" || value.localizedCaseInsensitiveCompare("on") == .orderedSame { return true }
        if value == "0" || value.localizedCaseInsensitiveCompare("off") == .orderedSame { return false }
        return nil
    }
}

// MARK: - The live channel-strip adapter

/// The verified live adapter: volume, pan, mute, solo and send level on a Mixer channel strip. Discipline:
/// - the strip is located from live AX evidence (the snapshot's captured AX path first, verified by the strip's own
///   caption; a unique-name search across the live Mixer as fallback) — never guessed, never by coordinates;
/// - mute/solo use the documented AXPress on the strip's own captioned control and the switch is believed only after
///   re-reading the value;
/// - volume/pan write AXValue, and every volume write is calibrated first: the slider's scale is proven from
///   same-moment evidence (AXValue vs the displayed dB text), the write mechanism is proven with an idempotent
///   read → set(same value) → read, a raw-scale fader is driven by the measured servo (never a guessed curve), and a
///   write that does not verify is rolled back to the original position before the failure is reported;
/// - nothing else on the strip is ever touched.
struct LogicChannelStripAdapter: LiveActionAdapter {
    private let supportedActions: Set<MixAction> = [.setVolume, .setPan, .setMute, .setSolo, .setSendLevel]
    private let supportedBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]
    /// One tolerance across the product: the validator's 0.05, matching the 0.1 precision Logic's controls display.
    static let tolerance = 0.05
    /// The plan's direction proof (`parameters.current`) was validated against the snapshot; before a live write the
    /// same number must still match the control's own live reading — a project that drifted since the analysis
    /// silently invalidates every delta and reason the model argued with, so the write is refused instead of applied
    /// to a state nobody reasoned about. Returns nil when the plan carries no `current` or the reading still matches.
    static func stalenessRefusal(planCurrent: Double?, live: Double, control: String, unit: String) -> String? {
        guard let planCurrent, abs(planCurrent - live) > tolerance else { return nil }
        return "\(control) reads \(live)\(unit) live but the plan's parameters.current says \(planCurrent)\(unit) — the project changed since the analysis. Rescan and validate the plan again."
    }

    func supports(_ action: MixAction) -> Bool { supportedActions.contains(action) }

    func execute(_ command: MixCommand, context: LiveExecutionContext) -> ExecutionResult {
        func failure(_ message: String) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: nil, after: nil, error: message) }
        guard let track = context.snapshot.tracks.first(where: { $0.id == command.target.trackID || ($0.name.value != nil && $0.name.value == command.target.trackName) }) else { return failure("Track is not present in the current normalized facts.") }
        guard let channelPath = track.axPaths.channel, let name = track.name.value else { return failure("Track \u{2018}\(track.logicalTrackID)\u{2019} has no captured Mixer channel strip — live execution needs the strip's own controls.") }
        guard AXIsProcessTrusted() else { return failure("Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated && ($0.bundleIdentifier.map(supportedBundleIDs.contains) == true || $0.localizedName == "Logic Pro") }) else { return failure("Logic Pro is not running.") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let strip: AXUIElement
        switch resolveStrip(named: name, capturedPath: channelPath, in: appElement) {
        case .failed(let reason): return failure(reason)
        case .resolved(let element): strip = element
        }
        switch command.action {
        case .setMute: return toggle(command, strip: strip, control: "mute")
        case .setSolo: return toggle(command, strip: strip, control: "solo")
        case .setVolume: return setVolume(command, strip: strip)
        case .setPan: return setPan(command, strip: strip)
        case .setSendLevel: return setSendLevel(command, strip: strip)
        default: return failure("No verified live Logic adapter is installed for this action.")
        }
    }

    // MARK: Strip resolution

    private enum StripResolution { case resolved(AXUIElement), failed(String) }
    /// Resolves the live AXUIElement of the strip the snapshot captured. The captured AX path (child indices from the
    /// application element) is walked first and trusted only when the element it lands on still carries the strip's
    /// exact caption and a volume-fader slider; when the path has gone stale, the live Mixer areas are searched for a
    /// strip with that exact caption, and only a UNIQUE match is accepted — two same-named strips are ambiguous and
    /// refused, exactly as the normalizer refuses to link them.
    private func resolveStrip(named name: String, capturedPath: String, in appElement: AXUIElement) -> StripResolution {
        if let walked = element(at: capturedPath, from: appElement), isStrip(walked, named: name) { return .resolved(walked) }
        let candidates = liveMixerStrips(in: appElement).filter { StripControlGrammar.matches(string($0, kAXDescriptionAttribute), name) }
        switch candidates.count {
        case 1: return .resolved(candidates[0])
        case 0: return .failed("Channel strip \u{2018}\(name)\u{2019} was not found in Logic's live Mixer — the captured AX path is stale and no strip carries that caption. Rescan and validate the plan again.")
        default: return .failed("Channel strip \u{2018}\(name)\u{2019} is ambiguous in Logic's live Mixer (\(candidates.count) strips carry that caption) — refusing to guess which one the plan means.")
        }
    }
    /// Walks a captured AX path ("application.3.0.15…"): each numeric segment indexes into the live children array.
    private func element(at path: String, from appElement: AXUIElement) -> AXUIElement? {
        let segments = path.split(separator: ".")
        guard segments.first == "application" else { return nil }
        var current = appElement
        for segment in segments.dropFirst() {
            guard let index = Int(segment) else { return nil }
            let kids = children(current)
            guard kids.indices.contains(index) else { return nil }
            current = kids[index]
        }
        return current
    }
    private func isStrip(_ element: AXUIElement, named name: String) -> Bool {
        role(element) == "AXLayoutItem"
            && StripControlGrammar.matches(string(element, kAXDescriptionAttribute), name)
            && children(element).contains { role($0) == "AXSlider" && StripControlGrammar.matches(string($0, kAXDescriptionAttribute) ?? string($0, kAXTitleAttribute), "volume fader") }
    }
    /// Every strip in the live Mixer, using the same structural evidence as the normalizer: an AXLayoutArea described
    /// "mixer" whose AXLayoutItem children carry a volume-fader slider. The area with the most strips is the real
    /// Mixer (the inspector mirrors the selected strip in a smaller "mixer" area); strips from smaller areas are added
    /// only when the main area shows no strip with their caption, so a mirror never doubles a name into ambiguity.
    private func liveMixerStrips(in appElement: AXUIElement) -> [AXUIElement] {
        var areas: [[AXUIElement]] = []
        var visited = 0
        var queue: [(element: AXUIElement, depth: Int)] = windows(appElement).map { ($0, 0) }
        while !queue.isEmpty && visited < 60_000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if role(element) == "AXLayoutArea", string(element, kAXDescriptionAttribute)?.localizedCaseInsensitiveContains("mixer") == true {
                areas.append(children(element).filter { candidate in
                    role(candidate) == "AXLayoutItem" && (string(candidate, kAXDescriptionAttribute)?.isEmpty == false)
                        && children(candidate).contains { role($0) == "AXSlider" && StripControlGrammar.matches(string($0, kAXDescriptionAttribute) ?? string($0, kAXTitleAttribute), "volume fader") }
                })
                continue // the area's strips are captured; no need to enqueue its thousands of grandchildren
            }
            if depth < 14 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
        }
        guard let mainIndex = areas.indices.max(by: { areas[$0].count < areas[$1].count }) else { return [] }
        var strips = areas[mainIndex]
        var names = Set(strips.compactMap { string($0, kAXDescriptionAttribute)?.localizedLowercase })
        for (index, area) in areas.enumerated() where index != mainIndex {
            for strip in area {
                guard let name = string(strip, kAXDescriptionAttribute)?.localizedLowercase else { continue }
                if names.insert(name).inserted { strips.append(strip) }
            }
        }
        return strips
    }

    // MARK: Mute / solo — AXPress with re-read

    private func toggle(_ command: MixCommand, strip: AXUIElement, control caption: String) -> ExecutionResult {
        func failure(_ message: String) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: nil, after: nil, error: message) }
        guard let target = command.parameters["value"]?.boolValue else { return failure("\(command.action.rawValue) needs a boolean parameters.value.") }
        switch uniqueChild(of: strip, caption: caption, roles: ["AXButton", "AXCheckBox"]) {
        case .failed(let reason): return failure(reason)
        case .resolved(let element):
            guard let before = StripControlGrammar.boolValue(string(element, kAXValueAttribute)) else { return failure("The \(caption) control's value does not read as a switch position.") }
            if before == target { return .init(actionID: command.id, status: ExecutionStatus.executed, before: .bool(before), after: .bool(before), error: nil) }
            guard press(element) else { return failure("AXPress on the \(caption) control did not succeed.") }
            // Proof over trust: the toggle counts only when the control itself re-reads as the target state.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                usleep(100_000)
                if let after = StripControlGrammar.boolValue(string(element, kAXValueAttribute)), after == target {
                    return .init(actionID: command.id, status: ExecutionStatus.executed, before: .bool(before), after: .bool(after), error: nil)
                }
            }
            return failure("The \(caption) control still reads \(before ? "on" : "off") after AXPress — the press was not accepted.")
        }
    }

    // MARK: Pan — AXValue write with idempotent proof and rollback

    private func setPan(_ command: MixCommand, strip: AXUIElement) -> ExecutionResult {
        func failure(_ message: String, before: Double? = nil) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: before.map { JSONValue.number($0) }, after: nil, error: message) }
        guard let target = command.parameters["value"]?.numberValue else { return failure("set_pan needs a numeric parameters.value.") }
        switch uniqueChild(of: strip, caption: "pan", roles: ["AXSlider"]) {
        case .failed(let reason): return failure(reason)
        case .resolved(let slider):
            guard let before = number(slider, kAXValueAttribute) else { return failure("The pan control's AXValue does not read as a number.") }
            if let stale = Self.stalenessRefusal(planCurrent: command.parameters["current"]?.numberValue, live: before, control: "Pan", unit: "") { return failure(stale, before: before) }
            if abs(before - target) <= Self.tolerance { return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(before), after: .number(before), error: nil) }
            // The pan facts (and the validator's −64…+63 range) come from this control's own AXValue, so the scale is
            // the fact scale by construction — but the write mechanism is still proven idempotently before moving it.
            if let refusal = proveIdempotentWrite(slider, value: before, read: { self.number(slider, kAXValueAttribute) }) { return failure(refusal, before: before) }
            guard setNumber(slider, target) else { return failure("Writing the pan target over AXValue was rejected.", before: before) }
            if let after = awaitValue(read: { self.number(slider, kAXValueAttribute) }, near: target) {
                return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(before), after: .number(after), error: nil)
            }
            let observed = number(slider, kAXValueAttribute)
            let restored = setNumber(slider, before) && awaitValue(read: { self.number(slider, kAXValueAttribute) }, near: before) != nil
            return failure("The pan control reads \(observed.map { String($0) } ?? "unreadable") after writing \(target) — the value did not verify. \(restored ? "The knob was restored to its original position \(before)." : "RESTORING the original position \(before) also failed — check the strip in Logic.")", before: before)
        }
    }

    // MARK: Volume — scale calibration, then a verified write on the proven scale

    private func setVolume(_ command: MixCommand, strip: AXUIElement) -> ExecutionResult {
        func failure(_ message: String, before: Double? = nil) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: before.map { JSONValue.number($0) }, after: nil, error: message) }
        guard let target = command.parameters["value"]?.numberValue else { return failure("set_volume needs a numeric parameters.value.") }
        let slider: AXUIElement
        switch uniqueChild(of: strip, caption: "volume fader", roles: ["AXSlider"]) {
        case .failed(let reason): return failure(reason)
        case .resolved(let element): slider = element
        }
        // The displayed dB is the same evidence the Volume facts come from; without it no write can be verified.
        guard let level = children(strip).first(where: { StripControlGrammar.matches(string($0, kAXDescriptionAttribute), "volume fader level") }) else { return failure("The strip exposes no \u{2018}volume fader level\u{2019} text — a volume write could not be verified, so none is attempted.") }
        func displayedDB() -> Double? { StripControlGrammar.decimal(string(level, kAXTitleAttribute) ?? string(level, kAXValueAttribute)) }
        guard let rawBefore = number(slider, kAXValueAttribute) else { return failure("The volume fader's AXValue does not read as a number.") }
        guard let dbBefore = displayedDB() else { return failure("The strip's \u{2018}volume fader level\u{2019} text does not read as a dB number.") }
        if let stale = Self.stalenessRefusal(planCurrent: command.parameters["current"]?.numberValue, live: dbBefore, control: "Volume", unit: " dB") { return failure(stale, before: dbBefore) }
        return calibratedDBWrite(command, control: "fader", slider: slider, displayed: displayedDB, rawBefore: rawBefore, dbBefore: dbBefore, target: target)
    }

    // MARK: Send level — the knob is written only on the scale the facts proved

    /// Writes one send knob. The send is located by the same structural evidence the normalizer publishes the fact
    /// from — the destination-captioned AXGroup holding a "bypass" checkbox, with the "send knob" AXSlider directly
    /// after it — and the write runs on the scale the knob itself proves live: its AXValueDescription displaying dB
    /// (direct write or measured servo, verified against that description), or the knob's bare AXValue on its own
    /// bounded raw scale (the validator's range came from those bounds). A knob proving neither scale is refused.
    private func setSendLevel(_ command: MixCommand, strip: AXUIElement) -> ExecutionResult {
        func failure(_ message: String, before: Double? = nil) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: before.map { JSONValue.number($0) }, after: nil, error: message) }
        guard let target = command.parameters["value"]?.numberValue else { return failure("set_send_level needs a numeric parameters.value.") }
        guard let destination = command.target.sendDestination?.trimmingCharacters(in: .whitespacesAndNewlines), !destination.isEmpty else { return failure("set_send_level needs target.sendDestination naming the send's Destination fact.") }
        let kids = children(strip)
        let groups = kids.enumerated().filter { _, child in
            role(child) == "AXGroup" && StripControlGrammar.matches(string(child, kAXDescriptionAttribute), destination)
                && children(child).contains { role($0) == "AXCheckBox" && StripControlGrammar.matches(string($0, kAXDescriptionAttribute), "bypass") }
        }
        guard groups.count == 1 else { return failure(groups.isEmpty ? "No occupied send to \u{2018}\(destination)\u{2019} was found on the live strip — rescan and validate the plan again." : "The live strip shows \(groups.count) sends to \u{2018}\(destination)\u{2019} — refusing to guess which knob to write.") }
        let index = groups[0].offset
        guard kids.indices.contains(index + 1), role(kids[index + 1]) == "AXSlider", StripControlGrammar.matches(string(kids[index + 1], kAXDescriptionAttribute) ?? string(kids[index + 1], kAXTitleAttribute), "send knob") else { return failure("The send to \u{2018}\(destination)\u{2019} exposes no \u{2018}send knob\u{2019} slider directly after its group — the knob cannot be located, refusing to write.") }
        let knob = kids[index + 1]
        guard let rawBefore = number(knob, kAXValueAttribute) else { return failure("The send knob's AXValue does not read as a number.") }
        func describedDB() -> Double? {
            guard let text = string(knob, kAXValueDescriptionAttribute), text.localizedCaseInsensitiveContains("db") else { return nil }
            return StripControlGrammar.decimal(text)
        }
        if let dbBefore = describedDB() {
            if let stale = Self.stalenessRefusal(planCurrent: command.parameters["current"]?.numberValue, live: dbBefore, control: "Send level", unit: " dB") { return failure(stale, before: dbBefore) }
            return calibratedDBWrite(command, control: "send knob", slider: knob, displayed: describedDB, rawBefore: rawBefore, dbBefore: dbBefore, target: target)
        }
        // No dB is displayed anywhere on this knob, so the only proven scale is the knob's own AXValue — the exact
        // scale the fact (and the plan's target) is on. The write mechanism is still proven idempotently first.
        if let stale = Self.stalenessRefusal(planCurrent: command.parameters["current"]?.numberValue, live: rawBefore, control: "Send level", unit: " (raw knob units)") { return failure(stale, before: rawBefore) }
        if abs(rawBefore - target) <= Self.tolerance { return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(rawBefore), after: .number(rawBefore), error: nil) }
        if let refusal = proveIdempotentWrite(knob, value: rawBefore, read: { self.number(knob, kAXValueAttribute) }) { return failure(refusal, before: rawBefore) }
        guard setNumber(knob, target) else { return failure("Writing the send level target over AXValue was rejected.", before: rawBefore) }
        if let after = awaitValue(read: { self.number(knob, kAXValueAttribute) }, near: target) {
            return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(rawBefore), after: .number(after), error: nil)
        }
        let observed = number(knob, kAXValueAttribute)
        let restored = setNumber(knob, rawBefore) && awaitValue(read: { self.number(knob, kAXValueAttribute) }, near: rawBefore) != nil
        return failure("The send knob reads \(observed.map { String($0) } ?? "unreadable") after writing \(target) — the value did not verify. \(restored ? "The knob was restored to its original position \(rawBefore)." : "RESTORING the original position \(rawBefore) also failed — check the strip in Logic.")", before: rawBefore)
    }

    // MARK: The shared calibrated dB write (volume fader, dB-displaying send knob)

    /// Everything after the staleness gate for a dB-verified slider write: mechanism proof (idempotent read → set(the
    /// same value) → read, with the displayed dB required unchanged), scale detection from same-moment evidence, a
    /// direct verified write on the proven dB scale, the measured servo on the raw scale, and rollback with a named
    /// reason on every failure. `displayed` must re-read the control's own dB display — success is only ever claimed
    /// from that re-read, never from the written number.
    private func calibratedDBWrite(_ command: MixCommand, control: String, slider: AXUIElement, displayed displayedDB: () -> Double?, rawBefore: Double, dbBefore: Double, target: Double) -> ExecutionResult {
        func failure(_ message: String, before: Double? = nil) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: before.map { JSONValue.number($0) }, after: nil, error: message) }
        if abs(dbBefore - target) <= Self.tolerance { return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(dbBefore), after: .number(dbBefore), error: nil) }
        // Mechanism proof before the first real write: read → set(the same value) → read, and the displayed dB must
        // not move either. A slider that rejects or distorts its own current value gets no further writes.
        if let refusal = proveIdempotentWrite(slider, value: rawBefore, read: { self.number(slider, kAXValueAttribute) }) { return failure(refusal, before: dbBefore) }
        guard let dbAfterProof = displayedDB(), abs(dbAfterProof - dbBefore) <= Self.tolerance else { return failure("Re-writing the \(control)'s own value moved the displayed dB — the write mechanism is not idempotent, refusing to continue.", before: dbBefore) }
        func rollback() -> Bool { setNumber(slider, rawBefore) && awaitValue(read: displayedDB, near: dbBefore) != nil }
        switch FaderScale.detect(sliderValue: rawBefore, displayedDB: dbBefore) {
        case .decibels:
            guard setNumber(slider, target) else { return failure("Writing the target over AXValue was rejected.", before: dbBefore) }
            if let after = awaitValue(read: displayedDB, near: target) { return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(dbBefore), after: .number(after), error: nil) }
            let restored = rollback()
            return failure("The \(control) displays \(displayedDB().map { String($0) } ?? "unreadable") dB after writing \(target) dB on the proven dB scale — the value did not verify. \(restored ? "The \(control) was restored to \(dbBefore) dB." : "RESTORING \(dbBefore) dB also failed — check the strip in Logic.")", before: dbBefore)
        case .raw:
            // Raw units (the real Logic shape: AXValue 173 at 0.0 dB). No guessed curve: the servo measures the
            // control itself, and it needs the slider's own bounds to keep every step inside the control's travel.
            guard let rawMin = number(slider, kAXMinValueAttribute), let rawMax = number(slider, kAXMaxValueAttribute), rawMin < rawMax else {
                return failure("The \(control)'s AXValue (\(rawBefore)) is not the displayed dB (\(dbBefore)) and the slider exposes no AXMinValue/AXMaxValue to calibrate against — the scale is unproven, refusing to write.", before: dbBefore)
            }
            var points: [(raw: Double, db: Double)] = [(rawBefore, dbBefore)]
            while true {
                switch FaderServoMath.step(points: points, targetDB: target, range: rawMin...rawMax, tolerance: Self.tolerance) {
                case .converged:
                    return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(dbBefore), after: .number(points[points.count - 1].db), error: nil)
                case .failed(let reason):
                    let restored = rollback()
                    return failure("Calibrated \(control) write failed: \(reason). \(restored ? "The \(control) was restored to \(dbBefore) dB." : "RESTORING \(dbBefore) dB also failed — check the strip in Logic.")", before: dbBefore)
                case .move(let raw):
                    guard setNumber(slider, raw) else {
                        let restored = rollback()
                        return failure("Writing raw \(raw) over AXValue was rejected mid-calibration. \(restored ? "The \(control) was restored to \(dbBefore) dB." : "RESTORING \(dbBefore) dB also failed — check the strip in Logic.")", before: dbBefore)
                    }
                    usleep(120_000)
                    guard let rawNow = number(slider, kAXValueAttribute), let dbNow = displayedDB() else {
                        let restored = rollback()
                        return failure("The \(control) stopped reading back mid-calibration. \(restored ? "The \(control) was restored to \(dbBefore) dB." : "RESTORING \(dbBefore) dB also failed — check the strip in Logic.")", before: dbBefore)
                    }
                    points.append((rawNow, dbNow))
                }
            }
        }
    }

    // MARK: Mechanism proof and small AX helpers

    /// The safe write proof required before the first real write: the control's CURRENT value is written back and the
    /// re-read must show it unchanged. Returns nil when proven, otherwise the refusal message.
    private func proveIdempotentWrite(_ element: AXUIElement, value: Double, read: () -> Double?) -> String? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return "The control's AXValue is not settable — Logic does not accept writes on this slider." }
        guard setNumber(element, value) else { return "Writing the control's own current value back was rejected — the write mechanism is unproven, refusing to continue." }
        usleep(120_000)
        guard let after = read(), abs(after - value) <= max(Self.tolerance, abs(value) * 0.001) else { return "Re-writing the control's own value changed its reading — the write mechanism is not idempotent, refusing to continue." }
        return nil
    }
    /// Polls a re-read until it lands within tolerance of `expected`; nil when it never does within the deadline.
    private func awaitValue(read: () -> Double?, near expected: Double, timeout: TimeInterval = 2) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(100_000)
            if let value = read(), abs(value - expected) <= Self.tolerance { return value }
        }
        return nil
    }
    private enum ControlResolution { case resolved(AXUIElement), failed(String) }
    /// The strip's own control with EXACTLY this caption — among the strip's direct children, like every channel fact.
    /// Zero or several matches are refusals with the captions actually found, never a guess.
    private func uniqueChild(of strip: AXUIElement, caption: String, roles: Set<String>) -> ControlResolution {
        let matches = children(strip).filter { child in
            roles.contains(role(child)) && (StripControlGrammar.matches(string(child, kAXDescriptionAttribute), caption) || StripControlGrammar.matches(string(child, kAXTitleAttribute), caption))
        }
        switch matches.count {
        case 1: return .resolved(matches[0])
        case 0:
            let seen = children(strip).compactMap { string($0, kAXDescriptionAttribute) ?? string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
            return .failed("The strip exposes no control captioned \u{2018}\(caption)\u{2019} (captions found: \(seen.isEmpty ? "none" : seen.joined(separator: ", "))).")
        default: return .failed("The strip exposes \(matches.count) controls captioned \u{2018}\(caption)\u{2019} — refusing to guess which one to write.")
        }
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }; return value as? [AXUIElement] ?? [] }
    private func windows(_ app: AXUIElement) -> [AXUIElement] { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }; return value as? [AXUIElement] ?? [] }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }; return value as? String ?? (value as? NSNumber)?.stringValue }
    private func number(_ element: AXUIElement, _ attribute: String) -> Double? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }; if let number = value as? NSNumber { return number.doubleValue }; return StripControlGrammar.decimal(value as? String) }
    private func setNumber(_ element: AXUIElement, _ value: Double) -> Bool { AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, NSNumber(value: value)) == .success }
    private func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "?" }
    @discardableResult private func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }
}
