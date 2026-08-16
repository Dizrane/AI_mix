import Testing
import Foundation
@testable import AIMixAssistant

// MARK: - Fake transport (no test in this file ever touches the network)

/// Scripted stand-in for URLSession behind `CapyHTTPTransport`: answers from a queue and records every request for
/// assertions. The lock makes the mutable state safe under the client's async calls (hence @unchecked Sendable).
private final class FakeTransport: CapyHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(status: Int, body: Data)] = []
    private var recorded: [URLRequest] = []
    func enqueue(status: Int, json: String) { lock.lock(); queue.append((status, Data(json.utf8))); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        guard !queue.isEmpty else { throw CapyAPIError.network("the fake transport queue is empty") }
        let next = queue.removeFirst()
        return (next.body, HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!)
    }
}

private func client(_ transport: FakeTransport, key: String = "test-key") -> CapyAPIClient {
    CapyAPIClient(apiKey: key, baseURL: URL(string: "https://api.capy.ai/api/v1")!, transport: transport)
}

// MARK: - CapyAPIClient

@Test func createThreadEncodesTheDocumentedRequest() async throws {
    let transport = FakeTransport()
    transport.enqueue(status: 200, json: #"{"id": "thread_1", "status": "active", "title": null}"#)
    let thread = try await client(transport).createThread(requestID: "req-1", projectID: "proj-1", message: "package text", model: .init(modelId: "anthropic/claude-opus-4-5", reasoningMode: "high"))
    #expect(thread.id == "thread_1"); #expect(thread.status == "active")
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.capy.ai/api/v1/threads")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["requestId"] as? String == "req-1")
    #expect(body["projectId"] as? String == "proj-1")
    #expect(body["message"] as? String == "package text")
    let model = try #require(body["model"] as? [String: Any])
    #expect(model["modelId"] as? String == "anthropic/claude-opus-4-5")
    #expect(model["reasoningMode"] as? String == "high")
}

@Test func threadStatusesDecodeAndSettledExcludesTheWorkingOnes() async throws {
    let transport = FakeTransport()
    transport.enqueue(status: 200, json: #"{"id": "t1", "status": "pending_user"}"#)
    let thread = try await client(transport).thread(id: "t1")
    #expect(thread.status == "pending_user")
    #expect(transport.requests.first?.url?.absoluteString == "https://api.capy.ai/api/v1/threads/t1")
    for settled in ["pending_user", "ready_for_review", "idle", "error", "archived"] { #expect(CapyThreadStatus.settled.contains(settled)) }
    for working in ["active", "waiting"] { #expect(!CapyThreadStatus.settled.contains(working)) }
}

@Test func sendMessagePostsTheTextToTheThread() async throws {
    let transport = FakeTransport()
    transport.enqueue(status: 200, json: #"{"id": "m1", "deduped": false}"#)
    try await client(transport).sendMessage(threadID: "t9", text: "Proceed with defaults")
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.capy.ai/api/v1/threads/t9/message")
    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["text"] as? String == "Proceed with defaults")
}

@Test func httpFailuresMapToNamedErrorsWithTheAPIsOwnExplanation() async throws {
    func failure(status: Int, json: String) async -> CapyAPIError? {
        let transport = FakeTransport()
        transport.enqueue(status: status, json: json)
        do { _ = try await client(transport).thread(id: "t1"); return nil } catch { return error as? CapyAPIError }
    }
    #expect(await failure(status: 401, json: #"{"_tag": "capy/Unauthorized"}"#) == .keyRejected)
    #expect(await failure(status: 402, json: #"{"_tag": "capy/PaymentRequired", "message": "balance exhausted"}"#) == .paymentRequired(detail: "balance exhausted"))
    #expect(await failure(status: 429, json: #"{"message": "slow down"}"#) == .rateLimited(detail: "slow down"))
    #expect(await failure(status: 404, json: #"{"_tag": "capy/ProjectNotFound"}"#) == .notFound(detail: "capy/ProjectNotFound"))
    #expect(await failure(status: 500, json: "not json at all") == .serverError(status: 500, detail: ""))
}

@Test func fullTranscriptFollowsTheCursorThroughEveryPage() async throws {
    let transport = FakeTransport()
    transport.enqueue(status: 200, json: #"{"items": [{"id": "m1", "source": "user", "text": "package", "createdAt": "2026-08-16T00:00:00Z"}], "cursor": "c1"}"#)
    transport.enqueue(status: 200, json: #"{"items": [{"id": "m2", "source": "assistant", "text": "stages", "createdAt": "2026-08-16T00:01:00Z"}], "cursor": null}"#)
    let messages = try await client(transport).fullTranscript(threadID: "t1")
    #expect(messages.map(\.id) == ["m1", "m2"])
    #expect(transport.requests.count == 2)
    #expect(transport.requests[0].url?.query()?.contains("after=") != true)
    #expect(transport.requests[1].url?.query()?.contains("after=c1") == true)
}

// MARK: - Polling discipline

@Test func pollingBacksOffToTheNamedCeiling() {
    #expect(AssistantPolling.nextInterval(after: 5) == 7.5)
    #expect(AssistantPolling.nextInterval(after: 7.5) == 11.25)
    #expect(AssistantPolling.nextInterval(after: 25) == 30) // 37.5 capped at the ceiling
    #expect(AssistantPolling.nextInterval(after: 30) == 30)
    #expect(AssistantPolling.totalTimeout == 15 * 60)
}

// MARK: - Fenced json extraction

@Test func lastJSONBlockWinsAmongSeveral() {
    let text = "prose\n```json\n{\"first\": 1}\n```\nmore\n```json\n{\"second\": 2}\n```\ntail"
    #expect(FencedCodeBlocks.lastJSONBlock(in: text) == "{\"second\": 2}")
    #expect(FencedCodeBlocks.jsonBlocks(in: text).count == 2)
}
@Test func nonJSONFencesAreIgnoredAndCannotOpenABlock() {
    let text = "```swift\nlet json = \"```json\"\n```\n```json\n{\"real\": true}\n```\n```text\nnot this\n```"
    #expect(FencedCodeBlocks.lastJSONBlock(in: text) == "{\"real\": true}")
}
@Test func textWithoutAJSONBlockYieldsNil() {
    #expect(FencedCodeBlocks.lastJSONBlock(in: "no code here") == nil)
    #expect(FencedCodeBlocks.lastJSONBlock(in: "```json\n```") == nil) // an empty block is not a deliverable
    #expect(FencedCodeBlocks.lastJSONBlock(in: "```python\nprint(1)\n```") == nil)
}
@Test func crlfLineEndingsAreNormalized() {
    #expect(FencedCodeBlocks.lastJSONBlock(in: "```json\r\n{\"a\": 1}\r\n```\r\n") == "{\"a\": 1}")
}

// MARK: - MixGraph dry validation

private let installed = [
    PluginInventoryItem(name: "AUParametricEQ", manufacturer: "Apple", type: "Effect", identifier: "aufx/pmeq/appl", version: nil),
    PluginInventoryItem(name: "Duplicate", manufacturer: "A", type: "Effect", identifier: "aufx/dup1/aaaa", version: nil),
    PluginInventoryItem(name: "Duplicate", manufacturer: "B", type: "Effect", identifier: "aufx/dup2/bbbb", version: nil),
]
private func graph(tracks: [MixGraphTrack], buses: [MixGraphBus] = [], master: MixGraphMaster = .init(), version: String = "1.0") -> MixGraph {
    MixGraph(schemaVersion: version, tracks: tracks, buses: buses, master: master)
}

@Test func dryCheckAcceptsAValidGraph() {
    let g = graph(tracks: [
        .init(name: "Beat", file: "Beat.wav", inserts: [.init(component: "aufx/pmeq/appl")], sends: [.init(bus: "Reverb", levelDB: -12)]),
        .init(name: "Vocal", file: "Vocal.wav"),
    ], buses: [.init(name: "Reverb")])
    #expect(MixGraphDryCheck.validate(g, audioFiles: ["Beat.wav", "Vocal.wav"], installedPlugins: installed).isEmpty)
}
@Test func dryCheckNamesAMissingFile() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Ghost.wav")]), audioFiles: ["Beat.wav"], installedPlugins: [])
    #expect(issues.count == 1); #expect(issues[0].contains("Ghost.wav")); #expect(issues[0].contains("Beat.wav"))
}
@Test func dryCheckNamesAnUnknownBus() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav", sends: [.init(bus: "Nowhere", levelDB: 0)])]), audioFiles: ["Beat.wav"], installedPlugins: [])
    #expect(issues.count == 1); #expect(issues[0].contains("Nowhere"))
}
@Test func dryCheckNamesDuplicateNames() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav"), .init(name: "Beat", file: "Vocal.wav")]), audioFiles: ["Beat.wav", "Vocal.wav"], installedPlugins: [])
    #expect(issues == ["Track name \"Beat\" is used more than once; names must be unique."])
}
@Test func dryCheckRefusesAForeignSchemaVersion() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav")], version: "2.0"), audioFiles: ["Beat.wav"], installedPlugins: [])
    #expect(issues.count == 1); #expect(issues[0].contains("\"2.0\"")); #expect(issues[0].contains("\"1.0\""))
}
@Test func dryCheckRejectsPanOutsideTheRange() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav", pan: 1.5)]), audioFiles: ["Beat.wav"], installedPlugins: [])
    #expect(issues.count == 1); #expect(issues[0].contains("pan 1.5"))
}
@Test func dryCheckRejectsAnInsertWithoutIdentity() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav", inserts: [.init()])]), audioFiles: ["Beat.wav"], installedPlugins: installed)
    #expect(issues.count == 1); #expect(issues[0].contains("neither a component identifier nor a component name"))
}
@Test func dryCheckRejectsAMalformedComponentIdentifier() {
    let issues = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav", inserts: [.init(component: "not-a-fourcc")])]), audioFiles: ["Beat.wav"], installedPlugins: installed)
    #expect(issues.count == 1); #expect(issues[0].contains("FourCC"))
}
@Test func dryCheckNamesANotInstalledPluginAndAnAmbiguousName() {
    let missing = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav", inserts: [.init(component: "aufx/none/none")])]), audioFiles: ["Beat.wav"], installedPlugins: installed)
    #expect(missing.count == 1); #expect(missing[0].contains("not installed"))
    let ambiguous = MixGraphDryCheck.validate(graph(tracks: [.init(name: "Beat", file: "Beat.wav", inserts: [.init(name: "Duplicate")])]), audioFiles: ["Beat.wav"], installedPlugins: installed)
    #expect(ambiguous.count == 1); #expect(ambiguous[0].contains("matches 2 installed plugins"))
}
@Test func dryCheckHonestlySkipsCatalogueChecksWithoutAnInventory() {
    let g = graph(tracks: [.init(name: "Beat", file: "Beat.wav", inserts: [.init(component: "aufx/none/none"), .init(name: "Anything")])]), files = ["Beat.wav"]
    #expect(MixGraphDryCheck.validate(g, audioFiles: files, installedPlugins: []).isEmpty)
}

