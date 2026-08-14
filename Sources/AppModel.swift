import Foundation
import AppKit

enum AnalyzerVisualState: Equatable { case ready, scanning, waiting, error(String) }
enum AudioExportPhase: Equatable { case idle, exporting, done, failed(String) }

/// Launching another application, isolated away from the UI. AppKit calls `openApplication`'s completion handler on its own
/// LaunchServices queue, so a handler written inside a `@MainActor` type is inferred main-actor-isolated and Swift 6's executor
/// assertion kills the process the moment it runs off the main thread — the app "unexpectedly quit" on the very click that asked
/// for the launch. The async overload has no such handler: it resumes on the caller's actor and reports the failure as a message.
struct ApplicationLauncher: Sendable {
    func launch(at url: URL, newInstance: Bool = false) async -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = newInstance
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration); return nil } catch { return error.localizedDescription }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var connection = LogicConnection(found: false, localizedName: nil, pid: nil, bundleIdentifier: nil, isFinishedLaunching: nil, isTerminated: nil, accessibilityTrusted: false, projectOpen: nil, projectName: nil, diagnostics: [], message: "Not checked")
    @Published var stage: WorkflowStage = .connection
    @Published var raw: RawSnapshot?; @Published var normalized: NormalizedSnapshot?; @Published var aiPackage = ""; @Published var aiPackageURL: URL?; @Published var aiPackageStatus = ""; @Published var planText = ""; @Published var validated: [ValidatedCommand] = []; @Published var analyzerState: AnalyzerVisualState = .ready; @Published var log: [String] = []; @Published var audioAssets: [AudioAsset] = []; @Published var audioStatus = ""; @Published var exportPhase: AudioExportPhase = .idle; @Published var showExportConfirm = false; private var analysisSessionID = "unsaved_session"
    @Published var availablePlugins: [PluginInventoryItem] = []
    /// The export dialog settings read when THIS session launched Logic's export; nil when no export was launched (or observed) —
    /// the manifests and the AI package then say so instead of assuming the WAVs were exported level-preserving.
    @Published var exportSettings: ExportSettingsFacts?
    /// The bounced Stereo Out mix, resolved from a real file in current/mix; nil until a bounce file is validated on disk.
    @Published var mixAsset: MixBounceAsset?
    @Published var mixStatus = ""
    @Published var mixPhase: AudioExportPhase = .idle
    @Published var showBounceConfirm = false
    let analyzer: any DAWAnalyzer = LogicAccessibilityAnalyzer(); let normalizer = SnapshotNormalizer(); let validator = CommandValidator(); let audioExtractor = AudioAssetExtractor(); let metricsAnalyzer = AudioMetricsAnalyzer(); let exporter = LogicExportAutomator(); let pluginInventory = PluginInventory(); private var store: SessionStore?
    /// Metrics of already-analyzed WAVs keyed by absolute path; entries are reused only while the file's size and modification date match, so Refresh Export Status never re-analyzes unchanged files.
    private var metricsCache: [String: AudioMetrics] = [:]
    private let storeInitFailure: String?
    init() {
        // Folder-name catch-up first, before anything derives paths from Bundle.main: an install updated by an app
        // version that did not rename the shell folder yet still sits in AI_Mix_<old tag>. On a successful rename
        // this relaunches from the renamed folder and never returns; otherwise it changes nothing.
        AppUpdater.adoptVersionedShellName()
        do { store = try SessionStore(); storeInitFailure = nil } catch { store = nil; storeInitFailure = error.localizedDescription }
        refreshConnection()
        startConnectionMonitor()
        AppUpdater.removeLeftovers()
        checkForUpdates()
    }
    private var connectionMonitor: Task<Void, Never>?
    /// Keeps the connection indicators live: Logic launching/quitting and the Accessibility grant are picked up on their
    /// own within a couple of seconds, no manual Refresh needed. Only a real change updates state and the log stays quiet.
    private func startConnectionMonitor() {
        connectionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let fresh = self.analyzer.connectionStatus()
                if fresh.found != self.connection.found || fresh.accessibilityTrusted != self.connection.accessibilityTrusted || fresh.pid != self.connection.pid || fresh.projectOpen != self.connection.projectOpen || fresh.projectName != self.connection.projectName {
                    self.connection = fresh
                    self.log.append(fresh.message)
                }
            }
        }
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
            Task {
                guard let failure = await ApplicationLauncher().launch(at: originalApp, newInstance: true) else { exit(0) }
                let message = "Quarantine removed, but relaunch failed: \(failure). Quit and open AI Mix Assistant.app yourself — it will now start normally."
                translocationStatus = message; log.append(message)
            }
        }
    }
    // MARK: Self-update
    @Published var updateAvailable: AppUpdate?
    @Published var updateStatus = ""
    @Published var updateInProgress = false
    private let updater = AppUpdater()
    /// Reads the latest GitHub release and compares versions; nothing is downloaded or installed here. The automatic
    /// launch check stays silent on failure (offline is not an error worth a banner); a user-initiated check reports
    /// every outcome, including "already up to date".
    func checkForUpdates(userInitiated: Bool = false) {
        guard let current = AppUpdater.currentVersion() else {
            if userInitiated { updateStatus = "Update checks need the released .app; this development run has no version to compare." }
            return
        }
        if userInitiated { updateStatus = "Checking for updates\u{2026}" }
        Task {
            do {
                let latest = try await updater.latestRelease()
                if AppUpdater.isNewer(latest.tag, than: current) {
                    updateAvailable = latest
                    updateStatus = "Version \(latest.tag) is available (you have v\(current))."
                } else {
                    updateAvailable = nil
                    if userInitiated { updateStatus = "You are on the latest version (v\(current))." }
                }
            } catch {
                if userInitiated { updateStatus = "Update check failed: \(error.localizedDescription)" }
            }
        }
    }
    /// Installing an update while the app is mid-work would sabotage that work: the swap renames the folder and
    /// relaunches the app, killing a running scan or the WAV-detection polling, and Logic would keep exporting into
    /// a destination path whose folder name just changed. The buttons disable on this and the guard tells the reason.
    var updateBlockedByWork: Bool { analyzerState == .scanning || exportPhase == .exporting || mixPhase == .exporting }
    /// User-requested in-place update: download the release ZIP, verify the new bundle, swap it in next to the
    /// untouched Data/, relaunch the new version and quit this one. Any failure is reported and leaves the current
    /// installation working; a translocated (quarantined read-only) copy must be repaired first, because its real
    /// bundle location is not what is running.
    func installUpdate() {
        guard let update = updateAvailable, !updateInProgress else { return }
        if updateBlockedByWork {
            updateStatus = "An analysis or Logic export is running — finish or cancel it first, then install the update."
            return
        }
        if TranslocationRepair.isActive {
            updateStatus = "The app is running from a translocated read-only copy. Click \u{201C}Fix and Relaunch\u{201D} first, then update."
            return
        }
        updateInProgress = true
        Task {
            let result = await updater.downloadAndInstall(update) { message in Task { @MainActor in self.updateStatus = message } }
            switch result {
            case .installed(let app):
                updateStatus = "Updated to \(update.tag). Relaunching\u{2026}"
                log.append("Updated to \(update.tag); relaunching from \(app.path)")
                if let failure = await ApplicationLauncher().launch(at: app, newInstance: true) {
                    updateStatus = "Updated to \(update.tag), but relaunch failed: \(failure). Quit and open AI Mix Assistant.app yourself — it is already the new version."
                    updateInProgress = false
                } else { exit(0) }
            case .failed(let reason):
                updateStatus = reason
                log.append(reason)
                updateInProgress = false
            }
        }
    }

    func refreshConnection() { connection = analyzer.connectionStatus(); log.append(connection.message) }
    func openAccessibilitySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    func launchLogic() {
        guard let url = ["com.apple.logic10", "com.apple.mobilelogic"].lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { log.append("Logic Pro was not found on this Mac."); return }
        Task {
            if let failure = await ApplicationLauncher().launch(at: url) { log.append("Could not launch Logic Pro: \(failure)") }
            refreshConnection()
        }
    }
    /// One truth per stage: the sidebar checkmark, the next stage's availability and the "Continue" button all derive
    /// from it. A stage is complete only when its own work is really done — Audio requires every discovered audio track
    /// to have a real exported WAV on disk, never a merely prepared asset list.
    func isComplete(_ stage: WorkflowStage) -> Bool { switch stage { case .connection: connection.found && connection.accessibilityTrusted && connection.projectOpen == true; case .analysis: normalized != nil; case .audio: !audioAssets.isEmpty && audioAssets.allSatisfy { $0.status == .exported }; case .aiPackage: !aiPackage.isEmpty; case .review: !validated.isEmpty } }
    /// Strict step order: a stage opens only when the previous one is complete — never every stage at once after a scan.
    func isAvailable(_ target: WorkflowStage) -> Bool { WorkflowStage(rawValue: target.rawValue - 1).map(isComplete) ?? true }
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
                raw = nil; normalized = nil; aiPackage = ""; aiPackageURL = nil; aiPackageStatus = ""; planText = ""; validated = []; audioAssets = []; audioStatus = ""; exportPhase = .idle; showExportConfirm = false; packageFolderURL = nil; packageZipURL = nil; metricsCache = [:]; exportSettings = nil; mixAsset = nil; mixStatus = ""; mixPhase = .idle; showBounceConfirm = false
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
            NSApp.activate() // the mixer step activated Logic; bring the user back to the results
        }
    }
    func cancelScan() { scanWork?.cancel() }
    @Published var packageFolderURL: URL?; @Published var packageZipURL: URL?
    var packageReadiness: PackageReadiness { PackageReadiness.evaluate(snapshot: normalized, assets: audioAssets) }
    func ensurePluginInventory() { if availablePlugins.isEmpty { availablePlugins = pluginInventory.discoverAvailable() } }
    func generateAIPackage() { guard let snapshot = normalized else { aiPackageStatus = "Run a full analysis first."; return }; ensurePluginInventory(); aiPackage = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: audioAssets, plugins: availablePlugins, delivery: .markdownOnly, exportSettings: exportSettings, mix: mixAsset); let r = packageReadiness; aiPackageStatus = "AI package generated (\(r.overall.rawValue)) · \(availablePlugins.count) plugins available." + (r.audioTotal > 0 && r.audioExported < r.audioTotal ? " Audio incomplete: \(r.audioTotal - r.audioExported) WAV missing." : "") }
    func savePackage() {
        guard let snapshot = normalized, let raw, let store else { aiPackageStatus = "Run a full analysis first."; return }
        ensurePluginInventory()
        let project = snapshot.project.name.value ?? "project"
        Task {
            // Final filesystem resolution before assembling: re-resolve every asset against the confirmed current/audio directory
            // (resolveExportedFile) and re-validate with AVAudioFile, so actualExportedPath and status reflect the real files right now.
            let audioDir = await store.folderURL("audio")
            let freshAssets = await analyzedAssets(raw: raw, normalized: snapshot, audioDir: audioDir)
            audioAssets = freshAssets
            // Two readers, two deliveries: the folder/ZIP ships the JSON and WAVs next to the document, while the on-screen text is
            // what "Copy for AI" puts on the clipboard — Markdown alone, so it must say so instead of pointing at files.
            let markdown = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: freshAssets, plugins: availablePlugins, delivery: .fullPackage, exportSettings: exportSettings, mix: mixAsset)
            aiPackage = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: freshAssets, plugins: availablePlugins, delivery: .markdownOnly, exportSettings: exportSettings, mix: mixAsset)
            let audioManifest = AudioManifest(assets: freshAssets, exportSettings: exportSettings, mix: mixAsset); let packageManifest = PackageManifest(project: project, assets: freshAssets, mix: mixAsset)
            let expected = freshAssets.filter { $0.status == .exported }.count
            do {
                let result = try await store.savePackage(projectName: project, markdown: markdown, snapshot: snapshot, audioManifest: audioManifest, packageManifest: packageManifest, assets: freshAssets, mix: mixAsset, audioExtractor: audioExtractor, probe: AudioFileProbe())
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
                audioAssets = []; audioStatus = ""; exportPhase = .idle; showExportConfirm = false; metricsCache = [:]; exportSettings = nil
                mixAsset = nil; mixStatus = ""; mixPhase = .idle; showBounceConfirm = false
                packageFolderURL = nil; packageZipURL = nil
                analyzerState = .ready; log = []; analysisSessionID = "unsaved_session"
                stage = .connection; refreshConnection()
                clearStatus = "Project data cleared."
            } catch { clearStatus = "Could not clear project data: \(error.localizedDescription)" }
        }
    }
    func copyAIPackage() { guard !aiPackage.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(aiPackage, forType: .string); aiPackageStatus = "AI package copied — send it to your LLM." }
    @Published var planStatus = ""
    func validatePlan() { guard let snapshot = normalized else { planStatus = "Run an analysis first."; return }; do { let plan = try JSONDecoder().decode(MixPlan.self, from: Data(planText.utf8)); validated = validator.validate(plan, against: snapshot); let valid = validated.filter { $0.status == .valid }.count; planStatus = "Validated \(plural(validated.count, "action")): \(valid) technically valid."; log.append("Plan validated: \(validated.count) actions.") } catch { validated = []; planStatus = "Invalid MixPlan JSON: \(error.localizedDescription)"; log.append("Invalid plan JSON: \(error.localizedDescription)") } }
    func prepareAudioExport() { rescanAudio(context: "prepared") }
    func refreshExportStatus() { guard !audioAssets.isEmpty else { audioStatus = "Prepare track export first."; return }; rescanAudio(context: "refreshed") }
    /// Re-scans the audio folder and rebuilds the assets from the current snapshot (deterministic). File presence alone flips requires_user_export → exported.
    private func rescanAudio(context: String) {
        guard let raw, let normalized, let store else { audioStatus = "Run a full read-only analysis first."; return }
        Task {
            let audioDir = await store.folderURL("audio")
            let assets = await analyzedAssets(raw: raw, normalized: normalized, audioDir: audioDir)
            audioAssets = assets
            let manifest = AudioManifest(assets: assets, exportSettings: exportSettings, mix: mixAsset); let s = manifest.summary
            do {
                _ = try await store.save(manifest, folder: "metadata", name: "audio_manifest.json")
                _ = try await store.saveText(manifest.markdown(), folder: "metadata", name: "AUDIO_ASSETS.md")
                audioStatus = "\(s.exported)/\(s.assets) WAV ready • \(s.audioRegions) regions • requires export \(s.requiresUserExport)\(s.failed > 0 ? " • failed \(s.failed)" : "")."
                log.append("Audio export \(context): \(s.exported)/\(s.assets) WAV detected.")
            } catch { audioStatus = "Could not save audio manifest: \(error.localizedDescription)" }
            if !aiPackage.isEmpty { generateAIPackage() }
        }
    }
    /// Extraction plus local DSP metrics, both off the main thread (like scan()) so the UI stays responsive. Metrics
    /// are facts about the FINAL files on disk: computed only for `exported` assets, served from the cache when the
    /// file identity (path + size + modification date) is unchanged, honestly recomputed when it is not.
    private func analyzedAssets(raw: RawSnapshot, normalized: NormalizedSnapshot, audioDir: URL) async -> [AudioAsset] {
        let extractor = audioExtractor; let metricsAnalyzer = metricsAnalyzer; let cache = metricsCache
        let (assets, refreshedCache) = await Task.detached(priority: .userInitiated) { () -> ([AudioAsset], [String: AudioMetrics]) in
            let extracted = extractor.extract(raw: raw, normalized: normalized, audioDirectory: audioDir)
            return metricsAnalyzer.attach(to: extracted, audioDirectory: audioDir, cache: cache)
        }.value
        metricsCache = refreshedCache
        return assets
    }
    func copyAudioManifest() { guard !audioAssets.isEmpty else { audioStatus = "Prepare track export first."; return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(AudioManifest(assets: audioAssets, exportSettings: exportSettings, mix: mixAsset).markdown(), forType: .string); audioStatus = "Audio manifest copied (Markdown) — paste it to your LLM with the WAV files." }

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
            NSApp.activate() // Logic keeps exporting on its own; bring the user back to the detection progress
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
            case .blockedByNormalize(let value):
                exportPhase = .failed("normalize")
                audioStatus = "Export stopped: Logic's export dialog has Normalize set to ‘\(value)’, which would rewrite the exported levels and falsify the relative-loudness evidence. Set Normalize to Off in File ▸ Export ▸ All Tracks as Audio Files… once, then export again."
                log.append("Logic export blocked: Normalize is ‘\(value)’, not Off — the dialog was cancelled and nothing was exported.")
            case .exported(let item, let format, let settings):
                exportSettings = ExportSettingsFacts(settings: settings)
                audioStatus = "Logic is exporting via ‘\(item)’ (\(format)). Detecting files…"
                log.append("Logic export launched via \(item), format=\(format), bit depth=\(settings.bitDepth ?? "unread"), normalize=\(settings.normalize ?? "unread").")
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
        var idleScans = 0
        for _ in 0..<400 { // hard cap ~10 minutes; large projects keep the wait alive as long as files keep arriving
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let assets = audioExtractor.extract(raw: raw, normalized: normalized, audioDirectory: audioDir)
            audioAssets = assets
            let summary = AudioManifest(assets: assets).summary
            audioStatus = "Detecting exported WAV… \(summary.exported)/\(summary.assets) ready."
            let signature = fileSignature(assets)
            if summary.assets > 0, summary.exported == summary.assets, signature == previousSignature { break } // stable final state
            idleScans = signature == previousSignature ? idleScans + 1 : 0
            previousSignature = signature
            if idleScans >= 40 { break } // a full minute with no new or growing files — Logic is not exporting (anymore)
        }
        // Final authoritative rescan of the audio directory — `exported` and `actualExportedPath` come only from the files that
        // really exist now, and DSP metrics are computed here, from those final stable files, never from mid-write intermediates.
        let finalAssets = await analyzedAssets(raw: raw, normalized: normalized, audioDir: audioDir)
        audioAssets = finalAssets
        let manifest = AudioManifest(assets: finalAssets, exportSettings: exportSettings, mix: mixAsset); let summary = manifest.summary
        _ = try? await store.save(manifest, folder: "metadata", name: "audio_manifest.json")
        _ = try? await store.saveText(manifest.markdown(), folder: "metadata", name: "AUDIO_ASSETS.md")
        if !aiPackage.isEmpty { generateAIPackage() }
        if summary.assets > 0 && summary.exported == summary.assets { exportPhase = .done; audioStatus = "\(summary.exported)/\(summary.assets) tracks exported." }
        else { exportPhase = .idle; audioStatus = "\(summary.exported)/\(summary.assets) tracks exported — \(summary.assets - summary.exported) still missing. Finish Logic's export into the folder, then Refresh Export Status." }
    }
    func openAudioFolder() { Task { await store?.reveal(folder: "audio") } }
    func revealData() { Task { await store?.reveal() } }

    // MARK: Mix bounce (Stereo Out)

    /// Preconditions + confirmation before launching Logic's native bounce. Never fakes success.
    func requestMixBounce() {
        guard normalized != nil, store != nil else { mixStatus = "Run a full read-only analysis first."; mixPhase = .failed("no analysis"); return }
        connection = analyzer.connectionStatus()
        guard connection.found else { mixStatus = "Logic Pro is not running — open your project first."; mixPhase = .failed("Logic not running"); return }
        guard connection.accessibilityTrusted else { mixStatus = "Accessibility permission is required to control Logic's bounce dialog."; mixPhase = .failed("accessibility denied"); return }
        showBounceConfirm = true
    }
    /// Launches File ▸ Bounce via AX, then waits for the REAL file on disk — a realtime bounce writes for as long as
    /// the song plays, so nothing is claimed until a stable, AVAudioFile-readable file exists in current/mix.
    func confirmMixBounce() {
        showBounceConfirm = false
        guard let store else { return }
        mixPhase = .exporting; mixStatus = "Bouncing the mix from Logic…"; mixAsset = nil
        Task {
            let mixDir = await store.folderURL("mix")
            await store.clearAudioFiles(folder: "mix") // one unambiguous file per bounce
            let exporter = exporter
            let outcome = await Task.detached(priority: .userInitiated) { exporter.bounceMix(destination: mixDir) }.value
            NSApp.activate() // Logic keeps bouncing on its own; bring the user back to the detection progress
            switch outcome {
            case .triggerFailed(let step, let detail):
                mixPhase = .failed(step)
                mixStatus = "Could not launch Logic's bounce at ‘\(step)’: \(detail)"
                log.append("Logic bounce trigger failed at \(step): \(detail)")
            case .blockedByNormalize(let value):
                mixPhase = .failed("normalize")
                mixStatus = "Bounce stopped: Logic's bounce dialog has Normalize set to ‘\(value)’, which would rewrite the mix level and falsify the loudness evidence. Set Normalize to Off in the bounce dialog once, then bounce again."
                log.append("Logic bounce blocked: Normalize is ‘\(value)’, not Off — the dialog was cancelled and nothing was bounced.")
            case .blockedByFormat(let selected):
                mixPhase = .failed("format")
                let checked = selected.filter(\.enabled).map(\.name)
                mixStatus = "Bounce stopped: the bounce dialog's format table has no uncompressed PCM format checked (\(checked.isEmpty ? "nothing is checked" : "checked: \(checked.joined(separator: ", "))")). A lossy file is not level evidence and would not be detected as the mix. In the bounce dialog, check PCM (Uncompressed) once and uncheck the compressed formats, then bounce again."
                log.append("Logic bounce blocked: format table read as \(selected.caption) — no uncompressed PCM format is checked; the dialog was cancelled and nothing was bounced.")
            case .navigationFailed(let step, let detail):
                mixPhase = .failed(step)
                mixStatus = "Logic's bounce dialog could not be automated at ‘\(step)’: \(detail) You can finish the dialog manually into the mix folder — the file will still be detected."
                log.append("Logic bounce dialog automation failed at \(step): \(detail)")
                await pollForMixBounce(mixDir: mixDir, settings: nil) // still detect if the user completes it manually
            case .bounced(let item, let settings):
                mixStatus = "Logic is bouncing via ‘\(item)’. Waiting for the file…"
                log.append("Logic bounce launched via \(item), format=\(settings.format ?? "unread"), normalize=\(settings.normalize ?? "unread").")
                await pollForMixBounce(mixDir: mixDir, settings: ExportSettingsFacts(settings: settings))
            }
        }
    }
    /// Done only when the file set in current/mix is stable between two scans AND the newest file really reads as audio
    /// (a mid-write bounce file does not); the asset's facts and DSP metrics then come from that final file alone.
    private func pollForMixBounce(mixDir: URL, settings: ExportSettingsFacts?) async {
        func signature() -> [String] {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: mixDir.path) else { return [] }
            return names.filter { ["wav", "aif", "aiff", "caf"].contains(($0 as NSString).pathExtension.lowercased()) }
                .map { name in
                    let size = (try? manager.attributesOfItem(atPath: mixDir.appendingPathComponent(name).path))?[.size] as? Int
                    return "\(name)|\(size.map(String.init) ?? "?")"
                }.sorted()
        }
        var previous: [String]? = nil
        var idleScans = 0
        for _ in 0..<1200 { // hard cap ~30 minutes: a realtime bounce takes as long as the song plays
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let current = signature()
            if !current.isEmpty, current == previous {
                let resolved = await Task.detached(priority: .userInitiated) { MixBounceAsset.resolve(in: mixDir, settings: settings) }.value
                if let resolved {
                    mixAsset = resolved
                    mixPhase = .done
                    mixStatus = "Mix bounced: \((resolved.relativePath as NSString).lastPathComponent)" + (resolved.metrics?.integratedLoudnessLUFS.value.map { String(format: " · %.1f LUFS integrated", $0) } ?? "")
                    log.append("Mix bounce detected: \(resolved.relativePath).")
                    await saveAudioManifest()
                    if !aiPackage.isEmpty { generateAIPackage() }
                    return
                }
            }
            idleScans = current == previous ? idleScans + 1 : 0
            previous = current
            mixStatus = current.isEmpty ? "Waiting for Logic's bounce file…" : "Bounce in progress — waiting for the file to finish…"
            if idleScans >= 80 { break } // two minutes with nothing arriving or becoming readable — Logic is not bouncing (anymore)
        }
        mixPhase = .idle
        mixStatus = "No finished mix bounce was detected in the mix folder. Finish Logic's bounce there manually or bounce again."
    }
    /// Rewrites audio_manifest.json / AUDIO_ASSETS.md from the current state (assets, export settings, mix).
    private func saveAudioManifest() async {
        guard let store else { return }
        let manifest = AudioManifest(assets: audioAssets, exportSettings: exportSettings, mix: mixAsset)
        _ = try? await store.save(manifest, folder: "metadata", name: "audio_manifest.json")
        _ = try? await store.saveText(manifest.markdown(), folder: "metadata", name: "AUDIO_ASSETS.md")
    }
    func openMixFolder() { Task { await store?.reveal(folder: "mix") } }
}
