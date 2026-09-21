//
// Copyright (c) 2026 RoMacShade / RoAndroidShade Authors.
// Embedded SPIR-V Bytecode for Vulkan Post-Processing Pipeline.
//

#pragma once

#include <cstdint>
#include <cstddef>

namespace roshade {

static const uint32_t kPostProcessVertSPV[] =
#include "vert_spv.inc"
;
static const size_t kPostProcessVertSPVSize = sizeof(kPostProcessVertSPV);

static const uint32_t kPostProcessFragSPV[] =
#include "frag_spv.inc"
;
static const size_t kPostProcessFragSPVSize = sizeof(kPostProcessFragSPV);

} // namespace roshade
