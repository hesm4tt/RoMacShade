//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan 3D Depth Interceptor & Capture Engine.
//

#pragma once

#include "../include/vulkan/vulkan.h"
#include <mutex>
#include <unordered_map>
#include <vector>

namespace roshade {

struct DepthCaptureConfig {
    bool enabled = true;
    bool reversedDepth = true;  // Roblox on modern engines uses reversed float depth (1.0 near, 0.0 far)
    bool downsampleHalf = true; // 50% resolution scaling for mobile thermal efficiency
};

struct CapturedDepthBuffer {
    VkImage image = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkFormat format = VK_FORMAT_UNDEFINED;
    uint32_t width = 0;
    uint32_t height = 0;
    VkImageLayout currentLayout = VK_IMAGE_LAYOUT_UNDEFINED;
};

class DepthCaptureManager {
public:
    static DepthCaptureManager &instance();

    void setConfig(const DepthCaptureConfig &config);
    const DepthCaptureConfig &config() const { return m_config; }

    // Intercepts and patches render pass creation to preserve depth from TBDR on-chip tile memory
    void patchRenderPassCreateInfo(VkRenderPassCreateInfo *pCreateInfo);
    void patchRenderPassCreateInfo2(VkRenderPassCreateInfo2 *pCreateInfo);

    // Tracks framebuffers and image attachments
    void registerImageView(VkImageView view, VkImage image, VkFormat format);
    void unregisterImageView(VkImageView view);
    void registerFramebuffer(VkFramebuffer framebuffer, const VkFramebufferCreateInfo *pCreateInfo);
    void unregisterFramebuffer(VkFramebuffer framebuffer);

    // Command buffer recording
    void onCmdBeginRenderPass(VkCommandBuffer cmd, const VkRenderPassBeginInfo *pRenderPassBegin);
    void onCmdEndRenderPass(VkCommandBuffer cmd);

    // Retrieves current scene depth for presentation shader passes
    CapturedDepthBuffer getActiveDepth(VkDevice device);
    void resetFrame(VkDevice device);

private:
    DepthCaptureManager() = default;

    DepthCaptureConfig m_config;
    std::mutex m_mutex;

    struct ImageViewRecord {
        VkImage image = VK_NULL_HANDLE;
        VkFormat format = VK_FORMAT_UNDEFINED;
    };
    std::unordered_map<VkImageView, ImageViewRecord> m_views;

    struct FramebufferRecord {
        uint32_t width = 0;
        uint32_t height = 0;
        std::vector<VkImageView> attachments;
    };
    std::unordered_map<VkFramebuffer, FramebufferRecord> m_framebuffers;

    std::unordered_map<VkDevice, CapturedDepthBuffer> m_activeDepth;
};

bool isDepthFormat(VkFormat format);

} // namespace roshade
