import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Named failures

/// Every way an offline render can refuse, each naming exactly what failed and what was expected. The engine is a
/// prototype, so nothing is repaired silently: a mismatched sample rate is an error (never a resample), a missing
/// plugin is an error (never a bypass), an unresolved parameter is an error (never a skip).
enum MixEngineError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(found: String, supported: String)
    case emptyGraph
    case duplicateTrackName(String)
    case duplicateBusName(String)
    case unknownSendBus(track: String, bus: String, known: [String])
    case inputFileUnreadable(track: String, path: String)
    case emptyInputFile(track: String, path: String)
    case unsupportedChannelCount(track: String, path: String, channels: Int)
    case sampleRateMismatch(track: String, path: String, rate: Double, expected: Double)
    case outputWouldOverwriteInput(path: String)
    case insertWithoutIdentity(insert: String)
    case invalidComponentIdentifier(insert: String, identifier: String)
    case notAnEffect(insert: String, identifier: String)
    case pluginNotInstalled(insert: String, requested: String)
    case ambiguousPluginName(insert: String, name: String, matches: [String])
    case instantiationFailed(insert: String, component: String, reason: String)
    case parameterTreeUnavailable(insert: String, requested: [String])
    case parametersNotResolved(insert: String, keys: [String], available: [String])
    case ambiguousParameter(insert: String, key: String, matches: [String])
    case engineStartFailed(reason: String)
    case alignmentDelayUnavailable(reason: String)
    case renderFailed(reason: String)
    case outputFileUnwritable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported): "MixGraph schemaVersion \"\(found)\" is not supported (this engine understands \"\(supported)\")."
        case .emptyGraph: "The MixGraph contains no tracks — there is nothing to render."
        case .duplicateTrackName(let name): "Track name \"\(name)\" is used more than once; names must be unique so reports and errors are unambiguous."
        case .duplicateBusName(let name): "Bus name \"\(name)\" is used more than once; sends address buses by name, so names must be unique."
        case .unknownSendBus(let track, let bus, let known): "Track \"\(track)\" sends to bus \"\(bus)\", which the graph does not define (known buses: \(known.isEmpty ? "none" : known.joined(separator: ", ")))."
        case .inputFileUnreadable(let track, let path): "Track \"\(track)\": the input WAV at \(path) cannot be opened for reading."
        case .emptyInputFile(let track, let path): "Track \"\(track)\": the input WAV at \(path) contains no audio frames."
        case .unsupportedChannelCount(let track, let path, let channels): "Track \"\(track)\": \(path) has \(channels) channels; this prototype renders mono and stereo inputs only."
        case .sampleRateMismatch(let track, let path, let rate, let expected): "Track \"\(track)\": \(path) is at \(rate) Hz but the mix runs at \(expected) Hz (taken from the first track). This prototype refuses to resample — re-export the file at the mix rate."
        case .outputWouldOverwriteInput(let path): "The output file \(path) is also an input of the graph; rendering would destroy its own source."
        case .insertWithoutIdentity(let insert): "\(insert) names neither a component identifier nor a component name — the plugin cannot be identified."
        case .invalidComponentIdentifier(let insert, let identifier): "\(insert): \"\(identifier)\" is not a valid FourCC component identifier (expected \"type/subtype/manufacturer\", e.g. \"aufx/pmeq/appl\")."
        case .notAnEffect(let insert, let identifier): "\(insert): \(identifier) is not an audio effect (type \"aufx\"); this prototype loads effects only."
        case .pluginNotInstalled(let insert, let requested): "\(insert): no installed Audio Unit effect matches \"\(requested)\" — the plugin is not installed on this machine."
        case .ambiguousPluginName(let insert, let name, let matches): "\(insert): the name \"\(name)\" matches \(plural(matches.count, "installed effect")) (\(matches.joined(separator: ", "))); use the exact component identifier instead."
        case .instantiationFailed(let insert, let component, let reason): "\(insert): the installed component \(component) failed to instantiate: \(reason)"
        case .parameterTreeUnavailable(let insert, let requested): "\(insert): the unit exposes no parameter tree, so the requested parameters (\(requested.joined(separator: ", "))) cannot be applied."
        case .parametersNotResolved(let insert, let keys, let available): "\(insert): \(plural(keys.count, "parameter")) could not be resolved: \(keys.joined(separator: ", ")). The unit exposes: \(available.joined(separator: "; "))."
        case .ambiguousParameter(let insert, let key, let matches): "\(insert): the display name \"\(key)\" matches \(plural(matches.count, "parameter")) (\(matches.joined(separator: ", "))); use the parameter identifier or address instead."
        case .engineStartFailed(let reason): "The offline audio engine failed to start: \(reason)"
        case .alignmentDelayUnavailable(let reason): "The sample-exact alignment delay could not be set up: \(reason). Without it, parallel paths with unequal insert latencies would land misaligned in the sum, so the render refuses instead of guessing."
        case .renderFailed(let reason): "Offline rendering failed: \(reason)"
        case .outputFileUnwritable(let path, let reason): "The output file \(path) cannot be created: \(reason)"
        }
    }
}

