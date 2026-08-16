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
/// secant iteration on the measured points, bounded — and it converges only when the control itself displays the
/// target dB within tolerance. The live Logic fader additionally CLAMPS every AXValue write to one bounded step
/// toward the written value (a real Stereo Out run moved ≈0.1 dB per write), so a long drive is many legitimate
/// measurements: the honest give-up is progress-based — a whole stagnation window of fresh readings that came no
/// closer to the target than everything measured before it — never a small fixed write budget. Every reading the
/// caller feeds in must be a real re-read; the function never extrapolates a result it did not measure.
struct FaderServoMath {
    enum Step: Equatable, Sendable { case converged; case move(raw: Double); case failed(reason: String) }
    /// True when the last `window` readings set no new record toward the target: the drive is measured by progress,
    /// so a clamped control may take hundreds of legitimate steps, while a control that stopped responding is caught
    /// within one window instead of being walked forever.
    static func stagnated(readings: [Double], target: Double, window: Int, tolerance: Double) -> Bool {
        guard readings.count > window else { return false }
        let recentBest = readings.suffix(window).map { abs($0 - target) }.min() ?? .infinity
        let earlierBest = readings.dropLast(window).map { abs($0 - target) }.min() ?? .infinity
        return recentBest > earlierBest - tolerance
    }
    /// The displayed level text quantizes to 0.1 dB, so two nearby raw positions can legally display the same dB; a
    /// slope is therefore computed only from a pair of points whose displayed values actually differ.
    static func step(points: [(raw: Double, db: Double)], targetDB: Double, range: ClosedRange<Double>, tolerance: Double = 0.05, maxMeasurements: Int = 1200, stagnationWindow: Int = 16) -> Step {
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
        if stagnated(readings: allDB, target: targetDB, window: stagnationWindow, tolerance: tolerance) {
            return .failed(reason: "the fader stopped at \(last.db) dB without progressing toward \(targetDB) dB across the last \(stagnationWindow) verified measurements")
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
            // A correction smaller than 0.1% of the travel is still a real move — on a steep stretch the last 0.1 dB
            // legitimately needs a tiny raw step, and a control that stops responding is caught by stagnation above.
            // Only a fader already pinned at a travel bound has nowhere left to go.
            if next == last.raw {
                return .failed(reason: "the servo cannot move past raw \(last.raw) (displayed \(last.db) dB) toward \(targetDB) dB — the target may lie outside the fader's travel")
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

// MARK: - Pure, testable strip resolution

/// The pure decision of WHICH live element a plan action's strip name addresses, extracted from the AX plumbing the
/// same way `CalibratedSliderWriter` extracts the write discipline — so the mirror scenario a real live run produced
/// (the snapshot's captured AX path landing on the main window's inspector MIRROR of the selected strip, same caption
/// and fader but a potentially stale AXValue, while a fresh scan read the real Mixer) is provable in unit tests. The
/// live Mixer areas — the scanner's own evidence — outrank the captured path by construction: the area with the most
/// strips is the real Mixer, smaller "mixer"-described areas are inspector mirrors of the same Logic objects and
/// contribute only names the main area does not show (exactly `SnapshotNormalizer.mixerStripNodes`' dedup — a name
/// found ONLY there is a real object and is kept), and a unique caption match resolves the element the scanner would
/// publish the fact from. Two same-named strips in the real Mixer stay ambiguous and refused regardless of where the
/// path lands — the path has no right to break a tie the scanner itself refuses to break. Only when NO area shows the
/// caption does the verified captured path resolve, and its provenance is carried on the result so every later
/// failure can name that the scanner's evidence never confirmed this element.
struct StripResolutionMath {
    enum Provenance: Equatable, Sendable { case liveMixer, capturedPathOnly }
    enum Decision<Strip> {
        case resolved(Strip, Provenance)
        case failed(String)
    }
    /// `areas` are the live "mixer"-described areas with their strips' captions; `pathStrip` is the captured AX
    /// path's landing element ONLY when it still verified as the named strip (exact caption plus volume-fader slider).
    static func decide<Strip>(name: String, areas: [[(caption: String, strip: Strip)]], pathStrip: Strip?) -> Decision<Strip> {
        var candidates: [Strip] = []
        if let mainIndex = areas.indices.max(by: { areas[$0].count < areas[$1].count }) {
            candidates = areas[mainIndex].filter { StripControlGrammar.matches($0.caption, name) }.map { $0.strip }
            if candidates.isEmpty {
                var names = Set(areas[mainIndex].map { $0.caption.localizedLowercase })
                for (index, area) in areas.enumerated() where index != mainIndex {
                    for entry in area where names.insert(entry.caption.localizedLowercase).inserted {
                        if StripControlGrammar.matches(entry.caption, name) { candidates.append(entry.strip) }
                    }
                }
            }
        }
        switch candidates.count {
        case 1: return .resolved(candidates[0], .liveMixer)
        case 0:
            if let pathStrip { return .resolved(pathStrip, .capturedPathOnly) }
            return .failed("Channel strip \u{2018}\(name)\u{2019} was not found in Logic's live Mixer — the captured AX path is stale and no strip carries that caption. Rescan and validate the plan again.")
        default: return .failed("Channel strip \u{2018}\(name)\u{2019} is ambiguous in Logic's live Mixer (\(candidates.count) strips carry that caption) — refusing to guess which one the plan means.")
        }
    }
}
extension StripResolutionMath.Decision: Equatable where Strip: Equatable {}

// MARK: - The calibrated slider write engine (pure algorithm over injected control IO)

/// Everything the calibrated write algorithm needs from one live slider, injected as closures so the whole write
/// discipline — staleness gate, mechanism proof, clamped drive, driven rollback — is unit-testable against a fake
/// control that misbehaves exactly like the live Logic fader (writes landing only as bounded steps, quantized
/// displays, swallowed writes). The adapter supplies AX-backed closures; nothing in the algorithm touches AX itself.
struct SliderWriteIO {
    /// The slider's own AXValue — the scale writes go out on.
    var readRaw: () -> Double?
    /// The control's displayed value — the fader's "volume fader level" dB text, a send knob's dB description, or the
    /// AXValue itself for controls whose value IS the fact scale (pan, a raw send knob). Success and rollback are only
    /// ever proven against this reading.
    var readDisplay: () -> Double?
    var write: (Double) -> Bool
    var isSettable: () -> Bool
    /// The slider's AXMinValue…AXMaxValue when it exposes a non-empty range; nil refuses the raw-scale servo.
    var bounds: () -> ClosedRange<Double>?
    /// The pause between a write and its re-read; the adapter sleeps, tests inject a no-op.
    var settle: () -> Void
}

/// The truthful result of one calibrated write: `executed` carries only re-read values, `refused` carries the exact
/// state the control was proven left in (its message names the restored — or not restored — displayed value).
enum SliderWriteOutcome: Equatable, Sendable {
    case executed(before: Double, after: Double)
    case refused(before: Double?, message: String)
}

/// The one write discipline every slider action runs through, in strict order:
/// 1. read the control (no writes yet); 2. the staleness gate against the plan's `parameters.current` — BEFORE any
/// write, the mechanism proof included; 3. the idempotent mechanism proof (read → set(the same value) → read) — and
/// when even that write moves the displayed value, the fact is recorded as Logic re-applying writes on this control
/// and the control is DRIVEN back to its original position before the refusal is reported; 4. the write on the proven
/// scale — a direct repeated drive on the dB/fact scale, the measured servo on the raw scale — where every write is
/// re-read and Logic's write clamping (each AXValue write lands only as a bounded step toward the written value) is
/// walked with a progress-based give-up instead of a fixed budget; 5. on ANY failure, a driven, multi-step rollback to
/// the original raw position, PROVEN by re-reading the displayed value — the refusal message states either the
/// verified return or the exact value the control was left at, never a silent third state.
struct CalibratedSliderWriter {
    var io: SliderWriteIO
    /// How the control is named in messages ("volume fader", "pan control", "send knob").
    var control: String
    /// The control name the staleness refusal uses ("Volume", "Pan", "Send level") and the unit its numbers carry.
    var stalenessControl: String
    var unit: String
    static let tolerance = LogicChannelStripAdapter.tolerance
    static let stagnationWindow = 16
    static let maxWrites = 1200

    func write(target: Double, planCurrent: Double?) -> SliderWriteOutcome {
        let tolerance = Self.tolerance
        guard let rawBefore = io.readRaw() else { return .refused(before: nil, message: "The \(control)'s AXValue does not read as a number.") }
        guard let dbBefore = io.readDisplay() else { return .refused(before: nil, message: "The \(control)'s displayed value does not read as a number.") }
        // The staleness gate fires before ANY write, the mechanism proof included: a drifted project is refused
        // without the control having been touched at all.
        if let stale = LogicChannelStripAdapter.stalenessRefusal(planCurrent: planCurrent, live: dbBefore, control: stalenessControl, unit: unit) {
            return .refused(before: dbBefore, message: stale)
        }
        if abs(dbBefore - target) <= tolerance { return .executed(before: dbBefore, after: dbBefore) }
        guard io.isSettable() else { return .refused(before: dbBefore, message: "The control's AXValue is not settable — Logic does not accept writes on this slider.") }
        // Mechanism proof: read → set(the same value) → read. On a control Logic merely echoes, nothing moves. A
        // control that re-applies even its own current value (clamping, requantization) has PROVEN it distorts writes:
        // the refusal is honest only after the control is driven back to where it stood.
        guard io.write(rawBefore) else { return .refused(before: dbBefore, message: "Writing the control's own current value back was rejected — the write mechanism is unproven, refusing to continue.") }
        io.settle()
        let dbEcho = io.readDisplay()
        if dbEcho == nil || abs(dbEcho! - dbBefore) > tolerance {
            let restoration = restore(rawTo: rawBefore, dbTo: dbBefore)
            return .refused(before: dbBefore, message: "Re-writing the \(control)'s own value moved its displayed value from \(dbBefore)\(unit) to \(dbEcho.map { "\($0)\(unit)" } ?? "an unreadable state") — Logic re-applies AXValue writes on this control instead of echoing them, so the write mechanism is unproven. \(restoration)")
        }
        let rawEcho = io.readRaw()
        if rawEcho == nil || abs(rawEcho! - rawBefore) > max(tolerance, abs(rawBefore) * 0.001) {
            let restoration = restore(rawTo: rawBefore, dbTo: dbBefore)
            return .refused(before: dbBefore, message: "Re-writing the \(control)'s own value changed its reading — the write mechanism is not idempotent, refusing to continue. \(restoration)")
        }
        // The write on the scale the control itself proved this very moment.
        let reason: String
        switch FaderScale.detect(sliderValue: rawBefore, displayedDB: dbBefore) {
        case .decibels:
            switch drive(toward: target) {
            case .reached(let after): return .executed(before: dbBefore, after: after)
            case .failed(let why): reason = why
            }
        case .raw:
            guard let range = io.bounds() else {
                return .refused(before: dbBefore, message: "The \(control)'s AXValue (\(rawBefore)) is not the displayed dB (\(dbBefore)) and the slider exposes no AXMinValue/AXMaxValue to calibrate against — the scale is unproven, refusing to write.")
            }
            switch servo(toward: target, range: range) {
            case .reached(let after): return .executed(before: dbBefore, after: after)
            case .failed(let why): reason = why
            }
        }
        let restoration = restore(rawTo: rawBefore, dbTo: dbBefore)
        return .refused(before: dbBefore, message: "Calibrated \(control) write failed: \(reason). \(restoration)")
    }

    private enum DriveResult { case reached(Double), failed(String) }
    /// Drives a control whose displayed value IS the write scale by repeating the target write: the live Logic
    /// controls apply each AXValue write only as a bounded step toward the written value, so one write proves nothing
    /// — success is only ever the re-read display within tolerance, and the give-up is progress-based.
    private func drive(toward target: Double) -> DriveResult {
        guard let start = io.readDisplay() else { return .failed("the \(control) stopped reading back before the drive") }
        var readings = [start]
        while readings.count <= Self.maxWrites {
            if abs(readings[readings.count - 1] - target) <= Self.tolerance { return .reached(readings[readings.count - 1]) }
            guard io.write(target) else { return .failed("writing \(target) over AXValue was rejected mid-drive") }
            io.settle()
            guard let now = io.readDisplay() else { return .failed("the \(control) stopped reading back mid-drive") }
            readings.append(now)
            if FaderServoMath.stagnated(readings: readings, target: target, window: Self.stagnationWindow, tolerance: Self.tolerance) {
                return .failed("the \(control) stopped at \(now)\(unit) without progressing toward \(target)\(unit) across the last \(Self.stagnationWindow) verified writes")
            }
        }
        return .failed("the \(control) did not reach \(target)\(unit) within \(Self.maxWrites) verified writes (last reading: \(readings[readings.count - 1])\(unit))")
    }
    /// Drives a raw-scale fader to the target displayed dB with the measured servo: `FaderServoMath` decides every
    /// next raw position from re-read (raw, displayed dB) pairs, tolerating Logic's write clamping by progress.
    private func servo(toward target: Double, range: ClosedRange<Double>) -> DriveResult {
        guard let raw = io.readRaw(), let db = io.readDisplay() else { return .failed("the \(control) stopped reading back before the drive") }
        var points: [(raw: Double, db: Double)] = [(raw, db)]
        while true {
            switch FaderServoMath.step(points: points, targetDB: target, range: range, tolerance: Self.tolerance, maxMeasurements: Self.maxWrites, stagnationWindow: Self.stagnationWindow) {
            case .converged: return .reached(points[points.count - 1].db)
            case .failed(let reason): return .failed(reason)
            case .move(let next):
                guard io.write(next) else { return .failed("writing raw \(next) over AXValue was rejected mid-calibration") }
                io.settle()
                guard let rawNow = io.readRaw(), let dbNow = io.readDisplay() else { return .failed("the \(control) stopped reading back mid-calibration") }
                points.append((rawNow, dbNow))
            }
        }
    }
    /// The rollback every failure ends in: the control is DRIVEN back to its original raw position with the same
    /// clamped-write discipline (a single restoring write is exactly what stranded the real Stereo Out fader at
    /// −1.0 dB), and the return is PROVEN by re-reading the displayed value. The sentence states the verified return,
    /// or names the exact value the control was left at — the caller never reports a rollback it did not re-read.
    private func restore(rawTo rawBefore: Double, dbTo dbBefore: Double) -> String {
        let rawTolerance = max(Self.tolerance, abs(rawBefore) * 0.001)
        var readings: [Double] = io.readRaw().map { [$0] } ?? []
        while readings.count <= Self.maxWrites, let last = readings.last {
            if abs(last - rawBefore) <= rawTolerance { break }
            guard io.write(rawBefore) else { break }
            io.settle()
            guard let now = io.readRaw() else { break }
            readings.append(now)
            if FaderServoMath.stagnated(readings: readings, target: rawBefore, window: Self.stagnationWindow, tolerance: Self.tolerance) { break }
        }
        let restored = io.readDisplay()
        if let restored, abs(restored - dbBefore) <= Self.tolerance {
            return "The \(control) was restored to \(dbBefore)\(unit)."
        }
        return "RESTORING \(dbBefore)\(unit) FAILED — the \(control) was left at \(restored.map { "\($0)\(unit)" } ?? "an unreadable value"); check the strip in Logic."
    }
}

// MARK: - The live channel-strip adapter

/// The verified live adapter: volume, pan, mute, solo and send level on a Mixer channel strip. Discipline:
/// - the strip is located from live AX evidence (a unique caption match in the live Mixer areas FIRST — the scanner's
///   own evidence, inspector mirrors deduped; the snapshot's captured AX path only as a verified fallback when no
///   area shows the caption, named as such in every later failure) — never guessed, never by coordinates;
/// - mute/solo use the documented AXPress on the strip's own captioned control and the switch is believed only after
///   re-reading the value;
/// - volume, pan and send levels all run through `CalibratedSliderWriter`: staleness gate before any write, the
///   idempotent mechanism proof, scale detection from same-moment evidence (AXValue vs the displayed dB text), the
///   measured servo on the raw scale (never a guessed curve), clamped writes walked by progress, and on every failure
///   a driven, re-read-proven rollback to the original position — the result names where the control really is;
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
        let provenance: StripResolutionMath.Provenance
        switch resolveStrip(named: name, capturedPath: channelPath, in: appElement) {
        case .failed(let reason): return failure(reason)
        case .resolved(let element, let origin): strip = element; provenance = origin
        }
        let outcome: ExecutionResult
        switch command.action {
        case .setMute: outcome = toggle(command, strip: strip, control: "mute")
        case .setSolo: outcome = toggle(command, strip: strip, control: "solo")
        case .setVolume: outcome = setVolume(command, strip: strip)
        case .setPan: outcome = setPan(command, strip: strip)
        case .setSendLevel: outcome = setSendLevel(command, strip: strip)
        default: outcome = failure("No verified live Logic adapter is installed for this action.")
        }
        // A failure on a strip only the captured path vouched for must say so: the scanner's evidence never confirmed
        // this element, so the reader is pointed at the one recipe that makes both readers meet — an open Mixer.
        guard provenance == .capturedPathOnly, outcome.status == ExecutionStatus.failed, let error = outcome.error else { return outcome }
        return .init(actionID: outcome.actionID, status: outcome.status, before: outcome.before, after: outcome.after, error: error + " The strip was resolved from the snapshot's captured AX path because no live Mixer area shows its caption — open the Mixer window (X) so Logic renders the strips and rescan.")
    }

    // MARK: Strip resolution

    /// Resolves the live AXUIElement of the strip the snapshot captured. The live Mixer areas — the scanner's own
    /// evidence — are searched FIRST and the captured AX path can never override or outrank them: the decision itself
    /// is `StripResolutionMath.decide` (pure, tested), fed the areas' captions and the path's landing element only
    /// when that element still verifies as the named strip (exact caption plus a volume-fader slider). A unique
    /// caption match resolves from the real Mixer; two same-named strips are ambiguous and refused, exactly as the
    /// normalizer refuses to link them; only a caption no area shows falls back to the verified captured path.
    private func resolveStrip(named name: String, capturedPath: String, in appElement: AXUIElement) -> StripResolutionMath.Decision<AXUIElement> {
        let walked = element(at: capturedPath, from: appElement)
        return StripResolutionMath.decide(name: name, areas: liveMixerAreas(in: appElement), pathStrip: walked.flatMap { isStrip($0, named: name) ? $0 : nil })
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
    /// Every "mixer"-described AXLayoutArea in the live UI, each with its strips (AXLayoutItem children captioned and
    /// carrying a volume-fader slider) — the same structural evidence the normalizer scans, delivered raw so
    /// `StripResolutionMath` applies the identical largest-area/mirror dedup the scanner applies.
    private func liveMixerAreas(in appElement: AXUIElement) -> [[(caption: String, strip: AXUIElement)]] {
        var areas: [[(caption: String, strip: AXUIElement)]] = []
        var visited = 0
        var queue: [(element: AXUIElement, depth: Int)] = windows(appElement).map { ($0, 0) }
        while !queue.isEmpty && visited < 60_000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if role(element) == "AXLayoutArea", string(element, kAXDescriptionAttribute)?.localizedCaseInsensitiveContains("mixer") == true {
                areas.append(children(element).compactMap { candidate -> (caption: String, strip: AXUIElement)? in
                    guard role(candidate) == "AXLayoutItem", let caption = string(candidate, kAXDescriptionAttribute), !caption.isEmpty,
                          children(candidate).contains(where: { role($0) == "AXSlider" && StripControlGrammar.matches(string($0, kAXDescriptionAttribute) ?? string($0, kAXTitleAttribute), "volume fader") })
                    else { return nil }
                    return (caption: caption, strip: candidate)
                })
                continue // the area's strips are captured; no need to enqueue its thousands of grandchildren
            }
            if depth < 14 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
        }
        return areas
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

    // MARK: Pan — the calibrated write on the fact scale (the slider's own AXValue)

    private func setPan(_ command: MixCommand, strip: AXUIElement) -> ExecutionResult {
        guard let target = command.parameters["value"]?.numberValue else { return .init(actionID: command.id, status: ExecutionStatus.failed, before: nil, after: nil, error: "set_pan needs a numeric parameters.value.") }
        switch uniqueChild(of: strip, caption: "pan", roles: ["AXSlider"]) {
        case .failed(let reason): return .init(actionID: command.id, status: ExecutionStatus.failed, before: nil, after: nil, error: reason)
        case .resolved(let slider):
            // The pan facts (and the validator's −64…+63 range) come from this control's own AXValue, so the write
            // scale is the fact scale by construction: the AXValue itself is the displayed value the engine verifies.
            let writer = CalibratedSliderWriter(io: sliderIO(slider, display: nil), control: "pan control", stalenessControl: "Pan", unit: "")
            return result(command, of: writer.write(target: target, planCurrent: command.parameters["current"]?.numberValue))
        }
    }

    // MARK: Volume — scale calibration, then a verified write on the proven scale

    private func setVolume(_ command: MixCommand, strip: AXUIElement) -> ExecutionResult {
        func failure(_ message: String) -> ExecutionResult { .init(actionID: command.id, status: ExecutionStatus.failed, before: nil, after: nil, error: message) }
        guard let target = command.parameters["value"]?.numberValue else { return failure("set_volume needs a numeric parameters.value.") }
        let slider: AXUIElement
        switch uniqueChild(of: strip, caption: "volume fader", roles: ["AXSlider"]) {
        case .failed(let reason): return failure(reason)
        case .resolved(let element): slider = element
        }
        // The displayed dB is the same evidence the Volume facts come from; without it no write can be verified.
        guard let level = children(strip).first(where: { StripControlGrammar.matches(string($0, kAXDescriptionAttribute), "volume fader level") }) else { return failure("The strip exposes no \u{2018}volume fader level\u{2019} text — a volume write could not be verified, so none is attempted.") }
        let writer = CalibratedSliderWriter(io: sliderIO(slider, display: { StripControlGrammar.decimal(self.string(level, kAXTitleAttribute) ?? self.string(level, kAXValueAttribute)) }), control: "volume fader", stalenessControl: "Volume", unit: " dB")
        return result(command, of: writer.write(target: target, planCurrent: command.parameters["current"]?.numberValue))
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
        func describedDB() -> Double? {
            guard let text = string(knob, kAXValueDescriptionAttribute), text.localizedCaseInsensitiveContains("db") else { return nil }
            return StripControlGrammar.decimal(text)
        }
        if describedDB() != nil {
            // The knob's own AXValueDescription displays dB: the same calibrated procedure as the volume fader.
            let writer = CalibratedSliderWriter(io: sliderIO(knob, display: describedDB), control: "send knob", stalenessControl: "Send level", unit: " dB")
            return result(command, of: writer.write(target: target, planCurrent: command.parameters["current"]?.numberValue))
        }
        // No dB is displayed anywhere on this knob, so the only proven scale is the knob's own AXValue — the exact
        // scale the fact (and the plan's target) is on: the AXValue itself is the displayed value the engine verifies.
        let writer = CalibratedSliderWriter(io: sliderIO(knob, display: nil), control: "send knob", stalenessControl: "Send level", unit: " (raw knob units)")
        return result(command, of: writer.write(target: target, planCurrent: command.parameters["current"]?.numberValue))
    }

    // MARK: The engine's AX-backed control IO and small AX helpers

    /// The live AX closures the calibrated write engine runs on. `display` re-reads the control's own displayed value
    /// (the fader's level text, a send knob's dB description); nil means the AXValue itself IS the displayed fact
    /// scale (pan, a raw send knob). The settle pause matches the ~0.1 dB-per-write cadence the real fader showed.
    private func sliderIO(_ slider: AXUIElement, display: (() -> Double?)?) -> SliderWriteIO {
        let readRaw = { self.number(slider, kAXValueAttribute) }
        return .init(
            readRaw: readRaw,
            readDisplay: display ?? readRaw,
            write: { self.setNumber(slider, $0) },
            isSettable: {
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(slider, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            },
            bounds: {
                guard let rawMin = self.number(slider, kAXMinValueAttribute), let rawMax = self.number(slider, kAXMaxValueAttribute), rawMin < rawMax else { return nil }
                return rawMin...rawMax
            },
            settle: { usleep(120_000) }
        )
    }
    /// Maps the engine's truthful outcome onto the action's `ExecutionResult`; `before`/`after` are re-read values.
    private func result(_ command: MixCommand, of outcome: SliderWriteOutcome) -> ExecutionResult {
        switch outcome {
        case .executed(let before, let after): return .init(actionID: command.id, status: ExecutionStatus.executed, before: .number(before), after: .number(after), error: nil)
        case .refused(let before, let message): return .init(actionID: command.id, status: ExecutionStatus.failed, before: before.map { JSONValue.number($0) }, after: nil, error: message)
        }
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
