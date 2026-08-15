import Foundation

/// The truthful record of what happened to ONE plan action. `status` is one of `ExecutionStatus`'s values; `before` /
/// `after` are the control's re-read values around the write (never assumed from the plan), and `error` explains every
/// non-executed outcome in one honest sentence.
struct ExecutionResult: Codable, Identifiable, Sendable { var id: String { actionID }; var actionID: String; var status: String; var before: JSONValue?; var after: JSONValue?; var error: String? }
/// The four statuses an action can end in. `executed` is claimed only after the written value was re-read from Logic's
/// own control; `failed` means a live write was refused or did not verify; `not_executed` means nothing was attempted.
enum ExecutionStatus { static let executed = "executed"; static let failed = "failed"; static let dryRun = "dry_run"; static let notExecuted = "not_executed" }

/// What a live adapter may rely on: the normalized snapshot the plan was validated against. Adapters re-read every
/// live value themselves — the snapshot supplies identity (track names, captured strip evidence), never current values.
struct LiveExecutionContext: Sendable { var snapshot: NormalizedSnapshot }

/// A verified write mechanism for one family of Logic actions. An adapter must: locate its target from live AX
/// evidence (never blind coordinates), prove the write mechanism before the first real write, re-read the control
/// afterwards, and return an `ExecutionResult` whose `before`/`after` are those re-read values. `SafeExecutor` routes
/// a valid command to an adapter only in LIVE mode; an action no registered adapter supports keeps the honest refusal.
protocol LiveActionAdapter: Sendable {
    func supports(_ action: MixAction) -> Bool
    func execute(_ command: MixCommand, context: LiveExecutionContext) -> ExecutionResult
}

protocol CommandExecutor: Sendable { func execute(_ commands: [ValidatedCommand], mode: OperationMode) async -> [ExecutionResult] }
/// Sequential, safety-first execution. Only `status == .valid` commands are ever considered; DRY RUN never touches an
/// adapter; LIVE routes each valid command to the first registered adapter that supports its action. The queue is
/// result-oriented: a failed adapter execution (a write that was refused or did not verify) halts everything after it —
/// later actions were often reasoned against the state the failed one should have produced — and each halted action is
/// reported `not_executed` naming the failure that stopped the queue. An action with no registered adapter is refused
/// honestly without halting: nothing was attempted and nothing changed.
struct SafeExecutor: CommandExecutor {
    var adapters: [any LiveActionAdapter] = []
    var context: LiveExecutionContext? = nil
    func execute(_ commands: [ValidatedCommand], mode: OperationMode) async -> [ExecutionResult] {
        var results: [ExecutionResult] = []
        var haltedBy: String? = nil
        for item in commands {
            guard item.status == .valid else { results.append(.init(actionID: item.id, status: ExecutionStatus.notExecuted, before: nil, after: nil, error: item.message)); continue }
            guard mode == .live else { results.append(.init(actionID: item.id, status: ExecutionStatus.dryRun, before: nil, after: nil, error: nil)); continue }
            if let haltedBy { results.append(.init(actionID: item.id, status: ExecutionStatus.notExecuted, before: nil, after: nil, error: "Not executed: action \u{2018}\(haltedBy)\u{2019} failed earlier, so the rest of the queue was halted.")); continue }
            guard let context, let adapter = adapters.first(where: { $0.supports(item.command.action) }) else {
                results.append(.init(actionID: item.id, status: ExecutionStatus.failed, before: nil, after: nil, error: "No verified live Logic adapter is installed for this action."))
                continue
            }
            let result = adapter.execute(item.command, context: context)
            results.append(result)
            if result.status == ExecutionStatus.failed { haltedBy = item.id }
        }
        return results
    }
}
struct SnapshotDiff: Codable, Sendable { var changed: [String]; var unchanged: [String]; var errors: [String] }
struct DiffEngine: Sendable { func compare(before: NormalizedSnapshot, after: NormalizedSnapshot) -> SnapshotDiff {
    let beforeTracks = Dictionary(before.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); let afterTracks = Dictionary(after.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }); var changed: [String] = []; var unchanged: [String] = []
    for (id, old) in beforeTracks { guard let new = afterTracks[id] else { changed.append("Track removed: \(old.name.value ?? id)"); continue }; let pluginsChanged = (try? JSONEncoder().encode(old.channel?.plugins)) != (try? JSONEncoder().encode(new.channel?.plugins)); if old.channel?.volumeDB.value != new.channel?.volumeDB.value || old.channel?.pan.value != new.channel?.pan.value || old.channel?.mute.value != new.channel?.mute.value || old.channel?.solo.value != new.channel?.solo.value || pluginsChanged { changed.append("Changed: \(old.name.value ?? id)") } else { unchanged.append(old.name.value ?? id) } }
    for (id, new) in afterTracks where beforeTracks[id] == nil { changed.append("Track added: \(new.name.value ?? id)") }; return .init(changed: changed, unchanged: unchanged, errors: [])
} }
