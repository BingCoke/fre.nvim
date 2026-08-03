## Agent skills

### Issue tracker

Issues and specs are tracked as local Markdown under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

The canonical triage labels are used unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.

## Engineering priorities

### Supported behavior first

Fre is a developer-oriented plugin. Optimize for the documented UI workflows and for ordinary filesystem or Neovim failures encountered while those workflows run correctly.

Trust internal callers, private modules, tests, and injected adapters to follow their contracts. Do not add validation, compatibility layers, recovery state, or tests for malformed private arguments, invented call sequences, duplicate completions, or other caller/adapter bugs unless a real supported workflow demonstrates the need.

Documented public validation may remain, but do not expand it speculatively. Low-level APIs such as `execute()` are caller-controlled; callers are responsible for supplying valid plans and serializing them with other operations.

### Concurrency scope

Assume the supported UI serializes mutually exclusive workflows. In particular, do not design for direct `execute()` and `refresh()` running concurrently, multiple refresh workflows overlapping, or callers invoking operations from incompatible UI states. Those combinations are unsupported caller errors unless the documented UI can produce them during normal use.

Keep only the asynchronous guards needed by normal Neovim scheduling, filesystem callbacks, watcher debounce, and destruction. Do not introduce a general admission framework, cancellation framework, state-machine framework, or generation system for hypothetical interleavings.

### Architecture over defensive completeness

Prefer the simplest architecture that runs the normal business flow correctly. A module should own one complete responsibility and its state transitions behind a small interface. Move a whole workflow; do not move only fields while leaving its implementation in `Instance`, and do not create shallow forwarding modules.

Use existing domain concepts before inventing new ones. Explicit dependencies between private modules are acceptable. Passing a specific `Tree`, `Buffer`, filesystem adapter, Watch controller, or operation callback is clearer than hiding dependencies behind `Instance` or a generic context/service bag.

Except for stateless utility modules and genuinely global owners, mutable state whose lifetime follows one `Instance` belongs to an Instance child module. `Instance` should retain only its documented identity/configuration, child-module references, and top-level workflow orchestration.

A child module must not receive, store, or call back into the `Instance` table. It should expose its own small interface and accept only the explicit values, child modules, adapters, or operation callbacks needed to perform its responsibility. A child may collaborate directly with specific children when that collaboration is part of its complete workflow; do not bounce every internal step through `Instance`.

Do not add private-field compatibility mirrors, aliases, event buses, generic dispatchers, or speculative extension seams. Refactors may update tests that depended on private layout.

If a refactor makes `instance.lua` larger, multiplies forwarding methods, expands the number of state concepts, or makes responsibilities harder to explain, stop and redesign instead of patching review findings.

### Testing and review

Prioritize tests for documented success paths and ordinary operational failures: filesystem errors, projection failures, write failures, watcher notifications, and destruction through supported UI flows.

Do not require exhaustive tests for invalid private input, unsupported cross-workflow concurrency, hostile adapters, or extremely unlikely callback misuse. Add such coverage only for a reproduced user-facing bug in a supported workflow.

Review findings block a change only when they break documented behavior, normal UI flow, data integrity under supported use, or the agreed module ownership. Findings based solely on unsupported misuse or hypothetical interleavings should be noted as caller responsibility, not fixed with additional architecture.
