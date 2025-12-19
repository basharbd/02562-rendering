"use strict";

window.onload = () => main();

async function loadTexture(device, url) {
  try {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`Failed to fetch texture: ${url}`);
    const blob = await resp.blob();
    const img = await createImageBitmap(blob, { colorSpaceConversion: "none" });

    const tex = device.createTexture({
      size: [img.width, img.height, 1],
      format: "rgba8unorm",
      usage:
        GPUTextureUsage.COPY_DST |
        GPUTextureUsage.TEXTURE_BINDING |
        GPUTextureUsage.RENDER_ATTACHMENT,
    });

    device.queue.copyExternalImageToTexture(
      { source: img, flipY: true },
      { texture: tex },
      { width: img.width, height: img.height }
    );

    return tex;
  } catch (err) {
    console.error(err);
    alert("Could not load texture. Check console.");
    return null;
  }
}

async function main() {
  if (!navigator.gpu) {
    alert("WebGPU not supported.");
    return;
  }

  const adapter = await navigator.gpu.requestAdapter();
  const device = await adapter.requestDevice();

  const canvas = document.getElementById("webgpu-canvas");
  const context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  // Load shader
  const code = await (await fetch("shader.wgsl")).text();
  const shaderModule = device.createShaderModule({ code });

  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "main_vs" },
    fragment: { module: shaderModule, entryPoint: "main_fs", targets: [{ format }] },
    primitive: { topology: "triangle-strip" },
  });

  // Setup uniforms
  const ubF = device.createBuffer({
    size: 16,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const ubUI = device.createBuffer({
    size: 16,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  // Load texture
  const texture = await loadTexture(device, "../../textures/grass.jpg");
  if (!texture) return;

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: ubF } },
      { binding: 1, resource: { buffer: ubUI } },
      { binding: 2, resource: texture.createView() },
    ],
  });

  const addressMenu = document.getElementById("addressmode");
  const filterMenu = document.getElementById("filtermode");

  // Update function
  function update() {
    const aspect = canvas.width / canvas.height;
    device.queue.writeBuffer(ubF, 0, new Float32Array([aspect, 0, 0, 0]));
    const useRepeat = addressMenu.value === "1" ? 1 : 0;
    const useLinear = filterMenu.value === "1" ? 1 : 0;
    device.queue.writeBuffer(ubUI, 0, new Uint32Array([useRepeat, useLinear, 0, 0]));
    draw();
  }

  // Render function
  function draw() {
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [{
        view: context.getCurrentTexture().createView(),
        loadOp: "clear",
        storeOp: "store",
        clearValue: { r: 0, g: 0, b: 0, a: 1 }
      }],
    });

    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(4);
    pass.end();

    device.queue.submit([encoder.finish()]);
  }

  // Event listeners
  addressMenu.addEventListener("change", update);
  filterMenu.addEventListener("change", update);
  window.addEventListener("resize", update);

  update();
}