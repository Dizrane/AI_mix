import Testing
import Foundation
import AVFoundation
@testable import AIMixAssistant

// MARK: - Fixtures

private func fixture() -> NormalizedSnapshot {
    let channel = ChannelFacts(volumeDB: .known(-2), pan: .known(0), mute: .known(false), solo: .known(false), automation: .known("Read"), input: .unavailable, output: .unavailable, plugins: [.init(id: "q", slot: 4, name: .known("Pro-Q 4"), manufacturer: .unavailable, bypass: .known(false), parameters: [.init(id: "gain", name: "Band 2 Gain", value: .known(0), range: -12...12, unit: "dB")])])
    let track = TrackFacts(logicalTrackID: "channel_aux_1", name: .known("Aux 1"), type: .known("aux"), matchStatus: .unresolved, axPaths: .init(header: nil, channel: "ax.channel"), header: nil, channel: channel)
    return .init(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1), completeness: .known("partial"), project: .empty, tracks: [track])
}

private func ax(_ role: String, id: String = "x", desc: String? = nil, title: String? = nil, value: String? = nil, _ children: [RawAccessibilityNode] = []) -> RawAccessibilityNode {
    .init(id: id, role: role, subrole: nil, title: title, description: desc, value: value, enabled: true, position: nil, size: nil, supportedAttributes: [], parameterizedAttributes: [], actions: [], children: children)
}
private func headerNode(_ id: String, _ desc: String) -> RawAccessibilityNode {
    ax("AXLayoutItem", id: id, desc: desc, [ax("AXCheckBox", desc: "Mute", value: "0"), ax("AXCheckBox", desc: "Solo", value: "0"), ax("AXCheckBox", desc: "Record Enable", value: "0"), ax("AXCheckBox", desc: "Input Monitoring", value: "0"), ax("AXSlider", desc: "Volume", value: "173"), ax("AXTextField", desc: "name", value: "x"), ax("AXRadioButton", desc: "Has Focus", value: "0")])
}
private func stripNode(_ id: String, _ name: String, send: Bool = true, plugin: String? = nil) -> RawAccessibilityNode {
    var kids: [RawAccessibilityNode] = [ax("AXTextField", desc: "name", value: name), ax("AXButton", desc: "mute", value: "off"), ax("AXButton", desc: "solo", value: "off"), ax("AXButton", desc: "record", value: "off"), ax("AXButton", desc: "monitoring", value: "off"), ax("AXSlider", desc: "volume fader", value: "160"), ax("AXTextField", desc: "volume fader level", title: "volume fader level, -1,5 dB"), ax("AXSlider", desc: "pan", value: "-20"), ax("AXButton", desc: "channel mode", value: "Mono"), ax("AXButton", desc: "Input 1"), ax("AXButton", desc: "EQ", value: "off"), ax("AXSlider", desc: "input gain", value: "7")]
    if send { kids.append(ax("AXButton", desc: "Bus 1")); kids.append(ax("AXButton", desc: "send button")) }
    kids.append(ax("AXButton", desc: "audio plug-in", title: plugin))
    kids.append(ax("AXButton", desc: "audio plug-in"))
    return ax("AXLayoutItem", id: id, desc: name, kids)
}
private func snapshot(headers: [RawAccessibilityNode], strips: [RawAccessibilityNode]) -> RawSnapshot {
    let root = ax("AXApplication", id: "application", [ax("AXGroup", id: "th", desc: "Tracks header", headers), ax("AXLayoutArea", id: "mx", desc: "Mixer", strips)])
    return RawSnapshot(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1), root: root)
}
private func normalize(headers: [RawAccessibilityNode], strips: [RawAccessibilityNode]) -> NormalizedSnapshot {
    SnapshotNormalizer().normalize(snapshot(headers: headers, strips: strips))
}

// MARK: - Validator / diff / plan / storage

