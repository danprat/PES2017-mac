# Pillar 1: ARM64 CPU Thread Affinity & Dynamic SoC Scheduler

## Overview
Modern mobile processors use heterogeneous multi-core architectures (ARM big.LITTLE / DynamIQ), typically divided into three distinct CPU clusters:
1. **Prime / Super Core** (1× Cortex-X1 / X2 / X3 / X4 / X925): Highest single-core IPC and clock speed (~3.0 - 3.4 GHz).
2. **Performance / Gold Cluster** (3-5× Cortex-A78 / A715 / A720): High sustained IPC (~2.6 - 2.8 GHz).
3. **Efficiency / Silver Cluster** (2-4× Cortex-A55 / A510 / A520): Low power, low IPC (~1.8 - 2.0 GHz).

Without explicit thread affinity, the Linux CFS (Completely Fair Scheduler) and Android Energy-Aware Scheduling (EAS) will periodically migrate heavy CPU threads to efficiency cores to conserve battery, causing abrupt frame drops from 60 FPS down to 25-30 FPS.

---

## Architecture & Pinning Matrix

```
       SoC Core Map                       Assigned Engine Threads
┌───────────────────────────┐           ┌─────────────────────────────────────────┐
│ Core 7 (Prime Cortex-X)   │ <=======> │ Main Recompiled Game Loop Thread        │
├───────────────────────────┤           ├─────────────────────────────────────────┤
│ Cores 5-6 (Gold Cortex-A) │ <=======> │ Vulkan Command Recorder & Submit Thread │
├───────────────────────────┤           ├─────────────────────────────────────────┤
│ Cores 2-4 (Gold Cortex-A) │ <=======> │ Audio Engine (AAudio) & Shader Warmup   │
├───────────────────────────┤           ├─────────────────────────────────────────┤
│ Cores 0-1 (Silver A55)    │ <=======> │ OS Background Services & Logcat Only    │
└───────────────────────────┘           └─────────────────────────────────────────┘
```

---

## Implementation Details

### 1. Topology Discovery (`/sys/devices/system/cpu/`)
At runtime startup, the native engine queries:
```
/sys/devices/system/cpu/cpu{N}/cpufreq/cpuinfo_max_freq
```
The CPU cores are sorted in descending order of maximum frequency to identify:
- **`primeCoreId`**: Highest frequency core (index 0 in sorted list).
- **`performanceCoreMask`**: Mask containing the next 2-4 highest frequency cores.
- **`efficiencyCoreMask`**: Remaining cores.

### 2. Thread Affinity Binding (`sched_setaffinity`)
Each native worker thread calls a dedicated affinity binding helper upon spawning:
```cpp
void PinCurrentThreadToCores(uint32_t coreMask)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    for (int i = 0; i < 32; ++i) {
        if (coreMask & (1u << i)) {
            CPU_SET(i, &cpuset);
        }
    }
    sched_setaffinity(0, sizeof(cpu_set_t), &cpuset);
}
```

---

## Validation & Metrics
1. Inspect thread placement with `top -H` and `perf` via adb.
2. Confirm the main PPC execution thread remains pinned to Core 7 with zero migration events under thermal load.
3. Validate frame time stability in the in-game HUD (`PES17_REPORT`).
