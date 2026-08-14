import SwiftUI

@main struct AIMixAssistantApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { RootView().environmentObject(model).frame(minWidth: 960, minHeight: 680) } }
}

// MARK: - Workflow model

/// Only stages with a working backend are exposed. Execution / verification are not shown until a live Logic adapter exists.
enum WorkflowStage: Int, CaseIterable, Identifiable {
    case connection, analysis, audio, aiPackage, review
    var id: Int { rawValue }
    var number: String { String(format: "%02d", rawValue + 1) }
    var title: String { switch self { case .connection: "Connection"; case .analysis: "Analysis"; case .audio: "Audio"; case .aiPackage: "AI Package"; case .review: "Review" } }
    var symbol: String { switch self { case .connection: "link"; case .analysis: "waveform.path.ecg"; case .audio: "waveform"; case .aiPackage: "doc.text"; case .review: "checklist" } }
}

// MARK: - Indicators

enum IndicatorState { case ok, warn, error, idle
    var color: Color { switch self { case .ok: .green; case .warn: .orange; case .error: .red; case .idle: .secondary } }
}
struct StatusDot: View {
    let state: IndicatorState
    var body: some View { Circle().fill(state.color).frame(width: 10, height: 10).overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5)).shadow(color: state.color.opacity(state == .idle ? 0 : 0.5), radius: 4) }
}
struct StatusRow: View {
    let title: String; let detail: String; let state: IndicatorState
    init(_ title: String, _ detail: String, _ state: IndicatorState) { self.title = title; self.detail = detail; self.state = state }
    var body: some View {
        HStack(spacing: 10) { StatusDot(state: state); Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
    }
}
struct CheckRow: View {
    let title: String; let detail: String
    var body: some View { HStack(spacing: 10) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13)); Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) } }
}

// MARK: - Reusable containers

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
struct Screen<Content: View>: View {
    let title: String; let subtitle: String; @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(.largeTitle, design: .rounded).weight(.semibold)); Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                content
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The one visually-primary "next step" of a stage: an accent, large, right-aligned button with an arrow, set off by a divider from secondary actions. Disabled until the stage lets you proceed.
struct StageFooter: View {
    let title: String; let enabled: Bool; let action: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.top, 4)
            HStack {
                Spacer()
                Button(action: action) { HStack(spacing: 8) { Text(title).fontWeight(.semibold); Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)) }.padding(.horizontal, 6).padding(.vertical, 2) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.accentColor).disabled(!enabled)
            }.padding(.top, 12)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var deleteStage1 = false
    @State private var deleteStage2 = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Settings").font(.system(.title2, design: .rounded).weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Card {
                Text("Updates").font(.headline)
                Text("The app updates itself in place from this project's GitHub Releases: the new AI Mix Assistant.app replaces the current one inside the same folder, and Data/ with your analyses stays untouched. A folder still named after the old version (AI_Mix_<version>) is renamed to the new one; a folder you named yourself is never touched.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Check for Updates") { model.checkForUpdates(userInitiated: true) }.disabled(model.updateInProgress)
                    if let update = model.updateAvailable {
                        Button(model.updateInProgress ? "Updating\u{2026}" : "Install \(update.tag)") { model.installUpdate() }.buttonStyle(.borderedProminent).disabled(model.updateInProgress || model.updateBlockedByWork)
                    }
                }
                if !model.updateStatus.isEmpty { Text(model.updateStatus).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Card {
                Text("Project Data").font(.headline)
                Text("Remove the temporary analysis data, generated packages, logs and exported audio that AI Mix Assistant created in its working directory. Your Logic project and any files outside AI Mix Assistant are not affected.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Clear Temporary Project Files") { confirmingClear = true }
                    if !model.clearStatus.isEmpty { Label(model.clearStatus, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Danger Zone").font(.system(size: 11, weight: .bold)).tracking(0.9).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Completely removes the application and all data stored inside its own directory.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Delete AI Mix Assistant", role: .destructive) { deleteStage1 = true }
                        if !model.deleteStatus.isEmpty { Text(model.deleteStatus).font(.callout).foregroundStyle(.red) }
                    }
                    Text("This action cannot be undone.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.35), lineWidth: 0.6))
            }
            Spacer()
        }
        .padding(24).frame(width: 500, height: 640)
        .confirmationDialog("Clear Temporary Project Files?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) { model.clearProjectData() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This will permanently remove temporary analysis data, generated packages, logs and exported audio from AI Mix Assistant. Your Logic project and files outside AI Mix Assistant will not be affected.") }
        .alert("Delete AI Mix Assistant?", isPresented: $deleteStage1) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") { DispatchQueue.main.async { deleteStage2 = true } }
        } message: { Text("AI Mix Assistant and all data stored inside its application directory will be permanently deleted:\n\n• Application\n• Project data\n• Audio files\n• AI packages\n• Logs\n• Temporary files\n\nThis action cannot be undone.") }
        .alert("Are you absolutely sure?", isPresented: $deleteStage2) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) { model.deleteApplication() }
        } message: { Text("The entire AI Mix Assistant directory will be permanently deleted, along with the app's own preferences and window-state files macOS keeps in ~/Library. Nothing else will be searched for or deleted.\n\nDirectory to delete:\n\(model.uninstallTargetPath)\n\nThe only remaining trace is the Accessibility permission entry, which macOS owns — remove it in System Settings → Privacy & Security → Accessibility if you wish.\n\nThis is permanent and cannot be undone.") }
    }
}

