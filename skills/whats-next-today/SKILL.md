---
name: What's next today
description: A quick read of the rest of today, the next client meeting, open GOAT alerts and what is running on this Mac.
keywords: [agenda, rest of today, what's next today, up next today, schedule today, today's schedule, today's agenda, day plan]
anchors: [agenda, rest of today, what's next today, whats next today, up next today, schedule today, today's schedule, today's agenda]
kind: read
reads: [next_meeting, goat_alerts, machine_health]
client: optional
inputs: []
touches:
  - "Reads only: Command's upcoming bookings, GOAT alerts and this Mac's running jobs. Nothing is changed."
outputs:
  - The next meeting with its client and time
  - Open alerts, each naming its client
  - Jobs running on this Mac
steps:
  - Read the next booking, the open GOAT alerts and this Mac's status.
guardrails:
  - Read-only. Booking changes need approval in GOAT.
verify: Every meeting and alert line names its client.
allowed_actions: []
status: active
prompt: "What's next for me today? List my next client meeting (client and time), the open GOAT alerts (name each client) and what's running on my Mac. Read only; change nothing."
---
A zero-token look at today. Nothing goes to Claude unless you tap Ask Claude.
