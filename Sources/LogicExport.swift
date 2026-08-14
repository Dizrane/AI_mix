import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

/// Outcome of the full one-click export. Never claims files were written — that is verified separately from disk.
enum ExportOutcome: Sendable {
    case exported(item: String, format: String, settings: ExportDialogSettings) // menu launched, destination set, Export pressed
    case blockedByNormalize(value: String, detail: String) // Normalize would rewrite levels and could not be switched to Off — cancelled, nothing exported
    case triggerFailed(step: String, detail: String)     // could not launch the export menu item
    case navigationFailed(step: String, detail: String)  // dialog opened but destination/confirm could not be driven
}

/// One row of the bounce dialog's format table: the format's own caption and whether its checkbox is checked. A fact
/// read off Logic's dialog, never a guess — the table decides which file kinds the bounce will actually write.
struct FormatSelection: Sendable, Equatable, Codable { var name: String; var enabled: Bool }

/// The level-affecting settings Logic's export dialog showed when the export was launched, read from the dialog's own
/// labelled controls before Export is pressed. Each value is the control's own caption; a control the dialog does not
/// expose stays nil — the setting is then honestly unknown, never assumed. Two controls are the only ones the automation
/// is allowed to change, each towards the one state the bounced evidence needs: a level-rewriting Normalize is switched
/// to Off before the export (`normalizeSwitchedFrom` records the value the dialog showed before; nil when Normalize was
/// already Off, unreadable, or never had to be touched), and the bounce dialog's format table is set to uncompressed PCM
/// alone — the PCM row checked (`pcmFormatCheckedByApp` records that row's own caption; nil when PCM was already
/// checked), the checked compressed rows unchecked (`formatsUncheckedByApp` records their captions; nil when none had to
/// be unchecked). Every switch is verified by re-reading the dialog. Format and bit depth are never changed. `formats`
/// is the bounce dialog's format table (the track-export dialog has a single format pop-up instead, so it stays nil
/// there); nil also when the table could not be read at all.
struct ExportDialogSettings: Sendable, Equatable, Codable {
    var format: String?
    var bitDepth: String?
    var normalize: String?
    var normalizeSwitchedFrom: String? = nil
    var formats: [FormatSelection]? = nil
    var pcmFormatCheckedByApp: String? = nil
    var formatsUncheckedByApp: [String]? = nil
    /// The state of Logic's transport Cycle control when the bounce was launched, after the automation ensured it is
    /// off ("Off" when proven; nil when no Cycle control could be read — never a guess). Cycle constrains File ▸ Bounce
    /// to the cycle section, so a proven "Off" is what makes the bounce range the whole project. Only the bounce reads
    /// it; the track export ignores Cycle entirely and this stays nil there.
    var cycle: String? = nil
    /// "On" when Cycle was on and the app switched it off (verified by re-reading) before opening the bounce dialog —
    /// the third deliberate write; nil when Cycle was already off, unreadable, or never had to be touched.
    var cycleSwitchedFrom: String? = nil
}

