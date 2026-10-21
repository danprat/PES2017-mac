#pragma once
// The guest addresses the runtime names for PES 2017 (default.xex, Europe, title
// update 0). The runtime hooks the title's own functions by address; a hook
// whose address is not defined here is compiled out, and the generic kernel,
// GPU and audio layers run without it.
//
// Located in the decoded image (pes/default.pe) with tools/find_in_title.py.
// A function entry is the bare hex address, without 0x, so GUEST_HOOK can paste
// it onto sub_ / __imp__sub_ / 0x.

#define MW2_TITLE_NAME  "PES 2017"
#define T_ENTRY_POINT   0x82416708u          // the XEX header's ENTRY_POINT

// ---- still to be located (see docs/PORTING.md) -----------------------------
// D3D9 (statically linked): Present, the arena wait and the shader-object
// initialisers. Until the first is found the frame is retired from the
// kernel's VdSwap path instead.
// #define T_D3D_Present          ........
// #define T_D3D_ArenaWait        ........

// Data the diagnostics read; zero means "not derived for this title".
#define T_DATA_DeviceTable     0u
#define T_DATA_ClientStates    0u
#define T_CLIENT_VALID         0u
#define T_CLIENT_ORIGIN        0u
#define T_CLIENT_ANGLES        0u

// Import records of the data variables the runtime fills in (kernel.cpp): the
// word at this address is the XEX import record (0x0001<ordinal>) until the
// runtime replaces it with a pointer. Found by parsing the XEX import table.
#define T_DATA_TimeStampBundlePtr  0x82000720u   // KeTimeStampBundle, ordinal 0xAD
#define T_DATA_DebugMonitorPtr     0x82000654u   // KeDebugMonitorData, ordinal 0x59

// D3D9's wait for the GPU to pass a fence: (device, fence, flags, ...). It spins
// until the word the device's +11024 points at -- written by the command
// processor's end-of-pipe EVENT_WRITE_SHD -- reaches the fence; +11036 is the
// last fence issued. Found from the main thread stalled in it (d3d_hooks.cpp).
#define T_D3D_BlockOnFence     823F70F8

// Hooking a recompiled function by address: GUEST_HOOK(T_x) { ... GUEST_ORIG(T_x)(ctx, base); }
#define MW2_CAT_(a, b) a##b
#define MW2_CAT(a, b) MW2_CAT_(a, b)
#define MW2_STR_(x) #x
#define MW2_STR(x) MW2_STR_(x)
#define GUEST_FUNC(name) MW2_CAT(sub_, name)          // the recompiled function
#define GUEST_ORIG(name) MW2_CAT(__imp__sub_, name)   // the original, once the function is hooked
#define GUEST_ADDR(name) MW2_CAT(0x, name)            // its guest address
#define GUEST_NAME(name) "sub_" MW2_STR(name)         // its name, for a log line
#define GUEST_HOOK(name) PPC_FUNC_IMPL(GUEST_ORIG(name)); PPC_FUNC(GUEST_FUNC(name))