@Test func validatorRejectsUnknownPluginParameter() { let plan = MixPlan(version: "1.0", status: "ready", actions: [.init(id: "a", target: .init(trackID: "channel_aux_1", pluginID: "q", parameterName: "Missing"), action: .setPluginParameter, parameters: ["value": .number(1)], reason: "LLM")]); #expect(CommandValidator().validate(plan, against: fixture()).first?.status == .requiresProbe) }
@Test func validatorChecksReportedRange() { let plan = MixPlan(version: "1.0", status: "ready", actions: [.init(id: "a", target: .init(trackID: "channel_aux_1", pluginID: "q", parameterID: "gain"), action: .setPluginParameter, parameters: ["value": .number(20)], reason: "LLM")]); #expect(CommandValidator().validate(plan, against: fixture()).first?.status == .invalid) }
@Test func diffReportsChangedTrack() { var after = fixture(); after.tracks[0].channel?.volumeDB = .known(-3); #expect(DiffEngine().compare(before: fixture(), after: after).changed == ["Changed: Aux 1"]) }
@Test func planJSONRoundTrip() throws { let plan = MixPlan(version: "1.0", status: "ready", actions: []); #expect(try JSONDecoder().decode(MixPlan.self, from: JSONEncoder().encode(plan)).version == "1.0") }
@Test func sessionStorage() async throws { let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString); let store = try SessionStore(root: temp); let url = try await store.save(fixture(), folder: "normalized", name: "s.json"); #expect(FileManager.default.fileExists(atPath: url.path)) }

// MARK: - Channel-strip fact extraction

@Test func normalizerExtractsChannelStripFacts() {
    let c = normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5", plugin: "Pro-Q 4")]).tracks.first?.channel
    #expect(c?.volumeDB.value == -1.5); #expect(c?.pan.value == -20); #expect(c?.channelMode.value == "Mono")
    #expect(c?.eqEnabled.value == false); #expect(c?.inputGain.value == 7); #expect(c?.record.value == false); #expect(c?.monitoring.value == false)
}
@Test func normalizerExtractsSend() {
    let c = normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5")]).tracks.first?.channel
    #expect(c?.sends.count == 1); #expect(c?.sends.first?.destination.value == "Bus 1"); #expect(c?.sends.first?.levelDB.state == .requiresProbe)
}
@Test func normalizerEmitsLoadedPluginAndIgnoresEmptySlots() {
    let c = normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5", plugin: "Pro-Q 4")]).tracks.first?.channel
    #expect(c?.plugins.count == 1); #expect(c?.plugins.first?.name.value == "Pro-Q 4"); #expect(c?.plugins.first?.slot == 0); #expect(c?.plugins.first?.bypass.state == .requiresProbe)
}

// MARK: - Track ↔ Channel linking (regression scenarios A–E)

@Test func linkA_headerPlusChannelBecomeOneConfirmedTrack() {
    let s = normalize(headers: [headerNode("h1", "Track 1 “Vox”")], strips: [stripNode("c1", "Vox")])
    #expect(s.tracks.count == 1)
    let t = s.tracks.first
    #expect(t?.matchStatus == .confirmed); #expect(t?.header != nil); #expect(t?.channel != nil)
    #expect(t?.header?.ordinal.value == 1); #expect(t?.logicalTrackID == "track_1")
    #expect(t?.channel?.sends.count == 1) // channel facts not lost after merge
    #expect(s.linking.confirmedLinks == 1); #expect(s.linking.logicalTracks == 1)
}
@Test func linkB_headerWithoutChannelKeepsChannelUnavailable() {
    let s = normalize(headers: [headerNode("h1", "Track 5 “Guitar”")], strips: [])
    #expect(s.tracks.count == 1)
    #expect(s.tracks.first?.matchStatus == .unresolved); #expect(s.tracks.first?.channel == nil); #expect(s.tracks.first?.header != nil)
    #expect(s.linking.unresolvedHeaders == 1)
}
@Test func linkC_channelWithoutHeaderStaysUnresolvedChannel() {
    let s = normalize(headers: [], strips: [stripNode("c1", "Aux 1", send: false)])
    #expect(s.tracks.count == 1)
    #expect(s.tracks.first?.matchStatus == .unresolved); #expect(s.tracks.first?.header == nil); #expect(s.tracks.first?.channel != nil)
    #expect(s.tracks.first?.logicalTrackID == "channel_aux_1"); #expect(s.linking.unresolvedChannels == 1)
}
@Test func linkD_sameNameObjectsAreNotMerged() {
    let s = normalize(headers: [headerNode("h1", "Track 1 “Dup”"), headerNode("h2", "Track 2 “Dup”")], strips: [stripNode("c1", "Dup")])
    #expect(s.tracks.count == 3)
    #expect(s.tracks.allSatisfy { $0.matchStatus == .ambiguous })
    #expect(Set(s.tracks.map(\.logicalTrackID)).count == 3) // unique stable ids
}
@Test func linkE_logicalIDsAreStableAcrossRepeatedAnalysis() {
    let raw = snapshot(headers: [headerNode("h1", "Track 1 “A”"), headerNode("h2", "Track 2 “B”")], strips: [stripNode("c1", "A"), stripNode("c2", "Zed")])
    let first = SnapshotNormalizer().normalize(raw).tracks.map(\.logicalTrackID)
    let second = SnapshotNormalizer().normalize(raw).tracks.map(\.logicalTrackID)
    #expect(first == second)
}

// MARK: - Project metadata honesty (caption match, never substring)

private func projectSnapshot(_ nodes: [RawAccessibilityNode], windowTitle: String? = nil, document: String? = nil, windowSource: String? = "AXMainWindow") -> NormalizedSnapshot {
    SnapshotNormalizer().normalize(RawSnapshot(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1, projectWindowTitle: windowTitle, projectWindowDocument: document, projectWindowSource: windowSource), root: ax("AXApplication", id: "application", nodes)))
}

@Test func projectFactsIgnoreSubstringLookalikes() {
    // "play" inside "Display" and "key" inside "keyboard" once produced falsely `known` facts carrying another control's value.
    let s = projectSnapshot([ax("AXStaticText", id: "lcd", title: "Display", value: "Beats & Project"), ax("AXGroup", id: "kb", desc: "keyboard", value: "C3")])
    #expect(s.project.transportState.state == .unavailable)
    #expect(s.project.keySignature.state == .unavailable)
    #expect(s.project.name.state == .unavailable) // "Project" inside a value is not a caption either
}
@Test func projectFactsStayKnownFromRealCaptions() {
    let s = projectSnapshot([ax("AXStaticText", id: "tempo", desc: "Tempo", value: "115"), ax("AXStaticText", id: "keysig", desc: "Key Signature", value: "D# minor")])
    #expect(s.project.tempo.state == .known); #expect(s.project.tempo.value == 115)
    #expect(s.project.keySignature.value == "D# minor")
}
@Test func captionedLabelIsNeverPublishedAsItsOwnValue() {
    // Logic labels a field with one element and shows the value in another: the label carries no AXValue and must be skipped,
    // never emitted as "Key Signature: known: Key Signature".
    let s = projectSnapshot([ax("AXStaticText", id: "label", title: "Key Signature"), ax("AXStaticText", id: "field", desc: "Key Signature", value: "D# minor")])
    #expect(s.project.keySignature.value == "D# minor"); #expect(s.project.keySignature.source == "field")
    let labelOnly = projectSnapshot([ax("AXStaticText", id: "label", title: "Tempo")])
    #expect(labelOnly.project.tempo.state == .unavailable)
}
@Test func projectNameComesFromTheMainWindowDocument() {
    let s = projectSnapshot([], windowTitle: "fanlove — Tracks", document: "file:///Users/dizrane/Music/Logic/fanlove.logicx")
    #expect(s.project.name.value == "fanlove") // the project file name wins over the window title, which carries the view name
    #expect(s.project.name.source == "AXDocument of AXMainWindow")
}
@Test func projectNameFallsBackToTheWindowTitleVerbatim() {
    let titleOnly = projectSnapshot([], windowTitle: "fanlove — Tracks")
    #expect(titleOnly.project.name.value == "fanlove — Tracks"); #expect(titleOnly.project.name.source == "AXTitle of AXMainWindow")
    #expect(projectSnapshot([]).project.name.state == .unavailable) // no open project: no name is invented
}
@Test func projectNameCitesTheWindowAttributeItWasReadFrom() {
    // The analyzer falls back to AXFocusedWindow when Logic exposes no main window; the published source must say so, not claim AXMainWindow.
    let focused = projectSnapshot([], document: "file:///Users/dizrane/Music/Logic/fanlove.logicx", windowSource: "AXFocusedWindow")
    #expect(focused.project.name.source == "AXDocument of AXFocusedWindow")
}

// MARK: - Inspector mirror strips (phantom channel duplicates)

@Test func linkF_inspectorMirrorsAreDroppedRealStripsKept() {
    let root = ax("AXApplication", id: "application", [
        ax("AXGroup", id: "th", desc: "Tracks header", [headerNode("h1", "Track 1 “Фон”"), headerNode("h2", "Track 2 “Beat”")]),
        ax("AXLayoutArea", id: "application.0.6", desc: "Mixer", [stripNode("i1", "Фон"), stripNode("i2", "Stereo Out")]),
        ax("AXLayoutArea", id: "application.0.8", desc: "Mixer", [stripNode("c1", "Фон"), stripNode("c2", "Beat"), stripNode("c3", "Aux 2")])
    ])
    let s = SnapshotNormalizer().normalize(RawSnapshot(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1), root: root))
    #expect(s.linking.channelCandidates == 4) // 3 real Mixer strips + the inspector-only "Stereo Out"
    #expect(s.tracks.count == 4) // track_1, track_2, channel_aux_2, channel_stereo_out — no phantoms
    let fon = s.tracks.filter { $0.name.value == "Фон" }
    #expect(fon.count == 1); #expect(fon.first?.matchStatus == .confirmed) // selected track no longer sees 1 header + 2 channels
    #expect(s.tracks.contains { $0.name.value == "Stereo Out" && $0.matchStatus == .unresolved }) // only-in-inspector object is a real object
    #expect(!s.tracks.map(\.logicalTrackID).contains("channel_фон"))
}
@Test func linkG_sameNameStripsInsideMixerStayAmbiguous() {
    let root = ax("AXApplication", id: "application", [
        ax("AXGroup", id: "th", desc: "Tracks header", [headerNode("h1", "Track 1 “Dup”")]),
        ax("AXLayoutArea", id: "insp", desc: "Mixer", [stripNode("i1", "Dup")]),
        ax("AXLayoutArea", id: "mx", desc: "Mixer", [stripNode("c1", "Dup"), stripNode("c2", "Dup")])
    ])
    let s = SnapshotNormalizer().normalize(RawSnapshot(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1), root: root))
    #expect(s.tracks.count == 3) // both real same-named Mixer strips kept, only the inspector mirror dropped
    #expect(s.tracks.allSatisfy { $0.matchStatus == .ambiguous })
}

// MARK: - Phase 2: audio asset extraction (provenance only)

private func regionNode(_ id: String, _ name: String, x: Double, w: Double) -> RawAccessibilityNode {
    var node = ax("AXLayoutItem", id: id, desc: name); node.position = "\(x),300.0"; node.size = "\(w)x56.0"; return node
}
private func laneArea(_ id: String, _ desc: String, _ regions: [RawAccessibilityNode]) -> RawAccessibilityNode { ax("AXLayoutArea", id: id, desc: desc, regions) }
/// One raw snapshot with both Tracks headers (so the normalizer assigns logical IDs) and arrange lanes with regions.
private func audioSnapshot() -> RawSnapshot {
    let headers = [headerNode("h1", "Track 1 “Beat”"), headerNode("h2", "Track 2 “Vox”")]
    let arrange = ax("AXGroup", id: "arr", [
        laneArea("l1", "Track 1 “Beat”", [regionNode("r1", "Beat", x: 100, w: 800)]),
        laneArea("l2", "Track 2 “Vox”", [regionNode("r4", "Vox #03", x: 700, w: 180), regionNode("r2", "Vox #01", x: 120, w: 200), regionNode("r3", "Vox #02", x: 400, w: 150)])
    ])
    let root = ax("AXApplication", id: "application", [ax("AXGroup", id: "th", desc: "Tracks header", headers), arrange])
    return RawSnapshot(application: .init(name: "Logic Pro", bundleIdentifier: "com.apple.logic10", pid: 1), root: root)
}
private func extractAudio(_ raw: RawSnapshot, dir: URL? = nil) -> [AudioAsset] {
    AudioAssetExtractor().extract(raw: raw, normalized: SnapshotNormalizer().normalize(raw), audioDirectory: dir)
}
private func writeWAV(_ url: URL, seconds: Double = 0.5, sampleRate: Double = 44100, channels: AVAudioChannelCount = 1) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels), AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(seconds * sampleRate))!
    buf.frameLength = AVAudioFrameCount(seconds * sampleRate)
    try file.write(from: buf)
}

