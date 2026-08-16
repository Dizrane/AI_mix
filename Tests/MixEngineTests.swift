import Testing
import Foundation
import AVFoundation
@testable import AIMixAssistant

// MARK: - Fixtures
// CI runs on plain GitHub macOS runners, so every insert used here is an Apple built-in AU (AUParametricEQ,
// AUDynamicsProcessor, AUPeakLimiter, AUMatrixReverb) — the only effects guaranteed installed. Third-party plugins
// are exercised by the same code paths but proven on a real Mac, never fabricated here.

private func mixFixtureDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mixengine-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
private func writeStereoFloatWAV(_ url: URL, sampleRate: Double = 48000, left: [Float], right: [Float]) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = min(left.count, right.count)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
    right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: frames) }
    try file.write(from: buffer)
}
private func mixSine(_ frequency: Double, amplitude: Double, seconds: Double, sampleRate: Double = 48000) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}
private func mixImpulse(at index: Int, amplitude: Float, length: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: length)
    samples[index] = amplitude
    return samples
}
private func argmaxAbs(_ samples: [Float]) -> Int {
    var best = 0
    for index in samples.indices where abs(samples[index]) > abs(samples[best]) { best = index }
    return best
}
/// The latency AUPeakLimiter itself reports at the mix rate, read from an independent instance after allocating its
/// render resources — the same source the engine compensates from. The tests derive every expectation from this
/// runtime number instead of hardcoding any plugin's latency; when the installed limiter reports zero, the alignment
/// assertions still hold exactly (the zero case is a provable no-op).
private func probedLimiterLatencyFrames(sampleRate: Double = 48000) throws -> Int {
    let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    let probe = AVAudioUnitEffect(audioComponentDescription: description)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    try probe.auAudioUnit.inputBusses[0].setFormat(format)
    try probe.auAudioUnit.outputBusses[0].setFormat(format)
    try probe.auAudioUnit.allocateRenderResources()
    defer { probe.auAudioUnit.deallocateRenderResources() }
    return MixLatencyMath.insertLatency(reportedSeconds: probe.auAudioUnit.latency, sampleRate: sampleRate).frames
}
private func readChannels(_ url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let frames = Int(buffer.frameLength)
    return (0..<Int(file.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames)) }
}
private func render(_ graph: MixGraph, folder: URL, output: String = "mix.wav", options: MixEngine.Options = .init(tailSeconds: 0)) throws -> MixRenderResult {
    try MixEngine().render(graph: graph, folder: folder, outputURL: folder.appendingPathComponent(output), options: options)
}
/// Asserts that rendering the graph fails with a `MixEngineError` accepted by `check` — never with silence and never
/// with a foreign error type.
private func expectEngineError(_ graph: MixGraph, folder: URL, _ check: (MixEngineError) -> Bool) {
    do {
        _ = try render(graph, folder: folder)
        Issue.record("expected a MixEngineError, but the render succeeded")
    } catch let error as MixEngineError {
        #expect(check(error), "unexpected MixEngineError: \(error)")
    } catch {
        Issue.record("expected a MixEngineError, got \(error)")
    }
}

private let parametricEQ = "aufx/pmeq/appl"
private let matrixReverb = "aufx/mrev/appl"
private let peakLimiter = "aufx/lmtr/appl"

// MARK: - Sum correctness

