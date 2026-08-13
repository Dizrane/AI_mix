import Foundation
import AppKit

/// Stores exactly one current analysis inside Data/current next to the application bundle.
actor SessionStore {
    let root: URL; let sessionURL: URL
    init(root: URL? = nil) throws {
        let base: URL
        if let root { base = root } else {
            if Bundle.main.bundleURL.pathExtension == "app", let shared = Self.sharedContainerName(Bundle.main.bundleURL.deletingLastPathComponent()) { throw StorageError.appInSharedLocation(shared) }
            base = Self.dataRoot()
        }
        self.root = base; self.sessionURL = base.appendingPathComponent("current", isDirectory: true); try Self.createStructure(at: sessionURL)
    }
    /// Deletes only the app-owned `current` working directory and recreates it before a new read-only scan.
    func resetForNewAnalysis() throws { let manager = FileManager.default; if manager.fileExists(atPath: sessionURL.path) { try manager.removeItem(at: sessionURL) }; try Self.createStructure(at: sessionURL) }
    func save<T: Encodable>(_ value: T, folder: String, name: String) throws -> URL { let url = sessionURL.appendingPathComponent(folder).appendingPathComponent(name); try JSONEncoder.pretty.encode(value).write(to: url, options: .atomic); return url }
    func saveText(_ value: String, name: String) throws -> URL { let url = sessionURL.appendingPathComponent(name); try value.data(using: .utf8)?.write(to: url, options: .atomic); return url }
    func saveText(_ value: String, folder: String, name: String) throws -> URL { let url = sessionURL.appendingPathComponent(folder).appendingPathComponent(name); try value.data(using: .utf8)?.write(to: url, options: .atomic); return url }
    /// URL of an app-owned working folder inside `current` (e.g. "audio", "metadata"). It does not create or delete anything.
    func folderURL(_ folder: String) -> URL { sessionURL.appendingPathComponent(folder, isDirectory: true) }
    func reveal() { reveal(url: sessionURL) }
    func reveal(folder: String) { reveal(url: folderURL(folder)) }
    /// Revealing in Finder is AppKit UI work and belongs on the main actor: called straight from this actor it would run on a
    /// background executor, the same off-main AppKit use that kills the process elsewhere. The store only decides which URL.
    nonisolated func reveal(url: URL) { Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    /// Clears only audio files inside the app-owned current/audio working folder before a fresh export. Never touches other locations.
    func clearAudioFiles() { let dir = folderURL("audio"); let manager = FileManager.default; guard let files = try? manager.contentsOfDirectory(atPath: dir.path) else { return }; for file in files where ["wav", "aif", "aiff", "caf"].contains((file as NSString).pathExtension.lowercased()) { try? manager.removeItem(at: dir.appendingPathComponent(file)) } }
    /// Assembles current/package with the markdown, JSON snapshots and the REAL exported WAVs, then best-effort zips it. Never fabricates files.
    /// Each exported asset is resolved against the confirmed audio directory (current/audio) at copy time — `actualExportedPath` if it still
    /// exists, otherwise re-resolved via the extractor — validated with AVAudioFile, copied, and the destination is verified. `copiedWAVs`
    /// counts only files that were actually written; `missing` names any exported asset whose WAV could not be resolved/validated/copied.
    func savePackage(projectName: String, markdown: String, snapshot: NormalizedSnapshot, audioManifest: AudioManifest, packageManifest: PackageManifest, assets: [AudioAsset], audioExtractor: AudioAssetExtractor, probe: AudioFileProbe) throws -> (folder: URL, zip: URL?, copiedWAVs: Int, missing: [String]) {
        let manager = FileManager.default
        let audioDir = folderURL("audio") // the confirmed source directory: current/audio
        let pkg = sessionURL.appendingPathComponent("package", isDirectory: true)
        if manager.fileExists(atPath: pkg.path) { try manager.removeItem(at: pkg) }
        try manager.createDirectory(at: pkg.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: pkg.appendingPathComponent("AI_MIX_ANALYSIS.md"), options: .atomic)
        try JSONEncoder.pretty.encode(snapshot).write(to: pkg.appendingPathComponent("logic_snapshot.json"), options: .atomic)
        try JSONEncoder.pretty.encode(audioManifest).write(to: pkg.appendingPathComponent("audio_manifest.json"), options: .atomic)
        try JSONEncoder.pretty.encode(packageManifest).write(to: pkg.appendingPathComponent("manifest.json"), options: .atomic)
        var copied = 0; var missing: [String] = []
        for asset in assets where asset.status == .exported {
            let label = asset.trackName.value ?? asset.audioID
            // 1. Final filesystem resolution: prefer actualExportedPath if the file still exists, else re-resolve the real file in current/audio.
            var source: URL? = nil
            if let relative = asset.actualExportedPath.value {
                let candidate = sessionURL.appendingPathComponent(relative)
                if manager.fileExists(atPath: candidate.path) { source = candidate }
            }
            if source == nil { source = audioExtractor.resolvedFile(audioID: asset.audioID, trackName: asset.trackName.value ?? "", in: audioDir) }
            guard let realFile = source, manager.fileExists(atPath: realFile.path) else { missing.append("\(label): no WAV found in current/audio"); continue }
            // 2. Validate the real file via AVAudioFile before counting it.
            guard probe.read(realFile) != nil else { missing.append("\(label): \(realFile.lastPathComponent) is not a readable audio file"); continue }
            // 3. Copy the actual file into package/audio/<actual filename>, then 4. verify the destination exists.
            let destination = pkg.appendingPathComponent("audio").appendingPathComponent(realFile.lastPathComponent)
            if manager.fileExists(atPath: destination.path) { try? manager.removeItem(at: destination) }
            do { try manager.copyItem(at: realFile, to: destination) } catch { missing.append("\(label): copy failed (\(error.localizedDescription))"); continue }
            if manager.fileExists(atPath: destination.path) { copied += 1 } else { missing.append("\(label): destination missing after copy") }
        }
        let safeName = projectName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let zipURL = sessionURL.appendingPathComponent("AI_Mix_Analysis_\(safeName.isEmpty ? "project" : safeName).zip")
        if manager.fileExists(atPath: zipURL.path) { try? manager.removeItem(at: zipURL) }
        let zip: URL? = ((try? runDitto(source: pkg, dest: zipURL)) == true) ? zipURL : nil
        return (pkg, zip, copied, missing)
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
    /// Closed-shell rule: the folder around the .app is app-owned (it receives `Data/` and is what uninstall deletes), so it
    /// must never be a folder that owns the user's other files. Returns a display name when `folder` is such a shared location.
    static func sharedContainerName(_ folder: URL) -> String? {
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        if resolved == home { return "the home folder" }
        if resolved.path == "/Applications" { return "/Applications" }
        let sharedNames: Set<String> = ["Downloads", "Desktop", "Documents", "Applications", "Music", "Movies", "Pictures", "Public", "Library"]
        if resolved.deletingLastPathComponent() == home, sharedNames.contains(resolved.lastPathComponent) { return "~/\(resolved.lastPathComponent)" }
        return nil
    }
}
enum StorageError: LocalizedError {
    case appInSharedLocation(String)
    var errorDescription: String? {
        switch self {
        case .appInSharedLocation(let name): "AI Mix Assistant.app sits directly in \(name). The app keeps everything inside the folder around it, so move the .app into its own dedicated folder (for example AI_Mix_v1) with Finder and launch it again — deleting that folder will then remove the whole program with all its data."
        }
    }
}
extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e } }
