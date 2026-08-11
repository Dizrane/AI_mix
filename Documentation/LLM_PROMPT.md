# LLM contract

The system prompt states that the LLM is the decision maker and must use only supplied facts. It returns strict `MixPlan` JSON, or `status: "request_probe"` with no actions when data is missing. The LLM layer is provider-neutral; configure an OpenAI-compatible transport and credentials through an app-specific secure settings implementation before production use.
