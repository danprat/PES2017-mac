// Temporary probes for porting PES 2017: which of the title's named procedures
// run, and in what order. sub_82F00CE8 takes the procedure's name (an MSVC
// std::string at r5) and, for "ProcExit", sets the flag that ends the main loop
// (byte [*(0x83F862D4) + 60], read by sub_8259B208).
#include <ppc_recomp_shared.h>
#include "title.h"
#include "guest.h"
#include "log.h"
#include "crash.h"
#include "kernel/kernel.h"
#include "platform.h"
#include <atomic>
#include <cstring>
#include <cmath>
#include <string>
#include <chrono>
#include "gpu/gpu.h"

namespace
{
    // MSVC's std::string: 16 bytes of inline buffer, size at +16, capacity at
    // +20; past 15 characters the first word points at the heap copy.
    std::string GuestStdString(uint32_t address)
    {
        if (!address) return {};
        const uint32_t size = *GuestPtr<be32>(address + 16), capacity = *GuestPtr<be32>(address + 20);
        if (size > 256) return "<odd size>";
        const uint32_t data = capacity >= 16 ? uint32_t(*GuestPtr<be32>(address)) : address;
        return std::string(reinterpret_cast<const char*>(guest::Base() + data), size);
    }
}





