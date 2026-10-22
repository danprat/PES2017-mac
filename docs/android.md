# Android Port Documentation

This document describes the architecture, hardware compatibility, build pipeline, and runtime configuration for running **Modern Warfare 2 (2009)** natively on Android.

---

## 1. Architecture Overview

Rather than running through a traditional emulator (which introduces heavy instruction translation overhead), the Android port uses ahead-of-time compiled C++ generated directly from the Xbox 360 executable:

```
Xbox 360 default.xex  --->  XenonRecomp  --->  Recompiled C++ (ppc/)
                                                     |
                                            Android NDK (Clang 18)
                                                     |
                                                libmw2.so
                                                     |
               +-------------------------------------+------------------------------------+
               |                                                                          |
    Launcher Process (UI)                                                      Game Process (:game)
  - MainActivity.kt (Kotlin)                                                 - GameActivity.kt
  - Disc discovery & installation                                            - Native Vulkan ANativeWindow
  - Custom driver selection (Turnip)                                         - Dedicated game worker thread
  - Global preferences                                                       - Low-latency AAudio engine
                                                                             - Virtual touch gamepad overlay
```

### Dual-Process Isolation
The app is structured into two separate processes in the Android manifest:
1. **The Launcher Process** (`com.mw2.recomp.sp`): Renders the setup, preferences, driver installer, and log viewer. It stays alive independently of the game run.
2. **The Game Process** (`com.mw2.recomp.sp:game`): Hosts the recompiled guest runtime and Vulkan presentation context. Because guest Xbox 360 threads cannot be gracefully unwound mid-frame without risking driver faults, exiting the game terminates the `:game` process cleanly without crashing the launcher.

---

## 2. Hardware Compatibility & GPU Requirements

### System Requirements
- **Architecture**: 64-bit ARM (`arm64-v8a`). 32-bit devices are strictly unsupported due to the guest's 4 GiB virtual address space reservation.
- **Operating System**: Android 10 or later (API level 29+). Fully compatible with 16 KB memory page kernels on Android 14 and 15.
- **RAM**: Minimum 4 GB RAM (6 GB+ recommended).
- **Storage**: ~7-8 GB free internal storage for game assets.

### GPU & Vulkan Driver Requirements
The custom Vulkan pipeline renderer requires:
- **Vulkan 1.3** core support, OR
- **Vulkan 1.1 / 1.2** with both `VK_KHR_dynamic_rendering` and `VK_EXT_extended_dynamic_state` extensions.

#### Compatibility by SoC / GPU Architecture

| SoC Family | GPU Architecture | Compatibility Status | Notes |
| **Qualcomm Snapdragon (Flagship & Mid-Range)** | Adreno 6xx, 7xx (SD 865–8 Gen 3, **SD 778G / 778G+**, 782G, 7 Gen 1/2/3, 7+ Gen 2/3) | **Supported (100% Native)** | Vulkan 1.3 supported out of the box via stock drivers or sideloadable Mesa **Turnip** drivers (`Adreno 642L` on 778G+ has complete Turnip support). Solid 60 FPS at 720p/1080p. |
| **Qualcomm Snapdragon (Entry Mid-Range)** | Adreno 619, 710 (SD 695, SD 6 Gen 1, SD 4 Gen 2) | **Supported (30–60 FPS)** | Supports Turnip and stock Vulkan 1.1/1.3. Playable with 60%–75% resolution scale. |
| **Google Tensor** | Mali-G78, Mali-G710, Immortalis-G715 (Pixel 6, 7, 8, 9) | **Supported (100%)** | Google ships native Vulkan 1.3 drivers on Android 13/14+. |
| **Samsung Exynos** | AMD RDNA2 / RDNA3 Xclipse (Exynos 2200, 2400) | **Supported (100%)** | Native Vulkan 1.3 driver support. |
| **MediaTek Dimensity (Flagship)** | Mali-G710, Immortalis-G720 (Dimensity 8100, 8200, 9000, 9200, 9300) | **Supported (100%)** | Native Vulkan 1.3 driver support. |
| **MediaTek Dimensity (Mid-Range)** | Mali-G57, Mali-G68 (Dimensity 700, 810, 920, 1080, 6080, 7050) | **Supported (100% Playable)** | Fully supported via dedicated Vulkan 1.1 `VkRenderPass` legacy mode (`runtime/gpu/vulkan/render_pass.cpp`) with non-blocking shader warmup, bypassing OEM lack of `VK_KHR_dynamic_rendering`. |
| **MediaTek Helio (Budget)** | Mali-G52, Mali-G57 MC2, Mali-G76 (Helio G99, G96, G95, G88) | **Supported (Playable 30–60 FPS)** | Supported via Vulkan 1.1 `VkRenderPass` fallback + CPU BC1–BC5 texture decompressor. Playable at 540p–720p 60% scale. |