// MARK: - Result

/// One parameter the engine set on an Audio Unit: what the graph asked, what the parameter tree resolved it to, and
/// what the parameter reported when read back immediately after the write. `verified` is a plain tolerance comparison
/// (the unit may legitimately quantize); the read-back value is always reported so nothing diverges silently.
struct MixAppliedParameter: Sendable {
    var key: String
    var resolvedIdentifier: String
    var resolvedName: String
    var requestedValue: Double
    var readBackValue: Double
    var verified: Bool
}

/// One insert that was really loaded: where it sits, what the graph requested, which installed component it resolved
/// to, the full parameter write/read-back report, and the latency the unit itself reported. The latency is read from
/// `auAudioUnit.latency` only after the engine allocated render resources — the one moment the number is real — so
/// every latency figure in a report traces to the unit's own statement, never to a guess.
struct MixInsertReport: Sendable {
    var location: String
    var requested: String
    var resolvedName: String
    var resolvedIdentifier: String
    var parameters: [MixAppliedParameter]
    /// `auAudioUnit.latency` in seconds, read after render resources were allocated.
    var latencySeconds: Double
    /// The reported latency in whole frames at the mix rate — the part the render really compensates; a fractional
    /// remainder, if any, is named in the result's `notes`.
    var latencyFrames: Int
}

/// The engine's answer: where the mix landed and the measured facts about it. The metrics come from the same local
/// BS.1770-4 analyzer the app uses for exported WAVs; the engine only reports numbers — what is acceptable is the
/// caller's judgement. `busMetrics` is best effort (manual-rendering taps carry no delivery guarantee) and `notes`
/// names what was and was not measured. `renderedFrames` counts the frames written to the mix file: the graph's own
/// latency (`compensatedLatencyFrames`) is rendered in addition and trimmed from the head, so the file stays
/// positionally at t=0 with its full tail. Anything the compensation could NOT align — a fractional latency a unit
/// reported — is named in `notes` instead of being silently absorbed.
struct MixRenderResult: Sendable {
    var outputURL: URL
    var sampleRate: Double
    var renderedFrames: Int
    /// Total graph latency in frames — slowest track chain + slowest bus chain + master chain, every summand traced
    /// to `auAudioUnit.latency` — that was aligned across all parallel paths and trimmed from the written mix.
    var compensatedLatencyFrames: Int
    var inserts: [MixInsertReport]
    var mixMetrics: AudioMetrics?
    var busMetrics: [String: AudioMetrics]
    var notes: [String]
}

// MARK: - Engine

