//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan ReShadeFX Runtime & Presentation Post-Processor.
//

#pragma once

#include "../include/vulkan/vulkan.h"
#include "DepthCapture.h"
#include <string>
#include <vector>
#include <unordered_map>
#include <memory>
#include <mutex>

namespace roshade {

struct FXVulkanConfig {
    bool enabled = true;
    float qualityScale = 0.75f; // Default 75% for balanced mobile performance
    bool enableSSR = false;     // Disabled by default on mobile for thermal safety
    bool enableAO = true;       // Ambient Occlusion
    bool enableBloom = true;
    bool enableColorGrading = true;
    std::string activePreset = "Vibrant Mobile";
};

class FXVulkanRuntime {
public:
    static FXVulkanRuntime &instance();

    void setConfig(const FXVulkanConfig &config);
    const FXVulkanConfig &config() const { return m_config; }

    // Initialization per Vulkan device
    VkResult initDevice(VkDevice device, VkPhysicalDevice physicalDevice, PFN_vkGetDeviceProcAddr gdpa);
    void destroyDevice(VkDevice device);

    // Swapchain tracking
    void registerSwapchain(VkSwapchainKHR swapchain, VkFormat format, uint32_t width, uint32_t height, const std::vector<VkImage> &images);
    void destroySwapchain(VkSwapchainKHR swapchain);

    // Presentation hook: processes swapchain image right before display submission
    VkResult onQueuePresent(VkQueue queue, const VkPresentInfoKHR *pPresentInfo, PFN_vkQueuePresentKHR origPresent);

private:
    FXVulkanRuntime() = default;

    VkResult buildPipelineForDevice(VkDevice device, VkFormat targetFormat);
    void recordPostProcessing(VkCommandBuffer cmd, VkImage swapchainImage, CapturedDepthBuffer depth, uint32_t width, uint32_t height);

    FXVulkanConfig m_config;
    std::mutex m_mutex;

    struct DeviceDispatchTable {
        PFN_vkGetDeviceProcAddr gdpa = nullptr;
        PFN_vkCreateSampler CreateSampler = nullptr;
        PFN_vkDestroySampler DestroySampler = nullptr;
        PFN_vkCreateDescriptorSetLayout CreateDescriptorSetLayout = nullptr;
        PFN_vkDestroyDescriptorSetLayout DestroyDescriptorSetLayout = nullptr;
        PFN_vkCreatePipelineLayout CreatePipelineLayout = nullptr;
        PFN_vkDestroyPipelineLayout DestroyPipelineLayout = nullptr;
        PFN_vkCreateGraphicsPipelines CreateGraphicsPipelines = nullptr;
        PFN_vkDestroyPipeline DestroyPipeline = nullptr;
        PFN_vkCreateShaderModule CreateShaderModule = nullptr;
        PFN_vkDestroyShaderModule DestroyShaderModule = nullptr;
        PFN_vkCreateCommandPool CreateCommandPool = nullptr;
        PFN_vkDestroyCommandPool DestroyCommandPool = nullptr;
        PFN_vkAllocateCommandBuffers AllocateCommandBuffers = nullptr;
        PFN_vkFreeCommandBuffers FreeCommandBuffers = nullptr;
        PFN_vkBeginCommandBuffer BeginCommandBuffer = nullptr;
        PFN_vkEndCommandBuffer EndCommandBuffer = nullptr;
        PFN_vkCmdBeginRenderPass CmdBeginRenderPass = nullptr;
        PFN_vkCmdEndRenderPass CmdEndRenderPass = nullptr;
        PFN_vkCmdBindPipeline CmdBindPipeline = nullptr;
        PFN_vkCmdBindDescriptorSets CmdBindDescriptorSets = nullptr;
        PFN_vkCmdPushConstants CmdPushConstants = nullptr;
        PFN_vkCmdDraw CmdDraw = nullptr;
        PFN_vkQueueSubmit QueueSubmit = nullptr;
        PFN_vkQueueWaitIdle QueueWaitIdle = nullptr;
    };

    struct DeviceContext {
        VkDevice device = VK_NULL_HANDLE;
        VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
        DeviceDispatchTable dispatch;
        VkCommandPool commandPool = VK_NULL_HANDLE;
        VkSampler colorSampler = VK_NULL_HANDLE;
        VkSampler depthSampler = VK_NULL_HANDLE;
        VkDescriptorSetLayout descLayout = VK_NULL_HANDLE;
        VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
        VkPipeline graphicsPipeline = VK_NULL_HANDLE;
        VkShaderModule vsModule = VK_NULL_HANDLE;
        VkShaderModule fsModule = VK_NULL_HANDLE;
        bool initialized = false;
    };
    std::unordered_map<VkDevice, DeviceContext> m_devices;

    struct SwapchainContext {
        VkFormat format = VK_FORMAT_UNDEFINED;
        uint32_t width = 0;
        uint32_t height = 0;
        std::vector<VkImage> images;
        std::vector<VkImageView> views;
    };
    std::unordered_map<VkSwapchainKHR, SwapchainContext> m_swapchains;
};

} // namespace roshade
