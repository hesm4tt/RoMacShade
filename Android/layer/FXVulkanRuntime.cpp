//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan ReShadeFX Runtime & Presentation Post-Processor.
//

#include "FXVulkanRuntime.h"
#include <algorithm>
#include <cmath>

namespace roshade {

FXVulkanRuntime &FXVulkanRuntime::instance() {
    static FXVulkanRuntime runtime;
    return runtime;
}

void FXVulkanRuntime::setConfig(const FXVulkanConfig &config) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_config = config;
}

VkResult FXVulkanRuntime::initDevice(VkDevice device, VkPhysicalDevice physicalDevice, PFN_vkGetDeviceProcAddr gdpa) {
    if (!gdpa) return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::mutex> lock(m_mutex);
    DeviceContext ctx;
    ctx.device = device;
    ctx.physicalDevice = physicalDevice;
    ctx.dispatch.gdpa = gdpa;

#define LOAD_VK_PROC(name) ctx.dispatch.name = reinterpret_cast<PFN_vk##name>(gdpa(device, "vk" #name))
    LOAD_VK_PROC(CreateSampler);
    LOAD_VK_PROC(DestroySampler);
    LOAD_VK_PROC(CreateDescriptorSetLayout);
    LOAD_VK_PROC(DestroyDescriptorSetLayout);
    LOAD_VK_PROC(CreatePipelineLayout);
    LOAD_VK_PROC(DestroyPipelineLayout);
    LOAD_VK_PROC(CreateGraphicsPipelines);
    LOAD_VK_PROC(DestroyPipeline);
    LOAD_VK_PROC(CreateShaderModule);
    LOAD_VK_PROC(DestroyShaderModule);
    LOAD_VK_PROC(CreateCommandPool);
    LOAD_VK_PROC(DestroyCommandPool);
    LOAD_VK_PROC(AllocateCommandBuffers);
    LOAD_VK_PROC(FreeCommandBuffers);
    LOAD_VK_PROC(BeginCommandBuffer);
    LOAD_VK_PROC(EndCommandBuffer);
    LOAD_VK_PROC(CmdBeginRenderPass);
    LOAD_VK_PROC(CmdEndRenderPass);
    LOAD_VK_PROC(CmdBindPipeline);
    LOAD_VK_PROC(CmdBindDescriptorSets);
    LOAD_VK_PROC(CmdPushConstants);
    LOAD_VK_PROC(CmdDraw);
    LOAD_VK_PROC(QueueSubmit);
    LOAD_VK_PROC(QueueWaitIdle);
#undef LOAD_VK_PROC

    // Create samplers
    VkSamplerCreateInfo samplerInfo{};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_LINEAR;
    samplerInfo.minFilter = VK_FILTER_LINEAR;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    if (ctx.dispatch.CreateSampler) {
        ctx.dispatch.CreateSampler(device, &samplerInfo, nullptr, &ctx.colorSampler);
    }

    samplerInfo.magFilter = VK_FILTER_NEAREST;
    samplerInfo.minFilter = VK_FILTER_NEAREST;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    if (ctx.dispatch.CreateSampler) {
        ctx.dispatch.CreateSampler(device, &samplerInfo, nullptr, &ctx.depthSampler);
    }

    // Create descriptor set layout
    VkDescriptorSetLayoutBinding bindings[2]{};
    bindings[0].binding = 0;
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    bindings[0].pImmutableSamplers = nullptr;

    bindings[1].binding = 1;
    bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[1].descriptorCount = 1;
    bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    bindings[1].pImmutableSamplers = nullptr;

    VkDescriptorSetLayoutCreateInfo layoutInfo{};
    layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layoutInfo.bindingCount = 2;
    layoutInfo.pBindings = bindings;
    if (ctx.dispatch.CreateDescriptorSetLayout) {
        ctx.dispatch.CreateDescriptorSetLayout(device, &layoutInfo, nullptr, &ctx.descLayout);
    }

    // Create pipeline layout with push constants for live settings
    VkPushConstantRange pushRange{};
    pushRange.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    pushRange.offset = 0;
    pushRange.size = sizeof(float) * 8; // vibrance, exposure, contrast, time, width, height, etc.

    VkPipelineLayoutCreateInfo pipeLayoutInfo{};
    pipeLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeLayoutInfo.setLayoutCount = 1;
    pipeLayoutInfo.pSetLayouts = &ctx.descLayout;
    pipeLayoutInfo.pushConstantRangeCount = 1;
    pipeLayoutInfo.pPushConstantRanges = &pushRange;
    if (ctx.dispatch.CreatePipelineLayout) {
        ctx.dispatch.CreatePipelineLayout(device, &pipeLayoutInfo, nullptr, &ctx.pipelineLayout);
    }

    ctx.initialized = true;
    m_devices[device] = ctx;
    return VK_SUCCESS;
}

void FXVulkanRuntime::destroyDevice(VkDevice device) {
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_devices.find(device);
    if (it != m_devices.end()) {
        auto &ctx = it->second;
        if (ctx.graphicsPipeline && ctx.dispatch.DestroyPipeline) ctx.dispatch.DestroyPipeline(device, ctx.graphicsPipeline, nullptr);
        if (ctx.pipelineLayout && ctx.dispatch.DestroyPipelineLayout) ctx.dispatch.DestroyPipelineLayout(device, ctx.pipelineLayout, nullptr);
        if (ctx.descLayout && ctx.dispatch.DestroyDescriptorSetLayout) ctx.dispatch.DestroyDescriptorSetLayout(device, ctx.descLayout, nullptr);
        if (ctx.colorSampler && ctx.dispatch.DestroySampler) ctx.dispatch.DestroySampler(device, ctx.colorSampler, nullptr);
        if (ctx.depthSampler && ctx.dispatch.DestroySampler) ctx.dispatch.DestroySampler(device, ctx.depthSampler, nullptr);
        if (ctx.commandPool && ctx.dispatch.DestroyCommandPool) ctx.dispatch.DestroyCommandPool(device, ctx.commandPool, nullptr);
        m_devices.erase(it);
    }
}

void FXVulkanRuntime::registerSwapchain(VkSwapchainKHR swapchain, VkFormat format, uint32_t width, uint32_t height, const std::vector<VkImage> &images) {
    std::lock_guard<std::mutex> lock(m_mutex);
    SwapchainContext ctx;
    ctx.format = format;
    ctx.width = width;
    ctx.height = height;
    ctx.images = images;
    m_swapchains[swapchain] = ctx;
}

void FXVulkanRuntime::destroySwapchain(VkSwapchainKHR swapchain) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_swapchains.erase(swapchain);
}

VkResult FXVulkanRuntime::onQueuePresent(VkQueue queue, const VkPresentInfoKHR *pPresentInfo, PFN_vkQueuePresentKHR origPresent) {
    if (!pPresentInfo || !origPresent) return VK_ERROR_INITIALIZATION_FAILED;

    if (!m_config.enabled) {
        return origPresent(queue, pPresentInfo);
    }

    // Intercept presentation and forward
    return origPresent(queue, pPresentInfo);
}

} // namespace roshade
