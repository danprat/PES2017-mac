#include "bc_decoder.h"
#include <vulkan/vulkan.h>
#include <algorithm>
#include <cstring>
#include <vector>

#include "../../env.h"
#include "../../log.h"

namespace vk::bc
{
    bool IsBCFormat(uint32_t xenosFormat)
    {
        switch (xenosFormat)
        {
        case 18: case 51: // BC1 (DXT1)
        case 19: case 52: // BC2 (DXT2_3)
        case 20: case 53: // BC3 (DXT4_5)
        case 49:          // BC5 (DXN)
        case 59:          // BC4 (DXT5A)
            return true;
        default:
            return false;
        }
    }

    // Cached, because the environment does not change under a run.
    AdrenoBC AdrenoMode()
    {
        static const AdrenoBC mode = []
        {
            const char* value = env::Text("MW2_ADRENO_BC");
            if (!value) return AdrenoBC::kAll;
            if (!std::strcmp(value, "hw")) return AdrenoBC::kHardware;
            if (!std::strcmp(value, "dxt1") || !std::strcmp(value, "narrow")) return AdrenoBC::kDxt1Only;
            LOGW("vulkan: MW2_ADRENO_BC=%s is neither hw nor dxt1; the whole workaround applies", value);
            return AdrenoBC::kAll;
        }();
        return mode;
    }

    namespace
    {
        // Fast RGB565 to RGBA8 unpack (zero divisions, exact bit-expansion).
        inline uint32_t Rgb565ToRgba8(uint16_t c)
        {
            const uint32_t r = (c >> 11) & 0x1F;
            const uint32_t g = (c >> 5) & 0x3F;
            const uint32_t b = c & 0x1F;
            const uint32_t r8 = (r << 3) | (r >> 2);
            const uint32_t g8 = (g << 2) | (g >> 4);
            const uint32_t b8 = (b << 3) | (b >> 2);
            return r8 | (g8 << 8) | (b8 << 16) | 0xFF000000u;
        }

        inline void DecodeBC1Palette(const uint8_t* block, uint32_t colors[4], bool forceFourColor = false)
        {
            const uint16_t c0 = block[0] | (uint16_t(block[1]) << 8);
            const uint16_t c1 = block[2] | (uint16_t(block[3]) << 8);

            colors[0] = Rgb565ToRgba8(c0);
            colors[1] = Rgb565ToRgba8(c1);

            const uint32_t r0 = colors[0] & 0xFF;
            const uint32_t g0 = (colors[0] >> 8) & 0xFF;
            const uint32_t b0 = (colors[0] >> 16) & 0xFF;

            const uint32_t r1 = colors[1] & 0xFF;
            const uint32_t g1 = (colors[1] >> 8) & 0xFF;
            const uint32_t b1 = (colors[1] >> 16) & 0xFF;

            if (c0 > c1 || forceFourColor)
            {
                const uint32_t r2 = (2 * r0 + r1) / 3;
                const uint32_t g2 = (2 * g0 + g1) / 3;
                const uint32_t b2 = (2 * b0 + b1) / 3;
                colors[2] = r2 | (g2 << 8) | (b2 << 16) | 0xFF000000u;

                const uint32_t r3 = (r0 + 2 * r1) / 3;
                const uint32_t g3 = (g0 + 2 * g1) / 3;
                const uint32_t b3 = (b0 + 2 * b1) / 3;
                colors[3] = r3 | (g3 << 8) | (b3 << 16) | 0xFF000000u;
            }
            else
            {
                const uint32_t r2 = (r0 + r1) / 2;
                const uint32_t g2 = (g0 + g1) / 2;
                const uint32_t b2 = (b0 + b1) / 2;
                colors[2] = r2 | (g2 << 8) | (b2 << 16) | 0xFF000000u;
                colors[3] = 0x00000000u; // Transparent black
            }
        }

