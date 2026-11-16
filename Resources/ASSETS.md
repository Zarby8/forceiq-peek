# Ghost mark assets

**BOB Motion `ForceIQ-Peak-BOB-v1`, version 1.1** (tarball `ForceIQ-Peak-BOB-v1.1.tar.gz`, MD5 `bca17c6b5226efcf0fe1eefc362df582`,
verified). Brand sign-off in the pack MANIFEST: "TRON-approved 10/18 (ForceIQ Peak surface)". Internal ForceIQ art,
Chris-locked: Peak never recolors or alters the mark; effects only go around it (and none for attention, which has its own bloom).

Bundled (only what Peak uses): `bob/MANIFEST.json` (as shipped, v1.1) and `bob/h264-black/peak-bob-<asset>-{64,128}.mp4`
for all six assets (idle, attention, thinking, typing, receipt, error), 12 files, ~240 KB. Every file's MD5 is checked
against MANIFEST.json by `PeakCoreTests.testBundledFilesMatchManifestMD5AndOnlyUsedSizesShip`.

Playback is driven by MANIFEST.json (`peak_state_map` + `states.*.loop`), never by frame numbers in code:
idle = loop (v1.1: 60 frames, 0-59, seamless); attention = loop 0-47; working = thinking intro 0-15 then loop 16-71;
typing = intro 0-19 then loop 20-67; receipt = once, then idle; error = once, hold f61 (real failures only).
No idle crossfade (v1.1's idle is seamless).

Formats: `h264-black` (default; no alpha needed on the pure-black notch/pill). `hevc-alpha` is a setting
(`settings.json` `ghostFormat`), not bundled and not yet proven in AVFoundation; Peak falls back to h264-black for any
missing file. To try it: point `FORCEIQ_PEAK_GHOST_DIR` at an unpacked pack root that has `hevc-alpha/`.

Lineage: BOB-Motion-Ghost-v2 (v2.1-export-bolt); canonical web launcher assets in Zarby8/forceiq-ghost #278 (5f077edb) / #284 (917d675b).
Raycast icon `raycast/images/peak.png` = pack `posters/peak-bob-idle-64.png` (MD5 68bd04a588eac29b067f68b8b92b5d2f).

# 3PO chat droid assets

**BOB Motion `ForceIQ-Peak-3PO-v1`** (tarball `ForceIQ-Peak-3PO-v1.tar.gz`, 1.03 GB, MD5 `4c712b9fd55dca52f43769976ec5b6ad`;
`MANIFEST.json` MD5 `bf67596170da1025137b8fda5485369d`; all 395 file MD5s verified on the box, the bundled ones again on the M5).
Brand sign-off in the pack: "TRON-approved 10/18 (ForceIQ Peak surface)". Original droid design (concept A, split visor),
Blender 4.5.9 LTS / Cycles, no AI generation. Internal ForceIQ art; Peak never recolors it.

Bundled in `threepo/` (16 files, ~2.0 MB; `PeakCoreTests.ThreePOAvatarBundleTests` checks the set and every MD5):
- `MANIFEST.json` as shipped (drives frames / fps / clip names; nothing hardcoded in the player).
- `rig/3po.usdz` (1.5 MB): the live RealityKit rig, **the default tier**. M5 first-load check (macOS 26.6.2): loads in
  ~0.3 s, every node of the README contract is there (`head`, `head/eye_glow`, `head/eye_scan`, `head/talk_light`,
  `talk_light_ring`), and the load fix sets both `talk_light` materials' emission to 0. Driven by the pack's own curves
  (`PeakCore/ThreePOCurves.swift`, ported from `source/curves.py`); while tokens stream the talk light follows the stream rate.
- `hevc_alpha/64/3po_<clip>_64_hevc_alpha.mov`: 5 loops + 8 transitions (13 files, ~320 KB), the middle tier.
  hevc_alpha was proven on the M5: AVFoundation decodes `hvc1` with `ContainsAlphaChannel`, corner alpha 0, body
  alpha 254, and an AVPlayerLayer over a pure red layer shows red through the corners (h264_black shows black).
- `sprites/64/talking/3po_talk_amp_00_64.png`: the neutral still (Reduce Motion, beside each reply).
Only 64 px ships: the header is 32 pt (@2x = 64 px; macOS has no @3x). The 96–768 px sizes, ProRes, h264_black,
PNG zips and the other sprites stay in the pack.

Order (`AvatarTier`): rig → rendered loops → the static vector droid mark (`DroidMark`). `FORCEIQ_PEAK_3PO_RIG=0`
skips the rig; `FORCEIQ_PEAK_3PO_RIG=<file.usdz>` loads another rig; `FORCEIQ_PEAK_3PO_DIR=<pack root>` points at an
unpacked pack. A missing or broken usdz falls back to the loops (tested); no complete loop set falls back to the mark.

# GHOST avatar pack

**ForceIQ-Peek-GHOST-v1, version 1.0** — Chris's ghost-on-the-gold-ring character (pose sheet + motion test
approved as-is 2026-11-16), selectable with `FORCEIQ_PEAK_MARK=ghost`; the eyes and BOB stay the defaults.
Bundled: `ghost/MANIFEST.json` + `ghost/h264-black/peak-ghost-<asset>-{64,128}.mp4` for six assets
(idle, working, waiting, done, failed, sleeping), 12 files, ~470 KB; every MD5 is checked by
`GhostAvatarPackTests`. The pack declares its own `file_prefix` (`peak-ghost-`) in the manifest;
a manifest without one keeps the BOB default.

Source: the 1152x768 / 24 fps / 10 s motion-test grid (2 cols x 3 rows). Each cell was centre-cropped
256x256 and scaled; loops are ping-pong (the BOB idle precedent: frames 24..83..25 of the cell, 118 frames),
one-shots play forward (60 frames). State map: idle->idle (fierce), working->working, attention->waiting,
receipt->done (one-shot, then idle), error->failed (one-shot, hold last frame). typing has no pose in the
grid and rides the working loop; sleeping ships in the pack but no GhostState maps to it yet.
