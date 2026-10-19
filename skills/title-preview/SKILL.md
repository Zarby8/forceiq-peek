---
name: Title slide preview
description: Propose a re-render of a client's title slide and folder image as a preview in scratch. Uses 3PO's routine rerender fix.
keywords: [title slide, title card, folder image, retitle, title preview, wrong title]
kind: action
action: rerender
client: required
inputs:
  - "client: the client (picked from your roster)"
  - "text: the title card text, e.g. '<client> vs <opponent> 10.18'"
touches:
  - "A title and folder preview in scratch only. Delivering it is a separate confirm in GOAT."
outputs:
  - A fix card for the client; Run shows GOAT's preview, then Confirm re-renders
steps:
  - Propose rerender with the title text for the client.
guardrails:
  - Proposes only. GOAT previews, and nothing renders until you Confirm.
verify: The fix card names the client and the title text.
allowed_actions: [rerender]
status: active
prompt: "Re-render the title slide preview for {client} with the text '{text}'. Preview only; delivering is a separate confirm."
---
Run gives you 3PO's normal rerender fix card (the routine allow-list); nothing renders until GOAT's preview and your Confirm.
