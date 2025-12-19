"use strict";

// -------------------------------------------------------------------------
// Global State & UI Interaction
// -------------------------------------------------------------------------
let g_zoomValue = 1.0;

function setupOptions(callback) {
    const gammaSlider = document.getElementById('gamma-slider');
    gammaSlider.oninput = (e) => {
        document.getElementById('gamma-slider-label').innerText = e.target.value;
        callback();
    };

    document.getElementById('triangle-shader-select').onchange = () => {
        callback();
    };
    document.getElementById('enable-background').onchange = () => {
        callback();
    };

    const canvas = document.getElementById('my-canvas');
    canvas.addEventListener('wheel', (event) => {
        event.preventDefault();
        const sensitivity = 0.1;
        if (event.deltaY < 0) {
            g_zoomValue += sensitivity;
        } else {
            g_zoomValue -= sensitivity;
        }
        g_zoomValue = Math.min(Math.max(g_zoomValue, 0.1), 10.0);
        document.getElementById('zoom-label').innerText = g_zoomValue.toFixed(1);
        callback();
    }, { passive: false });
}

function getOptions() {
    const gamma = document.getElementById('gamma-slider').value;
    const triangleShaderIndex = document.getElementById('triangle-shader-select').value;
    const enableBackground = document.getElementById('enable-background').checked ? 1 : 0;

    return {
        gamma,
        cameraConstant: g_zoomValue,
        triangleShaderIndex,
        enableBackground,
    };
}

window.onload = function () { main(); }

