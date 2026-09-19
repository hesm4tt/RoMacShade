#include "../../Effects/Fullscreen.fxh"
texture Scene : COLOR;
sampler SceneSampler { Texture = Scene; SRGBTexture = true; };
float4 PS(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    return tex2D(SceneSampler, uv);
}
technique Roundtrip { pass { VertexShader = FullscreenVS; PixelShader = PS; SRGBWriteEnable = true; } }
