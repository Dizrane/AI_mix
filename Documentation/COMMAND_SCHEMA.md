# Command schema

`MixPlan` is JSON: `version`, `status`, and `actions`. Every action has `id`, `target`, `action`, `parameters`, `reason`.

The complete declared vocabulary is in `MixAction`; the current safe executor supports validation of volume, pan, mute, solo, plugin bypass, and plugin parameters. Unsupported actions are explicitly rejected. Every implemented action requires a typed `parameters.value`: numeric for `set_volume` / `set_pan` / `set_plugin_parameter`, boolean for `set_mute` / `set_solo` / `set_plugin_bypass`; a missing or mistyped value is invalid. Plugin parameter changes additionally require an observed plugin, observed parameter, and reported range when present. The Review screen accepts the plan as a bare JSON object or inside a Markdown code fence (```json … ```), including a fence pasted with surrounding prose.

Example:

```json
{"version":"1.0","status":"ready","actions":[{"id":"volume_1","target":{"trackID":"aux"},"action":"set_volume","parameters":{"value":-3.0},"reason":"LLM-provided rationale"}]}
```
