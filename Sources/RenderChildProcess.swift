import Foundation

// MARK: - Why a child process at all
//
// An offline render loads third-party Audio Unit plugins into the rendering process itself (AUv2 units cannot load
// out-of-process), and a plugin bug anywhere — load, processing, or teardown — kills that process in ways Swift
// cannot catch: a real v0.2.37 crash report shows Slate Digital's SlateCore framework calling free() on a pointer it
// never allocated while -[AVAudioNode dealloc] tore the graph down, and libmalloc aborting the whole app with
// SIGABRT — AFTER the render had already completed. AVAudioEngine's NSExceptions (e.g. a rejected connection format)
// are equally uncatchable. So the app never renders in its own process: each render runs the app's own binary as a
// short-lived `mix-render` child, and the contract below makes the parent independent of the child's clean exit —
// the child writes `mix.wav`, then the JSON result file (the facts of `MixRenderResult`) atomically LAST, so a
// present, decodable result file proves the render finished even when the child died during plugin teardown.

/// How the child render process ended — the fact the outcome classification pairs with the result file's presence.
enum RenderChildTermination: Sendable, Equatable {
    /// The child exited on its own; 0 is the clean exit, anything else is the CLI's named refusal (already on stderr).
    case exited(code: Int32)
    /// The child was killed by an uncaught signal — a plugin crash (SIGABRT, SIGSEGV, …), not a named refusal.
    case signalled(signal: Int32)
    /// The child made no progress within the allowed time and was killed by the parent — most likely a hung plugin.
    case timedOut(seconds: Double)

    /// "signal 6 (Abort trap: 6)" / "exit code 1" / "killed after 900 s" — the phrase failure messages and notes use.
    var phrase: String {
        switch self {
        case .exited(let code): "exit code \(code)"
        case .signalled(let signal): "signal \(signal) (\(String(cString: strsignal(signal))))"
        case .timedOut(let seconds): "killed by the app after \(Int(seconds)) s without finishing"
        }
    }
}

/// A named refusal of a child render: what the child produced (or did not), how it ended, and what it said on stderr
/// — the one sentence the Render screen shows. Never a silent retry, never a bypass.
struct RenderChildFailure: Error, Equatable, Sendable { let message: String }

/// A render the child really delivered: the decoded result file, plus the honest note when the child died AFTER
/// writing it — the mix and its measured facts are intact, and the post-render crash is named instead of hidden.
struct RenderChildSuccess: Sendable {
    var result: MixRenderResult
    var postRenderNote: String?
}

/// Launches, supervises and classifies the `mix-render` child process. The pure classification (`classify`) is
/// separated from the launch plumbing so the outcome rules are testable without loading a single real plugin.
enum RenderChildProcess {
    /// Generous ceiling for one offline render. Offline rendering is faster than real time on any material this app
    /// exports, so a child still running after this long is a hung plugin, not a slow mix — it is killed and the
    /// failure named. Deliberately generous: killing a working render would be worse than waiting.
    static let timeoutSeconds: Double = 15 * 60

    // MARK: Orchestration

    /// One full child render: writes the graph JSON next to the output, clears any stale result file, launches the
    /// app's own binary with the `mix-render` subcommand, waits (with the timeout above), and classifies the outcome
    /// from the result file and the termination facts.
    static func render(graph: MixGraph, audioFolder: URL, outputURL: URL, graphURL: URL, resultURL: URL) async -> Result<RenderChildSuccess, RenderChildFailure> {
        guard let executable = Bundle.main.executableURL else {
            return .failure(.init(message: "The app's own executable could not be located, so the render child process cannot be launched."))
        }
        do { try JSONEncoder().encode(graph).write(to: graphURL, options: .atomic) }
        catch { return .failure(.init(message: "The MixGraph could not be written to \(graphURL.path) for the child process: \(error.localizedDescription)")) }
        // A stale result file from a previous render must never masquerade as this render's sentinel.
        try? FileManager.default.removeItem(at: resultURL)
        let run: RenderChildRun
        do {
            run = try await launchAndWait(executable: executable,
                                          arguments: ["mix-render", audioFolder.path, graphURL.path, "--output", outputURL.path, "--result", resultURL.path],
                                          timeoutSeconds: timeoutSeconds)
        } catch {
            return .failure(error as? RenderChildFailure ?? .init(message: error.localizedDescription))
        }
        return classify(resultFileData: try? Data(contentsOf: resultURL), termination: run.termination, standardError: run.standardError)
    }

    // MARK: Outcome classification (pure)

    /// The outcome rules, in one testable place. A valid result file is the completion sentinel — the child writes it
    /// atomically only after `mix.wav` is complete — so its presence means success even when the child then died
    /// during plugin teardown (exactly the observed SlateCore crash); the death is named in a note, never hidden. No
    /// result file means the render never finished: a named failure quoting how the child ended and what it wrote to
    /// stderr. A result file that exists but does not decode is equally a named failure — a half-truth is not a mix.
    static func classify(resultFileData: Data?, termination: RenderChildTermination, standardError: String) -> Result<RenderChildSuccess, RenderChildFailure> {
        if let data = resultFileData {
            do {
                let result = try JSONDecoder().decode(MixRenderResult.self, from: data)
                return .success(.init(result: result, postRenderNote: postRenderNote(for: termination)))
            } catch {
                return .failure(.init(message: "The render child process left a result file that could not be decoded (\(error.localizedDescription)); the child ended with \(termination.phrase).\(stderrSuffix(standardError))"))
            }
        }
        return .failure(.init(message: "The render child process produced no result file, so the render did not complete; the child ended with \(termination.phrase).\(stderrSuffix(standardError))"))
    }

