"use strict";

// Entry Point
window.onload = function () {
    main();
};

// Main Application Logic
async function main() {
    // GPU Initialization
    const gpu = navigator.gpu;
    const adapter = await gpu.requestAdapter();
    const device = await adapter.requestDevice();

    // Canvas Setup
    const canvas = document.getElementById("webgpu-canvas");
    const context = canvas.getContext("gpupresent") || canvas.getContext("webgpu");
    const canvasFormat = navigator.gpu.getPreferredCanvasFormat();

    configureCanvasContext(context, device, canvasFormat);

    const pixelSize = 1 / canvas.height;
    
    // Model Loading
    const objFilename = '../../objects/teapot.obj';
    const drawingInfo = await loadOBJFile(objFilename, 1, true);

    // Buffer Creation
    const vBuffer = createBuffer(device, drawingInfo.vertices, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);
    const iBuffer = createBuffer(device, drawingInfo.indices, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);

    const {uniforms, uniformBuffer} = createUniformBuffer(device, canvas);
    const jitterBuffer = createJitterBuffer(device, 200);

    // Pipeline Creation
    const pipeline = await createRenderPipeline(device, canvasFormat);

    // Event Handling
    setupEventListeners(uniforms, uniformBuffer, device, animate);

    let bindGroup;

    // Animation Loop
    function animate() {
        bindGroup = createBindGroup(device, pipeline, uniformBuffer, jitterBuffer, vBuffer, iBuffer);
        render();
    }

    function render() {
        computeJitters(jitterBuffer, device, pixelSize, uniforms[2]);
        executeRenderPass(device, context, pipeline, bindGroup);
    }

    animate();
}

// Canvas Configuration
function configureCanvasContext(context, device, format) {
    context.configure({
        device: device,
        format: format,
    });
}

// OBJ Loading Wrapper
async function loadOBJFile(filename, scale, ccw) {
    return await readOBJFile(filename, scale, ccw);
}

// Buffer Utility
function createBuffer(device, data, usage) {
    const buffer = device.createBuffer({
        size: data.byteLength,
        usage: usage,
    });
    device.queue.writeBuffer(buffer, 0, data);
    return buffer;
}

// Uniform Buffer Setup
function createUniformBuffer(device, canvas) {
    const aspect = canvas.width / canvas.height;
    const cameraConstant = 2.5;
    const jitterSub = 1;
    
    const uniforms = new Float32Array([aspect, cameraConstant, jitterSub, 0]);

    const uniformBuffer = device.createBuffer({
        size: uniforms.byteLength, 
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    device.queue.writeBuffer(uniformBuffer, 0, uniforms);

    return {uniforms, uniformBuffer};
}

// Jitter Buffer Setup
function createJitterBuffer(device, length) {
    const jitter = new Float32Array(length);
    const buffer = device.createBuffer({
        size: jitter.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
    });
    return buffer;
}

// Render Pipeline Construction
async function createRenderPipeline(device, format) {
    const shaderModule = device.createShaderModule({
        code: await (await fetch("shader.wgsl")).text()
    });

    return device.createRenderPipeline({
        layout: "auto",
        vertex: {
            module: shaderModule,
            entryPoint: "main_vs",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "main_fs",
            targets: [{ format: format }],
        },
        primitive: {
            topology: "triangle-strip",
        },
    });
}

// Event Listeners
function setupEventListeners(uniforms, uniformBuffer, device, animatecallback) {
    addEventListener("wheel", function (ev) {
        ev.preventDefault(); 
        
        const zoom = ev.deltaY > 0 ? 0.95 : 1.05;
        uniforms[1] *= zoom;
        device.queue.writeBuffer(uniformBuffer, 0, uniforms);
        animatecallback();
    }, { passive: false });
}

// Bind Group Creation
function createBindGroup(device, pipeline, uniformBuffer, jitterBuffer, vBuffer, iBuffer) {
    return device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
            { binding: 0, resource: { buffer: uniformBuffer } },
            { binding: 1, resource: { buffer: jitterBuffer } },
            { binding: 2, resource: { buffer: vBuffer } },
            { binding: 3, resource: { buffer: iBuffer } },
        ],
    });
}

// Jitter Computation
function computeJitters(jitterBuffer, device, pixelSize, jitterSub) {
    const jitter = new Float32Array(jitterBuffer.size / Float32Array.BYTES_PER_ELEMENT);
    const step = pixelSize / jitterSub;

    if (jitterSub < 2) {
        jitter[0] = 0.0;
        jitter[1] = 0.0;
    } else {
        for (let i = 0; i < jitterSub; ++i) {
            for (let j = 0; j < jitterSub; ++j) {
                const idx = (i * jitterSub + j) * 2;
                jitter[idx] = (Math.random() + j) * step - pixelSize * 0.5;
                jitter[idx + 1] = (Math.random() + i) * step - pixelSize * 0.5;
            }
        }
    }

    device.queue.writeBuffer(jitterBuffer, 0, jitter);
}

// Render Pass Execution
function executeRenderPass(device, context, pipeline, bindGroup) {
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
        colorAttachments: [{
            view: context.getCurrentTexture().createView(),
            loadOp: "clear",
            storeOp: "store",
        }],
    });

    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(4);
    pass.end();

    device.queue.submit([encoder.finish()]);
}