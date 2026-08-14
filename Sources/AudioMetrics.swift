import Foundation
import AVFoundation
import Accelerate

// MARK: - Metric values

/// Share of total spectral energy per fixed analysis band, in percent (0–100). Bands: sub 20–60 Hz, bass 60–250 Hz,
/// low-mid 250–500 Hz, mid 500–2000 Hz, high-mid 2000–6000 Hz, high 6000–20000 Hz.
/// Methodology (fixed, so the numbers stay comparable between files): Welch averaging of Hann-windowed 4096-point
/// real FFTs with 50 % overlap over a mono mixdown (plain channel average) of the whole file; a band's energy is the
/// sum of power-spectrum bins whose centre frequency falls inside the band, expressed relative to the total power of
/// all bins above DC. Bands may sum to slightly less than 100 % because energy below 20 Hz or above 20 kHz (or the
/// file's Nyquist) belongs to no band — that remainder is real signal, not rounding.
struct SpectralBandShares: Codable, Sendable {
    var subPercent: Double; var bassPercent: Double; var lowMidPercent: Double; var midPercent: Double; var highMidPercent: Double; var highPercent: Double
}

/// One silent stretch of the file in seconds. Silence is a measured fact of the exported WAV (Logic renders timeline
/// gaps into the full-track file), detected as consecutive 100 ms windows whose RMS across all channels is below −60 dBFS.
struct SilenceInterval: Codable, Sendable, Equatable { var start: Double; var end: Double }

/// Objective DSP measurements of ONE exported WAV file — facts about that file, never about the Logic project and
/// never a musical judgement. Every fact is `known` only when it was really computed from the file's samples
/// (source = file path); values that do not exist for the material are honest `unavailable`: stereo facts for mono
/// files, and every dB/LUFS level of pure digital silence (its level is −∞, which has no finite dBFS value — the
/// silence map carries that fact instead). `analyzedFileSize`/`analyzedFileModifiedAt` record the exact file identity
/// the numbers were computed from, and double as the cache key that prevents re-analysis of unchanged files.
struct AudioMetrics: Codable, Sendable {
    /// Integrated loudness per ITU-R BS.1770-4: K-weighting (high-shelf + RLB high-pass biquads), 400 ms blocks with
    /// 75 % overlap, absolute −70 LUFS gate then relative −10 LU gate. `unavailable` when every block is gated out.
    var integratedLoudnessLUFS: Fact<Double>
    /// True peak per BS.1770-4 (4× oversampling, polyphase FIR), max over all channels, dBTP.
    var truePeakDBTP: Fact<Double>
    var samplePeakDBFS: Fact<Double>
    var rmsDBFS: Fact<Double>
    /// Crest factor = sample peak − RMS, dB.
    var crestFactorDB: Fact<Double>
    var spectralBands: Fact<SpectralBandShares>
    /// Power-weighted mean frequency of the averaged spectrum, Hz.
    var spectralCentroidHz: Fact<Double>
    /// L/R correlation coefficient (−1…+1). Only for 2-channel files; `unavailable` otherwise or when a channel is all zeros.
    var stereoCorrelation: Fact<Double>
    /// Mid/side energy ratio in dB, mid = (L+R)/2, side = (L−R)/2. `unavailable` for mono and when either energy is
    /// exactly zero (a perfectly mono or perfectly anti-phase signal has no finite ratio).
    var midSideRatioDB: Fact<Double>
    var silenceIntervals: Fact<[SilenceInterval]>
    /// Share of the file's frames inside silent windows, percent 0–100.
    var silencePercent: Fact<Double>
    /// Mean sample value averaged over all channels (a plain number; 0 means no DC offset).
    var dcOffsetMean: Fact<Double>
    /// Samples belonging to runs of ≥ 3 consecutive samples with |x| ≥ 1 − 1e-4 — a count, not a verdict.
    var clippedSampleCount: Fact<Int>
    var analyzedFileSize: Int
    var analyzedFileModifiedAt: Date
}

