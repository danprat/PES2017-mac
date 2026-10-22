# Master Roadmap: Native 60 FPS ARM64 Android Port (Vulkan 1.0 or above)

This roadmap outlines the complete architecture, engineering milestones, and phase-by-phase implementation plan to achieve a locked **60 FPS native ARM64 Android port** targeting **Vulkan 1.0 or above** (supporting legacy Android devices with only Vulkan 1.0 core) for *Pro Evolution Soccer 2017* on [OpenPort-Labs/pes17-android](https://github.com/OpenPort-Labs/pes17-android).

---

## Architecture Overview

```
     ┌──────────────────────────────────────────────────────────┐
     │        PES 2017 Android Native Runtime (ARM64)           │
     └──────────────────────────────────────────────────────────┘
                                │
          ┌─────────────────────┼─────────────────────┐
          ▼                     ▼                     ▼
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│     Pillar 1      │ │     Pillar 2      │ │     Pillar 3      │
│ CPU Affinity &    │ │ Tile-Based Vulkan │ │ Memory Budget &   │
│ SoC Scheduler     │ │ Mobile Pipeline   │ │ LMK Safety        │
└───────────────────┘ └───────────────────┘ └───────────────────┘
```

---

## The Three Core Engineering Pillars

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

---

## Phase Execution Plan

| Phase | Pillar | Description | Primary Targets |
| :---: | :---: | :--- | :--- |
| **Phase 1** | **Pillar 1** | CPU Topology Discovery & Prime Core Thread Affinity | `runtime/thread.cpp`, `android/app/src/main/cpp/` |
| **Phase 2** | **Pillar 2** | Mobile TBDR RenderPass `DONT_CARE` Ops & Skybox/Normal Fixes | `runtime/gpu/vulkan/renderer_pipelines.cpp`, `texture_cache.cpp` |
| **Phase 3** | **Pillar 3** | 128 MB LMK-Safe Dynamic Eviction & Memory Tracking | `runtime/gpu/vulkan/renderer_arena.cpp`, `texture_cache.cpp` |
