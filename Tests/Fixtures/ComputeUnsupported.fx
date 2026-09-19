void UnsupportedCompute(uint3 threadID : SV_DispatchThreadID)
{
}
technique ComputeUnsupported
{
    pass
    {
        ComputeShader = UnsupportedCompute<1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
    }
}