/// Two stereo files with known levels and lengths must render (no inserts) to their arithmetic sum: unity paths stay
/// unity, the dB gain lands as its exact linear factor, and alignment is positional — after the shorter file ends the
/// mix equals the longer file alone.
@Test func mixEngineSumsTracksArithmetically() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = mixSine(440, amplitude: 0.25, seconds: 1.0)
    let b = mixSine(770, amplitude: 0.30, seconds: 0.5)
    try writeStereoFloatWAV(dir.appendingPathComponent("a.wav"), left: a, right: a)
    try writeStereoFloatWAV(dir.appendingPathComponent("b.wav"), left: b, right: b)
    let minusSixDB = -6.020599913279624 // exactly the linear factor 0.5
    let graph = MixGraph(tracks: [
        .init(name: "A", file: "a.wav"),
        .init(name: "B", file: "b.wav", gainDB: minusSixDB)
    ])
    let result = try render(graph, folder: dir)
    #expect(result.sampleRate == 48000)
    #expect(result.renderedFrames == 48000)
    let channels = try readChannels(dir.appendingPathComponent("mix.wav"))
    #expect(channels.count == 2)
    var worst: Float = 0
    for channel in channels {
        #expect(channel.count == 48000)
        for index in 0..<channel.count {
            let expected = a[index] + (index < b.count ? 0.5 * b[index] : 0)
            worst = max(worst, abs(channel[index] - expected))
        }
    }
    #expect(worst < 1e-4, "worst deviation from the arithmetic sum was \(worst)")
    #expect(result.mixMetrics?.clippedSampleCount.value == 0)
    #expect(MixEngineCLI.report(for: result).contains("sample peak"))
}

// MARK: - Parameter roundtrip and audible effect

/// Setting AUParametricEQ's centre frequency and gain through the parameter tree must read back equal, and the render
/// must really lose energy in the cut band — the parameters were applied to the DSP, not just to a data structure.
@Test func mixEngineParametricEQRoundtripChangesSpectrum() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let material = zip(mixSine(100, amplitude: 0.35, seconds: 2), mixSine(3000, amplitude: 0.35, seconds: 2)).map(+)
    try writeStereoFloatWAV(dir.appendingPathComponent("m.wav"), left: material, right: material)

    let reference = try render(MixGraph(tracks: [.init(name: "M", file: "m.wav")]), folder: dir, output: "mix_reference.wav")
    let referenceBands = try #require(reference.mixMetrics?.spectralBands.value)
    #expect(referenceBands.highMidPercent > 30)

    // Addresses from AudioUnitParameters.h: 0 = centre frequency, 1 = Q, 2 = gain (dB).
    let eq = MixGraphInsert(component: parametricEQ, parameters: ["0": 3000, "1": 2, "2": -20])
    let cut = try render(MixGraph(tracks: [.init(name: "M", file: "m.wav", inserts: [eq])]), folder: dir)
    let report = try #require(cut.inserts.first)
    #expect(report.resolvedIdentifier == parametricEQ)
    #expect(report.parameters.count == 3)
    for parameter in report.parameters {
        #expect(parameter.verified, "\(parameter.key) read back \(parameter.readBackValue) after setting \(parameter.requestedValue)")
        #expect(abs(parameter.readBackValue - parameter.requestedValue) <= max(1e-3, abs(parameter.requestedValue) * 1e-3))
    }
    let cutBands = try #require(cut.mixMetrics?.spectralBands.value)
    #expect(cutBands.highMidPercent < 5, "a −20 dB cut at 3 kHz must collapse the high-mid share (got \(cutBands.highMidPercent)%)")
    #expect(cutBands.bassPercent > referenceBands.bassPercent)
}

/// The display-name fallback resolves a parameter that is addressed by neither identifier nor address — the name is
/// read from the real unit first, so the test proves resolution, not a hardcoded localization.
@Test func mixEngineResolvesParameterByDisplayName() throws {
    let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_ParametricEQ, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    let probe = AVAudioUnitEffect(audioComponentDescription: description)
    let gainParameter = try #require(probe.auAudioUnit.parameterTree?.allParameters.first { $0.address == 2 })
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tone = mixSine(500, amplitude: 0.3, seconds: 0.3)
    try writeStereoFloatWAV(dir.appendingPathComponent("t.wav"), left: tone, right: tone)
    let insert = MixGraphInsert(component: parametricEQ, parameters: [gainParameter.displayName: -12])
    let result = try render(MixGraph(tracks: [.init(name: "T", file: "t.wav", inserts: [insert])]), folder: dir)
    let applied = try #require(result.inserts.first?.parameters.first)
    #expect(applied.resolvedName == gainParameter.displayName)
    #expect(abs(applied.readBackValue + 12) <= 0.012)
}

