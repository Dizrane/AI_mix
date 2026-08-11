import Foundation
import AppKit

enum UninstallResult: Sendable {
    case deleted(path: String)
    case blocked(reason: String)
    case failed(reason: String)
    case partiallyRemoved(reason: String)
}

/// Full self-removal: "ONE APP ROOT → ONE DELETE". Deletes the single, known AI Mix Assistant root directory
/// (the folder holding the .app and its Data) recursively, after strict safety checks. It NEVER searches the
/// filesystem for leftovers, never touches ~/Library, system locations, Logic, or anything outside that one root.
struct AppUninstaller: Sendable {
    /// The exact directory that would be deleted, or nil if it cannot be unambiguously determined.
    func targetRoot() -> URL? { SessionStore.applicationRootURL() }

    func deleteApplicationRoot() -> UninstallResult {
        guard let root = targetRoot() else { return .blocked(reason: "The AI Mix Assistant directory could not be determined (the app is not running from its .app bundle). Nothing was deleted.") }
        if let reason = safetyFailure(root) { return .blocked(reason: reason) }
        let manager = FileManager.default
        do {
            try manager.removeItem(at: root)
        } catch {
            // Honest result: report success only if the directory is actually gone.
            if !manager.fileExists(atPath: root.path) { return .deleted(path: root.path) }
            let bundleGone = !manager.fileExists(atPath: root.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent).path)
            return bundleGone ? .partiallyRemoved(reason: "Some files under \(root.path) could not be removed: \(error.localizedDescription)") : .failed(reason: error.localizedDescription)
        }
        return manager.fileExists(atPath: root.path) ? .partiallyRemoved(reason: "Some files under \(root.path) could not be removed.") : .deleted(path: root.path)
    }

    /// Returns a human-readable reason if deleting `root` would be unsafe, else nil. No filesystem scanning — only checks on this one path.
    private func safetyFailure(_ root: URL) -> String? {
        let manager = FileManager.default
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        if path.isEmpty || path == "/" { return "Refusing to delete the filesystem root." }
        if path == home { return "Refusing to delete your home directory." }
        if resolved.pathComponents.count < 3 { return "The path \(path) is too shallow to be the AI Mix Assistant directory." }
        let forbidden: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/private/var", "/private/tmp", "/tmp", "/bin", "/usr", "/opt", "/Volumes", home]
        if forbidden.contains(path) { return "Refusing to delete a protected location (\(path))." }
        if path.hasPrefix("/private/var/folders") || path.hasPrefix("/private/tmp/AppTranslocation") { return "The app appears to be running from a temporary/translocated location; the real directory cannot be safely determined. Nothing was deleted." }
        // Characteristic structure: the root must actually contain THIS .app bundle and the Data directory.
        var isDir: ObjCBool = false
        let appInside = root.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard manager.fileExists(atPath: appInside.path, isDirectory: &isDir), isDir.boolValue else { return "The AI Mix Assistant application bundle was not found inside \(path); refusing to delete." }
        guard manager.fileExists(atPath: root.appendingPathComponent("Data").path) else { return "The expected Data directory was not found inside \(path); refusing to delete." }
        return nil
    }
}
