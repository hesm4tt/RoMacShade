# Metal host integration — MacShade 0.4

The host entry library has loaded and applied color effects inside Roblox 0.739.0.7390687 on Apple M5 / macOS 27.0. This uses a separate, locally signed app copy. It is a startup loader; the already-running official Roblox process is left open.

## Launcher

Double-click `Launch Roblox with MacShade.command`, or run:

```sh
python3 Tools/roblox_host.py run
python3 Tools/roblox_host.py run --preset "Presets/Clear Day.ini"
python3 Tools/roblox_host.py run --fx /path/to/effect.fx
```

`run` hashes the installed executable and uses a matching cache directory beneath `~/Library/Application Support/MacShade/Hosts`. A new Roblox version gets a fresh copy. It checks the prepared copy's marker, executable hash, signature, and loading entitlements before launch, then waits up to 15 seconds for a same-PID report with installed hooks and completed processed frames. It never overwrites an existing destination during preparation. If a cached copy fails validation, use the explicit fresh-destination workflow below.

```sh
python3 Tools/roblox_host.py inspect
python3 Tools/roblox_host.py prepare --destination "$HOME/Roblox-MacShade-Test.app"
python3 Tools/roblox_host.py launch --app "$HOME/Roblox-MacShade-Test.app" --log-directory "$HOME/Library/Logs/MacShade"
```

Preparation uses `ditto`, preserves the original XML entitlements, adds `com.apple.security.cs.allow-dyld-environment-variables` and `com.apple.security.cs.disable-library-validation`, and ad-hoc signs the copied main app. Nested components retain their original signatures. The installed executable hash is checked again afterward. Apple's documentation describes the required [DYLD exception](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables) and [library validation exception](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).

Only the new player's environment receives `DYLD_INSERT_LIBRARIES`. Its initializer clears that setting before the player starts helper processes. No persistent shell, launchctl, SIP, or system-wide setting is changed. Launching the copied app directly from Finder does not load MacShade; use the command file or Python launcher.

## Controls and reports

**⌘E** opens/closes the window-attached overlay; **⌘B** toggles processing. The collapsed control occupies a small area at the top right. Closing the inspector restores the host's prior first responder. Import/export, effect ordering, parameter editing, reload, and shader-folder selection are handled by the overlay. Resizing suspends effects compiled for the previous dimensions until a replacement chain is ready.

The report JSON records the process and host bundle, hook/overlay state, acquired drawables, committed buffers, render-target matches, encoded processing/FX counts, completed processed frames, GPU errors and depth status. Counters count drawable-processing submissions, so a host that writes the same drawable in multiple command buffers may count it more than once. `processedFrames` and `fxFrames` mean encoding succeeded; `completedFrames` means the command buffer completed successfully. None is a frame-rate benchmark or a pixel-equivalence guarantee. `launch` returning a PID alone does not prove rendering; `run` also checks the completion report.

`HostProbe PID` prints a read-only signing/task-port diagnostic. Any task right granted to the probe is immediately deallocated. It does not read target memory, suspend threads, or modify the process. The tested original Roblox process denied this request; the tested startup copy does not depend on task-port access.

## Rendering integration

The hooks observe `CAMetalLayer.nextDrawable`, associate each returned texture with a weak drawable reference, and recognize that texture in render-pass color attachments. This identifies a buffer that writes a drawable even when the application presents the drawable directly instead of calling a command-buffer presentation method. Processing is appended before that writer buffer commits. Existing command-buffer presentation hooks remain supported and deduplicate drawables within the buffer.

The current discovery hooks the default GPU's observed command-buffer class. It does not discover arbitrary private engine resources. A drawable written only by blit/compute, an MSAA resolve destination, another GPU, or a different unobserved command-buffer implementation may need additional integration. Processing occurs on the final rendered color image, including rendered UI.

The independent `MetalHostHarness.app` links no MacShade library. External loading was tested with both command-buffer presentation and direct drawable presentation; the latter completed 475 frames under Metal API Validation, with 454 depth-effect submissions after compilation and no GPU errors.

## Depth status

The actual local qUINT SSR shader compiles. Its depth workload works in the independent host. In the tested Roblox avatar preview, the matcher did not find current depth corresponding to the final drawable: the report showed 12 captured startup attachments, zero successful SSR submissions and no GPU errors. The shader is therefore skipped, and the overlay reports **Waiting for scene depth**. A captured attachment count by itself does not establish a correct scene-depth input.

Roblox SSR is **not verified or complete**. Its depth producer, presentation relationship, viewport and projection convention must still be matched. The current path requires compatible single-sample Depth32Float/Depth16Unorm attachments in the same command buffer and does not cover packed depth/stencil, MSAA, another queue/buffer, or infinite-Z conversion. A reversed-depth checkbox alone cannot solve those associations.

The supplied Roblox app and qUINT source files are not redistributed. The package contains MacShade code/binaries and the licensed bundled shaders only. The source and resulting runtime are experimental; acceptance of a locally signed copy by future Roblox versions is untested.
