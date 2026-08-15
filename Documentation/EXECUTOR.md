# Executor

Execution is sequential and result-oriented. `SafeExecutor` routes plan actions by mode:

- **READ ONLY / DRY RUN** — never mutate Logic. A valid action reports `dry_run`; an invalid one reports `not_executed` with the validator's message. DRY RUN is the UI default.
- **LIVE** — available only by the user's explicit mode choice plus a per-run confirmation. Only actions with `status == .valid` from `CommandValidator` are ever considered; each is routed to the first registered `LiveActionAdapter` whose `supports(action)` accepts it. An action no adapter supports keeps the honest refusal ("No verified live Logic adapter is installed for this action") without touching Logic.

## Adapter contract (`LiveActionAdapter`)

An adapter must locate its target from live AX evidence (never coordinates), prove its write mechanism before the first real write, re-read the control after every write, and return an `ExecutionResult` whose `before`/`after` are the re-read values — never the plan's numbers. A write that does not verify must be rolled back to the original position before the failure is reported.

## The verified channel-strip adapter (`LogicChannelStripAdapter`)

Covers exactly four actions: `set_volume`, `set_pan`, `set_mute`, `set_solo`.

- **Strip resolution** — the snapshot's captured AX path is walked and trusted only when the element still carries the strip's exact caption and a volume-fader slider; otherwise the live Mixer areas are searched (same structural evidence as the normalizer, inspector mirrors excluded) and only a unique caption match is accepted. Two same-named strips are refused as ambiguous.
- **Mute / solo** — documented `AXPress` on the strip's own control captioned exactly `mute` / `solo`; the toggle counts only when the control re-reads as the target state. A control already at the target is not pressed.
- **Staleness gate** — when a volume/pan action carries the direction proof's `parameters.current`, the live reading must still match it (tolerance 0.05) before anything is written; a project that drifted since the analysis fails with "rescan and validate the plan again" instead of executing deltas nobody reasoned about.
- **Volume** — calibration is mandatory because Logic's fader has been observed publishing raw units over AX (AXValue 173 while the level text reads 0.0 dB). The scale is decided from same-moment evidence (`FaderScale.detect`): AXValue equal to the displayed dB (tolerance 0.05) proves the dB scale; anything else is raw. Before the first real write the mechanism is proven idempotently — read → set(the same value) → read, with both the AXValue and the displayed dB required unchanged; any deviation refuses the write with a named reason. On the dB scale the target is written directly and verified against the displayed dB. On the raw scale no curve is guessed: `FaderServoMath` steps the fader with measured secant iterations bounded by the slider's own AXMinValue/AXMaxValue, and the action succeeds only when the strip's displayed dB reads the target within 0.05. Any failure (no bounds, unresponsive display, stall, budget exhausted) rolls the fader back to its original position and reports why.
- **Pan** — the pan facts and the validator's −64…+63 range come from this slider's own AXValue, so the write is on the fact scale by construction; it is still proven idempotently first, verified by re-reading, and rolled back when the re-read does not match.

## Queue semantics

Actions run strictly in plan order. A `failed` adapter execution halts everything after it — later actions were often reasoned against the state the failed one should have produced — and every halted action reports `not_executed` naming the failure. After a LIVE queue the app runs a fresh read-only `fullScan`, normalizes it and shows `DiffEngine.compare` (changed / unchanged / errors, including mute/solo changes) next to the per-action results.

Actions outside the four (plug-ins, sends, routing) still fail safely: no adapter exists for them and none is guessed.

## Verification cycle (closed before/after loop)

The loop closes after the plan is applied — automatically after a LIVE queue, or by the Review screen's "Verify Applied Plan" button for a plan the user applied by hand. One fresh read-only scan then: (1) diffs the tracks against the snapshot the plan was validated with; (2) checks every `valid` action's absolute target against the re-read known fact (`PlanVerifier`, tolerance 0.05 — the validator's own) with three honest outcomes — `matched`, `mismatched` (both values shown), `unverifiable` (a non-known fresh fact is stated as such and never guessed into a result); (3) freezes the current files' measurements as the pre-apply baseline (`MetricsBaselineEntry`) — control moves change the audio only after a new export/bounce, so the files on disk at verification time still carry the state the plan reasoned from; and (4) ADOPTS the fresh snapshot as the current analysis.

After that the user can re-export the tracks and re-bounce the mix from the same card; `MetricsComparison` joins the frozen baseline with the newly measured files by identity (rows exist only where both sides were really measured — the metrics cache keys by file identity, so an unchanged file keeps identical numbers and is flagged "unchanged file", never presented as the plan's sonic effect). The next generated AI package is then the post-apply second round: schema ≥ 2.27 marks it `Post-apply snapshot: yes` and carries the verification lines, the track diff and the before/after metrics in a `Post-apply verification` section, so the model assesses what the applied plan actually achieved and proposes the next circle from the fresh facts alone.