// MARK: - API delivery package (the document the Assistant sends)

private func apiFixture() -> NormalizedSnapshot {
    .init(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1), completeness: .known("partial"), project: .empty, tracks: [])
}
private func exportedAsset(_ id: String, name: String, file: String) -> AudioAsset {
    .init(audioID: id, logicalTrackID: "track_\(id)", trackName: .known(name), expectedExportPath: "audio/\(file)", actualExportedPath: .known("audio/\(file)"), sourceFile: .unavailable, status: .exported, statusReason: nil, regions: [], durationSeconds: .known(10), sampleRate: .known(44100), channels: .known(2), bitDepth: .known(24), format: .known("PCM"), trackAXPath: nil)
}

@Test func apiDeliveryTeachesTheMixGraphContractInsteadOfTheMixPlan() {
    let md = AIPackageGenerator().make(snapshot: apiFixture(), sessionID: "t", audio: [exportedAsset("a1", name: "Beat", file: "Beat.wav"), exportedAsset("a2", name: "Vocal", file: "Vocal.wav")], plugins: installed, delivery: .apiDelivery)
    #expect(md.contains("Package schema: `2.30`"))
    #expect(md.contains("DELIVERY: API (TEXT ONLY)"))
    #expect(md.contains("## MixGraph response contract (machine-validated)"))
    #expect(!md.contains("## Mix Plan schema (machine-validated)"))
    #expect(md.contains("6. MIX GRAPH — only after confirmation."))
    #expect(md.contains("contains NO fenced json code block at all"))
    #expect(md.contains("EXACTLY ONE fenced json code block"))
    // The embedded example is built from the really exported file names and the really installed catalogue.
    #expect(md.contains("\"file\": \"Beat.wav\"")); #expect(md.contains("\"file\": \"Vocal.wav\""))
    #expect(md.contains("\"component\": \"aufx/pmeq/appl\""))
}
@Test func apiDeliveryExampleStaysHonestWithNothingExported() {
    let md = AIPackageGenerator().make(snapshot: apiFixture(), sessionID: "t", audio: [], plugins: [], delivery: .apiDelivery)
    #expect(md.contains("\"tracks\": []"))
    #expect(md.contains("none are exported yet, so the honest example is empty"))
}
@Test func pluginCatalogueCarriesTheComponentIdentifierInEveryDelivery() {
    for delivery in [PackageDelivery.fullPackage, .markdownOnly, .apiDelivery] {
        let md = AIPackageGenerator().make(snapshot: apiFixture(), sessionID: "t", plugins: installed, delivery: delivery)
        #expect(md.contains("- AUParametricEQ (Effect) — component `aufx/pmeq/appl`"))
    }
}