// MARK: - Root & navigation

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    var body: some View {
        NavigationSplitView { Sidebar(showSettings: $showSettings) } detail: {
            switch model.stage {
            case .connection: ConnectionScreen()
            case .analysis: AnalysisScreen()
            case .audio: AudioScreen()
            case .aiPackage: PackageScreen()
            case .review: ReviewScreen()
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("AI Mix Assistant").font(.system(.headline, design: .rounded)).padding(.bottom, 2)
            Text("Semi-automatic Logic Pro mixing").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            ForEach(WorkflowStage.allCases) { stage in StepRow(stage: stage) }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                StatusRow("Accessibility", model.connection.accessibilityTrusted ? "Granted" : "Required", model.connection.accessibilityTrusted ? .ok : .warn)
                StatusRow("Logic Pro", model.connection.found ? "Connected" : "Not found", model.connection.found ? .ok : .error)
                StatusRow("Project", model.connection.projectOpen == true ? (model.connection.projectName ?? "Open") : (model.connection.projectOpen == false ? "Not open" : "Not checked"), model.connection.projectOpen == true ? .ok : (model.connection.projectOpen == false ? .warn : .idle))
            }.font(.caption)
            if let update = model.updateAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Button { model.installUpdate() } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)); Text(model.updateInProgress ? "Updating\u{2026}" : "Update to \(update.tag)").font(.system(size: 12, weight: .semibold)); Spacer() }.contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent).controlSize(.small).disabled(model.updateInProgress || model.updateBlockedByWork)
                    if !model.updateStatus.isEmpty { Text(model.updateStatus).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(.top, 8)
            }
            Divider().padding(.vertical, 8)
            HStack {
                Button { showSettings = true } label: {
                    HStack(spacing: 8) { Image(systemName: "gearshape").font(.system(size: 13)); Text("Settings").font(.system(size: 13)); Spacer() }
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Text(Self.versionLabel).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14).frame(minWidth: 236)
    }
    static let versionLabel = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v\($0)" } ?? "dev"
    struct StepRow: View {
        let stage: WorkflowStage
        @EnvironmentObject var model: AppModel
        private var isCurrent: Bool { model.stage == stage }
        private var available: Bool { model.isAvailable(stage) }
        private var done: Bool { model.isComplete(stage) }
        var body: some View {
            Button { model.go(to: stage) } label: {
                HStack(spacing: 10) {
                    Text(stage.number).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(isCurrent ? Color.accentColor : .secondary).frame(width: 20, alignment: .leading)
                    Image(systemName: stage.symbol).font(.system(size: 12)).frame(width: 16)
                    Text(stage.title).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    Spacer()
                    if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green) }
                    else if !available { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!available).opacity(available ? 1 : 0.45)
        }
    }
}

