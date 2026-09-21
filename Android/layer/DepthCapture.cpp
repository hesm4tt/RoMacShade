//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan 3D Depth Interceptor & Capture Engine.
//

#include "DepthCapture.h"
#include "Log.h"

namespace roshade {

bool isDepthFormat(VkFormat format) {
    switch (format) {
        case VK_FORMAT_D16_UNORM:
        case VK_FORMAT_X8_D24_UNORM_PACK32:
        case VK_FORMAT_D32_SFLOAT:
        case VK_FORMAT_D16_UNORM_S8_UINT:
        case VK_FORMAT_D24_UNORM_S8_UINT:
        case VK_FORMAT_D32_SFLOAT_S8_UINT:
            return true;
        default:
            return false;
    }
}

DepthCaptureManager &DepthCaptureManager::instance() {
    static DepthCaptureManager mgr;
    return mgr;
}

void DepthCaptureManager::setConfig(const DepthCaptureConfig &config) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_config = config;
}

void DepthCaptureManager::patchRenderPassCreateInfo(VkRenderPassCreateInfo *pCreateInfo) {
    if (!pCreateInfo || !m_config.enabled) return;

    for (uint32_t i = 0; i < pCreateInfo->attachmentCount; ++i) {
        VkAttachmentDescription &att = const_cast<VkAttachmentDescription &>(pCreateInfo->pAttachments[i]);
        if (isDepthFormat(att.format)) {
            // Force mobile TBDR tile memory flush to system RAM
            if (att.storeOp == VK_ATTACHMENT_STORE_OP_DONT_CARE) {
                att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
                LOGI("DepthCapture: Patched VkRenderPass attachment %u (format %d) DONT_CARE -> STORE", i, att.format);
            }
        }
    }
}

void DepthCaptureManager::patchRenderPassCreateInfo2(VkRenderPassCreateInfo2 *pCreateInfo) {
    if (!pCreateInfo || !m_config.enabled) return;

    for (uint32_t i = 0; i < pCreateInfo->attachmentCount; ++i) {
        VkAttachmentDescription2 &att = const_cast<VkAttachmentDescription2 &>(pCreateInfo->pAttachments[i]);
        if (isDepthFormat(att.format)) {
            if (att.storeOp == VK_ATTACHMENT_STORE_OP_DONT_CARE) {
                att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
                LOGI("DepthCapture: Patched VkRenderPass2 attachment %u (format %d) DONT_CARE -> STORE", i, att.format);
            }
        }
    }
}

void DepthCaptureManager::registerImageView(VkImageView view, VkImage image, VkFormat format) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_views[view] = {image, format};
}

void DepthCaptureManager::unregisterImageView(VkImageView view) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_views.erase(view);
}

void DepthCaptureManager::registerFramebuffer(VkFramebuffer framebuffer, const VkFramebufferCreateInfo *pCreateInfo) {
    if (!pCreateInfo) return;
    std::lock_guard<std::mutex> lock(m_mutex);
    FramebufferRecord rec;
    rec.width = pCreateInfo->width;
    rec.height = pCreateInfo->height;
    if (pCreateInfo->pAttachments && pCreateInfo->attachmentCount > 0) {
        rec.attachments.assign(pCreateInfo->pAttachments, pCreateInfo->pAttachments + pCreateInfo->attachmentCount);
    }
    m_framebuffers[framebuffer] = rec;
}

void DepthCaptureManager::unregisterFramebuffer(VkFramebuffer framebuffer) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_framebuffers.erase(framebuffer);
}

void DepthCaptureManager::onCmdBeginRenderPass(VkCommandBuffer cmd, const VkRenderPassBeginInfo *pRenderPassBegin) {
    if (!pRenderPassBegin || !m_config.enabled) return;
    (void)cmd;

    std::lock_guard<std::mutex> lock(m_mutex);
    auto fbIt = m_framebuffers.find(pRenderPassBegin->framebuffer);
    if (fbIt == m_framebuffers.end()) return;

    const auto &fb = fbIt->second;
    for (VkImageView view : fb.attachments) {
        auto vIt = m_views.find(view);
        if (vIt != m_views.end() && isDepthFormat(vIt->second.format)) {
            // Candidate 3D depth attachment discovered
            CapturedDepthBuffer candidate;
            candidate.image = vIt->second.image;
            candidate.view = view;
            candidate.format = vIt->second.format;
            candidate.width = fb.width;
            candidate.height = fb.height;
            candidate.currentLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            // Associate with active device
            m_activeDepth[VK_NULL_HANDLE] = candidate;
            LOGI("DepthCapture: Bound active 3D depth buffer %ux%u format=%d view=%p",
                 candidate.width, candidate.height, candidate.format, static_cast<void *>(candidate.view));
            break;
        }
    }
}

void DepthCaptureManager::onCmdEndRenderPass(VkCommandBuffer cmd) {
    (void)cmd;
}

CapturedDepthBuffer DepthCaptureManager::getActiveDepth(VkDevice device) {
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_activeDepth.find(device);
    if (it != m_activeDepth.end() && it->second.image != VK_NULL_HANDLE) {
        return it->second;
    }
    // Fall back to default
    auto defIt = m_activeDepth.find(VK_NULL_HANDLE);
    if (defIt != m_activeDepth.end()) {
        return defIt->second;
    }
    return {};
}

void DepthCaptureManager::resetFrame(VkDevice device) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_activeDepth.erase(device);
    m_activeDepth.erase(VK_NULL_HANDLE);
}

} // namespace roshade
