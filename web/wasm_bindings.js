// WebGPU WASM Bindings for zig_webgpu_platform
// This module provides Emscripten runtime stubs and complete WebGPU bindings
// that bridge WASM wgpu* calls to the browser's WebGPU API.

// =============================================================================
// Global State
// =============================================================================

let wasmInstance = null;
let wasmMemory = null;
let canvasElement = null;
let gpuContext = null;
let mainLoopCallback = null;
let mainLoopRunning = false;
let animationFrameId = null;

// Debug mode: enabled by ?debug URL parameter (set by index.html before this module loads)
const DEBUG = typeof window !== "undefined" && window.__DEBUG === true;
function dbg(...args) { if (DEBUG) console.log(...args); }

// Preferred canvas format for this browser (set during init)
let preferredCanvasFormat = "bgra8unorm";

// Pre-initialized WebGPU objects (created during JS init before WASM runs)
// This solves the async initialization problem - WASM code can use these synchronously.
let preInitAdapter = null;
let preInitDevice = null;
let preInitInstanceHandle = 0;
let preInitAdapterHandle = 0;
let preInitDeviceHandle = 0;
let preInitSurfaceHandle = 0;

// =============================================================================
// Handle Registry
// Maps integer handles (used by WASM) to JavaScript WebGPU objects.
// Handle 0 is reserved for null/invalid.
// =============================================================================

const handleRegistry = new Map();
let nextHandle = 1;

function registerHandle(obj) {
    if (!obj) return 0;
    const handle = nextHandle++;
    handleRegistry.set(handle, obj);
    return handle;
}

function getHandle(handle) {
    if (handle === 0) return null;
    return handleRegistry.get(handle) || null;
}

function freeHandle(handle) {
    if (handle !== 0) {
        handleRegistry.delete(handle);
    }
}

// =============================================================================
// WASM Memory Utilities
// =============================================================================

function readCString(ptr) {
    if (!ptr || !wasmMemory) return "";
    const mem = new Uint8Array(wasmMemory.buffer);
    let end = ptr;
    while (mem[end] !== 0) end++;
    return new TextDecoder().decode(mem.subarray(ptr, end));
}

function readU32(ptr) {
    if (!wasmMemory) return 0;
    const view = new DataView(wasmMemory.buffer);
    return view.getUint32(ptr, true);
}

function readI32(ptr) {
    if (!wasmMemory) return 0;
    const view = new DataView(wasmMemory.buffer);
    return view.getInt32(ptr, true);
}

function readU64(ptr) {
    if (!wasmMemory) return 0n;
    const view = new DataView(wasmMemory.buffer);
    return view.getBigUint64(ptr, true);
}

function readF32(ptr) {
    if (!wasmMemory) return 0;
    const view = new DataView(wasmMemory.buffer);
    return view.getFloat32(ptr, true);
}

function readF64(ptr) {
    if (!wasmMemory) return 0;
    const view = new DataView(wasmMemory.buffer);
    return view.getFloat64(ptr, true);
}

function writeU32(ptr, value) {
    if (!wasmMemory) return;
    const view = new DataView(wasmMemory.buffer);
    view.setUint32(ptr, value, true);
}

function writeI32(ptr, value) {
    if (!wasmMemory) return;
    const view = new DataView(wasmMemory.buffer);
    view.setInt32(ptr, value, true);
}

function writeF64(ptr, value) {
    if (!wasmMemory) return;
    const view = new DataView(wasmMemory.buffer);
    view.setFloat64(ptr, value, true);
}

function writePtr(ptr, value) {
    writeU32(ptr, value);
}

// Write a C string to WASM memory at the given address
function writeCString(ptr, str, maxLen) {
    if (!wasmMemory) return;
    const mem = new Uint8Array(wasmMemory.buffer);
    const encoded = new TextEncoder().encode(str);
    const len = Math.min(encoded.length, maxLen - 1);
    for (let i = 0; i < len; i++) {
        mem[ptr + i] = encoded[i];
    }
    mem[ptr + len] = 0;
}

// =============================================================================
// Texture Format Mapping
// Maps WebGPU C API enum values to browser WebGPU format strings
// =============================================================================

const TEXTURE_FORMAT_MAP = {
    0x00000000: undefined, // undef
    0x00000001: "r8unorm",
    0x00000002: "r8snorm",
    0x00000003: "r8uint",
    0x00000004: "r8sint",
    0x00000005: "r16uint",
    0x00000006: "r16sint",
    0x00000007: "r16float",
    0x00000008: "rg8unorm",
    0x00000009: "rg8snorm",
    0x0000000a: "rg8uint",
    0x0000000b: "rg8sint",
    0x0000000c: "r32float",
    0x0000000d: "r32uint",
    0x0000000e: "r32sint",
    0x0000000f: "rg16uint",
    0x00000010: "rg16sint",
    0x00000011: "rg16float",
    0x00000012: "rgba8unorm",
    0x00000013: "rgba8unorm-srgb",
    0x00000014: "rgba8snorm",
    0x00000015: "rgba8uint",
    0x00000016: "rgba8sint",
    0x00000017: "bgra8unorm",
    0x00000018: "bgra8unorm-srgb",
    0x00000019: "rgb10a2unorm",
    0x0000001a: "rg11b10ufloat",
    0x0000001b: "rgb9e5ufloat",
    0x0000001c: "rg32float",
    0x0000001d: "rg32uint",
    0x0000001e: "rg32sint",
    0x0000001f: "rgba16uint",
    0x00000020: "rgba16sint",
    0x00000021: "rgba16float",
    0x00000022: "rgba32float",
    0x00000023: "rgba32uint",
    0x00000024: "rgba32sint",
    0x00000025: "stencil8",
    0x00000026: "depth16unorm",
    0x00000027: "depth24plus",
    0x00000028: "depth24plus-stencil8",
    0x00000029: "depth32float",
    0x0000002a: "depth32float-stencil8",
};

function textureFormatToJS(format) {
    return TEXTURE_FORMAT_MAP[format] || "bgra8unorm";
}

// Vertex format mapping
const VERTEX_FORMAT_MAP = {
    0x00000001: "uint8x2",
    0x00000002: "uint8x4",
    0x00000003: "sint8x2",
    0x00000004: "sint8x4",
    0x00000005: "unorm8x2",
    0x00000006: "unorm8x4",
    0x00000007: "snorm8x2",
    0x00000008: "snorm8x4",
    0x00000009: "uint16x2",
    0x0000000a: "uint16x4",
    0x0000000b: "sint16x2",
    0x0000000c: "sint16x4",
    0x0000000d: "unorm16x2",
    0x0000000e: "unorm16x4",
    0x0000000f: "snorm16x2",
    0x00000010: "snorm16x4",
    0x00000011: "float16x2",
    0x00000012: "float16x4",
    0x00000013: "float32",
    0x00000014: "float32x2",
    0x00000015: "float32x3",
    0x00000016: "float32x4",
    0x00000017: "uint32",
    0x00000018: "uint32x2",
    0x00000019: "uint32x3",
    0x0000001a: "uint32x4",
    0x0000001b: "sint32",
    0x0000001c: "sint32x2",
    0x0000001d: "sint32x3",
    0x0000001e: "sint32x4",
};