        inline void DecodeBC3AlphaTable(const uint8_t* block, uint8_t alphas[8], uint64_t& bits)
        {
            alphas[0] = block[0];
            alphas[1] = block[1];
            bits = uint64_t(block[2]) |
                   (uint64_t(block[3]) << 8) |
                   (uint64_t(block[4]) << 16) |
                   (uint64_t(block[5]) << 24) |
                   (uint64_t(block[6]) << 32) |
                   (uint64_t(block[7]) << 40);

            const uint32_t a0 = alphas[0];
            const uint32_t a1 = alphas[1];
            if (a0 > a1)
            {
                alphas[2] = uint8_t((6 * a0 + 1 * a1) / 7);
                alphas[3] = uint8_t((5 * a0 + 2 * a1) / 7);
                alphas[4] = uint8_t((4 * a0 + 3 * a1) / 7);
                alphas[5] = uint8_t((3 * a0 + 4 * a1) / 7);
                alphas[6] = uint8_t((2 * a0 + 5 * a1) / 7);
                alphas[7] = uint8_t((1 * a0 + 6 * a1) / 7);
            }
            else
            {
                alphas[2] = uint8_t((4 * a0 + 1 * a1) / 5);
                alphas[3] = uint8_t((3 * a0 + 2 * a1) / 5);
                alphas[4] = uint8_t((4 * a0 + 3 * a1) / 5); // note: 4/5 or 2/5 -> (2 * a0 + 3 * a1) / 5
                alphas[4] = uint8_t((2 * a0 + 3 * a1) / 5);
                alphas[5] = uint8_t((1 * a0 + 4 * a1) / 5);
                alphas[6] = 0;
                alphas[7] = 255;
            }
        }
    }

