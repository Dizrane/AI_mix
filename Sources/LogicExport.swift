import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Outcome of the full one-click export. Never claims files were written — that is verified separately from disk.
enum ExportOutcome: Sendable {
    case exported(item: String, format: String, settings: ExportDialogSettings) // menu launched, destination set, Export pressed
    case blockedByNormalize(value: String)               // dialog read, Normalize would rewrite levels — cancelled, nothing exported
    case triggerFailed(step: String, detail: String)     // could not launch the export menu item
    case navigationFailed(step: String, detail: String)  // dialog opened but destination/confirm could not be driven
}

/// One row of the bounce dialog's format table: the format's own caption and whether its checkbox is checked. A fact
/// read off Logic's dialog, never a guess — the table decides which file kinds the bounce will actually write.
struct FormatSelection: Sendable, Equatable, Codable { var name: String; var enabled: Bool }

/// The level-affecting settings Logic's export dialog showed when the export was launched, read from the dialog's own
/// labelled controls before Export is pressed. Each value is the control's own caption; a control the dialog does not
/// expose stays nil — the setting is then honestly unknown, never assumed. The automation only READS these controls
/// (the contract of never changing Logic's export settings stands); a harmful value cancels the export instead.
/// `formats` is the bounce dialog's format table (the track-export dialog has a single format pop-up instead, so it
/// stays nil there); nil also when the table could not be read at all.
struct ExportDialogSettings: Sendable, Equatable, Codable {
    var format: String?
    var bitDepth: String?
    var normalize: String?
    var formats: [FormatSelection]? = nil
}

/// Outcome of the one-click mix bounce (Logic's File ▸ Bounce). Mirrors `ExportOutcome`: it never claims a file was
/// written — the real bounce file is detected and verified from disk separately, because a realtime bounce keeps
/// writing long after the dialog is confirmed.
enum BounceOutcome: Sendable {
    case bounced(item: String, settings: ExportDialogSettings) // menu launched, destination set, Bounce pressed
    case blockedByNormalize(value: String)               // dialog read, Normalize would rewrite levels — cancelled, nothing bounced
    case blockedByFormat(selected: [FormatSelection])    // dialog read, no uncompressed PCM format is checked — cancelled, nothing bounced
    case triggerFailed(step: String, detail: String)     // could not launch the bounce menu item
    case navigationFailed(step: String, detail: String)  // dialog opened but settings/destination could not be driven
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
/// project/export settings (format, bit depth, normalize are left exactly as the dialog shows them). The dialog's
/// level-affecting settings ARE read as facts, and a Normalize other than Off cancels the export: normalized WAVs
/// would silently falsify every relative-level fact the exported files are supposed to prove.
struct LogicExportAutomator: Sendable {
    private let supportedBundleIDs: Set<String> = ["com.apple.logic10", "com.apple.mobilelogic"]
    /// Shown when a top-level menu title does not match: the automation relies on English menu names by design.
    private let englishUIHint = "If these titles are not English, run Logic Pro with the English UI (System Settings \u{25B8} General \u{25B8} Language & Region \u{25B8} Applications \u{25B8} add Logic Pro \u{25B8} English) — menu automation relies on English names."