extension AudioMetrics {
    /// Where the audible material ends, derived from the measured silence map: a silent range that runs to the file's
    /// end is trailing padding, not content — Logic's export and bounce can run past the last region (e.g. to the
    /// project end marker), and the file length then overstates the material. Returns the full duration when the map
    /// proves no trailing silent range; a fully silent file has its content end at 0. Pure and testable.
    static func contentEndSeconds(duration: Double, silence: [SilenceInterval]) -> Double {
        guard let last = silence.last, last.end >= duration - 0.2 else { return duration }
        return last.start
    }
}

// MARK: - Analyzer

/// Local, read-only DSP analysis of an exported WAV. Opens the file via AVAudioFile for reading only and never
/// modifies it; all DSP runs on system frameworks (Accelerate/vDSP), no third-party code. The whole file is processed
/// in streamed chunks, so memory stays flat regardless of file length and a 5-minute stereo file takes seconds.
/// Call it off the main thread (AppModel does, via Task.detached).
struct AudioMetricsAnalyzer: Sendable {
    private static let chunkFrames = 1 << 16
    /// −60 dBFS as mean square, the silence-window threshold.
    private static let silenceMeanSquare = 1e-6
    private static let clipThreshold: Float = 1.0 - 1e-4
    private static let clipRunMinimum = 3

