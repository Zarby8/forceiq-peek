# ForceIQ Peak (PR 1)

A Ghost-branded strip for macOS. It wraps the notch on a notch display and floats as a pill at top-center on a display
without one (Studio Display). There's one non-activating, borderless `NSPanel` per `NSScreen`, above the menu bar, on
every Space and stationary, and it follows `NSApplication.didChangeScreenParametersNotification`. Pure white on pure
black, green `#5BE37D` and gold `#F5C542` accents, no dim gray text.

**Ghost mark:** BOB Motion **ForceIQ-Peak-BOB-v1, v1.1** (idle re-timed to a seamless 60-frame loop), h264 on black,
masked to a circle, played with AVPlayerLooper and driven by the pack's MANIFEST.json. See `Resources/ASSETS.md`.

## What it shows (modules, on or off per coach profile)
- **meetings**: the next Command meeting for this coach's client: the client name, a live countdown, Join (opens the
  https link only) and Open in Command.
- **approvals**: GOAT fixes (view-only, since GOAT is already running them) and approvals, each naming its client.
  Anything that sends, deletes, invoices, books or edits a database is view-only and opens in GOAT.
- **family**: family-delivery alerts, only when the engine's `GOAT_FAMILY_DELIVERY_ALERTS` is on (default off). Copy link only.
- **switcher**: the profile's apps, activated or launched by bundle ID. An app that isn't installed shows a gold outline and a gold "Not installed" line (full opacity) and can't be launched.
- Declared for later: voice, machine_glance.

**3PO droid:** BOB Motion **ForceIQ-Peak-3PO-v1**. The chat header plays the live RealityKit rig (`rig/3po.usdz`),
then the rendered hevc_alpha loops, then the static droid mark, by what loads (`AvatarTier`). States follow the chat:
idle (waiting), listening (mic open; voice flag), thinking (send → first token, tools, 'consulting Opus'), talking
(tokens streaming), and one alert flash per new approval or refusal card. Every change starts at once (within
100 ms): the rig blends its parameters from the pose on screen, and the loops crossfade (130 ms) from the frame on
screen into the pack's 20-frame transitions (non-idle → non-idle via idle); fast flips coalesce, latest wins. Only
the alert flash settling back to idle waits for the flash to finish. A steady idle rig parks: one captured idle pass
plays as a layer animation and RealityKit leaves the window until something changes (chat-open idle CPU about the
static mark's). Proof tours: `FORCEIQ_PEAK_DEMO_TOUR=3po-send` (send latency), `3po-idle` (chat-open idle CPU). The droid lives only in the expanded chat, so a
collapsed Peak renders and decodes nothing; Reduce Motion shows a still. Proof tour: `FORCEIQ_PEAK_DEMO=1
FORCEIQ_PEAK_DEMO_TOUR=3po`. See `Resources/ASSETS.md`.

**3PO memory:** say "remember Sample Skater's games are on Saturdays" and 3PO keeps it, for this coach only, as plain local
JSONL under `<peak_root>/<owner>/memory/facts.jsonl` (append-only; "forget …" or the Forget button marks a fact forgotten
and never deletes the file). Client facts are resolved against this coach's roster (peakdrop.roster(); an unclear client
is tap-to-pick) and always name the client. Anything that looks like a key or token is stripped before it is written.
Recall is local (relevance + recency) and packed into a token budget; only those lines ride along with a Claude turn, and
the saved session keeps no copy. The 3PO tab's **Memory** pill shows the list (client sections in gold, General in
green, forgotten facts on request), all white text on black at full opacity. Routes: `GET /api/3po/memory`,
`POST /api/3po/memory {op: add|forget}`.

**3PO skills:** named, reusable prompts or actions (`peak/skills/<slug>/SKILL.md` with `kind: read|prompt|action`, plus
this coach's own in `<peak_root>/<owner>/skills/`). In chat a skill first shows its description card (inputs, what it
touches, outputs) with Run / Ask Claude / Copy prompt; only the card's Run tap runs it. Read skills answer locally (zero
tokens), prompt skills go to Claude, action skills only propose a fix from 3PO's routine allow-list (then GOAT's preview
and Confirm). Anything else is view-only with a GOAT approval card. Starters: What's next today, Spend this month,
Explain this approval card, Shift progress for a client, Title slide preview. `/skills` lists them.

Tapping a card only shows a plain description (inputs, what it touches, outputs). Then come Run / Ask Claude / Copy
prompt. Nothing runs until that explicit tap. Upscale, Dagu and publish progress are never shown, only "Open in
Command". Peak uploads nothing, and client video stays local.

## Data (local GOAT engine only, 127.0.0.1:8765; no new outbound network)
| Endpoint | Status |
|---|---|
| `GET /api/peak/profile` | **new**, this Mac only: this coach's `peak` overlay section (engine/peakprofile.py), no secrets |
| `GET /api/peak/next-meeting` | **new**, this Mac only, read-only: the next Command booking (engine/peakmeeting.py → panels.command_get) |
| `GET /api/live` | existing: fixes and download counts |
| `GET /api/approvals`, `POST /api/approvals/<id>/approve\|ask\|prompt` | existing (approve without confirm only previews strong gates; Peak never sends confirm) |
| `GET /api/family-delivery-alerts` | existing (flag off → enabled=false, no Command call) |

Auth works the same way as GOAT's own Mac app trust. A loopback request with no Tailscale headers is "this Mac (local
process)" to phone.py, so Peak carries no token and no secret.

## Control
- Hotkey: ctrl+opt+G by default (set in the profile), via KeyboardShortcuts 3.1.0. You can re-bind it in Shortcut…, and
  the menu-bar **Built-in hotkey** item turns it on or off (persisted).
- Menu bar "Peak": show/hide, per-display checkboxes (by display UUID, persisted in `<state_root>/settings.json`), About, Quit.
- URL scheme `forceiq-peak://` (strict; unknown actions are ignored; only the action name is logged):
  `toggle`, `show`, `hide`, `expand`, `collapse`, `ask[?q=…]` (opens the ask field prefilled and never sends),
  `switch?app=<bundle id from the profile>`, `display?id=<display UUID>&state=on|off`.
- Raycast: `raycast/*.sh` script commands (package "ForceIQ Peak"). At install they're copied to `~/ForceIQ/peak/raycast/`.
  Add that folder once by hand: Raycast Settings → Extensions → + → Add Script Directory.

## Build and test (never installs, launches or adds a login item)
```
peak/build.sh      # → peak/build/ForceIQ Peak.app (scratch, SwiftPM cache and TMPDIR under ~/ForceIQ/)
cd peak && TMPDIR=~/ForceIQ/peak-tmp swift test --scratch-path ~/ForceIQ/peak-derived/<name> --cache-path ~/ForceIQ/peak-derived/swiftpm-cache
```
Per coach: see `ADD-A-COACH.md` and `profile.template.json`. Third-party code: `THIRD_PARTY_NOTICES.md`.
