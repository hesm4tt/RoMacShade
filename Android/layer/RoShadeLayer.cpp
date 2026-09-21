//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan Interceptor Layer Entry Points and Dispatch Table.
//

#include "RoShadeLayer.h"
#include "DepthCapture.h"
#include "FXVulkanRuntime.h"
#include "Log.h"
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace {

// Process filtering: only intercept Roblox, act as transparent pass-through for others
bool IsTargetProcess() {
    static int s_isTarget = -1;
    if (s_isTarget != -1) return s_isTarget == 1;

    FILE *f = fopen("/proc/self/cmdline", "r");
    if (f) {
        char cmdline[256] = {0};
        size_t n = fread(cmdline, 1, sizeof(cmdline) - 1, f);
        fclose(f);
        if (n > 0) {
            if (strstr(cmdline, "com.roblox.client") != nullptr) {
                s_isTarget = 1;
                LOGI("VK_LAYER_RoShade: Activated for target process: %s", cmdline);
                return true;
            }
        }
    }
    s_isTarget = 0;
    return false;
}

// Dispatch table for downstream instance and device calls
struct InstanceDispatch {
    PFN_vkGetInstanceProcAddr gpa = nullptr;
    PFN_vkDestroyInstance DestroyInstance = nullptr;
};

struct DeviceDispatch {
    PFN_vkGetDeviceProcAddr gdpa = nullptr;
    PFN_vkDestroyDevice DestroyDevice = nullptr;
    PFN_vkGetDeviceQueue GetDeviceQueue = nullptr;
    PFN_vkGetDeviceQueue2 GetDeviceQueue2 = nullptr;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers = nullptr;
    PFN_vkFreeCommandBuffers FreeCommandBuffers = nullptr;
    PFN_vkCreateRenderPass CreateRenderPass = nullptr;
    PFN_vkCreateRenderPass2 CreateRenderPass2 = nullptr;
    PFN_vkCreateImageView CreateImageView = nullptr;
    PFN_vkDestroyImageView DestroyImageView = nullptr;
    PFN_vkCreateFramebuffer CreateFramebuffer = nullptr;
    PFN_vkDestroyFramebuffer DestroyFramebuffer = nullptr;
    PFN_vkCmdBeginRenderPass CmdBeginRenderPass = nullptr;
    PFN_vkCmdEndRenderPass CmdEndRenderPass = nullptr;
    PFN_vkCreateSwapchainKHR CreateSwapchainKHR = nullptr;
    PFN_vkDestroySwapchainKHR DestroySwapchainKHR = nullptr;
    PFN_vkGetSwapchainImagesKHR GetSwapchainImagesKHR = nullptr;
    PFN_vkQueuePresentKHR QueuePresentKHR = nullptr;
};

std::mutex g_dispatchMutex;
std::unordered_map<void *, InstanceDispatch> g_instanceDispatch;
std::unordered_map<void *, DeviceDispatch> g_deviceDispatch;
InstanceDispatch g_lastInstanceDispatch;
DeviceDispatch g_lastDeviceDispatch;
VkInstance g_lastInstance = VK_NULL_HANDLE;

template <typename T>
void *GetKey(T handle) {
    if (!handle) return nullptr;
    return *reinterpret_cast<void **>(handle);
}

// Forward declarations
VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateRenderPass(VkDevice, const VkRenderPassCreateInfo *, const VkAllocationCallbacks *, VkRenderPass *);
VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateRenderPass2(VkDevice, const VkRenderPassCreateInfo2 *, const VkAllocationCallbacks *, VkRenderPass *);
VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateImageView(VkDevice, const VkImageViewCreateInfo *, const VkAllocationCallbacks *, VkImageView *);
VKAPI_ATTR void VKAPI_CALL RoShade_DestroyImageView(VkDevice, VkImageView, const VkAllocationCallbacks *);
VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateFramebuffer(VkDevice, const VkFramebufferCreateInfo *, const VkAllocationCallbacks *, VkFramebuffer *);
VKAPI_ATTR void VKAPI_CALL RoShade_DestroyFramebuffer(VkDevice, VkFramebuffer, const VkAllocationCallbacks *);
VKAPI_ATTR void VKAPI_CALL RoShade_CmdBeginRenderPass(VkCommandBuffer, const VkRenderPassBeginInfo *, VkSubpassContents);
VKAPI_ATTR void VKAPI_CALL RoShade_CmdEndRenderPass(VkCommandBuffer);
VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateSwapchainKHR(VkDevice, const VkSwapchainCreateInfoKHR *, const VkAllocationCallbacks *, VkSwapchainKHR *);
VKAPI_ATTR void VKAPI_CALL RoShade_DestroySwapchainKHR(VkDevice, VkSwapchainKHR, const VkAllocationCallbacks *);
VKAPI_ATTR VkResult VKAPI_CALL RoShade_QueuePresentKHR(VkQueue, const VkPresentInfoKHR *);
VKAPI_ATTR void VKAPI_CALL RoShade_DestroyDevice(VkDevice, const VkAllocationCallbacks *);
VKAPI_ATTR void VKAPI_CALL RoShade_GetDeviceQueue(VkDevice, uint32_t, uint32_t, VkQueue *);
VKAPI_ATTR void VKAPI_CALL RoShade_GetDeviceQueue2(VkDevice, const VkDeviceQueueInfo2 *, VkQueue *);
VKAPI_ATTR VkResult VKAPI_CALL RoShade_AllocateCommandBuffers(VkDevice, const VkCommandBufferAllocateInfo *, VkCommandBuffer *);
VKAPI_ATTR void VKAPI_CALL RoShade_FreeCommandBuffers(VkDevice, VkCommandPool, uint32_t, const VkCommandBuffer *);

// Internal device proc lookup: never calls PLT or external symbols
PFN_vkVoidFunction RoShade_LookupDeviceProc(const char *pName) {
    if (!pName) return nullptr;
    if (strcmp(pName, "vkDestroyDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyDevice);
    if (strcmp(pName, "vkGetDeviceQueue") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_GetDeviceQueue);
    if (strcmp(pName, "vkGetDeviceQueue2") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_GetDeviceQueue2);
    if (strcmp(pName, "vkAllocateCommandBuffers") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_AllocateCommandBuffers);
    if (strcmp(pName, "vkFreeCommandBuffers") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_FreeCommandBuffers);
    if (strcmp(pName, "vkCreateRenderPass") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateRenderPass);
    if (strcmp(pName, "vkCreateRenderPass2") == 0 || strcmp(pName, "vkCreateRenderPass2KHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateRenderPass2);
    if (strcmp(pName, "vkCreateImageView") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateImageView);
    if (strcmp(pName, "vkDestroyImageView") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyImageView);
    if (strcmp(pName, "vkCreateFramebuffer") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateFramebuffer);
    if (strcmp(pName, "vkDestroyFramebuffer") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyFramebuffer);
    if (strcmp(pName, "vkCmdBeginRenderPass") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CmdBeginRenderPass);
    if (strcmp(pName, "vkCmdEndRenderPass") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CmdEndRenderPass);
    if (strcmp(pName, "vkCreateSwapchainKHR") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateSwapchainKHR);
    if (strcmp(pName, "vkDestroySwapchainKHR") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroySwapchainKHR);
    if (strcmp(pName, "vkQueuePresentKHR") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_QueuePresentKHR);
    return nullptr;
}

// -------------------------------------------------------------------------
// Instance Interceptors
// -------------------------------------------------------------------------

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateInstance(
    const VkInstanceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkInstance *pInstance) {
    if (!pCreateInfo || !pInstance) return VK_ERROR_INITIALIZATION_FAILED;

    VkLayerInstanceCreateInfo *chain_info = const_cast<VkLayerInstanceCreateInfo *>(
        reinterpret_cast<const VkLayerInstanceCreateInfo *>(pCreateInfo->pNext));

    while (chain_info && (chain_info->sType != VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO ||
                          chain_info->function != VK_LAYER_LINK_INFO)) {
        chain_info = const_cast<VkLayerInstanceCreateInfo *>(
            reinterpret_cast<const VkLayerInstanceCreateInfo *>(chain_info->pNext));
    }

    if (!chain_info || !chain_info->u.pLayerInfo) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    PFN_vkGetInstanceProcAddr nextGPA = chain_info->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    chain_info->u.pLayerInfo = chain_info->u.pLayerInfo->pNext;

    // Guard against self-reference cycle
    if (nextGPA == vkGetInstanceProcAddr || nextGPA == VK_LAYER_RoShadeGetInstanceProcAddr) {
        LOGW("VK_LAYER_RoShade: Self-reference in instance chain link, advancing");
        if (chain_info->u.pLayerInfo) {
            nextGPA = chain_info->u.pLayerInfo->pfnNextGetInstanceProcAddr;
            chain_info->u.pLayerInfo = chain_info->u.pLayerInfo->pNext;
        }
    }

    PFN_vkCreateInstance createInstance = reinterpret_cast<PFN_vkCreateInstance>(nextGPA(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!createInstance) return VK_ERROR_INITIALIZATION_FAILED;

    VkResult res = createInstance(pCreateInfo, pAllocator, pInstance);
    if (res != VK_SUCCESS) return res;

    auto key = GetKey(*pInstance);
    InstanceDispatch dispatch;
    dispatch.gpa = nextGPA;
    dispatch.DestroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(nextGPA(*pInstance, "vkDestroyInstance"));
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        g_instanceDispatch[key] = dispatch;
        g_lastInstanceDispatch = dispatch;
        if (IsTargetProcess()) {
            g_lastInstance = *pInstance;
        }
    }
    if (IsTargetProcess()) {
        LOGI("VK_LAYER_RoShade: Intercepted vkCreateInstance for instance %p", static_cast<void *>(*pInstance));
    }
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL RoShade_DestroyInstance(
    VkInstance instance,
    const VkAllocationCallbacks *pAllocator) {
    auto key = GetKey(instance);
    InstanceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_instanceDispatch.find(key);
        if (it != g_instanceDispatch.end()) {
            dispatch = it->second;
            g_instanceDispatch.erase(it);
        } else {
            dispatch = g_lastInstanceDispatch;
        }
        if (g_lastInstance == instance) {
            g_lastInstance = VK_NULL_HANDLE;
        }
    }
    if (dispatch.DestroyInstance) {
        dispatch.DestroyInstance(instance, pAllocator);
    }
}

// -------------------------------------------------------------------------
// Device Interceptors
// -------------------------------------------------------------------------

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateDevice(
    VkPhysicalDevice physicalDevice,
    const VkDeviceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkDevice *pDevice) {
    if (!pCreateInfo || !pDevice) return VK_ERROR_INITIALIZATION_FAILED;

    VkLayerDeviceCreateInfo *chain_info = const_cast<VkLayerDeviceCreateInfo *>(
        reinterpret_cast<const VkLayerDeviceCreateInfo *>(pCreateInfo->pNext));

    while (chain_info && (chain_info->sType != VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO ||
                          chain_info->function != VK_LAYER_LINK_INFO)) {
        chain_info = const_cast<VkLayerDeviceCreateInfo *>(
            reinterpret_cast<const VkLayerDeviceCreateInfo *>(chain_info->pNext));
    }

    if (!chain_info || !chain_info->u.pLayerInfo) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    PFN_vkGetInstanceProcAddr nextGIPA = chain_info->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr nextGDPA = chain_info->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    chain_info->u.pLayerInfo = chain_info->u.pLayerInfo->pNext;

    // Guard against self-reference cycle
    if (nextGDPA == vkGetDeviceProcAddr || nextGDPA == VK_LAYER_RoShadeGetDeviceProcAddr) {
        LOGW("VK_LAYER_RoShade: Self-reference in device chain link, advancing");
        if (chain_info->u.pLayerInfo) {
            nextGDPA = chain_info->u.pLayerInfo->pfnNextGetDeviceProcAddr;
            chain_info->u.pLayerInfo = chain_info->u.pLayerInfo->pNext;
        }
    }

    PFN_vkCreateDevice createDevice = nullptr;
    if (g_lastInstance != VK_NULL_HANDLE) {
        createDevice = reinterpret_cast<PFN_vkCreateDevice>(nextGIPA(g_lastInstance, "vkCreateDevice"));
    }
    if (!createDevice) {
        createDevice = reinterpret_cast<PFN_vkCreateDevice>(nextGIPA(VK_NULL_HANDLE, "vkCreateDevice"));
    }
    if (!createDevice) {
        LOGE("VK_LAYER_RoShade: failed to resolve downstream vkCreateDevice!");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkResult res = createDevice(physicalDevice, pCreateInfo, pAllocator, pDevice);
    if (res != VK_SUCCESS) return res;

    auto key = GetKey(*pDevice);
    DeviceDispatch dispatch;
    dispatch.gdpa = nextGDPA;
    dispatch.DestroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(nextGDPA(*pDevice, "vkDestroyDevice"));
    dispatch.GetDeviceQueue = reinterpret_cast<PFN_vkGetDeviceQueue>(nextGDPA(*pDevice, "vkGetDeviceQueue"));
    dispatch.GetDeviceQueue2 = reinterpret_cast<PFN_vkGetDeviceQueue2>(nextGDPA(*pDevice, "vkGetDeviceQueue2"));
    dispatch.AllocateCommandBuffers = reinterpret_cast<PFN_vkAllocateCommandBuffers>(nextGDPA(*pDevice, "vkAllocateCommandBuffers"));
    dispatch.FreeCommandBuffers = reinterpret_cast<PFN_vkFreeCommandBuffers>(nextGDPA(*pDevice, "vkFreeCommandBuffers"));
    dispatch.CreateRenderPass = reinterpret_cast<PFN_vkCreateRenderPass>(nextGDPA(*pDevice, "vkCreateRenderPass"));
    dispatch.CreateRenderPass2 = reinterpret_cast<PFN_vkCreateRenderPass2>(nextGDPA(*pDevice, "vkCreateRenderPass2"));
    if (!dispatch.CreateRenderPass2) {
        dispatch.CreateRenderPass2 = reinterpret_cast<PFN_vkCreateRenderPass2>(nextGDPA(*pDevice, "vkCreateRenderPass2KHR"));
    }
    dispatch.CreateImageView = reinterpret_cast<PFN_vkCreateImageView>(nextGDPA(*pDevice, "vkCreateImageView"));
    dispatch.DestroyImageView = reinterpret_cast<PFN_vkDestroyImageView>(nextGDPA(*pDevice, "vkDestroyImageView"));
    dispatch.CreateFramebuffer = reinterpret_cast<PFN_vkCreateFramebuffer>(nextGDPA(*pDevice, "vkCreateFramebuffer"));
    dispatch.DestroyFramebuffer = reinterpret_cast<PFN_vkDestroyFramebuffer>(nextGDPA(*pDevice, "vkDestroyFramebuffer"));
    dispatch.CmdBeginRenderPass = reinterpret_cast<PFN_vkCmdBeginRenderPass>(nextGDPA(*pDevice, "vkCmdBeginRenderPass"));
    dispatch.CmdEndRenderPass = reinterpret_cast<PFN_vkCmdEndRenderPass>(nextGDPA(*pDevice, "vkCmdEndRenderPass"));
    dispatch.CreateSwapchainKHR = reinterpret_cast<PFN_vkCreateSwapchainKHR>(nextGDPA(*pDevice, "vkCreateSwapchainKHR"));
    dispatch.DestroySwapchainKHR = reinterpret_cast<PFN_vkDestroySwapchainKHR>(nextGDPA(*pDevice, "vkDestroySwapchainKHR"));
    dispatch.GetSwapchainImagesKHR = reinterpret_cast<PFN_vkGetSwapchainImagesKHR>(nextGDPA(*pDevice, "vkGetSwapchainImagesKHR"));
    dispatch.QueuePresentKHR = reinterpret_cast<PFN_vkQueuePresentKHR>(nextGDPA(*pDevice, "vkQueuePresentKHR"));

    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        g_deviceDispatch[key] = dispatch;
        g_lastDeviceDispatch = dispatch;
    }

    if (IsTargetProcess()) {
        LOGI("VK_LAYER_RoShade: Intercepted vkCreateDevice for device %p, initializing FX runtime", static_cast<void *>(*pDevice));
        roshade::FXVulkanRuntime::instance().initDevice(*pDevice, physicalDevice, nextGDPA);
    }
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL RoShade_GetDeviceQueue(
    VkDevice device,
    uint32_t queueFamilyIndex,
    uint32_t queueIndex,
    VkQueue *pQueue) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }
    if (dispatch.GetDeviceQueue) {
        dispatch.GetDeviceQueue(device, queueFamilyIndex, queueIndex, pQueue);
        if (pQueue && *pQueue) {
            std::lock_guard<std::mutex> lock(g_dispatchMutex);
            g_deviceDispatch[GetKey(*pQueue)] = dispatch;
        }
    }
}

VKAPI_ATTR void VKAPI_CALL RoShade_GetDeviceQueue2(
    VkDevice device,
    const VkDeviceQueueInfo2 *pQueueInfo,
    VkQueue *pQueue) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }
    if (dispatch.GetDeviceQueue2) {
        dispatch.GetDeviceQueue2(device, pQueueInfo, pQueue);
        if (pQueue && *pQueue) {
            std::lock_guard<std::mutex> lock(g_dispatchMutex);
            g_deviceDispatch[GetKey(*pQueue)] = dispatch;
        }
    }
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_AllocateCommandBuffers(
    VkDevice device,
    const VkCommandBufferAllocateInfo *pAllocateInfo,
    VkCommandBuffer *pCommandBuffers) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }
    if (!dispatch.AllocateCommandBuffers) return VK_ERROR_INITIALIZATION_FAILED;

    VkResult res = dispatch.AllocateCommandBuffers(device, pAllocateInfo, pCommandBuffers);
    if (res == VK_SUCCESS && pCommandBuffers && pAllocateInfo) {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; ++i) {
            g_deviceDispatch[GetKey(pCommandBuffers[i])] = dispatch;
        }
    }
    return res;
}

