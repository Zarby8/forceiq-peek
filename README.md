# ForceIQ Peek (PR 1)

> **Naming.** The product is called **Peek** (ForceIQ Peek, the PEEK wing). Identifiers keep the old spelling on purpose, so your
> macOS permissions and every integration keep working: bundle id `com.forceiq.peak`, the `forceiq-peak://` links, the
> `~/ForceIQ/peak` folder, the `PeakCore` / `ForceIQPeak` module names, `FORCEIQ_PEAK_*` env vars and GOAT's `/api/peak/*` routes.


A Ghost-branded strip for macOS. It wraps the notch on a notch display and floats as a pill at top-center on a display
without one (Studio Display). There's one non-activating, borderless `NSPanel` per `NSScreen`, above the menu bar, on
every Space and stationary, and it follows `NSApplication.didChangeScreenParametersNotification`. Pure white on pure
black, green `#4FFF4F` and gold `#F4C430` accents (ForceIQ Brand 2026; defined once in `Sources/PeakCore/Brand.swift`), no dim gray text.

**Peek mark (default): the eyes 👀.** Two eyes drawn as vectors in one SwiftUI `Canvas` (`EyesMark.swift`; the pose per state is pure,
tested code in `PeakCore/EyesPose.swift`). The pupils carry the state: green = fine, gold = something needs you (attention also
gets a gold ring around the mark, since the glow skips that state; error = startled gold pupils and a gold ring). Idle glances
right, left and up and blinks; working scans; typing reads down; the receipt blinks and shows a green ring once. While the mark
sleeps (a collapsed idle pill) or Reduce Motion is on, the `TimelineView` is paused, so no frame is scheduled. The launch log
says `mark=peek-eyes`. `FORCEIQ_PEAK_MARK=bob` brings back the BOB loops below (the assets are still bundled).

**App icon and About art.** `Resources/AppIcon.icns` (the eyes on a black squircle with a green ring and a gold edge), named by
`CFBundleIconFile` in Info.plist and copied in by `build.sh`. The About panel is the standard one, which shows the app icon, so it
is the About art too. Regenerate with `python3 peak/scripts/make_icon.py` (Pillow, macOS `iconutil`); the .icns is committed, so a
build never needs it. Before this the bundle carried no icon at all (Finder and About showed the generic default).

**BOB mark (opt-in via `FORCEIQ_PEAK_MARK=bob`):** BOB Motion **ForceIQ-Peek-BOB-v1, v1.1** (idle re-timed to a seamless 60-frame loop), h264 on black,
masked to a circle, played with AVPlayerLooper and driven by the pack's MANIFEST.json. See `Resources/ASSETS.md`.
Its glow breathes as a Core Animation layer animation (`CAGlowView`, curve in `GlowBreath`): the render server runs
it, so an expanded, idle Peek does no per-frame SwiftUI work.

## What it shows (modules, on or off per coach profile)
- **meetings**: the next Command meeting for this coach's client: the client name, a live countdown, Join (opens the
  https link only) and Open in Command.
- **approvals**: GOAT fixes (view-only, since GOAT is already running them) and approvals, each naming its client.
  Anything that sends, deletes, invoices, books or edits a database is view-only and opens in GOAT.
- **family**: family-delivery alerts, only when the engine's `GOAT_FAMILY_DELIVERY_ALERTS` is on (default off). Copy link only.
- **switcher**: the profile's apps, activated or launched by bundle ID. An app that isn't installed shows a gold outline and a gold "Not installed" line (full opacity) and can't be launched.
- **voice** (opt-in, off by default; Settings → "Voice"): toggle dictation into 3PO. See **Voice** below.
- Declared for later: machine_glance.