    /// Analyzes one audio file. Returns nil when the file cannot be opened or holds no frames — the caller keeps the
    /// asset without metrics rather than publishing fabricated numbers.
    func analyze(fileAt url: URL) -> AudioMetrics? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int,
              let fileModified = attributes[.modificationDate] as? Date,
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(file.length)
        guard sampleRate > 0, channelCount > 0, totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunkFrames)),
              let kFilter = KWeightingFilter(sampleRate: sampleRate, channels: channelCount) else { return nil }
        let truePeak = TruePeakScanner(channels: channelCount, chunkCapacity: Self.chunkFrames)
        let spectrum = SpectrumAccumulator(sampleRate: sampleRate)

        var channelSums = [Double](repeating: 0, count: channelCount)
        var samplePeak: Float = 0
        var clippedSamples = 0
        var clipRuns = [Int](repeating: 0, count: channelCount)
        var sumLL = 0.0, sumRR = 0.0, sumLR = 0.0
        // 100 ms sub-blocks shared by loudness gating (4 sub-blocks = one 400 ms block at 75 % overlap) and the silence map.
        let subFrames = max(1, Int((sampleRate * 0.1).rounded()))
        var subPosition = 0
        var kSubEnergy = 0.0, rawSubEnergy = 0.0
        var kSubBlocks: [Double] = []
        var rawSubBlocks: [(energy: Double, frames: Int)] = []
        var kOut = [[Float]](repeating: [Float](repeating: 0, count: Self.chunkFrames), count: channelCount)
        var mono = [Float](repeating: 0, count: Self.chunkFrames)

        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(Self.chunkFrames))) != nil else { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<channelCount {
                let samples = data[channel]
                var sum: Float = 0; vDSP_sve(samples, 1, &sum, vDSP_Length(frames)); channelSums[channel] += Double(sum)
                var magnitude: Float = 0; vDSP_maxmgv(samples, 1, &magnitude, vDSP_Length(frames)); samplePeak = max(samplePeak, magnitude)
                if magnitude >= Self.clipThreshold {
                    var run = clipRuns[channel]
                    for index in 0..<frames {
                        if abs(samples[index]) >= Self.clipThreshold {
                            run += 1
                            if run == Self.clipRunMinimum { clippedSamples += Self.clipRunMinimum } else if run > Self.clipRunMinimum { clippedSamples += 1 }
                        } else { run = 0 }
                    }
                    clipRuns[channel] = run
                } else { clipRuns[channel] = 0 }
                truePeak.consume(channel: channel, samples: samples, count: frames)
                kOut[channel].withUnsafeMutableBufferPointer { out in kFilter.filter(channel: channel, input: samples, output: out.baseAddress!, count: frames) }
            }
            if channelCount == 2 {
                var ll: Float = 0; vDSP_svesq(data[0], 1, &ll, vDSP_Length(frames)); sumLL += Double(ll)
                var rr: Float = 0; vDSP_svesq(data[1], 1, &rr, vDSP_Length(frames)); sumRR += Double(rr)
                var lr: Float = 0; vDSP_dotpr(data[0], 1, data[1], 1, &lr, vDSP_Length(frames)); sumLR += Double(lr)
            }
            if channelCount == 1 { spectrum.consume(data[0], count: frames) } else {
                mono.withUnsafeMutableBufferPointer { mix in
                    mix.baseAddress!.update(from: data[0], count: frames)
                    for channel in 1..<channelCount { vDSP_vadd(mix.baseAddress!, 1, data[channel], 1, mix.baseAddress!, 1, vDSP_Length(frames)) }
                    var scale = Float(1) / Float(channelCount)
                    vDSP_vsmul(mix.baseAddress!, 1, &scale, mix.baseAddress!, 1, vDSP_Length(frames))
                    spectrum.consume(mix.baseAddress!, count: frames)
                }
            }
            var offset = 0
            while offset < frames {
                let take = min(subFrames - subPosition, frames - offset)
                for channel in 0..<channelCount {
                    var raw: Float = 0; vDSP_svesq(data[channel] + offset, 1, &raw, vDSP_Length(take)); rawSubEnergy += Double(raw)
                    kOut[channel].withUnsafeBufferPointer { weighted in
                        var energy: Float = 0; vDSP_svesq(weighted.baseAddress! + offset, 1, &energy, vDSP_Length(take)); kSubEnergy += Double(energy)
                    }
                }
                offset += take; subPosition += take
                if subPosition == subFrames {
                    kSubBlocks.append(kSubEnergy); rawSubBlocks.append((rawSubEnergy, subFrames))
                    kSubEnergy = 0; rawSubEnergy = 0; subPosition = 0
                }
            }
        }
        if subPosition > 0 { rawSubBlocks.append((rawSubEnergy, subPosition)) } // trailing partial window counts for silence coverage, never for gating

        let source = url.path
        func decibels(_ meanSquareOrPower: Double) -> Double { 10 * log10(meanSquareOrPower) }

        // Full-file RMS from the silence sub-blocks (they cover every frame of every channel exactly once).
        let totalEnergy = rawSubBlocks.reduce(0) { $0 + $1.energy }
        let meanSquare = totalEnergy / Double(totalFrames * channelCount)
        let rms: Fact<Double> = meanSquare > 0 ? .known(decibels(meanSquare), source: source) : .unavailable
        let peak: Fact<Double> = samplePeak > 0 ? .known(20 * log10(Double(samplePeak)), source: source) : .unavailable
        var crest: Fact<Double> = .unavailable
        if let peakDB = peak.value, let rmsDB = rms.value { crest = .known(peakDB - rmsDB, source: source) }
        let truePeakLinear = max(Double(truePeak.maxMagnitude), Double(samplePeak))
        let truePeakFact: Fact<Double> = truePeakLinear > 0 ? .known(20 * log10(truePeakLinear), source: source) : .unavailable

        // BS.1770-4 gating: block mean square = 4 consecutive 100 ms sub-blocks; loudness −0.691 + 10·log10(z).
        var lufs: Fact<Double> = .unavailable
        if kSubBlocks.count >= 4 {
            let blockFrames = Double(4 * subFrames)
            var blocks: [Double] = []
            blocks.reserveCapacity(kSubBlocks.count - 3)
            for start in 0...(kSubBlocks.count - 4) {
                let energy: Double = kSubBlocks[start] + kSubBlocks[start + 1] + kSubBlocks[start + 2] + kSubBlocks[start + 3]
                blocks.append(energy / blockFrames)
            }
            let absoluteGated = blocks.filter { -0.691 + decibels($0) > -70 }
            if !absoluteGated.isEmpty {
                let relativeThreshold = -0.691 + decibels(absoluteGated.reduce(0, +) / Double(absoluteGated.count)) - 10
                let gated = blocks.filter { let loudness = -0.691 + decibels($0); return loudness > -70 && loudness > relativeThreshold }
                if !gated.isEmpty { lufs = .known(-0.691 + decibels(gated.reduce(0, +) / Double(gated.count)), source: source) }
            }
        }

        var bands: Fact<SpectralBandShares> = .unavailable
        var centroid: Fact<Double> = .unavailable
        if let result = spectrum.finish() { bands = .known(result.bands, source: source); centroid = .known(result.centroidHz, source: source) }

        var correlation: Fact<Double> = .unavailable
        var midSide: Fact<Double> = .unavailable
        if channelCount == 2 {
            if sumLL > 0 && sumRR > 0 { correlation = .known(min(1, max(-1, sumLR / (sumLL * sumRR).squareRoot())), source: source) }
            let midEnergy = (sumLL + 2 * sumLR + sumRR) / 4, sideEnergy = (sumLL - 2 * sumLR + sumRR) / 4
            if midEnergy > 0 && sideEnergy > 0 { midSide = .known(decibels(midEnergy / sideEnergy), source: source) }
        }

        var intervals: [SilenceInterval] = []
        var silentFrames = 0
        var frameCursor = 0
        for block in rawSubBlocks {
            let start = Double(frameCursor) / sampleRate
            let end = Double(frameCursor + block.frames) / sampleRate
            frameCursor += block.frames
            guard block.energy / Double(block.frames * channelCount) < Self.silenceMeanSquare else { continue }
            silentFrames += block.frames
            if let last = intervals.last, last.end == start { intervals[intervals.count - 1].end = end } else { intervals.append(SilenceInterval(start: start, end: end)) }
        }
        let silencePercent = Double(silentFrames) / Double(totalFrames) * 100

        let dcOffset = channelSums.reduce(0, +) / Double(totalFrames * channelCount)
        return AudioMetrics(
            integratedLoudnessLUFS: lufs, truePeakDBTP: truePeakFact, samplePeakDBFS: peak, rmsDBFS: rms, crestFactorDB: crest,
            spectralBands: bands, spectralCentroidHz: centroid, stereoCorrelation: correlation, midSideRatioDB: midSide,
            silenceIntervals: .known(intervals, source: source), silencePercent: .known(silencePercent, source: source),
            dcOffsetMean: .known(dcOffset, source: source), clippedSampleCount: .known(clippedSamples, source: source),
            analyzedFileSize: fileSize, analyzedFileModifiedAt: fileModified)
    }

    /// Attaches metrics to every `exported` asset from its REAL file on disk; assets without a confirmed file never
    /// carry metrics (no fabricated numbers). The cache is keyed by absolute path and an entry is reused only when the
    /// file's size and modification date still match — so Refresh Export Status re-analyzes nothing that did not
    /// change, while a re-exported file is honestly recomputed. Returns the refreshed cache holding only current files.
    func attach(to assets: [AudioAsset], audioDirectory: URL, cache: [String: AudioMetrics]) -> (assets: [AudioAsset], cache: [String: AudioMetrics]) {
        var refreshed: [String: AudioMetrics] = [:]
        var result = assets
        for index in result.indices {
            result[index].metrics = nil
            guard result[index].status == .exported, let relative = result[index].actualExportedPath.value else { continue }
            let url = audioDirectory.appendingPathComponent((relative as NSString).lastPathComponent)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if let hit = cache[url.path], hit.analyzedFileSize == size, hit.analyzedFileModifiedAt == modified {
                result[index].metrics = hit; refreshed[url.path] = hit; continue
            }
            guard let metrics = analyze(fileAt: url) else { continue }
            result[index].metrics = metrics; refreshed[url.path] = metrics
        }
        return (result, refreshed)
    }
}

