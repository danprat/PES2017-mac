# Master Roadmap: Native 60 FPS ARM64 Android Port (Vulkan 1.0 or above)

This roadmap outlines the complete architecture, engineering milestones, and phase-by-phase implementation plan to achieve a locked **60 FPS native ARM64 Android port** targeting **Vulkan 1.0 or above** (supporting legacy Android devices with only Vulkan 1.0 core) for *Call of Duty: Modern Warfare 2 (2009)* on [OpenPort-Labs/mw2-android](https://github.com/OpenPort-Labs/mw2-android).

---

## Architecture Overview

```
                               ┌──────────────────────────────────────────────────────────┐
                               │           MW2 Android Native Runtime (ARM64)             │
                               └──────────────────────────────────────────────────────────┘
                                                             │
                  ┌──────────────────────┬───────────────────┴───────────────────┬──────────────────────┐
                  ▼                      ▼                                       ▼                      ▼
        ┌───────────────────┐  ┌───────────────────┐                   ┌───────────────────┐  ┌───────────────────┐
        │     Pillar 1      │  │     Pillar 2      │                   │     Pillar 3      │  │     Pillar 4      │
        │ CPU Affinity &    │  │ Tile-Based Vulkan │                   │ Memory Budget &   │  │ Offline Bots &    │
        │ SoC Scheduler     │  │ Mobile Pipeline   │                   │ LMK Safety        │  │ Secure Netcode    │
        └───────────────────┘  └───────────────────┘                   └───────────────────┘  └───────────────────┘
```

---

## The Four Core Engineering Pillars

### [Pillar 1: ARM64 CPU Thread Affinity & Dynamic SoC Scheduler](pillar-1-cpu-affinity.md)
* **Objective**: Prevent the Android Linux kernel scheduler from migrating critical execution threads to low-clock efficiency cores.
* **Key Components**:
  - CPU topology detection via `/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq`.
  - Core pinning via `pthread_setaffinity_np` for Prime (Core 7), Performance (Cores 5-6), and Audio/Warmup (Cores 2-4).
  - Integration with Android NDK native worker threads.

### [Pillar 2: Tile-Based Vulkan Mobile Pipeline & Shaders](pillar-2-vulkan-mobile-pipeline.md)
* **Objective**: Eliminate GPU memory bandwidth bottlenecks, prevent thermal throttling, and fix Adreno/Mali rendering artifacts (black skybox/terrain).
* **Key Components**:
  - TBDR optimization: Set `VK_ATTACHMENT_STORE_OP_DONT_CARE` on transient depth/stencil targets.
  - Multi-tier shader warmup with persistent disk serialization (`shader_cache.bin`).
  - Correct cubemap sampling wrap mode (`VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE`) and BC5 / DXN normal map reconstruction ($Z = \sqrt{1 - X^2 - Y^2}$).
  - Hardware BC decompressor activation for Adreno (`vendorID == 0x5143`) and SIMD-optimized software fallback for Mali.

### [Pillar 3: Adaptive Memory Budgeting & LMK-Safe Stability](pillar-3-memory-lmk-budgeting.md)
* **Objective**: Guarantee rock-solid runtime stability with total application memory usage strictly bounded below 1.0 GB RSS on unified mobile RAM.
* **Key Components**:
  - 128 MB active texture cache with 2-pass dynamic LRU eviction (`kBlockBytes = 16 MB`).
  - Full 16 KB memory page alignment compatibility for Android 14/15.
  - Cutscene Bink video memory streaming bounds (<15 MB heap).

### [Pillar 4: Offline Bot Warfare & Secured Netcode](pillar-4-offline-bots-and-netcode.md)
* **Objective**: Enable full offline multiplayer gameplay with AI bots anywhere without internet, and harden network sockets against legacy 2009 RCE vulnerabilities.
* **Key Components**:
  - GSC script injection engine mounting Bot Warfare AI scripts from `iw4x-rawfiles`.
  - Packet validation and buffer overflow patches in connectionless packets and string tokenizers from `iw4x-client`.
  - Multi-touch virtual controls and gyroscope look aiming integration.

---

## Phase Execution Plan

| Phase | Pillar | Description | Primary Targets |
| :---: | :---: | :--- | :--- |
| **Phase 1** | **Pillar 1** | CPU Topology Discovery & Prime Core Thread Affinity | `runtime/thread.cpp`, `android/app/src/main/cpp/` |
| **Phase 2** | **Pillar 2** | Mobile TBDR RenderPass `DONT_CARE` Ops & Skybox/Normal Fixes | `runtime/gpu/vulkan/renderer_pipelines.cpp`, `texture_cache.cpp` |
| **Phase 3** | **Pillar 3** | 128 MB LMK-Safe Dynamic Eviction & Memory Tracking | `runtime/gpu/vulkan/renderer_arena.cpp`, `texture_cache.cpp` |
| **Phase 4** | **Pillar 4** | Bot Warfare GSC Injection & Netcode Packet Hardening | `runtime/network/`, `runtime/vfs/`, `docs/multiplayer.md` |
