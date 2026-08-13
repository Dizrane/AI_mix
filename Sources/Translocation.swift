import Foundation
import AppKit
import Darwin

/// Detects and repairs macOS App Translocation: Gatekeeper runs a downloaded (quarantined) app from a random
/// read-only volume under /private/var/folders/…/AppTranslocation, so `Data/` cannot be created next to the
/// real `.app` and the closed shell breaks. The repair happens only at explicit user request and touches only
/// the app's own shell folder: it removes the `com.apple.quarantine` attribute from that one folder (the same
/// folder uninstall would delete), verifies the attribute is actually gone from the bundle, and relaunches the
/// app from its real location. The folder itself stays exactly where the user put it — Desktop included.
enum TranslocationRepair {
    static var isActive: Bool { Bundle.main.bundleURL.path.contains("/AppTranslocation/") }

    enum Outcome { case repaired(originalApp: URL), failed(String) }

    /// The real on-disk `.app` the user launched, resolved through the Security framework
    /// (`SecTranslocateCreateOriginalPathForURL`). Nil when not translocated or when resolution fails.
    static func originalBundleURL() -> URL? {
        guard isActive else { return nil }
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(security) }
        guard let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias CreateOriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let createOriginalPath = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        var error: Unmanaged<CFError>?
        guard let original = createOriginalPath(Bundle.main.bundleURL as CFURL, &error) else { error?.release(); return nil }
        return (original.takeRetainedValue() as URL).standardizedFileURL
    }

    /// Removes the quarantine attribute from the original shell folder and confirms the `.app` is clean.
    /// Honest result: `.repaired` is returned only after re-reading the attribute from disk.
    static func dequarantineOriginal() -> Outcome {
        guard isActive else { return .failed("The app is not running from a translocated copy; nothing to fix.") }
        guard let originalApp = originalBundleURL(), originalApp.pathExtension == "app" else {
            return .failed("The original location of AI Mix Assistant.app could not be determined. Move the .app to another folder with Finder once and launch it again.")
        }
        let shellFolder = originalApp.deletingLastPathComponent()
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", shellFolder.path]
        xattr.standardOutput = FileHandle.nullDevice; xattr.standardError = FileHandle.nullDevice
        do { try xattr.run(); xattr.waitUntilExit() } catch {
            return .failed("Could not run /usr/bin/xattr to remove the quarantine attribute: \(error.localizedDescription)")
        }
        // xattr's exit status is unreliable here (files without the attribute report errors), so verify the bundle directly.
        if getxattr(originalApp.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            return .failed("The quarantine attribute could not be removed from \(originalApp.path). If macOS asked for permission to access that folder, allow it and try again; otherwise move the folder somewhere you own and retry.")
        }
        return .repaired(originalApp: originalApp)
    }
}
