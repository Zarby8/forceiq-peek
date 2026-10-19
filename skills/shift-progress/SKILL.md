---
name: Shift progress for a client
description: Where one client's shift and film downloads are right now.
keywords: [shift progress, shift download, shift downloads, film download, download progress, shifts, downloads]
anchors: [shift progress, shift download, film download, download progress, shifts downloaded, shift files]
kind: read
reads: [shift_progress]
client: required
inputs:
  - "client: the client (picked from your roster)"
touches:
  - "Reads only: shift and film download progress for that client. Nothing is changed."
outputs:
  - The client's download progress, naming the client
steps:
  - Read shift progress for the client.
guardrails:
  - Read-only. Upscale, Dagu and publish progress stay in Command.
verify: The answer names the client.
allowed_actions: []
status: active
prompt: "How far along are {client}'s shift and film downloads? Read only."
---
Zero-token lookup from GOAT's shift progress reader.
