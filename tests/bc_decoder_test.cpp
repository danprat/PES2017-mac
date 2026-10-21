// The software BC decoder (runtime/gpu/vulkan/bc_decoder.cpp): the path a Mali
// or other GPU without native block compression takes, where a wrong byte is a
// texture that is subtly wrong on the device and invisible on the desktop that
// reads the same disc.
//
// Every case compares against a decoder written here from the format's own
// definition, not against the one under test, so a mistake in the table, the
// index bit order or the row stride is a failure rather than a second copy of
// the same bug. It asserts rather than reporting, so ctest passes or fails;
// nothing it includes touches the guest, the disc, the GPU or the platform.
#include "gpu/vulkan/bc_decoder.h"
#include "gpu/texture.h"

#include <vulkan/vulkan.h>

#include <cstdio>
#include <string>
#include <vector>

namespace
{
    int g_checks = 0;
    int g_failures = 0;

    void Check(bool ok, const std::string& what)
    {
        g_checks++;
        if (ok) return;
        g_failures++;
        std::fprintf(stdout, "FAIL: %s\n", what.c_str());
    }

    // A run of the same numbers every time: a failure that cannot be repeated
    // is not worth the log line it prints.
    struct Rng
    {
        uint32_t state;
        explicit Rng(uint32_t seed) : state(seed) {}
        uint32_t Next()
        {
            state = state * 1664525u + 1013904223u;
            return state;
        }
        uint8_t Byte() { return uint8_t(Next() >> 24); }
    };

    // ---- the reference, written from the format definitions -----------------

    // RGB565 to RGBA8: three bits replicated into the low bits of five, two
    // bits into the low of six, so 31 is 255 and 0 is 0.
    void Expand565(uint16_t c, uint8_t px[4])
    {
        const uint32_t r = (c >> 11) & 0x1F;
        const uint32_t g = (c >> 5) & 0x3F;
        const uint32_t b = c & 0x1F;
        px[0] = uint8_t((r << 3) | (r >> 2));
        px[1] = uint8_t((g << 2) | (g >> 4));
        px[2] = uint8_t((b << 3) | (b >> 2));
        px[3] = 255;
    }

    uint16_t Le16(const uint8_t* p) { return uint16_t(p[0] | (uint16_t(p[1]) << 8)); }

    uint32_t Le32(const uint8_t* p)
    {
        return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
               (uint32_t(p[3]) << 24);
    }

    uint64_t Le48(const uint8_t* p)
    {
        uint64_t v = 0;
        for (int i = 0; i < 6; i++) v |= uint64_t(p[i]) << (8 * i);
        return v;
    }

    // The four colours a BC1 colour block names. Two endpoints, and either two
    // interpolated between them or one interpolated and one transparent black.
    void RefColorPalette(const uint8_t* block, bool alwaysFour, uint8_t pal[4][4])
    {
        const uint16_t c0 = Le16(block);
        const uint16_t c1 = Le16(block + 2);
        Expand565(c0, pal[0]);
        Expand565(c1, pal[1]);

        if (c0 > c1 || alwaysFour)
        {
            for (int channel = 0; channel < 3; channel++)
                pal[2][channel] = uint8_t((2 * pal[0][channel] + pal[1][channel]) / 3);
            pal[2][3] = 255;
            for (int channel = 0; channel < 3; channel++)
                pal[3][channel] = uint8_t((pal[0][channel] + 2 * pal[1][channel]) / 3);
            pal[3][3] = 255;
        }
        else
        {
            for (int channel = 0; channel < 3; channel++)
                pal[2][channel] = uint8_t((pal[0][channel] + pal[1][channel]) / 2);
            pal[2][3] = 255;
            pal[3][0] = pal[3][1] = pal[3][2] = pal[3][3] = 0;
        }
    }

    // BC3's alpha block, and BC4's only block: two endpoints and six values
    // between or around them, in one of the format's two modes.
    void RefAlphaPalette(uint8_t a0, uint8_t a1, uint8_t out[8])
    {
        out[0] = a0;
        out[1] = a1;
        if (a0 > a1)
        {
            for (int i = 1; i <= 6; i++)
                out[i + 1] = uint8_t(((7 - i) * a0 + i * a1) / 7);
        }
        else
        {
            out[2] = uint8_t((4 * a0 + a1) / 5);
            out[3] = uint8_t((3 * a0 + 2 * a1) / 5);
            out[4] = uint8_t((2 * a0 + 3 * a1) / 5);
            out[5] = uint8_t((a0 + 4 * a1) / 5);
            out[6] = 0;
            out[7] = 255;
        }
    }

