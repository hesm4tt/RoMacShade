#version 450

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outFragColor;

layout(binding = 0) uniform sampler2D sceneDepth;

layout(push_constant) uniform PushConstants {
    float exposure;
    float contrast;
    float vibrance;
    float bloomIntensity;
    float aoStrength;
    float hasDepth;
    float width;
    float height;
} pc;

void main() {
    // Multiplicative modulation factor (1.0 = unchanged scene)
    vec3 modColor = vec3(1.0);

    // 1. Ambient Occlusion from captured TBDR 3D depth buffer
    float ao = 1.0;
    if (pc.hasDepth > 0.5) {
        float rawDepth = texture(sceneDepth, inUV).r;
        float dCenter = 1.0 - rawDepth;
        vec2 texel = vec2(3.5 / pc.width, 3.5 / pc.height);

        float dN = 1.0 - texture(sceneDepth, inUV + vec2(0.0, texel.y)).r;
        float dS = 1.0 - texture(sceneDepth, inUV - vec2(0.0, texel.y)).r;
        float dE = 1.0 - texture(sceneDepth, inUV + vec2(texel.x, 0.0)).r;
        float dW = 1.0 - texture(sceneDepth, inUV - vec2(texel.x, 0.0)).r;

        float depthDiff = (abs(dCenter - dN) + abs(dCenter - dS) + abs(dCenter - dE) + abs(dCenter - dW));
        ao = clamp(1.0 - depthDiff * pc.aoStrength * 28.0, 0.20, 1.0);
        modColor *= ao;
    }

    // 2. Exposure & Contrast boost
    modColor *= pc.exposure;
    modColor = pow(clamp(modColor, 0.001, 2.0), vec3(pc.contrast));

    // 3. Cinematic Color Grading (Vibrant preset: sunlight warm highlights, deep rich shadows)
    vec3 warmSun = vec3(1.12, 1.05, 0.92);
    vec3 coolShadow = vec3(0.88, 0.94, 1.08);
    float lumaEst = clamp((modColor.r + modColor.g + modColor.b) * 0.333, 0.0, 1.0);
    modColor *= mix(coolShadow, warmSun, lumaEst);

    // 4. Aspect-ratio aware cinematic vignette
    vec2 coord = (inUV - 0.5) * vec2(pc.width / pc.height, 1.0);
    float vig = 1.0 - smoothstep(0.40, 1.35, length(coord));
    modColor *= mix(1.0, vig, 0.40);

    // 5. Discrete stylized RoShade indicator in top-right corner
    vec2 pixelPos = inUV * vec2(pc.width, pc.height);
    vec2 indicatorPos = vec2(pc.width - 36.0, 44.0);
    float distToIndicator = length(pixelPos - indicatorPos);
    if (distToIndicator < 6.0) {
        // Glowing azure dot indicating active Vulkan RoShade injection
        modColor = vec3(0.2, 1.6, 2.0);
    } else if (distToIndicator < 10.0) {
        modColor *= 1.3;
    }

    // Output modulation color for multiplicative blending
    outFragColor = vec4(clamp(modColor, 0.0, 2.5), 1.0);
}
