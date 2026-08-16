import Foundation

/// The Render stage: a MixGraph JSON — pasted by hand (the keyless fallback that keeps the app fully usable without
/// any API) or delivered by the Assistant — is DRY-validated with named verdicts, and only an explicit press of
/// Render runs `MixEngine` offline over the exported WAVs in current/audio to produce `mix.wav` in current/render.
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
    private func decodeRenderGraph() -> Result<MixGraph, String> {
        let text = renderGraphText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("Paste a MixGraph JSON first.") }
        let body = FencedCodeBlocks.lastJSONBlock(in: text) ?? text
        do { return .success(try JSONDecoder().decode(MixGraph.self, from: Data(body.utf8))) }
        catch { return .failure("Invalid MixGraph JSON: \(error.localizedDescription)") }
    }

    /// The dry validation — the same checks the Assistant applies to a model reply, so both paths meet one standard.
    func validateRenderGraph() {
        switch decodeRenderGraph() {
        case .failure(let reason):
            renderIssues = [reason]; renderGraphValid = false; renderStatus = "MixGraph rejected."
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

    /// The single explicit render action. Runs `MixEngine` off the main thread, reports the named engine error on
    /// failure, and on success publishes the real measured facts of the written file plus its render report.
    func runRender() {
        guard !renderRunning else { return }
        guard renderGraphValid, case .success(let graph) = decodeRenderGraph() else { renderStatus = "Validate the MixGraph first."; return }
        guard let store else { renderStatus = storageUnavailableMessage; return }
        renderRunning = true; renderedMixURL = nil; renderSummary = ""
        renderStatus = "Rendering mix.wav offline\u{2026}"
        Task {
            let audioDir = await store.folderURL("audio")
            let renderDir = await store.folderURL("render")
            try? FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
            let outputURL = renderDir.appendingPathComponent("mix.wav")
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<MixRenderResult, Error> in
                do { return .success(try MixEngine().render(graph: graph, folder: audioDir, outputURL: outputURL)) }
                catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let result):
                renderedMixURL = result.outputURL
                renderSummary = Self.renderSummaryLine(result)
                renderStatus = "mix.wav rendered."
                let report = MixEngineCLI.report(for: result)
                _ = try? await store.saveText(report, folder: "render", name: "render_report.txt")
                log.append("Offline render finished: \(result.outputURL.lastPathComponent), \(result.renderedFrames) frames at \(Int(result.sampleRate)) Hz.")
            case .failure(let error):
                renderStatus = (error as? MixEngineError)?.errorDescription ?? error.localizedDescription
                log.append("Offline render failed: \(renderStatus)")
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