    /// Full one-click export to `destination`. Returns .exported only after the Export button was pressed on a dialog confirmed to point at `destination`.
    func exportAllTracks(destination: URL) -> ExportOutcome {
        guard AXIsProcessTrusted() else { return .triggerFailed(step: "accessibility", detail: "Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = runningLogic() else { return .triggerFailed(step: "logic_running", detail: "Logic Pro is not running.") }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        app.activate(); usleep(400_000)
        // Close any stale export/go-to dialogs left over from a previous run.
        closeWindows(while: { self.findExportDialog(appElement) }, applicationPid: pid)

        let item: String
        switch pressAllTracksMenu(appElement) {
        case .failed(let step, let detail): return .triggerFailed(step: step, detail: detail)
        case .pressed(let title): item = title
        }
        guard let dialog = waitForExportDialog(appElement, timeout: 8) else { return .navigationFailed(step: "export_dialog", detail: "Export dialog did not appear after launching \u{2018}\(item)\u{2019}.") }
        // Read the dialog's level-affecting settings first: a Normalize other than Off would rewrite the exported
        // levels, so the export is cancelled (Escape closes the dialog this automation opened) before anything else.
        let settings = dialogSettings(dialog)
        if let normalize = settings.normalize, Self.normalizeBlocksExport(normalize) == true {
            closeWindows(while: { self.findExportDialog(appElement) }, applicationPid: pid)
            return .blockedByNormalize(value: normalize)
        }
        let format = settings.format ?? "unknown"

        // Destination via the standard Go-to-Folder field (AX-set is ignored by the panel, so paste real text).
        // The user's clipboard is snapshotted completely first — every item with all its representations, not just plain
        // text — and restored on every exit path: the automation must not eat what they had copied, whatever it was.
        let savedClipboard = Self.clipboardSnapshot()
        defer { Self.restoreClipboard(savedClipboard) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(destination.path, forType: .string)
        if let failure = pasteDestination(into: dialog, applicationPid: pid, destination: destination) { return .navigationFailed(step: failure.step, detail: failure.detail) }

        let confirmed = waitForExportDialog(appElement, timeout: 3) ?? dialog
        let whereValue = firstDescendant(confirmed) { self.role($0) == "AXPopUpButton" && self.string($0, kAXTitleAttribute) == "Where:" }.flatMap { self.string($0, kAXValueAttribute) }
        guard whereValue == destination.lastPathComponent else { return .navigationFailed(step: "navigate", detail: "Destination not confirmed (Where=\(whereValue ?? "?"), expected \(destination.lastPathComponent)); not exporting to avoid a wrong folder.") }
        guard let exportButton = firstDescendant(confirmed, { self.role($0) == "AXButton" && self.string($0, kAXTitleAttribute) == "Export" }) else { return .navigationFailed(step: "export_button", detail: "Export button not found on the dialog.") }
        guard press(exportButton) else { return .navigationFailed(step: "press_export", detail: "AXPress on the Export button did not succeed.") }
        return .exported(item: item, format: format, settings: settings)
    }

    /// Only the literal "Off" preserves the files' real levels: "On" always rewrites gain and "Overload Protection Only"
    /// rewrites it whenever anything peaks over full scale — either way the exported WAVs stop being evidence of the
    /// project's relative loudness. Nil means the caption could not be read at all: the caller proceeds and the manifest
    /// records the setting as unavailable instead of pretending it was checked.
    static func normalizeBlocksExport(_ caption: String?) -> Bool? {
        guard let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else { return nil }
        return caption.localizedCaseInsensitiveCompare("off") != .orderedSame
    }

    /// Reads the export dialog's own labelled settings controls. Labels come from each control's AXTitle (the same
    /// mechanism the destination check uses on the "Where:" pop-up) — but in Logic's real dialog the caption is a
    /// SEPARATE static text ("Normalize:") and the pop-up itself is anonymous, so a title search alone finds nothing.
    /// The dialog's own geometry then supplies the link (verified on a live dialog snapshot: the "Normalize:" text and
    /// its pop-up share one row — label at y=504, pop-up at y=500): the control a caption labels is the nearest control
    /// to its right on the same row. The format pop-up keeps a value-based fallback ("WAVE") for a dialog variant that
    /// does not caption it at all. A control found nowhere yields nil — never a guess.
    private func dialogSettings(_ dialog: AXUIElement) -> ExportDialogSettings {
        var elements: [AXUIElement] = []
        collectDescendants(dialog, into: &elements)
        func labelled(_ needle: String, roles: Set<String>) -> AXUIElement? {
            elements.first { roles.contains(self.role($0)) && (self.string($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(needle) }
        }
        func geometryLabelled(_ needle: String, roles: Set<String>) -> AXUIElement? {
            // A static text is a caption when its own text names the setting; its control is matched purely by row geometry.
            let labels = elements.filter { element in
                guard self.role(element) == "AXStaticText" else { return false }
                let texts = [self.string(element, kAXValueAttribute), self.string(element, kAXTitleAttribute)].compactMap { $0 }
                return texts.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            let candidates: [(control: AXUIElement, frame: CGRect)] = elements.compactMap { element in
                guard roles.contains(self.role(element)), let controlFrame = self.frame(element) else { return nil }
                return (element, controlFrame)
            }
            for label in labels {
                guard let labelFrame = frame(label) else { continue }
                if let index = Self.rowControlIndex(labelFrame: labelFrame, controlFrames: candidates.map(\.frame)) { return candidates[index].control }
            }
            return nil
        }
        func setting(_ needle: String, roles: Set<String>) -> AXUIElement? { labelled(needle, roles: roles) ?? geometryLabelled(needle, roles: roles) }
        let formatControl = setting("format", roles: ["AXPopUpButton"]) ?? elements.first { self.role($0) == "AXPopUpButton" && (self.string($0, kAXValueAttribute) ?? "").uppercased().contains("WAV") }
        var normalize: String? = nil
        if let control = setting("normalize", roles: ["AXPopUpButton", "AXCheckBox"]) {
            let value = string(control, kAXValueAttribute)
            // A checkbox exposes a switch position, and here the caption of that position is documented by the control itself: 1 is On, 0 is Off.
            normalize = role(control) == "AXCheckBox" ? value.flatMap { $0 == "1" ? "On" : ($0 == "0" ? "Off" : nil) } : value
        }
        return ExportDialogSettings(format: formatControl.flatMap { self.string($0, kAXValueAttribute) }, bitDepth: setting("bit depth", roles: ["AXPopUpButton"]).flatMap { self.string($0, kAXValueAttribute) }, normalize: normalize)
    }

    /// The control a caption labels, by dialog geometry alone: on the same row as the label (their vertical extents
    /// overlap by at least half the smaller height — the label's baseline offset never breaks this, a neighbouring row
    /// never passes it) and to the label's right, nearest first. Pure and testable; nil when no control qualifies.
    static func rowControlIndex(labelFrame: CGRect, controlFrames: [CGRect]) -> Int? {
        func sameRow(_ control: CGRect) -> Bool {
            let overlap = min(labelFrame.maxY, control.maxY) - max(labelFrame.minY, control.minY)
            return overlap >= min(labelFrame.height, control.height) / 2
        }
        return controlFrames.enumerated()
            .filter { sameRow($0.element) && $0.element.minX >= labelFrame.maxX - 8 }
            .min(by: { ($0.element.minX, $0.offset) < ($1.element.minX, $1.offset) })?
            .offset
    }

    /// The bounce dialog's format table, read as facts: every table row that carries a checkbox is a format row —
    /// the checkbox is the selection, the row's text its caption. Only the BOUNCE dialog is read this way (the track
    /// export has a single format pop-up, and a save panel's file browser rows carry no checkboxes, so nothing else
    /// matches). nil when no such rows exist — the table is then honestly unread, never assumed.
    private func formatSelections(_ dialog: AXUIElement) -> [FormatSelection]? {
        var elements: [AXUIElement] = []
        collectDescendants(dialog, into: &elements)
        var selections: [FormatSelection] = []
        for row in elements where role(row) == "AXRow" {
            var rowElements: [AXUIElement] = []
            collectDescendants(row, into: &rowElements)
            guard let checkbox = rowElements.first(where: { self.role($0) == "AXCheckBox" }), let value = string(checkbox, kAXValueAttribute), value == "0" || value == "1" else { continue }
            let texts: [String] = rowElements.flatMap { element -> [String?] in
                [self.string(element, kAXTitleAttribute), self.role(element) == "AXStaticText" ? self.string(element, kAXValueAttribute) : nil, self.string(element, kAXDescriptionAttribute)]
            }.compactMap { $0 }
            guard let caption = texts.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            selections.append(FormatSelection(name: caption.trimmingCharacters(in: .whitespaces), enabled: value == "1"))
        }
        return selections.isEmpty ? nil : selections
    }

    /// Whether the bounce must be cancelled because the checked formats provably contain no uncompressed PCM entry.
    /// The bounced mix is the measurable loudness reference, so it must be a WAV/AIFF-family PCM file: a lossy MP3/AAC
    /// bounce is not level evidence and the app would not even detect it as the mix. An unread table (nil) never
    /// blocks — the setting is then published as unavailable instead of guessed.
    static func formatsBlockBounce(_ formats: [FormatSelection]?) -> Bool {
        guard let formats, !formats.isEmpty else { return false }
        return !formats.contains { $0.enabled && Self.isUncompressedPCM($0.name) }
    }
    /// The caption grammar of Logic's own format rows: the PCM row is titled "PCM" (older dialogs) or "Uncompressed"
    /// and its file types are the WAV/AIFF/CAF family. A caption naming none of these is not PCM — never a guess.
    static func isUncompressedPCM(_ name: String) -> Bool {
        let lowered = name.localizedLowercase
        return ["pcm", "uncompressed", "wave", "wav", "aiff", "aif", "caf"].contains { lowered.contains($0) }
    }

    /// Full one-click bounce of the mix (Logic's Stereo Out) to `destination` via File ▸ Bounce — the sum through the
    /// whole master chain, which no per-track export contains. Same discipline as the track export: every element is
    /// discovered at runtime, settings are only READ (a Normalize other than Off cancels the bounce instead of being
    /// changed), the destination is driven through the standard save-panel keys and verified before the final press,
    /// and the user's clipboard is snapshotted and restored. Logic's bounce dialog ships in two shapes — a settings
    /// window whose confirm opens a separate name/destination panel, or one combined window — and both are handled by
    /// looking for the panel's own "Where:" pop-up rather than assuming a shape.
    func bounceMix(destination: URL) -> BounceOutcome {
        guard AXIsProcessTrusted() else { return .triggerFailed(step: "accessibility", detail: "Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = runningLogic() else { return .triggerFailed(step: "logic_running", detail: "Logic Pro is not running.") }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        app.activate(); usleep(400_000)
        // Close any stale bounce windows left over from a previous run.
        closeWindows(while: { self.firstBounceWindow(appElement) }, applicationPid: pid)

        let item: String
        switch pressBounceMenu(appElement) {
        case .failed(let step, let detail): return .triggerFailed(step: step, detail: detail)
        case .pressed(let title): item = title
        }
        guard let dialog = waitForBounceWindow(appElement, timeout: 8) else { return .navigationFailed(step: "bounce_dialog", detail: "Bounce dialog did not appear after launching \u{2018}\(item)\u{2019}.") }
        // Level-affecting settings first: a Normalize other than Off would rewrite the bounced level, so the bounce
        // is cancelled (Escape closes what this automation opened) before any destination work. The format table is
        // read the same way: a bounce whose checked formats contain no uncompressed PCM would produce a lossy file
        // that is not level evidence (and would not even be detected as the mix), so it is cancelled too.
        var settings = dialogSettings(dialog)
        settings.formats = formatSelections(dialog)
        if let normalize = settings.normalize, Self.normalizeBlocksExport(normalize) == true {
            closeWindows(while: { self.firstBounceWindow(appElement) }, applicationPid: pid)
            return .blockedByNormalize(value: normalize)
        }
        if Self.formatsBlockBounce(settings.formats) {
            closeWindows(while: { self.firstBounceWindow(appElement) }, applicationPid: pid)
            return .blockedByFormat(selected: settings.formats ?? [])
        }
        // The name/destination panel: the dialog itself when it already carries the save-panel controls, otherwise the
        // panel that appears after the settings window is confirmed.
        let panel: AXUIElement
        if hasWherePopup(dialog) { panel = dialog }
        else {
            guard let confirm = bounceConfirmButton(dialog) else { return .navigationFailed(step: "bounce_button", detail: "No Bounce/OK button found on the bounce dialog.") }
            guard press(confirm) else { return .navigationFailed(step: "press_bounce", detail: "AXPress on the bounce dialog's confirm button did not succeed.") }
            guard let saved = waitForBounceWindow(appElement, timeout: 8, where: { self.hasWherePopup($0) }) else { return .navigationFailed(step: "save_panel", detail: "The bounce name/destination panel did not appear.") }
            panel = saved
        }
        // Destination via the standard Go-to-Folder field, exactly like the track export; clipboard fully preserved.
        let savedClipboard = Self.clipboardSnapshot()
        defer { Self.restoreClipboard(savedClipboard) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(destination.path, forType: .string)
        if let failure = pasteDestination(into: panel, applicationPid: pid, destination: destination) { return .navigationFailed(step: failure.step, detail: failure.detail) }
        let confirmed = waitForBounceWindow(appElement, timeout: 3, where: { self.hasWherePopup($0) }) ?? panel
        let whereValue = firstDescendant(confirmed) { self.role($0) == "AXPopUpButton" && self.string($0, kAXTitleAttribute) == "Where:" }.flatMap { self.string($0, kAXValueAttribute) }
        guard whereValue == destination.lastPathComponent else { return .navigationFailed(step: "navigate", detail: "Destination not confirmed (Where=\(whereValue ?? "?"), expected \(destination.lastPathComponent)); not bouncing to avoid a wrong folder.") }
        guard let finalButton = bounceConfirmButton(confirmed) else { return .navigationFailed(step: "final_button", detail: "No Bounce/OK button found on the destination panel.") }
        guard press(finalButton) else { return .navigationFailed(step: "press_final", detail: "AXPress on the final Bounce button did not succeed.") }
        return .bounced(item: item, settings: settings)
    }

    /// Makes Logic's Mixer visible before analysis, because channel strips carry the richest AX facts. Reads the View menu:
    /// "Hide Mixer" means it is already on screen (the opened menu is closed with Escape, nothing pressed); "Show Mixer" is
    /// pressed via AXPress — the same documented menu mechanism the export automation uses, never a blind keystroke that
    /// could land in a focused text field. It changes only which panes are on screen, never project state.
    func ensureMixerVisible() -> MixerEnsureOutcome {
        guard AXIsProcessTrusted() else { return .failed(step: "accessibility", detail: "Accessibility permission is not granted to AI Mix Assistant.") }
        guard let app = runningLogic() else { return .failed(step: "logic_running", detail: "Logic Pro is not running.") }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        app.activate(); usleep(400_000)
        guard let menuBar = copyElement(appElement, kAXMenuBarAttribute) else { return .failed(step: "menu_bar", detail: "AXMenuBar attribute is unavailable.") }
        guard let viewItem = childByTitle(menuBar, "View") else { return .failed(step: "view_menu", detail: "View menu not found. Menus: \(childTitles(menuBar)). \(englishUIHint)") }
        _ = press(viewItem); usleep(400_000) // open View so Logic validates & populates the submenu
        guard let viewMenu = firstMenu(of: viewItem), let mixerItem = childContaining(viewMenu, "mixer") else { postKey(53, [], via: .pid(pid)); return .failed(step: "mixer_item", detail: "No Mixer item found in the View menu.") }
        let title = string(mixerItem, kAXTitleAttribute) ?? "Mixer"
        if title.localizedCaseInsensitiveContains("hide") { postKey(53, [], via: .pid(pid)); usleep(250_000); return .alreadyVisible } // already visible; just close the menu
        guard press(mixerItem) else { postKey(53, [], via: .pid(pid)); return .failed(step: "press", detail: "AXPress on \u{2018}\(title)\u{2019} did not succeed.") }
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
        guard let fileItem = childByTitle(menuBar, "File") else { return .failed("file_menu", "File menu not found. Menus: \(childTitles(menuBar)). \(englishUIHint)") }
        _ = press(fileItem); usleep(400_000) // open File so Logic validates & populates the submenu
        guard let fileMenu = firstMenu(of: fileItem), let exportItem = childByTitle(fileMenu, "Export") else { return .failed("export_item", "‘Export’ not found in File.") }
        _ = press(exportItem); usleep(400_000)
        guard let exportMenu = firstMenu(of: exportItem), let leaf = childContaining(exportMenu, "all tracks as audio files") else { return .failed("all_tracks_item", "‘All Tracks as Audio Files…’ not found.") }
        let leafTitle = string(leaf, kAXTitleAttribute) ?? "All Tracks as Audio Files…"
        if bool(leaf, kAXEnabledAttribute) == false { return .failed("item_disabled", "‘\(leafTitle)’ is disabled — the project may have no exportable audio tracks.") }
        guard press(leaf) else { return .failed("press", "AXPress on ‘\(leafTitle)’ did not succeed.") }
        return .pressed(leafTitle)
    }

    // MARK: bounce menu + window discovery

    /// File ▸ Bounce ▸ Project or Section… in current Logic; an older un-nested "Bounce…" leaf opens the dialog directly.
    private func pressBounceMenu(_ appElement: AXUIElement) -> MenuPress {
        guard let menuBar = copyElement(appElement, kAXMenuBarAttribute) else { return .failed("menu_bar", "AXMenuBar attribute is unavailable.") }
        guard let fileItem = childByTitle(menuBar, "File") else { return .failed("file_menu", "File menu not found. Menus: \(childTitles(menuBar)). \(englishUIHint)") }
        _ = press(fileItem); usleep(400_000) // open File so Logic validates & populates the submenu
        guard let fileMenu = firstMenu(of: fileItem), let bounceItem = childContaining(fileMenu, "bounce") else { return .failed("bounce_item", "No Bounce item found in the File menu. \(englishUIHint)") }
        let bounceTitle = string(bounceItem, kAXTitleAttribute) ?? "Bounce"
        if bool(bounceItem, kAXEnabledAttribute) == false { return .failed("item_disabled", "\u{2018}\(bounceTitle)\u{2019} is disabled — is a project open?") }
        _ = press(bounceItem); usleep(400_000)
        guard let submenu = firstMenu(of: bounceItem) else { return .pressed(bounceTitle) } // an un-nested Bounce… item was already pressed
        guard let leaf = childContaining(submenu, "project") else { return .failed("bounce_leaf", "No \u{2018}Project or Section\u{2019} item found under \u{2018}\(bounceTitle)\u{2019}. Items: \(childTitles(submenu)).") }
        let leafTitle = string(leaf, kAXTitleAttribute) ?? "Project or Section…"
        if bool(leaf, kAXEnabledAttribute) == false { return .failed("item_disabled", "\u{2018}\(leafTitle)\u{2019} is disabled — is a project open?") }
        guard press(leaf) else { return .failed("press", "AXPress on \u{2018}\(leafTitle)\u{2019} did not succeed.") }
        return .pressed("\(bounceTitle) \u{25B8} \(leafTitle)")
    }
    /// A bounce window is recognised by its own evidence: a title containing "bounce", or a "Bounce"-titled button.
    private func isBounceWindow(_ window: AXUIElement) -> Bool {
        if (string(window, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains("bounce") { return true }
        return firstDescendant(window) { self.role($0) == "AXButton" && self.string($0, kAXTitleAttribute) == "Bounce" } != nil
    }
    private func firstBounceWindow(_ app: AXUIElement, where predicate: ((AXUIElement) -> Bool)? = nil) -> AXUIElement? { windows(app).first { isBounceWindow($0) && (predicate?($0) ?? true) } }
    private func waitForBounceWindow(_ app: AXUIElement, timeout: TimeInterval, where predicate: ((AXUIElement) -> Bool)? = nil) -> AXUIElement? { let deadline = Date().addingTimeInterval(timeout); while Date() < deadline { if let window = firstBounceWindow(app, where: predicate) { return window }; usleep(250_000) }; return nil }
    /// The confirm control on either bounce window shape: current Logic titles it "Bounce", older dialogs "OK".
    private func bounceConfirmButton(_ window: AXUIElement) -> AXUIElement? { firstDescendant(window) { self.role($0) == "AXButton" && ["Bounce", "OK"].contains(self.string($0, kAXTitleAttribute) ?? "") } }
    /// The standard save-panel destination pop-up — the evidence that a window can take the go-to-folder keys at all.
    private func hasWherePopup(_ window: AXUIElement) -> Bool { firstDescendant(window) { self.role($0) == "AXPopUpButton" && self.string($0, kAXTitleAttribute) == "Where:" } != nil }

    // MARK: clipboard preservation
    /// The complete state of a pasteboard: every item with the data of every representation it carries (files, images,
    /// rich text — not just a plain string), so "your clipboard is restored" is true whatever the user had copied.
    /// A type whose data cannot be materialized (an unfulfilled promise) is skipped; everything readable survives.
    static func clipboardSnapshot(of pasteboard: NSPasteboard = .general) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
        }
    }
    /// Writes a snapshot back. An empty snapshot restores an empty clipboard — the borrowed destination path is
    /// removed either way, never left behind just because the user had nothing copied.
    static func restoreClipboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items = snapshot.compactMap { entry -> NSPasteboardItem? in
            guard !entry.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: helpers
    private func runningLogic() -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { !$0.isTerminated && ($0.bundleIdentifier.map(supportedBundleIDs.contains) == true || $0.localizedName == "Logic Pro") } }
    private func findExportDialog(_ app: AXUIElement) -> AXUIElement? { windows(app).first { firstDescendant($0, { self.role($0) == "AXButton" && self.string($0, kAXTitleAttribute) == "Export" }) != nil } }
    private func waitForExportDialog(_ app: AXUIElement, timeout: TimeInterval) -> AXUIElement? { let deadline = Date().addingTimeInterval(timeout); while Date() < deadline { if let d = findExportDialog(app) { return d }; usleep(250_000) }; return nil }
    // MARK: key routing to the process that really owns the panel

    /// Where a keystroke is sent: a specific process, or the system event stream (used only while Logic is frontmost).
    enum KeyRoute: Equatable, Sendable { case pid(pid_t), global }
    /// The routes to try for a file panel's keys, in order of evidence. macOS runs open/save panels in their own
    /// system process (the AppKit panel service), and a key posted to Logic's pid never reaches that process — the
    /// go-to-folder sheet simply does not open. So the panel element's OWN pid comes first; Logic's pid stays as the
    /// fallback for an in-process panel; the system-wide stream is last, and the caller uses it only while Logic (or
    /// the panel process) is frontmost, so the paste can never land in another application the user switched to.
    static func keyRouteCandidates(panelOwner: pid_t?, applicationPid: pid_t) -> [KeyRoute] {
        var routes: [KeyRoute] = []
        if let panelOwner, panelOwner != applicationPid { routes.append(.pid(panelOwner)) }
        routes.append(.pid(applicationPid))
        routes.append(.global)
        return routes
    }
    /// The pid of the process an AX element really belongs to — for a remote file panel this is the panel service, not Logic.
    private static func ownerPid(of element: AXUIElement) -> pid_t? { var pid: pid_t = 0; return AXUIElementGetPid(element, &pid) == .success ? pid : nil }
    /// Keystrokes are addressed, never sprayed: `.pid` posts to that process directly (postToPid) so the keys land
    /// there no matter where focus is; `.global` posts to the HID stream and is only used behind a frontmost check.
    private func postKey(_ code: CGKeyCode, _ flags: CGEventFlags, via route: KeyRoute) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); up?.flags = flags
        switch route {
        case .pid(let pid): down?.postToPid(pid); usleep(40_000); up?.postToPid(pid)
        case .global: down?.post(tap: .cghidEventTap); usleep(40_000); up?.post(tap: .cghidEventTap)
        }
    }
    /// Closes windows this automation may have left open (stale export/bounce dialogs), Escape-ing each via the pid
    /// that really owns it — a remote file panel ignores an Escape addressed to Logic.
    private func closeWindows(while find: () -> AXUIElement?, applicationPid: pid_t) {
        for _ in 0..<3 {
            guard let window = find() else { return }
            postKey(53, [], via: .pid(Self.ownerPid(of: window) ?? applicationPid)); usleep(350_000)
        }
    }
    /// Drives the standard go-to-folder flow on `panel`: ⌘⇧G, ⌘V of the destination (already on the clipboard),
    /// Return — each key routed to the process that demonstrably owns the panel. The route is proven by its effect:
    /// the sheet either opens or the next route is tried, and the route that opened it carries the remaining keys.
    /// Returns nil on success, otherwise the failing step and an honest detail.
    private func pasteDestination(into panel: AXUIElement, applicationPid: pid_t, destination: URL) -> (step: String, detail: String)? {
        let owner = Self.ownerPid(of: panel)
        var opened: (sheet: AXUIElement, route: KeyRoute)? = nil
        for route in Self.keyRouteCandidates(panelOwner: owner, applicationPid: applicationPid) {
            if route == .global {
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard frontmost == applicationPid || (owner != nil && frontmost == owner) else { continue }
            }
            postKey(5, [.maskCommand, .maskShift], via: route) // ⌘⇧G
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                usleep(250_000)
                if let sheet = firstDescendant(panel, { self.role($0) == "AXSheet" }) { opened = (sheet, route); break }
            }
            if opened != nil { break }
        }
        guard let (sheet, route) = opened else {
            return ("goto_sheet", "The go-to-folder sheet did not open after \u{2318}\u{21E7}G. Keys were addressed to the panel's own process (\(owner.map(String.init) ?? "unknown")) and to Logic (\(applicationPid))" + (NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPid ? " and to the system event stream" : "; the system event stream was skipped because Logic is not frontmost") + ".")
        }
        guard let field = firstDescendant(sheet, { ["AXComboBox", "AXTextField"].contains(self.role($0)) }) else { return ("goto_sheet", "The go-to-folder sheet opened but exposes no text field.") }
        postKey(9, [.maskCommand], via: route); usleep(450_000) // ⌘V
        let pasted = string(field, kAXValueAttribute) ?? ""
        guard pasted.contains(destination.path) else { return ("paste_path", "Destination did not paste into the go-to field (got: \(pasted)).") }
        postKey(36, [], via: route); usleep(1_000_000) // Return accepts the path
        return nil
    }
    private func firstDescendant(_ element: AXUIElement, _ match: (AXUIElement) -> Bool, _ depth: Int = 0) -> AXUIElement? { if match(element) { return element }; guard depth < 20 else { return nil }; for child in children(element) { if let found = firstDescendant(child, match, depth + 1) { return found } }; return nil }
    private func collectDescendants(_ element: AXUIElement, into result: inout [AXUIElement], _ depth: Int = 0) { result.append(element); guard depth < 20 else { return }; for child in children(element) { collectDescendants(child, into: &result, depth + 1) } }
    /// The element's on-screen frame from its documented AXPosition/AXSize attributes; nil when either is unreadable.
    private func frame(_ element: AXUIElement) -> CGRect? {
        func axValue<T>(_ attribute: String, _ type: AXValueType, _ zero: T) -> T? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }; var result = zero; guard AXValueGetValue(value as! AXValue, type, &result) else { return nil }; return result }
        guard let origin = axValue(kAXPositionAttribute, .cgPoint, CGPoint.zero), let size = axValue(kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }
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