// MARK: - Send path

/// A track sending into a bus with AUMatrixReverb (100 % wet) must leave a reverb tail in the render after the dry
/// material ends — proof that the send topology (dedicated send mixer into the bus chain) really carries signal.
@Test func mixEngineSendFeedsReverbTailAfterDryMaterialEnds() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dry = mixSine(660, amplitude: 0.4, seconds: 0.5)
    try writeStereoFloatWAV(dir.appendingPathComponent("dry.wav"), left: dry, right: dry)
    let graph = MixGraph(
        tracks: [.init(name: "Dry", file: "dry.wav", sends: [.init(bus: "verb", levelDB: 0)])],
        buses: [.init(name: "verb", inserts: [.init(component: matrixReverb, parameters: ["0": 100])])] // address 0 = dry/wet mix, 100 % wet
    )
    let result = try render(graph, folder: dir, options: .init(tailSeconds: 2, measureBuses: true))
    #expect(result.renderedFrames == 24000 + 96000)
    let channels = try readChannels(dir.appendingPathComponent("mix.wav"))
    let tail = Array(channels[0][Int(0.7 * 48000)..<Int(1.5 * 48000)])
    let tailPeak = tail.map(abs).max() ?? 0
    #expect(tailPeak > 1e-4, "expected an audible reverb tail after the dry file ended, got peak \(tailPeak)")
    let head = Array(channels[0][0..<24000])
    #expect((head.map(abs).max() ?? 0) > 0.3, "the dry signal itself must still reach the master sum")
    #expect(result.notes.contains { $0.hasPrefix("bus \"verb\"") }, "the bus measurement must be reported by name, measured or honestly unavailable")
}

// MARK: - Latency compensation: pure planning math

/// Two tracks with unequal insert-chain latencies are aligned purely by player offsets: the lower-latency track
/// starts later, no DSP enters any path, and the trim removes the slowest chain from the output.
@Test func mixLatencyPlanAlignsUnequalTrackChainsByPlayerOffsets() {
    let plan = MixLatencyMath.plan(trackChainFrames: ["A": 0, "B": 576], busChainFrames: [:], masterChainFrames: 0)
    #expect(plan.playerOffsetFrames == ["A": 576, "B": 0])
    #expect(plan.busOutputDelayFrames.isEmpty)
    #expect(plan.directBranchDelayFrames == 0)
    #expect(plan.trimFrames == 576)
}

/// A send into a latent bus splits one signal into two branches of different latency; the plan repairs the divergence
/// where it happens — the direct branch waits for the slowest bus, every bus output waits for the difference — while
/// player offsets still equalize the tracks before any fan-out.
@Test func mixLatencyPlanDelaysDivergingBranchesAgainstLatentBuses() {
    let plan = MixLatencyMath.plan(trackChainFrames: ["T": 128, "U": 0], busChainFrames: ["verb": 512, "comp": 64], masterChainFrames: 0)
    #expect(plan.playerOffsetFrames == ["T": 0, "U": 128])
    #expect(plan.busOutputDelayFrames == ["verb": 0, "comp": 448])
    #expect(plan.directBranchDelayFrames == 512)
    #expect(plan.trimFrames == 128 + 512)
}

/// The master chain sits on the single path after every sum, so its latency needs no alignment — only removal from
/// the head of the written file.
@Test func mixLatencyPlanTrimsMasterChainLatencyWithoutAligningAnything() {
    let plan = MixLatencyMath.plan(trackChainFrames: ["A": 0, "B": 0], busChainFrames: [:], masterChainFrames: 576)
    #expect(plan.playerOffsetFrames == ["A": 0, "B": 0])
    #expect(plan.directBranchDelayFrames == 0)
    #expect(plan.trimFrames == 576)
}

