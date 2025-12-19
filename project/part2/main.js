"use strict";

window.onload = function () {
  main();
};

async function main() {
  if (!navigator.gpu) {
    throw new Error("WebGPU not supported on this browser.");
  }

  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error("No appropriate GPUAdapter found.");
  }

  const device = await adapter.requestDevice();

  // Load WGSL shader code (Updated path)
  const wgsl = device.createShaderModule({
    code: await (await fetch("shader.wgsl")).text()
  });

  // Setup canvas and configure context
  const canvas = document.querySelector("canvas");
  const ctx = canvas.getContext("webgpu");
  const canvasFormat = navigator.gpu.getPreferredCanvasFormat();
  ctx.configure({
    device: device,
    format: canvasFormat
  });

  // Create pipeline
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: {
      module: wgsl,
      entryPoint: "main_vs",
    },
    fragment: {
      module: wgsl,
      entryPoint: "main_fs",
      targets: [
        { format: canvasFormat },
        { format: "rgba32float" } // Second render target for progressive rendering
      ]
    },
    primitive: {
      topology: "triangle-strip",
    }
  });

  // Setup textures
  const textures = {
    width: canvas.width,
    height: canvas.height,
    renderSrc: device.createTexture({
      size: [canvas.width, canvas.height],
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
      format: 'rgba32float',
    }),
    renderDst: device.createTexture({
      size: [canvas.width, canvas.height],
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
      format: 'rgba32float',
    })
  };

  // Render function
  function render(dev, context, pipe, texs, bindGroup) {
    const encoder = dev.createCommandEncoder();

    const pass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view: context.getCurrentTexture().createView(),
          loadOp: "clear",
          storeOp: "store",
        },
        {
          view: texs.renderSrc.createView(),
          loadOp: "load",
          storeOp: "store",
        }
      ]
    });
    pass.setBindGroup(0, bindGroup);
    pass.setPipeline(pipe);
    pass.draw(4);
    pass.end();

    encoder.copyTextureToTexture(
      { texture: texs.renderSrc },
      { texture: texs.renderDst },
      [texs.width, texs.height]
    );

    dev.queue.submit([encoder.finish()]);
  }

  // Load scene geometry (Updated path)
  const filename = "../../objects/CornellBox.obj";
  const drawingInfo = await readOBJFile(filename, 1, true);

  const apertureSlider = document.getElementById("aperture");

  // Use the input event for live updating
  apertureSlider.addEventListener("input", function () {
    const aperture = apertureSlider.value / 5;

    // Update the uniforms_f array with the new focalpoint
    uniforms_f[2] = aperture;

    // Write the updated uniforms to the GPU buffer
    device.queue.writeBuffer(uniformBuffer_f, 0, uniforms_f);

    console.log("Updated apeture:", aperture);

    // Reset frame number to re-accumulate the image
    frame_num = 0;
    uniforms_int[2] = frame_num;
    device.queue.writeBuffer(uniformBuffer_int, 0, uniforms_int);
  });
  const aperture = apertureSlider.value / 5;

  const focal = document.getElementById("focalpoint");

  // Use the input event for live updating
  focal.addEventListener("input", function () {
    const focalpoint = 1.1 + focal.value / 75;

    // Update the uniforms_f array with the new focalpoint
    uniforms_f[3] = focalpoint;

    // Write the updated uniforms to the GPU buffer
    device.queue.writeBuffer(uniformBuffer_f, 0, uniforms_f);

    console.log("Updated focalpoint:", focalpoint);

    // Reset frame number to re-accumulate the image
    frame_num = 0;
    uniforms_int[2] = frame_num;
    device.queue.writeBuffer(uniformBuffer_int, 0, uniforms_int);
  });
  const focalpoint = 1.1 + focal.value / 75;

  // Prepare uniform data
  const aspect = canvas.width / canvas.height;
  const gamma = 1.5;
  const uniforms_f = new Float32Array([aspect, gamma, aperture, focalpoint]);

  let frame_num = 0;
  const uniforms_int = new Int32Array([canvas.width, canvas.height, frame_num]);

  const uniformBuffer_f = device.createBuffer({
    size: uniforms_f.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const uniformBuffer_int = device.createBuffer({
    size: uniforms_int.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  device.queue.writeBuffer(uniformBuffer_f, 0, uniforms_f);
  device.queue.writeBuffer(uniformBuffer_int, 0, uniforms_int);

  // Build BSP tree and related buffers
  const bspTreeBuffers = build_bsp_tree(drawingInfo, device, {});

  // Create light indices buffer
  const lightIndicesBuffer = device.createBuffer({
    size: drawingInfo.light_indices.byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
  });
  device.queue.writeBuffer(lightIndicesBuffer, 0, drawingInfo.light_indices);

  // Flatten and upload material data
  const mats = drawingInfo.materials
    .map(m => [m.color, m.emission])
    .flat()
    .map(color => [color.r, color.g, color.b, color.a])
    .flat();
  const materialsArray = new Float32Array(mats);

  const materialsBuffer = device.createBuffer({
    size: materialsArray.byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  device.queue.writeBuffer(materialsBuffer, 0, materialsArray);

  // Create bind group
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: uniformBuffer_f } },
      { binding: 1, resource: { buffer: uniformBuffer_int } },
      { binding: 3, resource: { buffer: bspTreeBuffers.aabb } },
      { binding: 4, resource: { buffer: bspTreeBuffers.attribs } },
      { binding: 6, resource: { buffer: materialsBuffer } },
      { binding: 7, resource: { buffer: bspTreeBuffers.indices } },
      { binding: 8, resource: { buffer: bspTreeBuffers.treeIds } },
      { binding: 9, resource: { buffer: bspTreeBuffers.bspTree } },
      { binding: 10, resource: { buffer: bspTreeBuffers.bspPlanes } },
      { binding: 11, resource: { buffer: lightIndicesBuffer } },
      { binding: 12, resource: textures.renderDst.createView() },
    ],
  });

  // Animation loop
  function animate() {
    uniforms_int[2] = frame_num;
    frame_num++;
    device.queue.writeBuffer(uniformBuffer_int, 0, uniforms_int);
    render(device, ctx, pipeline, textures, bindGroup);
  }

  // Update frames at a set interval
  setInterval(() => {
    if (frame_num < 100000) {
      requestAnimationFrame(animate);
    }
  }, 1);
}