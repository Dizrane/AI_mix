import Foundation

/// "1 header" / "2 headers": counts are reported with a real plural everywhere they reach the user, in facts and in the UI alike.
func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

enum FactState: String, Codable, Sendable { case known, unknown, unavailable, requiresProbe = "requires_probe" }

struct Fact<Value: Codable & Sendable>: Codable, Sendable {
    var state: FactState
    var value: Value?
    var source: String?
    static func known(_ value: Value, source: String? = nil) -> Self { .init(state: .known, value: value, source: source) }
    static var unavailable: Self { .init(state: .unavailable, value: nil, source: nil) }
}

struct RawAccessibilityNode: Codable, Identifiable, Sendable {
    var id: String; var role: String; var subrole: String?; var title: String?; var description: String?; var value: String?; var enabled: Bool?; var position: String?; var size: String?; var supportedAttributes: [String]; var parameterizedAttributes: [String]; var actions: [String]; var children: [RawAccessibilityNode]
}

struct AXDiscoveryDiagnostics: Codable, Sendable {
    var windowsFound: Int; var roles: [String: Int]; var mixerDiscovered: Bool; var tracksAreaDiscovered: Bool; var channelStripsFound: Int; var pluginWindowsFound: Int; var candidatesFound: Int = 0; var validatedTracks: Int = 0; var validatedChannels: Int = 0; var probes: [ProbeSummary]
    static let empty = AXDiscoveryDiagnostics(windowsFound: 0, roles: [:], mixerDiscovered: false, tracksAreaDiscovered: false, channelStripsFound: 0, pluginWindowsFound: 0, probes: [])
    enum CodingKeys: String, CodingKey { case windowsFound, roles, mixerDiscovered, tracksAreaDiscovered, channelStripsFound, pluginWindowsFound, candidatesFound, validatedTracks, validatedChannels, probes }
    init(windowsFound: Int, roles: [String: Int], mixerDiscovered: Bool, tracksAreaDiscovered: Bool, channelStripsFound: Int, pluginWindowsFound: Int, candidatesFound: Int = 0, validatedTracks: Int = 0, validatedChannels: Int = 0, probes: [ProbeSummary]) { self.windowsFound = windowsFound; self.roles = roles; self.mixerDiscovered = mixerDiscovered; self.tracksAreaDiscovered = tracksAreaDiscovered; self.channelStripsFound = channelStripsFound; self.pluginWindowsFound = pluginWindowsFound; self.candidatesFound = candidatesFound; self.validatedTracks = validatedTracks; self.validatedChannels = validatedChannels; self.probes = probes }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); windowsFound = try c.decode(Int.self, forKey: .windowsFound); roles = try c.decode([String: Int].self, forKey: .roles); mixerDiscovered = try c.decode(Bool.self, forKey: .mixerDiscovered); tracksAreaDiscovered = try c.decode(Bool.self, forKey: .tracksAreaDiscovered); channelStripsFound = try c.decode(Int.self, forKey: .channelStripsFound); pluginWindowsFound = try c.decode(Int.self, forKey: .pluginWindowsFound); candidatesFound = try c.decodeIfPresent(Int.self, forKey: .candidatesFound) ?? 0; validatedTracks = try c.decodeIfPresent(Int.self, forKey: .validatedTracks) ?? 0; validatedChannels = try c.decodeIfPresent(Int.self, forKey: .validatedChannels) ?? 0; probes = try c.decode([ProbeSummary].self, forKey: .probes) }
}
struct DiscoveryCandidate: Codable, Identifiable, Sendable { var id: String; var kind: String; var validation: FactState; var evidence: [String]; var node: RawAccessibilityNode }
struct ProbeSummary: Codable, Identifiable, Sendable { var id: String { type.rawValue }; var type: ProbeType; var status: FactState; var message: String }
struct RawDiscoveryTarget: Codable, Identifiable, Sendable { var id: String; var kind: String; var node: RawAccessibilityNode }

struct RawSnapshot: Codable, Sendable {
    var schemaVersion = "1.1"; var capturedAt = Date(); var application: ApplicationInfo; var root: RawAccessibilityNode; var targets: [RawDiscoveryTarget] = []; var diagnostics: AXDiscoveryDiagnostics = .empty
}
/// The scanned application plus the documented identity of the window that holds the project: `projectWindowDocument` is the project file
/// URL exposed by `AXDocument`, `projectWindowTitle` the window's own caption, and `projectWindowSource` names the attribute the window
/// itself came from, so a published project fact can cite the exact read path. All nil when Logic exposes no such window.
struct ApplicationInfo: Codable, Sendable { var name: String; var bundleIdentifier: String; var pid: Int32; var projectWindowTitle: String? = nil; var projectWindowDocument: String? = nil; var projectWindowSource: String? = nil }