/// A graph whose units all report zero latency plans an all-zero no-op: nothing is offset, delayed or trimmed.
@Test func mixLatencyPlanIsANoOpForAZeroLatencyGraph() {
    let plan = MixLatencyMath.plan(trackChainFrames: ["A": 0, "B": 0], busChainFrames: ["verb": 0], masterChainFrames: 0)
    #expect(plan.playerOffsetFrames == ["A": 0, "B": 0])
    #expect(plan.busOutputDelayFrames == ["verb": 0])
    #expect(plan.directBranchDelayFrames == 0)
    #expect(plan.trimFrames == 0)
}

/// Reported seconds convert to whole frames with the uncompensatable remainder carried, not hidden: an exact frame
/// count leaves only float noise, a fractional latency names its fraction, a negative report contributes nothing.
@Test func mixLatencyMathConvertsReportedSecondsToWholeFramesHonestly() {
    let exact = MixLatencyMath.insertLatency(reportedSeconds: 576.0 / 48000.0, sampleRate: 48000)
    #expect(exact.frames == 576)
    #expect(abs(exact.residualSamples) < MixLatencyMath.residualNoteThresholdSamples)
    let fractional = MixLatencyMath.insertLatency(reportedSeconds: 100.4 / 48000.0, sampleRate: 48000)
    #expect(fractional.frames == 100)
    #expect(abs(fractional.residualSamples - 0.4) < 1e-6)
    let negative = MixLatencyMath.insertLatency(reportedSeconds: -0.001, sampleRate: 48000)
    #expect(negative.frames == 0)
    #expect(abs(negative.residualSamples + 48.0) < 1e-9)
    let zero = MixLatencyMath.insertLatency(reportedSeconds: 0, sampleRate: 48000)
    #expect(zero == MixInsertLatency(frames: 0, residualSamples: 0))
}

/// The alignment delay ring is bit-exact by construction, proven with plain `==` on the floats: input comes back
/// untouched exactly `delayFrames` later, across arbitrary block boundaries, and zero delay is the identity.
@Test func sampleExactDelayRingReplaysInputBitExactly() {
    var ring = SampleExactDelayRing(delayFrames: 3)
    #expect(ring.process([1, 2, 3, 4, 5]) == [0, 0, 0, 1, 2])
    #expect(ring.process([6, 7]) == [3, 4])
    #expect(ring.process([8]) == [5])
    var identity = SampleExactDelayRing(delayFrames: 0)
    let input: [Float] = [0.125, -0.25, 0.3]
    #expect(identity.process(input) == input)
    var longDelay = SampleExactDelayRing(delayFrames: 5)
    #expect(longDelay.process([1, 2]) == [0, 0])
    #expect(longDelay.process([3]) == [0])
    #expect(longDelay.process([4, 5, 6, 7]) == [0, 0, 1, 2])
    #expect(longDelay.process([8, 9]) == [3, 4])
}

// MARK: - Latency compensation: rendered proof

/// Two tracks carry an impulse at the same input sample; one runs through AUPeakLimiter on its own chain. The
/// limiter's latency is read from the unit at runtime (never hardcoded): the solo render proves the trim (the impulse
/// lands exactly where the input put it), and the two-track render proves alignment arithmetically — the mix at the
/// impulse sample equals the sum of the individual renders there, which is only possible when both branches landed on
/// the same frame. Every assertion holds exactly for a zero-latency limiter too (the provable no-op case).
@Test func mixEngineAlignsUnequalTrackChainsSampleExactly() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let position = 4800
    let impulse = mixImpulse(at: position, amplitude: 0.4, length: 24000)
    try writeStereoFloatWAV(dir.appendingPathComponent("a.wav"), left: impulse, right: impulse)
    try writeStereoFloatWAV(dir.appendingPathComponent("b.wav"), left: impulse, right: impulse)
    let probedLatency = try probedLimiterLatencyFrames()

    let limited = try render(MixGraph(tracks: [.init(name: "B", file: "b.wav", inserts: [.init(component: peakLimiter)])]), folder: dir, output: "mix_b.wav")
    #expect(limited.inserts.first?.latencyFrames == probedLatency)
    #expect(limited.compensatedLatencyFrames == probedLatency)
    #expect(limited.renderedFrames == 24000)
    let limitedChannels = try readChannels(dir.appendingPathComponent("mix_b.wav"))
    #expect(argmaxAbs(limitedChannels[0]) == position, "the limited track's impulse must land exactly at the input position — the trim removed exactly the reported latency")

    let together = try render(MixGraph(tracks: [
        .init(name: "A", file: "a.wav"),
        .init(name: "B", file: "b.wav", inserts: [.init(component: peakLimiter)])
    ]), folder: dir)
    #expect(together.compensatedLatencyFrames == probedLatency)
    let channels = try readChannels(dir.appendingPathComponent("mix.wav"))
    #expect(argmaxAbs(channels[0]) == position)
    let expected = 0.4 + limitedChannels[0][position]
    #expect(abs(channels[0][position] - expected) < 1e-4, "the aligned sum at the impulse must equal the individual renders' sum (got \(channels[0][position]), expected \(expected))")
}

