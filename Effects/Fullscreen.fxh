#ifndef MACSHADE_FULLSCREEN_FXH
#define MACSHADE_FULLSCREEN_FXH

// An oversized triangle covers the complete frame without a diagonal seam.
void FullscreenVS(uint vertexID : SV_VertexID,
                  out float4 position : SV_Position,
                  out float2 uv : TEXCOORD0)
{
    uv = float2((vertexID << 1) & 2, vertexID & 2);
    position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
}

#endif
