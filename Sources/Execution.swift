import Foundation

struct ExecutionResult: Codable, Identifiable, Sendable { var id: String { actionID }; var actionID: String; var status: String; var before: JSONValue?; var after: JSONValue?; var error: String? }
protocol CommandExecutor: Sendable { func execute(_ commands: [ValidatedCommand], mode: OperationMode) async -> [ExecutionResult] }
struct SafeExecutor: CommandExecutor {
    func execute(_ commands: [ValidatedCommand], mode: OperationMode) async -> [ExecutionResult] { commands.map { item in
        guard item.status == .valid else { return .init(actionID: item.id, status: "not_executed", before: nil, after: nil, error: item.message) }
        guard mode == .live else { return .init(actionID: item.id, status: "dry_run", before: nil, after: nil, error: nil) }
        return .init(actionID: item.id, status: "failed", before: nil, after: nil, error: "No verified live Logic adapter is installed for this action.")
    } }
}
struct SnapshotDiff: Codable, Sendable { var changed: [String]; var unchanged: [String]; var errors: [String] }
struct DiffEngine: Sendable { func compare(before: NormalizedSnapshot, after: NormalizedSnapshot) -> SnapshotDiff {
    let beforeTracks = Dictionary(before.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); let afterTracks = Dictionary(after.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); var changed: [String] = []; var unchanged: [String] = []
    for (id, old) in beforeTracks { guard let new = afterTracks[id] else { changed.append("Track removed: \(old.name.value ?? id)"); continue }; let pluginsChanged = (try? JSONEncoder().encode(old.channel?.plugins)) != (try? JSONEncoder().encode(new.channel?.plugins)); if old.channel?.volumeDB.value != new.channel?.volumeDB.value || old.channel?.pan.value != new.channel?.pan.value || pluginsChanged { changed.append("Changed: \(old.name.value ?? id)") } else { unchanged.append(old.name.value ?? id) } }
    for (id, new) in afterTracks where beforeTracks[id] == nil { changed.append("Track added: \(new.name.value ?? id)") }; return .init(changed: changed, unchanged: unchanged, errors: [])
} }
