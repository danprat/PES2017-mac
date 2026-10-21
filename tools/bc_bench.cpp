// How long one 2048x2048 software block-compressed decode takes, per format.
//
// The decoder (runtime/gpu/vulkan/bc_decoder.cpp) runs on every texture a Mali
// or Adreno device uploads -- the path the Adreno workaround puts everything
// through -- so its inner loops are worth a number rather than an opinion. This
// prints one: the time of one decode of a full-size texture, in each format the
// decoder answers for, with the same output buffer reused as the runtime reuses
// its decode scratch, so what is timed is the decode and not the allocation.
//
//   cmake --build build --target bc-bench && ./build/bc-bench [size] [runs]
//
// The payload is generated from a fixed seed and the fastest run is reported,
// so two runs of the same build agree and a change can be compared with the
// one before it. tests/bc_decoder_test.cpp is what says the output is right;
// this says only how long it took.
#include "gpu/vulkan/bc_decoder.h"
#include "gpu/texture.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace
{
    // The same generator the decoder's test uses: a run that cannot be repeated
    // is not worth the line it prints.
    struct Rng
    {
        uint32_t state;
        explicit Rng(uint32_t seed) : state(seed) {}
        uint32_t Next() { state = state * 1664525u + 1013904223u; return state; }
        uint8_t Byte() { return uint8_t(Next() >> 24); }
    };

    struct Case
    {
        const char* name;
        uint32_t format;        // the guest format, as a fetch constant names it
        size_t blockBytes;
        size_t outBytes;        // per pixel, so the rate means something
    };

    // What each format decodes to: the same bytes per pixel the decoder's own
    // switch gives VK_FORMAT_R8G8B8A8_UNORM, R8G8_UNORM and R8_UNORM.
    const Case kCases[] = {
        { "BC1  DXT1", 18, 8, 4 },
        { "BC2  DXT3", 19, 16, 4 },
        { "BC3  DXT5", 20, 16, 4 },
        { "BC4  DXT5A", 59, 8, 1 },
        { "BC5  DXN", 49, 16, 2 },
    };

    double Best(uint32_t format, uint32_t width, uint32_t height, size_t blockBytes, int runs)
    {
        const uint32_t blocksWide = (width + 3) / 4, blocksHigh = (height + 3) / 4;
        Rng rng(0x1234u + format);

        gpu::TextureData src;
        src.width = width;
        src.height = height;
        src.blocksWide = blocksWide;
        src.blocksHigh = blocksHigh;
        src.bytesPerBlock = blockBytes;
        src.layers = 1;
        src.bytes.resize(size_t(blocksWide) * blocksHigh * blockBytes);
        for (uint8_t& byte : src.bytes) byte = rng.Byte();

        gpu::TextureData dst;
        int outFormat = 0;
        if (!vk::bc::Decompress(src, format, dst, outFormat)) return -1.0;   // sizes the buffer once

        double best = -1.0;
        for (int i = 0; i < runs; i++)
        {
            const auto started = std::chrono::steady_clock::now();
            if (!vk::bc::Decompress(src, format, dst, outFormat)) return -1.0;
            const double ms = std::chrono::duration<double, std::milli>(
                                  std::chrono::steady_clock::now() - started).count();
            if (best < 0 || ms < best) best = ms;
        }
        return best;
    }
}

int main(int argc, char** argv)
{
    const uint32_t size = argc > 1 ? uint32_t(std::atoi(argv[1])) : 2048;
    const int runs = argc > 2 ? std::atoi(argv[2]) : 12;
    if (size < 4) { std::fprintf(stderr, "size must be at least 4\n"); return 2; }

    std::printf("%ux%u, best of %d runs\n\n", size, size, runs);
    std::printf("%-10s %8s %10s %9s %10s\n", "format", "block", "output ms", "MB/s in", "MB/s out");
    for (const Case& c : kCases)
    {
        const double ms = Best(c.format, size, size, c.blockBytes, runs);
        if (ms < 0)
        {
            std::fprintf(stderr, "%s: decoding failed\n", c.name);
            return 1;
        }
        const double inMB = double(size_t(size) * size / 16 * c.blockBytes) / (1024.0 * 1024.0);
        const double outMB = double(size_t(size) * size * c.outBytes) / (1024.0 * 1024.0);
        std::printf("%-10s %6zu B %9.2f ms %9.0f %10.0f\n", c.name, c.blockBytes, ms,
                    inMB / (ms / 1000.0), outMB / (ms / 1000.0));
    }
    return 0;
}
