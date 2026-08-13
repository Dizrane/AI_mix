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
private func stripNode(_ id: String, _ name: String, routing: Bool = true, plugin: String? = nil) -> RawAccessibilityNode {
    var kids: [RawAccessibilityNode] = [ax("AXTextField", desc: "name", value: name), ax("AXButton", desc: "mute", value: "off"), ax("AXButton", desc: "solo", value: "off"), ax("AXButton", desc: "record", value: "off"), ax("AXButton", desc: "monitoring", value: "off"), ax("AXSlider", desc: "volume fader", value: "160"), ax("AXTextField", desc: "volume fader level", title: "volume fader level, -1,5 dB"), ax("AXSlider", desc: "pan", value: "-20"), ax("AXButton", desc: "channel mode", value: "Mono"), ax("AXButton", desc: "Input 1"), ax("AXButton", desc: "EQ", value: "off"), ax("AXSlider", desc: "input gain", value: "7")]
    if routing { kids.append(ax("AXButton", desc: "Bus 1")); kids.append(ax("AXButton", desc: "St Out")); kids.append(ax("AXButton", desc: "send button")) }
    kids.append(ax("AXButton", desc: "audio plug-in", title: plugin))
    kids.append(ax("AXButton", desc: "audio plug-in"))
    return ax("AXLayoutItem", id: id, desc: name, kids)
}
/// Mirrors the real AX shape of a mixer strip captured from a Logic Pro raw dump (fanlove.logicx, 2026-08-14): children in the
/// documented order — name, mute, solo, volume fader (+ level text), peak meter, pan, automation group, group pop-up, output
/// button, send slots (empty "send button" AXButtons; an occupied send is an AXGroup with a bypass checkbox plus a "send knob"
/// slider), audio plug-in, channel mode, input button, EQ, gain-reduction meter, setting.
private func realStrip(_ id: String, _ name: String, output: String?, sends: [(destination: String, bypass: String)] = [], emptySendSlots: Int = 2, afterChannelMode: String? = nil) -> RawAccessibilityNode {
    var kids: [RawAccessibilityNode] = [ax("AXTextField", desc: "name", value: name), ax("AXButton", desc: "mute", value: "off"), ax("AXButton", desc: "solo", value: "off"), ax("AXSlider", desc: "volume fader", value: "173"), ax("AXTextField", desc: "volume fader level", title: "volume fader level, 0,0 dB"), ax("AXButton", desc: "peak level meter", title: "peak level meter", value: "signal clipping off"), ax("AXSlider", desc: "pan", value: "0"), ax("AXGroup", desc: "Read, automation enabled", [ax("AXCheckBox", desc: "automation", value: "1"), ax("AXButton", desc: "list")]), ax("AXPopUpButton", desc: "group", title: "group")]
    if let output { kids.append(ax("AXButton", desc: output)) }
    kids += Array(repeating: ax("AXButton", desc: "send button"), count: emptySendSlots)
    for send in sends { kids.append(ax("AXGroup", desc: send.destination, [ax("AXCheckBox", desc: "bypass", value: send.bypass), ax("AXButton", desc: "list")])); kids.append(ax("AXSlider", desc: "send knob", value: "0")) }
    kids.append(ax("AXButton", desc: "audio plug-in"))
    kids.append(ax("AXButton", desc: "channel mode", value: "Stereo"))
    if let afterChannelMode { kids.append(ax("AXButton", desc: afterChannelMode)) }
    kids += [ax("AXButton", desc: "EQ", value: "off"), ax("AXButton", desc: "gain reduction meter", value: "off"), ax("AXButton", desc: "setting")]
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
@Test func normalizerNeverClassifiesRoutingButtonsAsSends() {
    let c = normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5")]).tracks.first?.channel
    #expect(c?.routingButtons.count == 2) // "Bus 1" and "St Out"; the empty "send button" slot is ignored
    #expect(c?.routingButtons.map(\.destination.value) == ["Bus 1", "St Out"])
    #expect(c?.routingButtons.allSatisfy { $0.slotKind.state == .requiresProbe } == true)
    #expect(c?.output.state == .unavailable) // a "Bus 1"/"St Out" button is never promoted to a confirmed output either
}
@Test func normalizerEmitsLoadedPluginAndIgnoresEmptySlots() {
    let c = normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5", plugin: "Pro-Q 4")]).tracks.first?.channel
    #expect(c?.plugins.count == 1); #expect(c?.plugins.first?.name.value == "Pro-Q 4"); #expect(c?.plugins.first?.slot == 0); #expect(c?.plugins.first?.bypass.state == .requiresProbe)
}

// MARK: - Routing classification (structures verified against a real mixer dump)

@Test func classifierProvesOutputSendAndAuxInputFromRealStripStructure() {
    // Aux 1 from the reference dump: output "Stereo Output" after the group pop-up, one occupied send to Bus 3
    // (AXGroup with bypass checkbox + send knob), input bus "Bus 1" directly after the channel-mode button.
    let c = normalize(headers: [], strips: [realStrip("c1", "Aux 1", output: "Stereo Output", sends: [("Bus 3", "0")], emptySendSlots: 1, afterChannelMode: "Bus 1")]).tracks.first?.channel
    #expect(c?.output.state == .known); #expect(c?.output.value == "Stereo Output")
    #expect(c?.input.state == .known); #expect(c?.input.value == "Bus 1")
    #expect(c?.sends.count == 1)
    #expect(c?.sends.first?.destination.value == "Bus 3")
    #expect(c?.sends.first?.bypass.value == false)
    #expect(c?.sends.first?.level.state == .requiresProbe) // the send knob's raw value has no readable unit
    #expect(c?.sends.first?.pan.state == .requiresProbe) // no send pan control is exposed at all
    #expect(c?.routingButtons.isEmpty == true) // every destination on this strip is classified
}
@Test func outputButtonAndAuxInputAreNeverSends() {
    // Audio 3 and Aux 2 from the reference dump carry destination buttons ("Bus 1" output, "Bus 2" aux input) but no
    // occupied send slot: the package once described eight sends in this send-free project. Empty "send button" slots and
    // the automation AXGroup (its checkbox is "automation", not "bypass") must contribute nothing either.
    let s = normalize(headers: [], strips: [realStrip("c1", "Audio 3", output: "Bus 1", afterChannelMode: "Input 1"), realStrip("c2", "Aux 2", output: "Stereo Output", afterChannelMode: "Bus 2")])
    let audio = s.tracks.first { $0.name.value == "Audio 3" }?.channel, aux = s.tracks.first { $0.name.value == "Aux 2" }?.channel
    #expect(audio?.sends.isEmpty == true); #expect(aux?.sends.isEmpty == true)
    #expect(audio?.output.value == "Bus 1"); #expect(audio?.input.value == "Input 1")
    #expect(aux?.output.value == "Stereo Output"); #expect(aux?.input.value == "Bus 2")
    #expect(audio?.routingButtons.isEmpty == true); #expect(aux?.routingButtons.isEmpty == true)
}
@Test func nonDestinationNeighboursAreNeverRoutingFacts() {
    // Stereo Out from the reference dump: the group pop-up is followed by "audio plug-in" (no output button at all) and the
    // channel-mode button by "mastering assistant" — structural position alone must not turn either into a routing fact.
    let strip = ax("AXLayoutItem", id: "c1", desc: "Stereo Out", [ax("AXTextField", desc: "name", value: "Stereo Out"), ax("AXButton", desc: "mute", value: "off"), ax("AXSlider", desc: "volume fader", value: "173"), ax("AXTextField", desc: "volume fader level", title: "volume fader level, 0,0 dB"), ax("AXGroup", desc: "Read, automation enabled", [ax("AXCheckBox", desc: "automation", value: "1"), ax("AXButton", desc: "list")]), ax("AXPopUpButton", desc: "group", title: "group"), ax("AXButton", desc: "audio plug-in"), ax("AXButton", desc: "channel mode", value: "Stereo"), ax("AXButton", desc: "mastering assistant"), ax("AXButton", desc: "EQ", value: "off")])
    let c = normalize(headers: [], strips: [strip]).tracks.first?.channel
    #expect(c?.output.state == .unavailable); #expect(c?.input.state == .unavailable)
    #expect(c?.sends.isEmpty == true); #expect(c?.routingButtons.isEmpty == true)
}
@Test func packageRendersProvenSendsAndClassifiedRouting() {
    let s = normalize(headers: [], strips: [realStrip("c1", "Aux 1", output: "Stereo Output", sends: [("Bus 3", "0")], emptySendSlots: 1, afterChannelMode: "Bus 1")])
    let md = AIPackageGenerator().make(snapshot: s, sessionID: "t")
    #expect(md.contains("- Output: known: Stereo Output · kind: stereo_output"))
    #expect(md.contains("- Input: known: Bus 1 · kind: bus"))
    #expect(md.contains("- Destination: known: Bus 3 · kind: bus"))
    #expect(md.contains("- Bypass: known: false"))
    #expect(md.contains("- Level: requires_probe"))
    #expect(md.contains("- none: no destination button on this strip is left unclassified"))
    #expect(!md.contains("no confirmed send facts"))
}
@Test func destinationKindsFollowLogicCaptionGrammar() {
    // The kind separates "output to the stereo bus" from "output into a bus" (and hardware I/O) without weakening honesty:
    // it is derived from the same caption grammar the routing classifier accepts, and an unknown caption gets NO kind.
    #expect(RoutingDestinationKind.classify("Bus 12") == .bus)
    #expect(RoutingDestinationKind.classify("St Out") == .stereoOutput)
    #expect(RoutingDestinationKind.classify("Stereo Out") == .stereoOutput)
    #expect(RoutingDestinationKind.classify("Stereo Output") == .stereoOutput)
    #expect(RoutingDestinationKind.classify("Output 1-2") == .hardwareOutput)
    #expect(RoutingDestinationKind.classify("Output") == .hardwareOutput)
    #expect(RoutingDestinationKind.classify("Input 3") == .hardwareInput)
    #expect(RoutingDestinationKind.classify("Input 1-2") == .hardwareInput)
    #expect(RoutingDestinationKind.classify("No Output") == .notConnected)
    #expect(RoutingDestinationKind.classify("No Input") == .notConnected)
    #expect(RoutingDestinationKind.classify("Mastering Assistant") == nil)
    #expect(RoutingDestinationKind.classify("Bus") == nil) // no number: not a destination caption Logic uses
}
@Test func unclassifiedRoutingButtonsStillCarryTheirDestinationKind() {
    // A button whose SLOT stays requires_probe still names a grammar-proven destination, and the kind narrows what the
    // slot could be: a "St Out" destination can be an output but never a send or an aux input (sends feed buses).
    let s = normalize(headers: [headerNode("h", "Track 6 “Audio 5”")], strips: [stripNode("c", "Audio 5")])
    let md = AIPackageGenerator().make(snapshot: s, sessionID: "t")
    #expect(md.contains("- Destination: known: Bus 1 · kind: bus"))
    #expect(md.contains("- Destination: known: St Out · kind: stereo_output"))
    #expect(md.contains("Slot kind (send / output / aux input): requires_probe"))
}

// MARK: - Track ↔ Channel linking (regression scenarios A–E)

@Test func linkA_headerPlusChannelBecomeOneConfirmedTrack() {
    let s = normalize(headers: [headerNode("h1", "Track 1 “Vox”")], strips: [stripNode("c1", "Vox")])
    #expect(s.tracks.count == 1)
    let t = s.tracks.first
    #expect(t?.matchStatus == .confirmed); #expect(t?.header != nil); #expect(t?.channel != nil)
    #expect(t?.header?.ordinal.value == 1); #expect(t?.logicalTrackID == "track_1")
    #expect(t?.channel?.routingButtons.count == 2) // channel facts not lost after merge
    #expect(s.linking.confirmedLinks == 1); #expect(s.linking.logicalTracks == 1)
}
@Test func linkB_headerWithoutChannelKeepsChannelUnavailable() {
    let s = normalize(headers: [headerNode("h1", "Track 5 “Guitar”")], strips: [])
    #expect(s.tracks.count == 1)
    #expect(s.tracks.first?.matchStatus == .unresolved); #expect(s.tracks.first?.channel == nil); #expect(s.tracks.first?.header != nil)
    #expect(s.linking.unresolvedHeaders == 1)
}
@Test func linkC_channelWithoutHeaderStaysUnresolvedChannel() {
    let s = normalize(headers: [], strips: [stripNode("c1", "Aux 1", routing: false)])
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
@Test func transportStateNeedsAStateNotASwitchPosition() {
    // Logic's play/stop controls publish "0"/"1"; that is not a transport state and was published as "Transport: known: 0".
    let numeric = projectSnapshot([ax("AXButton", id: "play", desc: "Play", value: "0")])
    #expect(numeric.project.transportState.state == .unknown); #expect(numeric.project.transportState.value == nil)
    let textual = projectSnapshot([ax("AXStaticText", id: "lcd", desc: "Transport", value: "Playing")])
    #expect(textual.project.transportState.value == "Playing")
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

// MARK: - Project presence (the Connection-stage check shares one rule with the normalizer's project name)

@Test func projectPresenceIsProvenByTheWindowDocument() {
    let p = ProjectPresence.evaluate(title: "fanlove — Tracks", document: "file:///Users/dizrane/Music/Logic/fanlove.logicx", windowSource: "AXMainWindow")
    #expect(p.open); #expect(p.name == "fanlove"); #expect(p.source == "AXDocument of AXMainWindow")
}
@Test func projectPresenceFallsBackToTheWindowTitle() {
    // An unsaved project has a window title but no document yet; the title is evidence and is published verbatim.
    let p = ProjectPresence.evaluate(title: "Untitled", document: nil, windowSource: "AXFocusedWindow")
    #expect(p.open); #expect(p.name == "Untitled"); #expect(p.source == "AXTitle of AXFocusedWindow")
}
@Test func projectPresenceWithoutWindowEvidenceIsClosed() {
    // Logic running with no open project exposes no captioned main/focused window: no project is claimed, no name invented.
    #expect(ProjectPresence.evaluate(title: nil, document: nil, windowSource: nil) == ProjectPresence(open: false, name: nil, source: nil))
    #expect(ProjectPresence.evaluate(title: "   ", document: nil, windowSource: "AXMainWindow").open == false)
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
    #expect(asset?.status == .exported); #expect(asset?.sampleRate.value == 44100); #expect(asset?.channels.value == 1); #expect(asset?.bitDepth.value == 16); #expect(asset?.format.value == "PCM (integer)")
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

@Test func packageStatesTheFullPackageDelivery() {
    let md = AIPackageGenerator().make(snapshot: fixture(), sessionID: "t", delivery: .fullPackage)
    #expect(md.contains("Package schema: `2.7`"))
    #expect(md.contains("DELIVERY: FULL PACKAGE"))
    #expect(md.contains("listen to ALL available WAV audio assets in `audio/`"))
    #expect(!md.contains("DELIVERY: THIS DOCUMENT ONLY"))
}
/// What "Copy for AI" hands over: no JSON, no WAVs. The document must not send the reader looking for files or invite a faked
/// listening report — the earlier text ordered exactly that even when only the Markdown was pasted.
@Test func markdownOnlyDeliveryNeverAsksForFilesOrListening() {
    let md = AIPackageGenerator().make(snapshot: fixture(), sessionID: "t", delivery: .markdownOnly)
    #expect(md.contains("DELIVERY: THIS DOCUMENT ONLY"))
    #expect(md.contains("never state or imply that it listened to the audio"))
    #expect(!md.contains("listen to ALL available WAV audio assets in `audio/`"))
    #expect(!md.contains("First, analyse the audio yourself"))
    #expect(!md.contains("The external AI must listen to the provided WAV files"))
    #expect(md.contains("measured audio metrics")) // the metrics are named as the audio evidence that does exist
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
    #expect(md.contains("- Flags: known: Mute false · Solo false · Record false · Monitoring false · EQ enabled false")) // known booleans share one line per block
    #expect(!md.contains("- Mute: known: false"))
}
/// The document must teach the exact JSON the Review screen decodes: the example it prints has to parse through the app's
/// own MixPlan decoder, or the model learns a shape whose paste later fails with "Invalid MixPlan JSON".
@Test func packageMixPlanExampleParsesThroughTheAppDecoder() throws {
    let md = AIPackageGenerator().make(snapshot: fixture(), sessionID: "t")
    #expect(md.contains("## Mix Plan schema (machine-validated)"))
    #expect(md.contains("Respond in Markdown a human will read")) // stages 1–4 are for the user, not for a parser
    #expect(!md.contains("Return your first response as JSON"))
    let json = try #require(md.components(separatedBy: "```json").last?.components(separatedBy: "```").first)
    let plan = try JSONDecoder().decode(MixPlan.self, from: Data(json.utf8))
    #expect(plan.actions.count == 2)
    #expect(plan.actions.allSatisfy { CommandValidator().implemented.contains($0.action) })
}
/// The AX meter section is empty by nature (Logic publishes no numeric meters), and next to per-file LUFS/peak numbers a bare
/// "LUFS: unavailable" reads as "no loudness data at all". It says which kind of reading it is and where the real numbers are.
@Test func meterSectionDistinguishesItselfFromFileMeasurements() {
    let md = AIPackageGenerator().make(snapshot: fixture(), sessionID: "t")
    #expect(md.contains("## Logic on-screen meters (AX)"))
    #expect(md.contains("not measurements of the audio files"))
    #expect(!md.contains("## Audio / meter data"))
}

// MARK: - Launching another application (Logic Pro, own relaunch)

/// Runs on the main actor, exactly as the buttons do: AppKit delivers `openApplication`'s completion handler on a LaunchServices
/// queue, so a main-actor-isolated handler traps the whole process there. Reaching an ordinary error return proves the launch path
/// reports failures instead of killing the app.
@MainActor @Test(.timeLimit(.minutes(1))) func launchingAMissingApplicationReportsInsteadOfCrashing() async {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).app")
    #expect(await ApplicationLauncher().launch(at: missing) != nil)
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

// MARK: - Local DSP audio metrics (facts about the WAV file, synthesized fixtures)

/// Float32 WAV writer for metric fixtures: exact sample values, no quantization noise. The analyzer under test never writes; only fixtures do.
private func writeFloatWAV(_ url: URL, sampleRate: Double = 48000, channels: [[Float]]) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = channels.map(\.count).min() ?? 0
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for (index, samples) in channels.enumerated() { samples.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) } }
    try file.write(from: buffer)
}
private func sineSamples(_ frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double = 48000) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}
private func analyzeWAV(channels: [[Float]], sampleRate: Double = 48000) throws -> AudioMetrics {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("metrics.wav")
    try writeFloatWAV(url, sampleRate: sampleRate, channels: channels)
    let metrics = AudioMetricsAnalyzer().analyze(fileAt: url)
    try? FileManager.default.removeItem(at: dir)
    return try #require(metrics)
}
/// −18 dBFS RMS sine ⇒ peak amplitude −14.99 dBFS.
private let minus18RMSAmplitude = pow(10.0, -18.0 / 20.0) * 2.0.squareRoot()

