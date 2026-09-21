//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan ReShadeFX Runtime & Presentation Post-Processor.
//

#include "FXVulkanRuntime.h"
#include "CompiledShaders.h"
#include "Log.h"
#include <algorithm>
#include <cmath>
#include <cstring>

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
    LOAD_VK_PROC(CreateDescriptorPool);
    LOAD_VK_PROC(DestroyDescriptorPool);
    LOAD_VK_PROC(AllocateDescriptorSets);
    LOAD_VK_PROC(UpdateDescriptorSets);
    LOAD_VK_PROC(CreatePipelineLayout);
    LOAD_VK_PROC(DestroyPipelineLayout);
    LOAD_VK_PROC(CreateGraphicsPipelines);
    LOAD_VK_PROC(DestroyPipeline);
    LOAD_VK_PROC(CreateShaderModule);
    LOAD_VK_PROC(DestroyShaderModule);
    LOAD_VK_PROC(CreateRenderPass);
    LOAD_VK_PROC(DestroyRenderPass);
    LOAD_VK_PROC(CreateFramebuffer);
    LOAD_VK_PROC(DestroyFramebuffer);
    LOAD_VK_PROC(CreateImageView);
    LOAD_VK_PROC(DestroyImageView);
    LOAD_VK_PROC(CreateCommandPool);
    LOAD_VK_PROC(DestroyCommandPool);
    LOAD_VK_PROC(AllocateCommandBuffers);
    LOAD_VK_PROC(FreeCommandBuffers);
    LOAD_VK_PROC(BeginCommandBuffer);
    LOAD_VK_PROC(EndCommandBuffer);
    LOAD_VK_PROC(ResetCommandBuffer);
    LOAD_VK_PROC(CmdBeginRenderPass);
    LOAD_VK_PROC(CmdEndRenderPass);
    LOAD_VK_PROC(CmdBindPipeline);
    LOAD_VK_PROC(CmdBindDescriptorSets);
    LOAD_VK_PROC(CmdPushConstants);
    LOAD_VK_PROC(CmdSetViewport);
    LOAD_VK_PROC(CmdSetScissor);
    LOAD_VK_PROC(CmdPipelineBarrier);
    LOAD_VK_PROC(CmdDraw);
    LOAD_VK_PROC(QueueSubmit);
    LOAD_VK_PROC(QueueWaitIdle);
