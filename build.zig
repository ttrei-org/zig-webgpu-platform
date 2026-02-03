const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Detect if building for web/WASM target
    const target_arch = target.result.cpu.arch;
    const target_os = target.result.os.tag;
    const is_wasm = target_arch.isWasm();
    const is_native = !is_wasm;

    // Configure output path: zig-out/web/ for WASM builds, default for native
    if (is_wasm) {
        b.install_prefix = "zig-out/web";
    }

    // Fetch zgpu dependency and get its module
    const zgpu_dep = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu_module = zgpu_dep.module("root");

    // Create the root module for the executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zgpu import
    root_module.addImport("zgpu", zgpu_module);

    // Fetch zigimg dependency and add import
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zigimg", zigimg_dep.module("zigimg"));

    // Fetch zglfw dependency and add import for desktop builds only
    var zglfw_dep: ?*std.Build.Dependency = null;
    if (is_native) {
        zglfw_dep = b.dependency("zglfw", .{
            .target = target,
            .optimize = optimize,
        });
        root_module.addImport("zglfw", zglfw_dep.?.module("root"));
    }

    const exe = b.addExecutable(.{
        .name = "zig_gui_experiment",
        .root_module = root_module,
    });

    // Native-only: Link Dawn/WebGPU and system dependencies
    // Emscripten uses browser's WebGPU implementation
    if (is_native) {
        const zgpu_build = @import("zgpu");
        zgpu_build.addLibraryPathsTo(exe);
        zgpu_build.linkSystemDeps(b, exe);

        // Add include path for Dawn headers
        exe.root_module.addIncludePath(zgpu_dep.path("libs/dawn/include"));
        exe.root_module.addIncludePath(zgpu_dep.path("src"));

        // Link Dawn and C++ runtime
        exe.linkSystemLibrary("dawn");
        exe.linkLibC();
        exe.linkLibCpp();

        // Link X11 on Linux for Dawn's surface support
        if (target_os == .linux) {
            exe.linkSystemLibrary("X11");
        }

        // Link GLFW library for desktop builds
        if (zglfw_dep) |dep| {
            exe.root_module.linkLibrary(dep.artifact("glfw"));
        }

        // Add C source files for Dawn bindings
        exe.root_module.addCSourceFile(.{
            .file = zgpu_dep.path("src/dawn.cpp"),
            .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
        });
        exe.root_module.addCSourceFile(.{
            .file = zgpu_dep.path("src/dawn_proc.c"),
            .flags = &.{"-fno-sanitize=undefined"},
        });
    } else {
        // WASM-specific configuration
        // Export WebGPU entry points and set up for browser environment
        //
        // Memory settings:
        // - export_memory: Required for JS to access WASM memory
        // - initial_memory: 64MB starting heap (sufficient for basic rendering)
        // - max_memory: null allows growth (equivalent to -sALLOW_MEMORY_GROWTH)
        //
        // Note: Browser-side settings (-sUSE_WEBGPU=1, -sMODULARIZE, -sEXPORT_ES6)
        // are configured in the HTML/JS loader, not the WASM build itself.
        // The browser provides WebGPU via navigator.gpu, no linking required.

        exe.export_memory = true;
        exe.export_table = true; // Export function table for emscripten_set_main_loop callbacks
        exe.initial_memory = 64 * 1024 * 1024; // 64MB initial heap
        exe.max_memory = null; // Allow memory growth (no upper limit)
        exe.import_symbols = true; // Allow imports from JS environment

        // Note: We do NOT link libc for WASM builds.
        // Zig doesn't have libc support for wasm32-emscripten targets.
        // Instead, we use custom emscripten bindings in web.zig that don't require libc.
        // The extern functions are imported from the JavaScript environment at runtime.

        // Export the wasm_main entry point which is explicitly defined for WASM builds.
        // We don't export _start/main to avoid triggering the standard library's
        // start.zig which doesn't support wasm32-emscripten architecture.
        exe.root_module.export_symbol_names = &.{
            "wasm_main", // Our custom WASM entry point
        };

        // For emscripten specifically, mark that we don't need a standard entry point
        // since the browser/JS will call our exported wasm_main function
        exe.entry = .disabled;
    }

    b.installArtifact(exe);

    // For web builds, also generate JavaScript glue code
    if (is_wasm) {
        // Create JavaScript loader file that instantiates the WASM module
        // This provides Emscripten runtime stubs and WebGPU integration
        const js_glue = b.addWriteFiles();
        _ = js_glue.add("zig_gui_experiment.js",
            \\// Generated JavaScript glue code for zig_gui_experiment.wasm
            \\// This module provides Emscripten runtime stubs and WebGPU integration
            \\
            \\// Global state for WASM module
            \\let wasmInstance = null;
            \\let wasmMemory = null;
            \\let gpuDevice = null;
            \\let gpuAdapter = null;
            \\let gpuContext = null;
            \\let canvasElement = null;
            \\let mainLoopCallback = null;
            \\let mainLoopRunning = false;
            \\let animationFrameId = null;
            \\
            \\// Handle registry for WebGPU objects (maps integer handles to JS objects)
            \\const handleRegistry = new Map();
            \\let nextHandle = 1;
            \\
            \\function registerHandle(obj) {
            \\    if (!obj) return 0;
            \\    const handle = nextHandle++;
            \\    handleRegistry.set(handle, obj);
            \\    return handle;
            \\}
            \\
            \\function getHandle(handle) {
            \\    return handleRegistry.get(handle) || null;
            \\}
            \\
            \\function freeHandle(handle) {
            \\    handleRegistry.delete(handle);
            \\}
            \\
            \\// Read a null-terminated string from WASM memory
            \\function readCString(ptr) {
            \\    if (!ptr || !wasmMemory) return "";
            \\    const mem = new Uint8Array(wasmMemory.buffer);
            \\    let end = ptr;
            \\    while (mem[end] !== 0) end++;
            \\    return new TextDecoder().decode(mem.subarray(ptr, end));
            \\}
            \\
            \\// Write a 32-bit integer to WASM memory
            \\function writeI32(ptr, value) {
            \\    if (!wasmMemory) return;
            \\    const view = new DataView(wasmMemory.buffer);
            \\    view.setInt32(ptr, value, true); // little-endian
            \\}
            \\
            \\// Write a 64-bit float to WASM memory
            \\function writeF64(ptr, value) {
            \\    if (!wasmMemory) return;
            \\    const view = new DataView(wasmMemory.buffer);
            \\    view.setFloat64(ptr, value, true); // little-endian
            \\}
            \\
            \\// Emscripten runtime stubs
            \\const emscriptenStubs = {
            \\    // emscripten_return_address: Used for stack traces, return 0 (no info)
            \\    emscripten_return_address: (level) => 0,
            \\
            \\    // emscripten_get_now: High-resolution timestamp in milliseconds
            \\    emscripten_get_now: () => performance.now(),
            \\
            \\    // emscripten_set_main_loop: Set up requestAnimationFrame loop
            \\    emscripten_set_main_loop: (funcPtr, fps, simulateInfiniteLoop) => {
            \\        mainLoopCallback = funcPtr;
            \\        mainLoopRunning = true;
            \\
            \\        // Find the function table - Zig may export it as __indirect_function_table
            \\        const table = wasmInstance.exports.__indirect_function_table;
            \\        if (!table) {
            \\            console.error("Function table not found in WASM exports");
            \\            console.log("Available exports:", Object.keys(wasmInstance.exports));
            \\            return;
            \\        }
            \\
            \\        function frame() {
            \\            if (!mainLoopRunning) return;
            \\            try {
            \\                // Call the WASM callback function via the function table
            \\                const func = table.get(funcPtr);
            \\                if (!func) {
            \\                    console.error("Function not found at index", funcPtr);
            \\                    mainLoopRunning = false;
            \\                    return;
            \\                }
            \\                func();
            \\            } catch (e) {
            \\                console.error("Main loop error:", e);
            \\                console.error("Stack:", e.stack);
            \\                mainLoopRunning = false;
            \\                return;
            \\            }
            \\            animationFrameId = requestAnimationFrame(frame);
            \\        }
            \\
            \\        animationFrameId = requestAnimationFrame(frame);
            \\    },
            \\
            \\    // emscripten_cancel_main_loop: Stop the animation loop
            \\    emscripten_cancel_main_loop: () => {
            \\        mainLoopRunning = false;
            \\        if (animationFrameId !== null) {
            \\            cancelAnimationFrame(animationFrameId);
            \\            animationFrameId = null;
            \\        }
            \\    },
            \\
            \\    // emscripten_get_canvas_element_size: Get canvas dimensions
            \\    emscripten_get_canvas_element_size: (targetPtr, widthPtr, heightPtr) => {
            \\        const canvas = canvasElement || document.getElementById("canvas");
            \\        if (!canvas) {
            \\            writeI32(widthPtr, 800);
            \\            writeI32(heightPtr, 600);
            \\            return -6; // EMSCRIPTEN_RESULT_FAILED
            \\        }
            \\        writeI32(widthPtr, canvas.width);
            \\        writeI32(heightPtr, canvas.height);
            \\        return 0; // EMSCRIPTEN_RESULT_SUCCESS
            \\    },
            \\
            \\    // emscripten_get_device_pixel_ratio: Get DPI scaling
            \\    emscripten_get_device_pixel_ratio: () => window.devicePixelRatio || 1.0,
            \\
            \\    // emscripten_get_element_css_size: Get CSS size of an element
            \\    emscripten_get_element_css_size: (targetPtr, widthPtr, heightPtr) => {
            \\        const canvas = canvasElement || document.getElementById("canvas");
            \\        if (!canvas) {
            \\            writeF64(widthPtr, 800);
            \\            writeF64(heightPtr, 600);
            \\            return -6; // EMSCRIPTEN_RESULT_FAILED
            \\        }
            \\        const rect = canvas.getBoundingClientRect();
            \\        writeF64(widthPtr, rect.width);
            \\        writeF64(heightPtr, rect.height);
            \\        return 0; // EMSCRIPTEN_RESULT_SUCCESS
            \\    },
            \\
            \\    // Mouse event callbacks - store callback pointers but don't register yet
            \\    // (registration happens when WASM calls these, we just need to accept the call)
            \\    emscripten_set_mousemove_callback_on_thread: (target, userData, useCapture, callback, thread) => {
            \\        // For now, return success - full implementation would register DOM events
            \\        console.log("emscripten_set_mousemove_callback_on_thread called");
            \\        return 0;
            \\    },
            \\
            \\    emscripten_set_mousedown_callback_on_thread: (target, userData, useCapture, callback, thread) => {
            \\        console.log("emscripten_set_mousedown_callback_on_thread called");
            \\        return 0;
            \\    },
            \\
            \\    emscripten_set_mouseup_callback_on_thread: (target, userData, useCapture, callback, thread) => {
            \\        console.log("emscripten_set_mouseup_callback_on_thread called");
            \\        return 0;
            \\    },
            \\
            \\    // HTML5 event cleanup
            \\    emscripten_html5_remove_all_event_listeners: () => {
            \\        console.log("emscripten_html5_remove_all_event_listeners called");
            \\    },
            \\};
            \\
            \\// WebGPU stubs - these bridge WASM calls to browser WebGPU API
            \\// Note: Full implementation requires mapping WASM struct layouts to JS objects
            \\const webgpuStubs = {
            \\    wgpuDeviceCreateCommandEncoder: (deviceHandle, descriptorPtr) => {
            \\        if (!gpuDevice) return 0;
            \\        try {
            \\            const encoder = gpuDevice.createCommandEncoder();
            \\            return registerHandle(encoder);
            \\        } catch (e) {
            \\            console.error("wgpuDeviceCreateCommandEncoder error:", e);
            \\            return 0;
            \\        }
            \\    },
            \\
            \\    wgpuCommandEncoderBeginRenderPass: (encoderHandle, descriptorPtr) => {
            \\        const encoder = getHandle(encoderHandle);
            \\        if (!encoder || !gpuContext) return 0;
            \\        try {
            \\            // Get current texture from canvas context
            \\            const textureView = gpuContext.getCurrentTexture().createView();
            \\            const renderPass = encoder.beginRenderPass({
            \\                colorAttachments: [{
            \\                    view: textureView,
            \\                    clearValue: { r: 0.392, g: 0.584, b: 0.929, a: 1.0 }, // Cornflower blue
            \\                    loadOp: "clear",
            \\                    storeOp: "store",
            \\                }],
            \\            });
            \\            return registerHandle(renderPass);
            \\        } catch (e) {
            \\            console.error("wgpuCommandEncoderBeginRenderPass error:", e);
            \\            return 0;
            \\        }
            \\    },
            \\
            \\    wgpuRenderPassEncoderSetPipeline: (passHandle, pipelineHandle) => {
            \\        const pass = getHandle(passHandle);
            \\        const pipeline = getHandle(pipelineHandle);
            \\        if (pass && pipeline) {
            \\            pass.setPipeline(pipeline);
            \\        }
            \\    },
            \\
            \\    wgpuRenderPassEncoderSetBindGroup: (passHandle, index, groupHandle, dynamicOffsetCount, dynamicOffsets) => {
            \\        const pass = getHandle(passHandle);
            \\        const group = getHandle(groupHandle);
            \\        if (pass && group) {
            \\            pass.setBindGroup(index, group);
            \\        }
            \\    },
            \\
            \\    wgpuRenderPassEncoderSetVertexBuffer: (passHandle, slot, bufferHandle, offset, size) => {
            \\        const pass = getHandle(passHandle);
            \\        const buffer = getHandle(bufferHandle);
            \\        if (pass && buffer) {
            \\            pass.setVertexBuffer(slot, buffer, Number(offset), Number(size));
            \\        }
            \\    },
            \\
            \\    wgpuRenderPassEncoderDraw: (passHandle, vertexCount, instanceCount, firstVertex, firstInstance) => {
            \\        const pass = getHandle(passHandle);
            \\        if (pass) {
            \\            pass.draw(vertexCount, instanceCount, firstVertex, firstInstance);
            \\        }
            \\    },
            \\
            \\    wgpuRenderPassEncoderEnd: (passHandle) => {
            \\        const pass = getHandle(passHandle);
            \\        if (pass) {
            \\            pass.end();
            \\            freeHandle(passHandle);
            \\        }
            \\    },
            \\
            \\    wgpuCommandEncoderFinish: (encoderHandle, descriptorPtr) => {
            \\        const encoder = getHandle(encoderHandle);
            \\        if (!encoder) return 0;
            \\        try {
            \\            const commandBuffer = encoder.finish();
            \\            freeHandle(encoderHandle);
            \\            return registerHandle(commandBuffer);
            \\        } catch (e) {
            \\            console.error("wgpuCommandEncoderFinish error:", e);
            \\            return 0;
            \\        }
            \\    },
            \\
            \\    wgpuQueueSubmit: (queueHandle, commandCount, commandsPtr) => {
            \\        if (!gpuDevice) return;
            \\        try {
            \\            // Read command buffer handles from WASM memory
            \\            const view = new DataView(wasmMemory.buffer);
            \\            const commandBuffers = [];
            \\            for (let i = 0; i < commandCount; i++) {
            \\                const handle = view.getUint32(commandsPtr + i * 4, true);
            \\                const buffer = getHandle(handle);
            \\                if (buffer) {
            \\                    commandBuffers.push(buffer);
            \\                    freeHandle(handle);
            \\                }
            \\            }
            \\            if (commandBuffers.length > 0) {
            \\                gpuDevice.queue.submit(commandBuffers);
            \\            }
            \\        } catch (e) {
            \\            console.error("wgpuQueueSubmit error:", e);
            \\        }
            \\    },
            \\
            \\    wgpuQueueWriteBuffer: (queueHandle, bufferHandle, offset, dataPtr, size) => {
            \\        const buffer = getHandle(bufferHandle);
            \\        if (!gpuDevice || !buffer) return;
            \\        try {
            \\            const data = new Uint8Array(wasmMemory.buffer, dataPtr, Number(size));
            \\            gpuDevice.queue.writeBuffer(buffer, Number(offset), data);
            \\        } catch (e) {
            \\            console.error("wgpuQueueWriteBuffer error:", e);
            \\        }
            \\    },
            \\
            \\    wgpuDeviceTick: (deviceHandle) => {
            \\        // No-op: Browser handles device ticking automatically
            \\    },
            \\};
            \\
            \\export async function init(wasmPath) {
            \\    if (!navigator.gpu) {
            \\        throw new Error("WebGPU is not supported in this browser");
            \\    }
            \\
            \\    gpuAdapter = await navigator.gpu.requestAdapter();
            \\    if (!gpuAdapter) {
            \\        throw new Error("Failed to get WebGPU adapter");
            \\    }
            \\
            \\    gpuDevice = await gpuAdapter.requestDevice();
            \\
            \\    // Get canvas and configure WebGPU context
            \\    canvasElement = document.getElementById("canvas");
            \\    if (canvasElement) {
            \\        gpuContext = canvasElement.getContext("webgpu");
            \\        if (gpuContext) {
            \\            const format = navigator.gpu.getPreferredCanvasFormat();
            \\            gpuContext.configure({
            \\                device: gpuDevice,
            \\                format: format,
            \\                alphaMode: "opaque",
            \\            });
            \\            console.log("WebGPU context configured with format:", format);
            \\        }
            \\    }
            \\
            \\    const response = await fetch(wasmPath || "bin/zig_gui_experiment.wasm");
            \\    const wasmBytes = await response.arrayBuffer();
            \\
            \\    // Combine all stubs into importObject.env
            \\    const importObject = {
            \\        env: {
            \\            ...emscriptenStubs,
            \\            ...webgpuStubs,
            \\        },
            \\    };
            \\
            \\    const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
            \\    wasmInstance = instance;
            \\
            \\    // Get memory export from WASM
            \\    wasmMemory = instance.exports.memory;
            \\    if (!wasmMemory) {
            \\        console.warn("WASM module did not export memory");
            \\    }
            \\
            \\    console.log("WASM module loaded successfully");
            \\    const exportNames = Object.keys(instance.exports);
            \\    console.log("Exports:", exportNames.join(", "));
            \\
            \\    return {
            \\        instance,
            \\        device: gpuDevice,
            \\        adapter: gpuAdapter,
            \\        context: gpuContext,
            \\        exports: instance.exports,
            \\    };
            \\}
            \\
            \\export default { init };
            \\
        );

        // Install the JS glue file to the web output directory
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            js_glue.getDirectory().path(b, "zig_gui_experiment.js"),
            .{ .custom = "." },
            "zig_gui_experiment.js",
        ).step);

        // Copy index.html from web/ to the web output directory
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path("web/index.html"),
            .{ .custom = "." },
            "index.html",
        ).step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}