    // One block as sixteen texels, in the byte order the decoder promises:
    // RGBA8 for the colour formats, RG8 for BC5 (R low, G high), R8 for BC4.
    void RefBlock(uint32_t format, const uint8_t* block, uint8_t texels[16][4])
    {
        switch (format)
        {
        case 18: case 51: // BC1
        case 19: case 52: // BC2
        case 20: case 53: // BC3
        {
            const bool dxt1 = (format == 18 || format == 51);
            const bool dxt3 = (format == 19 || format == 52);
            const uint8_t* colorBlock = dxt1 ? block : block + 8;
            const uint8_t* alphaBlock = dxt1 ? nullptr : block;

            uint8_t pal[4][4];
            // BC2 and BC3 always have four colours; only BC1 may spend the
            // fourth entry on transparent black.
            RefColorPalette(colorBlock, !dxt1, pal);
            const uint32_t indices = Le32(colorBlock + 4);

            uint8_t colors[8];
            uint64_t alphaIndices = 0;
            if (dxt1)
            {
                for (int i = 0; i < 8; i++) colors[i] = 0;
            }
            else if (dxt3)
            {
                // Sixteen four-bit alphas, low nibble first.
                for (int i = 0; i < 8; i++) colors[i] = 0;
                alphaIndices = 0;
            }
            else
            {
                RefAlphaPalette(alphaBlock[0], alphaBlock[1], colors);
                alphaIndices = Le48(alphaBlock + 2);
            }

            for (int i = 0; i < 16; i++)
            {
                const uint8_t* color = pal[(indices >> (2 * i)) & 3];
                texels[i][0] = color[0];
                texels[i][1] = color[1];
                texels[i][2] = color[2];
                if (dxt1) texels[i][3] = color[3];
                else if (dxt3)
                {
                    const uint32_t nibble = (alphaBlock[i / 2] >> ((i & 1) * 4)) & 0xF;
                    texels[i][3] = uint8_t(nibble * 17);
                }
                else texels[i][3] = colors[(alphaIndices >> (3 * i)) & 7];
            }
            break;
        }
        case 59: // BC4, one channel
        {
            uint8_t values[8];
            RefAlphaPalette(block[0], block[1], values);
            const uint64_t indices = Le48(block + 2);
            for (int i = 0; i < 16; i++)
            {
                texels[i][0] = values[(indices >> (3 * i)) & 7];
                texels[i][1] = 0;
                texels[i][2] = 0;
                texels[i][3] = 0;
            }
            break;
        }
        case 49: // BC5, red block then green block
        {
            uint8_t red[8], green[8];
            RefAlphaPalette(block[0], block[1], red);
            RefAlphaPalette(block[8], block[9], green);
            const uint64_t redIndices = Le48(block + 2);
            const uint64_t greenIndices = Le48(block + 10);
            for (int i = 0; i < 16; i++)
            {
                texels[i][0] = red[(redIndices >> (3 * i)) & 7];
                texels[i][1] = green[(greenIndices >> (3 * i)) & 7];
                texels[i][2] = 0;
                texels[i][3] = 0;
            }
            break;
        }
        default:
            for (int i = 0; i < 16; i++)
                texels[i][0] = texels[i][1] = texels[i][2] = texels[i][3] = 0;
            break;
        }
    }

    // ---- fixtures -----------------------------------------------------------

    uint32_t BytesPerTexel(uint32_t format)
    {
        if (format == 49) return 2;
        if (format == 59) return 1;
        return 4;
    }

    uint32_t CompressedBlockBytes(uint32_t format)
    {
        if (format == 18 || format == 51) return 8;
        return 16;
    }

    constexpr uint32_t kFormats[] = {18, 51, 19, 52, 20, 53, 49, 59};
    constexpr uint32_t kWidths[] = {4, 8, 6, 13};
    constexpr uint32_t kHeights[] = {4, 8, 10, 7};

    gpu::TextureData SingleLevel(uint32_t format, uint32_t width, uint32_t height,
                                 const std::vector<uint8_t>& blocks)
    {
        gpu::TextureData data;
        data.ok = true;
        data.width = width;
        data.height = height;
        data.blocksWide = (width + 3) / 4;
        data.blocksHigh = (height + 3) / 4;
        data.bytesPerBlock = CompressedBlockBytes(format);
        data.layers = 1;
        data.levels = {{width, height, 1, data.blocksWide, data.blocksHigh, 1, 0, blocks.size()}};
        data.bytes = blocks;
        return data;
    }

