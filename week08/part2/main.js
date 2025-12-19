"use strict";

// Initialize the global zoom level for the camera
let g_zoomValue = 1.0;

function setupOptions(callback) {
    // Attach an event listener to the gamma slider to update the label and trigger a re-render
    const gammaSlider = document.getElementById('gamma-slider');
    gammaSlider.oninput = (e) => {
        document.getElementById('gamma-slider-label').innerText = e.target.value;
        callback();
    };

    // Attach change listeners to dropdowns and checkboxes to trigger re-renders
    document.getElementById('triangle-shader-select').onchange = () => {
        callback();
    };
    document.getElementById('enable-background').onchange = () => {
        callback();
    };

    // Attach a wheel event listener to the canvas for controlling the zoom level
    const canvas = document.getElementById('my-canvas');
    canvas.addEventListener('wheel', (event) => {
        event.preventDefault();
        const sensitivity = 0.1;
        // Adjust zoom based on scroll direction
        if (event.deltaY < 0) {
            g_zoomValue += sensitivity;
        } else {
            g_zoomValue -= sensitivity;
        }
        // Clamp the zoom value between 0.1 and 10.0
        g_zoomValue = Math.min(Math.max(g_zoomValue, 0.1), 10.0);
        document.getElementById('zoom-label').innerText = g_zoomValue.toFixed(1);
        callback();
    }, { passive: false });
}

function getOptions() {
    // Retrieve the current values from the UI elements
    const gamma = document.getElementById('gamma-slider').value;
    const triangleShaderIndex = document.getElementById('triangle-shader-select').value;
    const enableBackground = document.getElementById('enable-background').checked ? 1 : 0;

    // Return the configuration object for the shader
    return {
        gamma,
        cameraConstant: g_zoomValue,
        triangleShaderIndex,
        enableBackground,
    };
}

// Entry point when the window loads
window.onload = function () { main(); }

