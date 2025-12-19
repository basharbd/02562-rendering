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
    const objFilename = '../../objects/CornellBoxWithBlocks.obj';
    const drawingInfo = await readOBJFile(objFilename, 1, true);

    // Buffer Creation
    const vBuffer = createBuffer(device, drawingInfo.vertices, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);
    const iBuffer = createBuffer(device, drawingInfo.indices, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);
    const nBuffer = createBuffer(device, drawingInfo.normals, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);
    const miBuffer = createBuffer(device, drawingInfo.mat_indices, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);

    // Material Data Setup
    const {mc, me} = matrialcolorandemission(drawingInfo.materials);
    const mcBuffer = createBuffer(device, mc, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);
    const meBuffer = createBuffer(device, me, GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE);

    const {uniforms, uniformBuffer} = createUniformBuffer(device, canvas);
    const jitterBuffer = createJitterBuffer(device, 200);

    // Pipeline Creation
    const pipeline = await createRenderPipeline(device, canvasFormat);

    // Event Handling
    setupEventListeners(uniforms, uniformBuffer, device, animate);

    // Bind Group Setup
    let bindGroup = createBindGroup(device, pipeline, uniformBuffer, jitterBuffer, vBuffer, iBuffer, nBuffer, miBuffer, mcBuffer, meBuffer);

    // Animation Loop
    function animate() {
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
    const cameraConstant = 1;
    const jitterSub = 1;
    const eye = [0.15, 1.5, 10.0];
    const lookat = [0.15, 1.5, 0.0];
    const up = [0.0, 1.0, 0.0];
    
    const uniforms = new Float32Array([aspect, cameraConstant, jitterSub, eye, lookat, up]);

    const uniformBuffer = device.createBuffer({
        size: uniforms.byteLength, 
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    device.queue.writeBuffer(uniformBuffer, 0, uniforms);

    return {uniforms, uniformBuffer};
}

// Material Processing
function matrialcolorandemission(materials) {
    let mc = new Float32Array(materials.length * 4);
    let me = new Float32Array(materials.length * 4);
    for (var i = 0; i < materials.length; i++) {
        mc[i * 4 + 0] = materials[i].color.r;
        mc[i * 4 + 1] = materials[i].color.g;
        mc[i * 4 + 2] = materials[i].color.b;
        mc[i * 4 + 3] = materials[i].color.a;
    }

    for (var i = 0; i < materials.length; i++) {
        me[i * 4 + 0] = materials[i].emission.r;
        me[i * 4 + 1] = materials[i].emission.g; 
        me[i * 4 + 2] = materials[i].emission.b;
        me[i * 4 + 3] = materials[i].emission.a;
    }
    return {mc, me};
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
function createBindGroup(device, pipeline, uniformBuffer, jitterBuffer, vBuffer, iBuffer, nBuffer, miBuffer, mcBuffer, meBuffer) {
    return device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
            { binding: 0, resource: { buffer: uniformBuffer } },
            { binding: 1, resource: { buffer: jitterBuffer } },
            { binding: 2, resource: { buffer: vBuffer } },
            { binding: 3, resource: { buffer: iBuffer } },
            { binding: 4, resource: { buffer: nBuffer } },
            { binding: 5, resource: { buffer: miBuffer } },
            { binding: 6, resource: { buffer: mcBuffer } },
            { binding: 7, resource: { buffer: meBuffer } },
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