---

## 3. SoC Tuning & Performance Optimization

Modern mobile SoCs use heterogeneous CPU clusters (e.g., 1 Prime + 3 Gold + 4 Silver, or 2+2+4 on Tensor). Left to the default OS scheduler, critical guest threads can be scheduled onto low-frequency efficiency cores.

### Core Affinity (`runtime/android/perf.cpp`)
- At startup, the runtime queries `/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq` to identify the fastest CPU cores.
- Guest execution threads and the Vulkan renderer thread are pinned to performance and prime clusters using `sched_setaffinity`.
- Efficiency cores (Cortex-A55 / A510) are reserved for background OS services and audio downmix processing.

### Dynamic Memory Management & Texture Budget
- **Device-Aware Defaults** (`ApplyMemoryDefaults`, `runtime/android/perf.cpp`): on Unified Memory Architecture the CPU and GPU share one pool, and the desktop defaults are sized for a machine with a separate one. Each default is taken from the memory this phone has, and each is set with overwrite off, so the launcher's own setting or a variable already in the environment wins:
  - **Texture budget**: a sixth of the device's memory, floor **128 MB**, capped at 1 GB and 1.5 GB at 12 GB — not the desktop "half of device-local RAM", which on a 6 GB phone is most of the phone. RSS stays in the low hundreds of megabytes in active gameplay.
  - **Upload arena** (`MW2_ARENA_MB`): committed up front, so **384 MB** at 8 GB and up, **256 MB** at 6 GB, **192 MB** below. The arena has a floor — a frame that runs out of its share draws nothing from the point it ran out — so unlike the shadow it is not taken below what a heavy frame needs.
  - **Guest-memory shadow** (`MW2_NO_SHADOW`): 512 MB behind the arena, in the same buffer, and a cache rather than a requirement — without it a draw copies its vertex data again, which is slower and nothing else. On a phone of **6 GB or less** the runtime does without, so nothing asks for a gigabyte before the first frame is drawn.
- **16 MB Memory Slabs (`image_memory.h`)**: Desktop builds allocate texture images in 64 MB blocks (`kBlockBytes`). On Android, block size is reduced to **16 MB** (`16ull << 20`) to eliminate oversized allocations, minimize heap fragmentation, and reduce virtual memory address space pressure.
- **Two-Pass LMK-Safe Eviction Engine**:
  - The cache inspection interval runs every 32 frames (reduced from 64) with an idle threshold `kUnusedFrames = 120` (2 seconds of inactivity).
  - **Pass 1 (Normal Sweep)**: Evicts textures that have been idle and unbound beyond the grace window down to 75% of budget.
  - **Pass 2 (Emergency Sweep)**: If streaming bursts still exceed the target threshold, an emergency pass evicts textures unbound for just 16 frames (outside the active GPU ring buffer depth). This prevents memory spikes during rapid mission transitions and high-density streaming (e.g. S.S.D.D. obstacle course).
- **`onTrimMemory` Responsive Budgeting**: When the OS sends low-memory warnings (`TRIM_MEMORY_RUNNING_LOW` or `TRIM_MEMORY_RUNNING_CRITICAL`), the texture cache automatically quarters its budget and calls `mallopt(M_PURGE, 0)` to return freed memory pages to the kernel.
- **Restoration**: When returning from background, the texture budget is dynamically restored to full capacity.