/// A send fans one track out into two branches: direct to the master sum and through a bus whose insert carries
/// latency. Offsets cannot split a fan-out, so this proves the per-branch delays: the bus branch's energy must ADD at
/// exactly the input impulse sample (any misalignment leaves the mix at the bare direct amplitude and puts a second
/// peak elsewhere), and every dominant sample sits at that one position.
@Test func mixEngineAlignsSendBusFanOutSampleExactly() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let position = 4800
    let impulse = mixImpulse(at: position, amplitude: 0.4, length: 24000)
    try writeStereoFloatWAV(dir.appendingPathComponent("t.wav"), left: impulse, right: impulse)
    let probedLatency = try probedLimiterLatencyFrames()
    let graph = MixGraph(
        tracks: [.init(name: "T", file: "t.wav", sends: [.init(bus: "comp", levelDB: 0)])],
        buses: [.init(name: "comp", inserts: [.init(component: peakLimiter)])]
    )
    let result = try render(graph, folder: dir)
    #expect(result.compensatedLatencyFrames == probedLatency)
    let channels = try readChannels(dir.appendingPathComponent("mix.wav"))
    #expect(argmaxAbs(channels[0]) == position)
    #expect(channels[0][position] > 0.45, "the bus branch must add its impulse at exactly the direct branch's sample (mix at the impulse was \(channels[0][position]))")
    let peak = abs(channels[0][argmaxAbs(channels[0])])
    for index in channels[0].indices where abs(channels[0][index]) > 0.5 * peak {
        #expect(index == position, "a dominant sample away from the impulse (index \(index)) means the branches did not converge")
    }
}

/// A latent bus that receives no sends still switches the graph onto the branch-delay topology, so the tracks' direct
/// path runs through the alignment delay — and must come out bit-faithful: the written mix is exactly the input
/// impulse at exactly the input position, everything else silent.
@Test func mixEngineAlignmentDelayKeepsTheDirectPathBitFaithful() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let position = 4800
    let impulse = mixImpulse(at: position, amplitude: 0.4, length: 24000)
    try writeStereoFloatWAV(dir.appendingPathComponent("a.wav"), left: impulse, right: impulse)
    let probedLatency = try probedLimiterLatencyFrames()
    let graph = MixGraph(
        tracks: [.init(name: "A", file: "a.wav")],
        buses: [.init(name: "pad", inserts: [.init(component: peakLimiter)])]
    )
    let result = try render(graph, folder: dir)
    #expect(result.compensatedLatencyFrames == probedLatency)
    #expect(result.renderedFrames == 24000)
    let channels = try readChannels(dir.appendingPathComponent("mix.wav"))
    for channel in channels {
        #expect(abs(channel[position] - 0.4) <= 1e-4, "the delayed direct path must stay faithful within the suite's unity-path tolerance (impulse came out as \(channel[position]))")
        for index in channel.indices where index != position && abs(channel[index]) > 1e-4 {
            Issue.record("expected silence at \(index), got \(channel[index]) — the alignment delay must not color or smear the signal")
            break
        }
    }
}

// MARK: - Limiter

