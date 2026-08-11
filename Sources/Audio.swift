import Foundation
import AVFoundation

// MARK: - Model

/// Whether the track audio has actually been captured on disk. Logic exposes no read-only audio-source path or PCM through AX, so automatic export is not possible; the honest default is `requires_user_export`.
enum AudioExtractionStatus: String, Codable, Sendable { case exported, requiresUserExport = "requires_user_export", failed, unavailable }

/// One Logic audio region, kept as provenance only. Timeline geometry is in raw timeline pixels (a shared scale across all lanes → relative alignment); seconds are not exposed by AX.
struct AudioRegionProvenance: Codable, Identifiable, Sendable {
    var regionID: String; var name: Fact<String>; var timelinePixelX: Fact<Double>; var timelinePixelWidth: Fact<Double>; var startSeconds: Fact<Double>; var durationSeconds: Fact<Double>; var axPath: String
    var id: String { regionID }
}

/// The export unit is ONE Logic track → one WAV. Its regions are recorded for provenance but are never split into separate assets.
/// `expectedExportPath` is the stable target (always known); `actualExportedPath` is known only when a real file is found on disk.
struct AudioAsset: Codable, Identifiable, Sendable {
    var audioID: String; var logicalTrackID: String; var trackName: Fact<String>
    var expectedExportPath: String; var actualExportedPath: Fact<String>
    var sourceFile: Fact<String>; var status: AudioExtractionStatus; var statusReason: String?
    var regions: [AudioRegionProvenance]
    var durationSeconds: Fact<Double>; var sampleRate: Fact<Double>; var channels: Fact<Int>; var bitDepth: Fact<Int>; var format: Fact<String>
    var trackAXPath: String?
    var id: String { audioID }
    var regionCount: Int { regions.count }
    var regionIDs: [String] { regions.map(\.regionID) }
}

struct AudioExtractionSummary: Codable, Sendable { var logicTracks: Int; var audioRegions: Int; var assets: Int; var exported: Int; var requiresUserExport: Int; var failed: Int }

struct AudioManifest: Codable, Sendable {
    var schemaVersion = "1.0"; var generatedAt = Date(); var assets: [AudioAsset]; var summary: AudioExtractionSummary
    init(assets: [AudioAsset]) {
        self.assets = assets
        self.summary = AudioExtractionSummary(logicTracks: assets.count, audioRegions: assets.reduce(0) { $0 + $1.regions.count }, assets: assets.count, exported: assets.filter { $0.status == .exported }.count, requiresUserExport: assets.filter { $0.status == .requiresUserExport }.count, failed: assets.filter { $0.status == .failed }.count)
    }
}

