import Testing
import Foundation
import AVFoundation
@testable import AIMixAssistant

// MARK: - Fixtures
// The child-process contract is proven WITHOUT loading a single third-party plugin: the outcome classification is a
// pure function fed with fabricated termination facts, the result-file round-trip uses a hand-built result, and the
// launch plumbing is exercised against tiny shell commands (exit codes, stderr, a real SIGABRT, a real timeout kill)
// — the same observable facts a crashing or hanging plugin would produce.

private func sampleRenderResult(outputPath: String = "/tmp/mix.wav") -> MixRenderResult {
    let metrics = AudioMetrics(
        integratedLoudnessLUFS: .known(-14.2, source: "test"), truePeakDBTP: .known(-1.0), samplePeakDBFS: .known(-1.3),
        rmsDBFS: .known(-18.0), crestFactorDB: .known(16.7), spectralBands: .unavailable, spectralCentroidHz: .known(950),
        stereoCorrelation: .unavailable, midSideRatioDB: .unavailable, silenceIntervals: .known([SilenceInterval(start: 0, end: 0.5)]),
        silencePercent: .known(4.2), dcOffsetMean: .known(0), clippedSampleCount: .known(0),
        analyzedFileSize: 1234, analyzedFileModifiedAt: Date(timeIntervalSince1970: 1_000_000))
    return MixRenderResult(
        outputURL: URL(fileURLWithPath: outputPath), sampleRate: 48000, renderedFrames: 96000, compensatedLatencyFrames: 512,
        inserts: [MixInsertReport(location: "track \"Kick\" insert 1", requested: "aufx/pmeq/appl", resolvedName: "AUParametricEQ",
                                  resolvedIdentifier: "aufx/pmeq/appl",
                                  parameters: [MixAppliedParameter(key: "0", resolvedIdentifier: "frequency", resolvedName: "Frequency",
                                                                   requestedValue: 90, readBackValue: 90, verified: true)],
                                  latencySeconds: 0.001, latencyFrames: 48)],
        mixMetrics: metrics, busMetrics: ["verb": metrics], notes: ["existing note"])
}

private func encoded(_ result: MixRenderResult) throws -> Data { try JSONEncoder().encode(result) }

/// Writes a constant-amplitude stereo WAV and returns only after the writer is released, so the file is fully flushed
/// before anything reads it back.
private func writeConstantStereoWAV(_ url: URL, frames: Int, amplitude: Float) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<2 { for index in 0..<frames { buffer.floatChannelData![channel][index] = amplitude } }
    try file.write(from: buffer)
}

// MARK: - Result file round-trip

@Test func renderResultRoundTripsThroughJSON() throws {
    let original = sampleRenderResult()
    let decoded = try JSONDecoder().decode(MixRenderResult.self, from: encoded(original))
    #expect(decoded.outputURL.path == original.outputURL.path)
    #expect(decoded.sampleRate == original.sampleRate)
    #expect(decoded.renderedFrames == original.renderedFrames)
    #expect(decoded.compensatedLatencyFrames == original.compensatedLatencyFrames)
    #expect(decoded.notes == original.notes)
    #expect(decoded.inserts.count == 1)
    #expect(decoded.inserts[0].location == "track \"Kick\" insert 1")
    #expect(decoded.inserts[0].latencyFrames == 48)
    #expect(decoded.inserts[0].parameters[0].resolvedIdentifier == "frequency")
    #expect(decoded.inserts[0].parameters[0].verified)
    #expect(decoded.mixMetrics?.integratedLoudnessLUFS == .known(-14.2, source: "test"))
    #expect(decoded.busMetrics["verb"]?.clippedSampleCount == .known(0))
}

// MARK: - Outcome classification (pure)

@Test func classifyCleanExitWithResultFileSucceedsWithoutANote() throws {
    let outcome = RenderChildProcess.classify(resultFileData: try encoded(sampleRenderResult()), termination: .exited(code: 0), standardError: "")
    guard case .success(let success) = outcome else { Issue.record("expected success"); return }
    #expect(success.postRenderNote == nil)
    #expect(success.result.renderedFrames == 96000)
}

@Test func classifyCrashAfterResultSucceedsAndNamesTheSignal() throws {
    let outcome = RenderChildProcess.classify(resultFileData: try encoded(sampleRenderResult()), termination: .signalled(signal: SIGABRT), standardError: "malloc: *** error")
    guard case .success(let success) = outcome else { Issue.record("expected success"); return }
    let note = try #require(success.postRenderNote)
    #expect(note.contains("signal \(SIGABRT)"))
    #expect(note.contains("AFTER"))
    #expect(note.contains("intact"))
}