#undef LOAD_VK_PROC

    // 1. Create Command Pool
    VkCommandPoolCreateInfo poolInfo{};
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    poolInfo.queueFamilyIndex = 0; // Default graphics family
    if (ctx.dispatch.CreateCommandPool) {
        ctx.dispatch.CreateCommandPool(device, &poolInfo, nullptr, &ctx.commandPool);
    }

    // 2. Create Depth Sampler (Linear clamp)
    VkSamplerCreateInfo samplerInfo{};
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    samplerInfo.magFilter = VK_FILTER_LINEAR;
    samplerInfo.minFilter = VK_FILTER_LINEAR;
    samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    if (ctx.dispatch.CreateSampler) {
        ctx.dispatch.CreateSampler(device, &samplerInfo, nullptr, &ctx.depthSampler);
    }

    // 3. Create Descriptor Set Layout (Binding 0: sceneDepth sampler)
    VkDescriptorSetLayoutBinding binding{};
    binding.binding = 0;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    VkDescriptorSetLayoutCreateInfo descLayoutInfo{};
    descLayoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    descLayoutInfo.bindingCount = 1;
    descLayoutInfo.pBindings = &binding;
    if (ctx.dispatch.CreateDescriptorSetLayout) {
        ctx.dispatch.CreateDescriptorSetLayout(device, &descLayoutInfo, nullptr, &ctx.descLayout);
    }

    // 4. Create Pipeline Layout with Push Constants
    VkPushConstantRange pushRange{};
    pushRange.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    pushRange.offset = 0;
    pushRange.size = sizeof(float) * 8; // exposure, contrast, vibrance, bloom, aoStrength, hasDepth, width, height

    VkPipelineLayoutCreateInfo pipeLayoutInfo{};
    pipeLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeLayoutInfo.setLayoutCount = (ctx.descLayout != VK_NULL_HANDLE) ? 1 : 0;
    pipeLayoutInfo.pSetLayouts = &ctx.descLayout;
    pipeLayoutInfo.pushConstantRangeCount = 1;
    pipeLayoutInfo.pPushConstantRanges = &pushRange;
    if (ctx.dispatch.CreatePipelineLayout) {
        ctx.dispatch.CreatePipelineLayout(device, &pipeLayoutInfo, nullptr, &ctx.pipelineLayout);
    }

    // 5. Create Descriptor Pool & Allocate Descriptor Set
    VkDescriptorPoolSize poolSize{};
    poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSize.descriptorCount = 8;

    VkDescriptorPoolCreateInfo descPoolInfo{};
    descPoolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    descPoolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    descPoolInfo.maxSets = 8;
    descPoolInfo.poolSizeCount = 1;
    descPoolInfo.pPoolSizes = &poolSize;
    if (ctx.dispatch.CreateDescriptorPool) {
        ctx.dispatch.CreateDescriptorPool(device, &descPoolInfo, nullptr, &ctx.descPool);
    }

    if (ctx.descPool && ctx.descLayout && ctx.dispatch.AllocateDescriptorSets) {
        VkDescriptorSetAllocateInfo allocInfo{};
        allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.descriptorPool = ctx.descPool;
        allocInfo.descriptorSetCount = 1;
        allocInfo.pSetLayouts = &ctx.descLayout;
        VkResult aRes = ctx.dispatch.AllocateDescriptorSets(device, &allocInfo, &ctx.descSet);
        if (aRes == VK_SUCCESS) {
            LOGI("FXVulkanRuntime: Successfully allocated descriptor set %p", static_cast<void *>(ctx.descSet));
        } else {
            LOGE("FXVulkanRuntime: Failed to allocate descriptor set: %d", aRes);
        }
    }

    // 6. Create Shader Modules
    if (ctx.dispatch.CreateShaderModule) {
        VkShaderModuleCreateInfo vsInfo{};
        vsInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        vsInfo.codeSize = kPostProcessVertSPVSize;
        vsInfo.pCode = kPostProcessVertSPV;
        ctx.dispatch.CreateShaderModule(device, &vsInfo, nullptr, &ctx.vsModule);

        VkShaderModuleCreateInfo fsInfo{};
        fsInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        fsInfo.codeSize = kPostProcessFragSPVSize;
        fsInfo.pCode = kPostProcessFragSPV;
        ctx.dispatch.CreateShaderModule(device, &fsInfo, nullptr, &ctx.fsModule);
    }

    ctx.initialized = true;
    m_devices[device] = ctx;
    LOGI("FXVulkanRuntime: Initialized device %p, shaders loaded (VS=%zu bytes, FS=%zu bytes)",
         static_cast<void *>(device), kPostProcessVertSPVSize, kPostProcessFragSPVSize);
    return VK_SUCCESS;
}

void FXVulkanRuntime::destroyDevice(VkDevice device) {
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_devices.find(device);
    if (it != m_devices.end()) {
        auto &ctx = it->second;
        if (ctx.graphicsPipeline && ctx.dispatch.DestroyPipeline) ctx.dispatch.DestroyPipeline(device, ctx.graphicsPipeline, nullptr);
        if (ctx.renderPass && ctx.dispatch.DestroyRenderPass) ctx.dispatch.DestroyRenderPass(device, ctx.renderPass, nullptr);
        if (ctx.vsModule && ctx.dispatch.DestroyShaderModule) ctx.dispatch.DestroyShaderModule(device, ctx.vsModule, nullptr);
        if (ctx.fsModule && ctx.dispatch.DestroyShaderModule) ctx.dispatch.DestroyShaderModule(device, ctx.fsModule, nullptr);
        if (ctx.descPool && ctx.dispatch.DestroyDescriptorPool) ctx.dispatch.DestroyDescriptorPool(device, ctx.descPool, nullptr);
        if (ctx.pipelineLayout && ctx.dispatch.DestroyPipelineLayout) ctx.dispatch.DestroyPipelineLayout(device, ctx.pipelineLayout, nullptr);
        if (ctx.descLayout && ctx.dispatch.DestroyDescriptorSetLayout) ctx.dispatch.DestroyDescriptorSetLayout(device, ctx.descLayout, nullptr);
        if (ctx.depthSampler && ctx.dispatch.DestroySampler) ctx.dispatch.DestroySampler(device, ctx.depthSampler, nullptr);
        if (ctx.commandPool && ctx.dispatch.DestroyCommandPool) ctx.dispatch.DestroyCommandPool(device, ctx.commandPool, nullptr);
        m_devices.erase(it);
    }
}

