import Foundation

/// A discovered Tracks-area header, before linking.
private struct HeaderModel: Sendable { var axPath: String; var name: String; var ordinal: Int?; var facts: HeaderFacts }
/// A discovered Mixer channel strip, before linking.
private struct ChannelModel: Sendable { var axPath: String; var name: String; var facts: ChannelFacts }

struct SnapshotNormalizer: Sendable {
    func normalize(_ raw: RawSnapshot, rawReference: String? = nil) -> NormalizedSnapshot {
        let all = flatten(raw.root) + raw.targets.flatMap { flatten($0.node) }
        /// A project fact is trusted only when a node's own caption (title or description) IS the label — exactly, or as a whole-word prefix ("Key Signature" for "key"). Substring search anywhere used to sign another control's value as `known` ("play" inside "Display", "key" inside "keyboard"); no confident caption means `.unavailable`, never a guess.
        func namedFact(_ labels: [String]) -> Fact<String> {
            func captionMatches(_ caption: String, _ label: String) -> Bool { let text = caption.localizedLowercase; let prefix = label.localizedLowercase; guard text.hasPrefix(prefix) else { return false }; guard text.count > prefix.count else { return true }; let next = text[text.index(text.startIndex, offsetBy: prefix.count)]; return !next.isLetter && !next.isNumber }
            guard let node = all.first(where: { node in labels.contains { label in [node.title, node.description].compactMap { $0 }.contains { captionMatches($0, label) } } }), let value = node.value ?? node.title else { return .unavailable }
            return .known(value, source: node.id)
        }
        let project = ProjectFacts(name: namedFact(["project"]), tempo: bpm(namedFact(["tempo", "bpm"])), timeSignature: namedFact(["time signature"]), keySignature: namedFact(["key signature", "key"]), sampleRate: decimal(namedFact(["sample rate"])), transportState: namedFact(["transport", "play", "stop"]))

        // Discover both AX representations from the application subtree only. `targets` re-inspect the same windows and would double every element under a different path id, so they are excluded here (identical names are still kept distinct as separate objects).
        let rootNodes = flatten(raw.root)
        let headerNodes = uniqueNodes(rootNodes.filter(isTrackHeaderCandidate))
        let channelNodes = uniqueNodes(mixerStripNodes(raw.root))
        let headers = headerNodes.map { HeaderModel(axPath: $0.id, name: trackName($0.title ?? $0.description ?? $0.id), ordinal: parseOrdinal($0.title ?? $0.description), facts: makeHeaderFacts(from: $0)) }
        let channels = channelNodes.map { ChannelModel(axPath: $0.id, name: $0.description ?? $0.id, facts: makeChannelFacts(from: $0)) }
        let (tracks, linking) = linkTracks(headers: headers, channels: channels)

        let trackCandidates = headerNodes.map { candidate($0, kind: "track_header", validation: .known, evidence: ["AXLayoutItem titled 'Track N' with header controls (name field + slider/checkbox/radio)"]) }
        let mixerCandidates = channelNodes.map { candidate($0, kind: "mixer_channel", validation: .known, evidence: ["AXLayoutItem is a direct child of the Mixer AXLayoutArea and contains a volume fader control"]) }
        let candidates = dedupe(trackCandidates + mixerCandidates)
        let diagnostics = updatedDiagnostics(raw.diagnostics, candidates: candidates, tracks: headers.count, channels: channels.count)
        let status: Fact<String> = tracks.isEmpty ? .init(state: .requiresProbe, value: nil, source: "structural discovery") : .known("\(linking.logicalTracks) logical tracks: \(linking.confirmedLinks) confirmed, \(linking.unresolvedHeaders) header-only, \(linking.unresolvedChannels) channel-only, \(linking.ambiguous) ambiguous", source: "structural linking")
        let limitations = ["Header↔channel links are confirmed only by a unique 1:1 name correspondence; shared names stay unmerged (ambiguous). No shared Logic identifier is exposed by AX, so links are never guessed.", "Only values exposed by matching AX controls are emitted; unavailable fields are never inferred."]
        return .init(application: raw.application, completeness: .known("read-only AX structural discovery with track↔channel linking", source: "normalizer"), project: project, tracksStatus: status, tracks: tracks, linking: linking, candidates: candidates, audio: .unavailable, arrangement: .unavailable, probes: raw.diagnostics.probes, diagnostics: diagnostics, limitations: limitations, rawSnapshotReference: rawReference)
    }

    // MARK: Linking

