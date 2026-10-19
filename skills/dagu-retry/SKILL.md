---
name: Dagu step retry
description: A pipeline job failed in Dagu (upscale, package, verify, deliver) and one step should run again.
keywords: [dagu, retry, failed, pipeline, step, upscale, job, recovery, recovery_skill, rerun, stuck]
steps:
  - Check dagu_status (and the job, if known) to find the failed step and its log line.
  - Check machine_health: no live meeting, 5090 lease free, NAS up.
  - Propose recover with the job id and the step (propose_fix action=recover).
guardrails:
  - Retries go only through recovery_skill (inspect, then run --enqueue) on the Mac that owns the job.
  - One attempt per run and step; if inspect refuses, explain why instead of proposing again.
  - Never dismiss, cancel or delete a job from 3PO; those need approval in GOAT.
verify: Dagu shows the step queued or running, then succeeded; the alert clears on the next scan.
allowed_actions: [recover]
status: active
---
recovery_skill.py is the only sanctioned retry path. The card's Run tap previews the inspect result first.
