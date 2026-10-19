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
3PO avatar: slot reserved (module id `3po`), art due EOD Mon.
