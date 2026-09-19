#include "../../Effects/Fullscreen.fxh"
texture History { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler HistorySampler { Texture = History; };
float4 PS(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return tex2D(HistorySampler, uv); }
technique HistoryEffect { pass { VertexShader = FullscreenVS; PixelShader = PS; RenderTarget = History; } }
