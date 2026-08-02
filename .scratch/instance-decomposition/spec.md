# Instance decomposition

## Problem

Instance currently owns public coordination, filesystem synchronization, tree topology, buffer projection, readiness, destruction, write locking, execution, watcher state, and many private request fields in one large module. The responsibilities are difficult to explain and changes lack locality.

Previous decomposition attempts moved fields without moving complete workflows, over-constrained collaboration between private modules, and added machinery for unsupported concurrency and unlikely caller misuse. That made Instance larger and the architecture less clear.

## Goal

Make Instance the public facade and top-level orchestrator over state-owning child modules. A child owns one complete responsibility and its state transitions. Child modules do not receive, retain, or call back into the Instance table.

The target ownership tree is:

```text
Instance
├── Lifecycle
├── Tree
├── Buffer
├── Sync
│   └── Watch
└── Work
```

Instance retains its documented identity and configuration, its Manager relationship, child-module references, public input validation, public workflow entry points, and top-level resource orchestration.

## Module depth and seams

Instance's documented public interface is the external seam. The child interfaces are internal seams that concentrate one complete responsibility; they are not extension points and do not require interchangeable implementations.

Each child must pass the deletion test: deleting it would force its owned complexity back into Instance or spread it across multiple callers. A child that only forwards calls, stores fields for workflows implemented elsewhere, or exposes implementation phases without hiding them is too shallow.

Use existing filesystem, watcher, mutation, and UI adapters where production and test implementations already vary. Do not introduce ports for Tree, Buffer, Neovim primitives, or other dependencies that have only one real implementation. Tests may use internal seams without expanding the child interface.

## Ownership

### Lifecycle

Own creating, ready, load-failed, destroying, and destroyed state; readiness observers; and normal destruction transition decisions. Lifecycle does not perform Neovim, Manager, Watch, Buffer, or other resource effects.

### Tree

Own the root node, node indexes, node ID allocation, directory state, expansion state, sorting, cloning, and candidate adoption. Tree identity remains stable when a candidate is adopted. Tree nodes contain topology and filesystem metadata, never Buffer projection state.

### Buffer

Own the committed tree projection, hidden-file presentation policy, semantic cursor intent, marker and extmark state, highlights, mappings tied to the buffer, and Neovim buffer resources. Buffer keeps projection metadata in Buffer-owned state keyed by stable node identity and internally restores its Neovim state when a commit fails.

### Sync

Own initial loading, directory loading and rescanning, manual refresh, write reconciliation, filesystem result and real-root state, dirty state, synchronization requests, and the complete candidate synchronization workflow. Sync owns Watch as an internal child and directly collaborates with Tree, Buffer, and filesystem adapters.

### Work

Own write capability, prepared actions, confirmation and execution phase transitions, post-write reconciliation, and the last write result. Work receives explicit UI and mutation operations but does not delegate its workflow state back to Actions or Instance.

## Interface direction

Child interfaces use named semantic operations for domain behavior. Do not replace a meaningful interface with generic `apply`, `query`, `run`, event-dispatch, or request-kind methods merely to reduce the method count.

Candidates, prepared projections, checkpoints, and write capabilities may be opaque private values where an ordinary asynchronous workflow requires identity. Do not turn every phase into a public transaction, ticket, lease, commit, or finish protocol. The owning child hides those phases whenever callers do not need to control them.

A synchronization candidate remains behind Sync's interface. Sync prepares Buffer against the candidate, asks Buffer to commit and internally restore on failure, then adopts the candidate through a trusted non-throwing Tree operation. Only after adoption does Sync publish result, real-root, dirty, and watcher state.

Operation callbacks are narrow named capabilities such as reporting an asynchronous error, requesting destruction, or delivering a watcher event. A handler map that exposes unrelated operations is a generic context bag or event bus and is not allowed.

## Composition rules

- Instance-scoped mutable state belongs to a child module unless it can be removed entirely.
- Child modules receive explicit values, child modules, adapters, and operation callbacks, never the complete Instance table or a generic context/service bag.
- Children may collaborate directly when that collaboration is part of a complete responsibility. Internal steps must not bounce through Instance as forwarding methods.
- Stateless utilities and genuine global owners remain outside the Instance ownership tree.
- Existing domain concepts are preferred. Deepen Tree and Buffer; do not introduce a separate Projection concept.
- Move complete workflows and delete their previous implementation in the same ticket. Do not leave compatibility mirrors or dual state.
- Trust private node references and opaque values according to their interface contracts. Do not add detached DTO layers or runtime ownership validation without a supported workflow that requires them.
- Instance may delegate a documented public method to a child after public validation. Private forwarding methods that only relay internal phases are not orchestration and must be removed.

## Supported behavior

The refactor preserves documented UI workflows: creating an Instance, initial expansion, navigation, editing and writing the buffer, manual refresh, watcher-driven refresh, presentation, and destruction. It preserves ordinary filesystem, projection, and write failures encountered through those workflows.

Internal callers and injected adapters are trusted to obey their contracts. Simultaneous direct execute and refresh, overlapping refreshes, malformed private arguments, duplicate completions, and calls from incompatible UI states are unsupported caller or adapter errors. The refactor must not add general admission, cancellation, or state-machine frameworks for those cases.

## Testing

The child interface is its test surface. Replace tests coupled to old Instance fields or cross-child implementation phases with tests that exercise supported outcomes through Lifecycle, Tree, Buffer, Sync, Work, or the documented Instance interface.

Use real Tree and Buffer modules in Sync workflow tests with the existing filesystem and watcher test adapters. Use the existing mutation and UI test adapters for Work. Do not add mocks or ports solely to inspect implementation details.

## Success criteria

- Each child responsibility can be explained in one sentence and exercised through a small interface.
- Instance contains no mutable business state that belongs to a child.
- No child stores or calls the Instance table.
- Normal business workflows and ordinary operational failures pass the existing full test suite.
- Tests focus on supported behavior and ownership, not exhaustive hypothetical misuse.
- Tests no longer require private Instance mirrors or direct access to child-owned mutable state.
- Sync and Work provide leverage by hiding their complete workflows rather than exposing their internal phases to Instance or Actions.
- Instance becomes a readable public facade and orchestrator, with a target size of roughly 700 to 900 lines.
- A phase that makes Instance larger, adds forwarding methods, or introduces more state concepts must be redesigned rather than patched.
