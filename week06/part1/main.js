"use strict";

// Internal State
let g_zoomValue = 1.4;
let g_subpixelValue = 1;

// Jitter Computation
function compute_jitters(jitter, pixelsize, subdivs) {
    const step = pixelsize / subdivs;
    if (subdivs < 2) {
        jitter[0] = 0.0;
        jitter[1] = 0.0;
    }
    else {
        for (var i = 0; i < subdivs; ++i)
            for (var j = 0; j < subdivs; ++j) {
                const idx = (i * subdivs + j) * 2;
                jitter[idx] = (Math.random() + j) * step - pixelsize * 0.5;
                jitter[idx + 1] = (Math.random() + i) * step - pixelsize * 0.5;
            }
    }
}

// UI Setup
function setupOptions(callback) {
    const gammaSlider = document.getElementById('gamma-slider');
    gammaSlider.oninput = (e) => {
        document.getElementById('gamma-slider-label').innerText = e.target.value;
        callback();
    };

    document.getElementById('triangle-shader-select').onchange = () => {
        callback();
    };

    document.getElementById('render-button').onclick = () => {
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

        g_zoomValue = Math.min(Math.max(g_zoomValue, 0.5), 5.0);
        document.getElementById('zoom-label').innerText = g_zoomValue.toFixed(1);
        
        callback();
    }, { passive: false });

    const subLabel = document.getElementById('subpixel-label');
    
    document.getElementById('subpixel-decr').onclick = () => {
        if (g_subpixelValue > 1) {
            g_subpixelValue--;
            subLabel.innerText = g_subpixelValue;
            callback();
        }
    };

    document.getElementById('subpixel-incr').onclick = () => {
        if (g_subpixelValue < 10) {
            g_subpixelValue++;
            subLabel.innerText = g_subpixelValue;
            callback();
        }
    };
}

// Option Retrieval
function getOptions() {
    const gamma = document.getElementById('gamma-slider').value;
    const triangleShaderIndex = document.getElementById('triangle-shader-select').value;
    
    return {
        gamma,
        cameraConstant: g_zoomValue,
        triangleShaderIndex,
        subpixelCount: g_subpixelValue,
    };
}

// Entry Point
window.onload = function () { main(); }

// Main Application Logic
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

    const canvas = document.getElementById('my-canvas');
    const context = canvas.getContext('webgpu');
    const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device: device,
        format: canvasFormat,
    });

    const wgslcode = await fetch("shader.wgsl").then(r => r.text());
    const wgsl = device.createShaderModule({
        code: wgslcode
    });

    const obj_filename = '../../objects/teapot.obj';
    const obj = await readOBJFile(obj_filename, 1, true); 

    const buffers = {};
    build_bsp_tree(obj, device, buffers);

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

    const matidxBuffer = device.createBuffer({
        size: obj.mat_indices.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
    });
    device.queue.writeBuffer(matidxBuffer, 0, obj.mat_indices);

    const lightidxBuffer = device.createBuffer({
        size: obj.light_indices.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
    });
    device.queue.writeBuffer(lightidxBuffer, 0, obj.light_indices);

    const pipeline = device.createRenderPipeline({
        layout: 'auto',
        vertex: { module: wgsl, entryPoint: 'main_vs' },
        fragment: {
            module: wgsl,
            entryPoint: 'main_fs',
            targets: [{ format: canvasFormat }],
        },
        primitive: { topology: 'triangle-strip', },
    });

    let jitter = new Float32Array(200); 
    const jitterBuffer = device.createBuffer({
        size: jitter.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
    });

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
            { binding: 2, resource: { buffer: jitterBuffer } },
            { binding: 3, resource: { buffer: buffers.positions } },
            { binding: 4, resource: { buffer: buffers.indices } },
            { binding: 5, resource: { buffer: buffers.normals } },
            { binding: 6, resource: { buffer: materialBuffer } },
            { binding: 7, resource: { buffer: matidxBuffer } },
            { binding: 9, resource: { buffer: buffers.aabb } },
        ],
    });

    const eye = [0.15, 1.5, 10.0];
    const look = [0.15, 1.5, 0.0];
    const up = [0.0, 1.0, 0.0];

    const v_dir = normalize(subtract(look, eye));
    const b1_dir = normalize(cross(v_dir, up));
    const b2_dir = normalize(cross(b1_dir, v_dir));

    const aspect = canvas.width / canvas.height;

    function render() {
        let opt = getOptions();

        compute_jitters(jitter, 1 / canvas.height, opt.subpixelCount);
        device.queue.writeBuffer(jitterBuffer, 0, jitter);

        new Float32Array(uniforms, 0, 4 * 7).set([
            aspect, opt.cameraConstant, opt.gamma, 0.0,
            0.0, 0.0, 0.0, 0.0,
            ...eye, 0.0,
            ...b1_dir, 0.0,
            ...b2_dir, 0.0,
            ...v_dir, 0.0,
        ]);
        new Uint32Array(uniforms, 4 * 3, 2).set([
            opt.triangleShaderIndex,
            opt.subpixelCount,
        ]);
        device.queue.writeBuffer(uniformBuffer, 0, uniforms);

        const encoder = device.createCommandEncoder();
        const pass = timingHelper.beginRenderPass(encoder, {
            colorAttachments: [{
                view: context.getCurrentTexture().createView(),
                loadOp: "clear",
                storeOp: "store",
            }]
        });
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bindGroup);
        pass.draw(4);
        pass.end();
        device.queue.submit([encoder.finish()]);

        timingHelper.getResult().then(time => {
            if (time > 0) {
                console.log(`GPU time: ${(time / 1000000).toFixed(3)} ms`);
            }
        });
    }

    setupOptions(render);
    render();
}