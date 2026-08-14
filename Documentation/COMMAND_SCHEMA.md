# Command schema

`MixPlan` is JSON: `version`, `status`, and `actions`. Every action has `id`, `target`, `action`, `parameters`, `reason`.

The complete declared vocabulary is in `MixAction`; the current safe executor supports validation of volume, pan, mute, solo, plugin bypass, and plugin parameters. Unsupported actions are explicitly rejected. Every implemented action requires a typed `parameters.value` holding the absolute target setting (never a relative change): numeric for `set_volume` / `set_pan` / `set_plugin_parameter`, boolean for `set_mute` / `set_solo` / `set_plugin_bypass`; a missing or mistyped value is invalid. `set_volume` must sit inside Logic's fader range −96…+6 dB and `set_pan` inside −64…+63 (`CommandValidator.volumeRangeDB` / `panRange`); out-of-range values are invalid. Action ids must be unique within the plan and `reason` must be non-empty — the validated plan is the user's manual instruction sheet (no live executor exists), so each action carries its own justification. Plugin parameter changes additionally require an observed plugin, observed parameter, and reported range when present. The Review screen accepts the plan as a bare JSON object or inside a Markdown code fence (```json … ```), including a fence pasted with surrounding prose, and displays each action's target value and reason.

Example:

```json
{"version":"1.0","status":"ready","actions":[{"id":"volume_1","target":{"trackID":"aux"},"action":"set_volume","parameters":{"value":-3.0},"reason":"LLM-provided rationale"}]}
```
