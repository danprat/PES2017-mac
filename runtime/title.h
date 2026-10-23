#pragma once
// The guest addresses the runtime names for PES 2017 (default.xex, Europe, title
// update 0). The runtime hooks the title's own functions by address; a hook
// whose address is not defined here is compiled out, and the generic kernel,
// GPU and audio layers run without it.
//
// Located in the decoded image (pes/default.pe) with tools/find_in_title.py.
// A function entry is the bare hex address, without 0x, so GUEST_HOOK can paste
// it onto sub_ / __imp__sub_ / 0x.

#define PES17_TITLE_NAME  "PES 2017"
#define T_ENTRY_POINT   0x82416708u          // the XEX header's ENTRY_POINT

// ---- still to be located (see docs/PORTING.md) -----------------------------
// D3D9 (statically linked): the arena wait and the shader-object initialisers.
// Present is sub_823F98E0 = D3D's swap (device, front buffer texture, params);
// the render thread's swap command (sub_83861FA0) calls it, and it ends in the
// VdSwap path. Its device offsets (present interval 13596 etc.) are MW2's and
// are NOT valid for PES: with a 60 -> 30 pacing change no device field differs.
#define T_D3D_Present          823F98E0
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

// The title's 16:9 aspect, as floats it loads (lfs) when a camera is made: the
// first sits next to 4/3 and the 34.1/52.6 degree FOVs and is copied into the
// camera objects (sub_828F1BC8, sub_834C5168, sub_83568020, ...); the second
// follows the far (1000) and near (5) planes of sub_83B51BE0's projection.
// PES17_ASPECT writes the screen's own aspect over both (main.cpp).
#define T_DATA_Aspect16x9      0x82042C08u
#define T_DATA_Aspect16x9b     0x8234808Cu

// Hooking a recompiled function by address: GUEST_HOOK(T_x) { ... GUEST_ORIG(T_x)(ctx, base); }
#define PES17_CAT_(a, b) a##b
#define PES17_CAT(a, b) PES17_CAT_(a, b)
#define PES17_STR_(x) #x
#define PES17_STR(x) PES17_STR_(x)
#define GUEST_FUNC(name) PES17_CAT(sub_, name)          // the recompiled function
#define GUEST_ORIG(name) PES17_CAT(__imp__sub_, name)   // the original, once the function is hooked
#define GUEST_ADDR(name) PES17_CAT(0x, name)            // its guest address
#define GUEST_NAME(name) "sub_" PES17_STR(name)         // its name, for a log line
#define GUEST_HOOK(name) PPC_FUNC_IMPL(GUEST_ORIG(name)); PPC_FUNC(GUEST_FUNC(name))
