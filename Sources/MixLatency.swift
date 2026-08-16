import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Pure latency-compensation math

/// One insert's reported latency translated to the mix rate: the whole-frame part the engine can really compensate,
/// and the fractional remainder it cannot. The remainder is carried instead of discarded so the engine can name it
/// in the render notes — a number that cannot be aligned by integer scheduling is reported, never rounded away in
/// silence.
struct MixInsertLatency: Equatable, Sendable {
    /// Whole frames of latency at the mix rate, never negative (a unit reporting a negative latency contributes
    /// nothing to the plan and shows up as a residual instead).
    var frames: Int
    /// What remains after taking `frames`: `reportedSeconds * sampleRate - frames`. Zero (within float noise) for
    /// every honest unit; anything larger is uncompensatable by whole-frame alignment and must be named.
    var residualSamples: Double
}

/// The complete alignment decision for one render, in frames at the mix rate. Every number is derived from latencies
/// the units themselves reported — nothing here is guessed — and the plan is pure data so the reasoning can be unit
/// tested without an audio engine.
struct MixLatencyPlan: Equatable, Sendable {
    /// Scheduled silence in front of each track's file, keyed by track name: `maxTrackChain - thisTrackChain`. Every
    /// input WAV starts at t=0, so playing a lower-latency track LATER aligns it without putting any DSP in its path.
    var playerOffsetFrames: [String: Int]
    /// Delay on each bus's output, keyed by bus name: `maxBusChain - thisBusChain`, so every bus return reaches the
    /// master sum equally late.
    var busOutputDelayFrames: [String: Int]
    /// Delay on the tracks' direct branch into the master sum: `maxBusChain`, so direct signal and bus returns meet
    /// the master sum at the same instant.
    var directBranchDelayFrames: Int
    /// The whole graph's latency — `maxTrackChain + maxBusChain + masterChain` — rendered in addition to the mix
    /// length and trimmed from the head of the output, so the written file stays positionally at t=0.
    var trimFrames: Int
}

/// Pure planning math for sample-accurate latency compensation, extracted from the AV plumbing so it is provable by
/// unit tests alone (the house pattern of `StripResolutionMath` and `FaderServoMath`). The alignment argument, by
/// construction rather than by measurement: (1) every input WAV covers the timeline from t=0, so scheduling
/// `maxTrackChain - L(track)` frames of silence in front of each file makes every track-mixer output carry the same
/// total latency — and because the offset happens BEFORE the track's fan-out into sends, every branch of that fan-out
/// inherits the alignment, which is why sends need no per-send delay. (2) A send's two branches diverge after the
/// track mixer: the direct branch reaches the master sum untouched while the bus branch gains that bus's insert-chain
/// latency, and no player offset can split a fan-out — so the divergence is repaired where it happens, with a delay
/// of `maxBusChain` on the direct branch and `maxBusChain - L(bus)` on each bus output, making every path into the
/// master sum equally late. (3) The master chain sits on the single remaining path, so its latency needs no
/// alignment, only removal: the total `trimFrames` is rendered beyond the mix length and cut from the head. A graph
/// whose units all report zero latency yields an all-zero plan — a provable no-op.
struct MixLatencyMath {
    /// Residuals larger than this (in samples) are named in the render notes; smaller ones are float noise from the
    /// seconds→frames conversion, not real misalignment.
    static let residualNoteThresholdSamples = 0.001

    /// Translates a unit's reported latency (`auAudioUnit.latency`, seconds — real only after render resources are
    /// allocated) into whole frames at the mix rate, keeping the uncompensatable remainder instead of hiding it.
    static func insertLatency(reportedSeconds: Double, sampleRate: Double) -> MixInsertLatency {
        let samples = reportedSeconds * sampleRate
        let frames = max(0, Int(samples.rounded()))
        return MixInsertLatency(frames: frames, residualSamples: samples - Double(frames))
    }

