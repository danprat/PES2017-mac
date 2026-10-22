# Pillar 3: Adaptive Memory Budgeting & LMK-Safe Stability

## Overview
Android devices run under tight unified memory constraints. System RAM is shared simultaneously between the CPU, the GPU (Vulkan allocations), the display server (SurfaceFlinger), and background OS daemons.

The Android **Low Memory Killer Daemon (LMKD)** will terminate any process that approaches device out-of-memory limits. For guaranteed stability across 4 GB and 6 GB devices, the game's total resident set size (RSS) must stay **strictly below 1.0 GB RAM**.

---

## Technical Solutions

### 1. 128 MB Active Texture Cache with Dynamic 2-Pass Eviction
* Xbox 360 titles frequently stream textures in and out of GPU memory.
* In `runtime/gpu/vulkan/texture_cache.cpp`:
  - Active texture memory is tracked continuously against a strict 128 MB threshold (`kDefaultMemoryBudgetBytes = 128 * 1024 * 1024`).
  - Allocation occurs in discrete 16 MB chunk blocks (`kBlockBytes = 16 * 1024 * 1024`).
  - When memory exceeds 128 MB:
    - **Pass 1**: Evict all textures that have not been bound in the last 120 frames (2 seconds).
    - **Pass 2 (High Pressure)**: Evict textures not bound in the current frame until usage drops below 96 MB.

### 2. 16 KB Memory Page Kernel Compatibility
Android 14 and Android 15 introduce support for 16 KB physical memory page sizes (replacing the traditional 4 KB page size).
- All native memory allocations, mmap mappings, and guest physical address space reservations must be aligned to 16,384 bytes (`0x4000`).
- Builds compiled with `-Wl,-z,max-page-size=16384` ensure seamless compatibility on Google Pixel 8/9 and newer flagships.

