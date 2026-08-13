# Analyzer and probes

`LogicAccessibilityAnalyzer.fullScan()` finds the actual running `com.apple.logic10` process, checks Accessibility trust, and recursively copies attributes from AX elements. It never invokes AX set operations, menus, keys, AppleScript, or screen coordinates.

Before the scan starts, the app makes Logic's Mixer visible (`LogicExportAutomator.ensureMixerVisible()`), because channel strips carry the richest facts: it reads the View menu and presses "Show Mixer" via AXPress only when the menu offers it ("Hide Mixer" means it is already on screen). This is UI navigation through the same documented menu mechanism as the export automation, kept outside the analyzer so the scan itself stays strictly read-only; if the menu item cannot be found the scan continues and says so in the log.

The raw tree is persisted before normalization. Normalization deliberately does not fabricate track, plug-in, or meter facts from control labels. Probes repeat a read-only capture and report their scope as evidence; targeted semantic extraction can be added only when real AX attributes prove it.

After export, `AudioMetricsAnalyzer` measures each confirmed WAV locally (loudness, true peak, spectrum, stereo, silence, technical flags) and attaches the numbers as facts about the file — see `AUDIO_METRICS.md`.

Regression fixture: real-world captures may contain `fanlove.logicx`, 115 BPM, 4/4, D# minor, Audio 3, Aux 1, and FabFilter/Auto-Tune plug-ins, but these remain test evidence, never assumed project structure.
