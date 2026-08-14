import Foundation

enum MixAction: String, Codable, CaseIterable, Sendable { case setVolume = "set_volume", setPan = "set_pan", setMute = "set_mute", setSolo = "set_solo", setInput = "set_input", setOutput = "set_output", setSendLevel = "set_send_level", setSendPan = "set_send_pan", setPluginBypass = "set_plugin_bypass", setPluginParameter = "set_plugin_parameter", insertPlugin = "insert_plugin", removePlugin = "remove_plugin", movePlugin = "move_plugin", createTrack = "create_track", deleteTrack = "delete_track", renameTrack = "rename_track" }
struct MixPlan: Codable, Sendable { var version: String; var status: String; var actions: [MixCommand] }
struct MixCommand: Codable, Identifiable, Sendable { var id: String; var target: CommandTarget; var action: MixAction; var parameters: [String: JSONValue]; var reason: String }
struct CommandTarget: Codable, Sendable { var trackID: String?; var trackName: String?; var pluginID: String?; var pluginName: String?; var parameterID: String?; var parameterName: String? }
enum JSONValue: Codable, Sendable, Equatable { case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from d: Decoder) throws { let c = try d.singleValueContainer(); if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) } else if let v = try? c.decode(Double.self) { self = .number(v) } else if let v = try? c.decode(String.self) { self = .string(v) } else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) } else { self = .array(try c.decode([JSONValue].self)) } }
    func encode(to e: Encoder) throws { var c = e.singleValueContainer(); switch self { case .string(let x): try c.encode(x); case .number(let x): try c.encode(x); case .bool(let x): try c.encode(x); case .object(let x): try c.encode(x); case .array(let x): try c.encode(x); case .null: try c.encodeNil() } }
    var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
}
extension MixPlan {
    /// The Review screen accepts the plan as an LLM actually delivers it: a bare JSON object, the same object inside a
    /// Markdown code fence (```json … ```), or a fenced block pasted along with surrounding prose. The first fenced block
    /// wins; without a fence, the text from the first "{" to the last "}" is tried; anything else passes through unchanged
    /// so the decoder reports the real error instead of a fence-induced one.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = trimmed.range(of: "```") {
            let afterFence = trimmed[fenceStart.upperBound...]
            let body = afterFence[(afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex)...]
            if let fenceEnd = body.range(of: "```") { return String(body[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first < last { return String(trimmed[first...last]) }
        return trimmed
    }
}
enum ValidationStatus: String, Codable, Sendable { case valid, invalid, requiresProbe = "requires_probe", unsupported }
struct ValidatedCommand: Identifiable, Sendable { var command: MixCommand; var status: ValidationStatus; var message: String; var id: String { command.id } }
struct CommandValidator: Sendable {
    let implemented: Set<MixAction> = [.setVolume, .setPan, .setMute, .setSolo, .setPluginBypass, .setPluginParameter]
    func validate(_ plan: MixPlan, against snapshot: NormalizedSnapshot) -> [ValidatedCommand] { plan.actions.map { command in
        guard implemented.contains(command.action) else { return .init(command: command, status: .unsupported, message: "Executor does not implement \(command.action.rawValue).") }
        guard let track = snapshot.tracks.first(where: { $0.id == command.target.trackID || ($0.name.value != nil && $0.name.value == command.target.trackName) }) else { return .init(command: command, status: .requiresProbe, message: "Track is not present in current normalized facts.") }
        // Every implemented action carries a typed `parameters.value`; a plan that omits or mistypes it is malformed,
        // not merely unproven — "technically valid" must mean the value can actually be applied.
        switch command.action {
        case .setVolume, .setPan: if command.parameters["value"]?.numberValue == nil { return .init(command: command, status: .invalid, message: "\(command.action.rawValue) needs a numeric parameters.value.") }
        case .setMute, .setSolo, .setPluginBypass: if command.parameters["value"]?.boolValue == nil { return .init(command: command, status: .invalid, message: "\(command.action.rawValue) needs a boolean parameters.value.") }
        default: break
        }
        if command.action == .setPluginParameter || command.action == .setPluginBypass { guard let plugin = (track.channel?.plugins ?? []).first(where: { $0.id == command.target.pluginID || $0.name.value == command.target.pluginName }) else { return .init(command: command, status: .requiresProbe, message: "Plugin requires an inspect_plugin probe.") }; if command.action == .setPluginParameter { guard let parameter = plugin.parameters.first(where: { $0.id == command.target.parameterID || $0.name == command.target.parameterName }), let value = command.parameters["value"]?.numberValue else { return .init(command: command, status: .requiresProbe, message: "Parameter/value requires inspect_plugin_parameters probe.") }; if let range = parameter.range, !range.contains(value) { return .init(command: command, status: .invalid, message: "Value is outside reported parameter range.") } } }
        return .init(command: command, status: .valid, message: "Technically valid against current snapshot.")
    } }
}
