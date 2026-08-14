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
    /// Locally computed DSP facts about the exported WAV file. Present only for `exported` assets whose final file was
    /// really analyzed (AppModel attaches them after the file set is confirmed stable); never fabricated for missing files.
    var metrics: AudioMetrics? = nil
    var id: String { audioID }
    var regionCount: Int { regions.count }
    var regionIDs: [String] { regions.map(\.regionID) }
}

struct AudioExtractionSummary: Codable, Sendable { var logicTracks: Int; var audioRegions: Int; var assets: Int; var exported: Int; var requiresUserExport: Int; var failed: Int }

/// The export dialog's level-affecting settings as facts: `known` only when the automation really read the control off
/// Logic's own dialog when it launched the export, `unavailable` when the dialog did not expose it — or when the WAVs
/// were exported outside this app session, where nothing about the dialog was observed at all. Normalize is the one
/// that decides whether the files are level evidence: any known value other than Off is switched to Off by the app
/// itself before exporting (a switch that fails cancels the export up front), so a recorded value is either "Off" or
/// honestly missing — and `normalizeSwitchedFrom` records the value the dialog showed before the app switched it.
struct ExportSettingsFacts: Codable, Sendable {
    var format: Fact<String>; var bitDepth: Fact<String>; var normalize: Fact<String>
    /// The value Normalize showed BEFORE the app switched it to Off — the one deliberate dialog write the automation
    /// performs; `unavailable` when Normalize was already Off, unreadable, or the dialog was never observed.
    var normalizeSwitchedFrom: Fact<String> = .unavailable
    /// The bounce dialog's format table (which format checkboxes were checked when the bounce was launched); the track
    /// export dialog has a single format pop-up instead, so there this fact is honestly `unavailable`.
    var formats: Fact<[FormatSelection]> = .unavailable
    /// The caption of the uncompressed PCM format row the app checked because the bounce dialog opened with no PCM
    /// format checked — half of the second deliberate dialog write (a check that fails cancels the bounce up front);
    /// `unavailable` when PCM was already checked, the table unreadable, or the dialog was never observed.
    var pcmFormatCheckedByApp: Fact<String> = .unavailable
    /// The captions of the checked compressed format rows the app unchecked so the bounce writes exactly one PCM
    /// file — the other half of that write; `unavailable` when none were checked, the table unreadable, or the
    /// dialog was never observed. A row that refused to uncheck stays visible as checked in `formats`.
    var formatsUncheckedByApp: Fact<[String]> = .unavailable
    /// The transport Cycle state proven before the bounce dialog opened ("Off" — Cycle constrains Logic's bounce to
    /// the cycle section, so this is what makes the bounce range the whole project); `unavailable` when no Cycle
    /// control could be read, or for the track export, which Cycle does not affect.
    var cycle: Fact<String> = .unavailable
    /// The value Cycle showed BEFORE the app switched it off — the third deliberate write; `unavailable` when Cycle
    /// was already off, unreadable, or never had to be touched.
    var cycleSwitchedFrom: Fact<String> = .unavailable
    init(settings: ExportDialogSettings) {
        format = settings.format.map { .known($0, source: "export dialog format pop-up") } ?? .unavailable
        bitDepth = settings.bitDepth.map { .known($0, source: "export dialog bit-depth pop-up") } ?? .unavailable
        normalize = settings.normalize.map { .known($0, source: "export dialog Normalize control") } ?? .unavailable
        normalizeSwitchedFrom = settings.normalizeSwitchedFrom.map { .known($0, source: "export dialog Normalize control before the app switched it to Off") } ?? .unavailable
        formats = settings.formats.map { .known($0, source: "bounce dialog format table") } ?? .unavailable
        pcmFormatCheckedByApp = settings.pcmFormatCheckedByApp.map { .known($0, source: "bounce dialog format table row the app checked") } ?? .unavailable
        formatsUncheckedByApp = settings.formatsUncheckedByApp.map { .known($0, source: "bounce dialog format table rows the app unchecked") } ?? .unavailable
        cycle = settings.cycle.map { .known($0, source: "Logic transport Cycle control, read before the bounce dialog opened") } ?? .unavailable
        cycleSwitchedFrom = settings.cycleSwitchedFrom.map { .known($0, source: "Logic transport Cycle control before the app switched it off") } ?? .unavailable
    }
    enum CodingKeys: String, CodingKey { case format, bitDepth, normalize, normalizeSwitchedFrom, formats, pcmFormatCheckedByApp, formatsUncheckedByApp, cycle, cycleSwitchedFrom }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Fact<String>.self, forKey: .format)
        bitDepth = try container.decode(Fact<String>.self, forKey: .bitDepth)
        normalize = try container.decode(Fact<String>.self, forKey: .normalize)
        normalizeSwitchedFrom = try container.decodeIfPresent(Fact<String>.self, forKey: .normalizeSwitchedFrom) ?? .unavailable
        formats = try container.decodeIfPresent(Fact<[FormatSelection]>.self, forKey: .formats) ?? .unavailable
        pcmFormatCheckedByApp = try container.decodeIfPresent(Fact<String>.self, forKey: .pcmFormatCheckedByApp) ?? .unavailable
        formatsUncheckedByApp = try container.decodeIfPresent(Fact<[String]>.self, forKey: .formatsUncheckedByApp) ?? .unavailable
        cycle = try container.decodeIfPresent(Fact<String>.self, forKey: .cycle) ?? .unavailable
        cycleSwitchedFrom = try container.decodeIfPresent(Fact<String>.self, forKey: .cycleSwitchedFrom) ?? .unavailable
    }
}

