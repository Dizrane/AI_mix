import Foundation

/// Overall readiness of the AI Mix Analysis package. `error` marks integrity problems that must be fixed; `incomplete` means some WAVs are still missing but a metadata package is fine.
enum ReadinessState: String, Codable, Sendable { case ready, incomplete, error, notReady = "not_ready" }

/// Pure, testable evaluation of whether the package can be trusted, derived from immutable facts only (never mutates them).
struct PackageReadiness: Sendable {
    struct MissingAudio: Sendable { var logicalTrackID: String; var name: String }
    var logicAnalysis: Bool; var trackDiscovery: Bool; var audioTotal: Int; var audioExported: Int; var provenanceOK: Bool
    var errors: [String]; var missingAudio: [MissingAudio]; var overall: ReadinessState

    static func evaluate(snapshot: NormalizedSnapshot?, assets: [AudioAsset]) -> PackageReadiness {
        let logic = snapshot != nil
        let hasTracks = !(snapshot?.tracks.isEmpty ?? true)
        let trackIDs = Set(snapshot?.tracks.map(\.logicalTrackID) ?? [])
        var errors: [String] = []
        for asset in assets where !trackIDs.contains(asset.logicalTrackID) { errors.append("Audio asset \(asset.audioID) references unknown logicalTrackID \(asset.logicalTrackID) (orphan provenance).") }
        for (id, group) in Dictionary(grouping: assets, by: \.logicalTrackID) where group.count > 1 { errors.append("logicalTrackID \(id) has \(group.count) audio assets (expected exactly one).") }
        let provenanceOK = errors.isEmpty
        let exported = assets.filter { $0.status == .exported }.count
        let missing = assets.filter { $0.status != .exported }.map { MissingAudio(logicalTrackID: $0.logicalTrackID, name: $0.trackName.value ?? $0.audioID) }
        let overall: ReadinessState
        if !logic || !hasTracks { overall = .notReady }
        else if !errors.isEmpty { overall = .error }
        else if assets.isEmpty || exported < assets.count { overall = .incomplete }
        else { overall = .ready }
        return .init(logicAnalysis: logic, trackDiscovery: hasTracks, audioTotal: assets.count, audioExported: exported, provenanceOK: provenanceOK, errors: errors, missingAudio: missing, overall: overall)
    }
}

/// Top-level manifest.json written alongside the package, describing its contents and the WAV↔track mapping.
struct PackageManifest: Codable, Sendable {
    struct TrackRef: Codable, Sendable { var logicalTrackID: String; var logicTrackName: String; var wav: String?; var expectedExportPath: String; var status: String; var regionCount: Int; var regionIDs: [String] }
    var schemaVersion = "2.0"; var project: String; var generatedAt = Date(); var assets: Int; var exported: Int; var requiresExport: Int; var tracks: [TrackRef]
    init(project: String, assets audioAssets: [AudioAsset]) {
        self.project = project
        self.assets = audioAssets.count
        self.exported = audioAssets.filter { $0.status == .exported }.count
        self.requiresExport = audioAssets.filter { $0.status == .requiresUserExport }.count
        self.tracks = audioAssets.map { TrackRef(logicalTrackID: $0.logicalTrackID, logicTrackName: $0.trackName.value ?? "unknown", wav: $0.actualExportedPath.value, expectedExportPath: $0.expectedExportPath, status: $0.status.rawValue, regionCount: $0.regionCount, regionIDs: $0.regionIDs) }
    }
}