/// Offline mixing engine: renders a `MixGraph` through AVAudioEngine in manual rendering mode, entirely outside any
/// DAW. Topology per track: AVAudioPlayerNode (scheduled at t=0) → insert AVAudioUnits (connected at the file's own
/// format) → a per-track AVAudioMixerNode carrying the track's gain (`outputVolume`) and pan (`pan`). AVAudioEngine's
/// connection API has no per-connection gain, so a send is a dedicated AVAudioMixerNode: the track mixer's output
/// fans out (one `connect(_:to:fromBus:format:)` call with multiple AVAudioConnectionPoints) to the master sum AND to
/// one send mixer per send, whose `outputVolume` is the send level and `pan` the send pan; the send mixer feeds the
/// bus. Sends are therefore post-fader and post-pan by construction. Each bus is a collector mixer → its inserts → an
/// output mixer carrying the bus gain; master is the same shape, its gain applied after the master inserts as a final
/// trim. The mix sample rate is the first input file's rate — a file at any other rate is a named error, never a
/// resample. Insert latency IS compensated, sample-accurately and only from numbers the units themselves report:
/// after `start()` has allocated render resources (the one moment `auAudioUnit.latency` is real), the engine plans
/// with `MixLatencyMath` — a lower-latency track starts later by scheduled silence instead of gaining DSP in its
/// path, send fan-outs are re-converged by bit-exact whole-frame delays (`SampleExactDelayAudioUnit`) on the direct
/// branch and on each bus output, and the graph's total latency is rendered in addition and trimmed from the head so
/// the written mix stays at t=0. What cannot be compensated (a fractional reported latency) is named in `notes`,
/// never silently misaligned.
struct MixEngine {
    /// Sample format of the written mix file; rendering itself is always float32.
    enum OutputSampleFormat: Sendable { case float32, int24 }
    struct Options: Sendable {
        /// Extra seconds rendered after the longest input ends, so reverb/delay tails are captured instead of cut.
        var tailSeconds: Double = 2
        var output: OutputSampleFormat = .float32
        /// When true, each bus output is also measured through a render tap — best effort, reported in `notes`.
        var measureBuses: Bool = false
        init(tailSeconds: Double = 2, output: OutputSampleFormat = .float32, measureBuses: Bool = false) {
            self.tailSeconds = tailSeconds; self.output = output; self.measureBuses = measureBuses
        }
    }

    private static let maximumRenderFrames: AVAudioFrameCount = 4096
    private static let instantiateTimeoutSeconds = 15.0

    /// Renders the graph to `outputURL` and returns the measured result. Relative track paths resolve against
    /// `folder`. Throws `MixEngineError` naming the first thing that cannot be done honestly.
    func render(graph: MixGraph, folder: URL, outputURL: URL, options: Options = .init()) throws -> MixRenderResult {
        guard graph.schemaVersion == MixGraph.supportedVersion else { throw MixEngineError.unsupportedSchemaVersion(found: graph.schemaVersion, supported: MixGraph.supportedVersion) }
        guard !graph.tracks.isEmpty else { throw MixEngineError.emptyGraph }
        if let duplicate = firstDuplicate(graph.tracks.map(\.name)) { throw MixEngineError.duplicateTrackName(duplicate) }
        if let duplicate = firstDuplicate(graph.buses.map(\.name)) { throw MixEngineError.duplicateBusName(duplicate) }
        let busNames = Set(graph.buses.map(\.name))
        for track in graph.tracks {
            for send in track.sends where !busNames.contains(send.bus) {
                throw MixEngineError.unknownSendBus(track: track.name, bus: send.bus, known: graph.buses.map(\.name))
            }
        }

        // Input files: the first file's sample rate is the mix rate; anything else is a named refusal.
        var files: [(track: MixGraphTrack, file: AVAudioFile)] = []
        for track in graph.tracks {
            // Deliberately not URL(fileURLWithPath:relativeTo:): a base URL without a trailing slash silently drops
            // its last path component during RFC 3986 resolution, sending the lookup into the folder's parent.
            let url = (track.file.hasPrefix("/") ? URL(fileURLWithPath: track.file) : folder.appendingPathComponent(track.file)).standardizedFileURL
            guard url.path != outputURL.standardizedFileURL.path else { throw MixEngineError.outputWouldOverwriteInput(path: url.path) }
            guard let file = try? AVAudioFile(forReading: url) else { throw MixEngineError.inputFileUnreadable(track: track.name, path: url.path) }
            guard file.length > 0 else { throw MixEngineError.emptyInputFile(track: track.name, path: url.path) }
            let channels = Int(file.processingFormat.channelCount)
            guard channels == 1 || channels == 2 else { throw MixEngineError.unsupportedChannelCount(track: track.name, path: url.path, channels: channels) }
            if let expected = files.first?.file.processingFormat.sampleRate, file.processingFormat.sampleRate != expected {
                throw MixEngineError.sampleRateMismatch(track: track.name, path: url.path, rate: file.processingFormat.sampleRate, expected: expected)
            }
            files.append((track, file))
        }
        let sampleRate = files[0].file.processingFormat.sampleRate
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { throw MixEngineError.renderFailed(reason: "no stereo processing format for \(sampleRate) Hz") }

        // Manual rendering is enabled BEFORE any node is attached, so no connection ever consults audio hardware —
        // the render works identically on a Mac with no output device (CI runners included).
        let engine = AVAudioEngine()
        do { try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: Self.maximumRenderFrames) }
        catch { throw MixEngineError.engineStartFailed(reason: error.localizedDescription) }

