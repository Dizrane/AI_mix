import Foundation

/// A named rejection of the pasted MixGraph text — the typed `Error` a `Result` requires, carrying the one sentence
/// the Render screen shows.
struct RenderGraphRejection: Error { let message: String }

/// The Render stage: a MixGraph JSON — pasted by hand (the keyless fallback that keeps the app fully usable without
/// any API) or delivered by the Assistant — is DRY-validated with named verdicts, and only an explicit press of
/// Render runs `MixEngine` offline over the exported WAVs in current/audio to produce `mix.wav` in current/render —
/// in a crash-isolated child process (`RenderChildProcess`), so a plugin bug can never take the app down with it.
/// Nothing renders automatically, and the result is measured, never presumed.
@MainActor extension AppModel {

    func resetRenderState() {
        renderGraphText = ""; renderIssues = []; renderGraphValid = false
        renderStatus = ""; renderRunning = false; renderedMixURL = nil; renderSummary = ""
    }

    /// Editing the paste field invalidates the previous verdicts: a changed graph is unvalidated until checked again.
    func renderGraphEdited() {
        renderGraphValid = false
        renderIssues = []
        if !renderStatus.isEmpty { renderStatus = "" }
    }

    /// The decoded graph behind the paste field. Tolerates a whole model reply pasted by hand by extracting its last
    /// fenced json block first.
    private func decodeRenderGraph() -> Result<MixGraph, RenderGraphRejection> {
        let text = renderGraphText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.init(message: "Paste a MixGraph JSON first.")) }
        let body = FencedCodeBlocks.lastJSONBlock(in: text) ?? text
        do { return .success(try JSONDecoder().decode(MixGraph.self, from: Data(body.utf8))) }
        catch { return .failure(.init(message: "Invalid MixGraph JSON: \(error.localizedDescription)")) }
    }

    /// The dry validation — the same checks the Assistant applies to a model reply, so both paths meet one standard.
    func validateRenderGraph() {
        switch decodeRenderGraph() {
        case .failure(let rejection):
            renderIssues = [rejection.message]; renderGraphValid = false; renderStatus = "MixGraph rejected."
        case .success(let graph):
            ensurePluginInventory()
            Task {
                let issues = MixGraphDryCheck.validate(graph, audioFiles: await audioFolderWAVs(), installedPlugins: availablePlugins)
                renderIssues = issues
                renderGraphValid = issues.isEmpty
                renderStatus = issues.isEmpty
                    ? "MixGraph is valid: \(graph.tracks.count) track\(graph.tracks.count == 1 ? "" : "s"), \(graph.buses.count) bus\(graph.buses.count == 1 ? "" : "es"). Ready to render."
                    : "MixGraph validation found \(issues.count) issue\(issues.count == 1 ? "" : "s") — fix them (or ask the assistant to) before rendering."
            }
        }
    }

    /// The single explicit render action. Runs the render in a short-lived CHILD process — the app's own binary with
    /// the `mix-render` subcommand — because plugins load in the rendering process and a plugin bug at load,
    /// processing, or Audio Unit teardown kills that process in ways Swift cannot catch (a real v0.2.37 crash:
    /// SIGABRT from a plugin freeing a pointer it never allocated, AFTER the render had completed — see
    /// `RenderChildProcess`). Success is the child's result file, not its clean exit: a child that crashed after
    /// writing it still succeeded, and the post-render crash is named in a note. On failure the named reason quotes
    /// how the child ended and its stderr; a hung child is killed after a generous timeout and fails by name. No
    /// silent retries, no bypass.
    func runRender() {
        guard !renderRunning else { return }
        guard renderGraphValid, case .success(let graph) = decodeRenderGraph() else { renderStatus = "Validate the MixGraph first."; return }
        guard let store else { renderStatus = storageUnavailableMessage; return }
        renderRunning = true; renderedMixURL = nil; renderSummary = ""
        renderStatus = "Rendering mix.wav offline in a child process\u{2026}"
        Task {
            let audioDir = await store.folderURL("audio")
            let renderDir = await store.folderURL("render")
            try? FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
            let outputURL = renderDir.appendingPathComponent("mix.wav")
            let graphURL = renderDir.appendingPathComponent("mixgraph.json")
            let resultURL = renderDir.appendingPathComponent("render_result.json")
            let outcome = await RenderChildProcess.render(graph: graph, audioFolder: audioDir, outputURL: outputURL, graphURL: graphURL, resultURL: resultURL)
            switch outcome {
            case .success(let success):
                var result = success.result
                if let note = success.postRenderNote { result.notes.append(note) }
                renderedMixURL = result.outputURL
                renderSummary = Self.renderSummaryLine(result)
                renderStatus = success.postRenderNote.map { "mix.wav rendered. Note: \($0)" } ?? "mix.wav rendered."
                let report = MixEngineCLI.report(for: result)
                _ = try? await store.saveText(report, folder: "render", name: "render_report.txt")
                log.append("Offline render finished: \(result.outputURL.lastPathComponent), \(result.renderedFrames) frames at \(Int(result.sampleRate)) Hz." + (success.postRenderNote.map { " Note: \($0)" } ?? ""))
            case .failure(let failure):
                renderStatus = "Render failed: \(failure.message)"
                log.append("Offline render failed: \(failure.message)")
            }
            renderRunning = false
        }
    }

    /// One line of measured facts about the written file — numbers from the same local analyzer, or an honest
    /// "unavailable" when the file could not be measured.
    static func renderSummaryLine(_ result: MixRenderResult) -> String {
        var parts = ["\(result.renderedFrames) frames at \(Int(result.sampleRate)) Hz"]
        if let metrics = result.mixMetrics {
            if let lufs = metrics.integratedLoudnessLUFS.value { parts.append(String(format: "%.1f LUFS integrated", lufs)) }
            if let peak = metrics.truePeakDBTP.value { parts.append(String(format: "%.1f dBTP true peak", peak)) }
            if let clipped = metrics.clippedSampleCount.value { parts.append("\(clipped) clipped samples") }
        } else { parts.append("metrics unavailable — the rendered file could not be analyzed") }
        return parts.joined(separator: " \u{00B7} ")
    }

    func openRenderFolder() { Task { await store?.reveal(folder: "render") } }
}
