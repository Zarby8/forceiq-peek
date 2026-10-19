---
name: Title slide re-render
description: A client's title slide or folder image is wrong, stale or missing and needs a fresh render.
keywords: [title, title slide, folder image, folder.png, rerender, re-render, redo title, crest, opponent, poster]
steps:
  - Read the GOAT alert or card for the title (goat_alerts) and note the client and game.
  - Rebuild the exact title line the Command Box uses, e.g. '<Surname> <Opponent> <m.d> title'.
  - Propose rerender with that title line (propose_fix action=rerender, args.text).
guardrails:
  - The render goes to the scratch preview folder only; Deliver to Desktop/NAS stays a separate tap in GOAT.
  - Never guess a crest or opponent name; if the card says NEEDS ATTENTION, say so and stop.
  - Never during a live Command meeting (the Run path waits on its own).
verify: The preview run lists the title MP4, still and folder.png and the spec check passes; Chris eyeballs the still.
allowed_actions: [rerender]
status: active
---
Title and folder images come from the center-ice renderer that Dagu's slides step uses. The Run button on the
proposal card goes through GOAT's existing rerender action (preview first, then confirm).