    // The decoded image against the reference, texel by texel. A stride mistake
    // shows up here as the first block's last texel landing in the second row.
    bool MatchesReference(const gpu::TextureData& decoded, const std::vector<uint8_t>& blocks,
                          uint32_t format, uint32_t width, uint32_t height,
                          std::string& why)
    {
        const uint32_t bpp = BytesPerTexel(format);
        const uint32_t blockBytes = CompressedBlockBytes(format);
        const uint32_t blocksWide = (width + 3) / 4;
        const uint32_t blocksHigh = (height + 3) / 4;

        if (decoded.bytes.size() != size_t(width) * height * bpp)
        {
            why = "decoded size is " + std::to_string(decoded.bytes.size()) + ", expected " +
                  std::to_string(size_t(width) * height * bpp);
            return false;
        }

        for (uint32_t by = 0; by < blocksHigh; by++)
        {
            for (uint32_t bx = 0; bx < blocksWide; bx++)
            {
                uint8_t texels[16][4];
                RefBlock(format, blocks.data() + (size_t(by) * blocksWide + bx) * blockBytes, texels);

                for (uint32_t i = 0; i < 16; i++)
                {
                    const uint32_t x = bx * 4 + (i & 3);
                    const uint32_t y = by * 4 + (i >> 2);
                    if (x >= width || y >= height) continue;

                    const uint8_t* got = decoded.bytes.data() + (size_t(y) * width + x) * bpp;
                    for (uint32_t channel = 0; channel < bpp; channel++)
                    {
                        if (got[channel] == texels[i][channel]) continue;
                        why = "format " + std::to_string(format) + " " + std::to_string(width) +
                              "x" + std::to_string(height) + " texel (" + std::to_string(x) + "," +
                              std::to_string(y) + ") channel " + std::to_string(channel) + " is " +
                              std::to_string(got[channel]) + ", reference says " +
                              std::to_string(texels[i][channel]);
                        return false;
                    }
                }
            }
        }
        return true;
    }

    void RandomBlocksMatchTheReference()
    {
        for (uint32_t format : kFormats)
        {
            for (size_t size = 0; size < sizeof kWidths / sizeof kWidths[0]; size++)
            {
                for (uint32_t seed = 1; seed <= 4; seed++)
                {
                    const uint32_t width = kWidths[size];
                    const uint32_t height = kHeights[size];
                    const size_t blockBytes = CompressedBlockBytes(format);
                    const size_t blockCount = ((width + 3) / 4) * ((height + 3) / 4);

                    Rng rng(seed * 7919u + format);
                    std::vector<uint8_t> blocks(blockCount * blockBytes);
                    for (uint8_t& byte : blocks) byte = rng.Byte();

                    gpu::TextureData decoded;
                    int vulkanFormat = 0;
                    const bool ok = vk::bc::Decompress(SingleLevel(format, width, height, blocks),
                                                       format, decoded, vulkanFormat);
                    const std::string what = "format " + std::to_string(format) + " " +
                                             std::to_string(width) + "x" +
                                             std::to_string(height) + " seed " +
                                             std::to_string(seed);
                    Check(ok, what + " decodes");
                    if (!ok) continue;

                    // The reason is filled in by the call, so it is read after it
                    // rather than in the same expression, where the order is the
                    // compiler's to choose and a failure would print nothing.
                    std::string why;
                    const bool matches = MatchesReference(decoded, blocks, format, width, height, why);
                    Check(matches, what + ": " + why);

                    const uint32_t expectedFormat =
                        format == 49 ? VK_FORMAT_R8G8_UNORM :
                        format == 59 ? VK_FORMAT_R8_UNORM : VK_FORMAT_R8G8B8A8_UNORM;
                    Check(vulkanFormat == int(expectedFormat),
                          what + " maps to Vulkan format " + std::to_string(expectedFormat) +
                              ", got " + std::to_string(vulkanFormat));
                    Check(decoded.expanded, what + " says it is expanded");
                    Check(decoded.bytesPerBlock == BytesPerTexel(format),
                          what + " has " + std::to_string(BytesPerTexel(format)) +
                              " bytes a texel");
                }
            }
        }
    }

