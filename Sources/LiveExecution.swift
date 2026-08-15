import Foundation
import ApplicationServices
import AppKit

// MARK: - Live adapter contract

/// Everything a live adapter may consult beyond the command itself: the normalized snapshot the plan was validated
/// against. Adapters resolve their target through the same rule as the validator (trackID or exact track name), so an
/// action can never execute against a different object than the one it was validated for.
struct LiveExecutionContext: Sendable { var snapshot: NormalizedSnapshot }

/// One action-specific live adapter (EXECUTOR.md contract): it declares which actions it implements, uses only the
/// allowed interaction mechanisms (AXValue writes and AXPress on the control the fact came from — never screen
/// coordinates, AppleScript or undocumented APIs), reads the control back after every write, and reports an honest
/// `ExecutionResult` with before/after. A failure is a failure; nothing is ever claimed on a blind write.
protocol LiveActionAdapter: Sendable {
    func supports(_ action: MixAction) -> Bool
    func execute(_ command: MixCommand, context: LiveExecutionContext) -> ExecutionResult
}

// MARK: - Fader scale calibration (pure, testable)

/// The scale a channel-strip slider was PROVEN to use for the write, decided from evidence, never assumed.
enum FaderScale: String, Sendable, Equatable { case decibels, raw }

/// Pure calibration arithmetic for fader-style controls. The channel strip exposes the writable slider and a separate
/// dB readout ("volume fader level"); whether the slider itself takes dB or raw fader units is decided by comparing
/// the two, and a raw-scale write is settled by a closed-loop search against Logic's own dB readout — the mapping is
/// never guessed from a formula, because Logic documents none.
enum FaderCalibration {
    /// Tolerance 0.05 matches the validator and the 0.1 precision the user can set on Logic's controls.
    static let tolerance = 0.05
    /// A slider whose own value equals the dB readout is a dB-scale control; anything else is a raw scale.
    static func classify(sliderValue: Double, dbReadout: Double, tolerance: Double = FaderCalibration.tolerance) -> FaderScale {
        abs(sliderValue - dbReadout) <= tolerance ? .decibels : .raw
    }
    /// Closed-loop bisection over a monotonically increasing control: `probe` writes a raw value and returns the dB
    /// the control then reads back (nil when the write or the readback fails, which aborts the search). Endpoints are
    /// never probed — the fader is not slammed to its extremes — and the search succeeds only when a probed value's
    /// own readback lands within `tolerance` of the target. Returns the raw value that proved the target, or nil:
    /// a scale too coarse to reach the target within tolerance is an honest failure, never an approximation.
    static func converge(target: Double, low: Double, high: Double, tolerance: Double = FaderCalibration.tolerance, maxSteps: Int = 24, probe: (Double) -> Double?) -> Double? {
        guard low < high else { return nil }
        var low = low, high = high
        for _ in 0..<maxSteps {
            let mid = (low + high) / 2
            guard let db = probe(mid) else { return nil }
            if abs(db - target) <= tolerance { return mid }
            if db < target { low = mid } else { high = mid }
        }
        return nil
    }
}

// MARK: - Logic channel-strip adapter (volume / pan / mute / solo)