extension AudioManifest {
    /// Compact, human- and LLM-readable Markdown for "Copy Audio Manifest". Facts only — no musical interpretation.
    func markdown() -> String {
        var out = ["# AUDIO ASSETS", "", "One WAV per Logic track. Track names are the user's own Logic names (facts). Region lists are provenance only. This file carries no musical interpretation — roles (lead/double/backing/beat/…) are for you to decide by listening.", "", "- Tracks: \(summary.assets) · Exported: \(summary.exported) · Requires export: \(summary.requiresUserExport)\(summary.failed > 0 ? " · Failed: \(summary.failed)" : "")"]
        for asset in assets {
            out += ["", "## \(asset.audioID)", "", "- Logic Track: \(asset.trackName.value ?? "unknown")", "- logicalTrackID: \(asset.logicalTrackID)", "- WAV: \(asset.actualExportedPath.value ?? asset.expectedExportPath)", "- Status: \(asset.status.rawValue)", "- Regions: \(asset.regionCount)"]
        }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - File probe (read-only technical metadata)

/// Reads technical metadata from an already-exported WAV. Opens the file read-only via AVAudioFile and never writes to it.
struct AudioFileProbe: Sendable {
    struct Metadata: Sendable { var durationSeconds: Double; var sampleRate: Double; var channels: Int; var bitDepth: Int?; var format: String }
    func read(_ url: URL) -> Metadata? {
        guard FileManager.default.fileExists(atPath: url.path), let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.fileFormat; let asbd = format.streamDescription.pointee
        let duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
        let bits = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        let name = asbd.mFormatID == kAudioFormatLinearPCM ? "PCM" : fourCharCode(asbd.mFormatID)
        return .init(durationSeconds: duration, sampleRate: format.sampleRate, channels: Int(format.channelCount), bitDepth: bits, format: name)
    }
    private func fourCharCode(_ code: AudioFormatID) -> String { let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]; return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown" }
}

// MARK: - Extractor

/// Read-only discovery of audio material. One asset per Logic audio track (arrange lane); regions grouped under the track, never exported individually.
struct AudioAssetExtractor: Sendable {
    func extract(raw: RawSnapshot, normalized: NormalizedSnapshot, audioDirectory: URL?, probe: AudioFileProbe = AudioFileProbe()) -> [AudioAsset] {
        let lanes = laneAreas(in: raw.root).sorted { ($0.ordinal, $0.axPath) < ($1.ordinal, $1.axPath) }
        let ordinalToLogicalID = Dictionary(normalized.tracks.compactMap { track in track.header?.ordinal.value.map { ($0, track.logicalTrackID) } }, uniquingKeysWith: { first, _ in first })
        var regionCounter = 0
        return lanes.enumerated().map { index, lane in
            let audioID = String(format: "audio_track_%03d", index + 1)
            let logicalTrackID = ordinalToLogicalID[lane.ordinal] ?? "track_\(lane.ordinal)"
            let regions: [AudioRegionProvenance] = lane.regionNodes.sorted { (pixelX($0) ?? 0, $0.id) < (pixelX($1) ?? 0, $1.id) }.map { node in
                regionCounter += 1
                let x = pixelX(node).map { Fact.known($0, source: node.id) } ?? .unavailable
                let w = pixelWidth(node).map { Fact.known($0, source: node.id) } ?? .unavailable
                return AudioRegionProvenance(regionID: String(format: "region_%03d", regionCounter), name: node.description.map { Fact.known($0, source: node.id) } ?? .unavailable, timelinePixelX: x, timelinePixelWidth: w, startSeconds: .init(state: .requiresProbe, value: nil, source: node.id), durationSeconds: .init(state: .requiresProbe, value: nil, source: node.id), axPath: node.id)
            }
            let expected = "audio/\(sanitizedFileName(lane.name)).wav"
            if let dir = audioDirectory, let fileURL = resolveExportedFile(audioID: audioID, trackName: lane.name, in: dir), let meta = probe.read(fileURL) {
                return AudioAsset(audioID: audioID, logicalTrackID: logicalTrackID, trackName: .known(lane.name, source: lane.axPath), expectedExportPath: expected, actualExportedPath: .known("audio/\(fileURL.lastPathComponent)", source: fileURL.path), sourceFile: .unavailable, status: .exported, statusReason: nil, regions: regions, durationSeconds: .known(meta.durationSeconds), sampleRate: .known(meta.sampleRate), channels: .known(meta.channels), bitDepth: meta.bitDepth.map { .known($0) } ?? .unavailable, format: .known(meta.format), trackAXPath: lane.axPath)
            }
            return AudioAsset(audioID: audioID, logicalTrackID: logicalTrackID, trackName: .known(lane.name, source: lane.axPath), expectedExportPath: expected, actualExportedPath: .unavailable, sourceFile: .unavailable, status: .requiresUserExport, statusReason: "No WAV found yet. Export this track manually (File ▸ Export ▸ All Tracks as Audio Files…) into the audio folder, then Refresh Export Status.", regions: regions, durationSeconds: .unavailable, sampleRate: .unavailable, channels: .unavailable, bitDepth: .unavailable, format: .unavailable, trackAXPath: lane.axPath)
        }
    }

    private struct Lane { var axPath: String; var ordinal: Int; var name: String; var regionNodes: [RawAccessibilityNode] }
    private func laneAreas(in root: RawAccessibilityNode) -> [Lane] {
        var result: [Lane] = []; var seenOrdinal = Set<Int>()
        func visit(_ node: RawAccessibilityNode) {
            if node.role == "AXLayoutArea", let desc = node.description, let ordinal = parseOrdinal(desc), seenOrdinal.insert(ordinal).inserted {
                let regionNodes = node.children.filter { $0.role == "AXLayoutItem" }
                if !regionNodes.isEmpty { result.append(Lane(axPath: node.id, ordinal: ordinal, name: trackName(desc), regionNodes: regionNodes)) }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return result
    }
    /// Unambiguous WAV↔track match: the canonical `audio_track_NNN.wav` first, then a file named after the Logic track (what Logic's "All Tracks as Audio Files…" produces). No manual path entry needed.
    private func resolveExportedFile(audioID: String, trackName: String, in directory: URL) -> URL? {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
        let exts = ["wav", "aif", "aiff", "caf"]
        let stems = [trackName, sanitizedFileName(trackName), audioID]
        // Exact match first (e.g. "Audio 3.wav").
        for stem in stems { for ext in exts where files.contains("\(stem).\(ext)") { return directory.appendingPathComponent("\(stem).\(ext)") } }
        // Then Logic's own export naming which appends an increment: "<Track Name>_1.wav".
        for stem in stems {
            let escaped = NSRegularExpression.escapedPattern(for: stem)
            for file in files.sorted() { for ext in exts where file.range(of: "^\(escaped)_\\d+\\.\(ext)$", options: [.regularExpression, .caseInsensitive]) != nil {
                return directory.appendingPathComponent(file)
            } }
        }
        return nil
    }
    /// Keeps the Logic name verbatim in facts, but makes a filesystem-safe filename (Logic itself replaces path separators on export).
    private func sanitizedFileName(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }
    private func pixelX(_ node: RawAccessibilityNode) -> Double? { node.position.flatMap { Double($0.split(separator: ",").first ?? "") } }
    private func pixelWidth(_ node: RawAccessibilityNode) -> Double? { node.size.flatMap { Double($0.split(separator: "x").first ?? "") } }
    private func parseOrdinal(_ text: String) -> Int? { guard let range = text.range(of: "Track\\s+(\\d+)", options: [.regularExpression, .caseInsensitive]) else { return nil }; return Int(text[range].split(whereSeparator: { !$0.isNumber }).first ?? "") }
    private func trackName(_ title: String) -> String { guard let first = title.firstIndex(of: "\u{201C}"), let last = title.lastIndex(of: "\u{201D}"), first < last else { return title }; return String(title[title.index(after: first)..<last]) }
}