VkResult FXVulkanRuntime::buildPipelineForDevice(DeviceContext &ctx, VkFormat format) {
    if (ctx.graphicsPipeline != VK_NULL_HANDLE) return VK_SUCCESS;
    if (!ctx.dispatch.CreateRenderPass || !ctx.dispatch.CreateGraphicsPipelines) return VK_ERROR_INITIALIZATION_FAILED;

    // 1. Create RenderPass with LOAD_OP_LOAD (preserve rendered scene)
    VkAttachmentDescription colorAtt{};
    colorAtt.format = format;
    colorAtt.samples = VK_SAMPLE_COUNT_1_BIT;
    colorAtt.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    colorAtt.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    colorAtt.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    colorAtt.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    colorAtt.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    colorAtt.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkAttachmentReference colorRef{};
    colorRef.attachment = 0;
    colorRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &colorRef;

    VkRenderPassCreateInfo rpInfo{};
    rpInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpInfo.attachmentCount = 1;
    rpInfo.pAttachments = &colorAtt;
    rpInfo.subpassCount = 1;
    rpInfo.pSubpasses = &subpass;
    VkResult res = ctx.dispatch.CreateRenderPass(ctx.device, &rpInfo, nullptr, &ctx.renderPass);
    if (res != VK_SUCCESS) {
        LOGE("FXVulkanRuntime: Failed to create post-processing render pass: %d", res);
        return res;
    }

    // 2. Shader Stages
    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = ctx.vsModule;
    stages[0].pName = "main";

    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = ctx.fsModule;
    stages[1].pName = "main";

    // 3. Vertex Input (Empty, driven by gl_VertexIndex)
    VkPipelineVertexInputStateCreateInfo viInfo{};
    viInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    // 4. Input Assembly
    VkPipelineInputAssemblyStateCreateInfo iaInfo{};
    iaInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    iaInfo.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    // 5. Viewport & Scissor (Dynamic)
    VkPipelineViewportStateCreateInfo vpInfo{};
    vpInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vpInfo.viewportCount = 1;
    vpInfo.scissorCount = 1;

    // 6. Rasterization State
    VkPipelineRasterizationStateCreateInfo rsInfo{};
    rsInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rsInfo.polygonMode = VK_POLYGON_MODE_FILL;
    rsInfo.cullMode = VK_CULL_MODE_NONE;
    rsInfo.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rsInfo.lineWidth = 1.0f;

    // 7. Multisample State
    VkPipelineMultisampleStateCreateInfo msInfo{};
    msInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    msInfo.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    // 8. Color Blend State (Multiplicative blend: out * dest)
    VkPipelineColorBlendAttachmentState blendAtt{};
    blendAtt.blendEnable = VK_TRUE;
    blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_DST_COLOR;
    blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAtt.colorBlendOp = VK_BLEND_OP_ADD;
    blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    blendAtt.alphaBlendOp = VK_BLEND_OP_ADD;
    blendAtt.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                              VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo cbInfo{};
    cbInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cbInfo.attachmentCount = 1;
    cbInfo.pAttachments = &blendAtt;

    // 9. Dynamic States
    VkDynamicState dynStates[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynInfo{};
    dynInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynInfo.dynamicStateCount = 2;
    dynInfo.pDynamicStates = dynStates;

    // 10. Pipeline Create Info
    VkGraphicsPipelineCreateInfo pipeInfo{};
    pipeInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeInfo.stageCount = 2;
    pipeInfo.pStages = stages;
    pipeInfo.pVertexInputState = &viInfo;
    pipeInfo.pInputAssemblyState = &iaInfo;
    pipeInfo.pViewportState = &vpInfo;
    pipeInfo.pRasterizationState = &rsInfo;
    pipeInfo.pMultisampleState = &msInfo;
    pipeInfo.pColorBlendState = &cbInfo;
    pipeInfo.pDynamicState = &dynInfo;
    pipeInfo.layout = ctx.pipelineLayout;
    pipeInfo.renderPass = ctx.renderPass;
    pipeInfo.subpass = 0;

    res = ctx.dispatch.CreateGraphicsPipelines(ctx.device, VK_NULL_HANDLE, 1, &pipeInfo, nullptr, &ctx.graphicsPipeline);
    if (res == VK_SUCCESS) {
        LOGI("FXVulkanRuntime: Post-processing graphics pipeline created successfully!");
    } else {
        LOGE("FXVulkanRuntime: Failed to create graphics pipeline: %d", res);
    }
    return res;
}

void FXVulkanRuntime::registerSwapchain(VkDevice device, VkSwapchainKHR swapchain, VkFormat format, uint32_t width, uint32_t height, const std::vector<VkImage> &images) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_devices.empty()) return;

    // Use matching device if possible
    auto devIt = m_devices.find(device);
    if (devIt == m_devices.end()) {
        devIt = m_devices.begin();
    }
    auto &ctx = devIt->second;

    buildPipelineForDevice(ctx, format);

    SwapchainContext swCtx;
    swCtx.device = ctx.device;
    swCtx.format = format;
    swCtx.width = width;
    swCtx.height = height;
    swCtx.images = images;
    swCtx.views.resize(images.size());
    swCtx.framebuffers.resize(images.size());

    // Create ImageViews and Framebuffers for swapchain images
    for (size_t i = 0; i < images.size(); ++i) {
        VkImageViewCreateInfo viewInfo{};
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = images[i];
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = format;
        viewInfo.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
        viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        viewInfo.subresourceRange.baseMipLevel = 0;
        viewInfo.subresourceRange.levelCount = 1;
        viewInfo.subresourceRange.baseArrayLayer = 0;
        viewInfo.subresourceRange.layerCount = 1;
        ctx.dispatch.CreateImageView(ctx.device, &viewInfo, nullptr, &swCtx.views[i]);

        VkFramebufferCreateInfo fbInfo{};
        fbInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fbInfo.renderPass = ctx.renderPass;
        fbInfo.attachmentCount = 1;
        fbInfo.pAttachments = &swCtx.views[i];
        fbInfo.width = width;
        fbInfo.height = height;
        fbInfo.layers = 1;
        ctx.dispatch.CreateFramebuffer(ctx.device, &fbInfo, nullptr, &swCtx.framebuffers[i]);
    }

    // Allocate reusable presentation command buffer
    if (ctx.commandPool && ctx.dispatch.AllocateCommandBuffers) {
        VkCommandBufferAllocateInfo allocInfo{};
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocInfo.commandPool = ctx.commandPool;
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocInfo.commandBufferCount = 1;
        ctx.dispatch.AllocateCommandBuffers(ctx.device, &allocInfo, &swCtx.cmdBuffer);
    }

    m_swapchains[swapchain] = swCtx;
    LOGI("FXVulkanRuntime: registerSwapchain %p (%ux%u, format=%d, %zu images/framebuffers configured)",
         static_cast<void *>(swapchain), width, height, format, images.size());
}

