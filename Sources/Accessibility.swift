import Foundation
import ApplicationServices
import AppKit

protocol DAWAnalyzer: Sendable { func connectionStatus() -> LogicConnection; func fullScan() throws -> RawSnapshot; func runProbe(_ request: ProbeRequest) throws -> ProbeResult }
struct RunningApplicationDiagnostic: Identifiable, Sendable { var id: Int32 { processIdentifier }; var localizedName: String; var bundleIdentifier: String; var processIdentifier: Int32; var isFinishedLaunching: Bool; var isTerminated: Bool }
struct LogicConnection: Sendable { var found: Bool; var localizedName: String?; var pid: Int32?; var bundleIdentifier: String?; var isFinishedLaunching: Bool?; var isTerminated: Bool?; var accessibilityTrusted: Bool; var diagnostics: [RunningApplicationDiagnostic]; var message: String }

/// Read-only AX inspector. It never calls AXUIElementPerformAction or any AX setter.
final class LogicAccessibilityAnalyzer: DAWAnalyzer, @unchecked Sendable {
    private let supportedBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]
    private var detectedApplication: NSRunningApplication?
    func connectionStatus() -> LogicConnection {
        let applications = NSWorkspace.shared.runningApplications
        let app = applications.first { !$0.isTerminated && ($0.bundleIdentifier.map(supportedBundleIDs.contains) == true || $0.localizedName == "Logic Pro") }
        detectedApplication = app
        let trusted = AXIsProcessTrusted()
        return .init(found: app != nil, localizedName: app?.localizedName, pid: app?.processIdentifier, bundleIdentifier: app?.bundleIdentifier, isFinishedLaunching: app?.isFinishedLaunching, isTerminated: app?.isTerminated, accessibilityTrusted: trusted, diagnostics: app == nil ? applications.map(diagnostic(for:)) : [], message: app == nil ? "Logic Pro is not present in NSWorkspace.runningApplications." : (trusted ? "Connected read-only." : "Logic Pro found; Accessibility permission is required."))
    }
    func fullScan() throws -> RawSnapshot {
        let status = connectionStatus(); guard let application = detectedApplication, let pid = status.pid else { throw AnalyzerError.logicNotRunning }; guard status.accessibilityTrusted else { throw AnalyzerError.accessibilityDenied }
        let appElement = AXUIElementCreateApplication(pid)
        // Inspect application and each AX window independently. This avoids treating one collapsed subtree as the entire DAW.
        let root = inspect(appElement, path: "application", depth: 0)
        let windows = childElements(appElement, attribute: kAXWindowsAttribute)
        let windowTargets = windows.enumerated().map { RawDiscoveryTarget(id: "window.\($0.offset)", kind: "window", node: inspect($0.element, path: "window.\($0.offset)", depth: 0)) }
        let targeted = targetedNodes(in: windowTargets)
        let all = flatten(root) + windowTargets.flatMap { flatten($0.node) }
        let diagnostics = makeDiagnostics(all: all, windows: windows.count, probes: defaultProbes(all: all))
        return .init(application: .init(name: application.localizedName ?? "Logic Pro", bundleIdentifier: application.bundleIdentifier ?? "unavailable", pid: pid), root: root, targets: windowTargets + targeted, diagnostics: diagnostics)
    }
    func runProbe(_ request: ProbeRequest) throws -> ProbeResult {
        let snapshot = try fullScan()
        let available: Bool = switch request.type { case .inspectMixer: snapshot.diagnostics.mixerDiscovered; case .inspectTrack, .inspectSelectedTrack, .inspectChannelStrip: snapshot.diagnostics.channelStripsFound > 0 || snapshot.diagnostics.tracksAreaDiscovered; case .inspectPlugin, .inspectPluginParameters: snapshot.diagnostics.pluginWindowsFound > 0; case .inspectTrackRegions, .inspectAudioMeter: false }
        return .init(request: request, status: available ? .known : .unavailable, snapshot: snapshot, message: available ? "Read-only probe found AX evidence; inspect normalized facts for values." : "No matching documented AX evidence was available in this scan.")
    }
    private func targetedNodes(in windows: [RawDiscoveryTarget]) -> [RawDiscoveryTarget] {
        let labels: [(String, [String])] = [("mixer", ["mixer", "channel strip"]), ("tracks_area", ["tracks", "track area"]), ("inspector", ["inspector"]), ("control_bar", ["control bar", "transport"]), ("plugin_window", ["plugin", "audio unit"])]
        return labels.compactMap { kind, terms in windows.flatMap { flatten($0.node) }.first(where: { node in searchable(node).contains(where: { text in terms.contains(where: text.localizedCaseInsensitiveContains) }) }).map { RawDiscoveryTarget(id: "target.\(kind).\($0.id)", kind: kind, node: $0) } }
    }
    private func makeDiagnostics(all: [RawAccessibilityNode], windows: Int, probes: [ProbeSummary]) -> AXDiscoveryDiagnostics {
        let roles = Dictionary(grouping: all, by: \.role).mapValues(\.count); let text = all.flatMap(searchable).joined(separator: " ").lowercased()
        let mixer = text.contains("mixer") || text.contains("channel strip"); let tracks = text.contains("tracks") || text.contains("track area"); let strips = all.filter { searchable($0).contains { $0.localizedCaseInsensitiveContains("channel strip") } }.count; let plugins = all.filter { $0.role == "AXWindow" && searchable($0).contains { $0.localizedCaseInsensitiveContains("plugin") || $0.localizedCaseInsensitiveContains("audio unit") } }.count
        return .init(windowsFound: windows, roles: roles, mixerDiscovered: mixer, tracksAreaDiscovered: tracks, channelStripsFound: strips, pluginWindowsFound: plugins, probes: probes)
    }
    private func defaultProbes(all: [RawAccessibilityNode]) -> [ProbeSummary] { let text = all.flatMap(searchable).joined(separator: " ").lowercased(); return ProbeType.allCases.map { type in let success: Bool = switch type { case .inspectMixer: text.contains("mixer"); case .inspectTrack, .inspectSelectedTrack, .inspectChannelStrip: text.contains("track") || text.contains("channel strip"); case .inspectPlugin, .inspectPluginParameters: text.contains("plugin") || text.contains("audio unit"); case .inspectTrackRegions: text.contains("region"); case .inspectAudioMeter: text.contains("meter") || text.contains("peak") }; return .init(type: type, status: success ? .known : .requiresProbe, message: success ? "AX discovery target found." : "Run targeted probe if required.") } }
    private func inspect(_ element: AXUIElement, path: String, depth: Int) -> RawAccessibilityNode {
        let attrs = attributeNames(element); let children = depth < 24 ? childElements(element, attribute: kAXChildrenAttribute) : []
        return .init(id: path, role: string(element, kAXRoleAttribute) ?? "unknown", subrole: string(element, kAXSubroleAttribute), title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute), value: valueString(element, kAXValueAttribute), enabled: bool(element, kAXEnabledAttribute), position: axValueString(element, kAXPositionAttribute, type: kAXValueCGPointType), size: axValueString(element, kAXSizeAttribute, type: kAXValueCGSizeType), supportedAttributes: attrs, parameterizedAttributes: parameterizedAttributeNames(element), actions: actionNames(element), children: children.enumerated().map { inspect($0.element, path: "\(path).\($0.offset)", depth: depth + 1) })
    }
    private func childElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] { var raw: CFArray?; let result = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, 500, &raw); return result == .success ? (raw as? [AXUIElement] ?? []) : [] }
    private func attributeNames(_ e: AXUIElement) -> [String] { var names: CFArray?; return AXUIElementCopyAttributeNames(e, &names) == .success ? (names as? [String] ?? []) : [] }
    private func parameterizedAttributeNames(_ e: AXUIElement) -> [String] { var names: CFArray?; return AXUIElementCopyParameterizedAttributeNames(e, &names) == .success ? (names as? [String] ?? []) : [] }
    private func actionNames(_ e: AXUIElement) -> [String] { var names: CFArray?; return AXUIElementCopyActionNames(e, &names) == .success ? (names as? [String] ?? []) : [] }
    private func attribute(_ e: AXUIElement, _ key: String) -> AnyObject? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil }
    private func string(_ e: AXUIElement, _ key: String) -> String? { attribute(e, key) as? String }
    private func bool(_ e: AXUIElement, _ key: String) -> Bool? { attribute(e, key) as? Bool }
    private func valueString(_ e: AXUIElement, _ key: String) -> String? { guard let value = attribute(e, key) else { return nil }; return (value as? String) ?? (value as? NSNumber).map(\.stringValue) }
    private func axValueString(_ e: AXUIElement, _ key: String, type: UInt32) -> String? { guard let value = attribute(e, key), CFGetTypeID(value) == AXValueGetTypeID(), let axType = AXValueType(rawValue: type) else { return nil }; let ax = value as! AXValue; if type == kAXValueCGPointType { var p = CGPoint.zero; guard AXValueGetValue(ax, axType, &p) else { return nil }; return "\(p.x),\(p.y)" }; var s = CGSize.zero; guard AXValueGetValue(ax, axType, &s) else { return nil }; return "\(s.width)x\(s.height)" }
    private func searchable(_ node: RawAccessibilityNode) -> [String] { [node.title, node.description, node.value, node.role, node.subrole].compactMap { $0 } }
    private func flatten(_ node: RawAccessibilityNode) -> [RawAccessibilityNode] { [node] + node.children.flatMap(flatten) }
    private func diagnostic(for app: NSRunningApplication) -> RunningApplicationDiagnostic { .init(localizedName: app.localizedName ?? "unavailable", bundleIdentifier: app.bundleIdentifier ?? "unavailable", processIdentifier: app.processIdentifier, isFinishedLaunching: app.isFinishedLaunching, isTerminated: app.isTerminated) }
}
enum AnalyzerError: LocalizedError { case logicNotRunning, accessibilityDenied; var errorDescription: String? { switch self { case .logicNotRunning: "Logic Pro is not running."; case .accessibilityDenied: "Accessibility permission is not granted to AI Mix Assistant." } } }