VKAPI_ATTR void VKAPI_CALL RoShade_FreeCommandBuffers(
    VkDevice device,
    VkCommandPool commandPool,
    uint32_t commandBufferCount,
    const VkCommandBuffer *pCommandBuffers) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
        if (pCommandBuffers) {
            for (uint32_t i = 0; i < commandBufferCount; ++i) {
                g_deviceDispatch.erase(GetKey(pCommandBuffers[i]));
            }
        }
    }
    if (dispatch.FreeCommandBuffers) {
        dispatch.FreeCommandBuffers(device, commandPool, commandBufferCount, pCommandBuffers);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateRenderPass(
    VkDevice device,
    const VkRenderPassCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkRenderPass *pRenderPass) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    if (pCreateInfo) {
        roshade::DepthCaptureManager::instance().patchRenderPassCreateInfo(
            const_cast<VkRenderPassCreateInfo *>(pCreateInfo));
    }
    return dispatch.CreateRenderPass(device, pCreateInfo, pAllocator, pRenderPass);
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateRenderPass2(
    VkDevice device,
    const VkRenderPassCreateInfo2 *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkRenderPass *pRenderPass) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    if (pCreateInfo) {
        roshade::DepthCaptureManager::instance().patchRenderPassCreateInfo2(
            const_cast<VkRenderPassCreateInfo2 *>(pCreateInfo));
    }
    return dispatch.CreateRenderPass2(device, pCreateInfo, pAllocator, pRenderPass);
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateImageView(
    VkDevice device,
    const VkImageViewCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkImageView *pView) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    VkResult res = dispatch.CreateImageView(device, pCreateInfo, pAllocator, pView);
    if (res == VK_SUCCESS && pView && pCreateInfo) {
        roshade::DepthCaptureManager::instance().registerImageView(*pView, pCreateInfo->image, pCreateInfo->format);
    }
    return res;
}