        var insertReports: [MixInsertReport] = []
        var loadedInserts: [(chain: MixChainKey, reportIndex: Int, unit: AVAudioUnit)] = []
        var notes: [String] = []

        func buildChain(after source: AVAudioNode, sourceFormat: AVAudioFormat, inserts: [MixGraphInsert], owner: String, chain: MixChainKey) throws -> AVAudioNode {
            var tail = source
            for (index, insert) in inserts.enumerated() {
                let location = "\(owner) insert \(index + 1)"
                let component = try resolveComponent(insert: insert, location: location)
                let unit = try instantiate(component: component, location: location)
                let parameters = try apply(parameters: insert.parameters, to: unit, location: location)
                engine.attach(unit)
                engine.connect(tail, to: unit, format: sourceFormat)
                insertReports.append(.init(location: location, requested: insert.component ?? insert.name ?? "?", resolvedName: component.name, resolvedIdentifier: identifierString(component.audioComponentDescription), parameters: parameters, latencySeconds: 0, latencyFrames: 0))
                loadedInserts.append((chain, insertReports.count - 1, unit))
                tail = unit
            }
            return tail
        }

        // Buses first, so track sends have a destination to connect to. Branch-alignment delays exist only when a
        // bus carries inserts: only then can a track's fan-out reach the master sum through two chains of different
        // latency, which no player offset can fix (an offset moves both branches equally). The delays are attached
        // now, at zero, because their real values are unknowable until render resources exist; they are configured
        // after `start()`, before the first render call.
        let masterCollector = AVAudioMixerNode()
        engine.attach(masterCollector)
        let needsBranchDelays = graph.buses.contains { !$0.inserts.isEmpty }
        var directCollector: AVAudioMixerNode?
        var directDelay: SampleExactDelayAudioUnit?
        var busDelays: [String: SampleExactDelayAudioUnit] = [:]
        if needsBranchDelays {
            let collector = AVAudioMixerNode()
            let delay = try SampleExactDelayAudioUnit.makeNode()
            engine.attach(collector)
            engine.attach(delay.node)
            engine.connect(collector, to: delay.node, format: stereo)
            engine.connect(delay.node, to: masterCollector, format: stereo)
            directCollector = collector
            directDelay = delay.unit
        }
        var busInputs: [String: AVAudioMixerNode] = [:]
        var busOutputs: [String: AVAudioMixerNode] = [:]
        for bus in graph.buses {
            let input = AVAudioMixerNode(); let output = AVAudioMixerNode()
            engine.attach(input); engine.attach(output)
            let chainEnd = try buildChain(after: input, sourceFormat: stereo, inserts: bus.inserts, owner: "bus \"\(bus.name)\"", chain: .bus(bus.name))
            engine.connect(chainEnd, to: output, format: stereo)
            output.outputVolume = Float(linearGain(bus.gainDB))
            if needsBranchDelays {
                let delay = try SampleExactDelayAudioUnit.makeNode()
                engine.attach(delay.node)
                engine.connect(output, to: delay.node, format: stereo)
                engine.connect(delay.node, to: masterCollector, format: stereo)
                busDelays[bus.name] = delay.unit
            } else {
                engine.connect(output, to: masterCollector, format: stereo)
            }
            busInputs[bus.name] = input
            busOutputs[bus.name] = output
        }

        var players: [(player: AVAudioPlayerNode, file: AVAudioFile, track: String)] = []
        for (track, file) in files {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let fileFormat = file.processingFormat
            let chainEnd = try buildChain(after: player, sourceFormat: fileFormat, inserts: track.inserts, owner: "track \"\(track.name)\"", chain: .track(track.name))
            let trackMixer = AVAudioMixerNode()
            engine.attach(trackMixer)
            engine.connect(chainEnd, to: trackMixer, format: fileFormat)
            trackMixer.outputVolume = Float(linearGain(track.gainDB))
            trackMixer.pan = Float(track.pan)
            let directSum = directCollector ?? masterCollector
            var destinations = [AVAudioConnectionPoint(node: directSum, bus: directSum.nextAvailableInputBus)]
            var sendMixers: [(mixer: AVAudioMixerNode, bus: String)] = []
            for send in track.sends {
                let sendMixer = AVAudioMixerNode()
                engine.attach(sendMixer)
                sendMixer.outputVolume = Float(linearGain(send.levelDB))
                sendMixer.pan = Float(send.pan)
                destinations.append(AVAudioConnectionPoint(node: sendMixer, bus: 0))
                sendMixers.append((sendMixer, send.bus))
            }
            engine.connect(trackMixer, to: destinations, fromBus: 0, format: stereo)
            for (sendMixer, busName) in sendMixers {
                guard let busInput = busInputs[busName] else { continue } // proven present by the upfront validation
                engine.connect(sendMixer, to: busInput, format: stereo)
            }
            players.append((player, file, track.name))
        }