function vertexFormatToJS(format) {
    return VERTEX_FORMAT_MAP[format] || "float32";
}

// Blend factor mapping (emscripten enum values, offset by 1 from native Dawn values)
const BLEND_FACTOR_MAP = {
    0x00000001: "zero",
    0x00000002: "one",
    0x00000003: "src",
    0x00000004: "one-minus-src",
    0x00000005: "src-alpha",
    0x00000006: "one-minus-src-alpha",
    0x00000007: "dst",
    0x00000008: "one-minus-dst",
    0x00000009: "dst-alpha",
    0x0000000A: "one-minus-dst-alpha",
    0x0000000B: "src-alpha-saturated",
    0x0000000C: "constant",
    0x0000000D: "one-minus-constant",
};

function blendFactorToJS(factor) {
    return BLEND_FACTOR_MAP[factor] || "one";
}

// Blend operation mapping (emscripten enum values)
const BLEND_OP_MAP = {
    0x00000001: "add",
    0x00000002: "subtract",
    0x00000003: "reverse-subtract",
    0x00000004: "max",
    0x00000008: "min",
};

function blendOpToJS(op) {
    return BLEND_OP_MAP[op] || "add";
}

// Primitive topology mapping (emscripten enum values, offset by 1)
const PRIMITIVE_TOPOLOGY_MAP = {
    0x00000001: "point-list",
    0x00000002: "line-list",
    0x00000003: "line-strip",
    0x00000004: "triangle-list",
    0x00000005: "triangle-strip",
};

function primitiveTopologyToJS(topology) {
    return PRIMITIVE_TOPOLOGY_MAP[topology] || "triangle-list";
}

// Cull mode mapping
const CULL_MODE_MAP = {
    0x00000000: "none",
    0x00000001: "front",
    0x00000002: "back",
};

function cullModeToJS(mode) {
    return CULL_MODE_MAP[mode] || "none";
}

// Front face mapping
const FRONT_FACE_MAP = {
    0x00000000: "ccw",
    0x00000001: "cw",
};

function frontFaceToJS(face) {
    return FRONT_FACE_MAP[face] || "ccw";
}

// Parse a BlendState from WASM memory (24 bytes)
function parseBlendState(ptr) {
    if (!ptr) return undefined;
    return {
        color: {
            operation: blendOpToJS(readU32(ptr + 0)),
            srcFactor: blendFactorToJS(readU32(ptr + 4)),
            dstFactor: blendFactorToJS(readU32(ptr + 8)),
        },
        alpha: {
            operation: blendOpToJS(readU32(ptr + 12)),
            srcFactor: blendFactorToJS(readU32(ptr + 16)),
            dstFactor: blendFactorToJS(readU32(ptr + 20)),
        },
    };
}

// Parse ColorWriteMask bits to GPUColorWrite flags
function colorWriteMaskToFlags(mask) {
    // Zig ColorWriteMask: bit 0=red, 1=green, 2=blue, 3=alpha
    // GPUColorWrite: RED=0x1, GREEN=0x2, BLUE=0x4, ALPHA=0x8, ALL=0xF
    return mask & 0xF;
}

// =============================================================================
// Emscripten Runtime Stubs
// =============================================================================

const emscriptenStubs = {
    emscripten_return_address: (level) => 0,
    
    emscripten_get_now: () => performance.now(),
    
    emscripten_set_main_loop: (funcPtr, fps, simulateInfiniteLoop) => {
        dbg("emscripten_set_main_loop called: funcPtr=" + funcPtr + " fps=" + fps + " sim=" + simulateInfiniteLoop);
        mainLoopCallback = funcPtr;
        mainLoopRunning = true;

        const table = wasmInstance.exports.__indirect_function_table;
        if (!table) {
            console.error("Function table not found in WASM exports");
            return;
        }

        let frameCount = 0;
        function frame() {
            if (!mainLoopRunning) return;
            try {
                const func = table.get(funcPtr);
                if (!func) {
                    console.error("Function not found at index", funcPtr);
                    mainLoopRunning = false;
                    return;
                }
                // In debug mode, push error scopes on first frame to catch validation errors
                if (DEBUG && frameCount === 0 && preInitDevice) {
                    preInitDevice.pushErrorScope("validation");
                    preInitDevice.pushErrorScope("out-of-memory");
                }
                func();
                frameCount++;
                if (DEBUG && frameCount === 1) {
                    dbg("Main loop: first frame executed");
                    if (preInitDevice) {
                        preInitDevice.popErrorScope().then(err => {
                            if (err) console.error("GPU OOM error: " + err.message);
                            else dbg("No OOM errors on first frame");
                        });
                        preInitDevice.popErrorScope().then(err => {
                            if (err) console.error("GPU validation error: " + err.message);
                            else dbg("No validation errors on first frame");
                        });
                    }
                } else if (DEBUG && frameCount === 5) {
                    // After a few frames, check if canvas has any non-zero content
                    try {
                        const ctx2d = document.createElement("canvas").getContext("2d");
                        ctx2d.canvas.width = 4;
                        ctx2d.canvas.height = 4;
                        ctx2d.drawImage(canvasElement, 0, 0, 4, 4);
                        const px = ctx2d.getImageData(0, 0, 4, 4).data;
                        const samples = [];
                        for (let i = 0; i < 16; i += 4) {
                            samples.push(`(${px[i]},${px[i+1]},${px[i+2]},${px[i+3]})`);
                        }
                        dbg("Canvas pixel samples: " + samples.join(" "));
                    } catch (e) {
                        dbg("Canvas readback failed: " + e.message);
                    }
                } else if (DEBUG && frameCount % 60 === 0) {
                    dbg("Main loop: frame " + frameCount);
                }
            } catch (e) {
                console.error("Main loop error (frame " + frameCount + "):", e);
                mainLoopRunning = false;
                return;
            }
            animationFrameId = requestAnimationFrame(frame);
        }

        animationFrameId = requestAnimationFrame(frame);
    },

    emscripten_cancel_main_loop: () => {
        mainLoopRunning = false;
        if (animationFrameId !== null) {
            cancelAnimationFrame(animationFrameId);
            animationFrameId = null;
        }
    },

    emscripten_get_canvas_element_size: (targetPtr, widthPtr, heightPtr) => {
        const canvas = canvasElement || document.getElementById("canvas");
        if (!canvas) {
            writeI32(widthPtr, 800);
            writeI32(heightPtr, 600);
            return -6;
        }
        writeI32(widthPtr, canvas.width);
        writeI32(heightPtr, canvas.height);
        return 0;
    },

    emscripten_get_device_pixel_ratio: () => window.devicePixelRatio || 1.0,

    emscripten_get_element_css_size: (targetPtr, widthPtr, heightPtr) => {
        const canvas = canvasElement || document.getElementById("canvas");
        if (!canvas) {
            writeF64(widthPtr, 800);
            writeF64(heightPtr, 600);
            return -6;
        }
        const rect = canvas.getBoundingClientRect();
        writeF64(widthPtr, rect.width);
        writeF64(heightPtr, rect.height);
        return 0;
    },

    emscripten_set_mousemove_callback_on_thread: (target, userData, useCapture, callback, thread) => 0,
    emscripten_set_mousedown_callback_on_thread: (target, userData, useCapture, callback, thread) => 0,
    emscripten_set_mouseup_callback_on_thread: (target, userData, useCapture, callback, thread) => 0,
    emscripten_html5_remove_all_event_listeners: () => {},
};

