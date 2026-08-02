# 01 — Let Tree own filesystem topology

**What to build:** Preserve normal Instance creation, directory lookup, expansion, collapse, and node reuse while making Tree the sole owner of the filesystem topology used by one Instance.

**Blocked by:** None — can start immediately

**Status:** resolved

- [x] Tree owns the root node, node indexes, node ID allocation, directory state, expansion state, sorting, cloning, snapshots, restoration, and candidate adoption without receiving or retaining Instance or Manager.
- [x] Tree receives only explicit immutable identity and path values, the configured comparator, and the node-ID observation capability it needs.
- [x] Tree does not add or retain new Buffer projection state. Existing row extmarks, visible ranges, marker state, and other projection fields remain unchanged in this phase and are moved only by Issue 02.
- [x] All topology lookup, reconcile, expansion, sorting, snapshot, restore, clone, and adoption operations cross a named semantic Tree interface rather than generic request dispatch.
- [x] Tree keeps one stable child-module identity. Candidate adoption replaces Tree-owned topology internally and is a trusted non-throwing operation once Buffer commit has succeeded.
- [x] Private callers may retain Tree node references according to the interface contract, but only Tree mutates topology. Do not add detached node DTOs or runtime ownership validation solely to enforce trusted private usage.
- [x] Node IDs remain monotonic and observed even when a candidate is discarded; IDs are not reused as rollback machinery.
- [x] Instance contains no topology mirrors or dual writes after migration.
- [x] Normal Instance creation, lookup, expansion, collapse, sorting, candidate failure, and stable-node behavior remain unchanged. Buffer projection behavior remains unchanged until Issue 02.
- [x] Tests coupled only to the old private field layout are updated or removed; supported Tree behavior is tested through the Tree interface and the full suite passes.
- [x] The change does not migrate Buffer, Sync, Lifecycle, Work, or unrelated UI behavior, does not add a compatibility layer, and does not make Instance larger.
