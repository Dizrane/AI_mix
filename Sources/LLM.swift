import Foundation

protocol LLMProvider: Sendable { var displayName: String { get }; func requestPlan(context: LLMContext) async throws -> MixPlan }
struct LLMContext: Codable, Sendable { var snapshot: NormalizedSnapshot; var probes: [ProbeResult]; var priorResults: [ExecutionResult] }
enum LLMError: LocalizedError { case notConfigured, malformedResponse; var errorDescription: String? { self == .notConfigured ? "No LLM provider is configured." : "The provider did not return a valid MixPlan JSON." } }
struct OpenAICompatibleProvider: LLMProvider { let endpoint: URL; let apiKey: String; let model: String; var displayName: String { "OpenAI-compatible" }
    func requestPlan(context: LLMContext) async throws -> MixPlan { throw LLMError.notConfigured } // Transport intentionally awaits app-specific credential configuration.
}
struct DisabledLLMProvider: LLMProvider { var displayName: String { "Not configured" }; func requestPlan(context: LLMContext) async throws -> MixPlan { throw LLMError.notConfigured } }
enum PromptBuilder { static func systemPrompt() -> String { "You are the mixing decision-maker. Return only MixPlan JSON. Use only known facts. If facts are insufficient, return status request_probe and no actions. Never invent tracks, plugins, parameters, or values." } }