async function main() {
    // Access the WebGPU API
    const gpu = navigator.gpu;
    const adapter = await gpu.requestAdapter();

    // Check for timestamp query support for profiling
    const canTimestamp = adapter.features.has('timestamp-query');
    const device = await adapter.requestDevice({
        requiredFeatures: [
            ...(canTimestamp ? ['timestamp-query'] : []),
        ],
    });
    // Initialize the helper for GPU timing operations
    const timingHelper = new TimingHelper(device);
    let gpuTime = 0;

    // Configure the canvas context for WebGPU
    const canvas = document.getElementById('my-canvas');
    const context = canvas.getContext('webgpu');
    const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device: device,
        format: canvasFormat,
    });

    // Load and compile the WGSL shader module
    const wgslcode = await fetch("shader.wgsl").then(r => r.text());
    const wgsl = device.createShaderModule({
        code: wgslcode
    });

    // Define the scene data (Cornell Box) and camera parameters
    const models = {
        'CornellBox': {
            path: '../../objects/CornellBox.obj',
            eye: vec3(277.0, 275.0, -570.0),
            look: vec3(277.0, 275.0, 0.0),
            up: vec3(0.0, 1.0, 0.0),
        },
    }
    const model = models['CornellBox'];
    // Parse the OBJ file to geometry data
    const obj = await readOBJFile(model.path, 1.0, true);

    // Initialize buffer storage and build the BSP tree acceleration structure
    const buffers = {};
    build_bsp_tree(obj, device, buffers);

    // Prepare the material buffer (emission and color)
    let mat_bytelength = obj.materials.length * 2 * 16;
    var materials = new ArrayBuffer(mat_bytelength);
    const materialBuffer = device.createBuffer({
        size: mat_bytelength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE,
    });
    // Populate the material buffer with padded vec4 data
    for (var i = 0; i < obj.materials.length; ++i) {
        const mat = obj.materials[i];
        const emission = vec4(mat.emission.r, mat.emission.g, mat.emission.b, mat.emission.a);
        const color = vec4(mat.color.r, mat.color.g, mat.color.b, mat.color.a);
        new Float32Array(materials, i * 2 * 16, 8).set([...emission, ...color]);
    }
    device.queue.writeBuffer(materialBuffer, 0, materials);

    // Create and upload the buffer containing indices of emissive triangles
    const lightidxBuffer = device.createBuffer({
        size: obj.light_indices.byteLength,
        usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
    });
    device.queue.writeBuffer(lightidxBuffer, 0, obj.light_indices);

    // Create the graphics pipeline
    const pipeline = device.createRenderPipeline({
        layout: 'auto',
        vertex: { module: wgsl, entryPoint: 'main_vs' },
        fragment: {
            module: wgsl,
            entryPoint: 'main_fs',
            targets: [
                { format: canvasFormat }, // Output to screen
                { format: 'rgba32float' } // Output to accumulation buffer
            ],
        },
        primitive: { topology: 'triangle-strip', },
    });

    // initialize textures for ping-pong rendering (accumulating samples over frames)
    let textures = new Object();
    textures.width = canvas.width;
    textures.height = canvas.height;
    // Texture to read from during the next frame (history)
    textures.renderSrc = device.createTexture({
        size: [canvas.width, canvas.height],
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
        format: 'rgba32float',
    });
    // Texture to write to during the current frame
    textures.renderDst = device.createTexture({
        size: [canvas.width, canvas.height],
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        format: 'rgba32float',
    });

    // Create the uniform buffer for passing scene and state data to shaders
    let bytelength = 7 * 16;
    let uniforms = new ArrayBuffer(bytelength);
    const uniformBuffer = device.createBuffer({
        size: uniforms.byteLength,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    // Create the bind group to link buffers and textures to shader binding points
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

    // Calculate camera basis vectors
    const { eye, look, up } = model;
    const v = normalize(subtract(look, eye));
    const b1 = normalize(cross(v, up));
    const b2 = normalize(cross(b1, v));
    const aspect = canvas.width / canvas.height;

    // State for the progressive rendering loop
    let frame = 0;
    const noOfJitters = 1;
    let keepRender = false;

    // Button event listeners to control the render loop
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

    // Loop function that increments frame count and requests the next frame
    function progressiveRender() {
        render();
        frame++;
        document.getElementById('frame-label').innerText = `Frame: ${frame}`;
        if (keepRender) { requestAnimationFrame(progressiveRender); }
    }

    // Main render function
    function render() {
        // Fetch current UI settings
        let { gamma, cameraConstant, triangleShaderIndex, enableBackground } = getOptions();

        // Update uniform data (floats)
        new Float32Array(uniforms, 0, 4 * 7).set([
            aspect, cameraConstant, gamma, 0.0,
            0.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0,
            ...eye, 0.0,
            ...b1, 0.0,
            ...b2, 0.0,
            ...v, 0.0,
        ]);
        // Update uniform data (integers/indices)
        new Uint32Array(uniforms, 4 * 3, 6).set([
            triangleShaderIndex,
            canvas.width,
            canvas.height,
            frame,
            noOfJitters,
            enableBackground
        ]);
        // Upload updated uniforms to the GPU
        device.queue.writeBuffer(uniformBuffer, 0, uniforms);

        // Encode the render pass commands
        const encoder = device.createCommandEncoder();
        const pass = timingHelper.beginRenderPass(encoder, {
            colorAttachments: [
                { view: context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", },
                { view: textures.renderSrc.createView(), loadOp: "load", storeOp: "store", }
            ]
        });

        // Set pipeline and resources, then draw a full-screen quad (4 vertices)
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bindGroup);
        pass.draw(4);
        pass.end();

        // Copy the current accumulation texture to the destination for the next frame
        encoder.copyTextureToTexture({ texture: textures.renderSrc }, { texture: textures.renderDst }, [textures.width, textures.height]);

        // Submit the command buffer
        device.queue.submit([encoder.finish()]);
        // Log GPU execution time if available
        timingHelper.getResult().then(time => {
            if (time > 0) console.log(`GPU time: ${(time / 1000000).toFixed(3)} ms`);
        });
    }

    // Initial setup and start of the render loop
    setupOptions(() => {
        frame = 0;
        document.getElementById('frame-label').innerText = `Frame: 0`;
        if (!keepRender) { requestAnimationFrame(progressiveRender); }
    });
    
    progressiveRender();
}