import Foundation

/// One derived signal-flow edge: the channel `from` feeds the channel `to` through the internal bus `viaBus`.
/// An edge is the pure join of two facts already proven in the snapshot — the feeder's `known` bus output or
/// send destination, and the receiver's `known` bus input naming the same bus — and both facts' sources are
/// kept, so every edge can cite the exact evidence it was derived from.
struct SignalFlowEdge: Sendable, Equatable {
    /// Which proven feeder fact the edge came from: the channel's output slot, or an occupied send.
    enum Kind: String, Sendable { case output, send }
    var from: String; var to: String; var viaBus: String; var kind: Kind
    var fromSource: String?; var toSource: String?
}

/// The project's bus wiring, derived purely from the routing facts of one normalized snapshot — no new reads
/// from Logic and no state, modelled on `PackageReadiness`. Edges connect only `known` facts whose destination
/// kind is `bus` (captions compared case-insensitively); a bus legitimately fans out, so several receivers of
/// one bus mean several edges, never an ambiguity. A bus with only one known end is not guessed into an edge
/// and not dropped: it is published under `unresolvedBuses` naming the end that IS known. `requires_probe`
/// routing buttons contribute nothing (their slot is unproven), and an output to the stereo output is a
/// terminal, not an edge — the stereo output channel itself, when the snapshot contains one, is `terminal`.
struct SignalFlowGraph: Sendable {
    struct Terminal: Sendable, Equatable { var trackID: String; var name: String }
    var edges: [SignalFlowEdge]
    var unresolvedBuses: [String]
    var terminal: Terminal?

    static func build(tracks: [TrackFacts]) -> SignalFlowGraph {
        /// A caption is bus evidence only when the fact is `known` AND Logic's own caption grammar says it is a bus.
        func bus(_ fact: Fact<String>) -> String? { guard fact.state == .known, let value = fact.value, RoutingDestinationKind.classify(value) == .bus else { return nil }; return value }
        struct BusEnd { var trackID: String; var bus: String; var source: String? }
        var feeders: [(end: BusEnd, kind: SignalFlowEdge.Kind)] = []
        var receivers: [BusEnd] = []
        for track in tracks {
            guard let channel = track.channel else { continue }
            if let caption = bus(channel.output) { feeders.append((BusEnd(trackID: track.logicalTrackID, bus: caption, source: channel.output.source), .output)) }
            for send in channel.sends { if let caption = bus(send.destination) { feeders.append((BusEnd(trackID: track.logicalTrackID, bus: caption, source: send.destination.source), .send)) } }
            if let caption = bus(channel.input) { receivers.append(BusEnd(trackID: track.logicalTrackID, bus: caption, source: channel.input.source)) }
        }
        let receiversByBus = Dictionary(grouping: receivers, by: { $0.bus.localizedLowercase })
        let edges = feeders.flatMap { feeder in (receiversByBus[feeder.end.bus.localizedLowercase] ?? []).map { receiver in SignalFlowEdge(from: feeder.end.trackID, to: receiver.trackID, viaBus: feeder.end.bus, kind: feeder.kind, fromSource: feeder.end.source, toSource: receiver.source) } }
        // A bus with one known end is a fact about incompleteness, published as such — never raw material for a guess.
        let feedersByBus = Dictionary(grouping: feeders, by: { $0.end.bus.localizedLowercase })
        var unresolved: [String] = []
        for (key, group) in feedersByBus where receiversByBus[key] == nil {
            let ends = group.map { "\($0.end.trackID) (\($0.kind.rawValue))" }.joined(separator: " and ")
            unresolved.append("\(group[0].end.bus): fed by \(ends), no channel with this input in the snapshot")
        }
        for (key, group) in receiversByBus where feedersByBus[key] == nil {
            let ends = group.map(\.trackID).joined(separator: " and ")
            unresolved.append("\(group[0].bus): input of \(ends), no channel routed into this bus in the snapshot")
        }
        let terminal = tracks.first { track in track.name.value.map { RoutingDestinationKind.classify($0) == .stereoOutput } == true }
            .map { Terminal(trackID: $0.logicalTrackID, name: $0.name.value ?? $0.logicalTrackID) }
        return SignalFlowGraph(edges: edges, unresolvedBuses: unresolved.sorted(), terminal: terminal)
    }
}
