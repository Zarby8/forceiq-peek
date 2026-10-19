---
name: Shift / game file naming check
description: Check whether a downloaded shift or full-game file follows the house naming rule.
keywords: [shift, shifts, naming, file name, filename, download, game file, mp4 name, rename]
steps:
  - Read the file name the user gives (text only; never open or upload the video).
  - Check it against CurrentTeam_OpponentFullName_m.d.yyyy.mp4 (opponent's full canonical name, date not zero-padded).
  - Say exactly which part is off and what the correct name would be.
guardrails:
  - Read-only. Renaming or moving client media is not a 3PO action; say it needs approval in GOAT.
  - Never ask for or accept the video itself.
verify: The suggested name matches the pattern and uses the client's current team.
allowed_actions: []
status: active
---
The naming rule is the one GOAT's provider downloads enforce (engine/providers.py NAME_RE).
