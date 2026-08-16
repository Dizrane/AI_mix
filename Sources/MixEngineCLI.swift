import Foundation

/// Debug-only lab bench for `MixEngine`: `swift run "AI Mix Assistant" mix-render <wav-folder> <mixgraph.json>`
/// renders `mix.wav` next to the input WAVs and prints the measured facts. It is a test rig, not product UI — the
/// entry point in `AIMixAssistantApp` compiles it in DEBUG builds only, and it never touches Logic or the app's data.
enum MixEngineCLI {
    /// Runs the subcommand and exits the process when the first argument requests it; returns silently otherwise so
    /// the ordinary SwiftUI launch proceeds.
    static func runAndExitIfRequested(arguments: [String]) {
        guard arguments.first == "mix-render" else { return }
        exit(run(arguments: Array(arguments.dropFirst())))
    }

    /// `mix-render` body, separated from `exit` so it is testable: arguments are `<wav-folder> <mixgraph.json>` plus
    /// optional `--tail <seconds>`, `--int24` and `--no-bus-metrics`. Returns the process exit code.
    static func run(arguments: [String]) -> Int32 {
        var positional: [String] = []
        var options = MixEngine.Options(tailSeconds: 2, output: .float32, measureBuses: true)
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
        let outputURL = folder.appendingPathComponent("mix.wav")
        do {
            let result = try MixEngine().render(graph: graph, folder: folder, outputURL: outputURL, options: options)
            print(report(for: result))
            return 0
        } catch {
            return fail((error as? MixEngineError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static let usage = "Usage: mix-render <wav-folder> <mixgraph.json> [--tail <seconds>] [--int24] [--no-bus-metrics]"

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("mix-render: " + message + "\n").utf8))
        return 1
    }

    /// Human-readable render report: the output location, every insert's parameter write/read-back, and the measured
    /// facts (numbers only — judging them is the caller's job).
    static func report(for result: MixRenderResult) -> String {
        var lines = ["Rendered \(result.outputURL.path) (\(plural(result.renderedFrames, "frame")) at \(Int(result.sampleRate)) Hz)."]
        if !result.inserts.isEmpty {
            lines.append("Inserts:")
            for insert in result.inserts {
                lines.append("  \(insert.location): \(insert.resolvedName) [\(insert.resolvedIdentifier)] (requested \"\(insert.requested)\")")
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
