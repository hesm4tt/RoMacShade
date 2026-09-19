#include "FXCompiler.hpp"
#include "../ThirdParty/ReShadeFX/source/effect_codegen.hpp"
#include "../ThirdParty/ReShadeFX/source/effect_parser.hpp"
#include "../ThirdParty/ReShadeFX/source/effect_preprocessor.hpp"
#include "../ThirdParty/SPIRV-Cross/spirv_msl.hpp"
#include <algorithm>
#include <cctype>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>

namespace macshade {
namespace {
std::string Uppercase(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return text;
}

size_t FindTexture(const reshadefx::effect_module &module, const std::string &name) {
    for (size_t i = 0; i < module.textures.size(); ++i)
        if (module.textures[i].unique_name == name) return i;
    throw std::runtime_error("Sampler references an unknown texture: " + name);
}

void WriteDefaultUniforms(FXProgram &program) {
    // ReShade's SPIR-V generator uses 4-byte scalars, 16-byte array stride and
    // 16-byte matrix-row stride. Its matrix representation is transposed when
    // generating SPIR-V, so the original constant's rows are copied intact.
    program.defaultUniformData.assign(program.module.total_uniform_size, 0);
    for (const auto &uniform : program.module.uniforms) {
        if (!uniform.has_initializer_value) continue;
        const auto &type = uniform.type;
        const size_t elementSize = type.is_matrix() ? type.rows * 16 : type.rows * 4;
        const size_t arrayStride = (elementSize + 15) & ~size_t(15);
        const size_t count = type.is_array() ? type.array_length : 1;
        for (size_t element = 0; element < count; ++element) {
            const reshadefx::constant *value = &uniform.initializer_value;
            if (type.is_array()) {
                if (element >= uniform.initializer_value.array_data.size()) continue;
                value = &uniform.initializer_value.array_data[element];
            }
            const size_t offset = uniform.offset + (type.is_array() ? element * arrayStride : 0);
            const size_t rows = type.is_matrix() ? type.rows : 1;
            const size_t components = type.is_matrix() ? type.cols : type.rows;
            for (size_t row = 0; row < rows; ++row) {
                const size_t destination = offset + row * 16;
                if (destination + components * 4 > program.defaultUniformData.size())
                    throw std::runtime_error("Uniform initializer exceeds its declared buffer layout: " + uniform.name);
                std::memcpy(program.defaultUniformData.data() + destination,
                            value->as_uint + row * components, components * 4);
            }
        }
    }
}

FXEntryPoint TranslateEntry(const std::vector<uint32_t> &spirv,
                            const std::pair<std::string, reshadefx::shader_type> &entry,
                            const reshadefx::effect_module &module) {
    const auto model = entry.second == reshadefx::shader_type::vertex
        ? spv::ExecutionModelVertex : spv::ExecutionModelFragment;
    spirv_cross::CompilerMSL compiler(spirv);
    compiler.set_entry_point(entry.first, model);
    const auto active = compiler.get_active_interface_variables();
    compiler.set_enabled_interface_variables(active);
    const auto resources = compiler.get_shader_resources(active);
    if (!resources.storage_images.empty() || !resources.storage_buffers.empty() ||
        !resources.subpass_inputs.empty() || !resources.push_constant_buffers.empty())
        throw std::runtime_error("Storage resources, subpass inputs and push constants are not supported: " + entry.first);
    if (!resources.separate_images.empty() || !resources.separate_samplers.empty())
        throw std::runtime_error("Unexpected separate image/sampler resources in the ReShade SPIR-V module.");
    if (resources.uniform_buffers.size() > 1)
        throw std::runtime_error("Multiple uniform buffers are not supported: " + entry.first);
    if (resources.sampled_images.size() > 16)
        throw std::runtime_error("This entry point exceeds MacShade's 16 sampled-texture limit: " + entry.first);

    spirv_cross::CompilerMSL::Options mslOptions;
    mslOptions.platform = spirv_cross::CompilerMSL::Options::macOS;
    mslOptions.set_msl_version(2, 3);
    mslOptions.argument_buffers = false;
    mslOptions.pad_fragment_output_components = true;
    compiler.set_msl_options(mslOptions);
    auto commonOptions = compiler.get_common_options();
    // FX full-screen vertex shaders already produce top-left texture UVs and
    // Direct3D/Metal depth [0,1]. Metal's viewport performs the required Y mapping.
    commonOptions.vertex.flip_vert_y = false;
    commonOptions.vertex.fixup_clipspace = false;
    compiler.set_common_options(commonOptions);

    FXEntryPoint result;
    result.fxName = entry.first;
    result.stage = entry.second;
    if (entry.second == reshadefx::shader_type::pixel) {
        for (const auto &resource : resources.stage_outputs) {
            if (compiler.has_decoration(resource.id, spv::DecorationLocation)) {
                const auto &type = compiler.get_type(resource.type_id);
                if (type.columns == 1 && type.array.empty())
                    result.outputComponents[compiler.get_decoration(resource.id, spv::DecorationLocation)] = type.vecsize;
            }
        }
    }
    uint32_t slot = 0;
    for (const auto &resource : resources.sampled_images) {
        const uint32_t descriptorSet = compiler.get_decoration(resource.id, spv::DecorationDescriptorSet);
        const uint32_t binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
        // Entry-point assembly compacts descriptor bindings, but preserves the
        // original SPIR-V variable IDs recorded in module.samplers. A binding
        // number is therefore not an index into the module's sampler list.
        const auto samplerIterator = std::find_if(module.samplers.begin(), module.samplers.end(),
            [&resource](const reshadefx::sampler &value) { return value.id == resource.id; });
        if (descriptorSet != 1 || samplerIterator == module.samplers.end())
            throw std::runtime_error("Unexpected sampled-texture binding in entry point: " + entry.first);
        const size_t samplerIndex = static_cast<size_t>(samplerIterator - module.samplers.begin());
        const auto &sampler = *samplerIterator;
        const size_t textureIndex = FindTexture(module, sampler.texture_name);
        const auto &texture = module.textures[textureIndex];
        const std::string semantic = Uppercase(texture.semantic);
        if (!semantic.empty() && semantic != "COLOR" && semantic != "DEPTH")
            throw std::runtime_error("Unsupported external texture semantic '" + texture.semantic + "': " + texture.name);
        if (texture.type != reshadefx::texture_type::texture_2d)
            throw std::runtime_error("Only 2D effect textures are currently supported: " + texture.name);
        spirv_cross::MSLResourceBinding mapping;
        mapping.stage = model;
        mapping.desc_set = descriptorSet;
        mapping.binding = binding;
        mapping.msl_texture = slot;
        mapping.msl_sampler = slot;
        compiler.add_msl_resource_binding(mapping);
        result.sampledBindings.push_back({samplerIndex, textureIndex, slot, slot});
        ++slot;
    }
    if (!resources.uniform_buffers.empty()) {
        const auto &resource = resources.uniform_buffers.front();
        spirv_cross::MSLResourceBinding mapping;
        mapping.stage = model;
        mapping.desc_set = compiler.get_decoration(resource.id, spv::DecorationDescriptorSet);
        mapping.binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
        mapping.msl_buffer = 0;
        compiler.add_msl_resource_binding(mapping);
        result.uniformBufferSlot = 0;
        result.uniformBufferSize = compiler.get_declared_struct_size(compiler.get_type(resource.base_type_id));
    }
    result.metalSource = compiler.compile();
    result.metalName = compiler.get_cleansed_entry_point_name(entry.first, model);
    // Check the generated resource indices against the reflection result instead
    // of assuming the Metal backend preserved a requested binding.
    for (size_t i = 0; i < resources.sampled_images.size(); ++i) {
        const auto id = resources.sampled_images[i].id;
        const uint32_t textureSlot = compiler.get_automatic_msl_resource_binding(id);
        const uint32_t samplerSlot = compiler.get_automatic_msl_resource_binding_secondary(id);
        if (textureSlot == UINT32_MAX || samplerSlot == UINT32_MAX)
            throw std::runtime_error("Metal resource reflection is missing an active texture or sampler: " + entry.first);
        result.sampledBindings[i].textureSlot = textureSlot;
        result.sampledBindings[i].samplerSlot = samplerSlot;
    }
    if (!resources.uniform_buffers.empty()) {
        const uint32_t binding = compiler.get_automatic_msl_resource_binding(resources.uniform_buffers.front().id);
        if (binding == UINT32_MAX)
            throw std::runtime_error("Metal resource reflection is missing the uniform buffer: " + entry.first);
        result.uniformBufferSlot = static_cast<int32_t>(binding);
    }
    return result;
}
} // namespace

bool CompileFXFile(const std::filesystem::path &file, const FXCompileOptions &options,
                   FXProgram &output, std::string &error) {
    error.clear();
    try {
        if (options.width == 0 || options.height == 0 || options.width > 16384 || options.height > 16384)
            throw std::runtime_error("FX buffer dimensions must be between 1 and 16384 pixels.");
        reshadefx::preprocessor preprocessor;
        preprocessor.add_include_path(std::filesystem::absolute(file).parent_path());
        for (const auto &directory : options.includeDirectories)
            preprocessor.add_include_path(directory);
        // Compatibility macros describe the shader-language interface only.
        // __RENDERER__ selects the SPIR-V/Vulkan branch used before Metal translation.
        std::map<std::string, std::string> definitions = {
            {"__RESHADE__", "60000"}, {"__RESHADE_PERFORMANCE_MODE__", "0"},
            {"__RENDERER__", "0x20000"}, {"__VENDOR__", "0x106B"},
            {"BUFFER_WIDTH", std::to_string(options.width)},
            {"BUFFER_HEIGHT", std::to_string(options.height)},
            {"BUFFER_RCP_WIDTH", "(1.0 / BUFFER_WIDTH)"},
            {"BUFFER_RCP_HEIGHT", "(1.0 / BUFFER_HEIGHT)"},
            {"BUFFER_COLOR_BIT_DEPTH", "8"}, {"BUFFER_COLOR_SPACE", "1"},
            {"RESHADE_DEPTH_INPUT_IS_REVERSED", "0"},
            {"tex2Dlodoffset", "tex2Dlod"},
            {"tex2Doffset", "tex2D"}
        };
        for (const auto &definition : options.definitions) definitions[definition.first] = definition.second;
        for (const auto &definition : definitions)
            preprocessor.add_macro_definition(definition.first, definition.second);
        if (!preprocessor.append_file(file)) {
            error = preprocessor.errors();
            return false;
        }
        // ReShade emits SPIR-V directly; glslang, DXC and a Vulkan runtime are not required.
        std::unique_ptr<reshadefx::codegen> backend(
            reshadefx::create_codegen_spirv(true, false, false, false, false));
        reshadefx::parser parser;
        if (!parser.parse(preprocessor.output(), backend.get())) {
            error = parser.errors();
            return false;
        }
        FXProgram result;
        result.module = backend->module();
        result.width = options.width;
        result.height = options.height;
        result.warnings = preprocessor.errors() + parser.errors();
        result.includedFiles = preprocessor.included_files();
        if (result.module.techniques.empty())
            throw std::runtime_error("The FX file declares no techniques.");
        for (const auto &entry : result.module.entry_points) {
            if (entry.second != reshadefx::shader_type::vertex && entry.second != reshadefx::shader_type::pixel)
                throw std::runtime_error("FX compute entry points are not supported: " + entry.first);
        }
        if (!result.module.storages.empty())
            throw std::runtime_error("FX storage images are not supported by MacShade's raster runtime.");
        for (const auto &entry : result.module.entry_points) {
            // This ReShade backend's finalize_code() is intentionally empty;
            // binary SPIR-V is emitted through per-entry assembly instead.
            std::string binary, assembly, diagnostics;
            if (!backend->assemble_code_for_entry_point(entry.first, binary, assembly, diagnostics))
                throw std::runtime_error("Could not assemble FX entry point " + entry.first + ": " + diagnostics);
            result.warnings += diagnostics;
            if (binary.size() < 20 || binary.size() % sizeof(uint32_t) != 0)
                throw std::runtime_error("The FX compiler produced an invalid SPIR-V buffer: " + entry.first);
            std::vector<uint32_t> spirv(binary.size() / sizeof(uint32_t));
            std::memcpy(spirv.data(), binary.data(), binary.size());
            result.entryPoints.emplace(entry.first, TranslateEntry(spirv, entry, result.module));
        }
        WriteDefaultUniforms(result);
        size_t paddedSize = result.defaultUniformData.size();
        for (const auto &entry : result.entryPoints)
            paddedSize = std::max(paddedSize, entry.second.uniformBufferSize);
        result.defaultUniformData.resize((paddedSize + 15) & ~size_t(15), 0);
        output = std::move(result);
        return true;
    } catch (const std::exception &exception) {
        error = exception.what();
        return false;
    } catch (...) {
        error = "Unknown error while compiling ReShade FX to Metal.";
        return false;
    }
}
} // namespace macshade
