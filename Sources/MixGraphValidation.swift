import Foundation

/// DRY validation of a MixGraph: the structural, filesystem and catalogue checks that need no Audio Unit
/// instantiation and no rendering. The Render screen runs it on a manual paste and the Assistant runs the exact same
/// checks on a model reply, so a graph that validates here fails later only for reasons that genuinely require
/// loading the units (instantiation, parameter trees, sample rates). Every finding is one named sentence; an empty
/// result is the verdict "valid". `MixEngine` remains the authority at render time — this never claims more than it
/// checked.
enum MixGraphDryCheck {
    /// - Parameters:
    ///   - audioFiles: file names actually present in the render source folder (current/audio); matched
    ///     case-insensitively against each track's file name.
    ///   - installedPlugins: the discovered Audio Unit inventory; when empty (inventory not run), catalogue checks
    ///     are honestly skipped rather than failing every insert.
    static func validate(_ graph: MixGraph, audioFiles: [String], installedPlugins: [PluginInventoryItem]) -> [String] {
        var issues: [String] = []
        if graph.schemaVersion != MixGraph.supportedVersion {
            issues.append("MixGraph schemaVersion \"\(graph.schemaVersion)\" is not supported (this engine understands \"\(MixGraph.supportedVersion)\").")
        }
        if graph.tracks.isEmpty { issues.append("The MixGraph contains no tracks — there is nothing to render.") }
        for name in duplicates(graph.tracks.map(\.name)) { issues.append("Track name \"\(name)\" is used more than once; names must be unique.") }
        for name in duplicates(graph.buses.map(\.name)) { issues.append("Bus name \"\(name)\" is used more than once; sends address buses by name.") }
        let knownBuses = Set(graph.buses.map(\.name))
        let lowercasedFiles = Set(audioFiles.map { $0.lowercased() })
        for track in graph.tracks {
            let fileName = (track.file as NSString).lastPathComponent
            if !lowercasedFiles.contains(fileName.lowercased()) {
                issues.append("Track \"\(track.name)\": the file \"\(track.file)\" is not among the exported WAVs (\(audioFiles.isEmpty ? "the audio folder holds no exported files" : "available: \(audioFiles.sorted().joined(separator: ", "))")).")
            }
            if !(-1.0...1.0).contains(track.pan) { issues.append("Track \"\(track.name)\": pan \(track.pan) is outside −1…+1.") }
            for send in track.sends {
                if !knownBuses.contains(send.bus) { issues.append("Track \"\(track.name)\" sends to bus \"\(send.bus)\", which the graph does not define (known buses: \(knownBuses.isEmpty ? "none" : knownBuses.sorted().joined(separator: ", "))).") }
                if !(-1.0...1.0).contains(send.pan) { issues.append("Track \"\(track.name)\": send pan \(send.pan) to \"\(send.bus)\" is outside −1…+1.") }
            }
            issues += checkInserts(track.inserts, owner: "track \"\(track.name)\"", installed: installedPlugins)
        }
        for bus in graph.buses { issues += checkInserts(bus.inserts, owner: "bus \"\(bus.name)\"", installed: installedPlugins) }
        issues += checkInserts(graph.master.inserts, owner: "master", installed: installedPlugins)
        return issues
    }

    private static func checkInserts(_ inserts: [MixGraphInsert], owner: String, installed: [PluginInventoryItem]) -> [String] {
        var issues: [String] = []
        for (index, insert) in inserts.enumerated() {
            let label = "\(owner) insert \(index + 1)"
            if insert.component == nil && insert.name == nil {
                issues.append("\(label) names neither a component identifier nor a component name — the plugin cannot be identified.")
                continue
            }
            if let component = insert.component {
                let parts = component.split(separator: "/", omittingEmptySubsequences: false)
                if parts.count != 3 || parts.contains(where: { $0.isEmpty || $0.count > 4 }) {
                    issues.append("\(label): \"\(component)\" is not a valid FourCC component identifier (expected \"type/subtype/manufacturer\", e.g. \"aufx/pmeq/appl\").")
                    continue
                }
                guard !installed.isEmpty else { continue }
                if !installed.contains(where: { $0.identifier.caseInsensitiveCompare(component) == .orderedSame }) {
                    issues.append("\(label): no installed Audio Unit matches \"\(component)\" — the plugin is not installed on this machine.")
                }
            } else if let name = insert.name, !installed.isEmpty {
                let matches = installed.filter { nameMatches(name, item: $0) }
                if matches.isEmpty { issues.append("\(label): no installed Audio Unit effect matches \"\(name)\" — the plugin is not installed on this machine.") }
                else if matches.count > 1 { issues.append("\(label): the name \"\(name)\" matches \(matches.count) installed plugins (\(matches.map(\.identifier).joined(separator: ", "))); use the exact component identifier instead.") }
            }
        }
        return issues
    }

    /// The same two accepted spellings `MixEngine` resolves by name: the bare component name, or "Manufacturer: Name" —
    /// both case-insensitive.
    private static func nameMatches(_ requested: String, item: PluginInventoryItem) -> Bool {
        let wanted = requested.trimmingCharacters(in: .whitespaces).lowercased()
        if item.name.lowercased() == wanted { return true }
        return "\(item.manufacturer): \(item.name)".lowercased() == wanted
    }

    private static func duplicates(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where !seen.insert(name).inserted && !result.contains(name) { result.append(name) }
        return result
    }
}