/// The bounced mix — Logic's Stereo Out captured through File ▸ Bounce: the sum through the whole master chain, the
/// reference the per-track WAVs are judged against (overall loudness, balance and masking exist only in the sum).
/// Deliberately NOT an `AudioAsset`: it maps to no Logic track, so it stays outside track provenance and readiness.
/// Every field is a fact about the real file found on disk; the asset exists only when such a file was validated.
struct MixBounceAsset: Codable, Sendable {
    var relativePath: String // "mix/<actual file name>" — the file proven on disk
    var durationSeconds: Fact<Double>; var sampleRate: Fact<Double>; var channels: Fact<Int>; var bitDepth: Fact<Int>; var format: Fact<String>
    /// The bounce dialog's level-affecting settings when THIS app launched the bounce; nil for a bounce it did not observe.
    var bounceSettings: ExportSettingsFacts?
    /// Locally computed DSP facts about the bounced file — same analyzer, same honesty as the per-track metrics.
    var metrics: AudioMetrics?

    /// The one real audio file in the mix folder, probed and measured. The newest readable file wins, so a leftover
    /// from an older bounce never shadows the file just written; an unreadable (mid-write) file is skipped, and with
    /// no readable audio at all the answer is nil — a mix bounce is never fabricated from directory contents.
    static func resolve(in directory: URL, settings: ExportSettingsFacts?, probe: AudioFileProbe = AudioFileProbe(), metricsAnalyzer: AudioMetricsAnalyzer = AudioMetricsAnalyzer()) -> MixBounceAsset? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
        func modified(_ name: String) -> Date { (try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date ?? .distantPast }
        let candidates = names.filter { ["wav", "aif", "aiff", "caf"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted { (modified($0), $0) > (modified($1), $1) }
        for name in candidates {
            let url = directory.appendingPathComponent(name)
            guard let meta = probe.read(url) else { continue }
            return MixBounceAsset(relativePath: "mix/\(name)", durationSeconds: .known(meta.durationSeconds), sampleRate: .known(meta.sampleRate), channels: .known(meta.channels), bitDepth: meta.bitDepth.map { .known($0) } ?? .unavailable, format: .known(meta.format), bounceSettings: settings, metrics: metricsAnalyzer.analyze(fileAt: url))
        }
        return nil
    }
}

extension [FormatSelection] {
    /// One human- and LLM-readable line for a read format table: every row with its own checked state, facts only.
    var caption: String { map { "\($0.name): \($0.enabled ? "checked" : "unchecked")" }.joined(separator: " · ") }
}

struct AudioManifest: Codable, Sendable {
    var schemaVersion = "1.7"; var generatedAt = Date(); var assets: [AudioAsset]; var summary: AudioExtractionSummary
    /// Nil when this session never observed Logic's export dialog (manual export, or the app was restarted since).
    var exportSettings: ExportSettingsFacts?
    /// The bounced Stereo Out mix; nil when no bounce file exists — its absence is stated, never papered over.
    var mix: MixBounceAsset?
    init(assets: [AudioAsset], exportSettings: ExportSettingsFacts? = nil, mix: MixBounceAsset? = nil) {
        self.assets = assets
        self.exportSettings = exportSettings
        self.mix = mix
        self.summary = AudioExtractionSummary(logicTracks: assets.count, audioRegions: assets.reduce(0) { $0 + $1.regions.count }, assets: assets.count, exported: assets.filter { $0.status == .exported }.count, requiresUserExport: assets.filter { $0.status == .requiresUserExport }.count, failed: assets.filter { $0.status == .failed }.count)
    }
}

extension AudioManifest {
    /// Compact, human- and LLM-readable Markdown for "Copy Audio Manifest". Facts only — no musical interpretation.
    func markdown() -> String {
        var out = ["# AUDIO ASSETS", "", "One WAV per Logic track. Track names are the user's own Logic names (facts). Region lists are provenance only. This file carries no musical interpretation — roles (lead/double/backing/beat/…) are for you to decide by listening.", "", "- Tracks: \(summary.assets) · Exported: \(summary.exported) · Requires export: \(summary.requiresUserExport)\(summary.failed > 0 ? " · Failed: \(summary.failed)" : "")"]
        func setting(_ fact: Fact<String>) -> String { fact.value ?? fact.state.rawValue }
        if let s = exportSettings {
            out += ["- Export dialog settings (read from Logic's own dialog when the export was launched): Format \(setting(s.format)) · Bit depth \(setting(s.bitDepth)) · Normalize \(setting(s.normalize))"]
            if let from = s.normalizeSwitchedFrom.value { out += ["- Normalize showed \u{201C}\(from)\u{201D} when the dialog opened; the app switched it to Off (and verified the switch) before the export, so the levels were not rewritten."] }
            if s.normalize.value == nil { out += ["- Normalize could not be read from the dialog, so whether the exported levels were rewritten is unverified — treat relative loudness between the WAVs with care unless the user confirms Normalize was Off."] }
        } else {
            out += ["- Export dialog settings: unavailable — this session did not observe Logic's export dialog, so whether Normalize altered the exported levels is unverified."]
        }
        if let mix {
            out += ["- Mix (Stereo Out): \(mix.relativePath) — the bounced sum through the master chain; per-track WAVs do not contain it."]
            if let from = mix.bounceSettings?.cycleSwitchedFrom.value { out += ["- Logic's transport Cycle showed \u{201C}\(from)\u{201D} before the bounce; the app switched it Off (and verified) before opening the bounce dialog, so the whole project was bounced rather than the cycle section."] }
            if let from = mix.bounceSettings?.normalizeSwitchedFrom.value { out += ["- Bounce dialog Normalize showed \u{201C}\(from)\u{201D}; the app switched it to Off (and verified the switch) before the bounce, so the mix level was not rewritten."] }
            if let row = mix.bounceSettings?.pcmFormatCheckedByApp.value { out += ["- The bounce dialog opened with no uncompressed PCM format checked; the app checked \u{201C}\(row)\u{201D} (and verified the check) before the bounce, so a real PCM mix file was written."] }
            if let rows = mix.bounceSettings?.formatsUncheckedByApp.value { out += ["- The bounce dialog also had \(rows.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")) checked; the app unchecked \(rows.count == 1 ? "it" : "them") (and verified) before the bounce, so exactly one PCM mix file was written."] }
            if let formats = mix.bounceSettings?.formats.value { out += ["- Bounce dialog formats (read from Logic's own format table when the bounce was launched): \(formats.caption)"] }
        } else {
            out += ["- Mix (Stereo Out): none — no bounced mix file exists, so the sum (overall loudness, balance, masking) is not part of this delivery."]
        }
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
        let name = asbd.mFormatID == kAudioFormatLinearPCM ? (asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "PCM (float)" : "PCM (integer)") : fourCharCode(asbd.mFormatID)
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
    /// Package-builder entry point: re-resolve an asset's REAL exported file on disk (same matching as extraction). Used for a final filesystem resolution before copying into the package.
    func resolvedFile(audioID: String, trackName: String, in directory: URL) -> URL? { resolveExportedFile(audioID: audioID, trackName: trackName, in: directory) }
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