@Test func metrics1_referenceSineMatchesTheory() throws {
    let m = try analyzeWAV(channels: [sineSamples(1000, amplitude: minus18RMSAmplitude, seconds: 10)])
    let rms = try #require(m.rmsDBFS.value); let crest = try #require(m.crestFactorDB.value)
    let lufs = try #require(m.integratedLoudnessLUFS.value); let truePeak = try #require(m.truePeakDBTP.value)
    let samplePeak = try #require(m.samplePeakDBFS.value); let bands = try #require(m.spectralBands.value)
    let centroid = try #require(m.spectralCentroidHz.value)
    #expect(abs(rms - -18.0) < 0.2)
    #expect(abs(crest - 3.01) < 0.3)
    #expect(abs(lufs - -18.0) < 1.0) // K-weighting ≈ 0 dB at 1 kHz
    #expect(abs(truePeak - -14.99) < 0.5)
    #expect(abs(samplePeak - -14.99) < 0.2)
    #expect(bands.midPercent > 95) // a 1 kHz tone lives in the 500–2000 Hz band
    #expect(abs(centroid - 1000) < 50)
    #expect(m.silencePercent.value == 0)
    #expect(m.clippedSampleCount.value == 0)
    #expect(m.rmsDBFS.source?.hasSuffix("metrics.wav") == true) // facts point at the analyzed file
}
@Test func metrics2_digitalSilenceStaysHonest() throws {
    // Digital silence has no finite dBFS/LUFS level: those facts are `unavailable`, and the silence map carries the evidence instead.
    let m = try analyzeWAV(channels: [[Float](repeating: 0, count: 5 * 48000)])
    #expect(m.rmsDBFS.state == .unavailable)
    #expect(m.samplePeakDBFS.state == .unavailable)
    #expect(m.truePeakDBTP.state == .unavailable)
    #expect(m.integratedLoudnessLUFS.state == .unavailable)
    #expect(m.crestFactorDB.state == .unavailable)
    #expect(m.spectralBands.state == .unavailable)
    #expect(m.spectralCentroidHz.state == .unavailable)
    let silencePercent = try #require(m.silencePercent.value)
    #expect(silencePercent > 99.5)
    let intervals = try #require(m.silenceIntervals.value)
    let interval = try #require(intervals.first)
    #expect(intervals.count == 1)
    #expect(abs(interval.start - 0) < 0.05)
    #expect(abs(interval.end - 5) < 0.05)
    #expect(m.dcOffsetMean.value == 0)
    #expect(m.clippedSampleCount.value == 0)
}
@Test func metrics3_stereoCorrelationDetectsPhase() throws {
    let left = sineSamples(440, amplitude: 0.5, seconds: 2)
    let antiPhase = try analyzeWAV(channels: [left, left.map { -$0 }])
    let antiCorrelation = try #require(antiPhase.stereoCorrelation.value)
    #expect(abs(antiCorrelation - -1.0) < 0.05)
    #expect(antiPhase.midSideRatioDB.state == .unavailable) // mid energy is exactly zero → no finite ratio
    let inPhase = try analyzeWAV(channels: [left, left])
    let inCorrelation = try #require(inPhase.stereoCorrelation.value)
    #expect(abs(inCorrelation - 1.0) < 0.05)
    #expect(inPhase.midSideRatioDB.state == .unavailable) // side energy is exactly zero → no finite ratio
}
@Test func metrics4_monoFileHasNoStereoFacts() throws {
    let m = try analyzeWAV(channels: [sineSamples(440, amplitude: 0.5, seconds: 1)])
    #expect(m.stereoCorrelation.state == .unavailable)
    #expect(m.midSideRatioDB.state == .unavailable)
}
@Test func metrics5_silenceMapFindsLeadingAndTrailingSilence() throws {
    let silence = [Float](repeating: 0, count: 48000)
    let m = try analyzeWAV(channels: [silence + sineSamples(1000, amplitude: 0.1, seconds: 1) + silence])
    let intervals = try #require(m.silenceIntervals.value)
    #expect(intervals.count == 2)
    #expect(abs(intervals[0].start - 0) < 0.2); #expect(abs(intervals[0].end - 1) < 0.2)
    #expect(abs(intervals[1].start - 2) < 0.2); #expect(abs(intervals[1].end - 3) < 0.2)
    let silencePercent = try #require(m.silencePercent.value)
    #expect(abs(silencePercent - 66.7) < 5)
}
@Test func metrics6_clippingCounterCountsOnlyRealClipRuns() throws {
    // A full-scale 30 Hz sine holds ≥ 3 consecutive samples at |x| ≥ 1 − 1e-4 around every peak; −6 dBFS never comes close.
    let clipped = try analyzeWAV(channels: [sineSamples(30, amplitude: 1.0, seconds: 1)])
    let clippedCount = try #require(clipped.clippedSampleCount.value)
    #expect(clippedCount > 0)
    let clean = try analyzeWAV(channels: [sineSamples(30, amplitude: pow(10.0, -6.0 / 20.0), seconds: 1)])
    #expect(clean.clippedSampleCount.value == 0)
}
@Test func metrics7_dcOffsetIsMeasured() throws {
    let m = try analyzeWAV(channels: [sineSamples(440, amplitude: 0.25, seconds: 1).map { $0 + 0.1 }])
    let dc = try #require(m.dcOffsetMean.value)
    #expect(abs(dc - 0.1) < 0.005)
}
@Test func metrics8_cacheServesUnchangedFilesAndInvalidatesChanged() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFloatWAV(dir.appendingPathComponent("audio_track_001.wav"), channels: [sineSamples(1000, amplitude: 0.1, seconds: 1)])
    let analyzer = AudioMetricsAnalyzer()
    let (first, cache) = analyzer.attach(to: extractAudio(audioSnapshot(), dir: dir), audioDirectory: dir, cache: [:])
    let metrics = try #require(first.first { $0.audioID == "audio_track_001" }?.metrics)
    #expect(first.first { $0.audioID == "audio_track_002" }?.metrics == nil) // requires_user_export never carries metrics
    // A poisoned cache entry with a matching file identity must be served verbatim — proof the file was NOT re-analyzed.
    var poisoned = metrics; poisoned.clippedSampleCount = .known(424242, source: "cache-proof")
    let key = try #require(cache.keys.first)
    let (second, _) = analyzer.attach(to: extractAudio(audioSnapshot(), dir: dir), audioDirectory: dir, cache: [key: poisoned])
    #expect(second.first { $0.audioID == "audio_track_001" }?.metrics?.clippedSampleCount.value == 424242)
    // Changing the file breaks the size+date identity → honest recomputation replaces the stale entry.
    try writeFloatWAV(dir.appendingPathComponent("audio_track_001.wav"), channels: [sineSamples(1000, amplitude: 0.1, seconds: 0.7)])
    let (third, _) = analyzer.attach(to: extractAudio(audioSnapshot(), dir: dir), audioDirectory: dir, cache: [key: poisoned])
    #expect(third.first { $0.audioID == "audio_track_001" }?.metrics?.clippedSampleCount.value == 0)
}
@Test func metrics9_packageRendersMetricsForExportedAssetsOnly() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFloatWAV(dir.appendingPathComponent("audio_track_001.wav"), channels: [sineSamples(1000, amplitude: minus18RMSAmplitude, seconds: 2)])
    let raw = audioSnapshot()
    let (assets, _) = AudioMetricsAnalyzer().attach(to: extractAudio(raw, dir: dir), audioDirectory: dir, cache: [:])
    let md = AIPackageGenerator().make(snapshot: SnapshotNormalizer().normalize(raw), sessionID: "t", audio: assets)
    #expect(md.contains("Package schema: `2.7`"))
    #expect(md.components(separatedBy: "- Audio metrics (computed locally, facts):").count == 2) // exactly one asset is exported
    #expect(md.contains(" LUFS")); #expect(md.contains(" dBTP"))
    #expect(md.contains("Integrated loudness (BS.1770-4): known: -18.0 LUFS"))
    #expect(md.contains("Stereo correlation L/R: unavailable")) // mono WAV — honest state, not a fabricated number
    #expect(md.contains("measured facts about the audio files, not musical judgements")) // External AI Instructions updated
    #expect(md.contains("Regions (1): `region_001`")) // regions name their provenance on one line; pixel geometry is not timing
    #expect(!md.contains("1 region: region_001")) // provenance counts regions; the ID list lives under the asset alone
    #expect(!md.contains("timeline x:"))
    #expect(md.contains("Format: known: PCM (float)")) // "Bit depth: 32" alone is ambiguous; the probe now says which PCM it is
    #expect(md.contains("Technical faults measured from the exported files: none")) // clean file → the digest says so up front
}
/// Measured faults must be visible at the top of Audio Assets, not only buried inside ten per-asset metric blocks: a file
/// with digital clipping and a DC offset gets one digest line naming its track and every fault found.
@Test func metrics12_technicalFaultsAreDigestedUpFront() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var samples = sineSamples(1000, amplitude: 0.5, seconds: 2).map { $0 + 0.01 } // DC offset of 1% full scale
    for index in 1_000..<1_010 { samples[index] = 1.0 } // a 10-sample run on the digital ceiling
    try writeFloatWAV(dir.appendingPathComponent("audio_track_001.wav"), channels: [samples])
    let raw = audioSnapshot()
    let (assets, _) = AudioMetricsAnalyzer().attach(to: extractAudio(raw, dir: dir), audioDirectory: dir, cache: [:])
    let md = AIPackageGenerator().make(snapshot: SnapshotNormalizer().normalize(raw), sessionID: "t", audio: assets)
    #expect(md.contains("Technical faults measured from the exported files (full numbers under each asset):"))
    #expect(md.contains("clipped sample"))
    #expect(md.contains("DC offset 0.01"))
    #expect(!md.contains("Technical faults measured from the exported files: none"))
}
/// A share that rounds to zero used to print "0% silent" directly above its own silence ranges, and a peak just under full scale
/// printed as "-0.0 dBTP". Both read as measurement errors, so a value that rounds to zero keeps a decimal or drops the sign.
@Test func metrics11_sharesAndSignedZeroesReadAsMeasurements() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 20 s of tone with a single 0.2 s silent window: 1 % silence, plus a full-scale sine whose true peak rounds to zero.
    var samples = sineSamples(1000, amplitude: 1, seconds: 20)
    for index in 48_000..<57_600 { samples[index] = 0 }
    try writeFloatWAV(dir.appendingPathComponent("audio_track_001.wav"), channels: [samples])
    let raw = audioSnapshot()
    let (assets, _) = AudioMetricsAnalyzer().attach(to: extractAudio(raw, dir: dir), audioDirectory: dir, cache: [:])
    let md = AIPackageGenerator().make(snapshot: SnapshotNormalizer().normalize(raw), sessionID: "t", audio: assets)
    #expect(!md.contains("-0.0 dBTP")); #expect(!md.contains("-0.0 dBFS")); #expect(!md.contains("-0.0 LUFS")) // a peak just under full scale is not a negative zero
    #expect(md.contains("1% silent") || md.contains("1.0% silent"))
    #expect(md.contains("bass 60–250 Hz")) // every band range carries its unit
}
@Test func metrics10_manifestCarriesMetricsThroughJSON() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeFloatWAV(dir.appendingPathComponent("audio_track_001.wav"), channels: [sineSamples(1000, amplitude: 0.1, seconds: 1)])
    let (assets, _) = AudioMetricsAnalyzer().attach(to: extractAudio(audioSnapshot(), dir: dir), audioDirectory: dir, cache: [:])
    let manifest = AudioManifest(assets: assets)
    let back = try JSONDecoder().decode(AudioManifest.self, from: JSONEncoder().encode(manifest))
    let metrics = try #require(back.assets.first { $0.audioID == "audio_track_001" }?.metrics)
    let rms = try #require(metrics.rmsDBFS.value)
    #expect(abs(rms - -23.01) < 0.2) // amplitude 0.1 sine ⇒ RMS = 20·log10(0.1/√2)
    #expect(back.assets.first { $0.audioID == "audio_track_002" }?.metrics == nil)
}

