import Foundation
import AppKit

/// Stores exactly one current analysis inside Data/current next to the application bundle.
actor SessionStore {
    let root: URL; let sessionURL: URL
    init(root: URL? = nil) throws { let base = root ?? Self.dataRoot(); self.root = base; self.sessionURL = base.appendingPathComponent("current", isDirectory: true); try Self.createStructure(at: sessionURL) }
    /// Deletes only the app-owned `current` working directory and recreates it before a new read-only scan.
    func resetForNewAnalysis() throws { let manager = FileManager.default; if manager.fileExists(atPath: sessionURL.path) { try manager.removeItem(at: sessionURL) }; try Self.createStructure(at: sessionURL) }
    func save<T: Encodable>(_ value: T, folder: String, name: String) throws -> URL { let url = sessionURL.appendingPathComponent(folder).appendingPathComponent(name); try JSONEncoder.pretty.encode(value).write(to: url, options: .atomic); return url }
    func saveText(_ value: String, name: String) throws -> URL { let url = sessionURL.appendingPathComponent(name); try value.data(using: .utf8)?.write(to: url, options: .atomic); return url }
    func saveText(_ value: String, folder: String, name: String) throws -> URL { let url = sessionURL.appendingPathComponent(folder).appendingPathComponent(name); try value.data(using: .utf8)?.write(to: url, options: .atomic); return url }
    /// URL of an app-owned working folder inside `current` (e.g. "audio", "metadata"). It does not create or delete anything.
    func folderURL(_ folder: String) -> URL { sessionURL.appendingPathComponent(folder, isDirectory: true) }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([sessionURL]) }
    func reveal(folder: String) { NSWorkspace.shared.activateFileViewerSelecting([folderURL(folder)]) }
    func reveal(url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    /// Clears only audio files inside the app-owned current/audio working folder before a fresh export. Never touches other locations.
    func clearAudioFiles() { let dir = folderURL("audio"); let manager = FileManager.default; guard let files = try? manager.contentsOfDirectory(atPath: dir.path) else { return }; for file in files where ["wav", "aif", "aiff", "caf"].contains((file as NSString).pathExtension.lowercased()) { try? manager.removeItem(at: dir.appendingPathComponent(file)) } }
    /// Assembles current/package with the markdown, JSON snapshots and only the REAL exported WAVs, then best-effort zips it. Never fabricates files.
    func savePackage(projectName: String, markdown: String, snapshot: NormalizedSnapshot, audioManifest: AudioManifest, packageManifest: PackageManifest, assets: [AudioAsset]) throws -> (folder: URL, zip: URL?, copiedWAVs: Int) {
        let manager = FileManager.default
        let pkg = sessionURL.appendingPathComponent("package", isDirectory: true)
        if manager.fileExists(atPath: pkg.path) { try manager.removeItem(at: pkg) }
        try manager.createDirectory(at: pkg.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: pkg.appendingPathComponent("AI_MIX_ANALYSIS.md"), options: .atomic)
        try JSONEncoder.pretty.encode(snapshot).write(to: pkg.appendingPathComponent("logic_snapshot.json"), options: .atomic)
        try JSONEncoder.pretty.encode(audioManifest).write(to: pkg.appendingPathComponent("audio_manifest.json"), options: .atomic)
        try JSONEncoder.pretty.encode(packageManifest).write(to: pkg.appendingPathComponent("manifest.json"), options: .atomic)
        var copied = 0
        for asset in assets where asset.status == .exported {
            guard let relative = asset.actualExportedPath.value else { continue }
            let source = sessionURL.appendingPathComponent(relative)
            let destination = pkg.appendingPathComponent(relative)
            guard manager.fileExists(atPath: source.path) else { continue }
            if manager.fileExists(atPath: destination.path) { try? manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination); copied += 1
        }
        let safeName = projectName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let zipURL = sessionURL.appendingPathComponent("AI_Mix_Analysis_\(safeName.isEmpty ? "project" : safeName).zip")
        if manager.fileExists(atPath: zipURL.path) { try? manager.removeItem(at: zipURL) }
        let zip: URL? = ((try? runDitto(source: pkg, dest: zipURL)) == true) ? zipURL : nil
        return (pkg, zip, copied)
    }
    private func runDitto(source: URL, dest: URL) throws -> Bool {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, dest.path]
        try process.run(); process.waitUntilExit(); return process.terminationStatus == 0
    }
    private static func createStructure(at current: URL) throws { for folder in ["raw", "normalized", "audio", "metadata", "prompts", "responses", "logs", "temporary"] { try FileManager.default.createDirectory(at: current.appendingPathComponent(folder), withIntermediateDirectories: true) } }
    private static func dataRoot() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" { return bundleURL.deletingLastPathComponent().appendingPathComponent("Data", isDirectory: true) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("Data", isDirectory: true)
    }
    /// The AI Mix Assistant root — the folder that contains the `.app` bundle AND its `Data/` (the same source of truth as `dataRoot`). Nil when not running from a `.app`, so the distributable root cannot be determined and full deletion must be blocked.
    static func applicationRootURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL.deletingLastPathComponent().standardizedFileURL
    }
}
extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e } }
