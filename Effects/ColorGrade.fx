// Original MacShade example. No external ReShade include files are required.
#include "Fullscreen.fxh"

uniform float Exposure <
    ui_type = "slider";
    ui_min = -2.0;
    ui_max = 2.0;
    ui_label = "Exposure (stops)";
> = 0.5;

uniform float Saturation <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 2.0;
> = 1.0;

texture2D SceneColor : COLOR;
sampler2D SceneSampler
{
    Texture = SceneColor;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

float4 GradePS(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    float4 color = tex2D(SceneSampler, uv);
    color.rgb *= exp2(Exposure);
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = lerp(luma.xxx, color.rgb, Saturation);
    return color;
}

float4 CopyPS(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    return tex2D(SceneSampler, uv);
}

technique ColorGrade
{
    pass
    {
        VertexShader = FullscreenVS;
        PixelShader = GradePS;
    }
}

technique Copy
{
    pass
    {
        VertexShader = FullscreenVS;
        PixelShader = CopyPS;
    }
}