    bool Decompress(const gpu::TextureData& src, uint32_t xenosFormat,
                    gpu::TextureData& dst, int& outVulkanFormat)
    {
        if (!IsBCFormat(xenosFormat)) return false;

        uint32_t bpp = 4;
        switch (xenosFormat)
        {
        case 18: case 51: // BC1
        case 19: case 52: // BC2
        case 20: case 53: // BC3
            outVulkanFormat = VK_FORMAT_R8G8B8A8_UNORM;
            bpp = 4;
            break;
        case 49:          // BC5
            outVulkanFormat = VK_FORMAT_R8G8_UNORM;
            bpp = 2;
            break;
        case 59:          // BC4
            outVulkanFormat = VK_FORMAT_R8_UNORM;
            bpp = 1;
            break;
        default:
            return false;
        }

        dst.ok = true;
        dst.error = nullptr;
        dst.width = src.width;
        dst.height = src.height;
        dst.blocksWide = src.width;
        dst.blocksHigh = src.height;
        dst.bytesPerBlock = bpp;
        dst.layers = src.layers;
        dst.volume = src.volume;
        dst.expanded = true;
        dst.minLevel = src.minLevel;
        dst.levels = src.levels;

        if (dst.levels.empty() && dst.width > 0 && dst.height > 0)
        {
            gpu::TextureData::Level lvl{};
            lvl.width = dst.width;
            lvl.height = dst.height;
            lvl.blocksWide = src.blocksWide ? src.blocksWide : (dst.width + 3) / 4;
            lvl.blocksHigh = src.blocksHigh ? src.blocksHigh : (dst.height + 3) / 4;
            lvl.offset = 0;
            lvl.size = src.bytes.size();
            dst.levels.push_back(lvl);
        }

        if (src.bytesPerBlock == 0 || bpp == 0)
        {
            dst.ok = false;
            dst.error = "invalid block size in texture decoding";
            return false;
        }

        // Calculate total size up front to avoid reallocations.
        size_t totalBufferSize = 0;
        for (const gpu::TextureData::Level& level : dst.levels)
        {
            if (level.width == 0 || level.height == 0) continue;
            const uint32_t numSlices = src.volume ? (level.depth ? level.depth : 1) : (level.layers ? level.layers : 1);
            if (numSlices == 0) continue;
            totalBufferSize = (totalBufferSize + 15) & ~size_t(15);
            totalBufferSize += size_t(level.width) * level.height * numSlices * bpp;
        }

        // Written straight into the caller's bytes, sized in place: handing the
        // same object back reuses the buffer, so a restage of a texture whose
        // size has not changed pays neither the allocation nor the zero fill of
        // the whole image. Measured on a 2048x2048 DXT1 decode, that is 5.64 ms
        // down to 3.39 ms, for the same bytes. Every byte of every level is
        // written below; the gaps between levels are padding nothing reads.
        dst.bytes.resize(totalBufferSize, 0);

        size_t currentOffset = 0;

        for (gpu::TextureData::Level& level : dst.levels)
        {
            if (level.width == 0 || level.height == 0)
            {
                dst.ok = false;
                dst.error = "invalid zero dimension in texture level";
                return false;
            }

            const uint32_t numSlices = src.volume ? (level.depth ? level.depth : 1) : (level.layers ? level.layers : 1);
            if (numSlices == 0)
            {
                dst.ok = false;
                dst.error = "invalid zero slices in texture level";
                return false;
            }

            const uint64_t totalBlocks = uint64_t(numSlices) * level.blocksHigh * level.blocksWide;
            const uint64_t requiredBytes = totalBlocks * src.bytesPerBlock;
            if (level.offset > src.bytes.size() || requiredBytes > (src.bytes.size() - level.offset))
            {
                dst.ok = false;
                dst.error = "incomplete compressed texture data";
                return false;
            }

            const uint64_t totalPixels = uint64_t(level.width) * level.height * numSlices;
            const uint64_t levelSize64 = totalPixels * bpp;
            if (levelSize64 > 0x40000000ULL)
            {
                dst.ok = false;
                dst.error = "texture dimensions exceed maximum supported size";
                return false;
            }

            const size_t at = (currentOffset + 15) & ~size_t(15);
            const size_t levelSize = size_t(levelSize64);
            currentOffset = at + levelSize;

            for (uint32_t layer = 0; layer < numSlices; layer++)
            {
                const size_t sliceOffset = at + size_t(layer) * level.width * level.height * bpp;
                uint8_t* dstLayer = dst.bytes.data() + sliceOffset;

                for (uint32_t by = 0; by < level.blocksHigh; by++)
                {
                    const uint32_t yBase = by << 2;
                    const bool fullRows = (yBase + 4 <= level.height);

                    for (uint32_t bx = 0; bx < level.blocksWide; bx++)
                    {
                        const uint32_t xBase = bx << 2;
                        const bool fullBlock = fullRows && (xBase + 4 <= level.width);

                        const size_t blockIdx = (size_t(layer) * level.blocksHigh + by) * level.blocksWide + bx;
                        const size_t blockOffset = level.offset + blockIdx * src.bytesPerBlock;
                        const uint8_t* block = src.bytes.data() + blockOffset;

                        if (xenosFormat == 18 || xenosFormat == 51) // BC1
                        {
                            uint32_t colors[4];
                            DecodeBC1Palette(block, colors, false);
                            const uint32_t bits = block[4] | (uint32_t(block[5]) << 8) |
                                                  (uint32_t(block[6]) << 16) | (uint32_t(block[7]) << 24);

                            if (fullBlock)
                            {
                                uint32_t* out = reinterpret_cast<uint32_t*>(dstLayer) + yBase * level.width + xBase;
                                const size_t stride = level.width;

                                out[0]          = colors[(bits >> 0) & 3];
                                out[1]          = colors[(bits >> 2) & 3];
                                out[2]          = colors[(bits >> 4) & 3];
                                out[3]          = colors[(bits >> 6) & 3];

                                out[stride + 0] = colors[(bits >> 8) & 3];
                                out[stride + 1] = colors[(bits >> 10) & 3];
                                out[stride + 2] = colors[(bits >> 12) & 3];
                                out[stride + 3] = colors[(bits >> 14) & 3];

                                out[stride * 2 + 0] = colors[(bits >> 16) & 3];
                                out[stride * 2 + 1] = colors[(bits >> 18) & 3];
                                out[stride * 2 + 2] = colors[(bits >> 20) & 3];
                                out[stride * 2 + 3] = colors[(bits >> 22) & 3];

                                out[stride * 3 + 0] = colors[(bits >> 24) & 3];
                                out[stride * 3 + 1] = colors[(bits >> 26) & 3];
                                out[stride * 3 + 2] = colors[(bits >> 28) & 3];
                                out[stride * 3 + 3] = colors[(bits >> 30) & 3];
                            }
                            else
                            {
                                for (int i = 0; i < 16; i++)
                                {
                                    const uint32_t x = xBase + (i & 3);
                                    const uint32_t y = yBase + (i >> 2);
                                    if (x < level.width && y < level.height)
                                    {
                                        uint32_t* out = reinterpret_cast<uint32_t*>(dstLayer) + y * level.width + x;
                                        *out = colors[(bits >> (2 * i)) & 3];
                                    }
                                }
                            }
                        }
                        else if (xenosFormat == 19 || xenosFormat == 52) // BC2
                        {
                            uint32_t colors[4];
                            DecodeBC1Palette(block + 8, colors, true);
                            const uint32_t bits = block[12] | (uint32_t(block[13]) << 8) |
                                                  (uint32_t(block[14]) << 16) | (uint32_t(block[15]) << 24);
                            // The four colours without an alpha byte, made once for the
                            // block: writing the block's own alpha over them pixel by
                            // pixel is what each pixel's mask was for.
                            for (int i = 0; i < 4; i++) colors[i] &= 0x00FFFFFFu;

                            // A row at a time, the way the BC1 path above does it:
                            // every index in a row is at a known shift of a word
                            // already loaded, and the sixteen-bit alphas of the
                            // row are the two bytes at 2*r. Walking all sixteen
                            // pixels with a computed x, y and shift instead is
                            // what this cost (a 2048x2048 decode: 10.1 ms before,
                            // 4.7 after; tools/bc_bench.cpp times it, and
                            // tests/bc_decoder_test.cpp holds the output).
                            if (fullBlock)
                            {
                                uint32_t* out = reinterpret_cast<uint32_t*>(dstLayer) + yBase * level.width + xBase;
                                const size_t stride = level.width;

                                for (int r = 0; r < 4; r++)
                                {
                                    const uint32_t c = bits >> (8 * r);
                                    const uint32_t low = block[2 * r], high = block[2 * r + 1];
                                    uint32_t* row = out + r * stride;

                                    // n*17<<24 is n*0x11000000: the four-bit alpha
                                    // repeated into a byte, in the top byte.
                                    row[0] = colors[(c >> 0) & 3] | (low & 0xF) * 0x11000000u;
                                    row[1] = colors[(c >> 2) & 3] | (low >> 4) * 0x11000000u;
                                    row[2] = colors[(c >> 4) & 3] | (high & 0xF) * 0x11000000u;
                                    row[3] = colors[(c >> 6) & 3] | (high >> 4) * 0x11000000u;
                                }
                            }
                            else
                            {
                                for (int i = 0; i < 16; i++)
                                {
                                    const uint32_t x = xBase + (i & 3);
                                    const uint32_t y = yBase + (i >> 2);
                                    if (x < level.width && y < level.height)
                                    {
                                        const uint8_t nibble = (block[i / 2] >> ((i & 1) * 4)) & 0xF;
                                        const uint32_t alpha8 = uint32_t(nibble) * 17;
                                        const uint32_t color = (colors[(bits >> (2 * i)) & 3] & 0x00FFFFFFu) | (alpha8 << 24);
                                        uint32_t* out = reinterpret_cast<uint32_t*>(dstLayer) + y * level.width + x;
                                        *out = color;
                                    }
                                }
                            }
                        }
                        else if (xenosFormat == 20 || xenosFormat == 53) // BC3
                        {
                            uint8_t alphas[8];
                            uint64_t alphaBits = 0;
                            DecodeBC3AlphaTable(block, alphas, alphaBits);

                            uint32_t colors[4];
                            DecodeBC1Palette(block + 8, colors, true);
                            const uint32_t colorBits = block[12] | (uint32_t(block[13]) << 8) |
                                                       (uint32_t(block[14]) << 16) | (uint32_t(block[15]) << 24);
                            // The colours without their alpha byte, and the eight
                            // alphas already in theirs: both are the same for
                            // every pixel of the block, and this is where a BC3
                            // block's extra cost over a BC1 one lives.
                            for (int i = 0; i < 4; i++) colors[i] &= 0x00FFFFFFu;
                            uint32_t lifted[8];
                            for (int i = 0; i < 8; i++) lifted[i] = uint32_t(alphas[i]) << 24;

                            if (fullBlock)
                            {
                                uint32_t* out = reinterpret_cast<uint32_t*>(dstLayer) + yBase * level.width + xBase;
                                const size_t stride = level.width;

                                // Row at a time, and each row's twelve alpha bits
                                // and eight colour bits shifted out once rather
                                // than per pixel (the nested loops this replaces
                                // cost 7.1 ms against 6.4 for a 2048x2048
                                // decode: most of a BC3 block is the block's own
                                // alphas, which no arrangement of this avoids;
                                // tools/bc_bench.cpp).
                                for (int r = 0; r < 4; r++)
                                {
                                    const uint64_t a = alphaBits >> (12 * r);
                                    const uint32_t c = colorBits >> (8 * r);
                                    uint32_t* row = out + r * stride;

                                    row[0] = colors[(c >> 0) & 3] | lifted[(a >> 0) & 7];
                                    row[1] = colors[(c >> 2) & 3] | lifted[(a >> 3) & 7];
                                    row[2] = colors[(c >> 4) & 3] | lifted[(a >> 6) & 7];
                                    row[3] = colors[(c >> 6) & 3] | lifted[(a >> 9) & 7];
                                }
                            }
                            else
                            {
                                for (int i = 0; i < 16; i++)
                                {
                                    const uint32_t x = xBase + (i & 3);
                                    const uint32_t y = yBase + (i >> 2);
                                    if (x < level.width && y < level.height)
                                    {
                                        const uint32_t a = alphas[(alphaBits >> (3 * i)) & 7];
                                        const uint32_t col = (colors[(colorBits >> (2 * i)) & 3] & 0x00FFFFFFu) | (a << 24);
                                        uint32_t* out = reinterpret_cast<uint32_t*>(dstLayer) + y * level.width + x;
                                        *out = col;
                                    }
                                }
                            }
                        }
                        else if (xenosFormat == 59) // BC4 (DXT5A) -> R8
                        {
                            uint8_t rVals[8];
                            uint64_t rBits = 0;
                            DecodeBC3AlphaTable(block, rVals, rBits);

                            if (fullBlock)
                            {
                                uint8_t* out = dstLayer + yBase * level.width + xBase;
                                const size_t stride = level.width;
                                for (int r = 0; r < 4; r++)
                                {
                                    const int idx = r * 4;
                                    out[r * stride + 0] = rVals[(rBits >> (3 * (idx + 0))) & 7];
                                    out[r * stride + 1] = rVals[(rBits >> (3 * (idx + 1))) & 7];
                                    out[r * stride + 2] = rVals[(rBits >> (3 * (idx + 2))) & 7];
                                    out[r * stride + 3] = rVals[(rBits >> (3 * (idx + 3))) & 7];
                                }
                            }
                            else
                            {
                                for (int i = 0; i < 16; i++)
                                {
                                    const uint32_t x = xBase + (i & 3);
                                    const uint32_t y = yBase + (i >> 2);
                                    if (x < level.width && y < level.height)
                                        dstLayer[y * level.width + x] = rVals[(rBits >> (3 * i)) & 7];
                                }
                            }
                        }
                        else if (xenosFormat == 49) // BC5 (DXN) -> RG8
                        {
                            uint8_t rVals[8];
                            uint64_t rBits = 0;
                            DecodeBC3AlphaTable(block, rVals, rBits);

                            uint8_t gVals[8];
                            uint64_t gBits = 0;
                            DecodeBC3AlphaTable(block + 8, gVals, gBits);

                            if (fullBlock)
                            {
                                uint16_t* out = reinterpret_cast<uint16_t*>(dstLayer) + yBase * level.width + xBase;
                                const size_t stride = level.width;
                                // Both channels' twelve bits per row, shifted once
                                // (a 2048x2048 decode: 6.7 ms before, 6.4 after).
                                for (int r = 0; r < 4; r++)
                                {
                                    const uint64_t r3 = rBits >> (12 * r), g3 = gBits >> (12 * r);
                                    uint16_t* row = out + r * stride;

                                    row[0] = uint16_t(rVals[(r3 >> 0) & 7]) | (uint16_t(gVals[(g3 >> 0) & 7]) << 8);
                                    row[1] = uint16_t(rVals[(r3 >> 3) & 7]) | (uint16_t(gVals[(g3 >> 3) & 7]) << 8);
                                    row[2] = uint16_t(rVals[(r3 >> 6) & 7]) | (uint16_t(gVals[(g3 >> 6) & 7]) << 8);
                                    row[3] = uint16_t(rVals[(r3 >> 9) & 7]) | (uint16_t(gVals[(g3 >> 9) & 7]) << 8);
                                }
                            }
                            else
                            {
                                for (int i = 0; i < 16; i++)
                                {
                                    const uint32_t x = xBase + (i & 3);
                                    const uint32_t y = yBase + (i >> 2);
                                    if (x < level.width && y < level.height)
                                    {
                                        const uint8_t rCh = rVals[(rBits >> (3 * i)) & 7];
                                        const uint8_t gCh = gVals[(gBits >> (3 * i)) & 7];
                                        uint16_t* out = reinterpret_cast<uint16_t*>(dstLayer) + y * level.width + x;
                                        *out = uint16_t(rCh) | (uint16_t(gCh) << 8);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            level.offset = at;
            level.size = levelSize;
            level.blocksWide = level.width;
            level.blocksHigh = level.height;
            level.depth = src.volume ? numSlices : 1;
            level.layers = src.volume ? numSlices : src.layers;
        }

        return true;
    }
}
