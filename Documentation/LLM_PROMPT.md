# LLM contract

No API transport ships in this application: the user hands the stage-4 AI Package to any external LLM themselves and pastes the answer back into the Review screen (stage 5). The package's own `AI_MIX_ANALYSIS.md` is the complete, self-contained instruction for the model — `AIPackageGenerator` embeds the workflow, the evidence rules and the machine-validated Mix Plan schema in the document itself, in two honest deliveries (full package with WAVs, or the Markdown alone).

The contract the document teaches: the model is the decision maker and works only from supplied facts (states other than `known` are not evidence and are never guessed). The workflow is human-in-the-loop in two strictly separated replies — the first delivers ANALYSIS / INTERPRETATION / ISSUES / QUESTIONS and no plan; only after the user's confirmation does the second deliver `MIX PLAN` (exactly one JSON block conforming to the `MixPlan` schema, see `COMMAND_SCHEMA.md`) plus `MANUAL STEPS` for everything the schema cannot encode. A pre-delivery checklist in the package mirrors exactly what the stage-5 validator rejects.

The `LLMProvider` protocol remains provider-neutral for a future in-app transport; none is configured or required today.
