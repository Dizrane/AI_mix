import Foundation
import AppKit

enum AnalyzerVisualState: Equatable { case ready, scanning, waiting, error(String) }
enum AudioExportPhase: Equatable { case idle, exporting, done, failed(String) }

@MainActor final class AppModel: ObservableObject {
    @Published var connection = LogicConnection(found: false, localizedName: nil, pid: nil, bundleIdentifier: nil, isFinishedLaunching: nil, isTerminated: nil, accessibilityTrusted: false, diagnostics: [], message: "Not checked")
    @Published var stage: WorkflowStage = .connection
    @Published var raw: RawSnapshot?; @Published var normalized: NormalizedSnapshot?; @Published var aiPackage = ""; @Published var aiPackageURL: URL?; @Published var aiPackageStatus = ""; @Published var planText = ""; @Published var validated: [ValidatedCommand] = []; @Published var analyzerState: AnalyzerVisualState = .ready; @Published var log: [String] = []; @Published var audioAssets: [AudioAsset] = []; @Published var audioStatus = ""; @Published var exportPhase: AudioExportPhase = .idle; @Published var showExportConfirm = false; private var analysisSessionID = "unsaved_session"
    @Published var availablePlugins: [PluginInventoryItem] = []
    let analyzer: any DAWAnalyzer = LogicAccessibilityAnalyzer(); let normalizer = SnapshotNormalizer(); let validator = CommandValidator(); let audioExtractor = AudioAssetExtractor(); let exporter = LogicExportAutomator(); let pluginInventory = PluginInventory(); private var store: SessionStore?
    private let storeInitFailure: String?
    init() {
        do { store = try SessionStore(); storeInitFailure = nil } catch { store = nil; storeInitFailure = error.localizedDescription }
        refreshConnection()
    }
    /// Honest storage diagnostics. Data lives in `Data/` next to the .app by design (one self-contained folder); when macOS App
    /// Translocation runs the app from a quarantined read-only copy, that folder cannot be created — say so instead of a vague error.
    var storageUnavailableMessage: String {
        var message = "AI Mix Assistant data storage is unavailable" + (storeInitFailure.map { ": \($0)" } ?? ".")
        if TranslocationRepair.isActive { message += " macOS launched the app from a quarantined read-only copy (App Translocation) — this happens on the first launch after downloading, wherever you put the folder. Click \u{201C}Fix and Relaunch\u{201D} to remove the quarantine from the app's own folder and restart it from its real location, or move AI Mix Assistant.app to another folder with Finder once and launch it again." }
        return message
    }
    // MARK: App Translocation repair
    var storageReady: Bool { store != nil }
    var isTranslocated: Bool { TranslocationRepair.isActive }
    @Published var translocationStatus = ""
    /// User-requested repair of App Translocation: dequarantine the app's own shell folder, then relaunch from the
    /// real location and quit this read-only copy. Reports honestly at every step; nothing happens automatically.
    func fixTranslocationAndRelaunch() {
        switch TranslocationRepair.dequarantineOriginal() {
        case .failed(let reason):
            translocationStatus = reason; log.append(reason)
        case .repaired(let originalApp):
            translocationStatus = "Quarantine removed. Relaunching from \(originalApp.deletingLastPathComponent().path)\u{2026}"
            log.append(translocationStatus)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: originalApp, configuration: configuration) { [weak self] _, openError in
                Task { @MainActor in
                    if let openError {
                        let message = "Quarantine removed, but relaunch failed: \(openError.localizedDescription). Quit and open AI Mix Assistant.app yourself — it will now start normally."
                        self?.translocationStatus = message; self?.log.append(message)
                    } else { exit(0) }
                }
            }
        }
    }
    func refreshConnection() { connection = analyzer.connectionStatus(); log.append(connection.message) }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func launchLogic() { for id in ["com.apple.logic10", "com.apple.mobilelogic"] { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, _ in Task { @MainActor in self?.refreshConnection() } }; return } }; log.append("Logic Pro was not found on this Mac.") }
    func isAvailable(_ target: WorkflowStage) -> Bool { switch target { case .connection: true; case .analysis: connection.found && connection.accessibilityTrusted; case .audio, .aiPackage, .review: normalized != nil } }
    func go(to target: WorkflowStage) { if isAvailable(target) { stage = target } }
    @Published var scanProgress = 0
    private var scanWork: Task<RawSnapshot, Error>?
    /// The AX scan and normalization run off the main thread so the UI stays responsive; progress streams back and Cancel aborts cooperatively.
    func scan() {
        guard let store else { analyzerState = .error(storageUnavailableMessage); log.append(storageUnavailableMessage); return }
        analyzerState = .scanning; scanProgress = 0
        Task {
            do {
                try await store.resetForNewAnalysis()
                analysisSessionID = "analysis_\(ISO8601DateFormatter().string(from: Date()))"
                raw = nil; normalized = nil; aiPackage = ""; aiPackageURL = nil; aiPackageStatus = ""; planText = ""; validated = []; audioAssets = []; audioStatus = ""; exportPhase = .idle; showExportConfirm = false; packageFolderURL = nil; packageZipURL = nil
                log.append("Previous AI Mix Assistant analysis data removed. Starting a clean read-only scan.")
                let exporter = exporter
                let mixerOutcome = await Task.detached(priority: .userInitiated) { exporter.ensureMixerVisible() }.value
                switch mixerOutcome {
                case .alreadyVisible: log.append("Logic's Mixer is already visible.")
                case .opened(let item): log.append("Opened Logic's Mixer via \u{2018}\(item)\u{2019} so the scan sees every channel strip.")
                case .failed(let step, let detail): log.append("Could not open Logic's Mixer automatically (\(step)): \(detail) The scan continues, but channel-strip facts may be missing — open the Mixer (X) in Logic and rescan for full data.")
                }
                let analyzer = analyzer
                let onProgress: @Sendable (Int) -> Void = { [weak self] count in Task { @MainActor in self?.scanProgress = count } }
                let work = Task.detached(priority: .userInitiated) { try analyzer.fullScan(progress: onProgress) }
                scanWork = work
                let capture = try await work.value
                raw = capture
                let normalizer = normalizer
                let normalizedCapture = await Task.detached(priority: .userInitiated) { normalizer.normalize(capture, rawReference: "raw/accessibility_snapshot.json") }.value
                normalized = normalizedCapture
                _ = try await store.save(capture, folder: "raw", name: "accessibility_snapshot.json")
                _ = try await store.save(normalizedCapture, folder: "normalized", name: "normalized_project.json")
                analyzerState = .ready
                log.append("Read-only snapshot captured.")
            } catch is CancellationError {
                analyzerState = .ready; log.append("Scan cancelled — no snapshot was recorded.")
            } catch {
                analyzerState = .error(error.localizedDescription); log.append(error.localizedDescription)
            }
            scanWork = nil
        }
    }
    func cancelScan() { scanWork?.cancel() }
    @Published var packageFolderURL: URL?; @Published var packageZipURL: URL?
    var packageReadiness: PackageReadiness { PackageReadiness.evaluate(snapshot: normalized, assets: audioAssets) }
    func ensurePluginInventory() { if availablePlugins.isEmpty { availablePlugins = pluginInventory.discoverAvailable() } }
    func generateAIPackage() { guard let snapshot = normalized else { aiPackageStatus = "Run a full analysis first."; return }; ensurePluginInventory(); aiPackage = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: audioAssets, plugins: availablePlugins); let r = packageReadiness; aiPackageStatus = "AI package generated (\(r.overall.rawValue)) · \(availablePlugins.count) plugins available." + (r.audioTotal > 0 && r.audioExported < r.audioTotal ? " Audio incomplete: \(r.audioTotal - r.audioExported) WAV missing." : "") }
    func savePackage() {
        guard let snapshot = normalized, let raw, let store else { aiPackageStatus = "Run a full analysis first."; return }
        ensurePluginInventory()
        let project = snapshot.project.name.value ?? "project"
        Task {
            // Final filesystem resolution before assembling: re-resolve every asset against the confirmed current/audio directory
            // (resolveExportedFile) and re-validate with AVAudioFile, so actualExportedPath and status reflect the real files right now.
            let audioDir = await store.folderURL("audio")
            let freshAssets = audioExtractor.extract(raw: raw, normalized: snapshot, audioDirectory: audioDir)
            audioAssets = freshAssets
            let markdown = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: freshAssets, plugins: availablePlugins); aiPackage = markdown
            let audioManifest = AudioManifest(assets: freshAssets); let packageManifest = PackageManifest(project: project, assets: freshAssets)
            let expected = freshAssets.filter { $0.status == .exported }.count
            do {
                let result = try await store.savePackage(projectName: project, markdown: markdown, snapshot: snapshot, audioManifest: audioManifest, packageManifest: packageManifest, assets: freshAssets, audioExtractor: audioExtractor, probe: AudioFileProbe())
                packageFolderURL = result.folder; packageZipURL = result.zip; aiPackageURL = result.folder.appendingPathComponent("AI_MIX_ANALYSIS.md")
                if result.copiedWAVs == expected && result.missing.isEmpty {
                    aiPackageStatus = "Package saved (\(packageReadiness.overall.rawValue)) — \(result.copiedWAVs)/\(expected) WAV copied\(result.zip != nil ? ", zip ready" : "")."
                } else {
                    aiPackageStatus = "Package incomplete — \(result.copiedWAVs)/\(expected) WAV copied; not ready. Missing: \(result.missing.joined(separator: "; "))"
                }
                log.append("Package saved to \(result.folder.path): \(result.copiedWAVs)/\(expected) WAV copied, zip: \(result.zip != nil).")
            } catch { aiPackageStatus = "Could not save package: \(error.localizedDescription)" }
        }
    }
    func openPackageFolder() { Task { if let url = packageFolderURL { await store?.reveal(url: url) } else { aiPackageStatus = "Save the package first." } } }
    // MARK: Uninstall
    @Published var deleteStatus = ""
    let uninstaller = AppUninstaller()
    /// The exact directory that "Delete AI Mix Assistant" would remove, shown to the user in the final confirmation.
    var uninstallTargetPath: String { uninstaller.targetRoot()?.path ?? "unknown (app not running from its bundle)" }
    /// Runs after the SECOND confirmation only. Deletes the one app root, then quits — but only claims success if the directory is actually gone.
    func deleteApplication() {
        switch uninstaller.deleteApplicationRoot() {
        case .deleted(let path): deleteStatus = "AI Mix Assistant has been deleted."; log.append("Deleted application root: \(path)"); Task { try? await Task.sleep(nanoseconds: 700_000_000); exit(0) } // exit() skips AppKit's quit-time state saving, which would recreate the just-removed ~/Library artifacts
        case .blocked(let reason): deleteStatus = "Deletion blocked. \(reason)"
        case .failed(let reason): deleteStatus = "Unable to delete AI Mix Assistant. Reason: \(reason)"
        case .partiallyRemoved(let reason): deleteStatus = "AI Mix Assistant was only partially removed. \(reason)"
        }
    }
    @Published var clearStatus = ""
    /// Wipes the app's own working directory (current/) back to a clean first-run state and resets the UI. Uses the existing SessionStore; touches nothing outside AI Mix Assistant.
    func clearProjectData() {
        guard let store else { clearStatus = storageUnavailableMessage; return }
        Task {
            do {
                try await store.resetForNewAnalysis()
                raw = nil; normalized = nil; aiPackage = ""; aiPackageURL = nil; aiPackageStatus = ""
                planText = ""; validated = []; planStatus = ""
                audioAssets = []; audioStatus = ""; exportPhase = .idle; showExportConfirm = false
                packageFolderURL = nil; packageZipURL = nil
                analyzerState = .ready; log = []; analysisSessionID = "unsaved_session"
                stage = .connection; refreshConnection()
                clearStatus = "Project data cleared."
            } catch { clearStatus = "Could not clear project data: \(error.localizedDescription)" }
        }
    }
    func copyAIPackage() { guard !aiPackage.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(aiPackage, forType: .string); aiPackageStatus = "AI package copied — send it to your LLM." }
    @Published var planStatus = ""
    func validatePlan() { guard let snapshot = normalized else { planStatus = "Run an analysis first."; return }; do { let plan = try JSONDecoder().decode(MixPlan.self, from: Data(planText.utf8)); validated = validator.validate(plan, against: snapshot); let valid = validated.filter { $0.status == .valid }.count; planStatus = "Validated \(validated.count) action(s): \(valid) technically valid."; log.append("Plan validated: \(validated.count) actions.") } catch { validated = []; planStatus = "Invalid MixPlan JSON: \(error.localizedDescription)"; log.append("Invalid plan JSON: \(error.localizedDescription)") } }
    func prepareAudioExport() { rescanAudio(context: "prepared") }
    func refreshExportStatus() { guard !audioAssets.isEmpty else { audioStatus = "Prepare track export first."; return }; rescanAudio(context: "refreshed") }
    /// Re-scans the audio folder and rebuilds the assets from the current snapshot (deterministic). File presence alone flips requires_user_export → exported.
    private func rescanAudio(context: String) {
        guard let raw, let normalized, let store else { audioStatus = "Run a full read-only analysis first."; return }
        Task {
            let audioDir = await store.folderURL("audio")
            let assets = audioExtractor.extract(raw: raw, normalized: normalized, audioDirectory: audioDir)
            audioAssets = assets
            let manifest = AudioManifest(assets: assets); let s = manifest.summary
            do {
                _ = try await store.save(manifest, folder: "metadata", name: "audio_manifest.json")
                _ = try await store.saveText(manifest.markdown(), folder: "metadata", name: "AUDIO_ASSETS.md")
                audioStatus = "\(s.exported)/\(s.assets) WAV ready • \(s.audioRegions) regions • requires export \(s.requiresUserExport)\(s.failed > 0 ? " • failed \(s.failed)" : "")."
                log.append("Audio export \(context): \(s.exported)/\(s.assets) WAV detected.")
            } catch { audioStatus = "Could not save audio manifest: \(error.localizedDescription)" }
            if !aiPackage.isEmpty { generateAIPackage() }
        }
    }
    func copyAudioManifest() { guard !audioAssets.isEmpty else { audioStatus = "Prepare track export first."; return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(AudioManifest(assets: audioAssets).markdown(), forType: .string); audioStatus = "Audio manifest copied (Markdown) — paste it to your LLM with the WAV files." }

    /// Preconditions + confirmation before launching Logic's native export. Never fakes success.
    func requestExport() {
        guard normalized != nil, store != nil else { audioStatus = "Run a full read-only analysis first."; exportPhase = .failed("no analysis"); return }
        connection = analyzer.connectionStatus()
        guard connection.found else { audioStatus = "Logic Pro is not running — open your project first."; exportPhase = .failed("Logic not running"); return }
        guard connection.accessibilityTrusted else { audioStatus = "Accessibility permission is required to control Logic's export menu."; exportPhase = .failed("accessibility denied"); return }
        if audioAssets.isEmpty { rescanAudio(context: "prepared") }
        showExportConfirm = true
    }
    /// Launches the built-in "All Tracks as Audio Files…" export via AX, then verifies real files on disk.
    func confirmExport() {
        showExportConfirm = false
        guard let store else { return }
        exportPhase = .exporting; audioStatus = "Exporting tracks from Logic…"
        Task {
            let audioDir = await store.folderURL("audio")
            await store.clearAudioFiles() // clean our own working folder so the result is one unambiguous WAV per track
            let exporter = exporter
            let outcome = await Task.detached(priority: .userInitiated) { exporter.exportAllTracks(destination: audioDir) }.value
            switch outcome {
            case .triggerFailed(let step, let detail):
                exportPhase = .failed(step)
                audioStatus = "Could not launch Logic export at ‘\(step)’: \(detail)"
                log.append("Logic export trigger failed at \(step): \(detail)")
            case .navigationFailed(let step, let detail):
                exportPhase = .failed(step)
                audioStatus = "Logic export dialog could not be automated at ‘\(step)’: \(detail) You can finish Logic's dialog manually into the audio folder, then Refresh Export Status."
                log.append("Logic export dialog automation failed at \(step): \(detail)")
                await pollForExports(audioDir: audioDir) // still detect if the user completes it manually
            case .exported(let item, let format):
                audioStatus = "Logic is exporting via ‘\(item)’ (\(format)). Detecting files…"
                log.append("Logic export launched via \(item), format=\(format).")
                await pollForExports(audioDir: audioDir)
            }
        }
    }
    /// Waits for the REAL final WAVs, then finalises. Logic may briefly write `<name>.wav` and then rename it to `<name>_1.wav`;
    /// to avoid recording an intermediate file, the export is only considered done when every track is exported AND the resolved
    /// file set + sizes are unchanged between two consecutive scans (stable final names, not mid-write / mid-rename). A final
    /// authoritative rescan then sets `actualExportedPath` from the files that actually exist. Each file is still validated via AVAudioFile inside the extractor.
    private func pollForExports(audioDir: URL) async {
        guard let store, let raw, let normalized else { exportPhase = .idle; return }
        func fileSignature(_ assets: [AudioAsset]) -> [String] {
            assets.filter { $0.status == .exported }.compactMap { asset -> String? in
                guard let relative = asset.actualExportedPath.value else { return nil }
                let url = audioDir.appendingPathComponent((relative as NSString).lastPathComponent)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                return "\(asset.audioID)|\(relative)|\(size.map(String.init) ?? "?")"
            }.sorted()
        }
        var previousSignature: [String]? = nil
        for _ in 0..<80 { // up to ~2 minutes at 1.5s
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let assets = audioExtractor.extract(raw: raw, normalized: normalized, audioDirectory: audioDir)
            audioAssets = assets
            let summary = AudioManifest(assets: assets).summary
            audioStatus = "Detecting exported WAV… \(summary.exported)/\(summary.assets) ready."
            let signature = fileSignature(assets)
            if summary.assets > 0, summary.exported == summary.assets, signature == previousSignature { break } // stable final state
            previousSignature = signature
        }
        // Final authoritative rescan of the audio directory — `exported` and `actualExportedPath` come only from the files that really exist now.
        let finalAssets = audioExtractor.extract(raw: raw, normalized: normalized, audioDirectory: audioDir)
        audioAssets = finalAssets
        let manifest = AudioManifest(assets: finalAssets); let summary = manifest.summary
        _ = try? await store.save(manifest, folder: "metadata", name: "audio_manifest.json")
        _ = try? await store.saveText(manifest.markdown(), folder: "metadata", name: "AUDIO_ASSETS.md")
        if !aiPackage.isEmpty { generateAIPackage() }
        if summary.assets > 0 && summary.exported == summary.assets { exportPhase = .done; audioStatus = "\(summary.exported)/\(summary.assets) tracks exported." }
        else { exportPhase = .idle; audioStatus = "\(summary.exported)/\(summary.assets) tracks exported — \(summary.assets - summary.exported) still missing. Finish Logic's export into the folder, then Refresh Export Status." }
    }
    func openAudioFolder() { Task { await store?.reveal(folder: "audio") } }
    func revealData() { Task { await store?.reveal() } }
}