### Staying Alive in the Background (`GameService.kt`)
A run is the largest thing on the phone: the guest's 512 MB bank, the upload arena and the texture cache. Stepping out to a message stops the activity, and a stopped activity's process drops to Android's cached bucket, where it can be frozen and then killed — and the whole load starts again. `GameService` is a foreground service declared in the `:game` process with type `specialUse`, so it holds the run's process above the low-memory killer for as long as the game is up, and its notification says why it is there. (Created on Android 8+ only; Android 14 takes a foreground service only for a type the manifest names, hence `specialUse` with its subtype property.)

It does not keep the game *running* while it is away: the activity still pauses the guest when it goes off screen (`nativeSetPaused`). Nor does it license holding memory the system wants back — `onTrimMemory` still quarters the texture cache under pressure and `onResume` still restores it, service or no service.

### Mobile GPU Compatibility & Decompression
- **Zero-Copy BC1–BC5 CPU Software Decoder**: Mobile GPUs such as ARM Mali lack hardware BC/DXT block compression support. The runtime includes an optimized CPU decompressor (`runtime/gpu/vulkan/bc_decoder.cpp`) utilizing direct 32-bit and 64-bit aligned word writes, eliminating per-block `std::memcpy` call overhead. It decompresses BC1/BC2/BC3/BC5 into uncompressed RGBA8/RG8 buffers while calculating dirty checksums on original guest bytes to avoid infinite re-staging loops.
- **Silhouette & Normal Map Lighting Fix**: Unbound fallback samplers are seeded with neutral opaque white texels (`(255, 255, 255, 255)`) rather than transparent black (`(0, 0, 0, 0)`), preventing dark silhouette artifacts on character models, gear, weapons, and foreground geometry when ambient or lighting tables are streaming in. DXN / BC5 two-channel normal maps are appropriately swizzled to match mobile fragment pipelines.

---

## 4. Persistent Vulkan Pipeline & Shader Caching

Compiling SPIR-V shaders and graphics pipelines on mobile drivers causes noticeable in-game frame micro-stutters. The Android port implements a multi-tier caching and non-blocking warmup architecture:

- **Location**: Shader microcode recipes and driver binary pipeline caches are persisted in app-specific external files storage:
  `/sdcard/Android/data/com.mw2.recomp.sp/files/shader_cache.bin`
- **Instant Launcher-to-Title Boot**:
  On startup, `PrewarmFromCache()` operates under a 15-pipeline budget (or 250 ms max deadline). The initial 15 critical title-screen pipelines compile in ~200 ms, presenting the "PRESS START BUTTON" screen at locked 60 FPS within 2 seconds.
- **Background Warmup Scheduler (`warmup::Worker`)**:
  All remaining gameplay pipelines are queued into `warmup::g_warmupQueue` and compiled asynchronously on a dedicated background thread (`tid 25205`) during menus and cutscenes without dropping frame rate.
- **Auto-Flush on Pause / Lifecycle Changes**:
  Whenever the surface is destroyed, the user pauses, or memory is trimmed, `vk::pipeline::SaveCache()` commits the driver's native pipeline state blobs alongside the shader recipes.
- **Signal Safety & Crash Guarding (`runtime/crash.cpp`)**:
  Bionic libc lacks `pthread_kill` validation for arbitrary guest thread IDs. Long-running compilation stages are protected with Android-specific signal guards (`#ifndef MW2_ANDROID`), preventing spurious `SIGABRT` crashes.

---

## 5. Controls & Virtual Gamepad

