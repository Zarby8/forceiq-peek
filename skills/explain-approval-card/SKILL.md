---
name: Explain this approval card
description: Plain-English explanation of a GOAT approval card, what approving it would touch and what could go wrong. Explains only; never approves.
keywords: [explain, approval, approval card, what does this card do, card, approve, what is this asking]
kind: prompt
client: optional
inputs:
  - "card: the approval card's title or text (paste it after a colon)"
touches:
  - "Sends the card text you give it to Claude as a prompt. Approves nothing and runs nothing."
outputs:
  - What the card is asking, what approving would touch and the risks, naming the client when there is one
steps:
  - Read the card text and explain it plainly.
guardrails:
  - Explain only. Approving happens in GOAT, by you.
verify: The answer names the card's client when it has one and approves nothing.
allowed_actions: []
status: active
prompt: "Explain this GOAT approval card to me in plain English: what it is asking, what approving it would touch, what could go wrong, and whether it looks routine. {client_line}Do not approve, run or change anything; approving happens only in GOAT.\n\nCard: {card}"
---
The card text goes to Claude as this turn's prompt. Use it from a card's Ask Claude, or type: explain this approval card: <text>.
