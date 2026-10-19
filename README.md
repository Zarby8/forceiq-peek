# ForceIQ Peak (PR 1)

A Ghost-branded strip for macOS. It wraps the notch on a notch display and floats as a pill at top-center on a display
without one (Studio Display). There's one non-activating, borderless `NSPanel` per `NSScreen`, above the menu bar, on
every Space and stationary, and it follows `NSApplication.didChangeScreenParametersNotification`. Pure white on pure
black, green `#5BE37D` and gold `#F5C542` accents, no dim gray text.

**Ghost mark:** BOB Motion **ForceIQ-Peak-BOB-v1, v1.1** (idle re-timed to a seamless 60-frame loop), h264 on black,
masked to a circle, played with AVPlayerLooper and driven by the pack's MANIFEST.json. See `Resources/ASSETS.md`.
Its glow breathes as a Core Animation layer animation (`CAGlowView`, curve in `GlowBreath`): the render server runs
it, so an expanded, idle Peak does no per-frame SwiftUI work.

## What it shows (modules, on or off per coach profile)
- **meetings**: the next Command meeting for this coach's client: the client name, a live countdown, Join (opens the
  https link only) and Open in Command.
- **approvals**: GOAT fixes (view-only, since GOAT is already running them) and approvals, each naming its client.
  Anything that sends, deletes, invoices, books or edits a database is view-only and opens in GOAT.
- **family**: family-delivery alerts, only when the engine's `GOAT_FAMILY_DELIVERY_ALERTS` is on (default off). Copy link only.
- **switcher**: the profile's apps, activated or launched by bundle ID. An app that isn't installed shows a gold outline and a gold "Not installed" line (full opacity) and can't be launched.
- **voice** (opt-in, off by default; Settings → "Voice"): toggle dictation into 3PO. See **Voice** below.
- Declared for later: machine_glance.

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
Plain chat opens a card only when it names one of the skill's `anchors` (distinctive words such as "approval card" or
"spend"; generic words never count) and that skill covers most of the ask. Anything unclear, like "what can you do?",
goes to Claude. `/skill <name>` always opens the card.

Tapping a card only shows a plain description (inputs, what it touches, outputs). Then come Run / Ask Claude / Copy
prompt. Nothing runs until that explicit tap. Upscale, Dagu and publish progress are never shown, only "Open in
Command". Peak uploads nothing, and client video stays local.

## Motion and ease (tokens: PeakCore `PeakMotion`; guard: `MotionPolishGuardTests`)
- **One spring** (response 0.38, damping 0.82) for expand / collapse: the shell path morphs and the Ghost, title and
  badge move by matched geometry. The collapsed pill's hover lift (1.02) is near-critically damped and keyed to the lift
  only, so hovering never re-animates the shell.
- **Cards** rise 8 pt and sharpen from a light blur, 40 ms apart (capped at 6 steps); approvals pop from 0.94; a card that
  leaves squeezes its height to its top edge while the cards below slide up. Drop-zone tiles stagger the same way.
- **3PO chat:** bubbles slide in from their own side (you: trailing, 3PO: leading); the thinking dots stay (busy only);
  each streamed chunk lands at full white (no opacity fade on text); proposal and skill cards pop in; the model pill, Chat / Memory and Peak / 3PO
  slide their selection (matched geometry); the composer ring eases to green 2 pt with a soft halo on focus.
- **Ease:** every tap target is at least 28 pt. Esc collapses (the Collapse button carries it), Return sends, ⌘K focuses
  the composer (switching back to Chat).
- Every move is a finite one-shot on an event (no repeat, no clock, no TimelineView). Text is never opacity-faded, in or out; entries
  rise and sharpen at full opacity and exits leave at once. Reduce Motion: no motion (the shell crossfades). Proof tour (sample names only):
  `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_FEED=sample FORCEIQ_PEAK_DEMO_TOUR=polish GOAT_PEAK_ROOT=<scratch root>`.

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
  `switch?app=<bundle id from the profile>`, `display?id=<display UUID>&state=on|off`, `voice` (toggle dictation).