    /// Builds the alignment plan from per-chain latency sums (whole frames at the mix rate). Send topology is
    /// deliberately absent from the signature: the plan aligns every track before any fan-out and every bus output
    /// against the slowest bus, so it is correct for every possible send routing of the same chains.
    static func plan(trackChainFrames: [String: Int], busChainFrames: [String: Int], masterChainFrames: Int) -> MixLatencyPlan {
        let maxTrack = trackChainFrames.values.max() ?? 0
        let maxBus = busChainFrames.values.max() ?? 0
        return MixLatencyPlan(
            playerOffsetFrames: trackChainFrames.mapValues { maxTrack - $0 },
            busOutputDelayFrames: busChainFrames.mapValues { maxBus - $0 },
            directBranchDelayFrames: maxBus,
            trimFrames: maxTrack + maxBus + masterChainFrames
        )
    }
}

// MARK: - Sample-exact delay line

/// A fixed whole-frame delay: samples go into a ring and come back out `delayFrames` later, untouched. Bit-exact by
/// construction — no interpolation, no filtering, no feedback, no gain — which is exactly why the engine uses this
/// instead of `AVAudioUnitDelay`, whose wet path carries a low-pass filter and fractional-time interpolation that
/// would have to be proven transparent rather than being transparent by construction. Zero delay is a pure copy.
struct SampleExactDelayRing: Sendable {
    private var stored: [Float]
    private var index = 0

    init(delayFrames: Int) {
        stored = [Float](repeating: 0, count: max(0, delayFrames))
    }

    mutating func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int) {
        let length = stored.count
        guard length > 0 else {
            if UnsafePointer(output) != input { output.update(from: input, count: frames) }
            return
        }
        var cursor = index
        stored.withUnsafeMutableBufferPointer { ring in
            for frame in 0..<frames {
                let incoming = input[frame]
                output[frame] = ring[cursor]
                ring[cursor] = incoming
                cursor += 1
                if cursor == length { cursor = 0 }
            }
        }
        index = cursor
    }

    /// Array-in, array-out form for the unit tests that prove bit-exactness with plain `==` on the floats.
    mutating func process(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                guard let source = inputPointer.baseAddress, let destination = outputPointer.baseAddress else { return }
                process(input: source, output: destination, frames: input.count)
            }
        }
        return output
    }
}

// MARK: - In-process alignment delay Audio Unit

/// Render-side state of one alignment delay, kept in a lock-guarded box (the house `@unchecked Sendable` pattern):
/// the engine configures the delay once between `start()` and the first render call, and offline manual rendering
/// pulls the render block serially, so the lock only guards that one handoff — it is never contended during a render.
private final class AlignmentDelayState: @unchecked Sendable {
    private let lock = NSLock()
    private var delayFrames = 0
    private var rings: [SampleExactDelayRing] = []
    private var scratch: AVAudioPCMBuffer?
    private var scratchChannels: [UnsafeMutableRawPointer?] = []