    // A block whose colour endpoints are the other way round, with every index
    // asking for entry 3: for BC1 that is transparent black.
    void Bc1ThreeColorModeIsTransparent()
    {
        std::vector<uint8_t> block(8, 0);
        block[0] = 0x00; block[1] = 0x00; // c0 = 0
        block[2] = 0xFF; block[3] = 0xFF; // c1 = 65535, so c0 <= c1
        block[4] = block[5] = block[6] = block[7] = 0xFF; // every index is 3

        gpu::TextureData decoded;
        int vulkanFormat = 0;
        Check(vk::bc::Decompress(SingleLevel(18, 4, 4, block), 18, decoded, vulkanFormat),
              "BC1 three-colour block decodes");
        bool allClear = decoded.bytes.size() == 64;
        for (size_t i = 0; allClear && i < decoded.bytes.size(); i++)
            if (decoded.bytes[i] != 0) allClear = false;
        Check(allClear, "BC1 three-colour index 3 is transparent black, not opaque");
    }

    // The same endpoints in a BC2 block: BC2 has always four colours, so index
    // 3 must stay opaque. Taking it as transparent is the classic DXT1/DXT3 mix-up.
    void Bc2AlwaysHasFourColors()
    {
        std::vector<uint8_t> block(16, 0);
        block[0] = 0x00; block[1] = 0x00;
        block[2] = 0xFF; block[3] = 0xFF;
        block[8] = 0x00; block[9] = 0x00;   // colour c0
        block[10] = 0xFF; block[11] = 0xFF; // colour c1, so c0 <= c1
        block[12] = block[13] = block[14] = block[15] = 0xFF; // every index is 3
        // Four-bit alpha 15 everywhere: bytes 0..7 holding nibbles, all ones.
        for (int i = 0; i < 8; i++) block[i] = 0xFF;

        gpu::TextureData decoded;
        int vulkanFormat = 0;
        Check(vk::bc::Decompress(SingleLevel(19, 4, 4, block), 19, decoded, vulkanFormat),
              "BC2 block decodes");
        bool opaque = decoded.bytes.size() == 64;
        for (size_t i = 3; opaque && i < decoded.bytes.size(); i += 4)
            if (decoded.bytes[i] != 0xFF) opaque = false;
        Check(opaque, "BC2 index 3 stays opaque when its endpoints are in the BC1 order");
    }

    // BC3's two alpha modes: six interpolated values between two endpoints, or
    // four between and then a hard 0 and 255 at the top of the table.
    void Bc3AlphaModes()
    {
        const uint8_t a0 = 200, a1 = 10; // a0 > a1: eight-value mode

        std::vector<uint8_t> block(16, 0);
        block[0] = a0; block[1] = a1;
        // Every index 7 (the last interpolation, (a0 + 6 a1) / 7).
        for (int i = 2; i < 8; i++) block[i] = 0xFF;
        // Two opaque colours.
        block[8] = 0xFF; block[9] = 0xFF;
        block[10] = 0xFF; block[11] = 0xFF;
        block[12] = block[13] = block[14] = block[15] = 0;

        gpu::TextureData decoded;
        int vulkanFormat = 0;
        Check(vk::bc::Decompress(SingleLevel(20, 4, 4, block), 20, decoded, vulkanFormat),
              "BC3 eight-value alpha block decodes");
        const uint8_t expected = uint8_t((a0 + 6 * a1) / 7);
        bool right = decoded.bytes.size() == 64;
        for (size_t i = 3; right && i < decoded.bytes.size(); i += 4)
            if (decoded.bytes[i] != expected) right = false;
        Check(right, "BC3 eight-value mode interpolates index 7 as (a0 + 6 a1) / 7");

        // a0 <= a1: four interpolated values, then a hard 0 and 255.
        const uint8_t b0 = 10, b1 = 200;
        std::vector<uint8_t> other(16, 0);
        other[0] = b0; other[1] = b1;
        for (int i = 2; i < 8; i++) other[i] = 0xFF; // every index 7
        other[8] = 0xFF; other[9] = 0xFF;
        other[10] = 0xFF; other[11] = 0xFF;
        other[12] = other[13] = other[14] = other[15] = 0;

        gpu::TextureData decodedSix;
        Check(vk::bc::Decompress(SingleLevel(20, 4, 4, other), 20, decodedSix, vulkanFormat),
              "BC3 six-value alpha block decodes");
        bool opaque = decodedSix.bytes.size() == 64;
        for (size_t i = 3; opaque && i < decodedSix.bytes.size(); i += 4)
            if (decodedSix.bytes[i] != 255) opaque = false;
        Check(opaque, "BC3 six-value mode index 7 is opaque");
    }