// MARK: - Self-update

@Test func updaterComparesVersionsNumerically() {
    #expect(AppUpdater.isNewer("v0.2.7", than: "0.2.6"))
    #expect(AppUpdater.isNewer("v0.3.0", than: "0.2.10"))
    #expect(AppUpdater.isNewer("v0.2.10", than: "0.2.9")) // numeric, not lexicographic
    #expect(AppUpdater.isNewer("v0.2.6.1", than: "0.2.6"))
    #expect(!AppUpdater.isNewer("v0.2.6", than: "0.2.6"))
    #expect(!AppUpdater.isNewer("v0.2.5", than: "0.2.6"))
    #expect(!AppUpdater.isNewer("garbage", than: "0.2.6")) // a malformed tag can never look newer
}
@Test func updaterPicksTheAppZipAssetFromReleaseJSON() throws {
    let json = """
    {"tag_name":"v0.2.7","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},{"name":"AI-Mix-Assistant-v0.2.7-macos-universal.zip","browser_download_url":"https://example.com/app.zip"}]}
    """
    let update = try AppUpdater.update(fromReleaseJSON: Data(json.utf8))
    #expect(update.tag == "v0.2.7"); #expect(update.assetName == "AI-Mix-Assistant-v0.2.7-macos-universal.zip"); #expect(update.assetURL.absoluteString == "https://example.com/app.zip")
}
@Test func updaterRefusesAReleaseWithoutTheAppAsset() {
    let json = #"{"tag_name":"v0.2.7","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/n.txt"}]}"#
    #expect(throws: (any Error).self) { try AppUpdater.update(fromReleaseJSON: Data(json.utf8)) }
}
@Test func updaterReadsTheLatestTagFromTheReleasesPageRedirect() {
    // github.com/<repo>/releases/latest redirects to releases/tag/<tag> — no anonymous API rate limit on that path.
    let update = AppUpdater.update(fromLatestReleasePage: URL(string: "https://github.com/Dizrane/AI_mix/releases/tag/v0.2.9")!)
    #expect(update?.tag == "v0.2.9")
    #expect(update?.assetName == "AI-Mix-Assistant-v0.2.9-macos-universal.zip") // the Release workflow's fixed naming scheme
    #expect(update?.assetURL.absoluteString == "https://github.com/Dizrane/AI_mix/releases/download/v0.2.9/AI-Mix-Assistant-v0.2.9-macos-universal.zip")
}
@Test func updaterRejectsRedirectsThatAreNotAVersionTagPage() {
    // A repo without releases lands elsewhere, and a non-numeric tag is not a version: neither may produce an update offer.
    #expect(AppUpdater.update(fromLatestReleasePage: URL(string: "https://github.com/Dizrane/AI_mix/releases")!) == nil)
    #expect(AppUpdater.update(fromLatestReleasePage: URL(string: "https://github.com/Dizrane/AI_mix/releases/tag/garbage")!) == nil)
}
@Test func updaterValidatesTheDownloadedBundleAgainstTheReleaseTag() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let app = temp.appendingPathComponent("AI Mix Assistant.app")
    let executable = app.appendingPathComponent("Contents/MacOS/Demo")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Demo</string>
      <key>CFBundleIdentifier</key><string>test.updater.demo</string>
      <key>CFBundleShortVersionString</key><string>0.9.9</string>
    </dict></plist>
    """
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let updater = AppUpdater()
    #expect(updater.validate(bundle: app, expectedTag: "v0.9.9") == nil)
    #expect(updater.validate(bundle: app, expectedTag: "v1.0.0") != nil) // version mismatch is refused, not installed
}
