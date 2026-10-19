---
name: NAS remount
description: The ForceIQ NAS is unmounted, wedged or not answering and needs the saved-login reconnect.
keywords: [nas, mount, remount, reconnect, volumes, forceiq share, smb, synology, not responding, wedged]
steps:
  - Check machine_health for the NAS probe (mounted, stale, duplicate).
  - If it is not healthy, propose nas_remount (propose_fix action=nas_remount, no args).
guardrails:
  - Never during a live Command meeting.
  - A wedged-but-mounted share is only replaced when nothing is saving to it; the Run path checks this itself.
verify: machine_health shows the smbfs mount and a passing read probe.
allowed_actions: [nas_remount]
status: active
---
Entry point: GOAT's nas_remount action, which runs ~/.local/bin/mount-forceiq.sh.
