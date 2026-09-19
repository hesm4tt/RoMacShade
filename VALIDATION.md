# Validation — MacShade 0.4

Verified September 18, 2026 on Apple M5, macOS 27.0 (26A428), Apple clang 21.0.0. The included binaries are arm64 with a macOS 12 deployment target. Earlier macOS versions and Intel hardware have not been executed.

## Automated checks

| Suite | Passed checks | Coverage |
| --- | ---: | --- |
| RendererTests | 27 | Built-in grading, color formats, alpha, concurrency and invalid inputs |
| FXTests | 70 | Shader compilation/reflection, defaults and UI annotations, numeric edits, color-space handling, multiple passes, ordered effects, compiler definitions/includes and resource lifetimes |
| PresetTests | 43 | INI ordering and enabled state, numeric values, definitions, BOM/CRLF, bounds, malformed input and serialization precision |
| ChainTests | 19 | Preset resolution and application, disabled shaders, missing/ambiguous files, atomic failure, export/import, depth-convention adaptation and hotkey metadata |
| DepthCaptureTests | 40 | Depth32Float/Depth16Unorm GPU conversion, orientation, resizing, finite reversed depth, resource lifetime and invalid input rejection |
| DepthTests with local qUINT SSR | 18 | Explicit R32Float depth, changing textures, different dimensions, missing/incompatible depth, technique-dependent requirements, and the actual qUINT SSR multipass workload |

Total: **217 core checks passed**, rerun against the 0.4 build. **12 additional launcher tests passed**, covering XML entitlement extraction and preservation, unparseable signing output, fresh-copy boundaries, prepared identity verification, child-only environment settings, private logs, version-cache reuse, and requiring completed frames before reporting a successful run. Project Objective-C++ sources build with `-Wall -Wextra -Werror`; vendored compilers use the separate flags in `build.sh`.

## Roblox host integration

Verified the actual installed player version 0.739.0.7390687. The original hardened process denied a standard `task_for_pid` request (kernel status 5). Its executable SHA-256 before preparation was `58c5a42ac333cfade0813f83a6fed34b6ddac64b468a7f933cf054c08a58c16d`; preparation and final verification confirmed the same original hash and valid signature.

The isolated copy preserved the original executable-page-protection, camera, and microphone entitlements, added the two loading exceptions, and passed deep/strict signature verification after ad-hoc signing. Its copied executable hash is `a7b26107fcd3aa3a63f6d487a635d3361c7e5282a3e2ceb8c28c58a1e77dce34`.

- The first host experiment loaded the library and attached the overlay but encoded zero effects. Tracking drawable textures in render-pass attachments resolved that missed submission path.
- A subsequent actual Roblox run recorded **10,508 completed processed submissions**, **10,507 encoded FX submissions**, and **zero GPU errors** with ColorGrade active. Editing saturation to zero visibly turned its output grayscale.
- The final `Launch Roblox with MacShade.command --preset "Presets/Clear Day.ini"` created/reused the version cache, launched the copy and returned success only after its same-PID report showed completed processed frames.
- In that instance, navigated to the live 3D avatar view using Roblox's keyboard navigation, changed saturation to zero and visually verified the 3D avatar/background became grayscale. Imported Clear Day.ini through the native overlay and verified saturation returned to 1.02 and its four ordered entries loaded. Hiding the controls restored Roblox's text-entry first responder.
- The final copy remains separate from the original running app. The host initializer now clears its child-loading environment before helper launch; the final loader marker belongs to the player only.
- Verified ⌘B changed the overlay to Effects off and back on, and ⌘E hid/reopened the controls while restoring Roblox's first responder. Left Clear Day active with the controls open on the avatar preview.

The user's qUINT SSR file compiled in Roblox, but no depth matched the final drawable. That run recorded **15,232 completed built-in submissions**, **12 captured startup depth attachments**, **zero successful SSR submissions**, and **zero GPU errors**. The tested avatar-preview depth relationship remains unsupported. The overlay reports **Waiting for scene depth**; SSR in Roblox is not claimed to work.

Point-in-time, MacShade-only report snapshots are in [Validation/](Validation/). They exclude Roblox's full log, account information, and shader source files.

## Independent external-loading checks