    /// Links a header to a channel only when their name maps 1:1 (unique on both sides). Shared names are ambiguous and never merged; a view with no counterpart is unresolved.
    private func linkTracks(headers: [HeaderModel], channels: [ChannelModel]) -> ([TrackFacts], LinkingDiagnostics) {
        let headersByName = Dictionary(grouping: headers, by: { $0.name.localizedLowercase })
        let channelsByName = Dictionary(grouping: channels, by: { $0.name.localizedLowercase })
        var built: [TrackFacts] = []; var linkedChannelPaths = Set<String>()
        var confirmed = 0, unresolvedH = 0, unresolvedC = 0, ambiguous = 0
        for header in headers {
            let key = header.name.localizedLowercase
            let sameHeaders = headersByName[key] ?? [], sameChannels = channelsByName[key] ?? []
            if sameHeaders.count == 1, sameChannels.count == 1 {
                let channel = sameChannels[0]; linkedChannelPaths.insert(channel.axPath)
                built.append(makeTrack(header: header, channel: channel, status: .confirmed, evidence: ["Unique 1:1 name correspondence: exactly one Tracks-area header and one Mixer channel strip named \"\(header.name)\""]))
                confirmed += 1
            } else if sameChannels.isEmpty {
                built.append(makeTrack(header: header, channel: nil, status: .unresolved, evidence: ["Track header \"\(header.name)\" has no Mixer channel strip in this snapshot; channel facts unavailable"]))
                unresolvedH += 1
            } else {
                built.append(makeTrack(header: header, channel: nil, status: .ambiguous, evidence: ["Name \"\(header.name)\" is shared by \(plural(sameHeaders.count, "header")) and \(plural(sameChannels.count, "channel")); not merged to avoid guessing"]))
                ambiguous += 1
            }
        }
        for channel in channels where !linkedChannelPaths.contains(channel.axPath) {
            let sameHeaders = headersByName[channel.name.localizedLowercase] ?? []
            if sameHeaders.isEmpty {
                built.append(makeTrack(header: nil, channel: channel, status: .unresolved, evidence: ["Mixer channel strip \"\(channel.name)\" has no Tracks-area header (e.g. aux/bus/master/output); kept as an unresolved channel"]))
                unresolvedC += 1
            } else {
                built.append(makeTrack(header: nil, channel: channel, status: .ambiguous, evidence: ["Name \"\(channel.name)\" is shared across headers/channels; channel kept separate, not merged"]))
                ambiguous += 1
            }
        }
        let tracks = assignLogicalIDs(sortTracks(built))
        let linking = LinkingDiagnostics(trackHeaderCandidates: headers.count, channelCandidates: channels.count, confirmedLinks: confirmed, unresolvedHeaders: unresolvedH, unresolvedChannels: unresolvedC, ambiguous: ambiguous, logicalTracks: tracks.count)
        return (tracks, linking)
    }
    private func makeTrack(header: HeaderModel?, channel: ChannelModel?, status: MatchStatus, evidence: [String]) -> TrackFacts {
        let name = header?.name ?? channel?.name ?? "unknown"
        let source = header?.axPath ?? channel?.axPath
        let tentativeID: String
        if let header { tentativeID = header.ordinal.map { "track_\($0)" } ?? "track_\(slug(header.name))" } else { tentativeID = "channel_\(slug(name))" }
        return .init(logicalTrackID: tentativeID, name: .known(name, source: source), type: .init(state: .requiresProbe, value: nil, source: source), matchStatus: status, axPaths: .init(header: header?.axPath, channel: channel?.axPath), header: header?.facts, channel: channel?.facts, linkEvidence: evidence)
    }
    /// Deterministic order: header-bearing tracks by ordinal, then the rest by name, then by AX path — so logical IDs are stable across repeated analysis of the same snapshot.
    private func sortTracks(_ tracks: [TrackFacts]) -> [TrackFacts] {
        tracks.sorted { a, b in
            func key(_ t: TrackFacts) -> (Int, Int, String, String) { (t.axPaths.header == nil ? 1 : 0, t.header?.ordinal.value ?? Int.max, (t.name.value ?? "").localizedLowercase, t.axPaths.header ?? t.axPaths.channel ?? "") }
            let (ka, kb) = (key(a), key(b))
            if ka.0 != kb.0 { return ka.0 < kb.0 }; if ka.1 != kb.1 { return ka.1 < kb.1 }; if ka.2 != kb.2 { return ka.2 < kb.2 }; return ka.3 < kb.3
        }
    }
    private func assignLogicalIDs(_ tracks: [TrackFacts]) -> [TrackFacts] {
        var seen = Set<String>()
        return tracks.map { track in var t = track; var id = t.logicalTrackID; var n = 2; while !seen.insert(id).inserted { id = "\(t.logicalTrackID)_\(n)"; n += 1 }; t.logicalTrackID = id; return t }
    }

    // MARK: Fact extraction