/// A deliberately clipping sum (two 0.9 sines in phase) counts clipped samples without a limiter and zero with
/// AUPeakLimiter on the master — measured by the same clipped-sample metric the app uses for exported WAVs. The
/// master limiter's look-ahead latency must additionally NOT shift the render: the trim equals exactly the latency
/// the unit itself reported, and an impulse through the same master chain lands exactly at its input position.
@Test func mixEnginePeakLimiterPreventsClippedSamples() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let loud = mixSine(200, amplitude: 0.9, seconds: 1.0)
    try writeStereoFloatWAV(dir.appendingPathComponent("l1.wav"), left: loud, right: loud)
    try writeStereoFloatWAV(dir.appendingPathComponent("l2.wav"), left: loud, right: loud)
    let tracks: [MixGraphTrack] = [.init(name: "L1", file: "l1.wav"), .init(name: "L2", file: "l2.wav")]

    let clipped = try render(MixGraph(tracks: tracks, master: .init(gainDB: -1)), folder: dir, output: "mix_clipped.wav")
    let clippedCount = try #require(clipped.mixMetrics?.clippedSampleCount.value)
    #expect(clippedCount > 0, "the unlimited sum must really clip, or the limiter test proves nothing")
    #expect(clipped.compensatedLatencyFrames == 0, "a graph without inserts has nothing to compensate")

    let limited = try render(MixGraph(tracks: tracks, master: .init(gainDB: -1, inserts: [.init(component: peakLimiter)])), folder: dir)
    #expect(limited.mixMetrics?.clippedSampleCount.value == 0)
    let limitedPeak = try #require(limited.mixMetrics?.samplePeakDBFS.value)
    #expect(limitedPeak < 0)
    #expect(limited.renderedFrames == 48000)
    #expect(limited.compensatedLatencyFrames == limited.inserts.first?.latencyFrames)

    let position = 9600
    let impulse = mixImpulse(at: position, amplitude: 0.5, length: 24000)
    try writeStereoFloatWAV(dir.appendingPathComponent("imp.wav"), left: impulse, right: impulse)
    let aligned = try render(MixGraph(tracks: [.init(name: "I", file: "imp.wav")], master: .init(inserts: [.init(component: peakLimiter)])), folder: dir, output: "mix_impulse.wav")
    #expect(aligned.compensatedLatencyFrames == aligned.inserts.first?.latencyFrames)
    #expect(aligned.renderedFrames == 24000)
    let impulseChannels = try readChannels(dir.appendingPathComponent("mix_impulse.wav"))
    #expect(argmaxAbs(impulseChannels[0]) == position, "the master limiter's latency must be trimmed, not shifted into the mix")
}

// MARK: - Named refusals

@Test func mixEngineNamesMissingPluginAndUnresolvedParameter() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tone = mixSine(500, amplitude: 0.2, seconds: 0.2)
    try writeStereoFloatWAV(dir.appendingPathComponent("t.wav"), left: tone, right: tone)

    // A component identifier no machine has: a hard, named error — never a silent bypass.
    expectEngineError(MixGraph(tracks: [.init(name: "T", file: "t.wav", inserts: [.init(component: "aufx/zzzq/qqqz")])]), folder: dir) {
        if case .pluginNotInstalled(let insert, let requested) = $0 { return insert.contains("track \"T\" insert 1") && requested == "aufx/zzzq/qqqz" }
        return false
    }
    // Same for the name fallback.
    expectEngineError(MixGraph(tracks: [.init(name: "T", file: "t.wav", inserts: [.init(name: "No Such Plugin 9000")])]), folder: dir) {
        if case .pluginNotInstalled(_, let requested) = $0 { return requested == "No Such Plugin 9000" }
        return false
    }
    // An insert naming nothing at all is refused by name.
    expectEngineError(MixGraph(tracks: [.init(name: "T", file: "t.wav", inserts: [.init()])]), folder: dir) {
        if case .insertWithoutIdentity = $0 { return true }
        return false
    }
    // A parameter key the unit does not expose: the error names the key and lists what the unit really has.
    expectEngineError(MixGraph(tracks: [.init(name: "T", file: "t.wav", inserts: [.init(component: parametricEQ, parameters: ["definitely_not_a_parameter": 1])])]), folder: dir) {
        if case .parametersNotResolved(_, let keys, let available) = $0 { return keys == ["definitely_not_a_parameter"] && !available.isEmpty }
        return false
    }
}

