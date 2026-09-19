// Each pass adds half an exposure stop. The intermediate uses 8-bit linear RGB.
#include "Fullscreen.fxh"

texture2D SceneColor : COLOR;
sampler2D SceneSampler
{
    Texture = SceneColor;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

texture2D Intermediate
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA8;
};
sampler2D IntermediateSampler
{
    Texture = Intermediate;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

float4 FirstPS(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    float4 color = tex2D(SceneSampler, uv);
    return float4(color.rgb * exp2(0.5), color.a);
}

float4 SecondPS(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    float4 color = tex2D(IntermediateSampler, uv);
    return float4(color.rgb * exp2(0.5), color.a);
}

technique TwoPass
{
    pass First
    {
        VertexShader = FullscreenVS;
        PixelShader = FirstPS;
        RenderTarget = Intermediate;
    }
    pass Second
    {
        VertexShader = FullscreenVS;
        PixelShader = SecondPS;
    }
}