// MARK: - Streaming DSP helpers

/// Streaming ITU-R BS.1770-4 K-weighting: stage 1 high-shelf, stage 2 RLB high-pass, run as one two-section vDSP
/// biquad cascade with independent delay state per channel so chunked processing is bit-identical to one long pass.
/// The published BS.1770 coefficients are only valid at 48 kHz; both stages are re-derived here for the actual sample
/// rate from the analog design parameters (pre-warped bilinear transform), which reproduces the published 48 kHz
/// coefficients exactly and stays correct for 44.1/96 kHz exports.
private final class KWeightingFilter {
    private let setup: vDSP_biquad_Setup
    private var delays: [[Float]]
    init?(sampleRate: Double, channels: Int) {
        var coefficients = Self.coefficients(sampleRate: sampleRate)
        guard let created = vDSP_biquad_CreateSetup(&coefficients, 2) else { return nil }
        setup = created
        delays = Array(repeating: [Float](repeating: 0, count: 6), count: channels)
    }
    deinit { vDSP_biquad_DestroySetup(setup) }
    func filter(channel: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int) {
        delays[channel].withUnsafeMutableBufferPointer { state in vDSP_biquad(setup, state.baseAddress!, input, 1, output, 1, vDSP_Length(count)) }
    }
    /// vDSP section layout: b0 b1 b2 a1 a2 (a0 normalized to 1). At 48 kHz this evaluates to the exact coefficients
    /// printed in BS.1770-4 (shelf 1.53512485958697 … / high-pass a1 −1.99004745483398, a2 0.99007225036621).
    static func coefficients(sampleRate: Double) -> [Double] {
        let gainDB = 3.999843853973347, shelfF0 = 1681.974450955533, shelfQ = 0.7071752369554196
        let k = tan(.pi * shelfF0 / sampleRate)
        let vh = pow(10, gainDB / 20), vb = pow(vh, 0.4996667741545416)
        let a0: Double = 1 + k / shelfQ + k * k
        let shelfB0: Double = (vh + vb * k / shelfQ + k * k) / a0
        let shelfB1: Double = 2 * (k * k - vh) / a0
        let shelfB2: Double = (vh - vb * k / shelfQ + k * k) / a0
        let shelfA1: Double = 2 * (k * k - 1) / a0
        let shelfA2: Double = (1 - k / shelfQ + k * k) / a0
        let shelf: [Double] = [shelfB0, shelfB1, shelfB2, shelfA1, shelfA2]
        let hpF0 = 38.13547087602444, hpQ = 0.5003270373238773
        let kh = tan(.pi * hpF0 / sampleRate)
        let a0h: Double = 1 + kh / hpQ + kh * kh
        let hpA1: Double = 2 * (kh * kh - 1) / a0h
        let hpA2: Double = (1 - kh / hpQ + kh * kh) / a0h
        let highPass: [Double] = [1.0, -2.0, 1.0, hpA1, hpA2]
        return shelf + highPass
    }
}

