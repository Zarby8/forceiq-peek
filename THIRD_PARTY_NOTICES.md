# ForceIQ Peak: third-party notices

| Component | Use | License | Pin |
|---|---|---|---|
| [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global show/hide hotkey + its recorder view | MIT | exact `3.1.0`, commit `772133d9dbe800fdac0473226822994c5c162c58` (SwiftPM, see `Package.resolved`) |
| [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) | Voice: on-device speech recognition (Core ML, ANE) and the CTC name boost | Apache-2.0 | `v0.17.7`, commit `503b4bd1bbf7220882de39fe8ae6716aae4132da` (SwiftPM revision pin, see `Package.resolved`); built with **no traits** (its optional prebuilt NemoTextProcessing binary is not linked) |
| Parakeet TDT 0.6B v3 (NVIDIA), Core ML repack [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Voice: the speech model (downloaded on first enable into `<Peak root>/models`, not bundled) | CC-BY-4.0 | HF commit `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`; upstream [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) @ `541d1f99c6b0c3cd0b11a95167540bb8edefd82b` |
| Parakeet CTC 110M (NVIDIA), Core ML repack [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) | Voice: keyword spotter for the client-name boost | CC-BY-4.0 | HF commit `accdafd8cf8a2ff1cabe3c11e54416b405d409aa` |

Not adopted: DynamicNotchKit (MIT; reference only), twostraws/Inferno (MIT; no shader copied, the glow is Peak's own).
No code from boring.notch, DynamicNotch or mew-notch (GPL-3) is used. Nothing in Peak is GPL: FluidAudio is Apache-2.0 and
its own third-party notices (fastcluster BSD-2, VBx Apache-2.0, NemoTextProcessing Apache-2.0, TTS front-ends Apache/MIT/BSD;
UniDic is tri-licensed GPL/LGPL/BSD and taken under BSD, and is used only by FluidAudio's Japanese TTS, which Peak never calls)
ship in its checkout under `ThirdPartyLicenses/`. No NVIDIA Open Model License weights are used (no Parakeet EOU, Nemotron
or Parakeet Unified). Peak's name guard reads macOS's own word list (`/usr/share/dict/web2`, Webster's Second, public domain)
at runtime; it is not bundled.

## Parakeet weights: NVIDIA, CC-BY-4.0 (attribution)

"Parakeet TDT 0.6B v3" and "Parakeet CTC 110M" by NVIDIA, licensed under the Creative Commons Attribution 4.0 International
License (https://creativecommons.org/licenses/by/4.0/). Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 and
NVIDIA's Parakeet CTC 110M; converted to Core ML by FluidInference
(https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml, https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml).
Peak does not modify the weights; it downloads them unchanged at the pinned commits above. No warranties are given.

## FluidAudio: Apache License 2.0 (notice)

FluidAudio, Copyright FluidInference (https://github.com/FluidInference/FluidAudio), licensed under the Apache License,
Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0). FluidAudio ships no NOTICE file at v0.17.7; its LICENSE and
`ThirdPartyLicenses/` are reproduced with the checkout SwiftPM fetches. Unless required by applicable law or agreed to in
writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied. Peak uses FluidAudio unmodified.

Art: BOB Motion **ForceIQ-Peak-BOB-v1, v1.1** (internal ForceIQ art, Chris-locked; `Resources/ASSETS.md`) and BOB Motion
**ForceIQ-Peak-3PO-v1** (the 3PO droid: rig, loops, still; internal ForceIQ art, pinned by MANIFEST MD5
`bf67596170da1025137b8fda5485369d`). Not third-party. The droid plays with Apple system frameworks only (AVFoundation,
RealityKit); no new package dependency, no GPL code.

## KeyboardShortcuts: MIT License

MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