    private func makeHeaderFacts(from node: RawAccessibilityNode) -> HeaderFacts {
        func exact(_ desc: String) -> RawAccessibilityNode? { node.children.first { ($0.description ?? "").localizedCaseInsensitiveCompare(desc) == .orderedSame } }
        let ordinal = parseOrdinal(node.title ?? node.description).map { Fact.known($0, source: node.id) } ?? .unavailable
        let mute = exact("Mute").flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let solo = exact("Solo").flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let record = exact("Record Enable").flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let monitoring = exact("Input Monitoring").flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let volumeRaw = exact("Volume").flatMap { decimalValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let selected = exact("Has Focus").flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        return HeaderFacts(ordinal: ordinal, mute: mute, solo: solo, record: record, monitoring: monitoring, volumeRaw: volumeRaw, selected: selected)
    }
    private func makeChannelFacts(from node: RawAccessibilityNode) -> ChannelFacts {
        func control(_ words: [String]) -> RawAccessibilityNode? { node.children.first { child in words.contains { word in ((child.title ?? child.description) ?? "").localizedCaseInsensitiveContains(word) } } }
        func exactControl(_ desc: String) -> RawAccessibilityNode? { node.children.first { ($0.description ?? "").localizedCaseInsensitiveCompare(desc) == .orderedSame } }
        let volumeText = node.children.first { ($0.description ?? "").localizedCaseInsensitiveContains("volume fader level") }
        let volume = volumeText.flatMap { decimalValue($0.title ?? $0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let pan = control(["pan"]).flatMap { decimalValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let mute = control(["mute"]).flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let solo = control(["solo"]).flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let automation = node.children.first(where: { ($0.description ?? "").localizedCaseInsensitiveContains("automation") }).map { Fact.known($0.description!, source: node.id) } ?? .unavailable
        let input = node.children.first(where: { let text = $0.description ?? ""; return text.localizedCaseInsensitiveContains("input ") && !text.localizedCaseInsensitiveContains("monitoring") }).map { Fact.known($0.description!, source: node.id) } ?? .unavailable
        let record = control(["record"]).flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let monitoring = control(["monitoring"]).flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let channelMode = exactControl("channel mode").flatMap { $0.value }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let eqEnabled = exactControl("EQ").flatMap { boolValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let group = control(["group"]).flatMap { $0.value }.map { Fact.known($0, source: node.id) } ?? .unavailable
        let inputGain = exactControl("input gain").flatMap { decimalValue($0.value) }.map { Fact.known($0, source: node.id) } ?? .unavailable
        return ChannelFacts(volumeDB: volume, pan: pan, mute: mute, solo: solo, automation: automation, input: input, output: .unavailable, record: record, monitoring: monitoring, channelMode: channelMode, eqEnabled: eqEnabled, group: group, inputGain: inputGain, sends: sendSlots(in: node), plugins: pluginSlots(in: node))
    }
    /// Sends are AXButtons labelled with a routing destination (e.g. "Bus 1"). Empty "send button" slots are ignored. Level/pan are not exposed on the button and remain requires_probe.
    private func sendSlots(in node: RawAccessibilityNode) -> [SendFacts] {
        node.children.enumerated().compactMap { index, child in
            guard child.role == "AXButton", let desc = child.description, desc.range(of: "^Bus ", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            return SendFacts(id: "\(node.id).send.\(index)", destination: .known(desc, source: child.id), levelDB: .init(state: .requiresProbe, value: nil, source: child.id), pan: .init(state: .requiresProbe, value: nil, source: child.id))
        }
    }
    /// Insert slots are AXButtons described "audio plug-in". Only loaded slots (a non-empty name) are emitted; bypass and parameters require a targeted probe.
    private func pluginSlots(in node: RawAccessibilityNode) -> [PluginFacts] {
        node.children.filter { $0.role == "AXButton" && ($0.description ?? "").localizedCaseInsensitiveCompare("audio plug-in") == .orderedSame }.enumerated().compactMap { slot, child in
            guard let name = (child.title ?? child.value), !name.isEmpty else { return nil }
            return PluginFacts(id: "\(node.id).plugin.\(slot)", slot: slot, name: .known(name, source: child.id), manufacturer: .unavailable, bypass: .init(state: .requiresProbe, value: nil, source: child.id), parameters: [])
        }
    }

    // MARK: Candidate detection & helpers

    private func isTrackHeaderCandidate(_ node: RawAccessibilityNode) -> Bool { guard node.role == "AXLayoutItem", let title = node.title ?? node.description, title.localizedCaseInsensitiveContains("Track ") else { return false }; let roles = Set(node.children.map(\.role)); return roles.contains("AXTextField") && (roles.contains("AXSlider") || roles.contains("AXCheckBox") || roles.contains("AXRadioButton")) }
    private func isMixerStripCandidate(_ node: RawAccessibilityNode) -> Bool { guard node.role == "AXLayoutItem", node.description?.isEmpty == false else { return false }; let fader = node.children.contains { (($0.title ?? $0.description) ?? "").localizedCaseInsensitiveContains("volume fader") && $0.role == "AXSlider" }; return fader }
    /// Logic's main-window inspector also exposes a "mixer"-described AXLayoutArea, mirroring the SELECTED track's channel strip (and its output). Those mirrors are the same Logic objects seen twice, not new ones, so the area with the most strips is the real Mixer and a smaller area contributes only strips whose names the Mixer does not already show — a name found ONLY there is a real object and is kept. Same-named strips INSIDE one area are distinct objects and all stay (ambiguous by design).
    private func mixerStripNodes(_ node: RawAccessibilityNode) -> [RawAccessibilityNode] {
        var areas: [[RawAccessibilityNode]] = []
        func visit(_ node: RawAccessibilityNode) { if node.role == "AXLayoutArea", node.description?.localizedCaseInsensitiveContains("mixer") == true { areas.append(node.children.filter(isMixerStripCandidate)) }; node.children.forEach(visit) }
        visit(node)
        guard let mainIndex = areas.indices.max(by: { areas[$0].count < areas[$1].count }) else { return [] }
        var strips = areas[mainIndex]
        var names = Set(strips.map { ($0.description ?? $0.id).localizedLowercase })
        for (index, area) in areas.enumerated() where index != mainIndex {
            for strip in area where names.insert((strip.description ?? strip.id).localizedLowercase).inserted { strips.append(strip) }
        }
        return strips
    }
    private func candidate(_ node: RawAccessibilityNode, kind: String, validation: FactState, evidence: [String]) -> DiscoveryCandidate { .init(id: node.id, kind: kind, validation: validation, evidence: evidence, node: node) }
    private func uniqueNodes(_ nodes: [RawAccessibilityNode]) -> [RawAccessibilityNode] { var result: [RawAccessibilityNode] = []; var seen = Set<String>(); for node in nodes where seen.insert(node.id).inserted { result.append(node) }; return result.sorted { $0.id < $1.id } }
    private func dedupe(_ values: [DiscoveryCandidate]) -> [DiscoveryCandidate] { var result: [DiscoveryCandidate] = []; var seen = Set<String>(); for value in values where seen.insert(value.id).inserted { result.append(value) }; return result.sorted { $0.id < $1.id } }
    private func parseOrdinal(_ text: String?) -> Int? { guard let text, let range = text.range(of: "Track\\s+(\\d+)", options: [.regularExpression, .caseInsensitive]) else { return nil }; return Int(text[range].split(whereSeparator: { !$0.isNumber }).first ?? "") }
    private func trackName(_ title: String) -> String { guard let first = title.firstIndex(of: "“"), let last = title.lastIndex(of: "”"), first < last else { return title }; return String(title[title.index(after: first)..<last]) }
    private func slug(_ name: String) -> String { let mapped = name.localizedLowercase.map { $0.isLetter || $0.isNumber ? $0 : "_" }; let joined = String(mapped); let collapsed = joined.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_"); return collapsed.isEmpty ? "unnamed" : collapsed }
    private func boolValue(_ value: String?) -> Bool? { guard let value else { return nil }; if value == "1" || value.localizedCaseInsensitiveCompare("on") == .orderedSame { return true }; if value == "0" || value.localizedCaseInsensitiveCompare("off") == .orderedSame { return false }; return nil }
    private func bpm(_ fact: Fact<String>) -> Fact<Double> { guard let number = decimal(fact).value else { return .init(state: fact.state == .unavailable ? .unavailable : .unknown, value: nil, source: fact.source) }; guard number > 0 && number <= 999 else { return .init(state: .unknown, value: nil, source: fact.source) }; return .known(number, source: fact.source) }
    private func decimal(_ fact: Fact<String>) -> Fact<Double> { guard let value = fact.value, let number = decimalValue(value) else { return .init(state: fact.value == nil ? fact.state : .unknown, value: nil, source: fact.source) }; return .known(number, source: fact.source) }
    private func decimalValue(_ value: String?) -> Double? { guard let value else { return nil }; return value.replacingOccurrences(of: ",", with: ".").split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).compactMap { Double($0) }.first }
    private func updatedDiagnostics(_ source: AXDiscoveryDiagnostics, candidates: [DiscoveryCandidate], tracks: Int, channels: Int) -> AXDiscoveryDiagnostics { var result = source; result.candidatesFound = candidates.count; result.validatedTracks = tracks; result.validatedChannels = channels; result.channelStripsFound = channels; return result }
    private func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
    private func flatten(_ node: RawAccessibilityNode) -> [RawAccessibilityNode] { [node] + node.children.flatMap(flatten) }
}