@Test func classifyCrashBeforeResultFailsNamingSignalAndStderr() {
    let outcome = RenderChildProcess.classify(resultFileData: nil, termination: .signalled(signal: SIGSEGV), standardError: "plugin exploded\n")
    guard case .failure(let failure) = outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("no result file"))
    #expect(failure.message.contains("signal \(SIGSEGV)"))
    #expect(failure.message.contains("plugin exploded"))
}

@Test func classifyNamedRefusalExitFailsQuotingStderrAndExitCode() {
    let outcome = RenderChildProcess.classify(resultFileData: nil, termination: .exited(code: 1), standardError: "mix-render: Track \"Kick\": the input WAV cannot be opened.")
    guard case .failure(let failure) = outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("exit code 1"))
    #expect(failure.message.contains("the input WAV cannot be opened"))
}

@Test func classifyTimeoutFailsByName() {
    let outcome = RenderChildProcess.classify(resultFileData: nil, termination: .timedOut(seconds: 900), standardError: "")
    guard case .failure(let failure) = outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("900 s"))
    #expect(failure.message.contains("nothing to stderr"))
}

@Test func classifyUndecodableResultFileFailsByName() {
    let outcome = RenderChildProcess.classify(resultFileData: Data("not json".utf8), termination: .exited(code: 0), standardError: "")
    guard case .failure(let failure) = outcome else { Issue.record("expected failure"); return }
    #expect(failure.message.contains("could not be decoded"))
}

// MARK: - Launch plumbing (real child processes, no plugins)

@Test func launchCollectsExitCodeStdoutAndStderr() async throws {
    let run = try await RenderChildProcess.launchAndWait(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], timeoutSeconds: 30)
    #expect(run.termination == .exited(code: 3))
    #expect(run.standardOutput.contains("out"))
    #expect(run.standardError.contains("err"))
}

@Test func launchReportsAnUncaughtSignal() async throws {
    let run = try await RenderChildProcess.launchAndWait(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -ABRT $$"], timeoutSeconds: 30)
    #expect(run.termination == .signalled(signal: SIGABRT))
}

@Test func launchKillsAHungChildAtTheTimeout() async throws {
    let started = Date()
    let run = try await RenderChildProcess.launchAndWait(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], timeoutSeconds: 1)
    #expect(run.termination == .timedOut(seconds: 1))
    #expect(Date().timeIntervalSince(started) < 30)
}

@Test func launchRefusesAMissingExecutableByName() async {
    await #expect(throws: RenderChildFailure.self) {
        _ = try await RenderChildProcess.launchAndWait(executable: URL(fileURLWithPath: "/nonexistent/binary"), arguments: [], timeoutSeconds: 1)
    }
}

// MARK: - CLI sentinel contract (real render through MixEngine, Apple-only graph)

@Test func cliWritesTheResultFileAfterTheMixAndItDecodes() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("renderchild-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let frames = 4800
    try writeConstantStereoWAV(dir.appendingPathComponent("a.wav"), frames: frames, amplitude: 0.25)
    let graphURL = dir.appendingPathComponent("mixgraph.json")
    try Data(#"{"schemaVersion":"1.0","tracks":[{"name":"A","file":"a.wav"}]}"#.utf8).write(to: graphURL)
    let outputURL = dir.appendingPathComponent("rendered").appendingPathComponent("mix.wav")
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let resultURL = dir.appendingPathComponent("render_result.json")
    let code = MixEngineCLI.run(arguments: [dir.path, graphURL.path, "--tail", "0", "--output", outputURL.path, "--result", resultURL.path])
    #expect(code == 0)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let decoded = try JSONDecoder().decode(MixRenderResult.self, from: Data(contentsOf: resultURL))
    #expect(decoded.outputURL.path == outputURL.path)
    #expect(decoded.renderedFrames == frames)
    #expect(decoded.sampleRate == 48000)
}

@Test func cliRefusalWritesNoResultFile() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("renderchild-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let graphURL = dir.appendingPathComponent("mixgraph.json")
    try Data(#"{"schemaVersion":"1.0","tracks":[{"name":"A","file":"missing.wav"}]}"#.utf8).write(to: graphURL)
    let resultURL = dir.appendingPathComponent("render_result.json")
    let code = MixEngineCLI.run(arguments: [dir.path, graphURL.path, "--result", resultURL.path])
    #expect(code == 1)
    #expect(!FileManager.default.fileExists(atPath: resultURL.path))
}