@Test func audio1_assetsGetStableIDs() {
    let raw = audioSnapshot()
    #expect(extractAudio(raw).map(\.audioID) == extractAudio(raw).map(\.audioID))
    #expect(extractAudio(raw).flatMap { $0.regions.map(\.regionID) } == extractAudio(raw).flatMap { $0.regions.map(\.regionID) })
}
@Test func audio2_logicalTrackIDPreserved() {
    let assets = extractAudio(audioSnapshot())
    #expect(assets.first { $0.trackName.value == "Beat" }?.logicalTrackID == "track_1")
    #expect(assets.first { $0.trackName.value == "Vox" }?.logicalTrackID == "track_2")
}
@Test func audio3_oneTrackManyRegionsIsSingleAsset() {
    let assets = extractAudio(audioSnapshot())
    let vox = assets.filter { $0.trackName.value == "Vox" }
    #expect(vox.count == 1); #expect(vox.first?.regions.count == 3)
    // regions ordered left-to-right by timeline position
    #expect(vox.first?.regions.map { $0.name.value } == ["Vox #01", "Vox #02", "Vox #03"])
}
@Test func audio4_differentTracksAreNotMerged() {
    let assets = extractAudio(audioSnapshot())
    #expect(assets.count == 2); #expect(Set(assets.map(\.logicalTrackID)).count == 2); #expect(Set(assets.map(\.audioID)).count == 2)
}
@Test func audio5_newAnalysisClearsCurrentAudio() async throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let store = try SessionStore(root: temp)
    let audioDir = await store.folderURL("audio")
    let stray = audioDir.appendingPathComponent("audio_track_001.wav")
    try Data("x".utf8).write(to: stray)
    #expect(FileManager.default.fileExists(atPath: stray.path))
    try await store.resetForNewAnalysis()
    #expect(!FileManager.default.fileExists(atPath: stray.path))
    #expect(FileManager.default.fileExists(atPath: audioDir.path)) // folder recreated empty
}
@Test func audio6_manifestIsCreatedAndRoundTrips() throws {
    let manifest = AudioManifest(assets: extractAudio(audioSnapshot()))
    #expect(manifest.summary.assets == 2); #expect(manifest.summary.audioRegions == 4)
    let back = try JSONDecoder().decode(AudioManifest.self, from: JSONEncoder().encode(manifest))
    #expect(back.assets.count == 2); #expect(back.summary.audioRegions == 4)
}
@Test func audio7_missingSourceBecomesRequiresUserExport() {
    let asset = extractAudio(audioSnapshot(), dir: nil).first
    #expect(asset?.status == .requiresUserExport); #expect(asset?.sourceFile.state == .unavailable); #expect(asset?.durationSeconds.state == .unavailable)
}
@Test func audio8_exportedFileReadsMetadataWithoutModifyingIt() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wav = dir.appendingPathComponent("audio_track_001.wav")
    try writeWAV(wav)
    let before = try FileManager.default.attributesOfItem(atPath: wav.path)
    let asset = extractAudio(audioSnapshot(), dir: dir).first { $0.audioID == "audio_track_001" }
    #expect(asset?.status == .exported); #expect(asset?.sampleRate.value == 44100); #expect(asset?.channels.value == 1); #expect(asset?.bitDepth.value == 16); #expect(asset?.format.value == "PCM")
    let after = try FileManager.default.attributesOfItem(atPath: wav.path)
    #expect((before[.modificationDate] as? Date) == (after[.modificationDate] as? Date))
    #expect((before[.size] as? Int) == (after[.size] as? Int))
    try? FileManager.default.removeItem(at: dir)
}
@Test func audio9_repeatAnalysisProducesConsistentManifest() {
    let raw = audioSnapshot()
    let a = AudioManifest(assets: extractAudio(raw)); let b = AudioManifest(assets: extractAudio(raw))
    #expect(a.assets.map(\.audioID) == b.assets.map(\.audioID)); #expect(a.summary.audioRegions == b.summary.audioRegions)
}
@Test func audio10_aiPackageContainsProvenanceMapping() {
    let raw = audioSnapshot()
    let md = AIPackageGenerator().make(snapshot: SnapshotNormalizer().normalize(raw), sessionID: "t", audio: extractAudio(raw))
    #expect(md.contains("## Audio Assets"))
    #expect(md.contains("audio_track_001"))
    #expect(md.contains("logicalTrackID: known: track_1"))
    #expect(!md.contains("Lead")); #expect(!md.contains("Double")) // no musical interpretation
}

