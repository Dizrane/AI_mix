# Executor

Execution is sequential and result-oriented. The delivered `SafeExecutor` supports DRY RUN and refuses LIVE because no verified Logic mutation adapter exists yet. This prevents accidental operation through guessed UI coordinates or undocumented APIs.

Each future adapter must expose before/after readback and produce an `ExecutionResult`; a critical failure must halt its execution queue.