/// Outcome of the one-click mix bounce (Logic's File ▸ Bounce). Mirrors `ExportOutcome`: it never claims a file was
/// written — the real bounce file is detected and verified from disk separately, because a realtime bounce keeps
/// writing long after the dialog is confirmed.
enum BounceOutcome: Sendable {
    case bounced(item: String, settings: ExportDialogSettings) // menu launched, destination set, Bounce pressed
    case blockedByNormalize(value: String, detail: String) // Normalize would rewrite levels and could not be switched to Off — cancelled, nothing bounced
    case blockedByFormat(selected: [FormatSelection], detail: String) // no uncompressed PCM format is checked and the app could not check it — cancelled, nothing bounced
    case blockedByCycle(detail: String) // Cycle mode is provably on (the bounce would cover only the cycle section) and could not be switched off — cancelled, nothing bounced
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
/// the dialog's format and bit depth (left exactly as the dialog shows them). The dialog's level-affecting
/// settings ARE read as facts, and Normalize is the ONE deliberate exception to read-only here: a Normalize
/// other than Off would silently falsify every relative-level fact the exported files are supposed to prove,
/// so the automation switches that control to Off itself (the same documented AXPress mechanism as every
/// button), verifies the switch by re-reading the control, and records the original value as a fact. Only when
/// the switch demonstrably fails is the export cancelled — never silently exported with rewritten levels.
/// The bounce (`bounceMix`) has two more such exceptions, each with the same verification and the same honest
/// cancellation on failure: its format table is set to uncompressed PCM alone, and an enabled transport Cycle is
/// switched off before the bounce dialog opens — Logic bounces only the cycle section while Cycle is on, which
/// would silently truncate the one file the whole analysis treats as the full-project reference.
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
        // levels, so the automation switches it to Off itself before anything else — and cancels the export only
        // when that switch demonstrably fails (Escape then closes the dialog this automation opened).
        var settings = dialogSettings(dialog)
        if let normalize = settings.normalize, Self.normalizeBlocksExport(normalize) == true {
            switch switchNormalizeOff(dialog, applicationPid: pid) {
            case .switched(let from):
                settings = dialogSettings(dialog); settings.normalizeSwitchedFrom = from
            case .failed(let detail):
                closeWindows(while: { self.findExportDialog(appElement) }, applicationPid: pid)
                return .blockedByNormalize(value: normalize, detail: detail)
            }
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
        let formatControl = settingControl(in: elements, needle: "format", roles: ["AXPopUpButton"]) ?? elements.first { self.role($0) == "AXPopUpButton" && (self.string($0, kAXValueAttribute) ?? "").uppercased().contains("WAV") }
        let normalize = settingControl(in: elements, needle: "normalize", roles: ["AXPopUpButton", "AXCheckBox"]).flatMap(normalizeCaption)
        return ExportDialogSettings(format: formatControl.flatMap { self.string($0, kAXValueAttribute) }, bitDepth: settingControl(in: elements, needle: "bit depth", roles: ["AXPopUpButton"]).flatMap { self.string($0, kAXValueAttribute) }, normalize: normalize)
    }
    /// The control a caption names, found by the control's own title first and by row geometry second (see `rowControlIndex`).
    private func settingControl(in elements: [AXUIElement], needle: String, roles: Set<String>) -> AXUIElement? {
        if let titled = elements.first(where: { roles.contains(self.role($0)) && (self.string($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(needle) }) { return titled }
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
    /// The Normalize control's caption as the dialog itself documents it. A checkbox exposes a switch position whose
    /// captions are documented by the control: 1 is On, 0 is Off; a pop-up carries its selected item's own caption.
    private func normalizeCaption(_ control: AXUIElement) -> String? {
        let value = string(control, kAXValueAttribute)
        return role(control) == "AXCheckBox" ? value.flatMap { $0 == "1" ? "On" : ($0 == "0" ? "Off" : nil) } : value
    }

    /// Result of the one deliberate dialog write this automation performs: Normalize switched to Off, or an honest failure.
    private enum NormalizeSwitch { case switched(from: String), failed(detail: String) }
    /// Switches the dialog's Normalize control to Off — the same documented AXPress mechanism as every button press,
    /// and the only setting the automation ever changes: any other value rewrites the exported levels and falsifies
    /// the relative-loudness evidence, and asking the user to flip it by hand was the one manual step left. A pop-up
    /// is opened and its literal "Off" item pressed (strict title match, so nothing else can be selected); a checkbox
    /// is toggled off. The switch is only believed when re-reading the control proves the new value no longer blocks;
    /// anything short of that proof is a failure and the caller cancels the export instead of trusting a blind press.
    private func switchNormalizeOff(_ dialog: AXUIElement, applicationPid: pid_t) -> NormalizeSwitch {
        var elements: [AXUIElement] = []
        collectDescendants(dialog, into: &elements)
        guard let control = settingControl(in: elements, needle: "normalize", roles: ["AXPopUpButton", "AXCheckBox"]) else { return .failed(detail: "The Normalize control could not be found on the dialog again.") }
        guard let before = normalizeCaption(control) else { return .failed(detail: "The Normalize control's value could not be read.") }
        if Self.normalizeBlocksExport(before) != true { return .switched(from: before) } // already harmless — nothing to change
        if role(control) == "AXCheckBox" {
            guard press(control) else { return .failed(detail: "AXPress on the Normalize checkbox did not succeed.") }
        } else {
            guard press(control) else { return .failed(detail: "AXPress on the Normalize pop-up did not succeed.") }
            var menuItems: [AXUIElement] = []
            let menuDeadline = Date().addingTimeInterval(2)
            while Date() < menuDeadline {
                usleep(150_000)
                if let menu = firstDescendant(control, { self.role($0) == "AXMenu" }) { menuItems = children(menu); break }
            }
            guard !menuItems.isEmpty else { return .failed(detail: "The Normalize pop-up did not open its menu.") }
            let titles = menuItems.map { self.string($0, kAXTitleAttribute) ?? "" }
            guard let index = Self.offMenuItemIndex(titles) else {
                postKey(53, [], via: .pid(Self.ownerPid(of: control) ?? applicationPid)) // close the menu this attempt opened
                return .failed(detail: "The Normalize menu has no \u{2018}Off\u{2019} item (items: \(titles.filter { !$0.isEmpty }.joined(separator: ", "))).")
            }
            guard press(menuItems[index]) else { return .failed(detail: "AXPress on the Normalize menu's \u{2018}Off\u{2019} item did not succeed.") }
        }
        // Proof over trust: the switch counts only when the control itself re-reads as a non-blocking value.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            usleep(150_000)
            if let after = normalizeCaption(control), Self.normalizeBlocksExport(after) == false { return .switched(from: before) }
        }
        return .failed(detail: "Normalize still reads \u{2018}\(normalizeCaption(control) ?? "unreadable")\u{2019} after selecting Off.")
    }
    /// The index of the pop-up menu item that selects Off: the item whose own trimmed title IS "Off", case-insensitively.
    /// Strict equality on purpose — a title merely containing the letters ("Overload Protection Only" contains none, but
    /// a hypothetical "Offset" does) must never be pressed. Pure and testable; nil when no such item exists.
    static func offMenuItemIndex(_ titles: [String]) -> Int? {
        titles.firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Off") == .orderedSame }
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

    /// The bounce dialog's format table with each row's own checkbox element: every table row that carries a checkbox
    /// is a format row — the checkbox is the selection, the row's text its caption. Only the BOUNCE dialog is read
    /// this way (the track export has a single format pop-up, and a save panel's file browser rows carry no
    /// checkboxes, so nothing else matches). Empty when no such rows exist.
    private func formatRows(_ dialog: AXUIElement) -> [(selection: FormatSelection, checkbox: AXUIElement)] {
        var elements: [AXUIElement] = []
        collectDescendants(dialog, into: &elements)
        var rows: [(selection: FormatSelection, checkbox: AXUIElement)] = []
        for row in elements where role(row) == "AXRow" {
            var rowElements: [AXUIElement] = []
            collectDescendants(row, into: &rowElements)
            guard let checkbox = rowElements.first(where: { self.role($0) == "AXCheckBox" }), let value = string(checkbox, kAXValueAttribute), value == "0" || value == "1" else { continue }
            let texts: [String] = rowElements.flatMap { element -> [String?] in
                [self.string(element, kAXTitleAttribute), self.role(element) == "AXStaticText" ? self.string(element, kAXValueAttribute) : nil, self.string(element, kAXDescriptionAttribute)]
            }.compactMap { $0 }
            guard let caption = texts.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            rows.append((FormatSelection(name: caption.trimmingCharacters(in: .whitespaces), enabled: value == "1"), checkbox))
        }
        return rows
    }
    /// The format table read as facts alone; nil when no rows exist — the table is then honestly unread, never assumed.
    private func formatSelections(_ dialog: AXUIElement) -> [FormatSelection]? {
        let selections = formatRows(dialog).map { $0.selection }
        return selections.isEmpty ? nil : selections
    }

    /// Whether the checked formats provably contain no uncompressed PCM entry. The bounced mix is the measurable
    /// loudness reference, so it must be a WAV/AIFF-family PCM file: a lossy MP3/AAC bounce is not level evidence and
    /// the app would not even detect it as the mix. When this is true the automation checks the PCM row itself (see
    /// `switchPCMFormatOn`) and cancels only when that check demonstrably fails. An unread table (nil) never blocks —
    /// the setting is then published as unavailable instead of guessed.
    static func formatsBlockBounce(_ formats: [FormatSelection]?) -> Bool {
        guard let formats, !formats.isEmpty else { return false }
        return !formats.contains { $0.enabled && Self.isUncompressedPCM($0.name) }
    }
    /// The index of the format-table row whose caption names the uncompressed PCM family (see `isUncompressedPCM`).
    /// Pure and testable; nil when no such row exists — the automation then has nothing provable to check.
    static func pcmRowIndex(_ captions: [String]) -> Int? { captions.firstIndex(where: isUncompressedPCM) }
    /// The captions of checked rows that are NOT uncompressed PCM — every extra (lossy) file the bounce would write
    /// besides the WAV. Pure and testable; empty for an unread table.
    static func nonPCMChecked(_ formats: [FormatSelection]?) -> [String] {
        (formats ?? []).filter { $0.enabled && !isUncompressedPCM($0.name) }.map(\.name)
    }

    /// Result of the second deliberate dialog write: the format table set to PCM alone, or an honest failure.
    private enum FormatSwitch { case adjusted(pcmChecked: String?, unchecked: [String]), failed(detail: String) }
    /// Sets the bounce dialog's format table to uncompressed PCM alone — the same documented AXPress mechanism as
    /// every button, and (with Normalize and Cycle) one of only three settings the automation ever changes: the bounced mix must
    /// be exactly one measurable PCM file, so the PCM row (found by the same caption grammar `formatsBlockBounce`
    /// trusts) is checked and every checked non-PCM row is unchecked. Proof over trust, weighted by what each press
    /// protects: the checked PCM row is the evidence itself — when the re-read table does not prove it, the bounce is
    /// cancelled; a compressed row that refuses to uncheck would merely write an extra lossy file next to the WAV, so
    /// it is left visible in the recorded table (and named in the log) instead of cancelling a working bounce.
    private func switchFormatsToPCMOnly(_ dialog: AXUIElement) -> FormatSwitch {
        let rows = formatRows(dialog)
        guard !rows.isEmpty else { return .failed(detail: "The format table could not be read again.") }
        guard let index = Self.pcmRowIndex(rows.map { $0.selection.name }) else {
            return .failed(detail: "The format table has no uncompressed PCM row (rows: \(rows.map { $0.selection.name }.joined(separator: ", "))).")
        }
        let pcm = rows[index].selection
        if !pcm.enabled {
            guard press(rows[index].checkbox) else { return .failed(detail: "AXPress on the \u{2018}\(pcm.name)\u{2019} row's checkbox did not succeed.") }
        }
        var pressedOff: [String] = []
        for (offset, row) in rows.enumerated() where offset != index && row.selection.enabled {
            if press(row.checkbox) { pressedOff.append(row.selection.name) }
        }
        // Wait until the re-read table shows the full promised state (a table that stops being readable is not
        // proof); after the deadline, judge from the last readable table.
        let deadline = Date().addingTimeInterval(2)
        var latest: [FormatSelection]? = nil
        while Date() < deadline {
            usleep(150_000)
            guard let table = formatSelections(dialog) else { continue }
            latest = table
            if !Self.formatsBlockBounce(table), Self.nonPCMChecked(table).isEmpty { break }
        }
        guard let table = latest else { return .failed(detail: "The format table could not be re-read to verify the switch.") }
        guard !Self.formatsBlockBounce(table) else {
            return .failed(detail: "The \u{2018}\(pcm.name)\u{2019} row still reads unchecked after pressing its checkbox.")
        }
        let stillChecked = Self.nonPCMChecked(table)
        return .adjusted(pcmChecked: pcm.enabled ? nil : pcm.name, unchecked: pressedOff.filter { !stillChecked.contains($0) })
    }
    /// The caption grammar of Logic's transport Cycle control: the control names itself "Cycle" (or "Cycle Mode").
    /// Strict whole-caption equality on purpose — a control merely containing the word ("Cycle Recording", a window
    /// command like "Cycle Through Windows") must never be read as the transport Cycle, let alone pressed. Pure and testable.
    static func isCycleCaption(_ caption: String?) -> Bool {
        guard let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else { return false }
        return ["cycle", "cycle mode"].contains(caption.localizedLowercase)
    }
    /// Logic's transport Cycle control, discovered from the live windows by strict evidence: an AXCheckBox whose own
    /// caption IS the Cycle caption and whose value reads as a switch position ("0"/"1"). The main window is searched
    /// first (the control bar lives there), breadth-first and bounded — the control bar is a shallow child while the
    /// Tracks area holds thousands of deep elements, so BFS reaches it in few reads and the cap bounds the worst case.
    /// Nil when no such control is exposed — honest absence, never a guess.
    private func cycleControl(_ appElement: AXUIElement) -> AXUIElement? {
        var roots: [AXUIElement] = []
        if let main = copyElement(appElement, kAXMainWindowAttribute) { roots.append(main) }
        if let focused = copyElement(appElement, kAXFocusedWindowAttribute) { roots.append(focused) }
        roots += windows(appElement)
        for root in roots {
            if let found = firstShallowDescendant(of: root, { element in
                self.role(element) == "AXCheckBox"
                    && (Self.isCycleCaption(self.string(element, kAXTitleAttribute)) || Self.isCycleCaption(self.string(element, kAXDescriptionAttribute)))
                    && ["0", "1"].contains(self.string(element, kAXValueAttribute) ?? "")
            }) { return found }
        }
        return nil
    }
    /// Result of ensuring Cycle is off before a bounce: the proven Off state (and whether the app switched it),
    /// an honest "could not read", or a proven-On Cycle that refused to switch.
    private enum CycleEnsure { case off(switchedFromOn: Bool), unreadable, failed(detail: String) }
    /// Reads the transport Cycle control and switches it off when it is provably on — the same documented AXPress
    /// mechanism as every button, verified by re-reading the control. Runs BEFORE the bounce dialog opens, because the
    /// dialog captures its Start/End range from the cycle at open time. An absent or unreadable control is `unreadable`
    /// and never blocks; only a Cycle that provably reads On and cannot be switched off is a failure, because bouncing
    /// then provably yields a section, not the project.
    private func ensureCycleOff(_ appElement: AXUIElement) -> CycleEnsure {
        guard let control = cycleControl(appElement), let before = string(control, kAXValueAttribute) else { return .unreadable }
        if before == "0" { return .off(switchedFromOn: false) }
        guard press(control) else { return .failed(detail: "AXPress on the Cycle control did not succeed.") }
        // Proof over trust: the switch counts only when the control itself re-reads as off.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            usleep(150_000)
            if string(control, kAXValueAttribute) == "0" { return .off(switchedFromOn: true) }
        }
        return .failed(detail: "Cycle still reads On after pressing its control.")
    }

    /// The caption grammar of Logic's own format rows: the PCM row is titled "PCM" (older dialogs) or "Uncompressed"
    /// and its file types are the WAV/AIFF/CAF family. A caption naming none of these is not PCM — never a guess.
    static func isUncompressedPCM(_ name: String) -> Bool {
        let lowered = name.localizedLowercase
        return ["pcm", "uncompressed", "wave", "wav", "aiff", "aif", "caf"].contains { lowered.contains($0) }
    }

    /// Full one-click bounce of the mix (Logic's Stereo Out) to `destination` via File ▸ Bounce — the sum through the
    /// whole master chain, which no per-track export contains. Same discipline as the track export: every element is
    /// discovered at runtime, settings are read as facts and only three are ever changed, each towards the one state
    /// the evidence needs (an enabled transport Cycle is switched off before the dialog opens so the bounce covers the
    /// whole project rather than the cycle section, a level-rewriting Normalize is switched to Off, the format table is
    /// set to uncompressed PCM alone — all verified by re-reading; the bounce is cancelled only when such a switch
    /// demonstrably fails), the
    /// destination is driven through the standard save-panel keys and verified before the final press,
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

        // Cycle first, BEFORE the bounce menu: Logic documents that File ▸ Bounce covers only the cycle section while
        // Cycle mode is on, and the dialog captures its Start/End range the moment it opens — a stale cycle from
        // earlier work silently truncates the one file the analysis treats as the full-project reference. So Cycle is
        // the third and last deliberate write: the transport Cycle control is read, switched off when it is provably
        // on (verified by re-reading, recorded as a fact), and a proven-On Cycle that cannot be switched off cancels
        // the bounce honestly. An unreadable control never blocks — the finished file is accepted as is, and the AI
        // Package's duration check publishes any mismatch as a fact for the user and the model to judge.
        var cycleValue: String? = nil
        var cycleSwitchedFrom: String? = nil
        switch ensureCycleOff(appElement) {
        case .off(let switchedFromOn): cycleValue = "Off"; if switchedFromOn { cycleSwitchedFrom = "On" }
        case .unreadable: cycleValue = nil
        case .failed(let detail): return .blockedByCycle(detail: detail)
        }

        let item: String
        switch pressBounceMenu(appElement) {
        case .failed(let step, let detail): return .triggerFailed(step: step, detail: detail)
        case .pressed(let title): item = title
        }
        guard let dialog = waitForBounceWindow(appElement, timeout: 8) else { return .navigationFailed(step: "bounce_dialog", detail: "Bounce dialog did not appear after launching \u{2018}\(item)\u{2019}.") }
        // Level-affecting settings first: a Normalize other than Off would rewrite the bounced level, so the
        // automation switches it to Off itself and cancels the bounce only when that switch demonstrably fails
        // (Escape then closes what this automation opened). The format table is read as facts, and it is the second
        // deliberate write: the bounced mix must be exactly one measurable PCM file — no PCM checked yields only
        // lossy files that are no level evidence (and would not even be detected as the mix), a checked compressed
        // format writes a useless extra file — so the automation sets the table to PCM alone, verified by
        // re-reading, and cancels only when checking the PCM row demonstrably fails.
        var settings = dialogSettings(dialog)
        settings.formats = formatSelections(dialog)
        if let normalize = settings.normalize, Self.normalizeBlocksExport(normalize) == true {
            switch switchNormalizeOff(dialog, applicationPid: pid) {
            case .switched(let from):
                let formats = settings.formats
                settings = dialogSettings(dialog); settings.normalizeSwitchedFrom = from; settings.formats = formats
            case .failed(let detail):
                closeWindows(while: { self.firstBounceWindow(appElement) }, applicationPid: pid)
                return .blockedByNormalize(value: normalize, detail: detail)
            }
        }
        if settings.formats != nil, Self.formatsBlockBounce(settings.formats) || !Self.nonPCMChecked(settings.formats).isEmpty {
            switch switchFormatsToPCMOnly(dialog) {
            case .adjusted(let pcmChecked, let unchecked):
                settings.formats = formatSelections(dialog)
                settings.pcmFormatCheckedByApp = pcmChecked
                settings.formatsUncheckedByApp = unchecked.isEmpty ? nil : unchecked
            case .failed(let detail):
                closeWindows(while: { self.firstBounceWindow(appElement) }, applicationPid: pid)
                return .blockedByFormat(selected: settings.formats ?? [], detail: detail)
            }
        }
        settings.cycle = cycleValue
        settings.cycleSwitchedFrom = cycleSwitchedFrom
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
    /// Breadth-first search with a visit cap, for controls that sit shallow in a huge window (the transport bar in the
    /// project window): DFS would drown in the thousands of Tracks-area elements before reaching a sibling toolbar,
    /// while BFS finds a shallow control in few AX reads and the cap bounds the worst case when it does not exist.
    private func firstShallowDescendant(of root: AXUIElement, limit: Int = 6000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty && visited < limit {
            let element = queue.removeFirst()
            visited += 1
            if match(element) { return element }
            queue.append(contentsOf: children(element))
        }
        return nil
    }
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
