import Foundation

// MARK: - Pure helpers (unit-tested, no I/O)

/// Extraction of fenced code blocks from a model reply. The machine-readable deliverable of the API delivery is the
/// LAST fenced block whose info string is `json`; everything else in the reply is prose for the user. Pure text
/// functions — no network, no state.
enum FencedCodeBlocks {
    /// Every fenced code block tagged `json` (case-insensitive), in document order. A fence opens on a line starting
    /// with three backticks plus the info string and closes on a line of backticks alone; blocks with any other info
    /// string are skipped, and their content can never open a json block from inside.
    static func jsonBlocks(in text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [String] = []
        var insideJSON = false
        var insideOther = false
        var current: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isFenceLine = line.hasPrefix("```")
            let isClosingFence = isFenceLine && line.allSatisfy { $0 == "`" }
            if insideJSON {
                if isClosingFence { blocks.append(current.joined(separator: "\n")); insideJSON = false; current = [] }
                else { current.append(String(rawLine)) }
            } else if insideOther {
                if isClosingFence { insideOther = false }
            } else if isFenceLine {
                let info = line.drop(while: { $0 == "`" }).trimmingCharacters(in: .whitespaces).lowercased()
                if info == "json" { insideJSON = true } else { insideOther = true }
            }
        }
        return blocks
    }

    /// The last `json` block, trimmed; nil when the text has none (or only an empty one) — the caller reports the
    /// named "the model returned no MixGraph" failure instead of guessing.
    static func lastJSONBlock(in text: String) -> String? {
        guard let block = jsonBlocks(in: text).last?.trimmingCharacters(in: .whitespacesAndNewlines), !block.isEmpty else { return nil }
        return block
    }
}

/// The polling discipline, as named constants and pure math: intervals start at 5 s and back off to a 30 s ceiling,
/// and the whole poll has one named total ceiling after which it stops — resuming is always the user's explicit click,
/// never a silent endless retry.
enum AssistantPolling {
    static let initialInterval: TimeInterval = 5
    static let maximumInterval: TimeInterval = 30
    static let totalTimeout: TimeInterval = 15 * 60
    static func nextInterval(after interval: TimeInterval) -> TimeInterval { min(interval * 1.5, maximumInterval) }
}

/// The saved conversation: which package went out, what the model answered, which thread carried it — everything
/// needed to reproduce the analysis later. The API key is deliberately not part of this record.
struct AssistantDialogRecord: Codable, Sendable {
    var threadID: String
    var model: String
    var reasoning: String?
    var savedAt: Date
    var messages: [CapyMessage]
}

// MARK: - Orchestration (AppModel)

@MainActor extension AppModel {

    // MARK: Settings actions

