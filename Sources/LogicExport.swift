import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Outcome of the full one-click export. Never claims files were written — that is verified separately from disk.
enum ExportOutcome: Sendable {
    case exported(item: String, format: String)          // menu launched, destination set, Export pressed
    case triggerFailed(step: String, detail: String)     // could not launch the export menu item
    case navigationFailed(step: String, detail: String)  // dialog opened but destination/confirm could not be driven
}

/// Result of just launching Logic's native export (kept for compatibility / diagnostics).
enum ExportTriggerResult: Sendable { case opened(item: String); case pressedNoDialog(item: String); case failed(step: String, detail: String) }

/// Outcome of making Logic's Mixer visible before a scan. Purely UI navigation — it never touches project state.
enum MixerEnsureOutcome: Sendable { case alreadyVisible, opened(item: String), failed(step: String, detail: String) }

/// Write / automation layer that drives Logic's built-in "All Tracks as Audio Files…" export end to end.
/// Every element is discovered at runtime from the live AX tree (verified against the real dialog: an
/// `AXWindow`/`AXDialog` titled "Open" whose format popup already reads "WAVE", mode "One File per Track",
/// filename pattern "Track Name", and buttons "Cancel"/"Export"). It ONLY: presses menu items, posts the
/// standard file-panel keys (⌘⇧G to go-to-folder, ⌘V to paste the destination, Return to accept) and presses
/// the "Export" button. It never changes volume/pan/mute/solo/plug-ins/sends/routing/automation/regions or
/// project/export settings (format, bit depth, normalize are left at Logic's defaults).
struct LogicExportAutomator: Sendable {
    private let supportedBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]

    /// Full one-click export to `destination`. Returns .exported only after the Export button was pressed on a dialog confirmed to point at `destination`.
    func exportAllTracks(destination: URL) -> ExportOutcome {
        guard AXIsProcessTrusted() else { return .triggerFailed(step: "accessibility", detail: "Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = runningLogic() else { return .triggerFailed(step: "logic_running", detail: "Logic Pro is not running.") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        app.activate(); usleep(400_000)
        // Close any stale export/go-to dialogs left over from a previous run.
        for _ in 0..<3 where findExportDialog(appElement) != nil { postKey(53, []); usleep(350_000) }

        let item: String
        switch pressAllTracksMenu(appElement) {
        case .failed(let step, let detail): return .triggerFailed(step: step, detail: detail)
        case .pressed(let title): item = title
        }
        guard let dialog = waitForExportDialog(appElement, timeout: 8) else { return .navigationFailed(step: "export_dialog", detail: "Export dialog did not appear after launching \u{2018}\(item)\u{2019}.") }
        let format = firstDescendant(dialog) { self.role($0) == "AXPopUpButton" && (self.string($0, kAXValueAttribute) ?? "").uppercased().contains("WAV") }.flatMap { self.string($0, kAXValueAttribute) } ?? "unknown"

        // Destination via the standard Go-to-Folder field (AX-set is ignored by the panel, so paste real text).
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(destination.path, forType: .string)
        postKey(5, [.maskCommand, .maskShift]); usleep(700_000) // ⌘⇧G
        guard let sheet = firstDescendant(dialog, { self.role($0) == "AXSheet" }), let field = firstDescendant(sheet, { ["AXComboBox", "AXTextField"].contains(self.role($0)) }) else { return .navigationFailed(step: "goto_sheet", detail: "Go-to-folder field not found after ⌘⇧G.") }
        postKey(9, [.maskCommand]); usleep(450_000) // ⌘V
        let pasted = string(field, kAXValueAttribute) ?? ""
        guard pasted.contains(destination.path) else { return .navigationFailed(step: "paste_path", detail: "Destination did not paste into the go-to field (got: \(pasted)).") }
        postKey(36, []); usleep(1_000_000) // Return accepts the path

        let confirmed = waitForExportDialog(appElement, timeout: 3) ?? dialog
        let whereValue = firstDescendant(confirmed) { self.role($0) == "AXPopUpButton" && self.string($0, kAXTitleAttribute) == "Where:" }.flatMap { self.string($0, kAXValueAttribute) }
        guard whereValue == destination.lastPathComponent else { return .navigationFailed(step: "navigate", detail: "Destination not confirmed (Where=\(whereValue ?? "?"), expected \(destination.lastPathComponent)); not exporting to avoid a wrong folder.") }
        guard let exportButton = firstDescendant(confirmed, { self.role($0) == "AXButton" && self.string($0, kAXTitleAttribute) == "Export" }) else { return .navigationFailed(step: "export_button", detail: "Export button not found on the dialog.") }
        guard press(exportButton) else { return .navigationFailed(step: "press_export", detail: "AXPress on the Export button did not succeed.") }
        return .exported(item: item, format: format)
    }

    /// Makes Logic's Mixer visible before analysis, because channel strips carry the richest AX facts. Reads the View menu:
    /// "Hide Mixer" means it is already on screen (the opened menu is closed with Escape, nothing pressed); "Show Mixer" is
    /// pressed via AXPress — the same documented menu mechanism the export automation uses, never a blind keystroke that
    /// could land in a focused text field. It changes only which panes are on screen, never project state.
    func ensureMixerVisible() -> MixerEnsureOutcome {
        guard AXIsProcessTrusted() else { return .failed(step: "accessibility", detail: "Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = runningLogic() else { return .failed(step: "logic_running", detail: "Logic Pro is not running.") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        app.activate(); usleep(400_000)
        guard let menuBar = copyElement(appElement, kAXMenuBarAttribute) else { return .failed(step: "menu_bar", detail: "AXMenuBar attribute is unavailable.") }
        guard let viewItem = childByTitle(menuBar, "View") else { return .failed(step: "view_menu", detail: "View menu not found. Menus: \(childTitles(menuBar))") }
        _ = press(viewItem); usleep(400_000) // open View so Logic validates & populates the submenu
        guard let viewMenu = firstMenu(of: viewItem), let mixerItem = childContaining(viewMenu, "mixer") else { postKey(53, []); return .failed(step: "mixer_item", detail: "No Mixer item found in the View menu.") }
        let title = string(mixerItem, kAXTitleAttribute) ?? "Mixer"
        if title.localizedCaseInsensitiveContains("hide") { postKey(53, []); usleep(250_000); return .alreadyVisible } // already visible; just close the menu
        guard press(mixerItem) else { postKey(53, []); return .failed(step: "press", detail: "AXPress on \u{2018}\(title)\u{2019} did not succeed.") }
        usleep(800_000) // give Logic a moment to lay the Mixer out before the read-only scan
        return .opened(item: title)
    }

    /// Just launches the menu item (no dialog automation) — kept for diagnostics.
    func triggerAllTracksExport() -> ExportTriggerResult {
        guard AXIsProcessTrusted() else { return .failed(step: "accessibility", detail: "Accessibility permission is not granted.") }
        guard let app = runningLogic() else { return .failed(step: "logic_running", detail: "Logic Pro is not running.") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier); app.activate()
        switch pressAllTracksMenu(appElement) {
        case .failed(let step, let detail): return .failed(step: step, detail: detail)
        case .pressed(let title): return waitForExportDialog(appElement, timeout: 4) != nil ? .opened(item: title) : .pressedNoDialog(item: title)
        }
    }

    // MARK: menu discovery + press (unchanged behaviour, matches the real File ▸ Export hierarchy)
    private enum MenuPress { case pressed(String); case failed(String, String) }
    private func pressAllTracksMenu(_ appElement: AXUIElement) -> MenuPress {
        guard let menuBar = copyElement(appElement, kAXMenuBarAttribute) else { return .failed("menu_bar", "AXMenuBar attribute is unavailable.") }
        guard let fileItem = childByTitle(menuBar, "File") else { return .failed("file_menu", "File menu not found. Menus: \(childTitles(menuBar))") }
        _ = press(fileItem); usleep(400_000) // open File so Logic validates & populates the submenu
        guard let fileMenu = firstMenu(of: fileItem), let exportItem = childByTitle(fileMenu, "Export") else { return .failed("export_item", "‘Export’ not found in File.") }
        _ = press(exportItem); usleep(400_000)
        guard let exportMenu = firstMenu(of: exportItem), let leaf = childContaining(exportMenu, "all tracks as audio files") else { return .failed("all_tracks_item", "‘All Tracks as Audio Files…’ not found.") }
        let leafTitle = string(leaf, kAXTitleAttribute) ?? "All Tracks as Audio Files…"
        if bool(leaf, kAXEnabledAttribute) == false { return .failed("item_disabled", "‘\(leafTitle)’ is disabled — the project may have no exportable audio tracks.") }
        guard press(leaf) else { return .failed("press", "AXPress on ‘\(leafTitle)’ did not succeed.") }
        return .pressed(leafTitle)
    }

    // MARK: helpers
    private func runningLogic() -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { !$0.isTerminated && ($0.bundleIdentifier.map(supportedBundleIDs.contains) == true || $0.localizedName == "Logic Pro") } }
    private func findExportDialog(_ app: AXUIElement) -> AXUIElement? { windows(app).first { firstDescendant($0, { self.role($0) == "AXButton" && self.string($0, kAXTitleAttribute) == "Export" }) != nil } }
    private func waitForExportDialog(_ app: AXUIElement, timeout: TimeInterval) -> AXUIElement? { let deadline = Date().addingTimeInterval(timeout); while Date() < deadline { if let d = findExportDialog(app) { return d }; usleep(250_000) }; return nil }
    private func postKey(_ code: CGKeyCode, _ flags: CGEventFlags) { let src = CGEventSource(stateID: .hidSystemState); let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); down?.flags = flags; down?.post(tap: .cghidEventTap); usleep(40_000); let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); up?.flags = flags; up?.post(tap: .cghidEventTap) }
    private func firstDescendant(_ element: AXUIElement, _ match: (AXUIElement) -> Bool, _ depth: Int = 0) -> AXUIElement? { if match(element) { return element }; guard depth < 20 else { return nil }; for child in children(element) { if let found = firstDescendant(child, match, depth + 1) { return found } }; return nil }
    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement) }
    private func children(_ element: AXUIElement) -> [AXUIElement] { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }; return value as? [AXUIElement] ?? [] }
    private func windows(_ app: AXUIElement) -> [AXUIElement] { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }; return value as? [AXUIElement] ?? [] }
    private func string(_ element: AXUIElement, _ attribute: String) -> String? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }; return value as? String ?? (value as? NSNumber)?.stringValue }
    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }; return value as? Bool }
    private func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "?" }
    private func childByTitle(_ element: AXUIElement, _ title: String) -> AXUIElement? { children(element).first { string($0, kAXTitleAttribute) == title } }
    private func childContaining(_ element: AXUIElement, _ lowercasedNeedle: String) -> AXUIElement? { children(element).first { (string($0, kAXTitleAttribute) ?? "").lowercased().contains(lowercasedNeedle) } }
    private func childTitles(_ element: AXUIElement) -> [String] { children(element).compactMap { string($0, kAXTitleAttribute) }.filter { !$0.isEmpty } }
    private func firstMenu(of item: AXUIElement) -> AXUIElement? { children(item).first { string($0, kAXRoleAttribute) == "AXMenu" } }
    @discardableResult private func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }
}