        // Master: inserts on the full sum, then the gain as a final trim on the way into the output node.
        let masterChainEnd = try buildChain(after: masterCollector, sourceFormat: stereo, inserts: graph.master.inserts, owner: "master", chain: .master)
        let masterOut = AVAudioMixerNode()
        engine.attach(masterOut)
        engine.connect(masterChainEnd, to: masterOut, format: stereo)
        masterOut.outputVolume = Float(linearGain(graph.master.gainDB))
        engine.connect(masterOut, to: engine.outputNode, format: stereo)

        var busTaps: [(name: String, accumulator: BusTapAccumulator)] = []
        if options.measureBuses {
            for (name, output) in busOutputs.sorted(by: { $0.key < $1.key }) {
                let accumulator = BusTapAccumulator()
                output.installTap(onBus: 0, bufferSize: Self.maximumRenderFrames, format: nil) { buffer, _ in accumulator.append(buffer) }
                busTaps.append((name, accumulator))
            }
        }

        let tailFrames = AVAudioFramePosition((options.tailSeconds * sampleRate).rounded())
        let totalFrames = files.map { $0.file.length }.max()! + max(0, tailFrames)

        var outputFile: AVAudioFile?
        do { outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings(sampleRate: sampleRate, format: options.output)) }
        catch { throw MixEngineError.outputFileUnwritable(path: outputURL.path, reason: error.localizedDescription) }

        do { try engine.start() } catch { throw MixEngineError.engineStartFailed(reason: error.localizedDescription) }

        // A unit's reported latency is real only once its render resources exist, so the numbers are read here —
        // after `start()` has allocated the whole graph — and only now can offsets, branch delays and the output trim
        // be planned. A fractional remainder no whole-frame alignment can absorb is named instead of dropped.
        var trackChainFrames = Dictionary(uniqueKeysWithValues: graph.tracks.map { ($0.name, 0) })
        var busChainFrames = Dictionary(uniqueKeysWithValues: graph.buses.map { ($0.name, 0) })
        var masterChainFrames = 0
        for loaded in loadedInserts {
            let seconds = loaded.unit.auAudioUnit.latency
            let latency = MixLatencyMath.insertLatency(reportedSeconds: seconds, sampleRate: sampleRate)
            insertReports[loaded.reportIndex].latencySeconds = seconds
            insertReports[loaded.reportIndex].latencyFrames = latency.frames
            if abs(latency.residualSamples) > MixLatencyMath.residualNoteThresholdSamples {
                notes.append("\(insertReports[loaded.reportIndex].location): the unit reports \(String(format: "%.6f", seconds)) s of latency (\(String(format: "%.3f", seconds * sampleRate)) samples at \(Int(sampleRate)) Hz); only the whole-frame part (\(latency.frames)) is compensated — the \(String(format: "%.3f", latency.residualSamples))-sample remainder cannot be aligned by integer scheduling and stays uncompensated.")
            }
            switch loaded.chain {
            case .track(let name): trackChainFrames[name, default: 0] += latency.frames
            case .bus(let name): busChainFrames[name, default: 0] += latency.frames
            case .master: masterChainFrames += latency.frames
            }
        }
        let plan = MixLatencyMath.plan(trackChainFrames: trackChainFrames, busChainFrames: busChainFrames, masterChainFrames: masterChainFrames)
        directDelay?.configure(delayFrames: plan.directBranchDelayFrames)
        for (name, delay) in busDelays { delay.configure(delayFrames: plan.busOutputDelayFrames[name] ?? 0) }

        // Every input WAV covers the timeline from t=0, so a lower-latency track is aligned by playing it LATER:
        // exactly `playerOffsetFrames` of scheduled silence in front of the file, sample-accurate because a player
        // renders its scheduled segments back to back.
        for entry in players {
            let offset = plan.playerOffsetFrames[entry.track] ?? 0
            if offset > 0 {
                let fileFormat = entry.file.processingFormat
                guard let silence = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(offset)), let channelData = silence.floatChannelData else {
                    engine.stop(); throw MixEngineError.renderFailed(reason: "could not allocate \(plural(offset, "frame")) of alignment silence for track \"\(entry.track)\"")
                }
                silence.frameLength = AVAudioFrameCount(offset)
                for channel in 0..<Int(fileFormat.channelCount) { channelData[channel].update(repeating: 0, count: offset) }
                entry.player.scheduleBuffer(silence, completionHandler: nil)
            }
            entry.player.scheduleFile(entry.file, at: nil, completionHandler: nil)
            entry.player.play()
        }

        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.maximumRenderFrames) else {
            engine.stop(); throw MixEngineError.renderFailed(reason: "could not allocate the render buffer")
        }
        // The graph runs `trimFrames` late overall; rendering that many extra frames and dropping them from the head
        // keeps the written mix positionally at t=0 with its full tail.
        let renderTarget = totalFrames + AVAudioFramePosition(plan.trimFrames)
        var framesToDrop = plan.trimFrames
        var stalledIterations = 0
        while engine.manualRenderingSampleTime < renderTarget {
            let remaining = renderTarget - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(Int64(Self.maximumRenderFrames), remaining))
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(frames, to: renderBuffer) }
            catch { engine.stop(); throw MixEngineError.renderFailed(reason: error.localizedDescription) }
            switch status {
            case .success:
                stalledIterations = 0
                if framesToDrop > 0 {
                    let produced = Int(renderBuffer.frameLength)
                    let dropped = min(framesToDrop, produced)
                    framesToDrop -= dropped
                    let kept = produced - dropped
                    guard kept > 0 else { continue }
                    guard let channelData = renderBuffer.floatChannelData else {
                        engine.stop(); throw MixEngineError.renderFailed(reason: "the render buffer exposes no float channel data, so the latency preroll cannot be trimmed")
                    }
                    for channel in 0..<Int(renderBuffer.format.channelCount) {
                        memmove(channelData[channel], channelData[channel] + dropped, kept * MemoryLayout<Float>.stride)
                    }
                    renderBuffer.frameLength = AVAudioFrameCount(kept)
                }
                do { try outputFile?.write(from: renderBuffer) }
                catch { engine.stop(); throw MixEngineError.outputFileUnwritable(path: outputURL.path, reason: error.localizedDescription) }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalledIterations += 1
                guard stalledIterations < 1000 else { engine.stop(); throw MixEngineError.renderFailed(reason: "the engine made no progress for \(stalledIterations) consecutive render calls at frame \(engine.manualRenderingSampleTime)") }
                continue
            case .error:
                engine.stop(); throw MixEngineError.renderFailed(reason: "the engine reported a render error at frame \(engine.manualRenderingSampleTime)")
            @unknown default:
                engine.stop(); throw MixEngineError.renderFailed(reason: "the engine returned an unknown render status at frame \(engine.manualRenderingSampleTime)")
            }
        }
        let renderedFrames = Int(engine.manualRenderingSampleTime) - plan.trimFrames
        engine.stop()
        outputFile = nil // close the file so the analyzer measures the final bytes on disk

        var busMetrics: [String: AudioMetrics] = [:]
        for (name, accumulator) in busTaps {
            let channels = accumulator.drain()
            guard let frames = channels.first?.count, frames > 0 else {
                notes.append("bus \"\(name)\": the render tap delivered no audio, so bus metrics are unavailable (manual-rendering taps carry no delivery guarantee).")
                continue
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mixengine-bus-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if writeFloatWAV(temporary, sampleRate: sampleRate, channels: channels), let metrics = AudioMetricsAnalyzer().analyze(fileAt: temporary) {
                busMetrics[name] = metrics
                notes.append("bus \"\(name)\": measured from a best-effort render tap (\(plural(frames, "frame")); taps carry no delivery guarantee, the mix file is the authoritative measurement).")
            } else {
                notes.append("bus \"\(name)\": the tapped audio could not be analyzed, so bus metrics are unavailable.")
            }
        }

        let mixMetrics = AudioMetricsAnalyzer().analyze(fileAt: outputURL)
        if mixMetrics == nil { notes.append("the rendered mix file could not be analyzed; the render itself completed (\(plural(renderedFrames, "frame"))).") }
        return MixRenderResult(outputURL: outputURL, sampleRate: sampleRate, renderedFrames: renderedFrames, compensatedLatencyFrames: plan.trimFrames, inserts: insertReports, mixMetrics: mixMetrics, busMetrics: busMetrics, notes: notes)
    }

    // MARK: Component resolution and instantiation

    private func resolveComponent(insert: MixGraphInsert, location: String) throws -> AVAudioUnitComponent {
        let manager = AVAudioUnitComponentManager.shared()
        if let identifier = insert.component {
            guard let description = componentDescription(from: identifier) else { throw MixEngineError.invalidComponentIdentifier(insert: location, identifier: identifier) }
            guard description.componentType == kAudioUnitType_Effect else { throw MixEngineError.notAnEffect(insert: location, identifier: identifier) }
            guard let component = manager.components(matching: description).first else { throw MixEngineError.pluginNotInstalled(insert: location, requested: identifier) }
            return component
        }
        if let name = insert.name {
            let anyEffect = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            let matches = manager.components(matching: anyEffect).filter { nameMatches(name, component: $0) }
            guard !matches.isEmpty else { throw MixEngineError.pluginNotInstalled(insert: location, requested: name) }
            guard matches.count == 1 else { throw MixEngineError.ambiguousPluginName(insert: location, name: name, matches: matches.map { identifierString($0.audioComponentDescription) }) }
            return matches[0]
        }
        throw MixEngineError.insertWithoutIdentity(insert: location)
    }

    /// Matches the requested name against the component's own name, the name part after a "Manufacturer: " prefix,
    /// and the "Manufacturer: Name" composite — case-insensitively, because the list shown to users varies in casing.
    private func nameMatches(_ requested: String, component: AVAudioUnitComponent) -> Bool {
        if component.name.caseInsensitiveCompare(requested) == .orderedSame { return true }
        if let separator = component.name.range(of: ": "), String(component.name[separator.upperBound...]).caseInsensitiveCompare(requested) == .orderedSame { return true }
        if "\(component.manufacturerName): \(component.name)".caseInsensitiveCompare(requested) == .orderedSame { return true }
        return false
    }

    /// Version-2 units instantiate synchronously; a v3 (out-of-process) unit goes through the async API with a hard
    /// timeout so a hung extension becomes a named failure instead of a silent freeze.
    private func instantiate(component: AVAudioUnitComponent, location: String) throws -> AVAudioUnit {
        let description = component.audioComponentDescription
        let identifier = identifierString(description)
        if description.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue == 0 {
            return AVAudioUnitEffect(audioComponentDescription: description)
        }
        let box = InstantiationBox()
        AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { unit, error in box.complete(unit: unit, error: error) }
        let outcome = box.wait(seconds: Self.instantiateTimeoutSeconds)
        guard let unit = outcome.unit else { throw MixEngineError.instantiationFailed(insert: location, component: identifier, reason: outcome.failure ?? "unknown instantiation failure") }
        return unit
    }

    // MARK: Parameters

    /// Sets every requested parameter through the unit's AUParameterTree — resolved by identifier, then by numeric
    /// address, then by display name (exactly one match required) — reads each value back immediately, and refuses by
    /// name when any key resolves to nothing. Nothing is ever skipped silently.
    private func apply(parameters: [String: Double], to unit: AVAudioUnit, location: String) throws -> [MixAppliedParameter] {
        guard !parameters.isEmpty else { return [] }
        let all = unit.auAudioUnit.parameterTree?.allParameters ?? []
        guard !all.isEmpty else { throw MixEngineError.parameterTreeUnavailable(insert: location, requested: parameters.keys.sorted()) }
        var applied: [MixAppliedParameter] = []
        var unresolved: [String] = []
        for key in parameters.keys.sorted() {
            let value = parameters[key]!
            var match = all.first(where: { $0.identifier == key }) ?? all.first(where: { String($0.address) == key })
            if match == nil {
                let byName = all.filter { $0.displayName.caseInsensitiveCompare(key) == .orderedSame }
                guard byName.count <= 1 else { throw MixEngineError.ambiguousParameter(insert: location, key: key, matches: byName.map(\.identifier)) }
                match = byName.first
            }
            guard let parameter = match else { unresolved.append(key); continue }
            parameter.setValue(AUValue(value), originator: nil)
            let readBack = Double(parameter.value)
            let tolerance = max(1e-3, abs(value) * 1e-3)
            applied.append(.init(key: key, resolvedIdentifier: parameter.identifier, resolvedName: parameter.displayName, requestedValue: value, readBackValue: readBack, verified: abs(readBack - value) <= tolerance))
        }
        guard unresolved.isEmpty else {
            let available = all.map { "\($0.identifier) (address \($0.address), \"\($0.displayName)\")" }
            throw MixEngineError.parametersNotResolved(insert: location, keys: unresolved, available: available)
        }
        return applied
    }

    // MARK: Small helpers

    private func linearGain(_ decibels: Double) -> Double { pow(10, decibels / 20) }

    private func firstDuplicate(_ names: [String]) -> String? {
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted { return name }
        return nil
    }

    private func outputSettings(sampleRate: Double, format: OutputSampleFormat) -> [String: Any] {
        switch format {
        case .float32: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        case .int24: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
    }

    private func writeFloatWAV(_ url: URL, sampleRate: Double, channels: [[Float]]) -> Bool {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return false }
        let frames = channels.map(\.count).min() ?? 0
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return false }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() { samples.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames) } }
        return (try? file.write(from: buffer)) != nil
    }

    /// "aufx/pmeq/appl" ← AudioComponentDescription, the same identifier form `PluginInventory` publishes.
    private func identifierString(_ description: AudioComponentDescription) -> String {
        [description.componentType, description.componentSubType, description.componentManufacturer].map(fourCC).joined(separator: "/")
    }
    private func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "----"
    }
    private func componentDescription(from identifier: String) -> AudioComponentDescription? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        var codes: [OSType] = []
        for part in parts {
            guard (1...4).contains(part.count), part.allSatisfy(\.isASCII) else { return nil }
            let padded = part.padding(toLength: 4, withPad: " ", startingAt: 0)
            codes.append(padded.unicodeScalars.reduce(OSType(0)) { ($0 << 8) | OSType($1.value & 0xFF) })
        }
        return AudioComponentDescription(componentType: codes[0], componentSubType: codes[1], componentManufacturer: codes[2], componentFlags: 0, componentFlagsMask: 0)
    }
}

