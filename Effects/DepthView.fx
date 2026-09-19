// Original MacShade depth inspection effect. Finite perspective, near=1, far=1000.
#include "Fullscreen.fxh"
uniform float FarPlane < ui_label = "Far plane"; ui_min = 10.0; ui_max = 2000.0; > = 1000.0;
uniform float NearPlane < ui_label = "Near plane"; ui_min = 0.01; ui_max = 10.0; > = 1.0;
uniform float DisplayCurve < ui_label = "Display contrast"; ui_min = 0.1; ui_max = 1.0; > = 0.25;
texture2D SceneDepth : DEPTH;
sampler2D DepthSampler { Texture = SceneDepth; MinFilter = POINT; MagFilter = POINT; };
float4 DepthPS(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    float raw = tex2D(DepthSampler,uv).r;
    float normalizedDepth = NearPlane / max(FarPlane - raw * (FarPlane-NearPlane),0.00001);
    float shade=pow(saturate(normalizedDepth),DisplayCurve);
    return float4(shade,shade,shade,1.0);
}
technique DepthView { pass { VertexShader = FullscreenVS; PixelShader = DepthPS; } }
