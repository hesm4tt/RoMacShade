# RoAndroidShade (VK_LAYER_RoShade)
### Native Android Vulkan ReShadeFX & 3D Depth Runtime for Roblox

**RoAndroidShade** brings the post-processing and 3D depth-buffer shader capabilities of **RoMacShade** to Android devices running the official Roblox mobile client.

---

## 🌟 Key Highlights

- **🛡️ 100% Safe (No APK Tampering / No Ban Risk)**:
  Does **not** decompile, modify, patch, or repack the Roblox APK. This completely bypasses Roblox's client signature verification and tamper checks (*"Security Threat Detected"*).
- **🔓 No Root / Magisk Required**:
  Utilizes the official Android 10+ Vulkan GPU Debug Layer subsystem (`enable_gpu_debug_layers`), which allows user-space graphics validation and interceptor layers to be attached over ADB.
- **👁️ Full 3D Depth Buffer Capture**:
  Android mobile GPUs (Adreno, Mali, Immortalis) utilize Tile-Based Deferred Rendering (TBDR), which normally discards depth after each tile pass (`VK_ATTACHMENT_STORE_OP_DONT_CARE`). RoAndroidShade intercepts Vulkan render passes on the fly and converts them to `STORE_OP_STORE`, safely preserving full 3D scene depth in memory for screen-space reflections (SSR), ambient occlusion (AO), and depth of field (DoF).
- **⚡ High-Performance SPIR-V Execution**:
  Compiles ReShadeFX shaders directly to native SPIR-V bytecode using the vendored ReShadeFX compiler, rendering at native refresh rates (60Hz / 90Hz / 120Hz).

---

## 📋 Requirements

1. **Android Device**: Android 10 (API 29) or higher with Vulkan 1.1+ support.
2. **Roblox Client**: Official Roblox app installed from the Google Play Store.
3. **Computer**: Mac, Linux, or Windows with `adb` installed.
   - On macOS: `brew install android-platform-tools`
4. **Build Tools (Optional, only if building from source)**:
   - Android NDK r25+ (`brew install --cask android-ndk` or via Android Studio).
   - CMake 3.10+.

---

## 🚀 Quick Setup & Installation

### Step 1: Enable USB Debugging on Your Android Phone
1. Open **Settings** -> **About Phone**.
2. Tap **Build Number** 7 times until you see *"You are now a developer!"*.
3. Go to **Settings** -> **System** -> **Developer Options**.
4. Turn on **USB Debugging**.
5. Connect your phone to your computer via USB and accept the *"Allow USB debugging"* prompt on your phone.

### Step 2: Build the Layer (or use pre-built binaries)
From the `Android/` directory:
```bash
./scripts/build_android.sh
```
*This compiles `libVkLayer_RoShade.so` targeting `arm64-v8a` and places the binaries in `Android/dist/`.*

### Step 3: Install & Activate Layer Over ADB
Run the automated installer script:
```bash
./scripts/install_layer.sh
```
The script will:
1. Verify device connection.
2. Push `libVkLayer_RoShade.so` and `VkLayer_RoShade.json` to the device.
3. Configure Android's GPU debug layers specifically for `com.roblox.client`:
   ```bash
   adb shell settings put global enable_gpu_debug_layers 1
   adb shell settings put global gpu_debug_app com.roblox.client
   adb shell settings put global gpu_debug_layers VK_LAYER_RoShade
   ```

### Step 4: Play Roblox!
Launch Roblox on your phone. The layer will initialize automatically whenever Roblox begins rendering with Vulkan.

---

## 🔍 Diagnostics & Live Logs

You can watch real-time layer activity, depth attachment capture, and swapchain events using:
```bash
adb logcat -s RoShade
```

You should see log output similar to:
```text
I RoShade : VK_LAYER_RoShade: Intercepted vkCreateInstance
I RoShade : VK_LAYER_RoShade: Intercepted vkCreateDevice, initializing FX runtime
I RoShade : DepthCapture: Patched VkRenderPass attachment 1 (format 126) DONT_CARE -> STORE
I RoShade : DepthCapture: Bound active 3D depth buffer 2400x1080 format=126
I RoShade : VK_LAYER_RoShade: Intercepted vkCreateSwapchainKHR 2400x1080 format=44 images=3
```

---

## 🛑 How to Deactivate / Reset

To disable RoAndroidShade and restore Roblox to its vanilla, unmodified rendering pipeline:
```bash
./scripts/uninstall_layer.sh
```
Or manually reset the global settings:
```bash
adb shell settings delete global enable_gpu_debug_layers
adb shell settings delete global gpu_debug_app
adb shell settings delete global gpu_debug_layers
adb shell settings delete global gpu_debug_layer_app
```

---

## ⚙️ Architecture & Technical Details

```
              ┌──────────────────────────────────────────────┐
              │          Roblox Android Client               │
              │            (com.roblox.client)               │
              └──────────────────────┬───────────────────────┘
                                     │ Vulkan API calls
                                     ▼
        ┌────────────────────────────────────────────────────────────┐
        │                 VK_LAYER_RoShade Layer                     │
        │  ┌──────────────────────────────────────────────────────┐  │
        │  │ DepthCaptureManager:                                 │  │
        │  │ Patches VkRenderPass (DONT_CARE -> STORE)            │  │
        │  │ Captures 3D Depth Attachment for SSR / AO / DoF      │  │
        │  └──────────────────────────────────────────────────────┘  │
        │  ┌──────────────────────────────────────────────────────┐  │
        │  │ FXVulkanRuntime:                                     │  │
        │  │ Compiles ReShadeFX shaders to native SPIR-V          │  │
        │  │ Intercepts vkQueuePresentKHR for full-screen post-fx │  │
        │  └──────────────────────────────────────────────────────┘  │
        └────────────────────────────┬───────────────────────────────┘
                                     │ Downstream Dispatch Table
                                     ▼
              ┌──────────────────────────────────────────────┐
              │      Android Vulkan Loader & GPU Driver      │
              │       (Qualcomm Adreno / ARM Mali / etc.)    │
              └──────────────────────────────────────────────┘
```

- **Render Pass Interception (`DepthCapture.cpp`)**:
  Identifies depth attachments (`VK_FORMAT_D16_UNORM`, `VK_FORMAT_D24_UNORM_S8_UINT`, `VK_FORMAT_D32_SFLOAT`, etc.) and forces `storeOp = VK_ATTACHMENT_STORE_OP_STORE`.
- **Dynamic Device Dispatch Table (`RoShadeLayer.cpp`)**:
  Provides strict isolation with zero external static symbol dependencies, preventing symbol collisions across diverse Android OEM Vulkan loaders.
- **Low Thermal Footprint**:
  Configured for mobile efficiency. Depth is downsampled to 50% resolution internally when calculating complex ray-marched reflections (SSR) and Ambient Occlusion, maximizing battery life and preserving frame rates.
