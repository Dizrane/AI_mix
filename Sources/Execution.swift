import Foundation

struct ExecutionResult: Codable, Identifiable, Sendable { var id: String { actionID }; var actionID: String; var status: String; var before: JSONValue?; var after: JSONValue?; var error: String? }
protocol CommandExecutor: Sendable { func execute(_ commands: [ValidatedCommand], mode: OperationMode, context: LiveExecutionContext?) async -> [ExecutionResult] }
extension CommandExecutor { func execute(_ commands: [ValidatedCommand], mode: OperationMode) async -> [ExecutionResult] { await execute(commands, mode: mode, context: nil) } }

/// Sequential, result-oriented execution. Only `status == .valid` commands are ever eligible; DRY RUN never touches
/// Logic; LIVE routes each command to the first registered adapter that implements its action — an action with no
/// adapter fails honestly, exactly as before any adapter existed. A failure is critical: the rest of the queue is not
/// executed (each remaining command reports `not_executed` naming the failed action), because later moves may assume
/// the earlier ones landed.
struct SafeExecutor: CommandExecutor {
    var adapters: [any LiveActionAdapter] = []
    func execute(_ commands: [ValidatedCommand], mode: OperationMode, context: LiveExecutionContext?) async -> [ExecutionResult] {
        var results: [ExecutionResult] = []
        var haltedBy: String? = nil
        for item in commands {
            if let haltedBy {
                results.append(.init(actionID: item.id, status: "not_executed", before: nil, after: nil, error: "Queue halted: action \u{2018}\(haltedBy)\u{2019} failed before this one ran."))
                continue
            }
            guard item.status == .valid else { results.append(.init(actionID: item.id, status: "not_executed", before: nil, after: nil, error: item.message)); continue }
            guard mode == .live else { results.append(.init(actionID: item.id, status: "dry_run", before: nil, after: nil, error: nil)); continue }
            guard let adapter = adapters.first(where: { $0.supports(item.command.action) }), let context else {
                results.append(.init(actionID: item.id, status: "failed", before: nil, after: nil, error: "No verified live Logic adapter is installed for this action."))
                haltedBy = item.id
                continue
            }
            let result = adapter.execute(item.command, context: context)
            results.append(result)
            if result.status == "failed" { haltedBy = item.id }
        }
        return results
    }
}
struct SnapshotDiff: Codable, Sendable { var changed: [String]; var unchanged: [String]; var errors: [String] }
struct DiffEngine: Sendable { func compare(before: NormalizedSnapshot, after: NormalizedSnapshot) -> SnapshotDiff {
    let beforeTracks = Dictionary(before.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); let afterTracks = Dictionary(after.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); var changed: [String] = []; var unchanged: [String] = []
    for (id, old) in beforeTracks { guard let new = afterTracks[id] else { changed.append("Track removed: \(old.name.value ?? id)"); continue }; let pluginsChanged = (try? JSONEncoder().encode(old.channel?.plugins)) != (try? JSONEncoder().encode(new.channel?.plugins)); if old.channel?.volumeDB.value != new.channel?.volumeDB.value || old.channel?.pan.value != new.channel?.pan.value || pluginsChanged { changed.append("Changed: \(old.name.value ?? id)") } else { unchanged.append(old.name.value ?? id) } }
    for (id, new) in afterTracks where beforeTracks[id] == nil { changed.append("Track added: \(new.name.value ?? id)") }; return .init(changed: changed, unchanged: unchanged, errors: [])
} }