// MARK: - Screens

/// Shown whenever the closed-shell storage could not initialize. For App Translocation it offers the one-click
/// repair (dequarantine the app's own folder, relaunch from the real location); other causes show the diagnostic only.
struct StorageRepairCard: View {
    @EnvironmentObject var model: AppModel
    var showMessage = true
    var body: some View {
        Card {
            Label("Data storage unavailable", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
            if showMessage { Text(model.storageUnavailableMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.isTranslocated {
                HStack(spacing: 10) {
                    Button("Fix and Relaunch", action: model.fixTranslocationAndRelaunch).buttonStyle(.borderedProminent)
                    if !model.translocationStatus.isEmpty { Text(model.translocationStatus).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Text("Removes macOS's quarantine attribute from the AI Mix Assistant folder only, then restarts the app from where you placed it. Nothing else is modified.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConnectionScreen: View {
    @EnvironmentObject var model: AppModel
    private var ready: Bool { model.isComplete(.connection) }
    /// The three prerequisites in their real order: Accessibility is granted first, then Logic Pro runs, then a project is open
    /// inside it. The project row only claims something once the check could actually run (Logic found + Accessibility granted).
    private var project: (detail: String, state: IndicatorState) {
        guard model.connection.accessibilityTrusted else { return ("Waiting for Accessibility", .idle) }
        guard model.connection.found else { return ("Waiting for Logic Pro", .idle) }
        guard model.connection.projectOpen == true else { return ("No project open", .warn) }
        return (model.connection.projectName ?? "Open", .ok)
    }
    var body: some View {
        Screen(title: "Connection", subtitle: "Grant read-only access, launch Logic Pro and open your project.") {
            if !model.storageReady { StorageRepairCard() }
            Card {
                StatusRow("Accessibility", model.connection.accessibilityTrusted ? "Granted" : "Permission required", model.connection.accessibilityTrusted ? .ok : .warn)
                Divider()
                StatusRow("Logic Pro", model.connection.found ? (model.connection.localizedName ?? "Connected") : "Not found", model.connection.found ? .ok : .error)
                Divider()
                StatusRow("Project", project.detail, project.state)
            }
            HStack(spacing: 10) {
                Button("Refresh", action: model.refreshConnection)
                if !model.connection.accessibilityTrusted { Button("Open Accessibility Settings", action: model.openAccessibilitySettings) }
                if !model.connection.found { Button("Launch Logic Pro", action: model.launchLogic) }
            }
            if ready { Text("System ready. Logic Pro is analyzed read-only.").font(.callout).foregroundStyle(.secondary) }
            else { Text("Status refreshes automatically — grant Accessibility, launch Logic Pro and open a project; this screen updates on its own.").font(.caption).foregroundStyle(.secondary) }
            StageFooter(title: "Continue to Analysis", enabled: ready) { model.go(to: .analysis) }
        }
    }
}

struct AnalysisScreen: View {
    @EnvironmentObject var model: AppModel
    private var scanning: Bool { model.analyzerState == .scanning }
    var body: some View {
        Screen(title: "Analysis", subtitle: "Read-only capture of the Logic project. Logic Pro is never modified.") {
            Card {
                HStack { Label("READ-ONLY", systemImage: "eye").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.green.opacity(0.15))).foregroundStyle(.green); Spacer() }
                if scanning { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.scanProgress > 0 ? "Analyzing project (read-only)… \(model.scanProgress) elements inspected" : "Analyzing project (read-only)…").foregroundStyle(.secondary); Spacer(); Button("Cancel", action: model.cancelScan) } }
                else if let snapshot = model.normalized { checklist(snapshot) }
                else { Text("No analysis yet. Start a read-only scan of the current Logic project.").foregroundStyle(.secondary) }
            }
            Button(model.normalized == nil ? "Start Analysis" : "Re-run Analysis", action: model.scan).buttonStyle(.borderedProminent).disabled(!model.isAvailable(.analysis) || scanning)
            if case .error(let message) = model.analyzerState {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                if !model.storageReady && model.isTranslocated { StorageRepairCard(showMessage: false) }
            }
            if let snapshot = model.normalized { diagnostics(snapshot) }
            StageFooter(title: "Continue to Audio", enabled: model.isAvailable(.audio)) { model.go(to: .audio) }
        }
    }
    @ViewBuilder private func checklist(_ s: NormalizedSnapshot) -> some View {
        let channels = s.tracks.compactMap(\.channel)
        let outputs = channels.map(\.output), inputs = channels.map(\.input)
        let sends = channels.reduce(0) { $0 + $1.sends.count }, unclassified = channels.reduce(0) { $0 + $1.routingButtons.count }
        let graph = SignalFlowGraph.build(tracks: s.tracks)
        VStack(alignment: .leading, spacing: 8) {
            CheckRow(title: "Logic connection", detail: model.connection.localizedName ?? "Logic Pro")
            CheckRow(title: "Project discovery", detail: projectSummary(s))
            CheckRow(title: "Track discovery", detail: "\(s.linking.logicalTracks) logical tracks")
            CheckRow(title: "Channel discovery", detail: "\(s.linking.channelCandidates) mixer channels")
            CheckRow(title: "Routing", detail: "\(routingSummary(outputs, noun: "output")), \(routingSummary(inputs, noun: "input")), \(plural(sends, "send"))" + (unclassified == 0 ? "" : " · \(plural(unclassified, "button")) unclassified") + " · \(plural(graph.edges.count, "bus link")) resolved" + (graph.unresolvedBuses.isEmpty ? "" : " · \(graph.unresolvedBuses.count) \(graph.unresolvedBuses.count == 1 ? "bus" : "buses") unresolved"))
            CheckRow(title: "Snapshot generation", detail: "saved to Data/current")
        }
    }
    /// "5 outputs (4 Stereo Out · 1 Bus)": known routing facts counted per destination kind, so a stereo-bus output and a
    /// send-bus output are not one anonymous number. A destination whose caption the kind grammar does not know counts as "other".
    private func routingSummary(_ facts: [Fact<String>], noun: String) -> String {
        let kinds = facts.compactMap { $0.state == .known ? $0.value : nil }.map { RoutingDestinationKind.classify($0)?.label ?? "other" }
        guard !kinds.isEmpty else { return plural(0, noun) }
        let counts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
        let breakdown = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
        return "\(plural(kinds.count, noun)) (\(breakdown))"
    }
    private func projectSummary(_ s: NormalizedSnapshot) -> String {
        var parts: [String] = []
        if let name = s.project.name.value { parts.append(name) }
        if let t = s.project.tempo.value { parts.append("\(Int(t)) BPM") }
        if let k = s.project.keySignature.value { parts.append(k) }
        if let ts = s.project.timeSignature.value { parts.append(ts) }
        return parts.isEmpty ? "captured (Logic exposed no project metadata)" : parts.joined(separator: " · ")
    }
    @ViewBuilder private func diagnostics(_ s: NormalizedSnapshot) -> some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linking: \(s.linking.confirmedLinks) confirmed, \(s.linking.unresolvedHeaders) header-only, \(s.linking.unresolvedChannels) channel-only, \(s.linking.ambiguous) ambiguous").font(.caption).foregroundStyle(.secondary)
                Text("AX windows: \(s.diagnostics.windowsFound) · candidates: \(s.diagnostics.candidatesFound)").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Open Data Folder", action: model.revealData); Spacer() }
                DisclosureGroup("Normalized snapshot (JSON)") { ScrollView { Text(json(s)).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260) }
                if !model.log.isEmpty { DisclosureGroup("Session log") { VStack(alignment: .leading, spacing: 2) { ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) } }
            }.padding(.top, 4)
        }.font(.callout)
    }
    private func json<T: Encodable>(_ value: T) -> String { String(data: (try? JSONEncoder.pretty.encode(value)) ?? Data(), encoding: .utf8) ?? "" }
}

struct AudioScreen: View {
    @EnvironmentObject var model: AppModel
    private var exported: Int { model.audioAssets.filter { $0.status == .exported }.count }
    private var requires: Int { model.audioAssets.filter { $0.status == .requiresUserExport }.count }
    private var failed: Int { model.audioAssets.filter { $0.status == .failed }.count }
    var body: some View {
        Screen(title: "Audio", subtitle: "One WAV per Logic track. Regions are preserved as provenance, never split.") {
            Card {
                HStack(spacing: 10) { StatusDot(state: exportIndicator.0); Text(exportIndicator.1).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(exportIndicator.0.color); Spacer() }
                HStack(spacing: 28) {
                    metric("Logic tracks", "\(model.normalized?.linking.logicalTracks ?? 0)")
                    metric("Audio tracks", "\(model.audioAssets.count)")
                    metric("Exported", "\(exported)")
                    metric("Requires export", "\(requires)")
                    if failed > 0 { metric("Failed", "\(failed)") }
                }
                if !model.audioStatus.isEmpty { Text(model.audioStatus).font(.callout).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                Button("Export Tracks from Logic", action: model.requestExport).buttonStyle(.borderedProminent).disabled(model.normalized == nil || model.exportPhase == .exporting || model.mixPhase == .exporting)
                Button("Refresh Export Status", action: model.refreshExportStatus).disabled(model.audioAssets.isEmpty)
                Button("Open Audio Folder", action: model.openAudioFolder).disabled(model.audioAssets.isEmpty)
                Button("Copy Audio Manifest", action: model.copyAudioManifest).disabled(model.audioAssets.isEmpty)
            }
            if !model.audioAssets.isEmpty {
                Card { ForEach(model.audioAssets) { asset in
                    HStack(spacing: 10) {
                        StatusDot(state: audioState(asset.status))
                        Text(asset.trackName.value ?? asset.audioID).font(.system(size: 13, weight: .medium))
                        Text("\(asset.logicalTrackID) · \(asset.regions.count) regions").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(audioLabel(asset.status)).font(.caption.weight(.semibold)).foregroundStyle(audioState(asset.status).color)
                    }
                    if asset.id != model.audioAssets.last?.id { Divider() }
                } }
            }
            Text("Export Tracks from Logic launches Logic's own File \u{25B8} Export \u{25B8} All Tracks as Audio Files\u{2026} (one WAV per track, regions kept in place). AI Mix Assistant only triggers the export and never changes mix settings; it then detects the real WAVs and matches them to logicalTrackID.").font(.caption).foregroundStyle(.secondary)
            Card {
                HStack(spacing: 10) { StatusDot(state: mixIndicator.0); Text("Mix (Stereo Out)").font(.system(size: 13, weight: .semibold)); Spacer(); Text(mixIndicator.1).font(.caption.weight(.semibold)).foregroundStyle(mixIndicator.0.color) }
                if let mix = model.mixAsset {
                    Text(mixSummary(mix)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if !model.mixStatus.isEmpty { Text(model.mixStatus).font(.callout).foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    Button("Bounce Mix from Logic", action: model.requestMixBounce).disabled(model.normalized == nil || model.mixPhase == .exporting || model.exportPhase == .exporting)
                    Button("Open Mix Folder", action: model.openMixFolder).disabled(model.mixAsset == nil)
                }
                Text("Bounces the whole project through the master chain via Logic's own File \u{25B8} Bounce dialog into the app's mix folder, then measures the file. The sum is the reference for overall loudness and balance — per-track WAVs never contain it, so the AI Package stage opens only after both the track export and this bounce are done. Only two settings are ever corrected automatically: a level-rewriting Normalize is switched to Off, and the format table is set to PCM (Uncompressed) alone — compressed formats are unchecked; everything else is read as facts.").font(.caption).foregroundStyle(.secondary)
            }
            StageFooter(title: "Continue to AI Package", enabled: model.isAvailable(.aiPackage)) { model.go(to: .aiPackage) }
        }
        .onAppear { if model.normalized != nil && model.audioAssets.isEmpty { model.prepareAudioExport() } }
        .confirmationDialog("Export audio tracks from Logic Pro?", isPresented: $model.showExportConfirm, titleVisibility: .visible) {
            Button("Export") { model.confirmExport() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Logic Pro will export every track of the current project as one WAV file per track, using its own File \u{25B8} Export \u{25B8} All Tracks as Audio Files\u{2026} dialog. AI Mix Assistant drives that dialog into its audio folder automatically — don't touch Logic until the export starts. No mix settings are changed (only a level-rewriting Normalize is switched to Off), and your clipboard is restored afterwards.") }
        .confirmationDialog("Bounce the mix from Logic Pro?", isPresented: $model.showBounceConfirm, titleVisibility: .visible) {
            Button("Bounce") { model.confirmMixBounce() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Logic Pro will bounce the whole project (Stereo Out) using its own File \u{25B8} Bounce dialog. AI Mix Assistant drives that dialog into its mix folder automatically — don't touch Logic until the bounce starts. A realtime bounce plays the song once; only a level-rewriting Normalize is switched to Off and the format table is set to PCM (Uncompressed) alone, nothing else is changed, and your clipboard is restored afterwards.") }
    }
    private var exportIndicator: (IndicatorState, String) {
        switch model.exportPhase { case .idle: return (.idle, "Ready"); case .exporting: return (.warn, "Exporting\u{2026}"); case .done: return (.ok, "Exported"); case .failed(let step): return (.error, "Failed: \(step)") }
    }
    private var mixIndicator: (IndicatorState, String) {
        switch model.mixPhase { case .idle: return (.idle, model.mixAsset == nil ? "Not bounced" : "Bounced"); case .exporting: return (.warn, "Bouncing\u{2026}"); case .done: return (.ok, "Bounced"); case .failed(let step): return (.error, "Failed: \(step)") }
    }
    private func mixSummary(_ mix: MixBounceAsset) -> String {
        var parts = [mix.relativePath]
        if let lufs = mix.metrics?.integratedLoudnessLUFS.value { parts.append(String(format: "%.1f LUFS integrated", lufs)) }
        if let peak = mix.metrics?.truePeakDBTP.value { parts.append(String(format: "%.1f dBTP true peak", peak)) }
        return parts.joined(separator: " · ")
    }
    private func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 2) { Text(value).font(.system(.title2, design: .rounded).weight(.semibold)); Text(label).font(.caption).foregroundStyle(.secondary) } }
    private func audioState(_ s: AudioExtractionStatus) -> IndicatorState { switch s { case .exported: .ok; case .requiresUserExport: .warn; case .failed: .error; case .unavailable: .warn } }
    private func audioLabel(_ s: AudioExtractionStatus) -> String { switch s { case .exported: "Exported"; case .requiresUserExport: "Requires export"; case .failed: "Failed"; case .unavailable: "Unavailable" } }
}

struct PackageScreen: View {
    @EnvironmentObject var model: AppModel
    private var r: PackageReadiness { model.packageReadiness }
    private func flag(_ ok: Bool) -> IndicatorState { ok ? .ok : .warn }
    var body: some View {
        Screen(title: "AI Package", subtitle: "One package that bundles Logic facts, audio assets and provenance for any external LLM. No API is used — you send it yourself.") {
            Card {
                StatusRow("Logic facts", r.logicAnalysis ? "Ready" : "Run analysis first", flag(r.logicAnalysis))
                Divider()
                StatusRow("Tracks", r.trackDiscovery ? "\(model.normalized?.tracks.count ?? 0) logical tracks" : "None", flag(r.trackDiscovery))
                Divider()
                StatusRow("Audio assets", r.audioTotal == 0 ? "Not prepared" : "\(r.audioExported)/\(r.audioTotal) exported", r.audioTotal == 0 ? .idle : (r.audioExported == r.audioTotal ? .ok : .warn))
                Divider()
                StatusRow("Provenance", r.provenanceOK ? "Consistent" : "Errors", r.provenanceOK ? .ok : .error)
                Divider()
                StatusRow("AI Package", packageLabel, packageState)
            }
            HStack(spacing: 16) {
                Text("Plugins").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Label("Available: \(model.availablePlugins.count)", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
            }
            if !r.errors.isEmpty { Card { ForEach(r.errors, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) } } }
            if !r.missingAudio.isEmpty {
                Card {
                    Text("Audio analysis incomplete — \(plural(r.missingAudio.count, "WAV file")) missing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                    ForEach(r.missingAudio, id: \.logicalTrackID) { m in Text("\(m.logicalTrackID) — \(m.name)").font(.caption).foregroundStyle(.secondary) }
                    Text("Export the missing tracks in Logic, then Refresh Export Status on the Audio screen for a complete analysis.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Generate AI Package", action: model.generateAIPackage).buttonStyle(.borderedProminent).disabled(model.normalized == nil)
                if !model.aiPackage.isEmpty {
                    Button("Copy for AI", action: model.copyAIPackage)
                    Button("Save Package", action: model.savePackage)
                    Button("Open Package", action: model.openPackageFolder).disabled(model.packageFolderURL == nil)
                    Button("Open Audio Folder", action: model.openAudioFolder)
                }
            }
            if !model.aiPackageStatus.isEmpty { Text(model.aiPackageStatus).font(.callout).foregroundStyle(.secondary) }
            if !model.aiPackage.isEmpty {
                // This text is exactly what "Copy for AI" puts on the clipboard: the Markdown-only delivery, which states that no
                // JSON or WAV files came with it. The saved package's own AI_MIX_ANALYSIS.md is the full-package delivery, so the
                // preview must not claim to be that file.
                DisclosureGroup("Preview the text \u{201C}Copy for AI\u{201D} sends (Markdown only, no files)") { ScrollView { Text(model.aiPackage).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 320) }.font(.callout)
                if model.packageFolderURL != nil { Text("The saved package's own AI_MIX_ANALYSIS.md differs on purpose: it ships with the JSON files and WAVs, so it instructs the AI to read and listen to them. Open Package to read it.").font(.caption).foregroundStyle(.secondary) }
            }
            StageFooter(title: "Continue to Review", enabled: model.isAvailable(.review)) { model.go(to: .review) }
        }
        .onAppear { model.ensurePluginInventory() }
    }
    private var packageLabel: String { switch r.overall { case .ready: "Ready"; case .incomplete: "Incomplete"; case .error: "Integrity error"; case .notReady: "Not ready" } }
    private var packageState: IndicatorState { switch r.overall { case .ready: .ok; case .incomplete: .warn; case .error: .error; case .notReady: .idle } }
}

struct ReviewScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Screen(title: "Review", subtitle: "Paste the MixPlan JSON returned by your LLM. It is validated against the current snapshot — nothing is written to Logic Pro.") {
            Card {
                Text("MixPlan JSON").font(.headline)
                TextEditor(text: $model.planText).font(.system(.callout, design: .monospaced)).frame(minHeight: 150).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                HStack { Button("Validate", action: model.validatePlan).buttonStyle(.borderedProminent).disabled(model.planText.isEmpty || model.normalized == nil); Spacer(); if !model.planStatus.isEmpty { Text(model.planStatus).font(.callout).foregroundStyle(.secondary) } }
            }
            if !model.validated.isEmpty {
                Card {
                    Text("Proposed changes").font(.headline)
                    ForEach(model.validated) { item in
                        HStack(spacing: 10) {
                            StatusDot(state: item.status == .valid ? .ok : (item.status == .invalid ? .error : .warn))
                            VStack(alignment: .leading, spacing: 2) { Text("\(item.command.action.rawValue) · \(targetLabel(item.command.target))").font(.system(size: 13, weight: .medium)); Text(item.message).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(item.status.rawValue).font(.caption.weight(.semibold)).foregroundStyle(item.status == .valid ? .green : (item.status == .invalid ? .red : .orange))
                        }
                        if item.id != model.validated.last?.id { Divider() }
                    }
                }
            }
            Text("Live execution is not available in this build. AI Mix Assistant validates and previews the plan only; it never modifies Logic Pro.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func targetLabel(_ target: CommandTarget) -> String {
        var parts = [target.trackName ?? target.trackID ?? "—"]
        if let plugin = target.pluginName ?? target.pluginID { parts.append(plugin) }
        if let param = target.parameterName ?? target.parameterID { parts.append(param) }
        return parts.joined(separator: " / ")
    }
}