- Raycast: `raycast/*.sh` script commands (package "ForceIQ Peak"). At install they're copied to `~/ForceIQ/peak/raycast/`.
  Add that folder once by hand: Raycast Settings → Extensions → + → Add Script Directory.

## Voice (opt-in; off until scored on the coach's own voice)
- **Toggle only.** The mic button in the 3PO field, `forceiq-peak://voice` or the Raycast command "Talk to 3PO": the first
  press starts, the next press stops. No hold-to-talk, no wake word, no silence auto-stop. While it listens the droid is in
  its listening state. Settings → "Voice" turns it on (`settings.json` `voiceEnabled`; else the profile's `modules.voice`).
- **Engine:** FluidAudio 0.17.7 + Parakeet TDT 0.6B v3 (Core ML, ANE), re-decoded every 160 ms; the Parakeet CTC 110M name
  boost runs once at stop against the live roster (spotter rescue OFF). Models (about 560 MB) download once, on first
  enable, into `<Peak root>/models` (pinned HF commits; progress line in the 3PO field and Settings). No NVIDIA Open Model
  License models. Audio stays in memory on this Mac: never written, never uploaded.
- **Live words** in the notch / pill (when Peak is collapsed) and in the 3PO field: confirmed words only (the prefix two
  decodes agree on, about 0.5 s in), white at reduced opacity until the final pass, then pure white; client names
  underlined in gold.
- **Name guard** (PeakCore `VoiceNameGuard`): the boost may replace a word only when it sounds like the name. Months,
  weekdays, numbers, function words and Peak's command words are never replaced ("October", "compare" never become
  "Cooper"); any other dictionary word (macOS `/usr/share/dict/web2`) only by a near-homophone ("Holiday" → "Halliday").
  The "'s" the boost strips is restored ("Halliday's").
- **Commands.** The final words go to 3PO exactly like a typed message. "Open <client>'s FLOW package (and hit the code
  button)" and "Start a meeting with <client>" become a local confirm card (client, meeting, time; Run / Ask Claude / Copy
  prompt); an unclear client gets a pick card. Run only opens Command's own UI (the booking's room page, else the
  schedule) or brings FLOW forward. Peak never joins, records or books, and never touches the recorder. The code-button
  click is a desktop (Cua) action: behind `settings.json` `desktopActions`, OFF, and not wired until the STOP dry run passes.
- **Desktop actions STOP dry run (locate and report only).** `FORCEIQ_PEAK_DESKTOP_DRYRUN=1` with a scratch `GOAT_PEAK_ROOT`
  (never `~/ForceIQ/peak`) turns a client command card's Run into a dry run: each step (FLOW: find the client's latest
  package → bring FLOW forward → the code-window button; Command: the app → the room / schedule link → its start control)
  is located the safe way first (Peak's deep link, the app's URL scheme, App Intents, Accessibility read-only lookup, Cua
  last; Cua is not wired, only reported) and reported in a floating panel with a red **STOP** (Esc). STOP aborts between
  steps or mid-lookup and logs `dryrun STOPPED phase=… step=… latency_ms=… skipped=[…]`. Nothing is clicked, typed, opened
  or written in another app; bringing FLOW forward is the only effect. There is no live mode (`DesktopActionMode` is
  `off` / `dry_run`), `desktopActions` stays OFF with no UI, and `DesktopDryRunTests` fails if a perform / click / key /
  open / write API appears in the dry-run sources. Live proof: add `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_TOUR=dryrun-flow`
  (or `dryrun-meeting`) and optionally `FORCEIQ_PEAK_DRYRUN_PACE_MS=<ms between lookups>` so a STOP can land mid-step.
