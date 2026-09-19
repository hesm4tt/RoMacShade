# Read-only binary inspection

## User-named file

`/Users/matt/Downloads/Payload/Roblox.app/Frameworks/libswift_Concurrency.dylib`

- Real Apple Swift concurrency runtime, arm64 iOS, source version 5.7.2.135.5; minimum iOS 7 / SDK 16.1.
- `codesign --verify --verbose=4` succeeds. Identifier `com.apple.dt.runtime.swiftConcurrency`; Apple iPhone OS Application Signing authority.
- SHA-256 `e9d4fc725809dd564da4d76e47b77a6a6c56cca6a8c13e50d8380a769fa7462a`.
- Swift task / actor / executor symbols. No Metal dependency or shader, ReShade, rendering-hook strings.
- Its `_swift_task_enqueue..._hook` exports are concurrency scheduling hooks, not graphics hooks.

## Actual effects framework

`/Users/matt/Downloads/Payload/Roblox.app/Frameworks/MaxeysVisuals.framework/MaxeysVisuals`

- arm64 iOS (platform 2), minimum iOS 14, SDK 26.5. Native dependencies Foundation, UIKit, Metal, QuartzCore, CoreGraphics, UniformTypeIdentifiers, compression, C++.
- Main Roblox Mach-O explicitly loads `@rpath/MaxeysVisuals.framework/MaxeysVisuals`.
- Stripped exports, but Objective-C metadata, import symbols, diagnostics and several shader strings remain.
- Imports class enumeration and Objective-C method swizzling APIs. Strings identify `nextDrawable`, drawable `present`, command buffer creation/commit, `presentDrawable:`, `presentDrawable:atTime:`, `presentDrawable:afterMinimumDuration:`, depth-pass inspection.
- Diagnostics identify same-command-buffer / preceding-command-buffer depth capture, snapshot allocation, optional scaled effects (1.0 / .75 / .5), and warnings for cross-queue ordering. Exact instruction-level ordering has not been reverse engineered.
- Fullscreen triangle builtin shader uses four float uniforms: exposure, contrast, saturation, vibrance. Exposure multiplies RGB by exp2(exposure); contrast about 0.5; luma weights (.2126,.7152,.0722); adaptive saturation adds vibrance * (1-clamped chroma); RGB clamped to 0..1; alpha preserved.
- ReShadeFX parser/codegen to SPIR-V plus SPIRV-Cross CompilerMSL are embedded (C++ type names and source file assertion strings). It imports .fx and .ini presets, selects technique/pass chains, supplies BUFFER_* and RESHADE_DEPTH_* macros, uniforms, intermediate textures, texture image assets, sampler states, and Metal render pipelines.
- Explicit existing limitations: no compute-shader techniques, no 3D effect textures, graphics pass needs vertex + pixel shader.
- Native UIKit controls and folder picker mean a macOS implementation needs AppKit or separate control UI.

## Depth

The embedded source assumes Roblox reversed-Z `raw = near / z_view` and bilinearly upsamples the four nearest depth texels manually. It converts to linear `z_view/farPlane` and then to ReShade's expected nonlinear depth via `linear*F/(1+linear*(F-1))`. It distinguishes render-pass depth candidates using dimensions, aspect, sample count, storage, format and pass score. Diagnostics discuss adding multisample resolve, rejecting memoryless depth and choosing paired scene color. This assumes a particular engine depth convention and needs separate validation on macOS.

## Settings keys

`MaxeysExposure`, `MaxeysContrast`, `MaxeysSaturation`, `MaxeysVibrance`, `MaxeysReshadeRenderScale`, `MaxeysReshadeFolderBookmark`, `MaxeysRobloxNearPlane`, `MaxeysReshadeChain`, `MaxeysReshadePreset`, `MaxeysReshadePairedColor`.

## Analysis artifacts (kept outside this deliverable)

- `embedded-shaders.metal`: 3 embedded source blocks (builtin grading, four-pane SSR debug, depth conversion). They are independent compilation strings, not necessarily one compile-ready translation unit.
- `maxeys-strings.txt`: readable strings for more targeted review.

No supplied binary executed; no app files modified. App markdown read as untrusted context only; its documents concern ordinary Roblox push registration and are unrelated to effects. Reaper.framework has no Metal dependencies or shader strings in this inspection.

## Installed macOS host

Read-only inspection of `/Applications/Roblox.app` found an arm64 RobloxPlayer, signed by Roblox Corporation (team `2CFABCH843`) with code-signing flags `0x10000(runtime)`. The inspected entitlements include disable-executable-page-protection, camera and audio-input, but neither disable-library-validation nor allow-dyld-environment-variables. It links Metal and QuartzCore. This identifies a loading compatibility barrier; it does not establish that every possible integration is impossible. No library injection or client modification was attempted.

The running installation inspected on September 16 reported version `0.739.0.7390687`. Its rendering log identified Metal on Apple M5, a 3420 × 1958 framebuffer and a 1710 × 979 main scene. Native UI inspection showed a 3D avatar preview. These observations establish an active Metal renderer, not that MacShade was present in the process or that its hooks cover Roblox's submission path.