@Test func mixEngineRefusesMismatchedSampleRatesAndUnknownBuses() throws {
    let dir = try mixFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeStereoFloatWAV(dir.appendingPathComponent("a48.wav"), sampleRate: 48000, left: mixSine(440, amplitude: 0.2, seconds: 0.2), right: mixSine(440, amplitude: 0.2, seconds: 0.2))
    try writeStereoFloatWAV(dir.appendingPathComponent("b44.wav"), sampleRate: 44100, left: mixSine(440, amplitude: 0.2, seconds: 0.2, sampleRate: 44100), right: mixSine(440, amplitude: 0.2, seconds: 0.2, sampleRate: 44100))

    expectEngineError(MixGraph(tracks: [.init(name: "A", file: "a48.wav"), .init(name: "B", file: "b44.wav")]), folder: dir) {
        if case .sampleRateMismatch(let track, _, let rate, let expected) = $0 { return track == "B" && rate == 44100 && expected == 48000 }
        return false
    }
    expectEngineError(MixGraph(tracks: [.init(name: "A", file: "a48.wav", sends: [.init(bus: "ghost", levelDB: 0)])]), folder: dir) {
        if case .unknownSendBus(let track, let bus, _) = $0 { return track == "A" && bus == "ghost" }
        return false
    }
    expectEngineError(MixGraph(schemaVersion: "9.9", tracks: [.init(name: "A", file: "a48.wav")]), folder: dir) {
        if case .unsupportedSchemaVersion(let found, let supported) = $0 { return found == "9.9" && supported == "1.0" }
        return false
    }
    expectEngineError(MixGraph(tracks: [.init(name: "A", file: "missing.wav")]), folder: dir) {
        if case .inputFileUnreadable(let track, _) = $0 { return track == "A" }
        return false
    }
}

// MARK: - Schema

/// The graph JSON an LLM will produce stays minimal: only names and files are required, everything else defaults.
@Test func mixGraphDecodesMinimalJSONWithDefaults() throws {
    let json = #"{"schemaVersion":"1.0","tracks":[{"name":"A","file":"a.wav"}]}"#
    let graph = try JSONDecoder().decode(MixGraph.self, from: Data(json.utf8))
    #expect(graph.schemaVersion == "1.0")
    #expect(graph.tracks.count == 1)
    #expect(graph.tracks[0].gainDB == 0 && graph.tracks[0].pan == 0)
    #expect(graph.tracks[0].inserts.isEmpty && graph.tracks[0].sends.isEmpty)
    #expect(graph.buses.isEmpty && graph.master.gainDB == 0 && graph.master.inserts.isEmpty)
}

@Test func mixGraphRoundTripsThroughJSON() throws {
    let graph = MixGraph(
        tracks: [.init(name: "Kick", file: "kick.wav", gainDB: -2, pan: -0.3, inserts: [.init(component: "aufx/pmeq/appl", parameters: ["0": 120])], sends: [.init(bus: "verb", levelDB: -9, pan: 0.5)])],
        buses: [.init(name: "verb", gainDB: -3, inserts: [.init(name: "AUMatrixReverb")])],
        master: .init(gainDB: -1, inserts: [.init(component: "aufx/lmtr/appl")])
    )
    let decoded = try JSONDecoder().decode(MixGraph.self, from: JSONEncoder().encode(graph))
    #expect(decoded.tracks[0].sends[0].bus == "verb" && decoded.tracks[0].sends[0].levelDB == -9 && decoded.tracks[0].sends[0].pan == 0.5)
    #expect(decoded.buses[0].inserts[0].name == "AUMatrixReverb")
    #expect(decoded.master.gainDB == -1)
}