    /// The honest note a crash-after-result earns: the mix and its facts are intact, and the reader learns exactly
    /// how the child died anyway. A clean exit earns no note.
    private static func postRenderNote(for termination: RenderChildTermination) -> String? {
        switch termination {
        case .exited(let code) where code == 0: nil
        case .exited: "the render child process exited with \(termination.phrase) AFTER writing the complete result — the mix and its measured facts are intact."
        case .signalled: "the render child process crashed with \(termination.phrase) AFTER the render and its result were fully written — a plugin most likely failed during Audio Unit teardown; the mix and its measured facts are intact."
        case .timedOut(let seconds): "the render child process hung AFTER writing the complete result and was killed by the app after \(Int(seconds)) s — a plugin most likely hung during Audio Unit teardown; the mix and its measured facts are intact."
        }
    }

    private static func stderrSuffix(_ standardError: String) -> String {
        let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? " The child wrote nothing to stderr." : " Child stderr: \(trimmed)"
    }

    // MARK: Launch plumbing

    struct RenderChildRun: Sendable {
        var termination: RenderChildTermination
        var standardOutput: String
        var standardError: String
    }

    /// How long the supervisor still waits after SIGKILL for the termination callback, and after termination for the
    /// pipes' EOF. Deliberately short and, above all, FINITE: every wait in the supervisor is bounded, so a broken
    /// callback or a lost EOF degrades into a named outcome with partial output instead of a hang.
    private static let supervisorGraceSeconds: Double = 10

    /// Runs the child and waits for it, asynchronously: the blocking waits (semaphores, pipe reads) run on a GCD
    /// utility thread, never on the Swift Concurrency cooperative pool — parking a cooperative thread would starve
    /// every other task in the process (in the app and, worse, in the test runner, where a handful of blocked tests
    /// freeze the whole suite). Stdout and stderr are drained concurrently (a full pipe buffer would otherwise
    /// deadlock a chatty child against a waiting parent), the timeout is enforced with SIGKILL — a hung plugin may
    /// ignore SIGTERM, and the result file, not the exit, is the completion sentinel, so nothing of value is lost by
    /// killing hard — and every wait is bounded. Throws `RenderChildFailure` only when the process cannot be
    /// launched at all.
    static func launchAndWait(executable: URL, arguments: [String], timeoutSeconds: Double) async throws -> RenderChildRun {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: supervise(executable: executable, arguments: arguments, timeoutSeconds: timeoutSeconds))
            }
        }
    }

    /// The blocking supervisor body; runs entirely on one GCD thread.
    private static func supervise(executable: URL, arguments: [String], timeoutSeconds: Double) -> Result<RenderChildRun, RenderChildFailure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let standardOutput = DrainedPipe()
        let standardError = DrainedPipe()
        process.standardOutput = standardOutput.pipe
        process.standardError = standardError.pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return .failure(.init(message: "The render child process could not be launched (\(executable.path)): \(error.localizedDescription)")) }
        standardOutput.startDraining()
        standardError.startDraining()
        var timedOut = false
        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            timedOut = true
            kill(process.processIdentifier, SIGKILL)
            // SIGKILL cannot be caught or ignored, so termination follows promptly — but the wait for the callback
            // is still bounded: a lost callback yields the honest timeout outcome instead of hanging forever.
            _ = finished.wait(timeout: .now() + supervisorGraceSeconds)
        }
        let termination: RenderChildTermination = timedOut
            ? .timedOut(seconds: timeoutSeconds)
            : (process.terminationReason == .uncaughtSignal ? .signalled(signal: process.terminationStatus) : .exited(code: process.terminationStatus))
        return .success(RenderChildRun(termination: termination,
                                       standardOutput: standardOutput.drainedText(timeoutSeconds: supervisorGraceSeconds),
                                       standardError: standardError.drainedText(timeoutSeconds: supervisorGraceSeconds)))
    }

    /// One pipe whose read end is drained on a background queue while the parent waits for the child. The lock
    /// guards `collected` between the draining thread and the final read; the semaphore marks EOF. The final read is
    /// bounded: if EOF never arrives (nothing on a healthy system holds the write end open after the child died,
    /// but the supervisor refuses to bet a hang on it), whatever was collected so far is returned.
    private final class DrainedPipe: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var collected = Data()
        private let finished = DispatchSemaphore(value: 0)
        func startDraining() {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = self.pipe.fileHandleForReading.availableData // blocks until data or EOF
                    if chunk.isEmpty { break }
                    self.lock.lock(); self.collected.append(chunk); self.lock.unlock()
                }
                self.finished.signal()
            }
        }
        func drainedText(timeoutSeconds: Double) -> String {
            _ = finished.wait(timeout: .now() + timeoutSeconds)
            lock.lock(); defer { lock.unlock() }
            return String(data: collected, encoding: .utf8) ?? ""
        }
    }
}