// MARK: - Internal plumbing

/// Which insert chain a loaded unit sits in, kept so the engine can sum reported latencies per chain once the numbers
/// are real (after render resources exist) and hand the sums to the pure planning math.
private enum MixChainKey: Hashable {
    case track(String), bus(String), master
}

/// Hands the async AVAudioUnit instantiation result across threads exactly once, with a timeout. The lock makes the
/// single handoff safe; nothing else is shared. Internal rather than private because the sample-exact alignment delay
/// instantiates through the same async API.
final class InstantiationBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var unit: AVAudioUnit?
    private var failure: String?
    func complete(unit: AVAudioUnit?, error: Error?) {
        lock.lock()
        self.unit = unit
        self.failure = error.map { $0.localizedDescription } ?? (unit == nil ? "the system returned neither a unit nor an error" : nil)
        lock.unlock()
        semaphore.signal()
    }
    func wait(seconds: Double) -> (unit: AVAudioUnit?, failure: String?) {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return (nil, "instantiation timed out after \(Int(seconds)) s") }
        lock.lock(); defer { lock.unlock() }
        return (unit, failure)
    }
}

/// Collects a bus tap's buffers during manual rendering. Tap blocks arrive on an internal audio thread with no
/// delivery guarantee in manual rendering mode, so the accumulator only locks and copies; the engine polls `drain()`
/// after the render and reports honestly when nothing arrived.
private final class BusTapAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [[Float]] = []
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        if channels.isEmpty { channels = Array(repeating: [], count: Int(buffer.format.channelCount)) }
        for channel in 0..<channels.count { channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames)) }
    }
    /// Waits until the frame count stops growing (pending tap blocks may still land right after `engine.stop()`),
    /// then returns everything that arrived.
    func drain() -> [[Float]] {
        var previous = -1
        for _ in 0..<20 {
            lock.lock(); let count = channels.first?.count ?? 0; lock.unlock()
            if count == previous { break }
            previous = count
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock(); defer { lock.unlock() }
        return channels
    }
}
