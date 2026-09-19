#pragma once
#include "../ThirdParty/ReShadeFX/source/effect_module.hpp"
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace macshade {

struct FXCompileOptions {
    uint32_t width = 1920;
    uint32_t height = 1080;
    std::vector<std::filesystem::path> includeDirectories;
    std::map<std::string, std::string> definitions;
};

struct FXSampledBinding {
    size_t samplerIndex = 0; ///< Index into FXProgram::module.samplers.
    size_t textureIndex = 0; ///< Index into FXProgram::module.textures.
    uint32_t textureSlot = 0; ///< Metal [[texture(N)]].
    uint32_t samplerSlot = 0; ///< Metal [[sampler(N)]].
};

struct FXEntryPoint {
    std::string fxName; ///< Corresponds to pass.vs_entry_point or ps_entry_point.
    std::string metalName; ///< Actual, potentially renamed Metal function name.
    std::string metalSource;
    reshadefx::shader_type stage = reshadefx::shader_type::unknown;
    std::vector<FXSampledBinding> sampledBindings;
    std::map<uint32_t, uint32_t> outputComponents; ///< Original fragment components by color location, before MSL padding.
    int32_t uniformBufferSlot = -1; ///< -1 when the stage has no active uniforms.
    size_t uniformBufferSize = 0;
};

struct FXProgram {
    reshadefx::effect_module module;
    std::map<std::string, FXEntryPoint> entryPoints;
    std::vector<uint8_t> defaultUniformData; ///< SPIR-V/MSL layout, including padding.
    std::vector<std::filesystem::path> includedFiles;
    std::string warnings;
    uint32_t width = 0;
    uint32_t height = 0;
};

/// Compile user-supplied ReShade FX source to Metal and preserve pass metadata.
/// The source file's directory is searched before additional include paths.
/// Current backend accepts raster effects and COLOR/DEPTH textures. The runtime
/// requires an explicit depth input for techniques that actively sample DEPTH.
/// Compute, storage images and unknown external texture semantics fail explicitly.
/// This compiles shader source only; pipeline creation and pass execution belong
/// to the runtime. All exceptions are converted into the diagnostic string.
bool CompileFXFile(const std::filesystem::path &file, const FXCompileOptions &options,
                   FXProgram &output, std::string &error);

} // namespace macshade