/// BS.1770-4 true peak: 4× oversampling via a polyphase interpolation FIR (48-tap Blackman-windowed sinc, 12 taps per
/// phase, per-phase DC gain ≈ 1), evaluated with vDSP_conv. An 11-sample history per channel carries chunk boundaries,
/// so streamed analysis loses no inter-sample peaks.
private final class TruePeakScanner {
    private static let phases = 4
    private static let tapsPerPhase = 12
    private let phaseTaps: [[Float]]
    private var history: [[Float]]
    private var extended: [Float]
    private var upsampled: [Float]
    private(set) var maxMagnitude: Float = 0
    init(channels: Int, chunkCapacity: Int) {
        let taps = Self.phases * Self.tapsPerPhase
        let center = Double(taps - 1) / 2
        let impulse: [Double] = (0..<taps).map { (index: Int) -> Double in
            let x: Double = (Double(index) - center) / Double(Self.phases)
            let sinc: Double = x == 0 ? 1.0 : sin(.pi * x) / (.pi * x)
            let angle: Double = 2 * .pi * Double(index) / Double(taps - 1)
            let window: Double = 0.42 - 0.5 * cos(angle) + 0.08 * cos(2 * angle)
            return sinc * window
        }
        // Reversed per phase because vDSP_conv computes correlation; reversing the taps turns it into convolution.
        phaseTaps = (0..<Self.phases).map { phase in Array(stride(from: phase, to: taps, by: Self.phases).map { Float(impulse[$0]) }.reversed()) }
        history = Array(repeating: [Float](repeating: 0, count: Self.tapsPerPhase - 1), count: channels)
        extended = [Float](repeating: 0, count: chunkCapacity + Self.tapsPerPhase - 1)
        upsampled = [Float](repeating: 0, count: chunkCapacity)
    }
    func consume(channel: Int, samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let carry = Self.tapsPerPhase - 1
        extended.withUnsafeMutableBufferPointer { signal in
            history[channel].withUnsafeBufferPointer { previous in signal.baseAddress!.update(from: previous.baseAddress!, count: carry) }
            (signal.baseAddress! + carry).update(from: samples, count: count)
        }
        extended.withUnsafeBufferPointer { signal in
            upsampled.withUnsafeMutableBufferPointer { output in
                for taps in phaseTaps {
                    taps.withUnsafeBufferPointer { filter in
                        vDSP_conv(signal.baseAddress!, 1, filter.baseAddress!, 1, output.baseAddress!, 1, vDSP_Length(count), vDSP_Length(Self.tapsPerPhase))
                    }
                    var magnitude: Float = 0
                    vDSP_maxmgv(output.baseAddress!, 1, &magnitude, vDSP_Length(count))
                    maxMagnitude = max(maxMagnitude, magnitude)
                }
            }
        }
        if count >= carry { history[channel] = Array(UnsafeBufferPointer(start: samples + count - carry, count: carry)) }
        else { history[channel] = Array(history[channel].dropFirst(count)) + Array(UnsafeBufferPointer(start: samples, count: count)) }
    }
}

