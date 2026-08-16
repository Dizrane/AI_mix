import Foundation

/// The render child process (and the lab bench): `mix-render <wav-folder> <mixgraph.json>` renders `mix.wav`
/// through `MixEngine` — no UI, no Logic, none of the app's data — and prints the measured facts. It is compiled
/// into every build because the app launches ITSELF with this subcommand for each render (`RenderChildProcess`), so
/// a plugin crash kills only this short-lived child, never the UI. `--result <path>` is the parent's contract: the
/// result file carries the `MixRenderResult` facts as JSON and is written atomically only AFTER `mix.wav` is
/// complete, so its presence proves the render finished even when a plugin then kills the child during teardown.
enum MixEngineCLI {
    /// Runs the subcommand and exits the process when the first argument requests it; returns silently otherwise so
    /// the ordinary SwiftUI launch proceeds.
    static func runAndExitIfRequested(arguments: [String]) {
        guard arguments.first == "mix-render" else { return }
        exit(run(arguments: Array(arguments.dropFirst())))
    }

    /// `mix-render` body, separated from `exit` so it is testable: arguments are `<wav-folder> <mixgraph.json>` plus
    /// optional `--tail <seconds>`, `--int24`, `--no-bus-metrics`, `--output <path>` (defaults to `mix.wav` next to
    /// the inputs) and `--result <path>` (the JSON result file, written atomically after the mix — the parent's
    /// completion sentinel). Returns the process exit code.
    static func run(arguments: [String]) -> Int32 {
        var positional: [String] = []
        var options = MixEngine.Options(tailSeconds: 2, output: .float32, measureBuses: true)
        var outputPath: String?
        var resultPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--tail":
                guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]), seconds >= 0 else { return fail("--tail requires a non-negative number of seconds.") }
                options.tailSeconds = seconds
                index += 2
            case "--int24":
                options.output = .int24
                index += 1
            case "--no-bus-metrics":
                options.measureBuses = false
                index += 1
            case "--output":
                guard index + 1 < arguments.count else { return fail("--output requires a file path.") }
                outputPath = arguments[index + 1]
                index += 2
            case "--result":
                guard index + 1 < arguments.count else { return fail("--result requires a file path.") }
                resultPath = arguments[index + 1]
                index += 2
            default:
                guard !argument.hasPrefix("--") else { return fail("Unknown option \(argument).\n\(usage)") }
                positional.append(argument)
                index += 1
            }
        }
        guard positional.count == 2 else { return fail(usage) }
        let folder = URL(fileURLWithPath: positional[0], isDirectory: true)
        let graphURL = URL(fileURLWithPath: positional[1])
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else { return fail("\(folder.path) is not a folder.") }
        let graph: MixGraph
        do { graph = try JSONDecoder().decode(MixGraph.self, from: try Data(contentsOf: graphURL)) }
        catch { return fail("Could not load the MixGraph JSON at \(graphURL.path): \(error.localizedDescription)") }
        let outputURL = outputPath.map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("mix.wav")
        do {
            let result = try MixEngine().render(graph: graph, folder: folder, outputURL: outputURL, options: options)
            // The result file is the completion sentinel: written atomically, strictly after `render` returned with
            // `mix.wav` complete and closed, and before anything else — so a plugin that corrupts the process during
            // the still-pending Audio Unit teardown (deallocation the runtime may run any time after this point)
            // kills the child AFTER everything of value is on disk.
            if let resultPath {
                let resultURL = URL(fileURLWithPath: resultPath)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do { try encoder.encode(result).write(to: resultURL, options: .atomic) }
                catch { return fail("The render completed but the result file at \(resultURL.path) could not be written: \(error.localizedDescription)") }
            }
            print(report(for: result))
            return 0
        } catch {
            return fail((error as? MixEngineError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static let usage = "Usage: mix-render <wav-folder> <mixgraph.json> [--tail <seconds>] [--int24] [--no-bus-metrics] [--output <path>] [--result <path>]"

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("mix-render: " + message + "\n").utf8))
        return 1
    }

    /// Human-readable render report: the output location, every insert's parameter write/read-back, and the measured
    /// facts (numbers only — judging them is the caller's job).
    static func report(for result: MixRenderResult) -> String {
        var lines = ["Rendered \(result.outputURL.path) (\(plural(result.renderedFrames, "frame")) at \(Int(result.sampleRate)) Hz)."]
        lines.append("Compensated latency: \(plural(result.compensatedLatencyFrames, "frame")) — every parallel path aligned before summing, the head trimmed so the mix stays at t=0.")
        if !result.inserts.isEmpty {
            lines.append("Inserts:")
            for insert in result.inserts {
                lines.append("  \(insert.location): \(insert.resolvedName) [\(insert.resolvedIdentifier)] (requested \"\(insert.requested)\")")
                lines.append("    reported latency: \(plural(insert.latencyFrames, "frame")) (\(String(format: "%.3f", insert.latencySeconds * 1000)) ms, from auAudioUnit.latency)")
                for parameter in insert.parameters {
                    let verdict = parameter.verified ? "verified" : "READ-BACK DIFFERS"
                    lines.append("    \(parameter.key) → \(parameter.resolvedName) [\(parameter.resolvedIdentifier)]: set \(parameter.requestedValue), read back \(parameter.readBackValue) (\(verdict))")
                }
            }
        }
        lines.append("Measured mix facts:")
        lines.append(contentsOf: metricLines(result.mixMetrics, indent: "  "))
        for (name, metrics) in result.busMetrics.sorted(by: { $0.key < $1.key }) {
            lines.append("Measured bus \"\(name)\" facts (best-effort tap):")
            lines.append(contentsOf: metricLines(metrics, indent: "  "))
        }
        for note in result.notes { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }

    private static func metricLines(_ metrics: AudioMetrics?, indent: String) -> [String] {
        guard let metrics else { return [indent + "unavailable — the rendered file could not be analyzed."] }
        func level(_ fact: Fact<Double>, _ unit: String) -> String { fact.value.map { String(format: "%.2f %@", $0, unit) } ?? "unavailable" }
        return [
            indent + "integrated loudness: \(level(metrics.integratedLoudnessLUFS, "LUFS"))",
            indent + "true peak: \(level(metrics.truePeakDBTP, "dBTP"))",
            indent + "sample peak: \(level(metrics.samplePeakDBFS, "dBFS"))",
            indent + "RMS: \(level(metrics.rmsDBFS, "dBFS"))",
            indent + "clipped samples: \(metrics.clippedSampleCount.value.map(String.init) ?? "unavailable")"
        ]
    }
}
