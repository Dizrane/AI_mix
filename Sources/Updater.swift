import Foundation
import AppKit

/// In-place self-update from this repository's GitHub Releases. The released app lives inside one closed-shell folder
/// together with its `Data/`, so an update is the replacement of a single `.app`: download the release ZIP, unpack it,
/// verify the new bundle really is the released version, swap it in next to the untouched `Data/`, and relaunch. Every
/// step reports honestly and any failure before the swap leaves the current installation exactly as it was; a failure
/// during the swap restores the old bundle. Nothing runs automatically: the check only reads the public releases API,
/// and installation happens on an explicit click.
struct AppUpdate: Sendable, Equatable {
    var tag: String
    var assetName: String
    var assetURL: URL
}

enum UpdateInstallResult: Sendable { case installed(app: URL), failed(String) }

struct AppUpdater: Sendable {
    static let repository = "Dizrane/AI_mix"

    /// The running app's released version, nil in a development run (`swift run` has no bundle Info.plist).
    static func currentVersion() -> String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// Numeric dot-separated components; a leading `v` is tolerated. Nil when any component is not a number,
    /// so a malformed tag can never look "newer" than the installed version.
    static func parseVersion(_ text: String) -> [Int]? {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts { guard let number = Int(part) else { return nil }; numbers.append(number) }
        return numbers
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parseVersion(candidate), let b = parseVersion(current) else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Parses the GitHub "latest release" JSON and picks the app ZIP asset. Separated from the network call so the
    /// selection logic is testable without touching the network.
    static func update(fromReleaseJSON data: Data) throws -> AppUpdate {
        struct Release: Decodable { var tag_name: String; var assets: [Asset]; struct Asset: Decodable { var name: String; var browser_download_url: URL } }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("AI-Mix-Assistant") && $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noAppAsset(release.tag_name)
        }
        return AppUpdate(tag: release.tag_name, assetName: asset.name, assetURL: asset.browser_download_url)
    }

    /// The GitHub website's `releases/latest` page redirects to `releases/tag/<tag>`. Unlike the JSON API, that web endpoint
    /// has no anonymous 60-requests/hour-per-IP rate limit — a real user on a shared network hit that limit and every update
    /// check answered 403 — so the redirect is the primary source of the latest tag and the API is only the fallback. The
    /// asset name and URL follow the Release workflow's fixed naming scheme; a wrong construction cannot install anything,
    /// because the download fails on a missing asset and the unpacked bundle is verified against the tag before the swap.
    static func update(fromLatestReleasePage url: URL) -> AppUpdate? {
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "tag" else { return nil }
        let tag = parts[parts.count - 1]
        guard parseVersion(tag) != nil else { return nil }
        let asset = "AI-Mix-Assistant-\(tag)-macos-universal.zip"
        guard let assetURL = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(asset)") else { return nil }
        return AppUpdate(tag: tag, assetName: asset, assetURL: assetURL)
    }

    func latestRelease() async throws -> AppUpdate {
        var pageRequest = URLRequest(url: URL(string: "https://github.com/\(Self.repository)/releases/latest")!)
        pageRequest.httpMethod = "HEAD"
        pageRequest.timeoutInterval = 15
        if let (_, response) = try? await URLSession.shared.data(for: pageRequest),
           let http = response as? HTTPURLResponse, http.statusCode == 200, let page = http.url,
           let update = Self.update(fromLatestReleasePage: page) { return update }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode)
        }
        return try Self.update(fromReleaseJSON: data)
    }

    /// Downloads, unpacks, verifies and swaps in the new bundle. Returns the installed `.app` URL for relaunch;
    /// the caller decides when to quit this old instance.
    func downloadAndInstall(_ update: AppUpdate, status: @escaping @Sendable (String) -> Void) async -> UpdateInstallResult {
        let manager = FileManager.default
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            return .failed("Self-update needs the released .app bundle; this development run has no bundle to replace.")
        }
        let shell = currentApp.deletingLastPathComponent()
        guard manager.isWritableFile(atPath: shell.path) else {
            return .failed("The app's folder \(shell.path) is not writable, so the new version cannot be installed there.")
        }
        let workDir = manager.temporaryDirectory.appendingPathComponent("aimix-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: workDir) }
        let zipURL = workDir.appendingPathComponent(update.assetName)
        do {
            try manager.createDirectory(at: workDir, withIntermediateDirectories: true)
            status("Downloading \(update.assetName)\u{2026}")
            let (downloaded, response) = try await URLSession.shared.download(from: update.assetURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed("Download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) from \(update.assetURL.host ?? "the release server").")
            }
            try manager.moveItem(at: downloaded, to: zipURL)
        } catch { return .failed("Download failed: \(error.localizedDescription)") }
        status("Unpacking \(update.tag)\u{2026}")
        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        if let failure = run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path]) {
            return .failed("Could not unpack the update: \(failure)")
        }
        guard let newBundle = locateBundle(in: extractDir) else { return .failed("The downloaded archive contains no .app bundle.") }
        if let problem = validate(bundle: newBundle, expectedTag: update.tag) { return .failed(problem) }
        status("Installing \(update.tag)\u{2026}")
        let backup = shell.appendingPathComponent(currentApp.lastPathComponent + ".updating-old")
        try? manager.removeItem(at: backup)
        do { try manager.moveItem(at: currentApp, to: backup) } catch {
            return .failed("Could not move the current app aside: \(error.localizedDescription)")
        }
        do { try manager.moveItem(at: newBundle, to: currentApp) } catch {
            try? manager.moveItem(at: backup, to: currentApp)
            return .failed("Could not install the new app — the current version was restored: \(error.localizedDescription)")
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", currentApp.path])
        try? manager.removeItem(at: backup)
        return .installed(app: currentApp)
    }

    /// The new bundle is installed only after it proves it is what the release says: a readable Info.plist whose
    /// version equals the release tag, and a runnable main executable. Anything less is refused with the reason.
    func validate(bundle url: URL, expectedTag: String) -> String? {
        guard let bundle = Bundle(url: url) else { return "The downloaded app bundle could not be read." }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "The downloaded app declares no version, so it cannot be verified against \(expectedTag) — refusing to install."
        }
        let expected = expectedTag.hasPrefix("v") ? String(expectedTag.dropFirst()) : expectedTag
        guard version == expected else {
            return "The downloaded app reports version \(version), but the release is \(expectedTag) — refusing to install."
        }
        guard let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            return "The downloaded app has no runnable executable — refusing to install."
        }
        return nil
    }

    /// Removes a leftover `.updating-old` bundle from a previous update whose cleanup did not finish (the old app
    /// was still running when deletion was attempted). Called once at launch; touches only the app's own shell folder.
    static func removeLeftovers() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        let shell = bundleURL.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: shell.path) else { return }
        for item in items where item.hasSuffix(".updating-old") { try? FileManager.default.removeItem(at: shell.appendingPathComponent(item)) }
    }

    private func locateBundle(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" { return url }
        return nil
    }

    private func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (message?.isEmpty == false) ? message! : "exit code \(process.terminationStatus)"
        }
        return nil
    }
}

enum UpdateError: LocalizedError {
    case badResponse(Int?)
    case noAppAsset(String)
    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "GitHub answered \(code.map(String.init) ?? "with no HTTP status") instead of the latest release." + (code == 403 ? " A 403 usually means GitHub's anonymous API rate limit for this network (60 requests/hour per address); try again later." : "")
        case .noAppAsset(let tag): "Release \(tag) has no AI-Mix-Assistant ZIP asset to download."
        }
    }
}