// =============================================================================
// WebGPU Bindings - Complete implementation bridging wgpu* calls to browser API
// =============================================================================

// Pending async operations storage
const pendingAdapterRequests = new Map();
const pendingDeviceRequests = new Map();
let nextRequestId = 1;

const webgpuStubs = {
    // -------------------------------------------------------------------------
    // Instance
    // -------------------------------------------------------------------------
    
    wgpuCreateInstance: (descriptorPtr) => {
        // Return the pre-initialized instance handle.
        // WebGPU objects are pre-created in init() before WASM runs.
        // Return pre-initialized instance handle
        return preInitInstanceHandle;
    },

    wgpuInstanceRelease: (instanceHandle) => {
        freeHandle(instanceHandle);
    },

    wgpuInstanceCreateSurface: (instanceHandle, descriptorPtr) => {
        // Return the pre-initialized surface handle.
        // Return pre-initialized surface handle
        return preInitSurfaceHandle;
    },

    wgpuInstanceRequestAdapter: (instanceHandle, optionsPtr, callback, userdata) => {
        // Use pre-initialized adapter and call the callback synchronously.
        // The adapter was already requested in init(), so we can return it immediately.
        // Use pre-initialized adapter to avoid async issues
        
        const table = wasmInstance.exports.__indirect_function_table;
        const callbackFunc = table.get(callback);
        if (callbackFunc) {
            // Call callback synchronously with success status and pre-initialized handle
            // Status: 0 = success
            callbackFunc(0, preInitAdapterHandle, 0, userdata);
        } else {
            console.error("wgpuInstanceRequestAdapter: callback function not found at index", callback);
        }
    },

    // -------------------------------------------------------------------------
    // Adapter
    // -------------------------------------------------------------------------

    wgpuAdapterRelease: (adapterHandle) => {
        freeHandle(adapterHandle);
    },

    wgpuAdapterGetProperties: (adapterHandle, propertiesPtr) => {
        // AdapterProperties structure layout (based on wgpu.zig):
        // offset 0: next_in_chain (ptr) - 4 bytes on wasm32
        // offset 4: vendor_id (u32)
        // offset 8: vendor_name (ptr to string)
        // offset 12: architecture (ptr to string)
        // offset 16: device_id (u32)
        // offset 20: name (ptr to string)
        // offset 24: driver_description (ptr to string)
        // offset 28: adapter_type (u32 enum)
        // offset 32: backend_type (u32 enum)
        // offset 36: compatibility_mode (bool/u32)
        
        // For browser WebGPU, we don't have detailed adapter info access.
        // Fill in placeholder values.
        writeU32(propertiesPtr + 4, 0);  // vendor_id
        writeU32(propertiesPtr + 8, 0);  // vendor_name (null)
        writeU32(propertiesPtr + 12, 0); // architecture (null)
        writeU32(propertiesPtr + 16, 0); // device_id
        writeU32(propertiesPtr + 20, 0); // name (null)
        writeU32(propertiesPtr + 24, 0); // driver_description (null)
        writeU32(propertiesPtr + 28, 3); // adapter_type: unknown
        writeU32(propertiesPtr + 32, 2); // backend_type: webgpu
        writeU32(propertiesPtr + 36, 0); // compatibility_mode: false
    },

    wgpuAdapterRequestDevice: (adapterHandle, descriptorPtr, callback, userdata) => {
        // Use pre-initialized device and call the callback synchronously.
        // Use pre-initialized device to avoid async issues
        
        const table = wasmInstance.exports.__indirect_function_table;
        const callbackFunc = table.get(callback);
        if (callbackFunc) {
            // Call callback synchronously with success status and pre-initialized handle
            callbackFunc(0, preInitDeviceHandle, 0, userdata);
        } else {
            console.error("wgpuAdapterRequestDevice: callback function not found at index", callback);
        }
    },

    // -------------------------------------------------------------------------
    // Device
    // -------------------------------------------------------------------------

    wgpuDeviceRelease: (deviceHandle) => {
        const obj = getHandle(deviceHandle);
        if (obj && obj.device) {
            obj.device.destroy();
        }
        freeHandle(deviceHandle);
    },

    wgpuDeviceSetUncapturedErrorCallback: (deviceHandle, callback, userdata) => {
        const obj = getHandle(deviceHandle);
        if (!obj || !obj.device) return;
        
        obj.device.addEventListener("uncapturedError", (event) => {
            console.error("WebGPU uncaptured error:", event.error.message);
        });
    },

    wgpuDeviceGetQueue: (deviceHandle) => {
        const obj = getHandle(deviceHandle);
        if (!obj || !obj.device) return 0;
        return registerHandle({ type: "queue", queue: obj.device.queue, device: obj.device });
    },

    wgpuDeviceTick: (deviceHandle) => {
        // No-op in browser - GPU work is processed automatically
    },

    wgpuDeviceCreateSwapChain: (deviceHandle, surfaceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        const surfaceObj = getHandle(surfaceHandle);
        
        if (!deviceObj || !deviceObj.device || !surfaceObj || !surfaceObj.context) {
            console.error("Invalid device or surface for swap chain creation");
            return 0;
        }

        // SwapChainDescriptor layout:
        // offset 0: next_in_chain (ptr)
        // offset 4: label (ptr)
        // offset 8: usage (u32 flags)
        // offset 12: format (u32 enum)
        // offset 16: width (u32)
        // offset 20: height (u32)
        // offset 24: present_mode (u32 enum)

        const usage = readU32(descriptorPtr + 8);
        const format = readU32(descriptorPtr + 12);
        const width = readU32(descriptorPtr + 16);
        const height = readU32(descriptorPtr + 20);
        


        // Configure the canvas context (this is browser's equivalent of swap chain)
        const formatStr = preferredCanvasFormat;
        const zigFormatStr = textureFormatToJS(format);
        dbg(`Swap chain: zig format=${zigFormatStr} (0x${format.toString(16)}), browser preferred=${formatStr}, size=${width}x${height}`);
        dbg(`Canvas backing: ${canvasElement.width}x${canvasElement.height}, CSS: ${canvasElement.clientWidth}x${canvasElement.clientHeight}`);
        
        try {
            surfaceObj.context.configure({
                device: deviceObj.device,
                format: formatStr,
                alphaMode: "opaque",
                usage: GPUTextureUsage.RENDER_ATTACHMENT,
            });
            dbg("Canvas context configured successfully");

            // Store dimensions for swap chain object
            const swapChain = {
                type: "swapchain",
                context: surfaceObj.context,
                device: deviceObj.device,
                width: width,
                height: height,
                format: formatStr,
            };

            const handle = registerHandle(swapChain);
            dbg(`WebGPU swap chain configured: ${width}x${height}, format: ${formatStr}`);
            return handle;
        } catch (e) {
            console.error("Swap chain creation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreateShaderModule: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        // ShaderModuleDescriptor layout:
        // offset 0: next_in_chain (ptr) - points to ShaderModuleWGSLDescriptor
        // offset 4: label (ptr)

        const nextInChain = readU32(descriptorPtr);
        if (!nextInChain) {
            console.error("No shader source provided");
            return 0;
        }

        // ShaderModuleWGSLDescriptor (chained):
        // offset 0: chain.next (ptr)
        // offset 4: chain.struct_type (u32) - should be 6 for WGSL
        // offset 8: code (ptr to string)

        const structType = readU32(nextInChain + 4);
        const codePtr = readU32(nextInChain + 8);
        const code = readCString(codePtr);

        if (!code) {
            console.error("Empty shader code");
            return 0;
        }

        try {
            const shaderModule = deviceObj.device.createShaderModule({
                code: code,
            });
            return registerHandle({ type: "shaderModule", module: shaderModule });
        } catch (e) {
            console.error("Shader compilation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreateBindGroupLayout: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        // BindGroupLayoutDescriptor:
        // offset 0: next_in_chain (ptr)
        // offset 4: label (ptr)
        // offset 8: entry_count (usize = u32 on wasm32)
        // offset 12: entries (ptr)

        const entryCount = readU32(descriptorPtr + 8);
        const entriesPtr = readU32(descriptorPtr + 12);

        const entries = [];
        
        // BindGroupLayoutEntry layout on wasm32 (80 bytes, align 8):
        //   offset  0: next_in_chain (ptr, 4)
        //   offset  4: binding (u32, 4)
        //   offset  8: visibility (ShaderStage packed u32, 4)
        //   offset 12: [padding 4 bytes for align(8)]
        //   --- buffer: BufferBindingLayout (24 bytes, align 8) ---
        //   offset 16: buffer.next_in_chain (ptr, 4)
        //   offset 20: buffer.binding_type (u32 enum: 0=undef, 1=uniform, 2=storage, 3=read_only_storage)
        //   offset 24: buffer.has_dynamic_offset (U32Bool: 0=false, 1=true)
        //   offset 28: [padding 4 bytes for u64]
        //   offset 32: buffer.min_binding_size (u64)
        //   --- sampler: SamplerBindingLayout (8 bytes) ---
        //   offset 40: sampler.next_in_chain (ptr, 4)
        //   offset 44: sampler.binding_type (u32 enum: 0=undef, 1=filtering, 2=non_filtering, 3=comparison)
        //   --- texture: TextureBindingLayout (16 bytes) ---
        //   offset 48: texture.next_in_chain (ptr, 4)
        //   offset 52: texture.sample_type (u32 enum)
        //   offset 56: texture.view_dimension (u32 enum)
        //   offset 60: texture.multisampled (bool, 1 byte + 3 pad)
        //   --- storage_texture: StorageTextureBindingLayout (16 bytes) ---
        //   offset 64: storage_texture.next_in_chain (ptr, 4)
        //   offset 68: storage_texture.access (u32 enum)
        //   offset 72: storage_texture.format (u32 enum)
        //   offset 76: storage_texture.view_dimension (u32 enum)
        const ENTRY_SIZE = 80;

        const BUFFER_BINDING_TYPE_MAP = { 1: "uniform", 2: "storage", 3: "read-only-storage" };
        const SAMPLER_BINDING_TYPE_MAP = { 1: "filtering", 2: "non-filtering", 3: "comparison" };
        const TEXTURE_SAMPLE_TYPE_MAP = { 1: "float", 2: "unfilterable-float", 3: "depth", 4: "sint", 5: "uint" };
        const TEXTURE_VIEW_DIM_MAP = { 1: "1d", 2: "2d", 3: "2d-array", 4: "cube", 5: "cube-array", 6: "3d" };
        const STORAGE_ACCESS_MAP = { 1: "write-only", 2: "read-only", 3: "read-write" };

        for (let i = 0; i < entryCount; i++) {
            const entryPtr = entriesPtr + i * ENTRY_SIZE;
            
            const binding = readU32(entryPtr + 4);
            const visibility = readU32(entryPtr + 8);

            const entry = {
                binding: binding,
                visibility: visibility,
            };

            // Parse buffer binding (offset 20 = binding_type within the entry)
            const bufferBindingType = readU32(entryPtr + 20);
            if (bufferBindingType !== 0) {
                entry.buffer = {
                    type: BUFFER_BINDING_TYPE_MAP[bufferBindingType] || "uniform",
                    hasDynamicOffset: readU32(entryPtr + 24) !== 0,
                    minBindingSize: Number(readU64(entryPtr + 32)),
                };
            }

            // Parse sampler binding (offset 44 = sampler.binding_type)
            const samplerBindingType = readU32(entryPtr + 44);
            if (samplerBindingType !== 0) {
                entry.sampler = {
                    type: SAMPLER_BINDING_TYPE_MAP[samplerBindingType] || "filtering",
                };
            }

            // Parse texture binding (offset 52 = texture.sample_type)
            const textureSampleType = readU32(entryPtr + 52);
            if (textureSampleType !== 0) {
                const viewDim = readU32(entryPtr + 56);
                entry.texture = {
                    sampleType: TEXTURE_SAMPLE_TYPE_MAP[textureSampleType] || "float",
                    viewDimension: TEXTURE_VIEW_DIM_MAP[viewDim] || "2d",
                    multisampled: (new Uint8Array(wasmMemory.buffer))[entryPtr + 60] !== 0,
                };
            }

            // Parse storage texture binding (offset 68 = storage_texture.access)
            const storageAccess = readU32(entryPtr + 68);
            if (storageAccess !== 0) {
                const storageFmt = readU32(entryPtr + 72);
                const storageViewDim = readU32(entryPtr + 76);
                entry.storageTexture = {
                    access: STORAGE_ACCESS_MAP[storageAccess] || "write-only",
                    format: textureFormatToJS(storageFmt) || "rgba8unorm",
                    viewDimension: TEXTURE_VIEW_DIM_MAP[storageViewDim] || "2d",
                };
            }

            dbg("BindGroupLayout entry[" + i + "]: binding=" + binding +
                " visibility=0x" + visibility.toString(16) +
                (entry.buffer ? " buffer=" + entry.buffer.type : "") +
                (entry.sampler ? " sampler=" + entry.sampler.type : "") +
                (entry.texture ? " texture=" + entry.texture.sampleType : "") +
                (entry.storageTexture ? " storage=" + entry.storageTexture.access : ""));

            entries.push(entry);
        }

        try {
            if (DEBUG) deviceObj.device.pushErrorScope("validation");
            const layout = deviceObj.device.createBindGroupLayout({ entries });
            if (DEBUG) deviceObj.device.popErrorScope().then(err => {
                if (err) console.error("BindGroupLayout validation error: " + err.message);
            });
            return registerHandle({ type: "bindGroupLayout", layout: layout });
        } catch (e) {
            console.error("Bind group layout creation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreatePipelineLayout: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        // PipelineLayoutDescriptor:
        // offset 0: next_in_chain (ptr)
        // offset 4: label (ptr)
        // offset 8: bind_group_layout_count (usize)
        // offset 12: bind_group_layouts (ptr to array of handles)

        const layoutCount = readU32(descriptorPtr + 8);
        const layoutsPtr = readU32(descriptorPtr + 12);

        const bindGroupLayouts = [];
        for (let i = 0; i < layoutCount; i++) {
            const layoutHandle = readU32(layoutsPtr + i * 4);
            const layoutObj = getHandle(layoutHandle);
            if (layoutObj && layoutObj.layout) {
                bindGroupLayouts.push(layoutObj.layout);
            }
        }

        dbg("Creating pipeline layout with " + layoutCount + " bind group layout(s)");
        try {
            if (DEBUG) deviceObj.device.pushErrorScope("validation");
            const pipelineLayout = deviceObj.device.createPipelineLayout({
                bindGroupLayouts: bindGroupLayouts,
            });
            if (DEBUG) deviceObj.device.popErrorScope().then(err => {
                if (err) console.error("PipelineLayout validation error: " + err.message);
            });
            return registerHandle({ type: "pipelineLayout", layout: pipelineLayout });
        } catch (e) {
            console.error("Pipeline layout creation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreateRenderPipeline: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        // This is a complex descriptor. Parse the essential fields.
        // RenderPipelineDescriptor layout (simplified):
        // offset 0: next_in_chain
        // offset 4: label (ptr)
        // offset 8: layout (handle)
        // offset 12: vertex state starts

        const layoutHandle = readU32(descriptorPtr + 8);
        const layoutObj = getHandle(layoutHandle);

        // Vertex state at offset 12:
        // offset 12: vertex.next_in_chain
        // offset 16: vertex.module (handle)
        // offset 20: vertex.entry_point (ptr)
        // offset 24: vertex.constant_count
        // offset 28: vertex.constants (ptr)
        // offset 32: vertex.buffer_count
        // offset 36: vertex.buffers (ptr)

        const vertexModuleHandle = readU32(descriptorPtr + 16);
        const vertexEntryPointPtr = readU32(descriptorPtr + 20);
        const vertexBufferCount = readU32(descriptorPtr + 32);
        const vertexBuffersPtr = readU32(descriptorPtr + 36);

        const vertexModuleObj = getHandle(vertexModuleHandle);
        const vertexEntryPoint = vertexEntryPointPtr ? readCString(vertexEntryPointPtr) : "vs_main";

        // Parse vertex buffers
        const vertexBuffers = [];
        // VertexBufferLayout is 24 bytes on wasm32:
        // - array_stride: u64 (8 bytes) at offset 0
        // - step_mode: u32 (4 bytes) at offset 8
        // - attribute_count: usize/u32 (4 bytes) at offset 12
        // - attributes: ptr (4 bytes) at offset 16
        // - padding (4 bytes) to align to 8
        const BUFFER_LAYOUT_SIZE = 24;
        


        for (let i = 0; i < vertexBufferCount; i++) {
            const bufferPtr = vertexBuffersPtr + i * BUFFER_LAYOUT_SIZE;
            
            const arrayStride = Number(readU64(bufferPtr));
            const stepMode = readU32(bufferPtr + 8);
            const attrCount = readU32(bufferPtr + 12);
            const attrsPtr = readU32(bufferPtr + 16);
            


            const attributes = [];
            // VertexAttribute is 24 bytes on wasm32 (due to u64 alignment):
            // - format: u32 (4 bytes) at offset 0
            // - padding (4 bytes) to align u64
            // - offset: u64 (8 bytes) at offset 8
            // - shader_location: u32 (4 bytes) at offset 16
            // - padding (4 bytes) to align next element
            const ATTR_SIZE = 24;

            for (let j = 0; j < attrCount; j++) {
                const attrPtr = attrsPtr + j * ATTR_SIZE;
                
                const format = readU32(attrPtr);
                const attrOffset = Number(readU64(attrPtr + 8));
                const shaderLocation = readU32(attrPtr + 16);
                


                attributes.push({
                    format: vertexFormatToJS(format),
                    offset: attrOffset,
                    shaderLocation: shaderLocation,
                });
            }

            // VertexStepMode for emscripten:
            // 0 = undefined, 1 = vertex_buffer_not_used, 2 = vertex, 3 = instance
            const stepModeStr = stepMode === 2 ? "vertex" : (stepMode === 3 ? "instance" : "vertex");
            vertexBuffers.push({
                arrayStride: arrayStride,
                stepMode: stepModeStr,
                attributes: attributes,
            });
        }

        // Parse primitive state from descriptor at offset 40
        // PrimitiveState layout (20 bytes):
        //   offset 0: next_in_chain (ptr)
        //   offset 4: topology (u32 enum)
        //   offset 8: strip_index_format (u32 enum)
        //   offset 12: front_face (u32 enum)
        //   offset 16: cull_mode (u32 enum)
        const primTopology = readU32(descriptorPtr + 44);
        const primFrontFace = readU32(descriptorPtr + 52);
        const primCullMode = readU32(descriptorPtr + 56);

        const primitiveState = {
            topology: primitiveTopologyToJS(primTopology),
            frontFace: frontFaceToJS(primFrontFace),
            cullMode: cullModeToJS(primCullMode),
        };

        // Parse fragment state pointer at offset 80
        // FragmentState layout (28 bytes):
        //   offset 0: next_in_chain (ptr)
        //   offset 4: module (handle)
        //   offset 8: entry_point (ptr to string)
        //   offset 12: constant_count (u32)
        //   offset 16: constants (ptr)
        //   offset 20: target_count (u32)
        //   offset 24: targets (ptr to ColorTargetState array)
        const fragmentStatePtr = readU32(descriptorPtr + 80);
        let fragmentState = null;

        if (fragmentStatePtr) {
            const fragModuleHandle = readU32(fragmentStatePtr + 4);
            const fragEntryPointPtr = readU32(fragmentStatePtr + 8);
            const fragTargetCount = readU32(fragmentStatePtr + 20);
            const fragTargetsPtr = readU32(fragmentStatePtr + 24);

            const fragModuleObj = getHandle(fragModuleHandle);
            const fragEntryPoint = fragEntryPointPtr ? readCString(fragEntryPointPtr) : "fs_main";

            // Parse color target states (each 16 bytes):
            //   offset 0: next_in_chain (ptr)
            //   offset 4: format (u32 enum)
            //   offset 8: blend (ptr to BlendState, nullable)
            //   offset 12: write_mask (u32, ColorWriteMask bits)
            const targets = [];
            const COLOR_TARGET_SIZE = 16;

            for (let i = 0; i < fragTargetCount; i++) {
                const tgtPtr = fragTargetsPtr + i * COLOR_TARGET_SIZE;
                const zigFormat = readU32(tgtPtr + 4);
                const blendPtr = readU32(tgtPtr + 8);
                const writeMask = readU32(tgtPtr + 12);

                const zigFormatStr = textureFormatToJS(zigFormat);

                // Use browser's preferred format instead of Zig's hardcoded format,
                // since the swap chain canvas context is configured with preferredCanvasFormat.
                // On desktop Chrome this is bgra8unorm, on mobile Chrome it's rgba8unorm.
                const targetFormat = preferredCanvasFormat;

                const target = {
                    format: targetFormat,
                    writeMask: colorWriteMaskToFlags(writeMask),
                };

                // Parse blend state if present
                if (blendPtr) {
                    target.blend = parseBlendState(blendPtr);
                }

                targets.push(target);

                if (i === 0) {
                    dbg("Pipeline color target[0]: zigFormat=" + zigFormatStr +
                        " -> " + targetFormat + ", blend=" + (blendPtr ? "yes" : "no") +
                        ", writeMask=0x" + writeMask.toString(16));
                    if (blendPtr) {
                        dbg("  blend.color: " + target.blend.color.srcFactor +
                            " " + target.blend.color.operation + " " + target.blend.color.dstFactor);
                        dbg("  blend.alpha: " + target.blend.alpha.srcFactor +
                            " " + target.blend.alpha.operation + " " + target.blend.alpha.dstFactor);
                    }
                }
            }

            fragmentState = {
                module: fragModuleObj ? fragModuleObj.module : (vertexModuleObj ? vertexModuleObj.module : null),
                entryPoint: fragEntryPoint,
                targets: targets,
            };
        }

        const pipelineDesc = {
            layout: layoutObj ? layoutObj.layout : "auto",
            vertex: {
                module: vertexModuleObj ? vertexModuleObj.module : null,
                entryPoint: vertexEntryPoint,
                buffers: vertexBuffers,
            },
            primitive: primitiveState,
        };

        if (fragmentState) {
            pipelineDesc.fragment = fragmentState;
        }

        dbg("Creating render pipeline with format:", preferredCanvasFormat,
            "primitive:", primitiveState.topology, primitiveState.cullMode);
        try {
            if (DEBUG) deviceObj.device.pushErrorScope("validation");
            const pipeline = deviceObj.device.createRenderPipeline(pipelineDesc);
            if (DEBUG) deviceObj.device.popErrorScope().then(err => {
                if (err) console.error("Pipeline validation error: " + err.message);
                else dbg("Pipeline passed GPU validation");
            });
            dbg("Render pipeline created successfully");
            return registerHandle({ type: "renderPipeline", pipeline: pipeline });
        } catch (e) {
            console.error("Render pipeline creation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreateBuffer: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        // BufferDescriptor layout on wasm32:
        // offset 0: next_in_chain (ptr, 4 bytes)
        // offset 4: label (ptr, 4 bytes)
        // offset 8: usage (u32, 4 bytes)
        // offset 12: padding (4 bytes to align u64)
        // offset 16: size (u64, 8 bytes)
        // offset 24: mapped_at_creation (u32)

        const usage = readU32(descriptorPtr + 8);
        const size = Number(readU64(descriptorPtr + 16));
        const mappedAtCreation = readU32(descriptorPtr + 24) !== 0;



        // Convert usage flags
        let gpuUsage = 0;
        if (usage & 0x01) gpuUsage |= GPUBufferUsage.MAP_READ;
        if (usage & 0x02) gpuUsage |= GPUBufferUsage.MAP_WRITE;
        if (usage & 0x04) gpuUsage |= GPUBufferUsage.COPY_SRC;
        if (usage & 0x08) gpuUsage |= GPUBufferUsage.COPY_DST;
        if (usage & 0x10) gpuUsage |= GPUBufferUsage.INDEX;
        if (usage & 0x20) gpuUsage |= GPUBufferUsage.VERTEX;
        if (usage & 0x40) gpuUsage |= GPUBufferUsage.UNIFORM;
        if (usage & 0x80) gpuUsage |= GPUBufferUsage.STORAGE;
        if (usage & 0x100) gpuUsage |= GPUBufferUsage.INDIRECT;

        try {
            const buffer = deviceObj.device.createBuffer({
                size: size,
                usage: gpuUsage,
                mappedAtCreation: mappedAtCreation,
            });
            const handle = registerHandle({ type: "buffer", buffer: buffer });

            return handle;
        } catch (e) {
            console.error("Buffer creation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreateBindGroup: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        // BindGroupDescriptor:
        // offset 0: next_in_chain
        // offset 4: label (ptr)
        // offset 8: layout (handle)
        // offset 12: entry_count (usize)
        // offset 16: entries (ptr)

        const layoutHandle = readU32(descriptorPtr + 8);
        const entryCount = readU32(descriptorPtr + 12);
        const entriesPtr = readU32(descriptorPtr + 16);
        


        const layoutObj = getHandle(layoutHandle);
        if (!layoutObj || !layoutObj.layout) {
            console.error("wgpuDeviceCreateBindGroup: Invalid layout handle", layoutHandle);
            return 0;
        }

        const entries = [];
        
        // BindGroupEntry on wasm32:
        // offset 0: next_in_chain (ptr, 4 bytes)
        // offset 4: binding (u32, 4 bytes)
        // offset 8: buffer (ptr/handle, 4 bytes)
        // offset 12: padding (4 bytes to align u64)
        // offset 16: offset (u64, 8 bytes)
        // offset 24: size (u64, 8 bytes)
        // offset 32: sampler (ptr, 4 bytes)
        // offset 36: texture_view (ptr, 4 bytes)
        // Total: 40 bytes
        const ENTRY_SIZE = 40;

        for (let i = 0; i < entryCount; i++) {
            const entryPtr = entriesPtr + i * ENTRY_SIZE;
            
            const binding = readU32(entryPtr + 4);
            const bufferHandle = readU32(entryPtr + 8);
            const offset = Number(readU64(entryPtr + 16));
            const size = Number(readU64(entryPtr + 24));
            


            const entry = { binding: binding };

            if (bufferHandle) {
                const bufferObj = getHandle(bufferHandle);
                if (bufferObj && bufferObj.buffer) {
                    entry.resource = {
                        buffer: bufferObj.buffer,
                        offset: offset,
                        size: size || undefined,
                    };
                }
            }

            entries.push(entry);
        }

        try {
            const bindGroup = deviceObj.device.createBindGroup({
                layout: layoutObj.layout,
                entries: entries,
            });
            return registerHandle({ type: "bindGroup", group: bindGroup });
        } catch (e) {
            console.error("Bind group creation failed:", e);
            return 0;
        }
    },

    wgpuDeviceCreateCommandEncoder: (deviceHandle, descriptorPtr) => {
        const deviceObj = getHandle(deviceHandle);
        if (!deviceObj || !deviceObj.device) return 0;

        try {
            const encoder = deviceObj.device.createCommandEncoder();
            return registerHandle({ type: "commandEncoder", encoder: encoder });
        } catch (e) {
            console.error("Command encoder creation failed:", e);
            return 0;
        }
    },

    // -------------------------------------------------------------------------
    // Queue
    // -------------------------------------------------------------------------

    wgpuQueueRelease: (queueHandle) => {
        freeHandle(queueHandle);
    },

    wgpuQueueSubmit: (() => {
        let submitCount = 0;
        return (queueHandle, commandCount, commandsPtr) => {
            const queueObj = getHandle(queueHandle);
            if (!queueObj || !queueObj.queue) {
                console.error("queueSubmit: invalid queue handle");
                return;
            }

            const commandBuffers = [];
            for (let i = 0; i < commandCount; i++) {
                const cmdHandle = readU32(commandsPtr + i * 4);
                const cmdObj = getHandle(cmdHandle);
                if (cmdObj && cmdObj.buffer) {
                    commandBuffers.push(cmdObj.buffer);
                    freeHandle(cmdHandle);
                }
            }

            if (commandBuffers.length > 0) {
                try {
                    queueObj.queue.submit(commandBuffers);
                    submitCount++;
                    if (submitCount === 1) {
                        dbg("First queue.submit() succeeded (" + commandBuffers.length + " buffers)");
                    }
                } catch (e) {
                    console.error("queue.submit() failed:", e);
                }
            }
        };
    })(),

    wgpuQueueWriteBuffer: (() => {
        let writeCount = 0;
        return (queueHandle, bufferHandle, bufferOffset, dataPtr, size) => {
            const queueObj = getHandle(queueHandle);
            const bufferObj = getHandle(bufferHandle);
            
            if (!queueObj || !queueObj.queue || !bufferObj || !bufferObj.buffer) return;

            const data = new Uint8Array(wasmMemory.buffer, dataPtr, Number(size));

            // Log first few writeBuffer calls to see uniform data
            if (writeCount < 3) {
                const sizeN = Number(size);
                if (sizeN <= 16) {
                    // Likely uniform buffer - dump as floats
                    const fview = new Float32Array(wasmMemory.buffer, dataPtr, sizeN / 4);
                    dbg("writeBuffer #" + writeCount + ": size=" + sizeN + " offset=" + Number(bufferOffset) + " f32=[" + Array.from(fview).join(", ") + "]");
                } else {
                    dbg("writeBuffer #" + writeCount + ": size=" + sizeN + " offset=" + Number(bufferOffset));
                }
                writeCount++;
            }

            queueObj.queue.writeBuffer(bufferObj.buffer, Number(bufferOffset), data);
        };
    })(),

    // -------------------------------------------------------------------------
    // Swap Chain
    // -------------------------------------------------------------------------

    wgpuSwapChainRelease: (swapChainHandle) => {
        // In browser, "releasing" the swap chain means unconfiguring the context
        const obj = getHandle(swapChainHandle);
        if (obj && obj.context) {
            obj.context.unconfigure();
        }
        freeHandle(swapChainHandle);
    },

    wgpuSwapChainGetCurrentTextureView: (() => {
        let logged = false;
        return (swapChainHandle) => {
            const obj = getHandle(swapChainHandle);
            if (!obj || !obj.context) {
                console.error("getCurrentTextureView: invalid swap chain handle or no context");
                return 0;
            }

            try {
                const texture = obj.context.getCurrentTexture();
                if (!logged) {
                    dbg("getCurrentTexture: " + texture.width + "x" + texture.height + " format=" + texture.format);
                    logged = true;
                }
                const view = texture.createView();
                return registerHandle({ type: "textureView", view: view });
            } catch (e) {
                console.error("Failed to get current texture view:", e);
                return 0;
            }
        };
    })(),

    wgpuSwapChainPresent: (swapChainHandle) => {
        // In browser WebGPU, presentation happens automatically at the end of the frame.
        // No explicit present call needed.
    },

    // -------------------------------------------------------------------------
    // Command Encoder
    // -------------------------------------------------------------------------

    wgpuCommandEncoderBeginRenderPass: (() => {
        let loggedOnce = false;
        return (encoderHandle, descriptorPtr) => {
        const encoderObj = getHandle(encoderHandle);
        if (!encoderObj || !encoderObj.encoder) return 0;

        // RenderPassDescriptor:
        // offset 0: next_in_chain
        // offset 4: label (ptr)
        // offset 8: color_attachment_count (usize)
        // offset 12: color_attachments (ptr)

        const colorAttachmentCount = readU32(descriptorPtr + 8);
        const colorAttachmentsPtr = readU32(descriptorPtr + 12);

        const colorAttachments = [];

        // RenderPassColorAttachment (emscripten/wasm32):
        // offset 0:  next_in_chain (ptr, 4 bytes)
        // offset 4:  view (ptr, 4 bytes)
        // offset 8:  depth_slice (u32, 4 bytes)
        // offset 12: resolve_target (ptr, 4 bytes)
        // offset 16: load_op (u32, 4 bytes)
        // offset 20: store_op (u32, 4 bytes)
        // offset 24: clear_value (4 x f64 = 32 bytes, 8-byte aligned)
        // Total: 56 bytes
        const COLOR_ATTACH_SIZE = 56;

        for (let i = 0; i < colorAttachmentCount; i++) {
            const attachPtr = colorAttachmentsPtr + i * COLOR_ATTACH_SIZE;
            
            const viewHandle = readU32(attachPtr + 4);
            const loadOp = readU32(attachPtr + 16);
            const storeOp = readU32(attachPtr + 20);
            
            const clearR = readF64(attachPtr + 24);
            const clearG = readF64(attachPtr + 32);
            const clearB = readF64(attachPtr + 40);
            const clearA = readF64(attachPtr + 48);

            const viewObj = getHandle(viewHandle);

            if (!loggedOnce) {
                dbg("RenderPass attach: view=" + viewHandle + " loadOp=" + loadOp + " storeOp=" + storeOp);
                dbg("RenderPass clear: r=" + clearR + " g=" + clearG + " b=" + clearB + " a=" + clearA);
                loggedOnce = true;
            }

            const attachment = {
                view: viewObj ? viewObj.view : null,
                loadOp: loadOp === 1 ? "clear" : "load",
                storeOp: storeOp === 1 ? "store" : "discard",
                clearValue: { r: clearR, g: clearG, b: clearB, a: clearA },
            };

            if (attachment.view) {
                colorAttachments.push(attachment);
            }
        }

        if (colorAttachments.length === 0) {
            console.error("No valid color attachments for render pass");
            return 0;
        }

        try {
            const renderPass = encoderObj.encoder.beginRenderPass({
                colorAttachments: colorAttachments,
            });
            return registerHandle({ type: "renderPassEncoder", pass: renderPass });
        } catch (e) {
            console.error("Begin render pass failed:", e);
            console.error("Attachments:", JSON.stringify(colorAttachments.map(a => ({
                hasView: !!a.view, loadOp: a.loadOp, storeOp: a.storeOp,
                clear: a.clearValue
            }))));
            return 0;
        }
    };
    })(),

    wgpuCommandEncoderFinish: (encoderHandle, descriptorPtr) => {
        const encoderObj = getHandle(encoderHandle);
        if (!encoderObj || !encoderObj.encoder) return 0;

        try {
            const commandBuffer = encoderObj.encoder.finish();
            freeHandle(encoderHandle);
            return registerHandle({ type: "commandBuffer", buffer: commandBuffer });
        } catch (e) {
            console.error("Command encoder finish failed:", e);
            return 0;
        }
    },

    // -------------------------------------------------------------------------
    // Render Pass Encoder
    // -------------------------------------------------------------------------

    wgpuRenderPassEncoderSetPipeline: (passHandle, pipelineHandle) => {
        const passObj = getHandle(passHandle);
        const pipelineObj = getHandle(pipelineHandle);
        if (passObj && passObj.pass && pipelineObj && pipelineObj.pipeline) {
            passObj.pass.setPipeline(pipelineObj.pipeline);
        }
    },

    wgpuRenderPassEncoderSetBindGroup: (passHandle, groupIndex, groupHandle, dynamicOffsetCount, dynamicOffsetsPtr) => {
        const passObj = getHandle(passHandle);
        const groupObj = getHandle(groupHandle);
        if (passObj && passObj.pass && groupObj && groupObj.group) {
            passObj.pass.setBindGroup(groupIndex, groupObj.group);
        }
    },

    wgpuRenderPassEncoderSetVertexBuffer: (passHandle, slot, bufferHandle, offset, size) => {
        const passObj = getHandle(passHandle);
        const bufferObj = getHandle(bufferHandle);
        if (passObj && passObj.pass && bufferObj && bufferObj.buffer) {
            passObj.pass.setVertexBuffer(slot, bufferObj.buffer, Number(offset), Number(size));
        }
    },

    wgpuRenderPassEncoderDraw: (passHandle, vertexCount, instanceCount, firstVertex, firstInstance) => {
        const passObj = getHandle(passHandle);
        if (passObj && passObj.pass) {
            passObj.pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
        }
    },

    wgpuRenderPassEncoderEnd: (passHandle) => {
        const passObj = getHandle(passHandle);
        if (passObj && passObj.pass) {
            passObj.pass.end();
            freeHandle(passHandle);
        }
    },

    // -------------------------------------------------------------------------
    // Resource Release
    // -------------------------------------------------------------------------

    wgpuShaderModuleRelease: (handle) => { freeHandle(handle); },
    wgpuPipelineLayoutRelease: (handle) => { freeHandle(handle); },
    wgpuBindGroupLayoutRelease: (handle) => { freeHandle(handle); },
    wgpuSurfaceRelease: (handle) => { freeHandle(handle); },
    wgpuTextureViewRelease: (handle) => { freeHandle(handle); },
    wgpuRenderPipelineRelease: (handle) => { freeHandle(handle); },
    wgpuBufferRelease: (handle) => { freeHandle(handle); },
    wgpuBindGroupRelease: (handle) => { freeHandle(handle); },
    wgpuTextureRelease: (handle) => { freeHandle(handle); },
};

// =============================================================================
// Module Initialization
// =============================================================================

export async function init(wasmPath) {
    if (!navigator.gpu) {
        throw new Error("WebGPU is not supported in this browser");
    }

    // Get canvas and configure context
    canvasElement = document.getElementById("canvas");
    if (!canvasElement) {
        throw new Error("Canvas element not found");
    }

    // Determine preferred canvas format
    preferredCanvasFormat = navigator.gpu.getPreferredCanvasFormat();
    dbg("Preferred canvas format:", preferredCanvasFormat);

    // Pre-initialize WebGPU adapter and device BEFORE loading WASM.
    // This solves the async initialization problem - the WASM code uses synchronous
    // patterns (requestAdapterSync, requestDeviceSync) which expect callbacks to
    // fire synchronously. By pre-creating these objects, we can return them
    // immediately when the wgpu functions are called.
    dbg("Initializing WebGPU...");
    
    preInitAdapter = await navigator.gpu.requestAdapter({
        powerPreference: "high-performance"
    });
    if (!preInitAdapter) {
        throw new Error("Failed to get WebGPU adapter");
    }
    dbg("Adapter obtained");
    if (preInitAdapter.info) {
        const info = preInitAdapter.info;
        dbg("Adapter info: " + JSON.stringify({vendor: info.vendor, architecture: info.architecture, device: info.device, description: info.description}));
    }
    // Log adapter features
    const features = [];
    preInitAdapter.features.forEach(f => features.push(f));
    dbg("Adapter features: " + features.join(", "));

    preInitDevice = await preInitAdapter.requestDevice();
    if (!preInitDevice) {
        throw new Error("Failed to get WebGPU device");
    }
    dbg("Device obtained");

    // Listen for device lost
    preInitDevice.lost.then(info => {
        console.error("WebGPU device lost: " + info.reason + " - " + info.message);
    });

    // Get WebGPU context for canvas
    gpuContext = canvasElement.getContext("webgpu");
    if (!gpuContext) {
        throw new Error("Failed to get WebGPU context from canvas");
    }

    // Pre-register handles for the WebGPU objects.
    // The WASM code will get these handles when it calls wgpuCreateInstance, etc.
    preInitInstanceHandle = registerHandle({ type: "instance", gpu: navigator.gpu });
    preInitAdapterHandle = registerHandle({ type: "adapter", adapter: preInitAdapter });
    preInitDeviceHandle = registerHandle({ type: "device", device: preInitDevice });
    preInitSurfaceHandle = registerHandle({ type: "surface", context: gpuContext, canvas: canvasElement });

    dbg("WebGPU initialized");

    // Fetch and instantiate WASM
    const response = await fetch(wasmPath || "bin/zig_webgpu_platform.wasm");
    const wasmBytes = await response.arrayBuffer();

    const importObject = {
        env: {
            ...emscriptenStubs,
            ...webgpuStubs,
        },
    };

    const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
    wasmInstance = instance;
    wasmMemory = instance.exports.memory;

    if (!wasmMemory) {
        console.warn("WASM module did not export memory");
    }

    dbg("WASM module loaded");

    return {
        instance,
        exports: instance.exports,
    };
}

export default { init };
