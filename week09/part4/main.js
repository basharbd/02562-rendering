"use strict";

// -------------------------------------------------------------------------
// Global State & Texture Loading
// -------------------------------------------------------------------------
let g_zoomValue = 1.25;

async function load_texture(device, filename) {
    const response = await fetch(filename);
    const blob = await response.blob();
    const img = await createImageBitmap(blob, { colorSpaceConversion: 'none' });
    const texture = device.createTexture({
        size: [img.width, img.height, 1],
        format: "rgba8unorm",
        usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.RENDER_ATTACHMENT
    });
    device.queue.copyExternalImageToTexture(
        { source: img, flipY: true },
        { texture: texture },
        { width: img.width, height: img.height },
    );
    return texture;
}

// -------------------------------------------------------------------------
// UI Event Handlers
// -------------------------------------------------------------------------
function setupOptions(callback) {
    const gammaSlider = document.getElementById('gamma-slider');
    gammaSlider.oninput = (e) => {
        document.getElementById('gamma-slider-label').innerText = e.target.value;
        callback();
    };

    document.getElementById('triangle-shader-select').onchange = () => {
        callback();
    };

    const canvas = document.getElementById('my-canvas');
    canvas.addEventListener('wheel', (event) => {
        event.preventDefault();
        const sensitivity = 0.05;
        if (event.deltaY < 0) {
            g_zoomValue += sensitivity;
        } else {
            g_zoomValue -= sensitivity;
        }
        g_zoomValue = Math.min(Math.max(g_zoomValue, 0.1), 10.0);
        document.getElementById('zoom-label').innerText = g_zoomValue.toFixed(2);
        callback();
    }, { passive: false });
}

function getOptions() {
    const gamma = document.getElementById('gamma-slider').value;
    const triangleShaderIndex = document.getElementById('triangle-shader-select').value;
    
    return {
        gamma,
        cameraConstant: g_zoomValue,
        triangleShaderIndex,
    };
}

window.onload = function () { main(); }

// -------------------------------------------------------------------------
// Main WebGPU Application
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
    // Resource Loading (Shader & Environment Map)
    // ---------------------------------------------------------------------
    const wgslcode = await fetch("shader.wgsl").then(r => r.text());
    const wgsl = device.createShaderModule({
        code: wgslcode
    });

    const texture = await load_texture(device, '../../backgrounds/hangar_interior_4k.RGBE.PNG');

    // ---------------------------------------------------------------------
    // Scene Geometry & BSP Tree Construction
    // ---------------------------------------------------------------------
    const models = {
        'bunny': {
            path: '../../objects/bunny.obj',
            cameraConstant: 3.5,
            eye: vec3(-0.3, 0.14, 0.4),
            look: vec3(-0.02, 0.11, 0.0),
            up: vec3(0.0, 1.0, 0.0),
        },
    }
    const model = models['bunny'];
    const obj = await readOBJFile(model.path, 1.0, true);

    const buffers = {};
    build_bsp_tree(obj, device, buffers);

    // ---------------------------------------------------------------------
    // Material Buffer Setup
    // ---------------------------------------------------------------------
    let mat_bytelength = obj.materials.length * 2 * 16;
    var materials = new ArrayBuffer(mat_bytelength);
    const materialBuffer = device.createBuffer({
        size: mat_bytelength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
    });
    for (var i = 0; i < obj.materials.length; ++i) {
        const mat = obj.materials[i];
        const emission = [mat.emission.r, mat.emission.g, mat.emission.b, mat.emission.a];
        const color = [mat.color.r, mat.color.g, mat.color.b, mat.color.a];
        new Float32Array(materials, i * 2 * 16, 8).set([...emission, ...color]);
    }
    device.queue.writeBuffer(materialBuffer, 0, materials);

    // ---------------------------------------------------------------------
    // Render Pipeline & Texture Storage
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
    // Uniforms and Bind Groups
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
            { binding: 1, resource: texture.createView() },
            { binding: 2, resource: { buffer: buffers.attribs } },
            { binding: 3, resource: { buffer: buffers.indices } },
            { binding: 4, resource: textures.renderDst.createView() },
            { binding: 5, resource: { buffer: materialBuffer } },
            { binding: 6, resource: { buffer: buffers.aabb } },
            { binding: 7, resource: { buffer: buffers.treeIds } },
            { binding: 8, resource: { buffer: buffers.bspTree } },
            { binding: 9, resource: { buffer: buffers.bspPlanes } },
        ],
    });

    // ---------------------------------------------------------------------
    // Camera Configuration
    // ---------------------------------------------------------------------
    const { eye, look, up } = model;
    const v = normalize(subtract(look, eye));
    const b1 = normalize(cross(v, up));
    const b2 = normalize(cross(b1, v));
    const aspect = canvas.width / canvas.height;

    // ---------------------------------------------------------------------
    // Progressive Rendering Loop
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

    function render() {
        let opt = getOptions();

        new Float32Array(uniforms, 0, 4 * 7).set([
            aspect, opt.cameraConstant, opt.gamma, 0.0,
            0.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0,
            ...eye, 0.0,
            ...b1, 0.0,
            ...b2, 0.0,
            ...v, 0.0,
        ]);
        new Uint32Array(uniforms, 4 * 3, 6).set([
            opt.triangleShaderIndex,
            canvas.width,
            canvas.height,
            frame,
            noOfJitters,
            1 
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
        document.getElementById('frame-label').innerText = `Frame: 0`;
        if (!keepRender) { requestAnimationFrame(progressiveRender); }
    });
    
    progressiveRender();
}