    func saveCapyKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { capyKeyStatus = "Enter a key first."; return }
        if let failure = CapyKeyStore().save(trimmed) { capyKeyStatus = failure }
        else { capyKeyPresent = true; capyKeyStatus = "Key saved to the macOS Keychain. It never leaves the Keychain except as the Authorization header of Capy API requests." }
    }

    func removeCapyKey() {
        if let failure = CapyKeyStore().remove() { capyKeyStatus = failure }
        else { capyKeyPresent = false; capyKeyStatus = "Key removed from the Keychain." }
    }

    /// One cheap authenticated GET (list one thread of the configured project) with a named verdict: it proves the
    /// key and the project id together, and the error cases distinguish a rejected key from a wrong project id.
    func verifyCapyKey() {
        guard let key = CapyKeyStore().load(), !key.isEmpty else { capyKeyStatus = "No key stored — save one first."; return }
        let projectID = capyProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty else { capyKeyStatus = "Enter the Capy project id first (copy it from the project page URL at capy.ai)."; return }
        capyKeyStatus = "Verifying the key against \(CapyAPI.baseURL.host ?? "the Capy API")\u{2026}"
        Task {
            do { try await CapyAPIClient(apiKey: key).checkAccess(projectID: projectID); capyKeyStatus = "Key accepted and the project is reachable." }
            catch { capyKeyStatus = error.localizedDescription }
        }
    }

    // MARK: Assistant conversation

    var assistantConfigured: Bool { capyKeyPresent && !capyProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The last thing the model said — stages 1–4 first, later the confirmation reply — rendered on the Assistant screen.
    var assistantLatestReply: String { assistantTranscript.last(where: { $0.source == "assistant" && !$0.text.isEmpty })?.text ?? "" }

    func resetAssistantState() {
        assistantWork?.cancel(); assistantWork = nil
        assistantBusy = false; assistantStatus = ""; assistantThreadID = nil; assistantThreadStatus = ""
        assistantTranscript = []; assistantAwaitingConfirmation = false; assistantConfirmationText = ""
        assistantConfirmationSent = false; assistantGraphReady = false; assistantGraphIssues = []
        assistantFailure = nil; assistantCanResumePolling = false
    }

    /// Sends the API-delivery package into a fresh Capy thread and polls until the model's stage 1–4 reply settles.
    /// Requires the key (Keychain) and project id; without them the app stays fully usable through the Render
    /// screen's manual paste.
    func assistantAnalyze() {
        guard !assistantBusy else { return }
        guard let package = packageText(delivery: .apiDelivery) else { assistantStatus = "Run a full analysis first."; return }
        guard let key = CapyKeyStore().load(), !key.isEmpty else { assistantStatus = "No Capy API key. Add one in Settings → AI — or paste a MixGraph by hand on the Render screen."; return }
        let projectID = capyProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty else { assistantStatus = "No Capy project id. Set it in Settings → AI."; return }
        resetAssistantState()
        assistantBusy = true
        assistantStatus = "Creating a Capy thread and sending the analysis package\u{2026}"
        let model = CapyModelSelection(modelId: capyModelID, reasoningMode: capyReasoning == "default" ? nil : capyReasoning)
        assistantWork = Task {
            if let store { _ = try? await store.saveText(package, folder: "prompts", name: "assistant_package.md") }
            let client = CapyAPIClient(apiKey: key)
            do {
                let thread = try await client.createThread(requestID: UUID().uuidString, projectID: projectID, message: package, model: model)
                assistantThreadID = thread.id
                log.append("Capy thread created (\(thread.id), model \(model.modelId)\(model.reasoningMode.map { ", reasoning \($0)" } ?? "")); package sent (API delivery).")
                try await runAssistantTurn(client: client)
            } catch { assistantHandle(error) }
            assistantBusy = false
        }
    }

    /// Sends the user's stage-5 confirmation (their own text) and polls for the final MixGraph reply.
    func assistantConfirm() {
        let text = assistantConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { assistantStatus = "Write an answer to the model's questions, or press \u{201C}Accept All Defaults\u{201D}."; return }
        sendAssistantReply(text)
    }

    /// The one-click stage-5 confirmation for a user with nothing to add.
    func assistantAcceptDefaults() {
        sendAssistantReply("Proceed with your own proposed defaults for every question. Deliver the final MixGraph now, as exactly one fenced json code block.")
    }

    /// One fixed follow-up naming the validation errors, sent when the model's reply carried no valid MixGraph.
    func assistantAskFix() {
        let issues = assistantGraphIssues.isEmpty ? ["The reply contained no valid MixGraph JSON."] : assistantGraphIssues
        sendAssistantReply("Your last reply did not contain a valid MixGraph. Reply again with EXACTLY ONE fenced json code block containing the corrected MixGraph (schemaVersion \"1.0\") — no other fenced json blocks. Validation errors:\n" + issues.map { "- \($0)" }.joined(separator: "\n"))
    }

    /// Resumes polling after the named timeout — explicitly, on the user's click, never on its own.
    func assistantResumePolling() {
        guard !assistantBusy, assistantThreadID != nil else { return }
        guard let key = CapyKeyStore().load(), !key.isEmpty else { assistantStatus = "No Capy API key. Add one in Settings → AI."; return }
        assistantFailure = nil; assistantCanResumePolling = false
        assistantBusy = true
        assistantWork = Task {
            do { try await runAssistantTurn(client: CapyAPIClient(apiKey: key)) } catch { assistantHandle(error) }
            assistantBusy = false
        }
    }

    private func sendAssistantReply(_ text: String) {
        guard !assistantBusy, let id = assistantThreadID else { return }
        guard let key = CapyKeyStore().load(), !key.isEmpty else { assistantStatus = "No Capy API key. Add one in Settings → AI."; return }
        assistantAwaitingConfirmation = false
        assistantConfirmationSent = true
        assistantFailure = nil; assistantGraphIssues = []
        assistantBusy = true
        assistantStatus = "Sending the reply\u{2026}"
        assistantWork = Task {
            let client = CapyAPIClient(apiKey: key)
            do {
                try await client.sendMessage(threadID: id, text: text)
                try await runAssistantTurn(client: client)
            } catch { assistantHandle(error) }
            assistantBusy = false
        }
    }

    /// One turn of the conversation: poll the thread to a settled status (bounded intervals, named total ceiling),
    /// refresh and persist the transcript, then either present stages 1–4 for confirmation or extract the MixGraph.
    private func runAssistantTurn(client: CapyAPIClient) async throws {
        guard let id = assistantThreadID else { return }
        var interval = AssistantPolling.initialInterval
        let deadline = Date().addingTimeInterval(AssistantPolling.totalTimeout)
        while true {
            let thread = try await client.thread(id: id)
            assistantThreadStatus = thread.status
            if CapyThreadStatus.settled.contains(thread.status) { break }
            assistantStatus = "The model is working (thread status: \(thread.status))\u{2026}"
            guard Date() < deadline else { throw CapyAPIError.pollTimeout(minutes: Int(AssistantPolling.totalTimeout / 60)) }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            interval = AssistantPolling.nextInterval(after: interval)
        }
        assistantTranscript = try await client.fullTranscript(threadID: id)
        await persistAssistantDialog()
        if assistantThreadStatus == "error" { throw CapyAPIError.threadFailed }
        if assistantConfirmationSent {
            await assistantExtractGraph()
        } else {
            assistantAwaitingConfirmation = true
            assistantStatus = "Stages 1\u{2013}4 received. Answer the model's questions below, or accept its defaults."
        }
    }

    /// The last fenced `json` block of the transcript, decoded as a MixGraph and passed through the SAME dry
    /// validation as a manual paste on the Render screen. On success the graph lands in the Render screen's paste
    /// field with its verdicts — the user still presses Render themselves; there is no automatic render.
    private func assistantExtractGraph() async {
        let joined = assistantTranscript.filter { $0.source == "assistant" }.map(\.text).joined(separator: "\n\n")
        guard let block = FencedCodeBlocks.lastJSONBlock(in: joined) else {
            assistantGraphIssues = ["The reply contains no fenced json code block."]
            assistantFailure = "The model did not return a MixGraph: its reply has no fenced json block. Use \u{201C}Ask the Model to Fix It\u{201D} to request a corrected reply."
            return
        }
        let graph: MixGraph
        do { graph = try JSONDecoder().decode(MixGraph.self, from: Data(block.utf8)) }
        catch {
            assistantGraphIssues = ["The fenced json block does not decode as a MixGraph: \(error.localizedDescription)"]
            assistantFailure = "The model did not return a valid MixGraph: the json block does not decode against the schema. Use \u{201C}Ask the Model to Fix It\u{201D} to request a corrected reply."
            return
        }
        ensurePluginInventory()
        let issues = MixGraphDryCheck.validate(graph, audioFiles: await audioFolderWAVs(), installedPlugins: availablePlugins)
        guard issues.isEmpty else {
            assistantGraphIssues = issues
            assistantFailure = "The model returned a MixGraph, but it failed the dry validation (\(issues.count) issue\(issues.count == 1 ? "" : "s") listed below). Use \u{201C}Ask the Model to Fix It\u{201D} to send the errors back."
            return
        }
        if let store { _ = try? await store.saveText(block, folder: "responses", name: "assistant_mixgraph.json") }
        renderGraphText = block
        renderIssues = []
        renderGraphValid = true
        renderStatus = "MixGraph received from the assistant and validated: \(graph.tracks.count) track\(graph.tracks.count == 1 ? "" : "s"), \(graph.buses.count) bus\(graph.buses.count == 1 ? "" : "es"). Press Render when ready."
        assistantGraphReady = true
        assistantStatus = "MixGraph received and validated — it is loaded on the Render screen. Rendering starts only when you press Render there."
        log.append("Assistant delivered a valid MixGraph (\(graph.tracks.count) tracks); loaded on the Render screen.")
    }

    private func assistantHandle(_ error: Error) {
        if error is CancellationError { assistantStatus = "Assistant conversation cancelled."; return }
        let message = error.localizedDescription
        assistantFailure = message
        assistantStatus = ""
        if case CapyAPIError.pollTimeout = error { assistantCanResumePolling = true }
        log.append("Assistant failure: \(message)")
    }

    /// Persists the whole dialog next to the analysis (Data/current/responses) — reproducibility: which package went
    /// out, what the model answered, which graph was rendered. Never the key.
    private func persistAssistantDialog() async {
        guard let store, let id = assistantThreadID else { return }
        let record = AssistantDialogRecord(threadID: id, model: capyModelID, reasoning: capyReasoning == "default" ? nil : capyReasoning, savedAt: Date(), messages: assistantTranscript)
        _ = try? await store.save(record, folder: "responses", name: "assistant_thread.json")
    }

    /// File names of the real audio files in current/audio — the render sources every MixGraph is validated against.
    func audioFolderWAVs() async -> [String] {
        guard let store else { return [] }
        let dir = await store.folderURL("audio")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { ["wav", "aif", "aiff", "caf"].contains(($0 as NSString).pathExtension.lowercased()) }
    }
}