### Virtual Touch Overlay (`TouchOverlayView.kt`)
The virtual gamepad converts multi-touch gestures into normalized synthetic XInput controller packets:
- **Movement (Left Stick)**: Analog thumbstick with customizable deadzone.
- **Camera Look (Right Side)**: Uses a velocity-based flick model rather than a fixed virtual stick, allowing natural, responsive camera panning.
- **Sticky ADS**: The Aim Down Sights button can be configured to toggle or hold.
- **HUD Layout Editor**: Pause the game and tap **Edit controls** to move, resize, adjust opacity, or hide any button. Layouts are saved in `filesDir/controls.json`.

### Physical Gamepads
- Bluetooth and USB gamepads (Xbox, DualShock/DualSense, Razer Kishi, Backbone) are supported.
- Enable or disable hardware gamepads in **Settings** to avoid phantom inputs from misreported phone sensor devices.

---

## 6. Custom Vulkan Drivers (Turnip & libadrenotools)

For devices with Qualcomm Adreno GPUs, Mesa **Turnip** drivers offer substantial performance and correctness advantages over outdated OEM vendor drivers.

1. Download a compatible Turnip driver archive (`.zip` containing `meta.json` and `libvulkan_freedreno.so`).
2. Open **Graphics Driver** in the launcher.
3. Tap **Import Driver** and choose the downloaded zip.
4. The runtime extracts the driver into private storage and loads it using `libadrenotools` in a dedicated linker namespace.

---

## 7. Building from Source

### Prerequisites
- **JDK 17**.
- **Android SDK** with **NDK 28.2.13676358** (`platforms;android-35`).
- CMake 3.22.1+.
- Python 3.10+.

### Local Build Steps

```sh
# 1. Recompile Xbox 360 executables to C++ on your desktop
TITLE=sp ./build.sh
TITLE=mp ./build.sh

# 2. Fetch third-party dependencies (libadrenotools)
./android/fetch_deps.sh

# 3. Compile the Campaign APK (TU0)
cd android
./gradlew assembleCampaignTu0Release

# Or compile the Multiplayer APK:
./gradlew assembleMultiplayerTu0Release

# TU6 variants append Tu6 (needs TU6 recompiled trees; CI does this):
./gradlew assembleCampaignTu6Release assembleMultiplayerTu6Release
```

The compiled APK will be located at:
- `android/app/build/outputs/apk/campaignTu0/release/*.apk`
- `android/app/build/outputs/apk/multiplayerTu0/release/*.apk`

### GitHub Actions CI
The workflow in [.github/workflows/android.yml](../.github/workflows/android.yml) automates APK builds:
1. Navigate to **Actions** → **android** → **Run workflow**.
2. Supply a direct URL to your game disc archive or executables.
3. The runner builds with `ccache` and publishes the signed APK as a build artifact.

---

## 8. Game Files & Installation Workflow

The app does not bundle game files. The player provides an Xbox 360 disc image (`.iso`, `.7z`, or `.zip` of version 1.0.557):

- **Automatic Discovery**: Placing `Call of Duty - Modern Warfare 2 (USA, Europe).iso` in `/sdcard/Download/` enables the one-tap **⚡ INSTALL & PLAY** option in the launcher.
- **Extracted Location**: The installer unpacks verified game assets into:
  `/sdcard/Android/data/com.mw2.recomp.sp/files/game/`
- **Saves Location**: Campaign and profile saves are stored in:
  `/sdcard/Android/data/com.mw2.recomp.sp/files/saves/`

---

## 9. Diagnostics & Troubleshooting

| Symptom | Cause | Solution |
| :--- | :--- | :--- |
| **"Renderer Notice: GPU lacks Vulkan 1.3..."** | Device stock driver is Vulkan 1.1 without dynamic rendering. | Check for OEM system software updates. On Adreno devices, import a Turnip driver via the Driver menu. |
| **"The runtime library would not load"** | Incompatible ABI or 32-bit device. | Ensure device supports 64-bit ARM (`arm64-v8a`). |
| **Installation fails partway** | Insufficient storage space. | Ensure at least 8 GB of free storage is available on internal storage. |
| **Log inspection** | Debugging game launch or crashes. | Inspect `/sdcard/Android/data/com.mw2.recomp.sp/files/game.log` via ADB or the in-app Log viewer. |
