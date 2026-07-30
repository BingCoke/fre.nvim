# 06 — Complete Tab, Split, Float Mapping, and Documentation Behavior

**What to build:** Extend the exact selection workflow to tab and split destinations, expose layout-sensitive float mappings through minimal context and View inspection, and document the completed presentation model.

**Blocked by:** 03 — Preserve Semantic Cursors Across Shared Projection Changes; 05 — Implement Exact Select and View Ownership Transfer.

**Status:** ready-for-human

- [ ] Tab selection installs files or directory children in one explicitly created tab and leaves the source visible unless source hiding is requested.
- [ ] Split selection requires a valid split layout and uses the exact captured ordinary source or an explicit ordinary anchor.
- [ ] A float source without an explicit ordinary anchor fails before creating a split, buffer, or child Instance.
- [ ] Child Views created in tabs or splits record close-on-hide behavior and the exact origin used to create the destination.
- [ ] Files and directories follow the same validation, commit point, cleanup, and post-commit source-hide rules across all three selection actions.
- [ ] ActionContext remains a fresh synchronous source snapshot and does not gain layout, origin, visibility, View generation, token, or reconciliation fields.
- [ ] Public mapping tests demonstrate directory navigation remaining in a float and file selection targeting the inspected origin before hiding the source float.
- [ ] Documentation covers one managed View per tab, tab-local and global hide, binary toggle, default-layout reopening, source hiding, read-only View inspection, dynamic mappings, semantic cursor preservation, and unsupported native duplication.
