# Add a coach to ForceIQ Peak

Peak is per-coach. Its code has no coach names, clients, paths, bundle IDs or keys. Everything comes from that coach's
own GOAT overlay on that coach's own Mac.

1. **GOAT first.** The coach's Mac runs GOAT core with its own overlay (`<goat root>/overlay/profile.json`, or the
   directory in `GOAT_OVERLAY`). `engine/cbprofile.py` reads it. Peak doesn't have a parallel config.
2. **Add the `peak` section.** Copy `peak/profile.template.json` → the `"peak"` object into that overlay's `profile.json`
   and fill it in:
   - `coach_id`, `display_name`.
   - `state_root`: normally `~/ForceIQ/peak`. Logs (`logs/peak.log`), settings (`settings.json`), the profile cache, and
     later the memory store and the spend meter all live there.
   - `apps`: the app switcher. Read each bundle ID from the installed app (`/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "/Applications/X.app/Contents/Info.plist"`
     or `mdfind "kMDItemCFBundleIdentifier == '…'"`). Never guess. A listed app that isn't installed shows a gold outline and "Not installed".
   - `goat_bundle_id`: the coach's GOAT app (Open in GOAT).
   - `claude_key_ref`: a **Keychain reference** (service + account). Never the key itself; the engine drops anything
     that looks like a credential.
   - `accounts`: Command and FLOW account *references* only.
   - `hotkey`, `modules`: on/off per coach. Modules today: `meetings`, `approvals` (GOAT fixes + approvals), `family`
     (also needs `GOAT_FAMILY_DELIVERY_ALERTS`), `switcher`. Declared for later: `drops`, `3po`, `voice`,
     `machine_glance`, `spend`.
3. **Roster.** It isn't typed anywhere. Peak gets this coach's client names from the engine (`GET /api/peak/profile` →
   `roster`). Today that comes from the coach's GOAT book (`coaches.<owner>.book`, the same source as GOAT's vocab and
   suggest). There's no Command roster read in the engine yet; when there is, only `engine/peakprofile.py roster()`
   changes. Cards for clients who aren't on the roster are never shown (they're counted as "more in GOAT").
4. **Check it.** `curl -s http://127.0.0.1:8765/api/peak/profile` on that Mac (it's local-only; other devices get 403).
   You should see `"configured": true` and the right `coach_id`.
5. **Build and install** on that Mac: `peak/build.sh`, then the install step copies `peak/build/ForceIQ Peak.app` and
   `peak/raycast/` to `~/ForceIQ/peak/`. Raycast: Settings → Extensions → + → Add Script Directory →
   `~/ForceIQ/peak/raycast` (one time, by hand; Raycast keeps that list in its own encrypted DB).

Nothing in this file touches another coach's Mac. One coach, one overlay, one state root.