/// Whether Logic currently shows an open project, decided from the documented identity of its main/focused window. One rule
/// shared by the live Connection indicator and the normalizer's project name: `AXDocument` (the project file URL) is proof and
/// supplies the name; with no document the window's own non-empty `AXTitle` is the next real evidence, published verbatim (an
/// unsaved project has a title but no file yet). No such window, or a caption-less one, means no open project — never a guess.
/// Logic's project chooser is the one window it shows precisely when NO project is open, so its caption ("Choose a Project")
/// is evidence of absence, never a project name — English captions by design, like the whole menu-automation layer.
struct ProjectPresence: Sendable, Equatable {
    var open: Bool; var name: String?; var source: String?
    private static let chooserTitles: Set<String> = ["choose a project", "choose project"]
    static func evaluate(title: String?, document: String?, windowSource: String?) -> ProjectPresence {
        let window = windowSource ?? "AXWindow"
        if let document, let name = documentName(document) { return .init(open: true, name: name, source: "AXDocument of \(window)") }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if chooserTitles.contains(title.localizedLowercase) { return .init(open: false, name: nil, source: nil) }
            return .init(open: true, name: title, source: "AXTitle of \(window)")
        }
        return .init(open: false, name: nil, source: nil)
    }
    private static func documentName(_ document: String) -> String? {
        let url = URL(string: document).flatMap { $0.isFileURL ? $0 : nil } ?? URL(fileURLWithPath: document)
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }
}

