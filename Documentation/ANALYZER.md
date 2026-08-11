# Analyzer and probes

`LogicAccessibilityAnalyzer.fullScan()` finds the actual running `com.apple.logic10` process, checks Accessibility trust, and recursively copies attributes from AX elements. It never invokes AX set operations, menus, keys, AppleScript, or screen coordinates.

The raw tree is persisted before normalization. Normalization deliberately does not fabricate track, plug-in, or meter facts from control labels. Probes repeat a read-only capture and report their scope as evidence; targeted semantic extraction can be added only when real AX attributes prove it.

Regression fixture: real-world captures may contain `fanlove.logicx`, 115 BPM, 4/4, D# minor, Audio 3, Aux 1, and FabFilter/Auto-Tune plug-ins, but these remain test evidence, never assumed project structure.