VKAPI_ATTR void VKAPI_CALL RoShade_DestroyImageView(
    VkDevice device,
    VkImageView imageView,
    const VkAllocationCallbacks *pAllocator) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    roshade::DepthCaptureManager::instance().unregisterImageView(imageView);
    dispatch.DestroyImageView(device, imageView, pAllocator);
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateFramebuffer(
    VkDevice device,
    const VkFramebufferCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkFramebuffer *pFramebuffer) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    VkResult res = dispatch.CreateFramebuffer(device, pCreateInfo, pAllocator, pFramebuffer);
    if (res == VK_SUCCESS && pFramebuffer && pCreateInfo) {
        roshade::DepthCaptureManager::instance().registerFramebuffer(*pFramebuffer, pCreateInfo);
    }
    return res;
}

VKAPI_ATTR void VKAPI_CALL RoShade_DestroyFramebuffer(
    VkDevice device,
    VkFramebuffer framebuffer,
    const VkAllocationCallbacks *pAllocator) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    roshade::DepthCaptureManager::instance().unregisterFramebuffer(framebuffer);
    dispatch.DestroyFramebuffer(device, framebuffer, pAllocator);
}

VKAPI_ATTR void VKAPI_CALL RoShade_CmdBeginRenderPass(
    VkCommandBuffer commandBuffer,
    const VkRenderPassBeginInfo *pRenderPassBegin,
    VkSubpassContents contents) {
    auto key = GetKey(commandBuffer);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    roshade::DepthCaptureManager::instance().onCmdBeginRenderPass(commandBuffer, pRenderPassBegin);
    if (dispatch.CmdBeginRenderPass) {
        dispatch.CmdBeginRenderPass(commandBuffer, pRenderPassBegin, contents);
    }
}