    // BC5 must take its green channel from the second block. Reading the first
    // block twice is a red-only normal map, and a flat normal map still looks
    // like a normal map.
    void Bc5HasTwoChannels()
    {
        std::vector<uint8_t> block(16, 0);
        block[0] = 20; block[1] = 240;   // red endpoints, a0 <= a1: index 2
        block[8] = 200; block[9] = 10;   // green endpoints, a0 > a1: index 2
        // Every index is 2, packed three bits at a time. A byte of 0x92 repeated
        // is not that: the three-bit groups cross byte boundaries, so the fifth
        // index would come out as 1.
        for (int channel = 0; channel < 2; channel++)
        {
            uint64_t indices = 0;
            for (int i = 0; i < 16; i++) indices |= uint64_t(2) << (3 * i);
            for (int i = 0; i < 6; i++)
                block[2 + channel * 8 + i] = uint8_t(indices >> (8 * i));
        }

        gpu::TextureData decoded;
        int vulkanFormat = 0;
        Check(vk::bc::Decompress(SingleLevel(49, 4, 4, block), 49, decoded, vulkanFormat),
              "BC5 block decodes");

        const uint8_t expectedRed = uint8_t((4 * 20 + 240) / 5);
        const uint8_t expectedGreen = uint8_t((6 * 200 + 1 * 10) / 7);
        bool right = decoded.bytes.size() == 32;
        for (size_t i = 0; right && i + 1 < decoded.bytes.size(); i += 2)
        {
            if (decoded.bytes[i] != expectedRed) right = false;
            if (decoded.bytes[i + 1] != expectedGreen) right = false;
        }
        Check(right, "BC5 reads red from the first block and green from the second");
    }

    // Mips are separate ranges, each on its own sixteen-byte boundary, and the
    // decoder has to walk them with their own dimensions.
    void MipLevelsDecodeSeparately()
    {
        const uint32_t blockBytes = 16;
        std::vector<uint8_t> blocks(4 * blockBytes + 1 * blockBytes);
        Rng rng(4242);
        for (uint8_t& byte : blocks) byte = rng.Byte();

        gpu::TextureData source;
        source.ok = true;
        source.width = 8;
        source.height = 8;
        source.blocksWide = 2;
        source.blocksHigh = 2;
        source.bytesPerBlock = blockBytes;
        source.levels = {
            {8, 8, 1, 2, 2, 1, 0, 4 * blockBytes},
            {4, 4, 1, 1, 1, 1, 4 * blockBytes, 1 * blockBytes},
        };
        source.bytes = blocks;

        gpu::TextureData decoded;
        int vulkanFormat = 0;
        Check(vk::bc::Decompress(source, 20, decoded, vulkanFormat), "two-level BC3 decodes");
        Check(decoded.levels.size() == 2, "two-level BC3 keeps its levels");
        if (decoded.levels.size() != 2) return;

        Check(decoded.levels[0].offset == 0, "level 0 starts at the front");
        Check(decoded.levels[0].size == 8 * 8 * 4, "level 0 is 8x8 RGBA8");
        Check(decoded.levels[1].offset % 16 == 0, "level 1 starts on a sixteen-byte boundary");
        Check(decoded.levels[1].size == 4 * 4 * 4, "level 1 is 4x4 RGBA8");
        Check(decoded.bytes.size() >= decoded.levels[1].offset + decoded.levels[1].size,
              "level 1 fits in the decoded bytes");

        // The second level against the reference, read from its own blocks.
        gpu::TextureData justLevel1 = decoded;
        justLevel1.bytes.assign(decoded.bytes.begin() + decoded.levels[1].offset,
                                decoded.bytes.begin() + decoded.levels[1].offset +
                                    decoded.levels[1].size);
        std::string why;
        const bool levelMatches = MatchesReference(justLevel1,
                                                  std::vector<uint8_t>(blocks.begin() + 4 * blockBytes,
                                                                       blocks.end()),
                                                  20, 4, 4, why);
        Check(levelMatches, "level 1 decodes from its own blocks: " + why);
    }

