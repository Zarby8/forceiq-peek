---
name: Spend this month
description: How much Peak's 3PO has spent on Claude so far this month, against this coach's budget.
keywords: [spend, spent, spending, cost, costs, budget, claude bill, claude spend, monthly spend]
anchors: [spend, spent, spending, cost, budget, claude bill]
kind: read
reads: [spend]
client: none
inputs: []
touches:
  - "Reads only: this coach's local Peak usage log. No admin key, no billing, nothing is changed."
outputs:
  - Month-to-date Peak spend and the budget
  - The split by model
steps:
  - Read the Peak spend meter (this coach's usage log).
guardrails:
  - Read-only. Invoices and payments are never 3PO's to touch.
verify: The total matches the spend meter in the 3PO header.
allowed_actions: []
status: active
prompt: "How much has Peak 3PO spent on Claude this month, against my budget, split by model? Read only."
---
Local numbers only (Peak's own usage log). Account-wide spend stays behind the profile flag.