void FXVulkanRuntime::destroySwapchain(VkSwapchainKHR swapchain) {
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_swapchains.find(swapchain);
    if (it != m_swapchains.end()) {
        auto &swCtx = it->second;
        auto devIt = m_devices.find(swCtx.device);
        if (devIt != m_devices.end()) {
            auto &ctx = devIt->second;
            for (auto fb : swCtx.framebuffers) {
                if (fb && ctx.dispatch.DestroyFramebuffer) ctx.dispatch.DestroyFramebuffer(ctx.device, fb, nullptr);
            }
            for (auto view : swCtx.views) {
                if (view && ctx.dispatch.DestroyImageView) ctx.dispatch.DestroyImageView(ctx.device, view, nullptr);
            }
            if (swCtx.cmdBuffer && ctx.dispatch.FreeCommandBuffers) {
                ctx.dispatch.FreeCommandBuffers(ctx.device, ctx.commandPool, 1, &swCtx.cmdBuffer);
            }
        }
        m_swapchains.erase(it);
    }
}

VkResult FXVulkanRuntime::onQueuePresent(VkQueue queue, const VkPresentInfoKHR *pPresentInfo, PFN_vkQueuePresentKHR origPresent) {
    if (!pPresentInfo || !origPresent) return VK_ERROR_INITIALIZATION_FAILED;

    static uint64_t s_frameCounter = 0;
    s_frameCounter++;

    if (!m_config.enabled) {
        return origPresent(queue, pPresentInfo);
    }

    std::lock_guard<std::mutex> lock(m_mutex);

    for (uint32_t i = 0; i < pPresentInfo->swapchainCount; ++i) {
        VkSwapchainKHR swapchain = pPresentInfo->pSwapchains[i];
        uint32_t imageIndex = pPresentInfo->pImageIndices[i];

        auto swIt = m_swapchains.find(swapchain);
        if (swIt == m_swapchains.end()) continue;
        auto &swCtx = swIt->second;

        auto devIt = m_devices.find(swCtx.device);
        if (devIt == m_devices.end()) continue;
        auto &ctx = devIt->second;

        if (imageIndex >= swCtx.images.size() || imageIndex >= swCtx.framebuffers.size()) continue;
        if (!ctx.graphicsPipeline || !swCtx.cmdBuffer) continue;

        // Query active depth from DepthCaptureManager
        CapturedDepthBuffer depth = DepthCaptureManager::instance().getActiveDepth(ctx.device);

        VkCommandBuffer cmd = swCtx.cmdBuffer;
        if (ctx.dispatch.ResetCommandBuffer) {
            ctx.dispatch.ResetCommandBuffer(cmd, 0);
        }

        VkCommandBufferBeginInfo beginInfo{};
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (ctx.dispatch.BeginCommandBuffer) {
            ctx.dispatch.BeginCommandBuffer(cmd, &beginInfo);
        }

        // 1. Transition swapchain image: PRESENT_SRC_KHR -> COLOR_ATTACHMENT_OPTIMAL
        VkImageMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = swCtx.images[imageIndex];
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        if (ctx.dispatch.CmdPipelineBarrier) {
            ctx.dispatch.CmdPipelineBarrier(
                cmd,
                VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                0, 0, nullptr, 0, nullptr, 1, &barrier);
        }

        // 2. Begin Post-Processing RenderPass
        VkRenderPassBeginInfo rpBegin{};
        rpBegin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rpBegin.renderPass = ctx.renderPass;
        rpBegin.framebuffer = swCtx.framebuffers[imageIndex];
        rpBegin.renderArea.offset = {0, 0};
        rpBegin.renderArea.extent = {swCtx.width, swCtx.height};

        if (ctx.dispatch.CmdBeginRenderPass) {
            ctx.dispatch.CmdBeginRenderPass(cmd, &rpBegin, VK_SUBPASS_CONTENTS_INLINE);
        }

        // 3. Dynamic Viewport and Scissor
        if (ctx.dispatch.CmdSetViewport) {
            VkViewport vp{};
            vp.x = 0.0f;
            vp.y = 0.0f;
            vp.width = static_cast<float>(swCtx.width);
            vp.height = static_cast<float>(swCtx.height);
            vp.minDepth = 0.0f;
            vp.maxDepth = 1.0f;
            ctx.dispatch.CmdSetViewport(cmd, 0, 1, &vp);
        }
        if (ctx.dispatch.CmdSetScissor) {
            VkRect2D sc{};
            sc.offset = {0, 0};
            sc.extent = {swCtx.width, swCtx.height};
            ctx.dispatch.CmdSetScissor(cmd, 0, 1, &sc);
        }

        // 4. Bind Pipeline
        if (ctx.dispatch.CmdBindPipeline) {
            ctx.dispatch.CmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.graphicsPipeline);
        }

        // 5. Update & Bind Depth Descriptor Set
        bool hasValidDepth = false;
        if (ctx.descSet != VK_NULL_HANDLE && depth.view != VK_NULL_HANDLE && m_config.enableAO) {
            VkDescriptorImageInfo imageInfo{};
            imageInfo.imageLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
            imageInfo.imageView = depth.view;
            imageInfo.sampler = ctx.depthSampler;

            VkWriteDescriptorSet write{};
            write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descSet;
            write.dstBinding = 0;
            write.dstArrayElement = 0;
            write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            write.descriptorCount = 1;
            write.pImageInfo = &imageInfo;

            if (ctx.dispatch.UpdateDescriptorSets) {
                ctx.dispatch.UpdateDescriptorSets(ctx.device, 1, &write, 0, nullptr);
            }

            if (ctx.dispatch.CmdBindDescriptorSets) {
                ctx.dispatch.CmdBindDescriptorSets(
                    cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipelineLayout, 0, 1, &ctx.descSet, 0, nullptr);
            }
            hasValidDepth = true;
        }

        // 6. Push Constants (Exposure, Contrast, Vibrance, AO Strength, Depth Flag)
        struct PushConstants {
            float exposure;
            float contrast;
            float vibrance;
            float bloomIntensity;
            float aoStrength;
            float hasDepth;
            float width;
            float height;
        } pc{};
        pc.exposure = m_config.exposure;
        pc.contrast = m_config.contrast;
        pc.vibrance = m_config.vibrance;
        pc.bloomIntensity = 0.35f;
        pc.aoStrength = m_config.enableAO ? m_config.aoStrength : 0.0f;
        pc.hasDepth = hasValidDepth ? 1.0f : 0.0f;
        pc.width = static_cast<float>(swCtx.width);
        pc.height = static_cast<float>(swCtx.height);

        if (ctx.dispatch.CmdPushConstants) {
            ctx.dispatch.CmdPushConstants(
                cmd, ctx.pipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(pc), &pc);
        }

        // 6. Draw Fullscreen Composite Triangle
        if (ctx.dispatch.CmdDraw) {
            ctx.dispatch.CmdDraw(cmd, 3, 1, 0, 0);
        }

        // 7. End RenderPass
        if (ctx.dispatch.CmdEndRenderPass) {
            ctx.dispatch.CmdEndRenderPass(cmd);
        }

        // 8. Transition swapchain image: COLOR_ATTACHMENT_OPTIMAL -> PRESENT_SRC_KHR
        barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
        barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        if (ctx.dispatch.CmdPipelineBarrier) {
            ctx.dispatch.CmdPipelineBarrier(
                cmd,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                0, 0, nullptr, 0, nullptr, 1, &barrier);
        }

        if (ctx.dispatch.EndCommandBuffer) {
            ctx.dispatch.EndCommandBuffer(cmd);
        }

        // 9. Submit Post-Processing Command Buffer to Presentation Queue
        if (ctx.dispatch.QueueSubmit) {
            VkSubmitInfo submitInfo{};
            submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submitInfo.commandBufferCount = 1;
            submitInfo.pCommandBuffers = &cmd;
            ctx.dispatch.QueueSubmit(queue, 1, &submitInfo, VK_NULL_HANDLE);
        }
        if (ctx.dispatch.QueueWaitIdle) {
            ctx.dispatch.QueueWaitIdle(queue);
        }
    }

    if (s_frameCounter % 120 == 1) {
        LOGI("FXVulkanRuntime: Post-processing active | Frame #%llu | Preset '%s' (exp=%.2f, con=%.2f, ao=%.2f)",
             static_cast<unsigned long long>(s_frameCounter),
             m_config.activePreset.c_str(),
             m_config.exposure,
             m_config.contrast,
             m_config.aoStrength);
    }

    return origPresent(queue, pPresentInfo);
}

} // namespace roshade
