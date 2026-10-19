// ForceIQ Peak: glow ring AROUND the Ghost mark (SwiftUI .colorEffect). Never applied to the mark itself.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 ghostGlow(float2 position, half4 color, float time, half4 tint, float strength) {
    float pulse = 0.5 + 0.5 * sin(time * 3.0 + position.x * 0.08 + position.y * 0.05);
    half a = color.a * half(clamp(strength * (0.45 + 0.55 * pulse), 0.0, 1.0));
    return half4(tint.rgb * a, a);
}