// -------------------------------------------------------------------------
// Main WebGPU Entry Point
// -------------------------------------------------------------------------
async function main() {
    const gpu = navigator.gpu;
    const adapter = await gpu.requestAdapter();

    const canTimestamp = adapter.features.has('timestamp-query');
    const device = await adapter.requestDevice({
        requiredFeatures: [
            ...(canTimestamp ? ['timestamp-query'] : []),
        ],
    });
    const timingHelper = new TimingHelper(device);
    let gpuTime = 0;

    const canvas = document.getElementById('my-canvas');
    const context = canvas.getContext('webgpu');
    const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device: device,
        format: canvasFormat,
    });

    // ---------------------------------------------------------------------
    // Shader Compilation
    // ---------------------------------------------------------------------
    const wgslcode = await fetch("shader.wgsl").then(r => r.text());
    const wgsl = device.createShaderModule({
        code: wgslcode
    });

    // ---------------------------------------------------------------------
    // Scene Data & Acceleration Structure
    // ---------------------------------------------------------------------
    const models = {
        'CornellBox': {
            path: '../../objects/CornellBox.obj',
            eye: vec3(277.0, 275.0, -570.0),
            look: vec3(277.0, 275.0, 0.0),
            up: vec3(0.0, 1.0, 0.0),
        },
    }
    const model = models['CornellBox'];
    const obj = await readOBJFile(model.path, 1.0, true);

    const buffers = {};
    build_bsp_tree(obj, device, buffers);

    // ---------------------------------------------------------------------
    // Material & Light Buffers
    // ---------------------------------------------------------------------
    let mat_bytelength = obj.materials.length * 2 * 16;
    var materials = new ArrayBuffer(mat_bytelength);
    const materialBuffer = device.createBuffer({
        size: mat_bytelength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
    });
    for (var i = 0; i < obj.materials.length; ++i) {
        const mat = obj.materials[i];
        const emission = vec4(mat.emission.r, mat.emission.g, mat.emission.b, mat.emission.a);
        const color = vec4(mat.color.r, mat.color.g, mat.color.b, mat.color.a);
        new Float32Array(materials, i * 2 * 16, 8).set([...emission, ...color]);
    }
    device.queue.writeBuffer(materialBuffer, 0, materials);

    const lightidxBuffer = device.createBuffer({
        size: obj.light_indices.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
    });
    device.queue.writeBuffer(lightidxBuffer, 0, obj.light_indices);

    // ---------------------------------------------------------------------
    // Render Pipeline Configuration
    // ---------------------------------------------------------------------
    const pipeline = device.createRenderPipeline({
        layout: 'auto',
        vertex: { module: wgsl, entryPoint: 'main_vs' },
        fragment: {
            module: wgsl,
            entryPoint: 'main_fs',
            targets: [
                { format: canvasFormat },
                { format: 'rgba32float' }
            ],
        },
        primitive: { topology: 'triangle-strip', },
    });

    // ---------------------------------------------------------------------
    // Texture Management (Ping-Pong)
    // ---------------------------------------------------------------------
    let textures = new Object();
    textures.width = canvas.width;
    textures.height = canvas.height;
    textures.renderSrc = device.createTexture({
        size: [canvas.width, canvas.height],
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
        format: 'rgba32float',
    });
    textures.renderDst = device.createTexture({
        size: [canvas.width, canvas.height],
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        format: 'rgba32float',
    });

    // ---------------------------------------------------------------------
    // Uniform Buffers & Bind Groups
    // ---------------------------------------------------------------------
    let bytelength = 7 * 16;
    let uniforms = new ArrayBuffer(bytelength);
    const uniformBuffer = device.createBuffer({
        size: uniforms.byteLength,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    const bindGroup = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
            { binding: 0, resource: { buffer: uniformBuffer } },
            { binding: 2, resource: { buffer: buffers.attribs } },
            { binding: 3, resource: { buffer: buffers.indices } },
            { binding: 4, resource: textures.renderDst.createView() },
            { binding: 5, resource: { buffer: materialBuffer } },
            { binding: 6, resource: { buffer: buffers.aabb } },
            { binding: 7, resource: { buffer: buffers.treeIds } },
            { binding: 8, resource: { buffer: buffers.bspTree } },
            { binding: 9, resource: { buffer: buffers.bspPlanes } },
            { binding: 10, resource: { buffer: lightidxBuffer } },
        ],
    });

    // ---------------------------------------------------------------------
    // Camera Initialization
    // ---------------------------------------------------------------------
    const { eye, look, up } = model;
    const v = normalize(subtract(look, eye));
    const b1 = normalize(cross(v, up));
    const b2 = normalize(cross(b1, v));
    const aspect = canvas.width / canvas.height;

    // ---------------------------------------------------------------------
    // Render Loop Control
    // ---------------------------------------------------------------------
    let frame = 0;
    const noOfJitters = 1;
    let keepRender = false;

    document.getElementById('render-button').onclick = () => {
        if (!keepRender) { requestAnimationFrame(progressiveRender); }
    };

    document.getElementById('render-toggle').onclick = () => {
        keepRender = !keepRender;
        if (keepRender) { requestAnimationFrame(progressiveRender); }
    }

    document.getElementById('render-reset').onclick = () => {
        frame = 0;
        document.getElementById('frame-label').innerText = `Frame: 0`;
        if (!keepRender) { requestAnimationFrame(progressiveRender); }
    }

    function progressiveRender() {
        render();
        frame++;
        document.getElementById('frame-label').innerText = `Frame: ${frame}`;
        if (keepRender) { requestAnimationFrame(progressiveRender); }
    }

    // ---------------------------------------------------------------------
    // Frame Rendering Logic
    // ---------------------------------------------------------------------
    function render() {
        let { gamma, cameraConstant, triangleShaderIndex, enableBackground } = getOptions();

        new Float32Array(uniforms, 0, 4 * 7).set([
            aspect, cameraConstant, gamma, 0.0,
            0.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0,
            ...eye, 0.0,
            ...b1, 0.0,
            ...b2, 0.0,
            ...v, 0.0,
        ]);
        new Uint32Array(uniforms, 4 * 3, 6).set([
            triangleShaderIndex, canvas.width, canvas.height, frame, noOfJitters, enableBackground
        ]);
        device.queue.writeBuffer(uniformBuffer, 0, uniforms);

        const encoder = device.createCommandEncoder();
        const pass = timingHelper.beginRenderPass(encoder, {
            colorAttachments: [
                { view: context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", },
                { view: textures.renderSrc.createView(), loadOp: "load", storeOp: "store", }
            ]
        });

        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bindGroup);
        pass.draw(4);
        pass.end();

        encoder.copyTextureToTexture({ texture: textures.renderSrc }, { texture: textures.renderDst }, [textures.width, textures.height]);

        device.queue.submit([encoder.finish()]);
        timingHelper.getResult().then(time => {
            if (time > 0) console.log(`GPU time: ${(time / 1000000).toFixed(3)} ms`);
        });
    }

    setupOptions(() => {
        frame = 0;
        if (!keepRender) { requestAnimationFrame(progressiveRender); }
    });
    
    progressiveRender();
}