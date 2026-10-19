---
name: Meeting lookup
description: When is the next client meeting today, or what is on the calendar.
keywords: [meeting, meetings, calendar, next meeting, today, schedule, session, call]
steps:
  - Call meetings_today and answer with the time (Eastern) and the client's name.
guardrails:
  - Read-only. Booking changes need approval in GOAT.
verify: The answer names the client and the time from the calendar snapshot.
allowed_actions: []
status: active
---
Source: the Peak app's EventKit snapshot plus the advisor's calendar drop (GOAT calendar card).