The new HostHarness links AppKit/Metal/MetalKit and no MacShade library. Its unmodified baseline completed 120 submitted frames with no errors. Loading `libMacShadeHost.dylib` through dyld attached the overlay and applied Clear Day.ini; the 30-second harness run completed 1,789 frames with no encoding or GPU errors.

With `MACSHADE_TEST_DIRECT_PRESENT=1`, DepthView.fx and Metal API Validation enabled, it completed **475 frames**, including **454 encoded FX/depth submissions after compilation**, with no encoding or GPU errors. This exercises direct `[drawable present]` without any command-buffer presentation call. The hook's asynchronous report snapshot can lag the harness's final drained GPU count by one frame.

The final demo regression smoke also completed 12 frames with 12 FX submissions, 12 depth captures and no GPU errors while cycling all three command-buffer presentation variants. The render-target and presentation associations deduplicated each drawable within the buffer.

## Actual drawable / hook integration

Each smoke run submits 12 real CAMetalDrawables, cycles the three command-buffer presentation variants four times and requests presentation before scene encoding. All submitted buffers must complete without GPU errors. For a depth effect, at least 12 captured depth snapshots are also required.

| Effect / preset | Completed | FX encoded | Depth captures | GPU errors |
| --- | ---: | ---: | ---: | ---: |
| User's unmodified qUINT_ssr.fx, Metal API Validation enabled | 12 | 12 | 12 | 0 |
| Included DepthView.fx | 12 | 12 | 12 | 0 |
| Included Clear Day.ini: three enabled effects | 12 | 12 | 0 | 0 |
| SSR preset exported through the overlay, then imported | 12 | 12 | 12 | 0 |

The normal driver class was `AGXG17GFamilyCommandBuffer`; API Validation exercised `MTLDebugCommandBuffer`. Both were discovered at runtime. The scene pass deliberately requests a discard depth store action; the depth hook preserves and copies that attachment after its encoder ends. The demo's analytically intersected floor/buildings write corresponding perspective depth, using near 1, far 1000 and a 50-degree vertical field of view.

The external SSR test uses the user's local `qUINT_ssr.fx` and its companion `qUINT_common.fxh`; those files are not redistributed in this package. This verifies that specific shader and input path, not every qUINT shader or all ReShade features.

## Native UI verification

- Visually inspected the translucent overlay, effect library, parameter inspector, scroll views and native menus over the live Metal scene.
- Added ColorGrade directly from the library and changed saturation from 1 to 0.45; its slider and numeric field agreed.
- Imported Soft Cinema.ini: loaded four ordered entries, with ColorGrade/Vibrance enabled and LumaSharpen/Copy disabled.
- Selected and enabled the initially uncompiled LumaSharpen entry; its sliders, sample-pattern dropdown and checkbox appeared with imported values.
- Reordered LumaSharpen in the list.
- Loaded qUINT SSR and saw its actual reflected controls and a live depth-capture status at 2440 × 1640.
- Saved an SSR preset through NSSavePanel and imported it through NSOpenPanel; the saved file contains the technique and all ten editable shader parameters. Dynamic frame/time values are excluded.
- Set reflection intensity to 0.6, resized to 3420 × 1962, and verified that the value remained 0.6 after recompilation and depth capture resumed at the new size.
- UI verification used an isolated app copy, without replacing the user's prior demo installation.

## Remaining boundaries

**Color processing and the overlay have been verified inside a separately launched Roblox copy. Roblox depth matching remains unresolved.** This startup-loading route does not attach to an already-running official player. Full in-experience rendering paths and future Roblox versions have not been validated.

Automatic depth capture currently requires compatible single-sample Depth32Float/Depth16Unorm and color attachments in the same command buffer. The exact color association works in the demo; the aspect/size fallback is a heuristic and may choose incorrectly in another engine. MSAA, memoryless depth, packed depth/stencil, depth produced in a different command buffer or queue, parallel encoders and infinite-Z conversion are not implemented. A reversed-depth toggle alone does not establish a correct Roblox camera model.

No broad performance benchmark, pixel-equivalence comparison with Windows ReShade, or full third-party preset compatibility claim is made. Preset imports cannot supply missing shader/image assets, and unsupported effects still report diagnostics. The app is locally ad-hoc signed, not notarized.
