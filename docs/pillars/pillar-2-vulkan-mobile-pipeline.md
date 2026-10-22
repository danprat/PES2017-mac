# Pillar 2: Tile-Based Vulkan Mobile Pipeline & Shaders (Vulkan 1.0 or above)

## Overview
The mobile graphics backend strictly targets **Vulkan 1.0 or above** as its baseline (`app.apiVersion = VK_API_VERSION_1_0`). This guarantees full compatibility across older and budget Android devices that only expose Vulkan 1.0 core (such as Android 7/8/9, Snapdragon 660/835 Adreno 5xx, and MediaTek Helio / Mali-G52/G72), while opportunistically scaling up to Vulkan 1.2/1.3 when available.

Mobile GPUs (Qualcomm Adreno, ARM Mali, PowerVR, Samsung Xclipse) utilize **Tile-Based Deferred Rendering (TBDR)**. Unlike desktop immediate-mode GPUs, TBDR chips divide each frame into small screen tiles (typically 16×16 or 32×32 pixels) rendered directly in ultra-fast on-chip SRAM.

Bottlenecks and compatibility challenges occur when:
1. Drivers lack modern extensions like `VK_KHR_dynamic_rendering`, requiring a robust **Vulkan 1.0 classic `VkRenderPass` & `VkFramebuffer` path**.
2. Depth/stencil buffers are unnecessarily written back to system LPDDR RAM at the end of a render pass.
3. In-game shader compilation stalls the render thread while translating Xenos microcode to SPIR-V.
4. Sampler wrap modes or BC5 normal map swizzles fail, causing black terrain, silhouettes, and broken skyboxes.

---

## Technical Solutions

### 1. TBDR RenderPass `DONT_CARE` Optimization
In mobile graphics, depth and stencil attachments used for geometry culling during a frame are not needed once the final color buffer is resolved:
```cpp
VkAttachmentDescription depthAttachment{};
depthAttachment.format = g.depthFormat;
depthAttachment.samples = VK_SAMPLE_COUNT_1_BIT;
depthAttachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
depthAttachment.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE; // <--- Critical for TBDR!
depthAttachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
depthAttachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
```
* **Impact**: Eliminates up to 1.5 GB/s of continuous memory bus bandwidth, directly lowering SoC temperature and preventing thermal throttling.

### 2. Multi-Tiered Shader Pipeline Cache
To prevent gameplay stutter when new shaders are introduced:
- **Tier 1 (Instant Boot)**: Compile the first 15 critical title/menu shaders within a 250 ms budget.
- **Tier 2 (Background Warmup Scheduler)**: Asynchronously compile remaining gameplay pipelines during cutscenes and menus using `g_shadersMutex`.
- **Tier 3 (Persistent `VkPipelineCache`)**: Serialize compiled driver bytecode into `shader_cache.bin` on internal storage (`/data/data/com.pes2017.recomp/files/`).

### 3. Skybox & Normal Map Reconstruction
- **Skybox Cubemaps**: Ensure `VkSamplerAddressMode` is set to `VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE` for cubemap faces to avoid seam borders.
- **BC5 Normal Maps**: Mobile shaders reconstruct the Z normal component in the fragment stage:
  $$Z = \sqrt{\max(0.0, 1.0 - X^2 - Y^2)}$$
  Ensuring correct channel swizzle $(R, G \to X, Y)$ resolves dark or flat normal surfaces on Adreno and Mali.

### 4. GPU-Specific Compression Paths
- **Adreno**: Correctly activates hardware BC support when `physicalProperties.vendorID == 0x5143`.
- **Mali / Tensor**: Pure zero-copy SIMD-optimized BC1–BC5 software decompressor using aligned 64-bit word stores.
