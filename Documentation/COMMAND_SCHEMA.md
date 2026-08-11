# Command schema

`MixPlan` is JSON: `version`, `status`, and `actions`. Every action has `id`, `target`, `action`, `parameters`, `reason`.

The complete declared vocabulary is in `MixAction`; the current safe executor supports validation of volume, pan, mute, solo, plugin bypass, and plugin parameters. Unsupported actions are explicitly rejected. Plugin parameter changes require an observed plugin, observed parameter, numeric value, and reported range when present.

Example:

```json
{"version":"1.0","status":"ready","actions":[{"id":"volume_1","target":{"trackID":"aux"},"action":"set_volume","parameters":{"value":-3.0},"reason":"LLM-provided rationale"}]}
```
