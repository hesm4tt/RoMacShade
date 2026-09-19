#include "../../Effects/Fullscreen.fxh"
texture2D SceneDepth : DEPTH;
sampler2D DepthSampler { Texture = SceneDepth; };
float4 DepthPS(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    return float4(tex2D(DepthSampler, uv).rrr, 1.0);
}
technique DepthUnsupported
{
    pass { VertexShader = FullscreenVS; PixelShader = DepthPS; }
}