/// The verified live adapter for the four fader actions on a Logic channel strip. Discovery mirrors the analyzer's
/// documented structural rules on the LIVE AX tree (the Mixer AXLayoutArea with the most strips is the real Mixer; a
/// strip is an AXLayoutItem holding a "volume fader" slider; the target strip is matched by its exact name, uniquely
/// or not at all). Writes use only AXValue-set and AXPress on the control the corresponding fact was read from, every
/// write is verified by re-reading the control, a fader write is calibrated first (idempotent read → set(current) →
/// read, then a proven scale or a closed-loop search against the strip's own dB readout), and any unverifiable state
/// reverts the control and fails the action instead of leaving a half-applied move.
struct LogicChannelStripLiveAdapter: LiveActionAdapter {
    private static let supportedActions: Set<MixAction> = [.setVolume, .setPan, .setMute, .setSolo]
    private let supportedBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]

    func supports(_ action: MixAction) -> Bool { Self.supportedActions.contains(action) }

    func execute(_ command: MixCommand, context: LiveExecutionContext) -> ExecutionResult {
        func failed(_ error: String) -> ExecutionResult { .init(actionID: command.id, status: "failed", before: nil, after: nil, error: error) }
        guard supports(command.action) else { return failed("This adapter implements only volume, pan, mute and solo.") }
        guard AXIsProcessTrusted() else { return failed("Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated && ($0.bundleIdentifier.map(supportedBundleIDs.contains) == true || $0.localizedName == "Logic Pro") }) else { return failed("Logic Pro is not running.") }
        guard let track = context.snapshot.tracks.first(where: { $0.id == command.target.trackID || ($0.name.value != nil && $0.name.value == command.target.trackName) }) else { return failed("The action's target track is not present in the validated snapshot.") }
        guard let trackName = track.name.value else { return failed("The target track has no known Logic name to locate its channel strip by.") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let strip: AXUIElement
        switch channelStrip(named: trackName, in: appElement) {
        case .notFound(let reason): return failed(reason)
        case .found(let element): strip = element
        }
        switch command.action {
        case .setVolume:
            guard let target = command.parameters["value"]?.numberValue else { return failed("set_volume carries no numeric parameters.value.") }
            return executeVolume(command, strip: strip, target: target)
        case .setPan:
            guard let target = command.parameters["value"]?.numberValue else { return failed("set_pan carries no numeric parameters.value.") }
            return executePan(command, strip: strip, target: target)
        case .setMute, .setSolo:
            guard let target = command.parameters["value"]?.boolValue else { return failed("\(command.action.rawValue) carries no boolean parameters.value.") }
            return executeToggle(command, strip: strip, captionWord: command.action == .setMute ? "mute" : "solo", target: target)
        default:
            return failed("This adapter implements only volume, pan, mute and solo.")
        }
    }

    // MARK: Volume — calibrated slider write, verified against the strip's own dB readout

    private func executeVolume(_ command: MixCommand, strip: AXUIElement, target: Double) -> ExecutionResult {
        func failed(_ error: String) -> ExecutionResult { .init(actionID: command.id, status: "failed", before: nil, after: nil, error: error) }
        guard let slider = child(of: strip, role: "AXSlider", captionContains: "volume fader") else { return failed("The strip exposes no 'volume fader' slider.") }
        guard let readout = child(of: strip, role: nil, captionContains: "volume fader level") else { return failed("The strip exposes no 'volume fader level' dB readout, so a fader write cannot be verified — refusing to write blind.") }
        func readDB() -> Double? { decimal(string(readout, kAXTitleAttribute) ?? string(readout, kAXValueAttribute)) }
        guard let raw0 = number(slider, kAXValueAttribute) else { return failed("The volume fader exposes no readable numeric AXValue.") }
        guard let db0 = readDB() else { return failed("The strip's dB readout is not readable as a number.") }
        if let current = command.parameters["current"]?.numberValue, abs(db0 - current) > FaderCalibration.tolerance {
            return failed("Live Volume reads \(formatted(db0)) dB but the plan's current is \(formatted(current)) dB — the project changed since the analysis. Re-run the scan and re-validate the plan.")
        }
        // Idempotent calibration write: setting the control to its own current value must change nothing. It proves
        // the control accepts AXValue writes on the scale it reads back in, before any real value is committed.
        guard setNumber(slider, raw0) else { return failed("The volume fader rejected an AXValue write of its own current value — the control is not writable.") }
        usleep(120_000)
        guard let raw1 = number(slider, kAXValueAttribute), abs(raw1 - raw0) <= 0.01, let db1 = readDB(), abs(db1 - db0) <= FaderCalibration.tolerance else {
            _ = setNumber(slider, raw0)
            return failed("The idempotent calibration write changed the control's state — the fader scale is unverified and nothing was executed.")
        }
        let before = JSONValue.number(db0)
        switch FaderCalibration.classify(sliderValue: raw0, dbReadout: db0) {
        case .decibels:
            guard setNumber(slider, target) else { return failed("AXValue write of the dB target did not succeed.") }
            if let after = waitForReadback(readDB, expected: target) { return .init(actionID: command.id, status: "executed", before: before, after: .number(after), error: nil) }
            _ = setNumber(slider, raw0)
            return failed("After writing \(formatted(target)) dB the strip's readout never confirmed the value; the fader was reverted to \(formatted(db0)) dB.")
        case .raw:
            guard let low = number(slider, kAXMinValueAttribute), let high = number(slider, kAXMaxValueAttribute), low < high else {
                _ = setNumber(slider, raw0)
                return failed("The fader uses a raw scale but exposes no AXMinValue/AXMaxValue to calibrate against — refusing to guess the mapping.")
            }
            let settled = FaderCalibration.converge(target: target, low: low, high: high) { raw in
                guard setNumber(slider, raw) else { return nil }
                usleep(80_000)
                return readDB()
            }
            if settled != nil, let after = readDB(), abs(after - target) <= FaderCalibration.tolerance {
                return .init(actionID: command.id, status: "executed", before: before, after: .number(after), error: nil)
            }
            _ = setNumber(slider, raw0)
            return failed("Closed-loop calibration could not settle the fader at \(formatted(target)) dB — the readout never confirmed the target within 0.05 dB. The fader was reverted to \(formatted(db0)) dB; set this one value by hand.")
        }
    }

    // MARK: Pan — the fact's own control, written and verified on the same scale

    private func executePan(_ command: MixCommand, strip: AXUIElement, target: Double) -> ExecutionResult {
        func failed(_ error: String) -> ExecutionResult { .init(actionID: command.id, status: "failed", before: nil, after: nil, error: error) }
        guard let control = child(of: strip, role: nil, captionContains: "pan"), let p0 = controlNumber(control) else { return failed("The strip exposes no readable pan control.") }
        if let current = command.parameters["current"]?.numberValue, abs(p0 - current) > FaderCalibration.tolerance {
            return failed("Live Pan reads \(formatted(p0)) but the plan's current is \(formatted(current)) — the project changed since the analysis. Re-run the scan and re-validate the plan.")
        }
        guard setNumber(control, p0) else { return failed("The pan control rejected an AXValue write of its own current value — the control is not writable.") }
        usleep(120_000)
        guard let p1 = controlNumber(control), abs(p1 - p0) <= FaderCalibration.tolerance else {
            _ = setNumber(control, p0)
            return failed("The idempotent calibration write changed the pan control's state — the scale is unverified and nothing was executed.")
        }
        guard setNumber(control, target) else { return failed("AXValue write of the pan target did not succeed.") }
        if let after = waitForReadback({ self.controlNumber(control) }, expected: target) {
            return .init(actionID: command.id, status: "executed", before: .number(p0), after: .number(after), error: nil)
        }
        _ = setNumber(control, p0)
        return failed("After writing pan \(formatted(target)) the control read back a different value — the pan scale is unverified. The control was reverted to \(formatted(p0)); set this one value by hand.")
    }

    // MARK: Mute / Solo — AXPress on the strip's own checkbox, verified by re-reading

    private func executeToggle(_ command: MixCommand, strip: AXUIElement, captionWord: String, target: Bool) -> ExecutionResult {
        func failed(_ error: String) -> ExecutionResult { .init(actionID: command.id, status: "failed", before: nil, after: nil, error: error) }
        guard let control = child(of: strip, role: nil, captionContains: captionWord), let before = boolValue(string(control, kAXValueAttribute)) else {
            return failed("The strip exposes no readable \(captionWord) control with a 0/1 switch value.")
        }
        if before == target { return .init(actionID: command.id, status: "executed", before: .bool(before), after: .bool(before), error: nil) }
        guard press(control) else { return failed("AXPress on the \(captionWord) control did not succeed.") }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            usleep(100_000)
            if let now = boolValue(string(control, kAXValueAttribute)), now == target {
                return .init(actionID: command.id, status: "executed", before: .bool(before), after: .bool(now), error: nil)
            }
        }
        let now = boolValue(string(control, kAXValueAttribute))
        return failed("The \(captionWord) control still reads \(now.map { $0 ? "on" : "off" } ?? "unreadable") after the press — the target state was never confirmed.")
    }

    // MARK: Live strip discovery (the analyzer's structural rules, applied to live elements)

    private enum StripLookup { case found(AXUIElement), notFound(String) }
    private func channelStrip(named name: String, in appElement: AXUIElement) -> StripLookup {
        var areas: [[AXUIElement]] = []
        collectMixerAreas(appElement, depth: 0, into: &areas)
        guard let mainIndex = areas.indices.max(by: { areas[$0].count < areas[$1].count }) else { return .notFound("No Mixer area is visible in Logic's AX tree — open the Mixer (X) and retry.") }
        func matches(_ strips: [AXUIElement]) -> [AXUIElement] {
            strips.filter { (string($0, kAXDescriptionAttribute) ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        var found = matches(areas[mainIndex])
        if found.isEmpty { found = areas.enumerated().filter { $0.offset != mainIndex }.flatMap { matches($0.element) } }
        switch found.count {
        case 0: return .notFound("No channel strip named \u{201C}\(name)\u{201D} is visible in Logic's Mixer.")
        case 1: return .found(found[0])
        default: return .notFound("\(found.count) channel strips are named \u{201C}\(name)\u{201D} — the target is ambiguous and nothing was executed. Rename the track uniquely and re-analyze.")
        }
    }
    /// Collects the strips of every "mixer"-described AXLayoutArea. A strip is an AXLayoutItem with a non-empty
    /// description holding a "volume fader" AXSlider — the same rule the normalizer's discovery uses.
    private func collectMixerAreas(_ element: AXUIElement, depth: Int, into areas: inout [[AXUIElement]]) {
        guard depth < 24 else { return }
        if role(element) == "AXLayoutArea", (string(element, kAXDescriptionAttribute) ?? "").localizedCaseInsensitiveContains("mixer") {
            let strips = children(element).filter { strip in
                guard role(strip) == "AXLayoutItem", (string(strip, kAXDescriptionAttribute) ?? "").isEmpty == false else { return false }
                return child(of: strip, role: "AXSlider", captionContains: "volume fader") != nil
            }
            areas.append(strips)
        }
        for child in children(element) { collectMixerAreas(child, depth: depth + 1, into: &areas) }
    }

    // MARK: AX primitives

    private func child(of element: AXUIElement, role wantedRole: String?, captionContains needle: String) -> AXUIElement? {
        children(element).first { child in
            if let wantedRole, role(child) != wantedRole { return false }
            let caption = string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute) ?? ""
            return caption.localizedCaseInsensitiveContains(needle)
        }
    }
    private func waitForReadback(_ read: () -> Double?, expected: Double, timeout: TimeInterval = 1.5) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(100_000)
            if let value = read(), abs(value - expected) <= FaderCalibration.tolerance { return value }
        }
        return nil
    }
    private func controlNumber(_ element: AXUIElement) -> Double? { number(element, kAXValueAttribute) ?? decimal(string(element, kAXValueAttribute)) }
    private func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil }
    private func string(_ element: AXUIElement, _ key: String) -> String? { let value = attribute(element, key); return (value as? String) ?? (value as? NSNumber).map(\.stringValue) }
    private func number(_ element: AXUIElement, _ key: String) -> Double? { attribute(element, key) as? Double ?? (attribute(element, key) as? NSNumber)?.doubleValue }
    private func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }
    private func children(_ element: AXUIElement) -> [AXUIElement] { var raw: CFArray?; return AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 500, &raw) == .success ? (raw as? [AXUIElement] ?? []) : [] }
    private func setNumber(_ element: AXUIElement, _ value: Double) -> Bool { AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, NSNumber(value: value)) == .success }
    private func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }
    private func boolValue(_ value: String?) -> Bool? { value == "1" ? true : (value == "0" ? false : nil) }
    private func decimal(_ value: String?) -> Double? { guard let value else { return nil }; return value.replacingOccurrences(of: ",", with: ".").split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).compactMap { Double($0) }.first }
    private func formatted(_ value: Double) -> String { var text = String(format: "%.2f", value); while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() }; return text == "-0" ? "0" : text }
}
