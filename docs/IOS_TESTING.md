# iOS and iPadOS build

RoMacShade now has a source-built arm64 iOS/iPadOS dylib. It uses the repository's
Metal hooks, ReShade FX compiler, depth capture and preset parser, with a UIKit
overlay set in Arial. It does not load or modify Maxey's dylib. Supported shader
features still depend on the host renderer and the individual effect.

Build on a Mac with Xcode 27 or later:

```sh
bash iOS/build_ios.sh device
```

The output is `build/ios-source/device/RoMacShade.dylib`. The effect library is
embedded in the dylib, so first launch and the bundled presets work offline. The
neighboring `RoMacShade-effects.rmpack` (36 MB), JSON index, and checksums are
the files for the effect library release. See
[`iOS/effects-hosting/README.md`](../iOS/effects-hosting/README.md) for the
public repository description and release notes.

## Load with LiveContainer

1. Copy `RoMacShade.dylib` to Files on the iPhone or iPad.
2. In LiveContainer, select the base Roblox app's app-specific tweak folder and
   import the dylib there.
3. Open **Tweaks → Sign** and wait for signing to finish.
4. Launch Roblox, enter a 3D experience, open the floating RoMacShade control,
   and choose a preset or effect. The library contains all 17 supplied Extravi
   presets, two included sample presets, and the bundled effect and texture
   files.

The selection panel can open `.ini`, `.fx`, `.fxh`, or a folder. A selected
preset may queue while the game is at a menu; it compiles when a drawable is
available. If a preset references an unsupported effect, its error appears in
the status area while the currently active chain stays installed.

## Publish the effect library

The app's **Restore library from project release** action downloads the pinned
`ios-effects-v1` release from
[RoMacShade-Effects](https://github.com/hesm4tt/RoMacShade-Effects) and checks
the pack digest before installing it. To publish the matching assets, build the
effect pack, then create the `ios-effects-v1` release in that repository and
attach the `.rmpack`, `.json`, and `SHA256SUMS` files from
`build/ios-source/effect-hosting/`. Keep the pack filename
`RoMacShade-effects.rmpack`; the iOS downloader verifies its compiled SHA-256.

The included dylib is already self-contained; the GitHub download only updates
the separate local effect library. GitHub's [release guide](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
describes adding binary assets to a release.

## Signature errors

If LiveContainer reports `code signature invalid`, sign the dylib with
**Tweaks → Sign** and relaunch. LiveContainer signing has already succeeded for
this setup. Its [tweak guide](https://livecontainer.github.io/docs/guides/tweaks)
documents per-app tweak folders and manual signing.

The binary has an ad-hoc signature on this Mac. The final signature used on the
device comes from LiveContainer. This environment cannot run the iOS Simulator,
so the menu and live Metal/depth output still need a physical-device check.
