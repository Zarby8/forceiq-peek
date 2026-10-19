---
name: FLOW code-window heal
description: A FLOW package will not open or its code windows/buttons are broken and need the routine heal.
keywords: [flow, flowaipkg, package, code window, code windows, buttons, layout, heal, open check, loader]
steps:
  - Find the package path from the FLOW alert (goat_alerts) or the client's latest package.
  - Propose flow_fix with the .flowaipkg path (propose_fix action=flow_fix, args.path).
guardrails:
  - The heal makes a whole-package APFS backup first, runs FLOW's loader open check, and restores on failure.
  - Never edit the package by hand or delete backups.
  - Not while FLOW has the package open for editing.
verify: The fix log shows 'fixed' or 'nothing-fixable' and the open check reports the primary file decoded.
allowed_actions: [flow_fix]
status: active
---
The engine entry point is GOAT's flow_fix action (engine/flowfix.py fix: backup, fix, open check, auto-restore).
