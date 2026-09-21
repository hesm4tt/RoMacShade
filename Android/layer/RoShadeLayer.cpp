//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Android Vulkan Interceptor Layer Entry Points and Dispatch Table.
//

#include "RoShadeLayer.h"
#include "DepthCapture.h"
#include "FXVulkanRuntime.h"
#include "Log.h"
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace {

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

template <typename T>
void *GetKey(T handle) {
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
    }
    LOGI("VK_LAYER_RoShade: Intercepted vkCreateInstance for instance %p", static_cast<void *>(*pInstance));
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

    PFN_vkCreateDevice createDevice = reinterpret_cast<PFN_vkCreateDevice>(nextGIPA(VK_NULL_HANDLE, "vkCreateDevice"));
    if (!createDevice) return VK_ERROR_INITIALIZATION_FAILED;

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
    }

    LOGI("VK_LAYER_RoShade: Intercepted vkCreateDevice for device %p, initializing FX runtime", static_cast<void *>(*pDevice));
    roshade::FXVulkanRuntime::instance().initDevice(*pDevice, physicalDevice, nextGDPA);
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
    }

    VkRenderPassCreateInfo patched = *pCreateInfo;
    roshade::DepthCaptureManager::instance().patchRenderPassCreateInfo(&patched);
    return dispatch.CreateRenderPass(device, &patched, pAllocator, pRenderPass);
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
        dispatch = g_deviceDispatch[key];
    }

    VkRenderPassCreateInfo2 patched = *pCreateInfo;
    roshade::DepthCaptureManager::instance().patchRenderPassCreateInfo2(&patched);
    return dispatch.CreateRenderPass2(device, &patched, pAllocator, pRenderPass);
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
    }

    roshade::DepthCaptureManager::instance().onCmdBeginRenderPass(commandBuffer, pRenderPassBegin);
    dispatch.CmdBeginRenderPass(commandBuffer, pRenderPassBegin, contents);
}

VKAPI_ATTR void VKAPI_CALL RoShade_CmdEndRenderPass(VkCommandBuffer commandBuffer) {
    auto key = GetKey(commandBuffer);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        dispatch = g_deviceDispatch[key];
    }

    roshade::DepthCaptureManager::instance().onCmdEndRenderPass(commandBuffer);
    dispatch.CmdEndRenderPass(commandBuffer);
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
        dispatch = g_deviceDispatch[key];
    }

    VkResult res = dispatch.CreateSwapchainKHR(device, pCreateInfo, pAllocator, pSwapchain);
    if (res == VK_SUCCESS && pSwapchain && pCreateInfo) {
        uint32_t count = 0;
        dispatch.GetSwapchainImagesKHR(device, *pSwapchain, &count, nullptr);
        std::vector<VkImage> images(count);
        dispatch.GetSwapchainImagesKHR(device, *pSwapchain, &count, images.data());

        roshade::FXVulkanRuntime::instance().registerSwapchain(
            *pSwapchain, pCreateInfo->imageFormat, pCreateInfo->imageExtent.width, pCreateInfo->imageExtent.height, images);
        LOGI("VK_LAYER_RoShade: Intercepted vkCreateSwapchainKHR %ux%u format=%d images=%u",
             pCreateInfo->imageExtent.width, pCreateInfo->imageExtent.height, pCreateInfo->imageFormat, count);
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
        dispatch = g_deviceDispatch[key];
    }

    roshade::FXVulkanRuntime::instance().destroySwapchain(swapchain);
    dispatch.DestroySwapchainKHR(device, swapchain, pAllocator);
}

VKAPI_ATTR VkResult VKAPI_CALL RoShade_QueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR *pPresentInfo) {
    auto key = GetKey(queue);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        dispatch = g_deviceDispatch[key];
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
        dispatch = g_deviceDispatch[key];
        g_deviceDispatch.erase(key);
    }

    roshade::FXVulkanRuntime::instance().destroyDevice(device);
    if (dispatch.DestroyDevice) {
        dispatch.DestroyDevice(device, pAllocator);
    }
}

} // anonymous namespace

// -------------------------------------------------------------------------
// Khronos Layer Entry Points
// -------------------------------------------------------------------------

extern "C" {

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(
    VkNegotiateLayerInterface *pVersionStruct) {
    if (!pVersionStruct || pVersionStruct->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    if (pVersionStruct->loaderLayerInterfaceVersion >= 2) {
        pVersionStruct->pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
        pVersionStruct->pfnGetDeviceProcAddr = vkGetDeviceProcAddr;
        pVersionStruct->pfnGetPhysicalDeviceProcAddr = nullptr;
    }
    return VK_SUCCESS;
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(
    VkInstance instance,
    const char *pName) {
    if (!pName) return nullptr;

    if (strcmp(pName, "vkGetInstanceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetInstanceProcAddr);
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetDeviceProcAddr);
    if (strcmp(pName, "vkCreateInstance") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateInstance);
    if (strcmp(pName, "vkDestroyInstance") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyInstance);
    if (strcmp(pName, "vkCreateDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_CreateDevice);
    if (strcmp(pName, "vkDestroyDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(RoShade_DestroyDevice);

    // Route known device interceptors queried at instance level
    PFN_vkVoidFunction devProc = vkGetDeviceProcAddr(VK_NULL_HANDLE, pName);
    if (devProc) return devProc;

    if (instance == VK_NULL_HANDLE) return nullptr;
    auto key = GetKey(instance);
    InstanceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        dispatch = g_instanceDispatch[key];
    }
    if (dispatch.gpa) {
        return dispatch.gpa(instance, pName);
    }
    return nullptr;
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(
    VkDevice device,
    const char *pName) {
    if (!pName) return nullptr;

    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(vkGetDeviceProcAddr);
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

    if (device == VK_NULL_HANDLE) return nullptr;
    auto key = GetKey(device);
    DeviceDispatch dispatch;
    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        dispatch = g_deviceDispatch[key];
    }
    if (dispatch.gdpa) {
        return dispatch.gdpa(device, pName);
    }
    return nullptr;
}

} // extern "C"
