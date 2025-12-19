"use strict";

window.onload = function () { main(); }

async function main() {
    // Initialize WebGPU device and context
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
        document.getElementById("error-container").innerText = "WebGPU not supported on this browser.";
        document.getElementById("error-container").style.display = "block";
        return;
    }
    const device = await adapter.requestDevice();
    const canvas = document.getElementById("webgpu-canvas");
    const context = canvas.getContext("gpupresent") || canvas.getContext("webgpu");
    const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
    context.configure({ device: device, format: canvasFormat });

    const objData = await fetch("../../objects/teapot.obj").then(r => r.text());
    const mesh = parseOBJ_Simple(objData);

    // Create GPU buffers for vertex and index data
    const vBuffer = device.createBuffer({
        size: mesh.vertices.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
    });
    device.queue.writeBuffer(vBuffer, 0, mesh.vertices);

    const iBuffer = device.createBuffer({
        size: mesh.indices.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
    });
    device.queue.writeBuffer(iBuffer, 0, mesh.indices);

    let jitter = new Float32Array(200); 
    const jitterBuffer = device.createBuffer({
        size: jitter.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
    });

    // Initialize rendering parameters
    const aspect = canvas.width / canvas.height;
    let params = {
        cam_const: 1.0,
        sphereMaterial: 5.0,
        material: 1.0,
        subdivs: 4.0,
        scalingFactor: 0.2,
        aspect: aspect
    };
    
    let uniformsData = new Float32Array([
        params.aspect, params.cam_const, params.sphereMaterial, 
        params.material, params.subdivs, params.scalingFactor
    ]);

    const uniformBuffer = device.createBuffer({
        size: uniformsData.byteLength,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    // Load shader and create render pipeline
    const wgslCode = await (await fetch("shader.wgsl")).text();
    const shaderModule = device.createShaderModule({ code: wgslCode });

    const pipeline = device.createRenderPipeline({
        layout: "auto",
        vertex: {
            module: shaderModule,
            entryPoint: "main_vs",
        },
        fragment: {
            module: shaderModule,
            entryPoint: "main_fs",
            targets: [{ format: canvasFormat }]
        },
        primitive: { topology: "triangle-strip" },
    });

    // Load texture with different samplers for different rendering modes
    const texture = await load_texture(device, "../../textures/grass.jpg");
    const samplerClamp = device.createSampler({ addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge", minFilter: "linear", magFilter: "linear" });
    const samplerRepeat = device.createSampler({ addressModeU: "repeat", addressModeV: "repeat", minFilter: "nearest", magFilter: "nearest" });

    // Create bind groups for different rendering configurations
    const bindGroup0 = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
            { binding: 0, resource: { buffer: uniformBuffer } },
            { binding: 1, resource: samplerClamp },
            { binding: 2, resource: texture.createView() },
            { binding: 3, resource: { buffer: jitterBuffer } },
            { binding: 4, resource: { buffer: vBuffer } },
            { binding: 5, resource: { buffer: iBuffer } },
        ],
    });

    const bindGroup1 = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
            { binding: 0, resource: { buffer: uniformBuffer } },
            { binding: 1, resource: samplerRepeat },
            { binding: 2, resource: texture.createView() },
            { binding: 3, resource: { buffer: jitterBuffer } },
            { binding: 4, resource: { buffer: vBuffer } },
            { binding: 5, resource: { buffer: iBuffer } },
        ],
    });

    const bindGroups = [bindGroup0, bindGroup1];
    let currentGroup = 1;

    function updateUniforms() {
        uniformsData[0] = params.aspect;
        uniformsData[1] = params.cam_const;
        uniformsData[2] = params.sphereMaterial;
        uniformsData[3] = params.material;
        uniformsData[4] = params.subdivs;
        uniformsData[5] = params.scalingFactor;
        device.queue.writeBuffer(uniformBuffer, 0, uniformsData);
    }

    // Setup UI event listeners
    document.getElementById("sphereMenu").addEventListener("change", (e) => { params.sphereMaterial = parseFloat(e.target.value); requestFrame(); });
    document.getElementById("materialMenu").addEventListener("change", (e) => { params.material = parseFloat(e.target.value); requestFrame(); });
    document.getElementById("imageStyle").addEventListener("change", (e) => { currentGroup = parseInt(e.target.value); requestFrame(); });
    
    document.getElementById("increase").addEventListener("click", () => { 
        if(params.subdivs < 10) params.subdivs++; 
        requestFrame(); 
    });
    document.getElementById("decrease").addEventListener("click", () => { 
        if(params.subdivs > 1) params.subdivs--; 
        requestFrame(); 
    });

    canvas.addEventListener("wheel", (e) => {
        e.preventDefault();
        let zoom = e.deltaY > 0 ? 0.95 : 1.05;
        params.cam_const *= zoom;
        requestFrame();
    }, { passive: false });

    let frameId;
    function requestFrame() {
        if (!frameId) {
            frameId = requestAnimationFrame(renderFrame);
        }
    }

    // Main rendering loop
    function renderFrame() {
        updateUniforms();
        compute_jitters(jitter, 1 / canvas.height, params.subdivs);
        device.queue.writeBuffer(jitterBuffer, 0, jitter);

        const encoder = device.createCommandEncoder();
        const pass = encoder.beginRenderPass({
            colorAttachments: [{
                view: context.getCurrentTexture().createView(),
                loadOp: "clear",
                storeOp: "store",
                clearValue: { r: 0.1, g: 0.1, b: 0.1, a: 1.0 }
            }]
        });

        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bindGroups[currentGroup]);
        pass.draw(4);
        pass.end();

        device.queue.submit([encoder.finish()]);
        frameId = null;
    }


    requestFrame();
}
// Parse OBJ file format and extract vertex and index data
function parseOBJ_Simple(text) {
    const positions = [];
    const indices = [];
    const lines = text.split('\n');
    
    for (let line of lines) {
        line = line.trim();
        if (line.startsWith('v ')) {
            const parts = line.split(/\s+/);
            positions.push(parseFloat(parts[1]), parseFloat(parts[2]), parseFloat(parts[3]), 1.0);
        } else if (line.startsWith('f ')) {
            const parts = line.split(/\s+/);

            const idx0 = parseInt(parts[1].split('/')[0]) - 1;
            const idx1 = parseInt(parts[2].split('/')[0]) - 1;
            const idx2 = parseInt(parts[3].split('/')[0]) - 1;
            indices.push(idx0, idx1, idx2, 0);
        }
    }

    return {
        vertices: new Float32Array(positions),
        indices: new Uint32Array(indices)
    };
}

// Load and create GPU texture from image URL
async function load_texture(device, url) {
    const res = await fetch(url);
    const blob = await res.blob();
    const bitmap = await createImageBitmap(blob, { colorSpaceConversion: 'none' });
    
    const tex = device.createTexture({
        size: [bitmap.width, bitmap.height, 1],
        format: 'rgba8unorm',
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT
    });
    
    device.queue.copyExternalImageToTexture(
        { source: bitmap, flipY: true },
        { texture: tex },
        { width: bitmap.width, height: bitmap.height }
    );
    return tex;
}

// Generate random jitter offsets for anti-aliasing
function compute_jitters(jitter, pixelsize, subdivs) {
    const step = pixelsize / subdivs;
    if (subdivs < 2) {
        jitter[0] = 0.0; jitter[1] = 0.0;
        return;
    }
    for (let i = 0; i < subdivs; ++i) {
        for (let j = 0; j < subdivs; ++j) {
            const idx = (i * subdivs + j) * 2;
            jitter[idx] = (Math.random() + j) * step - pixelsize * 0.5;
            jitter[idx + 1] = (Math.random() + i) * step - pixelsize * 0.5;
        }
    }
}