    func prepare(format: AVAudioFormat, maximumFrames: AVAudioFrameCount) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard format.channelCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else { return false }
        scratch = buffer
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        scratchChannels = (0..<list.count).map { list[$0].mData }
        rings = (0..<Int(format.channelCount)).map { _ in SampleExactDelayRing(delayFrames: delayFrames) }
        return true
    }

    func tearDown() {
        lock.lock(); defer { lock.unlock() }
        scratch = nil
        scratchChannels = []
        rings = []
    }

    func configure(delayFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        self.delayFrames = max(0, delayFrames)
        rings = rings.map { _ in SampleExactDelayRing(delayFrames: self.delayFrames) }
    }

    /// Pulls the upstream signal into the scratch buffer and pushes it out `delayFrames` later. The scratch buffer's
    /// AudioBufferList is re-pointed at its own storage before every pull because a pull block is allowed to swap the
    /// data pointers for its own; the output list's null data pointers (a host asking the unit to provide memory) are
    /// answered with the pulled buffers, processed in place — the ring exchange reads each input sample before
    /// writing its output slot, so aliasing is safe.
    func render(frameCount: AUAudioFrameCount, timestamp: UnsafePointer<AudioTimeStamp>, outputData: UnsafeMutablePointer<AudioBufferList>, pull: AURenderPullInputBlock) -> AUAudioUnitStatus {
        lock.lock(); defer { lock.unlock() }
        guard let scratch, !rings.isEmpty else { return kAudioUnitErr_Uninitialized }
        guard frameCount <= scratch.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        let frames = Int(frameCount)
        let byteSize = UInt32(frames * MemoryLayout<Float>.stride)
        let input = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
        for channel in 0..<input.count {
            var buffer = input[channel]
            buffer.mData = scratchChannels[channel]
            buffer.mDataByteSize = byteSize
            input[channel] = buffer
        }
        var pullFlags = AudioUnitRenderActionFlags()
        let pullStatus = pull(&pullFlags, timestamp, frameCount, 0, input.unsafeMutablePointer)
        guard pullStatus == noErr else { return pullStatus }
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        guard output.count == input.count, output.count == rings.count else { return kAudioUnitErr_FormatNotSupported }
        for channel in 0..<output.count {
            guard let pulled = input[channel].mData else { return kAudioUnitErr_Uninitialized }
            var outBuffer = output[channel]
            if outBuffer.mData == nil { outBuffer.mData = pulled }
            outBuffer.mDataByteSize = byteSize
            output[channel] = outBuffer
            guard let outData = outBuffer.mData else { return kAudioUnitErr_Uninitialized }
            rings[channel].process(input: pulled.assumingMemoryBound(to: Float.self), output: outData.assumingMemoryBound(to: Float.self), frames: frames)
        }
        return noErr
    }
}

/// The engine's own branch-alignment delay: an in-process `AUAudioUnit` around `SampleExactDelayRing`, registered
/// locally and instantiated like any other effect so it sits mid-graph where a send's branches diverge. It exists
/// because AVAudioEngine offers no other provably transparent mid-graph delay — `AVAudioUnitDelay` colors its wet
/// path — and because the delay amount is only known after the engine has allocated render resources (the moment
/// insert latencies become real), so `configure(delayFrames:)` is called between `start()` and the first render.
final class SampleExactDelayAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("xdly"),
        componentManufacturer: fourCC("aimx"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(SampleExactDelayAudioUnit.self, as: componentDescription, name: "AI Mix Assistant: Sample-Exact Alignment Delay", version: 1)
    }()

    /// Registers the subclass once and instantiates an engine-attachable node in process. The returned pair carries
    /// the typed unit so the engine configures the delay without a cast that could silently do nothing.
    static func makeNode() throws -> (node: AVAudioUnit, unit: SampleExactDelayAudioUnit) {
        _ = registration
        let box = InstantiationBox()
        AVAudioUnit.instantiate(with: componentDescription, options: []) { unit, error in box.complete(unit: unit, error: error) }
        let outcome = box.wait(seconds: 15)
        guard let node = outcome.unit else { throw MixEngineError.alignmentDelayUnavailable(reason: outcome.failure ?? "unknown instantiation failure") }
        guard let unit = node.auAudioUnit as? SampleExactDelayAudioUnit else {
            throw MixEngineError.alignmentDelayUnavailable(reason: "the registered component did not instantiate in process as SampleExactDelayAudioUnit")
        }
        return (node, unit)
    }

    private let state = AlignmentDelayState()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw MixEngineError.alignmentDelayUnavailable(reason: "no standard stereo format is available")
        }
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    /// Sets the whole-frame delay. Legitimate any time before the first render call; the engine calls it right after
    /// reading the graph's real latencies.
    func configure(delayFrames: Int) { state.configure(delayFrames: delayFrames) }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard state.prepare(format: outputBusses[0].format, maximumFrames: max(4096, maximumFramesToRender)) else {
            throw MixEngineError.alignmentDelayUnavailable(reason: "the alignment delay could not allocate its render buffers")
        }
    }

    override func deallocateRenderResources() {
        state.tearDown()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = state
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            return state.render(frameCount: frameCount, timestamp: timestamp, outputData: outputData, pull: pullInputBlock)
        }
    }

    private static func fourCC(_ code: String) -> OSType {
        code.unicodeScalars.reduce(OSType(0)) { ($0 << 8) | OSType($1.value & 0xFF) }
    }
}
