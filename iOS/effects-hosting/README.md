# RoMacShade Effects

Versioned effect and preset library for [RoMacShade](https://github.com/hesm4tt/RoMacShade). The app compiles the included ReShade `.fx` shaders to Metal on the device, reads standard ReShade `.ini` presets, and stores user imports locally.

The `ios-effects-v1` release contains one compressed `RoMacShade-effects.rmpack` with the shaders, helper includes, textures and presets, plus its JSON file index and SHA-256 checksums. It includes all 17 supplied Extravi presets and two RoMacShade sample presets. The pack works with the matching RoMacShade iOS build and is not an IPA or standalone tweak.

To refresh the library in the app, open About → **Restore library from project release**. The pack is pinned to the build's SHA-256 and checked file by file before installation. First launch does not need a network connection because the same pack is embedded in the dylib.

The effect sources and presets come from their respective authors and retain their embedded notices. qUINT credits Pascal Gilcher / Marty McFly; Extravi presets credit Extravi; ReShadeFX credits crosire; SPIRV-Cross credits Khronos and contributors. The repository does not claim authorship of those works or replace their individual terms.

To prepare the release assets, run `bash iOS/prepare_effect_hosting.sh` in the RoMacShade source checkout. Attach the three files in `build/ios-source/effect-hosting/` to a GitHub release tagged `ios-effects-v1`. Preserve the exact `.rmpack` filename because the iOS build pins its download URL and checksum.
