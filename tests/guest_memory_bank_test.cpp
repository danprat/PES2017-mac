// Verifies the 512MB physical memory bank aliasing mechanism used on POSIX and macOS.
//
// Xbox 360 physical RAM (512 MB) is mirrored across three windows:
//   - 0x80000000 (Cached physical)
//   - 0xA0000000 (Uncached physical)
//   - 0xC0000000 (Physical aperture)
//
// On macOS / Darwin, SYS_memfd_create is unavailable, so OpenBankDescriptor()
// uses an unlinked temporary file descriptor with ftruncate(fd, 512MB) and mmap(MAP_SHARED).
// This test asserts that writes to any window are coherently visible across all three windows.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cassert>

#ifndef _WIN32
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <climits>
#include <string>

#ifndef MAP_NORESERVE
#define MAP_NORESERVE 0
#endif

namespace
{
    int g_failures = 0;
    int g_checks = 0;

    void Check(bool ok, const char* what)
    {
        g_checks++;
        if (ok) return;
        g_failures++;
        std::fprintf(stderr, "FAIL: %s\n", what);
    }

    // Opens an unlinked descriptor for the 512MB physical bank
    int CreateTestBankDescriptor()
    {
        const char* tmpDir = std::getenv("TMPDIR");
        if (!tmpDir || !*tmpDir) tmpDir = "/tmp";
        char path[PATH_MAX];
        std::snprintf(path, sizeof(path), "%s/pes17-test-bank.XXXXXX", tmpDir);
        const int fd = mkstemp(path);
        if (fd >= 0)
        {
            // Immediately unlink: verifies the file vanishes from directory
            unlink(path);
            return fd;
        }
        return -1;
    }
}

int main()
{
    std::printf("Testing macOS / POSIX guest physical memory bank aliasing...\n");

    const size_t bankSize = 512 * 1024 * 1024; // 512 MB
    const int fd = CreateTestBankDescriptor();
    Check(fd >= 0, "CreateTestBankDescriptor creates valid descriptor");

    if (fd < 0)
    {
        std::fprintf(stderr, "Fatal: unable to create test descriptor\n");
        return 1;
    }

    // Allocate sparse 512MB
    const int truncRes = ftruncate(fd, off_t(bankSize));
    Check(truncRes == 0, "ftruncate to 512MB succeeds");

    // Map three separate windows sharing the same backing store
    uint8_t* winCached = static_cast<uint8_t*>(mmap(nullptr, bankSize, PROT_READ | PROT_WRITE,
                                                    MAP_SHARED | MAP_NORESERVE, fd, 0));
    uint8_t* winUncached = static_cast<uint8_t*>(mmap(nullptr, bankSize, PROT_READ | PROT_WRITE,
                                                      MAP_SHARED | MAP_NORESERVE, fd, 0));
    uint8_t* winAperture = static_cast<uint8_t*>(mmap(nullptr, bankSize, PROT_READ | PROT_WRITE,
                                                      MAP_SHARED | MAP_NORESERVE, fd, 0));

    Check(winCached != MAP_FAILED, "mmap winCached succeeds");
    Check(winUncached != MAP_FAILED, "mmap winUncached succeeds");
    Check(winAperture != MAP_FAILED, "mmap winAperture succeeds");

    // The descriptor can be closed now; mappings keep the memory active
    close(fd);

    if (winCached != MAP_FAILED && winUncached != MAP_FAILED && winAperture != MAP_FAILED)
    {
        // Test offsets across the entire 512MB span
        const size_t offsets[] = {
            0,
            4096,               // page 1
            64 * 1024,          // 64 KB
            1024 * 1024,        // 1 MB
            128 * 1024 * 1024,  // 128 MB
            256 * 1024 * 1024,  // 256 MB
            bankSize - 8        // End of 512MB bank
        };

        for (size_t off : offsets)
        {
            const uint64_t magic = 0x5045533137584558ull ^ off; // "PES17XEX" ^ offset

            // 1. Write to winCached, verify in winUncached and winAperture
            *reinterpret_cast<volatile uint64_t*>(winCached + off) = magic;
            const uint64_t valUncached = *reinterpret_cast<volatile uint64_t*>(winUncached + off);
            const uint64_t valAperture = *reinterpret_cast<volatile uint64_t*>(winAperture + off);

            Check(valUncached == magic, "winUncached reflects write to winCached");
            Check(valAperture == magic, "winAperture reflects write to winCached");

            // 2. Write to winAperture, verify in winCached and winUncached
            const uint64_t magic2 = magic ^ 0xAA55AA55AA55AA55ull;
            *reinterpret_cast<volatile uint64_t*>(winAperture + off) = magic2;
            Check(*reinterpret_cast<volatile uint64_t*>(winCached + off) == magic2,
                  "winCached reflects write to winAperture");
            Check(*reinterpret_cast<volatile uint64_t*>(winUncached + off) == magic2,
                  "winUncached reflects write to winAperture");
        }

        // Clean up
        munmap(winCached, bankSize);
        munmap(winUncached, bankSize);
        munmap(winAperture, bankSize);
    }

    std::printf("Guest memory bank test completed: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
#else
int main()
{
    return 0;
}
#endif