VKAPI_ATTR void VKAPI_CALL RoShade_CmdEndRenderPass(VkCommandBuffer commandBuffer) {
    auto key = GetKey(commandBuffer);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    roshade::DepthCaptureManager::instance().onCmdEndRenderPass(commandBuffer);
    if (dispatch.CmdEndRenderPass) {
        dispatch.CmdEndRenderPass(commandBuffer);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_CreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkSwapchainKHR *pSwapchain) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    if (!dispatch.CreateSwapchainKHR) {
        LOGE("VK_LAYER_RoShade: dispatch.CreateSwapchainKHR is null!");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    VkResult res = dispatch.CreateSwapchainKHR(device, pCreateInfo, pAllocator, pSwapchain);
    if (res == VK_SUCCESS && pSwapchain && pCreateInfo) {
        uint32_t count = 0;
        if (dispatch.GetSwapchainImagesKHR) {
            dispatch.GetSwapchainImagesKHR(device, *pSwapchain, &count, nullptr);
            std::vector<VkImage> images(count);
            dispatch.GetSwapchainImagesKHR(device, *pSwapchain, &count, images.data());

            roshade::FXVulkanRuntime::instance().registerSwapchain(
                device, *pSwapchain, pCreateInfo->imageFormat, pCreateInfo->imageExtent.width, pCreateInfo->imageExtent.height, images);
            LOGI("VK_LAYER_RoShade: Intercepted vkCreateSwapchainKHR %ux%u format=%d images=%u",
                 pCreateInfo->imageExtent.width, pCreateInfo->imageExtent.height, pCreateInfo->imageFormat, count);
        }
    }
    return res;
}

VKAPI_ATTR void VKAPI_CALL RoShade_DestroySwapchainKHR(
    VkDevice device,
    VkSwapchainKHR swapchain,
    const VkAllocationCallbacks *pAllocator) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    roshade::FXVulkanRuntime::instance().destroySwapchain(swapchain);
    if (dispatch.DestroySwapchainKHR) {
        dispatch.DestroySwapchainKHR(device, swapchain, pAllocator);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_QueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo) {
    auto key = GetKey(queue);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    return roshade::FXVulkanRuntime::instance().onQueuePresent(queue, pPresentInfo, dispatch.QueuePresentKHR);
}

VKAPI_ATTR void VKAPI_CALL RoShade_DestroyDevice(
    VkDevice device,
    const VkAllocationCallbacks *pAllocator) {
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        if (it != g_deviceDispatch.end()) {
            dispatch = it->second;
            g_deviceDispatch.erase(it);
        } else {
            dispatch = g_lastDeviceDispatch;
        }
    }

    roshade::FXVulkanRuntime::instance().destroyDevice(device);
    if (dispatch.DestroyDevice) {
        dispatch.DestroyDevice(device, pAllocator);
    }
}

} // anonymous namespace

