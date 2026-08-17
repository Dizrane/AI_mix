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
    let analyzer: any DAWAnalyzer = LogicAccessibilityAnalyzer(); let normalizer = SnapshotNormalizer(); let validator = CommandValidator(); let audioExtractor = AudioAssetExtractor(); let metricsAnalyzer = AudioMetricsAnalyzer(); let exporter = LogicExportAutomator(); let pluginInventory = PluginInventory(); var store: SessionStore?

    // MARK: Capy assistant (LLM over the Capy API) — orchestration state; the API key itself lives ONLY in the
    // Keychain (CapyKeyStore) and is loaded at call time, never held in published state.
    @Published var capyKeyPresent = CapyKeyStore().load()?.isEmpty == false
    @Published var capyKeyStatus = ""
    @Published var capyProjectID = UserDefaults.standard.string(forKey: "capyProjectID") ?? "" { didSet { UserDefaults.standard.set(capyProjectID, forKey: "capyProjectID") } }
    @Published var capyModelID = UserDefaults.standard.string(forKey: "capyModelID") ?? CapyAPI.defaultModel { didSet { UserDefaults.standard.set(capyModelID, forKey: "capyModelID") } }
    @Published var capyReasoning = UserDefaults.standard.string(forKey: "capyReasoning") ?? "default" { didSet { UserDefaults.standard.set(capyReasoning, forKey: "capyReasoning") } }
    @Published var assistantBusy = false
    @Published var assistantStatus = ""
    @Published var assistantThreadID: String?
    @Published var assistantThreadStatus = ""
    @Published var assistantTranscript: [CapyMessage] = []
    @Published var assistantAwaitingConfirmation = false
    @Published var assistantConfirmationText = ""
    @Published var assistantGraphReady = false
    @Published var assistantGraphIssues: [String] = []
    @Published var assistantFailure: String?
    @Published var assistantCanResumePolling = false
    var assistantConfirmationSent = false
    /// How many non-empty assistant replies the transcript held when the last message went out — the baseline
    /// `AssistantSettling.turnComplete` compares against, so a thread status that has not caught up with the send
    /// yet can never pass off the previous transcript as the model's answer.
    var assistantRepliesBeforeSend = 0
    var assistantWork: Task<Void, Never>?

    // MARK: Offline render (MixEngine) — the Render stage's state; manual paste works with no API key at all.
    @Published var renderGraphText = ""
    @Published var renderIssues: [String] = []
    @Published var renderGraphValid = false
    @Published var renderStatus = ""
    @Published var renderRunning = false
    @Published var renderedMixURL: URL?
    @Published var renderSummary = ""
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
    var updateBlockedByWork: Bool { analyzerState == .scanning || exportPhase == .exporting || mixPhase == .exporting || executionRunning || verificationRunning }
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
    /// to have a real exported WAV on disk AND the bounced Stereo Out mix validated in current/mix (the sum is the
    /// loudness reference the AI package is built around), never a merely prepared asset list or the tracks alone.
    func isComplete(_ stage: WorkflowStage) -> Bool { switch stage { case .connection: connection.found && connection.accessibilityTrusted && connection.projectOpen == true; case .analysis: normalized != nil; case .audio: !audioAssets.isEmpty && audioAssets.allSatisfy { $0.status == .exported } && mixAsset != nil; case .aiPackage: !aiPackage.isEmpty; case .assistant: assistantGraphReady; case .render: renderedMixURL != nil; case .review: !validated.isEmpty } }
    /// Strict step order up to the AI package: a stage opens only when the previous one is complete. The three
    /// consumers of the package — Assistant (needs the Capy key), Render (works with a manual paste and no key at
    /// all) and Review (the Logic live path) — each open on the package alone, so no optional path gates another.
    func isAvailable(_ target: WorkflowStage) -> Bool {
        switch target {
        case .assistant, .render, .review: isComplete(.aiPackage)
        default: WorkflowStage(rawValue: target.rawValue - 1).map(isComplete) ?? true
        }
    }
    /// Navigation accepts only stages the interface exposes: the hidden Review stage (live execution) is unreachable
    /// even programmatically, so no code path can land the UI on it.
    func go(to target: WorkflowStage) { if WorkflowStage.visible.contains(target) && isAvailable(target) { stage = target } }
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
                raw = nil; normalized = nil; aiPackage = ""; aiPackageURL = nil; aiPackageStatus = ""; planText = ""; validated = []; resetExecutionState(); resetVerificationState(); resetAssistantState(); resetRenderState(); audioAssets = []; audioStatus = ""; exportPhase = .idle; showExportConfirm = false; packageFolderURL = nil; packageZipURL = nil; metricsCache = [:]; exportSettings = nil; mixAsset = nil; mixStatus = ""; mixPhase = .idle; showBounceConfirm = false
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
                ensurePluginInventory() // manufacturer facts are a cross-reference against the installed-plugin inventory
                let normalizer = normalizer; let inventory = availablePlugins
                let normalizedCapture = await Task.detached(priority: .userInitiated) { normalizer.normalize(capture, rawReference: "raw/accessibility_snapshot.json", pluginInventory: inventory) }.value
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
    func generateAIPackage() { guard let package = packageText(delivery: .markdownOnly) else { aiPackageStatus = "Run a full analysis first."; return }; aiPackage = package; let r = packageReadiness; aiPackageStatus = "AI package generated (\(r.overall.rawValue)\(postApplyVerifiedAt != nil ? ", post-apply" : "")) · \(availablePlugins.count) plugins available." + (r.audioTotal > 0 && r.audioExported < r.audioTotal ? " Audio incomplete: \(r.audioTotal - r.audioExported) WAV missing." : "") }
    /// The package document in a given delivery, built from the current analysis state; nil before an analysis exists.
    /// The Assistant sends the `.apiDelivery` variant — same facts, API-specific preamble and response contract.
    func packageText(delivery: PackageDelivery) -> String? {
        guard let snapshot = normalized else { return nil }
        ensurePluginInventory()
        return AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: audioAssets, plugins: availablePlugins, delivery: delivery, exportSettings: exportSettings, mix: mixAsset, postApply: postApplyReport)
    }
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
            let markdown = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: freshAssets, plugins: availablePlugins, delivery: .fullPackage, exportSettings: exportSettings, mix: mixAsset, postApply: postApplyReport)
            aiPackage = AIPackageGenerator().make(snapshot: snapshot, sessionID: analysisSessionID, audio: freshAssets, plugins: availablePlugins, delivery: .markdownOnly, exportSettings: exportSettings, mix: mixAsset, postApply: postApplyReport)
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
                planText = ""; validated = []; planStatus = ""; resetExecutionState(); resetVerificationState(); resetAssistantState(); resetRenderState()
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
    func validatePlan() { guard let snapshot = normalized else { planStatus = "Run an analysis first."; return }; do { let plan = try JSONDecoder().decode(MixPlan.self, from: Data(MixPlan.extractJSON(from: planText).utf8)); validated = validator.validate(plan, against: snapshot); resetExecutionState(); let valid = validated.filter { $0.status == .valid }.count; planStatus = "Validated \(plural(validated.count, "action")): \(valid) technically valid."; log.append("Plan validated: \(validated.count) actions.") } catch { validated = []; resetExecutionState(); planStatus = "Invalid MixPlan JSON: \(error.localizedDescription)"; log.append("Invalid plan JSON: \(error.localizedDescription)") } }

    // MARK: Plan execution (DRY RUN default; LIVE only by explicit user choice)

    /// DRY RUN is the default and never touches Logic; LIVE must be selected deliberately and re-confirmed per run.
    @Published var executionMode: OperationMode = .dryRun
    @Published var executionResults: [ExecutionResult] = []
    @Published var executionStatus = ""
    @Published var executionRunning = false
    @Published var showLiveConfirm = false
    var validExecutableActions: Int { validated.filter { $0.status == .valid }.count }
    private func resetExecutionState() { executionResults = []; executionStatus = ""; executionMode = .dryRun; showLiveConfirm = false }
    /// Preconditions + explicit confirmation before a LIVE run; a dry run needs no ceremony because it writes nothing.
    func requestExecution() {
        guard !executionRunning else { return }
        guard !validated.isEmpty, validExecutableActions > 0 else { executionStatus = "Validate a plan with at least one technically valid action first."; return }
        if executionMode == .live {
            connection = analyzer.connectionStatus()
            guard connection.found else { executionStatus = "Logic Pro is not running — open your project first."; return }
            guard connection.accessibilityTrusted else { executionStatus = "Accessibility permission is required for live execution."; return }
            showLiveConfirm = true
        } else { runExecution() }
    }
    func confirmLiveExecution() { showLiveConfirm = false; runExecution() }
    /// Runs the validated queue through SafeExecutor off the main thread. Only status == .valid actions can execute;
    /// after a LIVE queue a fresh read-only scan is compared against the snapshot the plan was validated with, so the
    /// user sees what really changed next to each action's own before/after readback.
    private func runExecution() {
        guard let snapshot = normalized else { executionStatus = "Run an analysis first."; return }
        let mode = executionMode
        executionRunning = true; executionResults = []
        executionStatus = mode == .live ? "Executing the plan in Logic\u{2026}" : "Dry run \u{2014} nothing is written to Logic."
        Task {
            let commands = validated
            let exporter = exporter
            if mode == .live {
                // The adapter finds strips in the live Mixer, so make sure it is on screen — same step as the scan.
                let mixerOutcome = await Task.detached(priority: .userInitiated) { exporter.ensureMixerVisible() }.value
                if case .failed(let step, let detail) = mixerOutcome { log.append("Could not confirm Logic's Mixer is visible before execution (\(step)): \(detail)") }
            }
            let adapters: [any LiveActionAdapter] = mode == .live ? [LogicChannelStripAdapter()] : []
            let executor = SafeExecutor(adapters: adapters, context: .init(snapshot: snapshot))
            let results = await Task.detached(priority: .userInitiated) { await executor.execute(commands, mode: mode) }.value
            executionResults = results
            let executed = results.filter { $0.status == ExecutionStatus.executed }.count
            let failed = results.filter { $0.status == ExecutionStatus.failed }.count
            if mode == .live {
                let outcome = "\(executed)/\(results.count) actions executed" + (failed > 0 ? ", \(failed) failed" : "")
                executionStatus = outcome + " — verifying with a fresh scan\u{2026}"
                log.append("LIVE execution finished: \(outcome).")
                await runVerification(executedLive: true)
                executionStatus = outcome + (verificationDiff.map { ". Fresh scan: \(plural($0.changed.count, "track")) changed, \($0.unchanged.count) unchanged." } ?? ", but the verification scan failed — see Verification below.")
                NSApp.activate() // execution activated Logic; bring the user back to the results
            } else {
                executionStatus = "Dry run finished: \(plural(validExecutableActions, "valid action")) would go to the live adapters; nothing was written to Logic."
                log.append("Dry run finished for \(results.count) actions.")
            }
            executionRunning = false
        }
    }

    // MARK: Post-apply verification — the closed before/after loop

    /// The checks of the last verified plan against the fresh post-apply facts; kept until the next verification or a
    /// new analysis so the post-apply AI package can carry them into the model's second round.
    @Published var planChecks: [PlanTargetCheck] = []
    @Published var verificationDiff: SnapshotDiff?
    @Published var verificationStatus = ""
    @Published var verificationRunning = false
    @Published var postApplyVerifiedAt: Date?
    private var postApplyExecutedLive = false
    /// The pre-apply measurements frozen when the verification ran: control moves change the audio only after a new
    /// export/bounce, so the files on disk at verification time still carry the state the plan reasoned from.
    private var metricsBaseline: [MetricsBaselineEntry] = []
    /// Live join of the frozen baseline with the current files' metrics — recomputed on every read, so a re-export or
    /// re-bounce immediately shows its before/after rows (the metrics cache keys by file identity).
    var metricDeltas: [MetricsDelta] { MetricsComparison.compare(baseline: metricsBaseline, assets: audioAssets, mix: mixAsset) }
    /// Everything the post-apply AI package states about the cycle; nil until a verification ran in this analysis.
    var postApplyReport: PostApplyReport? {
        guard let verifiedAt = postApplyVerifiedAt else { return nil }
        return .init(verifiedAt: verifiedAt, executedLive: postApplyExecutedLive, checks: planChecks, diff: verificationDiff ?? .init(changed: [], unchanged: [], errors: []), metricDeltas: metricDeltas)
    }
    private func resetVerificationState() { planChecks = []; verificationDiff = nil; verificationStatus = ""; postApplyVerifiedAt = nil; postApplyExecutedLive = false; metricsBaseline = [] }
    /// The manual entry into the closed loop, for a plan the user applied by hand in Logic: the same fresh scan, diff,
    /// plan-target checks and snapshot adoption that run automatically after a LIVE queue.
    func verifyAppliedPlan() {
        guard !verificationRunning, !executionRunning, analyzerState != .scanning else { return }
        guard normalized != nil else { verificationStatus = "Run an analysis first."; return }
        guard !validated.isEmpty else { verificationStatus = "Validate the plan you applied first — the checks compare its targets with the fresh facts."; return }
        connection = analyzer.connectionStatus()
        guard connection.found else { verificationStatus = "Logic Pro is not running — open your project first."; return }
        guard connection.accessibilityTrusted else { verificationStatus = "Accessibility permission is required for the verification scan."; return }
        verificationRunning = true
        verificationStatus = "Verifying the applied plan with a fresh read-only scan\u{2026}"
        Task {
            await runVerification(executedLive: false)
            verificationRunning = false
            NSApp.activate() // the mixer step activated Logic; bring the user back to the results
        }
    }
    /// One fresh read-only scan closes the loop: DiffEngine against the snapshot the plan was validated with, every
    /// valid action's target checked against the re-read known fact (tolerance 0.05 — the validator's own), the
    /// pre-apply metrics frozen as the before/after baseline, and the fresh snapshot ADOPTED as the current analysis —
    /// so the next generated AI package is the post-apply second round, and a re-export/re-bounce measures the new
    /// files against the frozen baseline. Verification never invents: a fact the fresh scan does not prove stays
    /// unverifiable, and metrics rows exist only where both sides were really measured.
    private func runVerification(executedLive: Bool) async {
        guard let reference = normalized else { return }
        verificationDiff = nil
        do {
            let exporter = exporter
            let mixerOutcome = await Task.detached(priority: .userInitiated) { exporter.ensureMixerVisible() }.value
            if case .failed(let step, let detail) = mixerOutcome { log.append("Could not confirm Logic's Mixer is visible before the verification scan (\(step)): \(detail)") }
            let analyzer = analyzer
            let fresh = try await Task.detached(priority: .userInitiated) { try analyzer.fullScan() }.value
            ensurePluginInventory()
            let normalizer = normalizer; let inventory = availablePlugins
            let freshNormalized = await Task.detached(priority: .userInitiated) { normalizer.normalize(fresh, rawReference: "raw/accessibility_snapshot.json", pluginInventory: inventory) }.value
            let diff = DiffEngine().compare(before: reference, after: freshNormalized)
            let checks = PlanVerifier().verify(validated, against: freshNormalized)
            var baseline: [MetricsBaselineEntry] = audioAssets.compactMap { asset in asset.metrics.map { MetricsBaselineEntry(id: asset.logicalTrackID, label: asset.trackName.value ?? asset.logicalTrackID, metrics: $0) } }
            if let mixMetrics = mixAsset?.metrics { baseline.append(MetricsBaselineEntry(id: "mix", label: "Mix (Stereo Out)", metrics: mixMetrics)) }
            metricsBaseline = baseline
            planChecks = checks; verificationDiff = diff
            postApplyVerifiedAt = Date(); postApplyExecutedLive = executedLive
            raw = fresh; normalized = freshNormalized
            if let store {
                _ = try? await store.save(fresh, folder: "raw", name: "accessibility_snapshot.json")
                _ = try? await store.save(freshNormalized, folder: "normalized", name: "normalized_project.json")
                let audioDir = await store.folderURL("audio")
                audioAssets = await analyzedAssets(raw: fresh, normalized: freshNormalized, audioDir: audioDir)
                await saveAudioManifest()
            }
            let matched = checks.filter { $0.outcome == .matched }.count
            let mismatched = checks.filter { $0.outcome == .mismatched }.count
            verificationStatus = "Fresh scan: \(plural(diff.changed.count, "track")) changed, \(diff.unchanged.count) unchanged. Plan targets: \(matched)/\(checks.count) matched" + (mismatched > 0 ? ", \(mismatched) MISMATCHED" : "") + ". The post-apply snapshot is now the current analysis — re-export the tracks and re-bounce the mix for before/after metrics, then generate the post-apply AI package."
            log.append("Post-apply verification: \(matched)/\(checks.count) plan targets matched; \(diff.changed.count) tracks changed.")
            if !aiPackage.isEmpty { generateAIPackage() }
        } catch {
            verificationStatus = "The verification scan failed: \(error.localizedDescription)"
            log.append("Verification scan failed: \(error.localizedDescription)")
        }
    }
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
            case .blockedByNormalize(let value, let detail):
                exportPhase = .failed("normalize")
                audioStatus = "Export stopped: Logic's export dialog has Normalize set to ‘\(value)’, which would rewrite the exported levels, and the app could not switch it to Off (\(detail)) Set Normalize to Off in File ▸ Export ▸ All Tracks as Audio Files… once, then export again."
                log.append("Logic export blocked: Normalize is ‘\(value)’ and switching it to Off failed (\(detail)) — the dialog was cancelled and nothing was exported.")
            case .exported(let item, let format, let settings):
                exportSettings = ExportSettingsFacts(settings: settings)
                if let from = settings.normalizeSwitchedFrom { log.append("Logic's export dialog had Normalize set to ‘\(from)’ — the app switched it to Off before exporting, so the WAVs keep the project's real levels.") }
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
            case .blockedByNormalize(let value, let detail):
                mixPhase = .failed("normalize")
                mixStatus = "Bounce stopped: Logic's bounce dialog has Normalize set to ‘\(value)’, which would rewrite the mix level, and the app could not switch it to Off (\(detail)) Set Normalize to Off in the bounce dialog once, then bounce again."
                log.append("Logic bounce blocked: Normalize is ‘\(value)’ and switching it to Off failed (\(detail)) — the dialog was cancelled and nothing was bounced.")
            case .blockedByCycle(let detail):
                mixPhase = .failed("cycle")
                mixStatus = "Bounce stopped: Logic's Cycle mode is on, so the bounce would cover only the cycle section instead of the whole project, and the app could not switch it off (\(detail)) Turn Cycle off in Logic (press C or click the cycle button in the control bar), then bounce again."
                log.append("Logic bounce blocked: Cycle mode is on and switching it off failed (\(detail)) — the bounce was cancelled and nothing was bounced.")
            case .blockedByFormat(let selected, let detail):
                mixPhase = .failed("format")
                let checked = selected.filter(\.enabled).map(\.name)
                mixStatus = "Bounce stopped: the bounce dialog's format table has no uncompressed PCM format checked (\(checked.isEmpty ? "nothing is checked" : "checked: \(checked.joined(separator: ", "))")), and the app could not check it itself (\(detail)) A lossy file is not level evidence and would not be detected as the mix. Check PCM (Uncompressed) in the bounce dialog once, then bounce again."
                log.append("Logic bounce blocked: format table read as \(selected.isEmpty ? "unreadable" : selected.caption) — no uncompressed PCM format is checked and checking it failed (\(detail)); the dialog was cancelled and nothing was bounced.")
            case .navigationFailed(let step, let detail):
                mixPhase = .failed(step)
                mixStatus = "Logic's bounce dialog could not be automated at ‘\(step)’: \(detail) You can finish the dialog manually into the mix folder — the file will still be detected."
                log.append("Logic bounce dialog automation failed at \(step): \(detail)")
                await pollForMixBounce(mixDir: mixDir, settings: nil) // still detect if the user completes it manually
            case .bounced(let item, let settings):
                if let from = settings.cycleSwitchedFrom { log.append("Logic's Cycle mode was ‘\(from)’ — the app switched it off (and verified) before opening the bounce dialog, so the whole project is bounced rather than the cycle section. Press C in Logic to turn Cycle back on if you need it.") }
                if settings.cycle == nil { log.append("Logic exposed no readable Cycle control before the bounce — whether a cycle range constrains this bounce is unverified; the finished file's duration is checked against the exported tracks instead.") }
                if let from = settings.normalizeSwitchedFrom { log.append("Logic's bounce dialog had Normalize set to ‘\(from)’ — the app switched it to Off before bouncing, so the file keeps the mix's real level.") }
                if let row = settings.pcmFormatCheckedByApp { log.append("Logic's bounce dialog had no uncompressed PCM format checked — the app checked ‘\(row)’ before bouncing, so a real PCM mix file is written.") }
                if let rows = settings.formatsUncheckedByApp { log.append("Logic's bounce dialog also had \(rows.joined(separator: ", ")) checked — the app unchecked \(rows.count == 1 ? "it" : "them") before bouncing, so exactly one PCM mix file is written.") }
                let leftover = LogicExportAutomator.nonPCMChecked(settings.formats)
                if !leftover.isEmpty { log.append("Note: \(leftover.joined(separator: ", ")) stayed checked in the bounce dialog (unchecking did not stick) — Logic writes that extra file too; the mix detection ignores it.") }
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
