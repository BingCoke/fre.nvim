# 01 — Extract Pure Layout Resolution and Exact Window Mechanics

**What to build:** Separate layout normalization, validation, resolution, and geometry materialization from presentation policy, while preserving the existing public layout behavior through exact Neovim window operations.

**Blocked by:** None — can start immediately.

**Status:** ready-for-human

- [x] Setup and Instance layout overrides remain copied snapshots and continue merging only within compatible layout families.
- [x] Current, split, and float layouts retain their public geometry behavior, including ratios, centered floats, borders, and split capacity checks.
- [x] Invalid layouts fail before creating, closing, resizing, or changing a destination window.
- [x] Exact window operations receive explicit destinations and anchors and do not discover Instance visibility or infer origins or action policy.
- [x] Existing public configuration and window-layout tests pass without assertions against new private layout internals.
- [x] The change introduces no View ownership model, compatibility layer, or selection behavior ahead of the tickets that own those contracts.