- **Desktop action, live: FLOW's Code Window only.** With a scratch `GOAT_PEAK_ROOT` whose `settings.json` has
  `desktopActions: true` plus `FORCEIQ_PEAK_DESKTOP_LIVE=1` (no dry-run opt-in; never `~/ForceIQ/peak`), Run on an
  "open <client>'s latest FLOW package and hit the code button" card finds the client's package, brings FLOW forward,
  locates the code-window target, arms the press (`FORCEIQ_PEAK_LIVE_ARM_MS`, default 1500) and then presses FLOW's
  `Code Window` menu item with AXPress on that exact element: role `AXMenuItem`, title exactly `Code Window`, one match,
  enabled, in the frontmost FLOW process, and only if FLOW's front window is that client's package. No coordinate
  clicks, no synthetic keys. STOP (button, or Esc via a key-down monitor) halts between steps, mid-lookup, during the arm
  and right before the press (`dryrun STOPPED phase=before_press …`). Nothing runs without the Run tap; the Command
  meeting start stays locate-only. `desktopActions` stays OFF by default with no UI toggle. `FORCEIQ_PEAK_FLOW_PACKAGES`
  points the package search at a scratch folder for demo proofs. `DesktopLiveTests` pins the single AXPress call site
  (`ForceIQPeak/DesktopPresser.swift`); the dry-run sources stay free of any perform API.
- **Live smoke:** `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_TOUR=voice GOAT_PEAK_ROOT=<scratch root> FORCEIQ_PEAK_VOICE_FEED=<folder
  of .wav>` feeds recorded `say` clips in real time through the mic's conversion path (fake roster) and logs
  `voice turn first_confirmed_ms=… final_ms=… cpu_pct=…` per clip plus a summary.
- **Real voice:** `sttbench --live` (the bake-off harness, `~/ForceIQ/stt-bakeoff`; uses its own `models/` copy, downloaded on first run if missing, and its own fake roster):
  ```
  cd ~/ForceIQ/stt-bakeoff && STTBench/.build/out/Products/Release/sttbench --engine tdtv3-ctc --la2 \
      --ctc-norescue --ctc-guard --models models --live
  ```
  Enter starts, Enter stops (Ctrl-C quits); it prints the live words, the final text, first-partial latency (from START,
  not speech onset) and final latency. The terminal app needs microphone access (System Settings → Privacy → Microphone).

## Build and test (never installs, launches or adds a login item)
```
peak/build.sh      # → peak/build/ForceIQ Peak.app (scratch, SwiftPM cache and TMPDIR under ~/ForceIQ/)
cd peak && TMPDIR=~/ForceIQ/peak-tmp swift test --scratch-path ~/ForceIQ/peak-derived/<name> --cache-path ~/ForceIQ/peak-derived/swiftpm-cache
```

### Idle CPU check (run it before any PR that adds motion)
```
peak/scripts/cpu_idle_check.sh                      # chat open + idle, 30 s: exit 1 above 2.0 %
peak/scripts/cpu_idle_check.sh --mode collapsed     # collapsed pills, idle: exit 1 above 0.5 %
peak/scripts/cpu_idle_check.sh --tier loops       # the rendered-loops fallback (rig off/failed), same limits
peak/scripts/cpu_idle_check.sh --all               # rig + loops x expanded + collapsed (4 runs, exit 1 if any fails)
peak/scripts/cpu_idle_check.sh --app <other .app> --max 2.0 --seconds 30 --settle 8
```
It launches its own demo instance of the build (`FORCEIQ_PEAK_DEMO=1`, `FORCEIQ_PEAK_DEMO_TOUR=3po-idle`) with a scratch
`GOAT_PEAK_ROOT` under `~/ForceIQ/peak-tmp/` and the quiet desk feed (`FORCEIQ_PEAK_DEMO_FEED=quiet`: no meeting, fixes
or approvals, so the Ghost is idle and its glow runs, as on a coach's Mac most of the day). The sample demo feed has
approvals, so the Ghost is in attention and the glow is off: a CPU number taken on it misses the glow. The script
measures only that PID and quits it. `GOAT_PEAK_ROOT` also keeps any demo or test run out of the coach's
`~/ForceIQ/peak` (logs, settings.json, profile.cache.json). Swift tests (`AmbientMotionGuardTests`) fail on a
`.repeatForever`, an uncapped or unpausable `TimelineView(.animation)`, a TimelineView glow, a new display link, or
repeating keyframes outside the busy-only ThinkingDots.

Per coach: see `ADD-A-COACH.md` and `profile.template.json`. Third-party code: `THIRD_PARTY_NOTICES.md`.