// MARK: - AI package: delivery modes & rendering polish

@Test func packageDeclaresDeliveryModes() {
    let md = AIPackageGenerator().make(snapshot: fixture(), sessionID: "t")
    #expect(md.contains("Package schema: `2.1`"))
    #expect(md.contains("Delivery modes"))
    #expect(md.contains("FULL PACKAGE")); #expect(md.contains("THIS DOCUMENT ONLY")); #expect(md.contains("NO AUDIO CAPABILITY"))
    #expect(md.contains("NEVER pretend to have listened"))
}
@Test func packageRendersNumbersRounded() {
    let asset = AudioAsset(audioID: "audio_track_001", logicalTrackID: "track_1", trackName: .known("Beat"), expectedExportPath: "audio/Beat.wav", actualExportedPath: .known("audio/Beat.wav"), sourceFile: .unavailable, status: .exported, statusReason: nil, regions: [], durationSeconds: .known(135.85066666666665), sampleRate: .known(44100), channels: .known(2), bitDepth: .known(16), format: .known("PCM"), trackAXPath: nil)
    let md = AIPackageGenerator().make(snapshot: fixture(), sessionID: "t", audio: [asset])
    #expect(md.contains("Duration: known: 135.85 s")); #expect(!md.contains("135.85066"))
    #expect(md.contains("Sample rate: known: 44100 Hz"))
}
@Test func linkEvidenceUsesRealPlurals() {
    let s = normalize(headers: [headerNode("h1", "Track 1 “Dup”"), headerNode("h2", "Track 2 “Dup”")], strips: [stripNode("c1", "Dup")])
    #expect(s.tracks.first?.linkEvidence.first?.contains("2 headers and 1 channel;") == true)
    #expect(!s.tracks.flatMap(\.linkEvidence).joined().contains("header(s)"))
}
@Test func packageCompactsUnavailableTrackFields() {
    let md = AIPackageGenerator().make(snapshot: normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5", plugin: "Pro-Q 4")]), sessionID: "t")
    #expect(!md.contains("- Group: unavailable")); #expect(!md.contains("- Automation: unavailable")) // pure-unavailable noise compressed…
    #expect(md.contains("- Unavailable: Automation, Group")); #expect(md.contains("- Unavailable: Output"))
    #expect(md.contains("- Pan: known: -20")); #expect(md.contains("- Volume: known: -1.5 dB")) // …while known facts keep their own lines
}

// MARK: - Closed-shell storage rules

@Test func sharedContainerDetectsCommonFolders() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(SessionStore.sharedContainerName(home.appendingPathComponent("Downloads")) == "~/Downloads")
    #expect(SessionStore.sharedContainerName(home) == "the home folder")
    #expect(SessionStore.sharedContainerName(URL(fileURLWithPath: "/Applications")) == "/Applications")
}
@Test func dedicatedAppFolderIsNotShared() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(SessionStore.sharedContainerName(home.appendingPathComponent("Downloads/AI_Mix_v1")) == nil)
    #expect(SessionStore.sharedContainerName(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AI_Mix")) == nil)
}

// MARK: - App Translocation repair

@Test func translocationRepairRefusesOutsideTranslocatedLaunch() {
    #expect(!TranslocationRepair.isActive)
    #expect(TranslocationRepair.originalBundleURL() == nil)
    if case .repaired = TranslocationRepair.dequarantineOriginal() { Issue.record("dequarantine must refuse when the app is not translocated") }
}