**3PO droid:** BOB Motion **ForceIQ-Peek-3PO-v1**. The chat header plays the live RealityKit rig (`rig/3po.usdz`),
then the rendered hevc_alpha loops, then the static droid mark, by what loads (`AvatarTier`). States follow the chat:
idle (waiting), listening (mic open; voice flag), thinking (send → first token, tools, 'consulting Opus'), talking
(tokens streaming), and one alert flash per new approval or refusal card. Every change starts at once (within
100 ms): the rig blends its parameters from the pose on screen, and the loops crossfade (130 ms) from the frame on
screen into the pack's 20-frame transitions (non-idle → non-idle via idle); fast flips coalesce, latest wins. Only
the alert flash settling back to idle waits for the flash to finish. A steady idle rig parks: one captured idle pass
plays as a layer animation and RealityKit leaves the window until something changes (chat-open idle CPU about the
static mark's). Proof tours: `FORCEIQ_PEAK_DEMO_TOUR=3po-send` (send latency), `3po-idle` (chat-open idle CPU). The droid lives only in the expanded chat, so a
collapsed Peek renders and decodes nothing; Reduce Motion shows a still. Proof tour: `FORCEIQ_PEAK_DEMO=1
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
Command". Peek uploads nothing, and client video stays local.

## Motion and ease (tokens: PeakCore `PeakMotion`; guard: `MotionPolishGuardTests`)
- **One spring** (response 0.38, damping 0.82) for expand / collapse: the shell path morphs and the Ghost, title and
  badge move by matched geometry. The collapsed pill's hover lift (1.02) is near-critically damped and keyed to the lift
  only, so hovering never re-animates the shell.
- **Cards** rise 8 pt and sharpen from a light blur, 40 ms apart (capped at 6 steps); approvals pop from 0.94; a card that
  leaves squeezes its height to its top edge while the cards below slide up. Drop-zone tiles stagger the same way.
- **3PO chat:** bubbles slide in from their own side (you: trailing, 3PO: leading); the thinking dots stay (busy only);
  each streamed chunk lands at full white (no opacity fade on text); proposal and skill cards pop in; the model pill, Chat / Memory and Peek / 3PO
  slide their selection (matched geometry); the composer ring eases to green 2 pt with a soft halo on focus.
- **Number rolls** (spend total, voice status line): the new value rolls up 6 pt from a light blur at full opacity and the
  old one leaves at once (`SwapText`). No `numericText` (it cross-fades the changing digits); Reduce Motion swaps in place.
- **Ease:** every tap target is at least 28 pt. Esc collapses (the Collapse button carries it), Return sends, ⌘K focuses
  the composer (switching back to Chat).
- Every move is a finite one-shot on an event (no repeat, no clock, no TimelineView). Text is never opacity-faded, in or out, and
  never dimmed or gray anywhere, voice included (guards: `testNoDimmedOrGrayTextAnywhere`, `testVoiceTextIsFullWhite`,
  `testNumberRollNeverFadesDigits`); entries
  rise and sharpen at full opacity and exits leave at once. Reduce Motion: no motion (the shell crossfades). Proof tour (sample names only):
  `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_FEED=sample FORCEIQ_PEAK_DEMO_TOUR=polish GOAT_PEAK_ROOT=<scratch root>`.

## Data (local GOAT engine only, 127.0.0.1:8765; no new outbound network)
| Endpoint | Status |
|---|---|
| `GET /api/peak/profile` | **new**, this Mac only: this coach's `peak` overlay section (engine/peakprofile.py), no secrets |
| `GET /api/peak/next-meeting` | **new**, this Mac only, read-only: the next Command booking (engine/peakmeeting.py → panels.command_get), plus `today` (today's named sessions) and `gpu_window` (meeting times only, for the 5090 light) |
| `GET /api/peak/client-directory` | **new**, this Mac only, read-only, asked only with `commandMeetingLink` on: this coach's active Command clients `[{id, display_name}]` (engine/peakdirectory.py → panels.command_get → Command `GET /clients/directory`); ids re-validated as UUIDs; nothing persisted or logged but counts |
| `GET /api/peak/next-session` | **new**, this Mac only (403 for phones), read-only, asked only with `nextSessionPill` on, at most every 5 min: this coach's next session and gap checks (engine/peaknextsession.py → panels.command_get → Command `GET /schedule/bookings?upcoming_only=true&recent_hours=12` and `GET /invoices/`; Ghost `GET /v1/portal/{id}/meeting-bundles` and `GET /v1/ghost/client/{id}/games` for "since last met"); this coach's roster only; nothing persisted, logs are counts and states only |
| `GET /api/peak/ready` | **new**, this Mac only (403 for phones), read-only, asked only with `readyAlerts` on (the default), at most every 10 min: the meeting packs GHOST has published and the FLOW packages built for this coach's roster (engine/peakready.py; one GHOST meeting-bundles read per roster client under a 25 s budget; nothing written, no file fetched) |
| `GET /api/live` | existing: fixes and download counts |
| `GET /api/approvals`, `POST /api/approvals/<id>/approve\|ask\|prompt` | existing (approve without confirm only previews strong gates; Peek never sends confirm) |
| `GET /api/family-delivery-alerts` | existing (flag off → enabled=false, no Command call) |

Auth works the same way as GOAT's own Mac app trust. A loopback request with no Tailscale headers is "this Mac (local
process)" to phone.py, so Peek carries no token and no secret.

## Control
- Hotkey: ctrl+opt+G by default (set in the profile), via KeyboardShortcuts 3.1.0. You can re-bind it in Shortcut…, and
  the menu-bar **Built-in hotkey** item turns it on or off (persisted).
- Menu bar "Peek": show/hide, per-display checkboxes (by display UUID, persisted in `<state_root>/settings.json`), About, Quit.
- URL scheme `forceiq-peak://` (strict; unknown actions are ignored; only the action name is logged):
  `toggle`, `show`, `hide`, `expand`, `collapse`, `ask[?q=…]` (opens the ask field prefilled and never sends),
  `switch?app=<bundle id from the profile>`, `display?id=<display UUID>&state=on|off`, `voice` (toggle dictation).
- Raycast: `raycast/*.sh` script commands (package "ForceIQ Peek"). At install they're copied to `~/ForceIQ/peak/raycast/`.
  Add that folder once by hand: Raycast Settings → Extensions → + → Add Script Directory.

## Always-on PEEK status (the notch wing)
Collapsed Peek is the hardware notch plus a **status wing** on its left: a black extension in the menu bar row, flush with
the notch and exactly as tall (no flare, nothing below), so the two read as one wider notch. It says **PEEK** in brand
green (#4FFF4F), or **PRESENTING** in gold while presenting. This is the compact state the established notch apps use
(Boring Notch's closed notch and DynamicNotchKit's compact leading/trailing content both draw beside the notch at notch
height, with ~6 pt top and ~14 pt bottom corner radii). Hover or click on the wing opens Peek; the top-edge trigger covers
the whole shape. The wing is 96 pt (`PeakGeometry.wingWidth`; set it to 0 to go back to a bare notch), sized for the longest
word; it covers whatever menu-bar items sit under it (the last app menus, on an app with very long menus). The Studio Display pill has no
wing (the pill is the status). **The menu-bar status item is off** (settings.json `menuBarItem`: true brings it back as a black "PEEK" capsule); the wing is
the status. **Right-click (or ctrl-click) the wing for the Peek menu**: Show / Hide, Displays, Presenting, Do not disturb,
Built-in hotkey, Shortcut, About, Quit. (A crowded notch-Mac menu bar can also hide a status item; the M5's had no on-screen
status-item window until the wing left room.)

**What the wing says** (`WingStatus`, pure and tested): idle = PEEK in green. A session inside 60 minutes = the client's first
name (6 characters, cut with an ellipsis) and whole minutes, e.g. `Spiros 42m`, then `now` from its start until 15 minutes
after (full name in the sheet, the peek and the VoiceOver label). A small gold dot = a gap needs you (missing / unpaid
invoice or export, from the next-session feed). A small red dot = the 5090 is held (a meeting live or within 2 h, or the
meeting status unknown). Presenting = gold PRESENTING, no dots, no names. The countdown re-judges every 30 s only while
it shows (a coarse tick, no animation). Demo: `FORCEIQ_PEAK_DEMO=1` with `{"nextSessionPill": true}` in the scratch root.

## One-tap actions on the peek
A peek can carry one button. **Start** (a meeting alert) is the meeting card's Run: it opens that session's page in Command and
nothing else (Join and Record stay taps inside Command); it works without opening the card's description first, and it is
the only action that does. **Review** (a new-approval alert) lands on that approval's description with Run one explicit tap
away (describe first). No other alert has a button; presenting keeps Start and drops Review; a view-only card never runs.
The button is in the notch layout and in the Studio Display pill layout. When the pointer is on no display, the alert shows on
the notch display, else the primary one. Logs say `state peek-action=start-meeting` and `card quick-start kind=meeting`,
never the client. `commandMeetingLink` (settings.json only, no UI) is separate: it is for the voice / ask "start a meeting
with <client>" path and does nothing until voice is on.

## Settings window
Right-click the PEEK wing, then **Settings…** (Cmd-,). Every control writes through to settings.json at once: present while
Command is live and presenting now, Do not disturb (1 hour / until tomorrow / off, with when it ends), quiet hours with start
and end times, the next-session countdown and gaps, the PEEK badge in the menu bar (these two apply when Peek restarts, and the
window says so), Voice, the built-in hotkey and the shortcut. `SettingsModel` (PeakCore) holds the logic and is tested; the
view is white text on black with gold section titles.

## Notch alerts (the peek)
Collapsed Peek is the notch plus its green status wing. An urgent alert widens the collapsed shape INLINE in the menu bar row (notch height, ~145 pt each side of the notch, the way Boring Notch's
sneak peek works) for 6 s (8 s for a failed fix): the client on the left of the notch, what happened on the right, then it retracts. What peeks: a meeting starting within 10 minutes; a fix that fails after Peek is up; Command's sign-in expiring
("Command sign-in | expired"); a new approval waiting ("<client> | needs your OK"); a new family-delivery alert; a shift
download finishing for one of the coach's clients ("<client> | download finished"; shift downloads only, never a provider grab); a meeting
pack GHOST has just published ("<client> | pack ready"); a FLOW package just built ("<client> | FLOW package ready").
Everything except the meeting is news only: what was already there when Peek first read that source is the baseline and never
peeks. When several wait, the most urgent goes first (meeting, fix, sign-in, approval, family, download, FLOW package, pack), one a minute. Each line names its client (Command's sign-in names Command); the dot is green for a meeting or a finished
download and gold for anything that needs you; text is pure white. A tap opens the sheet (a meeting alert lands on the next-session card when the pill is
on); the pointer resting on it holds it 3 s at a time. Nothing peeks while Peek is open, while dictating, during a live
session, in quiet hours, under Do not disturb (menu bar: 1 hour / until tomorrow morning / off), or within a minute of the
last peek. A held alert is not spent: it peeks when the gate lifts. The decision is `AlertPolicy` (PeakCore/Alerts.swift),
pure and tested; logs carry the kind or the reason, never a client. Pushing the pointer to the very top edge within 40 pt
of the notch shape also opens Peek (that strip never takes a click, so the menu bar stays usable). Only the Studio Display
pill lifts on hover; the notch never scales or brightens, so nothing paints outside it. Demo: `FORCEIQ_PEAK_DEMO=1
FORCEIQ_PEAK_DEMO_FEED=soon GOAT_PEAK_ROOT=<scratch root>` puts the sample meeting 9 min out.

**Pack ready / FLOW package ready.** *Pack ready*: a GHOST meeting bundle for one of the coach's clients whose every asset is
available. *FLOW package ready*: a package in FLOW's project folder for one of the coach's clients whose metadata reads and whose
bundled media is on disk at the size the metadata records (the copy finished). It does NOT run the code-window check (that
check rewrites shared state files, so it stays the on-demand FLOW card): a package that later fails the check still peeked as
built. Both fire on the transition to ready, never on existence: each client is baselined on its first successful read (a read
that failed first and recovers later never turns that client's packs into news) and FLOW's folder on its first successful
listing; an unreadable or missing folder is "unknown", never "nothing there". Many published at once peek once, counted
("<client> | 3 packs ready", "<client> +2 more | packs ready"). Presenting says only "A pack is ready" / "A FLOW package is
ready". Off with `readyAlerts: false` (Settings). Demo: `FORCEIQ_PEAK_DEMO_FEED=pack` or `flow` (the second read has one new item).

**Progress line.** While GOAT is working (a fix running, a shift download running; nothing else, per the Live Activity rule)
a 2 pt gold line hangs just under the notch and its wing (the notch itself has no pixels). It is a gold fill over a faint track when every
running download reports a percent and no fix is running; otherwise a static dashed line that says "working" without claiming
how far. Percents come only from GOAT's live doc, never estimated. It is a shape (no text), never animates, takes no click,
and is hidden while the sheet or a peek is open. Demo: `FORCEIQ_PEAK_DEMO_FEED=download` (38%) or `working` (dashed).

**Presenting mode** (menu bar: "Presenting (hide client details)"). For a shared screen: alerts say only "A session in 9 min" /
"A fix failed", the sheet shows one plain notice (plus a Show details button) instead of cards, the next-session card, 3PO,
the ask field and file drops, the Studio pill drops its client countdown, dictated words aren't echoed under the notch, and
"what's my day" answers that it is hidden. It is the one place the "every item names its client" rule is suspended. The
menu-bar badge turns gold and reads "PEEK · PRESENTING" as a reminder. It is persisted (`presenting` in settings.json), and a settings file
Peek can't read turns it ON, never off. Proof: `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_FEED=soon FORCEIQ_PEAK_DEMO_TOUR=1`
with `{"presenting": true}` in the scratch root.

**Auto-presenting.** Meetings run in the Command app and the client sees the screen, so presenting turns itself on while
Command is live on this Mac (GOAT's `gpu_window.live`, i.e. `ops.meeting_live`; never a Zoom or screen-share detector) and off
when it ends. An unreadable status changes nothing. Turn it off during a meeting (menu or Show details) and it stays off until
that meeting ends; the next meeting is automatic again. Turning it on by hand is sticky (persisted); automatic presenting is
never written down. `autoPresenting: false` in settings.json disables it. Proof: `FORCEIQ_PEAK_DEMO=1
FORCEIQ_PEAK_DEMO_FEED=live GOAT_PEAK_ROOT=<scratch>` (log: `state presenting=on reason=command-live`).

## Settings (`<state_root>/settings.json`; `GOAT_PEAK_ROOT` overrides the root)
Peek writes this file itself (menu bar, Settings); you can also hand-edit it. Every key is optional: a missing key (or a
JSON `null`) gets its default and the keys that are present are kept, so `{"commandMeetingLink": true}` alone works.
Unknown keys are ignored.

| key | type | default (missing key, no file, or an unreadable file) |
|---|---|---|
| `hiddenDisplays` | array of display UUIDs | `[]` (shown on every display) |
| `globallyHidden` | true/false | `false` (shown) |
| `hotkeyEnabled` | true/false | unset: the profile's `hotkey.enabled` |
| `ghostFormat` | `"h264-black"` / `"hevc-alpha"` | `"h264-black"` |
| `voiceEnabled` | true/false | unset: the profile's `modules.voice` (false by default); an unreadable file: off |
| `desktopActions` | true/false | `false` (no UI; on only matters in a scratch root with the live opt-in) |
| `cuaActions` | true/false | `false` (no UI; the Cua backend, only inside the three live gates plus `FORCEIQ_PEAK_CUA_LIVE=1`) |
| `commandMeetingLink` | true/false | `false` (no UI) |
| `nextSessionPill` | true/false | `false` (no UI) |
| `readyAlerts` | true/false | `true` (peek when a pack or FLOW package is ready; Settings has the toggle) |
| `quietHoursStart`, `quietHoursEnd` | `"HH:mm"` (24 h, local) | unset (no quiet window; both keys needed; start later than end wraps midnight; a bad time is an invalid key) |
| `dndUntil` | seconds since 1970 | unset (the menu's Do not disturb writes it) |
| `autoPresenting` | true/false | `true` (present while Command is live; an unreadable file leaves it on) |
| `presenting` | true/false | `false`; an unreadable file: **on** (the one fail-safe-to-hidden key) |

- **No file** is normal (a new Mac, a fresh scratch root): silent defaults, nothing logged, nothing written until a setting
  changes.
- **A file that exists but can't be used** fails loudly and fails closed. That covers a file Peek can't read, an empty
  file, invalid JSON, a top level that isn't an object, or any key with the wrong type (e.g. `"desktopActions": "yes"`,
  or a number inside `hiddenDisplays`). Then:
  - **all** settings use the defaults above, and `desktopActions`, `commandMeetingLink` and voice stay **off**
    (nothing is ever on because the file was bad);
  - `logs/peak.log` gets one line naming the file and the bad key or parse position, never a value, e.g.
    `settings unreadable path=…/settings.json error=key 'desktopActions' has the wrong type (expected true/false); using defaults (desktopActions, commandMeetingLink, voice off)`;
  - the home list shows a plain-white status row: **Settings file couldn't be read: using defaults**;
  - Peek never crashes. Before its first write over the bad file, it copies the file to
    `<state_root>/settings.unreadable.json` so hand edits aren't lost. Fix the file and relaunch Peek.
- Tests: `PrefsLoadTests` (lenient decode, loud failure, safe defaults) and `SettingsNoticeGuardTests` (the row is pure
  white with no fade, and `desktopActions` has no toggle).

## Voice (opt-in; off until scored on the coach's own voice)
- **Toggle only.** The mic button in the 3PO field, `forceiq-peak://voice` or the Raycast command "Talk to 3PO": the first
  press starts, the next press stops. No hold-to-talk, no wake word, no silence auto-stop. While it listens the droid is in
  its listening state. Settings → "Voice" turns it on (`settings.json` `voiceEnabled`; else the profile's `modules.voice`).
- **Engine:** FluidAudio 0.17.7 + Parakeet TDT 0.6B v3 (Core ML, ANE), re-decoded every 160 ms; the Parakeet CTC 110M name
  boost runs once at stop against the live roster (spotter rescue OFF). Models (about 560 MB) download once, on first
  enable, into `<Peak root>/models` (pinned HF commits; progress line in the 3PO field and Settings). No NVIDIA Open Model
  License models. Audio stays in memory on this Mac: never written, never uploaded.
- **Where the words appear (collapsed).** Inline in the menu bar row, at exactly the notch's height: the earliest words end at
  the notch's left side and the rest continue on its right, newest at the far right with a gold caret; older words scroll off
  whole (a leading ellipsis). Widths are measured with the real 13 pt font, so wide letters never become "Check th…".
  Nothing hangs below the notch and nothing touches the green ring (the sheet's own field shows the words when it is open).
  On a display without a notch (the Studio Displays) the pill widens in place to one line of the newest words. A click on the
  caption stops dictation. Demo proof: `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_TOUR=voice FORCEIQ_PEAK_VOICE_FEED=<folder of
  clips named *-notch-*.wav> GOAT_PEAK_ROOT=<scratch root with models/>`; add `FORCEIQ_PEAK_DEMO_FAKE_NOTCH=1` to draw the
  13" notch layout on a Mac whose built-in display is closed.
- **Dictate shortcut.** Control-Option-D (changeable in Settings): a press starts, the next press stops. It does nothing until
  Voice is on. A click on the mic button, `forceiq-peak://voice` and the Raycast command toggle the same way.
- **If the speech model won't load**, dictation falls back to Apple Speech, ON-DEVICE ONLY (`requiresOnDeviceRecognition`):
  if this Mac can't recognize on-device, Peek says so and sends audio nowhere. Settings shows why Apple Speech is in use; the
  name boost is Parakeet-only, so the fallback has no boost. First use asks for Speech Recognition access. Log:
  `voice fallback=apple-speech reason=<error type>`. Demo-only `FORCEIQ_PEAK_VOICE_FORCE_FALLBACK=1` exercises it.
- **Measured on the M5 (release build, 11 s dictation, 33 words, spoken clip fed through the same audio path as the mic):**
  model load 28 s the first time (Core ML compiles for the ANE), 0.4 s after; first confirmed words about 0.8 to 1.0 s after
  speech starts; final text 126 to 190 ms after stop (decode 40 to 70 ms plus the 85 to 115 ms name boost); about 20 to 35 %
  of one core while listening. (The 0.5 s in the bake-off was the first unconfirmed partial.) FluidAudio's
  `SlidingWindowAsrManager` (`.streaming`: 11 s chunks, 1 s hypothesis updates) was tried in the same harness and returned no text
  for 40 of 40 short utterances, so Peek keeps its own 160 ms sliding re-decode with LocalAgreement-2.
- **Sample-WAV smoke:** `peak/scripts/voice_smoke.sh [<Peek.app>] [<models dir>]` feeds a spoken 3 s and an 11 s clip through the mic's audio path on
  the real Neural Engine and fails unless the long clip gives 28+ words, first confirmed words within 2.0 s and the final text within 500 ms.
- **Live words** in the notch / pill (when Peek is collapsed) and in the 3PO field: confirmed words only (the prefix two
  decodes agree on, about 0.5 s in), pure white at full opacity from the first word (never dimmed or gray); until the
  final pass a gold caret (▍) trails the last word, then it goes. 'Listening…' is pure white too. Client names
  underlined in gold. The mic shows "…" while it loads or finishes (never half-faded). The voice status line under the
  field rolls each new state up at full opacity (`SwapText`; no numericText cross-fade).
- **Name guard** (PeakCore `VoiceNameGuard`): the boost may replace a word only when it sounds like the name. Months,
  weekdays, numbers, function words and Peek's command words are never replaced ("October", "compare" never become
  "Cooper"); any other dictionary word (macOS `/usr/share/dict/web2`) only by a near-homophone ("Holiday" → "Halliday").
  The "'s" the boost strips is restored ("Halliday's").
- **Commands.** The final words go to 3PO exactly like a typed message. "Open <client>'s FLOW package (and hit the code
  button)" and "Start a meeting with <client>" become a local confirm card (client, meeting, time; Run / Ask Claude / Copy
  prompt); an unclear client gets a pick card. Run only opens Command's own UI (the booking's room page, else the
  schedule) or brings FLOW forward. Peek never joins, records or books, and never touches the recorder. The code-button
  click is a desktop (Cua) action: behind `settings.json` `desktopActions`, OFF, and not wired until the STOP dry run passes.
- **Desktop actions STOP dry run (locate and report only).** `FORCEIQ_PEAK_DESKTOP_DRYRUN=1` with a scratch `GOAT_PEAK_ROOT`
  (never `~/ForceIQ/peak`) turns a client command card's Run into a dry run: each step (FLOW: find the client's latest
  package → bring FLOW forward → the code-window button; Command: the app → the room / schedule link → its start control)
  is located the safe way first (Peek's deep link, the app's URL scheme, App Intents, Accessibility read-only lookup, Cua
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
  **Production FLOW is never a live target** (PeakCore `ProductionGuard`): the presser refuses, before its guard and the
  press, a frontmost app with bundle id `com.forceiq.flowai` (any case), the app at `/Applications/FLOW.app`, any running
  `com.forceiq.flowai` pid, a pid in `FORCEIQ_PEAK_PROTECTED_PIDS`, or no readable bundle id; in live mode the locator
  won't bring such an app forward either. The press only reaches an isolated, non-production FLOW (FLOW's own test build
  with its own bundle id, DB and prefs), named by the smoke-only `FORCEIQ_PEAK_FLOW_TARGET_PID` and/or
  `FORCEIQ_PEAK_FLOW_TARGET_BUNDLE`; the frontmost process must then be exactly that instance. FLOW's project window has
  no title and no AXDocument, so the window check also accepts a static text in that window that is exactly the package's
  name (case aside), and resolves symlinks. A window title must be exactly the package's name; a partial, prefix or
  longer name (`FLOW-Dem`, `FLOW-Demo-extra` for `FLOW-Demo`) is refused, by title or by text. `ProductionTargetGuardTests` covers the refusals (pid 11311, the bundle id,
  the path) and pins the order.
- **Real-press smoke** (`peak/scripts/real_press_smoke.sh`): the live press against an isolated FLOW, proven in text by
  an Accessibility read of that FLOW's window list before and after.
  ```
  peak/build.sh
  peak/scripts/real_press_smoke.sh --pid <isolated FLOW pid> --package <the .flowaipkg it has open> --mode press
  peak/scripts/real_press_smoke.sh --pid <isolated FLOW pid> --package <same> --mode stop   # STOP while armed
  peak/scripts/real_press_smoke.sh --bundle <its non-production bundle id> --check-only      # target checks only
  ```
  It refuses production FLOW (exit 3) before it looks at or launches anything: `--bundle com.forceiq.flowai`, any pid of
  a running `/Applications/FLOW.app`, or a pid in `FORCEIQ_PEAK_PROTECTED_PIDS`, and hands those pids to Peek. It makes
  a scratch `GOAT_PEAK_ROOT` under `~/ForceIQ/peak-tmp` with `settings.json` `{"desktopActions": true, "hiddenDisplays":
  [], "globallyHidden": false}` (Peek ignores a settings.json missing the last two, so the flag would read off) and a
  package folder holding only a symlink named for the demo client, launches a demo Peek of the build in live mode, checks
  Peek logged `desktop mode=live`, taps Peek's own Run (AX, Peek's button only), and reads FLOW's windows again.
  `--mode press` passes when no `Code Window` window was open before, Peek logged one press, and a `Code Window` window is
  open after. `--mode stop` first closes an open `Code Window` window in the isolated FLOW, taps Peek's STOP while the
  press is armed, and passes on `STOPPED phase=before_press`, no press, no `Code Window` window. Then it quits its own
  demo Peek, deletes the scratch root (the symlink only) and leaves the proof in `~/ForceIQ/peak-tmp/real-press-<mode>-<time>`
  (or `--out`). No screen captures. The script never activates, quits or opens a FLOW (only Peek's step 2 brings the
  isolated FLOW forward, by pid) and never changes the installed Peek, its settings or the engine. Accessibility for the terminal is required (the helper `scripts/real_press_ax.swift` is
  compiled into `$TMPDIR`).
- **Cua backend (flag, OFF by default, no UI; waits for Chris's GO on his real setup).** [Cua](https://github.com/trycua/cua)'s
  `cua-driver` (MIT, pinned `0.36.0` with hashes in `peak/cua/requirements.lock`) can make the ONE live press instead of
  Peek's own AXPress. It lives in its own venv, `~/ForceIQ/.venv-peak-cua` (`peak/cua/install.sh`: `uv pip sync
  --require-hashes`, TMPDIR `~/ForceIQ/peak-tmp/cua/`), never the test venv or system Python. It is on only when all four
  hold: a scratch root (not `~/ForceIQ/peak`), `desktopActions: true`, `FORCEIQ_PEAK_DESKTOP_LIVE=1`, and `cuaActions: true`
  plus `FORCEIQ_PEAK_CUA_LIVE=1` (PeakCore `CuaGate`; log `desktop cua=on|off`). Off, Peek never imports, spawns or calls
  Cua (`CuaBackend.make` returns nil, `spawnCount` stays 0).
  - **One choke point.** Cua runs only from `DesktopPresser.pressCodeWindow`, after the same frontmost, production and
    PressGuard checks. `CuaBackend.invokeMenu` needs a `PressAuthorization` (minted only by re-running every guard) and an
    `ApprovalTicket` (minted only when the approval card's Run is tapped); neither can be built elsewhere.
  - **Approval card first.** Before every Cua run Peek shows a card: what it does ("Cua will press FLOW's Tools ›
    Code Window"), what it touches (that FLOW's pid and bundle id; no files, no other app, no database, no network), then
    Run / Cancel. Only a tap on that card's Run (`peak-cua-run`) mints the ticket; voice or a link never does; STOP,
    Cancel or 2 minutes without a tap cancel it. After the tap every guard runs again before the child starts.
  - **Production FLOW refused** as before (pid 11311 / any production pid, `com.forceiq.flowai`, `/Applications/FLOW.app`),
    and again inside the Cua child (`peak/cua/peak_cua_runner.py`) before `cua_driver` is imported and against the live
    process list after it. The child runs Cua embedded (never the CuaDriver.app daemon), calls only `list_apps`,
    `list_windows`, `invoke_menu` (fails closed, never falls back to pixels), never requests permissions, and gets a
    minimal environment (no keys or tokens, telemetry off).
  - **STOP** kills the child's whole process group (SIGKILL) and reaps it; `CuaBackendTests` measures ≤ 100 ms.
  - **Live smoke** (`peak/scripts/cua_live_smoke.sh`, same refusals and AX proof as the real-press smoke):
    ```
    peak/scripts/cua_live_smoke.sh --pid <isolated FLOW pid> --package <its .flowaipkg> --mode press
    peak/scripts/cua_live_smoke.sh --pid <isolated FLOW pid> --package <same> --mode stop   # STOP mid Cua run
    ```
    `--mode stop` holds the child in flight (`FORCEIQ_PEAK_CUA_SMOKE_HOLD_MS=3000`, after its checks, before Cua is
    imported) and passes on `stop_latency_ms` ≤ 100, the child gone, no press. If an isolated FLOW restores an empty
    window state instead of opening its package, launch it with `-ApplePersistenceIgnoreState YES` (this process only).
- **Command meeting link (flag, OFF by default; waits for Command #685's deploy).** With `settings.json`
  `commandMeetingLink: true` (no UI) or `FORCEIQ_PEAK_COMMAND_MEETING_LINK=1`, and desktop actions off, "start a meeting
  with <client>" resolves the client in this coach's Command directory (`GET /api/peak/client-directory`, kept in memory
  for 120 s, a failure for 30 s; never on disk). Only an exact, unique `display_name` match (case- and
  whitespace-normalised) goes straight to the link card; several, partial or fuzzy matches give a pick card naming the
  candidates; no match gives a plain not-found card. The card names the client and describes what Run does; Run (an
  explicit tap) re-validates and opens `forceiq-command://meeting/start?client_id=<lowercase uuid>&source=goat`, which
  shows Command's own Start / Cancel sheet: nothing starts until Start is tapped in Command. A name never goes into the
  link. 401 / a dead session → the existing "Command sign-in expired, tap to sign in" row; 403 (client role) → one dead
  state; nothing retries in a loop. Logs: `3po meeting-link match=unique|ambiguous|none clients=<n> …`, never a name or id.
  Flag off (or a desktop dry-run / live gate on) → the meeting start is unchanged (room page / schedule; locate-only under
  the gates). Known gaps (Command): the client_id is lost after a signed-out login, and the link is desktop-only (iOS out
  of scope). Smoke: `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_TOUR=meeting-link GOAT_PEAK_ROOT=<scratch root with
  settings.json {"commandMeetingLink": true}>` types unique / ambiguous / none against a mocked directory (fake clients)
  and taps Run once (demo: nothing opens).
- **Next-session pill and gap warnings (flag, OFF by default; read-only).** With `settings.json` `nextSessionPill: true`
  (no UI, no env opt-in), Peek asks `GET /api/peak/next-session` at most every 5 min (30 min after a sign-in loss; 403 →
  one dead state, no more asks) and keeps the answer in memory only. Flag off → no fetches, no pill. The engine reads
  Command through its existing auth and back-off (`panels.command_get`, the #23 dead-after-3 gate); Peek carries no token.
  Everything is scoped to this coach's profile and roster (`peakdrop.roster`); a booking for anyone else is dropped.
  - **Pill:** names the client and counts down locally (`in 42m`, `now`, `started 5m ago`; a 30 s `TimelineView`, no
    loop). Collapsed: the pill in pill mode, a gold dot in notch mode. Expanded: the pill sits on top of the home list;
    tap it for the card.
  - **Card (describes, never acts):** client, session time, countdown, **since last met** from Ghost (last meeting date,
    games since, G/A/P, latest game, Ghost score average, team change), and the gaps. It says "Read-only. Nothing here
    sends, books or changes an invoice."
  - **Gaps** (each names the client; any *present* gap turns the pill brand gold, `Brand.goldHex`; *unknown* gaps are
    listed with a note and leave the pill outline green; text is always pure white): (a) breakdown export missing for today's session; (b) invoice missing
    for today's session (same client and service month, status draft/pending/paid, from Command `/invoices/`); (c) an
    invoice pending 7 days or more (Command, never Square; 6d23h is not a gap, 7d is).
  - **Actions:** only **Ask TRON** (copies a prompt for TRON; nothing is sent) and **Copy**. No Run, no family contact, no
    booking or invoice change.
  - **Unknown until Command adds** (requested via TRON): (a) a read endpoint for a booking's breakdown export, e.g.
    `GET /schedule/bookings/{booking_id}/exports`, so (a) is always "unknown" today; (b) `invoice_id` (or `package_id`) on
    bookings rows so an invoice can be tied to the exact session instead of client + month.
  - Logs: `next-session outcome=… session=yes|no gaps=<present> unknown=<n> gold=yes|no fetches=<n>`, never a name. Smoke:
    `FORCEIQ_PEAK_DEMO=1 FORCEIQ_PEAK_DEMO_TOUR=next-session GOAT_PEAK_ROOT=<scratch root with settings.json
    {"nextSessionPill": true}>` fetches a mocked feed (fake clients), opens the card, taps Ask TRON and Copy (demo: an
    in-memory clipboard) and logs counts only.
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
peak/build.sh      # → peak/build/ForceIQ Peek.app (scratch, SwiftPM cache and TMPDIR under ~/ForceIQ/)
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

## "What's my day" brief and the 5090 light

- **Brief.** Type `/day` or "what's my day" in 3PO (or say it with the voice toggle; Voice stays off by default). Peek
  answers locally, with zero tokens and in three sentences: today's Command sessions (each naming the client), what's BLOCKED, and the
  decisions waiting on you. It reads next-meeting `today`, `/api/approvals` and `/api/live`. A source older than 300 s
  is labelled `STALE (read 9:30 AM ET, 12 min ago)`. A source that didn't answer is said plainly and nothing is
  invented. Speech uses only macOS AVSpeechSynthesizer on this Mac, and only while Voice is on. Pressing the voice
  toggle again stops it mid-sentence.
- **5090 light.** This is the dot under the expanded header. It's red from 2 h before a meeting through its end, including a
  meeting in progress. Because the bookings read is upcoming-only, an in-progress meeting comes from Command live on this
  Mac or from the calendar. The message names the case, e.g. "Meeting in progress (started 9:10 AM ET)" or "Meeting at
  9:30 AM ET, within 2 h". Otherwise the light is green. It's unknown when there's no read, the read is older than 300 s, Command's live status
  can't be read, or the calendar is unknown (missing, garbled, access not granted, no fetch time) or STALE (its
  `fetched_at` is older than 300 s). Unknown is treated as red and labelled. While it isn't green, Peek refuses every 5090 GPU action (the
  shifts/upscale drop zone, GPU proposals and GPU approvals) with one plain sentence, and nothing runs. Status reads only:
  Peek never talks to the 5090, its recording service, the service that guards it, or the recorder machine.
