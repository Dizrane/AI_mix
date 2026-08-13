import Foundation
import ApplicationServices
import AppKit

protocol DAWAnalyzer: Sendable { func connectionStatus() -> LogicConnection; func fullScan(progress: @escaping @Sendable (Int) -> Void) throws -> RawSnapshot; func runProbe(_ request: ProbeRequest) throws -> ProbeResult }
extension DAWAnalyzer { func fullScan() throws -> RawSnapshot { try fullScan(progress: { _ in }) } }
struct RunningApplicationDiagnostic: Identifiable, Sendable { var id: Int32 { processIdentifier }; var localizedName: String; var bundleIdentifier: String; var processIdentifier: Int32; var isFinishedLaunching: Bool; var isTerminated: Bool }
struct LogicConnection: Sendable { var found: Bool; var localizedName: String?; var pid: Int32?; var bundleIdentifier: String?; var isFinishedLaunching: Bool?; var isTerminated: Bool?; var accessibilityTrusted: Bool; var diagnostics: [RunningApplicationDiagnostic]; var message: String }

/// Read-only AX inspector. It never calls AXUIElementPerformAction or any AX setter.
struct LogicAccessibilityAnalyzer: DAWAnalyzer {
    private let supportedBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]
    func connectionStatus() -> LogicConnection {
        let applications = NSWorkspace.shared.runningApplications
        let app = applications.first { !$0.isTerminated && ($0.bundleIdentifier.map(supportedBundleIDs.contains) == true || $0.localizedName == "Logic Pro") }
        let trusted = AXIsProcessTrusted()
        return .init(found: app != nil, localizedName: app?.localizedName, pid: app?.processIdentifier, bundleIdentifier: app?.bundleIdentifier, isFinishedLaunching: app?.isFinishedLaunching, isTerminated: app?.isTerminated, accessibilityTrusted: trusted, diagnostics: app == nil ? applications.map(diagnostic(for:)) : [], message: app == nil ? "Logic Pro is not present in NSWorkspace.runningApplications." : (trusted ? "Connected read-only." : "Logic Pro found; Accessibility permission is required."))
    }
    /// One traversal of the application element captures everything: its AX children already include every window, so windows are
    /// referenced from the captured tree instead of being inspected a second time. `progress` receives the running element count;
    /// cancellation is honoured cooperatively between elements via `Task.checkCancellation`.
    func fullScan(progress: @escaping @Sendable (Int) -> Void) throws -> RawSnapshot {
        let status = connectionStatus(); guard status.found, let pid = status.pid else { throw AnalyzerError.logicNotRunning }; guard status.accessibilityTrusted else { throw AnalyzerError.accessibilityDenied }
        let appElement = AXUIElementCreateApplication(pid)
        var visited = 0
        let root = try inspect(appElement, path: "application", depth: 0, visited: &visited, progress: progress)
        let windowNodes = root.children.filter { $0.role == "AXWindow" }
        let windowTargets = windowNodes.enumerated().map { RawDiscoveryTarget(id: "window.\($0.offset)", kind: "window", node: $0.element) }
        let targeted = targetedNodes(in: windowTargets)
        let all = flatten(root)
        let diagnostics = makeDiagnostics(all: all, windows: windowNodes.count, probes: defaultProbes(all: all))
        let identity = projectIdentity(of: appElement)
        return .init(application: .init(name: status.localizedName ?? "Logic Pro", bundleIdentifier: status.bundleIdentifier ?? "unavailable", pid: pid, mainWindowTitle: identity.title, mainWindowDocument: identity.document), root: root, targets: windowTargets + targeted, diagnostics: diagnostics)
    }
    /// The two documented attributes that identify the open project: the main window's `AXDocument` (the `.logicx` file URL) and its
    /// `AXTitle`. Both are read from `AXMainWindow` so no window has to be guessed, and both are recorded verbatim as evidence — the
    /// normalizer decides what to publish. Neither exists for an app with no open project, and then both stay nil.
    private func projectIdentity(of application: AXUIElement) -> (title: String?, document: String?) {
        guard let window = attribute(application, kAXMainWindowAttribute) ?? attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return (nil, nil) }
        let element = window as! AXUIElement
        return (string(element, kAXTitleAttribute), string(element, kAXDocumentAttribute))
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
    /// One batched AX round-trip fetches all eight value attributes of an element instead of eight separate IPC calls. The menu-bar
    /// subtree is never descended into: menu items are not project evidence and their titles ("Play", "Region", "Tempo"…) would pollute
    /// text-based discovery while multiplying the scan cost.
    private func inspect(_ element: AXUIElement, path: String, depth: Int, visited: inout Int, progress: (Int) -> Void) throws -> RawAccessibilityNode {
        try Task.checkCancellation()
        visited += 1
        if visited % 256 == 0 { progress(visited) }
        let attrs = batchAttributes(element)
        let role = attrs.role ?? "unknown"
        let childItems = (depth < 24 && role != "AXMenuBar") ? childElements(element, attribute: kAXChildrenAttribute) : []
        var children: [RawAccessibilityNode] = []; children.reserveCapacity(childItems.count)
        for (offset, child) in childItems.enumerated() { children.append(try inspect(child, path: "\(path).\(offset)", depth: depth + 1, visited: &visited, progress: progress)) }
        return .init(id: path, role: role, subrole: attrs.subrole, title: attrs.title, description: attrs.description, value: attrs.value, enabled: attrs.enabled, position: attrs.position, size: attrs.size, supportedAttributes: attributeNames(element), parameterizedAttributes: parameterizedAttributeNames(element), actions: actionNames(element), children: children)
    }
    private struct NodeAttributes { var role: String?; var subrole: String?; var title: String?; var description: String?; var value: String?; var enabled: Bool?; var position: String?; var size: String? }
    private func batchAttributes(_ element: AXUIElement) -> NodeAttributes {
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &raw) == .success, let values = raw as? [AnyObject], values.count == keys.count else {
            return NodeAttributes(role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute), title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute), value: valueString(attribute(element, kAXValueAttribute)), enabled: attribute(element, kAXEnabledAttribute) as? Bool, position: axValueString(attribute(element, kAXPositionAttribute), type: kAXValueCGPointType), size: axValueString(attribute(element, kAXSizeAttribute), type: kAXValueCGSizeType))
        }
        func present(_ index: Int) -> AnyObject? { let value = values[index]; if value is NSNull { return nil }; if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }; return value }
        return NodeAttributes(role: present(0) as? String, subrole: present(1) as? String, title: present(2) as? String, description: present(3) as? String, value: valueString(present(4)), enabled: present(5) as? Bool, position: axValueString(present(6), type: kAXValueCGPointType), size: axValueString(present(7), type: kAXValueCGSizeType))
    }
    private func childElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] { var raw: CFArray?; let result = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, 500, &raw); return result == .success ? (raw as? [AXUIElement] ?? []) : [] }
    private func attributeNames(_ e: AXUIElement) -> [String] { var names: CFArray?; return AXUIElementCopyAttributeNames(e, &names) == .success ? (names as? [String] ?? []) : [] }
    private func parameterizedAttributeNames(_ e: AXUIElement) -> [String] { var names: CFArray?; return AXUIElementCopyParameterizedAttributeNames(e, &names) == .success ? (names as? [String] ?? []) : [] }
    private func actionNames(_ e: AXUIElement) -> [String] { var names: CFArray?; return AXUIElementCopyActionNames(e, &names) == .success ? (names as? [String] ?? []) : [] }
    private func attribute(_ e: AXUIElement, _ key: String) -> AnyObject? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil }
    private func string(_ e: AXUIElement, _ key: String) -> String? { attribute(e, key) as? String }
    private func valueString(_ value: AnyObject?) -> String? { guard let value else { return nil }; return (value as? String) ?? (value as? NSNumber).map(\.stringValue) }
    private func axValueString(_ value: AnyObject?, type: UInt32) -> String? { guard let value, CFGetTypeID(value) == AXValueGetTypeID(), let axType = AXValueType(rawValue: type) else { return nil }; let ax = value as! AXValue; if type == kAXValueCGPointType { var p = CGPoint.zero; guard AXValueGetValue(ax, axType, &p) else { return nil }; return "\(p.x),\(p.y)" }; var s = CGSize.zero; guard AXValueGetValue(ax, axType, &s) else { return nil }; return "\(s.width)x\(s.height)" }
    private func searchable(_ node: RawAccessibilityNode) -> [String] { [node.title, node.description, node.value, node.role, node.subrole].compactMap { $0 } }
    private func flatten(_ node: RawAccessibilityNode) -> [RawAccessibilityNode] { [node] + node.children.flatMap(flatten) }
    private func diagnostic(for app: NSRunningApplication) -> RunningApplicationDiagnostic { .init(localizedName: app.localizedName ?? "unavailable", bundleIdentifier: app.bundleIdentifier ?? "unavailable", processIdentifier: app.processIdentifier, isFinishedLaunching: app.isFinishedLaunching, isTerminated: app.isTerminated) }
}
enum AnalyzerError: LocalizedError { case logicNotRunning, accessibilityDenied; var errorDescription: String? { switch self { case .logicNotRunning: "Logic Pro is not running."; case .accessibilityDenied: "Accessibility permission is not granted to AI Mix Assistant." } } }