    // A payload one byte short is a compressed texture the caller has not
    // finished reading, not a texture to decode with the last byte guessed.
    void IncompleteDataFails()
    {
        std::vector<uint8_t> blocks(16 * 2 * 2 - 1, 0x5A);
        gpu::TextureData decoded;
        int vulkanFormat = 0;
        const bool ok = vk::bc::Decompress(SingleLevel(20, 8, 8, blocks), 20, decoded, vulkanFormat);
        Check(!ok, "a short compressed payload fails rather than decoding");
        Check(!decoded.ok, "a failed decode does not claim success");
        Check(decoded.error != nullptr, "a failed decode says why");
    }

    void UnsupportedFormatsAreRefused()
    {
        const uint32_t notBlockCompressed[] = {6, 2, 17, 48, 60, 0};
        for (uint32_t format : notBlockCompressed)
        {
            gpu::TextureData decoded;
            int vulkanFormat = 0;
            Check(!vk::bc::Decompress(SingleLevel(6, 4, 4, std::vector<uint8_t>(16, 0)), format,
                                      decoded, vulkanFormat),
                  "format " + std::to_string(format) + " is not decoded as a BC format");
            Check(!vk::bc::IsBCFormat(format),
                  "format " + std::to_string(format) + " is not reported as BC");
        }
        for (uint32_t format : kFormats)
            Check(vk::bc::IsBCFormat(format),
                  "format " + std::to_string(format) + " is reported as BC");
    }

    // A zero block size is what a format table with a hole in it returns; it
    // must be refused before any division or buffer arithmetic uses it.
    void ZeroBlockSizeIsRefused()
    {
        gpu::TextureData source = SingleLevel(20, 4, 4, std::vector<uint8_t>(16, 0));
        source.bytesPerBlock = 0;
        gpu::TextureData decoded;
        int vulkanFormat = 0;
        Check(!vk::bc::Decompress(source, 20, decoded, vulkanFormat),
              "a zero compressed block size is refused");
    }
}

// The decoder writes into the caller's own bytes, which is what lets the cache
// hand the same object back and keep the buffer: worth 40% of a 2048x2048
// decode, and only safe if a reused buffer changes nothing and a smaller image
// leaves none of the larger one behind it.
void DecodingIntoTheSameObjectReusesTheBuffer()
{
    const uint32_t format = 20; // DXT5, sixteen bytes a block
    Rng rng(4711);
    auto Blocks = [&rng](uint32_t width, uint32_t height)
    {
        std::vector<uint8_t> blocks(size_t((width + 3) / 4) * ((height + 3) / 4) * 16);
        for (uint8_t& byte : blocks) byte = rng.Byte();
        return blocks;
    };

    const std::vector<uint8_t> first = Blocks(8, 8);
    const std::vector<uint8_t> other = Blocks(8, 8);

    gpu::TextureData dst;
    int vulkanFormat = 0;
    Check(vk::bc::Decompress(SingleLevel(format, 8, 8, first), format, dst, vulkanFormat),
          "the first decode into an empty object works");
    Check(dst.bytes.size() == 8 * 8 * 4, "the first decode is the size of its image");
    const std::vector<uint8_t> wanted = dst.bytes;

    // Another texture through the same object, then the first one again: the
    // second decode reuses the buffer the first allocated.
    Check(vk::bc::Decompress(SingleLevel(format, 8, 8, other), format, dst, vulkanFormat),
          "a second decode into the same object works");
    Check(vk::bc::Decompress(SingleLevel(format, 8, 8, first), format, dst, vulkanFormat),
          "a third decode into the same object works");
    Check(dst.bytes == wanted,
          "decoding into a reused buffer gives what a fresh one gave");

    // A smaller image into the same object: what the upload copies is exactly
    // this size, so nothing of the larger image may survive.
    const std::vector<uint8_t> small = Blocks(4, 4);
    Check(vk::bc::Decompress(SingleLevel(format, 4, 4, small), format, dst, vulkanFormat),
          "a smaller decode into the same object works");
    Check(dst.bytes.size() == 4 * 4 * 4,
          "a smaller decode leaves its own size, not the larger image's");
    std::string why;
    const bool matches = MatchesReference(dst, small, format, 4, 4, why);
    Check(matches, "a smaller decode into a reused buffer is still right: " + why);
}

int main()
{
    RandomBlocksMatchTheReference();
    Bc1ThreeColorModeIsTransparent();
    Bc2AlwaysHasFourColors();
    Bc3AlphaModes();
    Bc5HasTwoChannels();
    MipLevelsDecodeSeparately();
    IncompleteDataFails();
    UnsupportedFormatsAreRefused();
    ZeroBlockSizeIsRefused();
    DecodingIntoTheSameObjectReusesTheBuffer();

    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