/// Welch power-spectrum accumulator over the mono mixdown: Hann-windowed 4096-point real FFT (vDSP), 50 % overlap.
/// Absolute scaling cancels out because only energy shares and the centroid (both ratios) are reported.
private final class SpectrumAccumulator {
    private static let length = 4096
    private static let hop = 2048
    private static let log2Length = vDSP_Length(12)
    private let setup: FFTSetup?
    private let sampleRate: Double
    private var window = [Float](repeating: 0, count: length)
    private var windowed = [Float](repeating: 0, count: length)
    private var real = [Float](repeating: 0, count: length / 2)
    private var imaginary = [Float](repeating: 0, count: length / 2)
    private var magnitudes = [Float](repeating: 0, count: length / 2)
    private var accumulated = [Double](repeating: 0, count: length / 2)
    private var pending: [Float] = []
    private var windowsProcessed = 0
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(Self.log2Length, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.length), Int32(vDSP_HANN_DENORM))
        pending.reserveCapacity(1 << 17)
    }
    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }
    func consume(_ samples: UnsafePointer<Float>, count: Int) {
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        var start = 0
        while pending.count - start >= Self.length { process(at: start); start += Self.hop }
        if start > 0 { pending.removeFirst(start) }
    }
    private func process(at offset: Int) {
        guard let setup else { return }
        let half = Self.length / 2
        pending.withUnsafeBufferPointer { source in vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(Self.length)) }
        real.withUnsafeMutableBufferPointer { realPart in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPart in
                var split = DSPSplitComplex(realp: realPart.baseAddress!, imagp: imaginaryPart.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2Length, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // drop the packed Nyquist term so bin 0 is pure DC
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        for bin in 0..<half { accumulated[bin] += Double(magnitudes[bin]) }
        windowsProcessed += 1
    }
    /// Returns nil for an all-zero signal: a silent file has no spectral distribution to report. A file shorter than
    /// one FFT window is analyzed once, zero-padded (its spectrum is still a fact about all of its samples).
    func finish() -> (bands: SpectralBandShares, centroidHz: Double)? {
        if windowsProcessed == 0 {
            guard !pending.isEmpty else { return nil }
            pending.append(contentsOf: [Float](repeating: 0, count: Self.length - pending.count))
            process(at: 0)
        }
        let binWidth = sampleRate / Double(Self.length)
        let edges: [(Double, Double)] = [(20, 60), (60, 250), (250, 500), (500, 2000), (2000, 6000), (6000, 20000)]
        var bandEnergy = [Double](repeating: 0, count: edges.count)
        var total = 0.0, weighted = 0.0
        for bin in 1..<(Self.length / 2) {
            let frequency = Double(bin) * binWidth
            let power = accumulated[bin]
            total += power; weighted += frequency * power
            if let band = edges.firstIndex(where: { frequency >= $0.0 && frequency < $0.1 }) { bandEnergy[band] += power }
        }
        guard total > 0 else { return nil }
        let percent = bandEnergy.map { $0 / total * 100 }
        return (SpectralBandShares(subPercent: percent[0], bassPercent: percent[1], lowMidPercent: percent[2], midPercent: percent[3], highMidPercent: percent[4], highPercent: percent[5]), weighted / total)
    }
}
