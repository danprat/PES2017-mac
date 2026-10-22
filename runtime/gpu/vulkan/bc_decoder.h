#pragma once

#include "gpu/texture.h"
#include <cstdint>

namespace vk::bc
{
    // Whether this Xenos texture format is a Block-Compressed format (BC1..BC5).
    bool IsBCFormat(uint32_t xenosFormat);

    // How much of the Snapdragon workaround applies where the driver's own BC
    // sampling is left enabled (pipeline.cpp turns it off on Adreno, because
    // its compressed-sampling path renders BC1-with-1-bit-alpha surfaces black
    // or missing for a frame at a time). MW2_ADRENO_BC picks a narrower rule
    // for a driver that proves clean:
    //   hw    -- keep the driver's BC sampling, as MW2_FORCE_BC_HW=1 does
    //   dxt1  -- keep it, and decode only the BC1 family in software
    // Unset, or anything else, is every BC format in software.
    enum class AdrenoBC { kAll, kHardware, kDxt1Only };
    AdrenoBC AdrenoMode();

    // Decompress a BC texture into uncompressed formats (RGBA8, R8, RG8).
    // Returns true on success and updates outVulkanFormat to the uncompressed VkFormat.
    bool Decompress(const gpu::TextureData& src, uint32_t xenosFormat,
                    gpu::TextureData& dst, int& outVulkanFormat);
}