// -------------------------------------------------------------------------
// Khronos & Android Layer Entry Points
// -------------------------------------------------------------------------

extern "C" {

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(
    VkNegotiateLayerInterface *pVersionStruct) {
    if (!pVersionStruct || pVersionStruct->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    LOGI("VK_LAYER_RoShade: vkNegotiateLoaderLayerInterfaceVersion requested version=%u",
         pVersionStruct->loaderLayerInterfaceVersion);
    pVersionStruct->pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    pVersionStruct->pfnGetDeviceProcAddr = vkGetDeviceProcAddr;
    pVersionStruct->pfnGetPhysicalDeviceProcAddr = nullptr;
    pVersionStruct->loaderLayerInterfaceVersion = 2;
    return VK_SUCCESS;
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(
    VkInstance instance,
    const char *pName) {
    if (!pName) return nullptr;

    // 1. Layer interface & dispatcher queries
    if (strcmp(pName, "vkGetInstanceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetInstanceProcAddr);
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetDeviceProcAddr);
    if (strcmp(pName, "VK_LAYER_RoShadeGetInstanceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetInstanceProcAddr);
    if (strcmp(pName, "VK_LAYER_RoShadeGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetDeviceProcAddr);

    // 2. Pre-instance enumeration commands (valid when instance == VK_NULL_HANDLE)
    if (strcmp(pName, "vkEnumerateInstanceVersion") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkEnumerateInstanceVersion);
    if (strcmp(pName, "vkEnumerateInstanceLayerProperties") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkEnumerateInstanceLayerProperties);
    if (strcmp(pName, "vkEnumerateInstanceExtensionProperties") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkEnumerateInstanceExtensionProperties);

    // 3. Instance creation
    if (strcmp(pName, "vkCreateInstance") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateInstance);

    // All functions below require a valid VkInstance
    if (instance == VK_NULL_HANDLE) return nullptr;

    if (strcmp(pName, "vkDestroyInstance") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyInstance);
    if (strcmp(pName, "vkCreateDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateDevice);
    if (strcmp(pName, "vkDestroyDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyDevice);

    // 4. Device interceptors (internal lookup, only for target process)
    if (IsTargetProcess()) {
        PFN_vkVoidFunction devProc = RoShade_LookupDeviceProc(pName);
        if (devProc) return devProc;
    }

    // 5. Forward everything else (including vkEnumerateDeviceExtensionProperties,
    //    vkEnumeratePhysicalDevices, etc.) to downstream loader/driver
    auto key = GetKey(instance);
    InstanceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_instanceDispatch.find(key);
        dispatch = (it != g_instanceDispatch.end()) ? it->second : g_lastInstanceDispatch;
    }

    // Call downstream GPA while preventing self-reference recursion
    if (dispatch.gpa && dispatch.gpa != vkGetInstanceProcAddr && dispatch.gpa != VK_LAYER_RoShadeGetInstanceProcAddr) {
        return dispatch.gpa(instance, pName);
    }
    return nullptr;
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(
    VkDevice device,
    const char *pName) {
    if (!pName) return nullptr;

    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetDeviceProcAddr);
    if (strcmp(pName, "VK_LAYER_RoShadeGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetDeviceProcAddr);

    // Check intercepted device procs directly (only for target process)
    if (IsTargetProcess()) {
        PFN_vkVoidFunction devProc = RoShade_LookupDeviceProc(pName);
        if (devProc) return devProc;
    }

    if (device == VK_NULL_HANDLE) return nullptr;

    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_deviceDispatch.find(key);
        dispatch = (it != g_deviceDispatch.end()) ? it->second : g_lastDeviceDispatch;
    }

    // Call downstream GDPA while preventing self-reference recursion
    if (dispatch.gdpa && dispatch.gdpa != vkGetDeviceProcAddr && dispatch.gdpa != VK_LAYER_RoShadeGetDeviceProcAddr) {
        return dispatch.gdpa(device, pName);
    }
    return nullptr;
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL VK_LAYER_RoShadeGetInstanceProcAddr(
    VkInstance instance,
    const char *pName) {
    return vkGetInstanceProcAddr(instance, pName);
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL VK_LAYER_RoShadeGetDeviceProcAddr(
    VkDevice device,
    const char *pName) {
    return vkGetDeviceProcAddr(device, pName);
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceVersion(
    uint32_t *pApiVersion) {
    if (pApiVersion) {
        *pApiVersion = VK_API_VERSION_1_2;
    }
    return VK_SUCCESS;
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(
    uint32_t *pPropertyCount,
    VkLayerProperties *pProperties) {
    if (pProperties == nullptr) {
        if (pPropertyCount) *pPropertyCount = 1;
        return VK_SUCCESS;
    }
    if (pPropertyCount == nullptr || *pPropertyCount < 1) {
        return VK_INCOMPLETE;
    }

    *pPropertyCount = 1;
    std::strncpy(pProperties[0].layerName, "VK_LAYER_RoShade", VK_MAX_EXTENSION_NAME_SIZE);
    pProperties[0].specVersion = VK_API_VERSION_1_2;
    pProperties[0].implementationVersion = 1;
    std::strncpy(pProperties[0].description, "RoAndroidShade ReShadeFX & 3D Depth Runtime", VK_MAX_DESCRIPTION_SIZE);
    return VK_SUCCESS;
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceLayerProperties(
    VkPhysicalDevice physicalDevice,
    uint32_t *pPropertyCount,
    VkLayerProperties *pProperties) {
    (void)physicalDevice;
    return vkEnumerateInstanceLayerProperties(pPropertyCount, pProperties);
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(
    const char *pLayerName,
    uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties) {
    if (pLayerName && strcmp(pLayerName, "VK_LAYER_RoShade") == 0) {
        if (pPropertyCount) *pPropertyCount = 0;
        return VK_SUCCESS;
    }

    // Pass-through to downstream loader if available
    InstanceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        dispatch = g_lastInstanceDispatch;
    }
    if (dispatch.gpa) {
        auto nextFunc = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
            dispatch.gpa(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties"));
        if (nextFunc && nextFunc != vkEnumerateInstanceExtensionProperties) {
            return nextFunc(pLayerName, pPropertyCount, pProperties);
        }
    }

    if (pPropertyCount) *pPropertyCount = 0;
    return VK_SUCCESS;
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(
    VkPhysicalDevice physicalDevice,
    const char *pLayerName,
    uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties) {
    if (pLayerName && strcmp(pLayerName, "VK_LAYER_RoShade") == 0) {
        if (pPropertyCount) *pPropertyCount = 0;
        return VK_SUCCESS;
    }

    // Pass-through to downstream loader / driver
    InstanceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        auto it = g_instanceDispatch.find(GetKey(physicalDevice));
        dispatch = (it != g_instanceDispatch.end()) ? it->second : g_lastInstanceDispatch;
    }
    if (dispatch.gpa) {
        auto nextFunc = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
            dispatch.gpa(VK_NULL_HANDLE, "vkEnumerateDeviceExtensionProperties"));
        if (!nextFunc && g_lastInstance != VK_NULL_HANDLE) {
            nextFunc = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
                dispatch.gpa(g_lastInstance, "vkEnumerateDeviceExtensionProperties"));
        }
        if (nextFunc && nextFunc != vkEnumerateDeviceExtensionProperties) {
            return nextFunc(physicalDevice, pLayerName, pPropertyCount, pProperties);
        }
    }

    if (pPropertyCount) *pPropertyCount = 0;
    return VK_SUCCESS;
}

} // extern "C"