struct NormalizedSnapshot: Codable, Sendable {
    var schemaVersion = "1.2"; var capturedAt = Date(); var application: ApplicationInfo
    var completeness: Fact<String>; var project: ProjectFacts; var tracksStatus: Fact<String> = .init(state: .requiresProbe, value: nil, source: nil); var tracks: [TrackFacts]; var linking: LinkingDiagnostics = .empty; var candidates: [DiscoveryCandidate] = []; var audio: AudioFacts = .unavailable; var arrangement: ArrangementFacts = .unavailable; var probes: [ProbeSummary] = []; var diagnostics: AXDiscoveryDiagnostics = .empty; var limitations: [String] = []; var rawSnapshotReference: String?
}
struct AudioFacts: Codable, Sendable { var peak: Fact<Double>; var rms: Fact<Double>; var lufs: Fact<Double>; var gainReduction: Fact<Double>; var inputLevel: Fact<Double>; var outputLevel: Fact<Double>; static let unavailable = AudioFacts(peak: .unavailable, rms: .unavailable, lufs: .unavailable, gainReduction: .unavailable, inputLevel: .unavailable, outputLevel: .unavailable) }
struct ArrangementFacts: Codable, Sendable { var regions: Fact<String>; var markers: Fact<String>; var sections: Fact<String>; static let unavailable = ArrangementFacts(regions: .unavailable, markers: .unavailable, sections: .unavailable) }
struct ProjectFacts: Codable, Sendable {
    var name: Fact<String>; var tempo: Fact<Double>; var timeSignature: Fact<String>; var keySignature: Fact<String>; var sampleRate: Fact<Double>; var transportState: Fact<String>
    static var empty: Self { .init(name: .unavailable, tempo: .unavailable, timeSignature: .unavailable, keySignature: .unavailable, sampleRate: .unavailable, transportState: .unavailable) }
}
/// Whether a Tracks-area header and a Mixer channel strip were linked into one Logic object.
enum MatchStatus: String, Codable, Sendable { case confirmed, unresolved, ambiguous }
/// AX paths are technical identifiers valid only for the current snapshot; the logical track_id is separate and stable.
struct TrackAXPaths: Codable, Sendable { var header: String?; var channel: String? }
/// A normalized Logic track. `header` and `channel` are two views of one object; either may be absent when a link is not confirmed.
struct TrackFacts: Codable, Identifiable, Sendable {
    var logicalTrackID: String; var name: Fact<String>; var type: Fact<String>; var matchStatus: MatchStatus; var axPaths: TrackAXPaths; var header: HeaderFacts?; var channel: ChannelFacts?; var linkEvidence: [String] = []
    var id: String { logicalTrackID }
}
/// Facts exposed by a Tracks-area track header (arrange view). Distinct from the mixer channel strip.
struct HeaderFacts: Codable, Sendable {
    var ordinal: Fact<Int>; var mute: Fact<Bool>; var solo: Fact<Bool>; var record: Fact<Bool>; var monitoring: Fact<Bool>; var volumeRaw: Fact<Double>; var selected: Fact<Bool>
    static let unavailable = HeaderFacts(ordinal: .unavailable, mute: .unavailable, solo: .unavailable, record: .unavailable, monitoring: .unavailable, volumeRaw: .unavailable, selected: .unavailable)
}
struct ChannelFacts: Codable, Sendable { var volumeDB: Fact<Double>; var pan: Fact<Double>; var mute: Fact<Bool>; var solo: Fact<Bool>; var automation: Fact<String>; var input: Fact<String>; var output: Fact<String>; var record: Fact<Bool> = .unavailable; var monitoring: Fact<Bool> = .unavailable; var channelMode: Fact<String> = .unavailable; var eqEnabled: Fact<Bool> = .unavailable; var group: Fact<String> = .unavailable; var inputGain: Fact<Double> = .unavailable; var sends: [SendFacts] = []; var routingButtons: [RoutingButtonFacts] = []; var plugins: [PluginFacts] = [] }
struct LinkingDiagnostics: Codable, Sendable {
    var trackHeaderCandidates: Int; var channelCandidates: Int; var confirmedLinks: Int; var unresolvedHeaders: Int; var unresolvedChannels: Int; var ambiguous: Int; var logicalTracks: Int
    static let empty = LinkingDiagnostics(trackHeaderCandidates: 0, channelCandidates: 0, confirmedLinks: 0, unresolvedHeaders: 0, unresolvedChannels: 0, ambiguous: 0, logicalTracks: 0)
}
struct PluginFacts: Codable, Identifiable, Sendable { var id: String; var slot: Int; var name: Fact<String>; var manufacturer: Fact<String>; var bypass: Fact<Bool>; var parameters: [PluginParameter] }
struct PluginParameter: Codable, Identifiable, Sendable { var id: String; var name: String; var value: Fact<Double>; var range: ClosedRange<Double>?; var unit: String? }
/// The KIND of a routing destination, derived from the caption grammar Logic itself uses for routing slots — the same
/// patterns the routing classifier accepts as destinations. "Bus N" is an internal bus; "St Out" / "Stereo Out(put)" the
/// project's stereo output; "Output" / "Output N(-M)" a hardware output (pair); "Input N(-M)" a hardware input;
/// "No Output" / "No Input" an explicitly disconnected slot. A caption matching no pattern returns nil — never a guess.
enum RoutingDestinationKind: String, Codable, Sendable {
    case bus, stereoOutput = "stereo_output", hardwareOutput = "hardware_output", hardwareInput = "hardware_input", notConnected = "not_connected"
    static func classify(_ destination: String) -> RoutingDestinationKind? {
        func matches(_ pattern: String) -> Bool { destination.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if matches("^Bus \\d+$") { return .bus }
        if matches("^St(ereo)? Out(put)?$") { return .stereoOutput }
        if matches("^Output( \\d+(-\\d+)?)?$") { return .hardwareOutput }
        if matches("^Input \\d+(-\\d+)?$") { return .hardwareInput }
        if matches("^No (Output|Input)$") { return .notConnected }
        return nil
    }
    /// Short human label for UI summaries; the raw value is the machine-readable form used in the AI package.
    var label: String { switch self { case .bus: "Bus"; case .stereoOutput: "Stereo Out"; case .hardwareOutput: "hardware out"; case .hardwareInput: "hardware in"; case .notConnected: "none" } }
}

/// A mixer-strip AXButton naming a routing destination ("Bus 1", "St Out") whose slot could NOT be proven. An EMPTY send
/// slot, the output slot and an aux's input slot share the same anonymous button shape over AX, so a destination button is
/// classified only by structural evidence (its documented neighbour in the strip); a button with no such evidence keeps
/// `slotKind = requires_probe` and must never be read as a send.
struct RoutingButtonFacts: Codable, Identifiable, Sendable { var id: String; var destination: Fact<String>; var slotKind: Fact<String> }
/// A proven, occupied send slot. Logic renders an occupied send as an AXGroup captioned with the destination that contains a
/// "bypass" checkbox — a shape no other strip control has (the automation group's checkbox is captioned "automation") — so the
/// destination and bypass are facts. The adjacent "send knob" slider exposes only a unitless raw value and no pan control is
/// exposed at all, so level and pan stay `requires_probe`.
struct SendFacts: Codable, Identifiable, Sendable { var id: String; var destination: Fact<String>; var bypass: Fact<Bool>; var level: Fact<Double>; var pan: Fact<Double> }

enum ProbeType: String, Codable, CaseIterable, Sendable { case inspectTrack = "inspect_track", inspectPlugin = "inspect_plugin", inspectPluginParameters = "inspect_plugin_parameters", inspectChannelStrip = "inspect_channel_strip", inspectTrackRegions = "inspect_track_regions", inspectMixer = "inspect_mixer", inspectSelectedTrack = "inspect_selected_track", inspectAudioMeter = "inspect_audio_meter" }
struct ProbeRequest: Codable, Sendable { var type: ProbeType; var trackID: String?; var trackName: String?; var pluginName: String? }
struct ProbeResult: Codable, Sendable { var request: ProbeRequest; var status: FactState; var snapshot: RawSnapshot?; var message: String }

enum OperationMode: String, Codable, CaseIterable, Sendable { case readOnly = "READ ONLY", dryRun = "DRY RUN", live = "LIVE" }
