"use strict";

window.onload = () => main();

async function load_texture(device, filename) {
  try {
    const response = await fetch(filename);
    if (!response.ok) throw new Error(`Failed to load texture: ${filename}`);
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
  } catch (e) {
    console.error(e);
    return null;
  }
}

async function main() {
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    showError("WebGPU not supported.");
    return;
  }
  const device = await adapter.requestDevice();
  
  const canvas = document.getElementById("webgpu-canvas");
  const context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  // Load shader
  let wgslCode = "";
  try {
    const response = await fetch("shader.wgsl");
    if (!response.ok) throw new Error("Could not load shader.wgsl");
    wgslCode = await response.text();
  } catch (err) {
    showError(`Failed to load shader file: ${err.message}`);
    return;
  }

  const shaderModule = device.createShaderModule({ code: wgslCode });
  const info = await shaderModule.getCompilationInfo();
  if (info.messages.some(m => m.type === "error")) {
    showError("WGSL compilation failed. Check console.");
    console.error(info.messages);
    return;
  }

  // Setup uniforms
  const ubF = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const ubUI = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

  // Load texture
  const texture = await load_texture(device, "../../textures/grass.jpg");
  if (!texture) {
    showError("Failed to load grass.jpg. Ensure ../../textures/grass.jpg exists.");
    return;
  }

  const sampler = device.createSampler({
    addressModeU: "repeat",
    addressModeV: "repeat",
    minFilter: "linear",
    magFilter: "linear",
  });

  // Create pipeline
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "main_vs" },
    fragment: { module: shaderModule, entryPoint: "main_fs", targets: [{ format }] },
    primitive: { topology: "triangle-strip" },
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: ubF } },
      { binding: 1, resource: { buffer: ubUI } },
      { binding: 2, resource: sampler },
      { binding: 3, resource: texture.createView() }
    ],
  });

  // State
  let cam_const = 1.0;
  let sphereMat = 5;
  let planeMat = 1;
  let useTexture = 1;

  const sphereMenu = document.getElementById("sphereMenu");
  const materialMenu = document.getElementById("materialMenu");
  const texToggle = document.getElementById("texToggle");

  // Update uniforms
  function update() {
    const aspect = canvas.width / canvas.height;
    device.queue.writeBuffer(ubF, 0, new Float32Array([aspect, cam_const, sphereMat, planeMat]));
    device.queue.writeBuffer(ubUI, 0, new Uint32Array([useTexture, 0, 0, 0]));
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
        clearValue: { r: 0.1, g: 0.3, b: 0.6, a: 1.0 }
      }]
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(4);
    pass.end();
    device.queue.submit([encoder.finish()]);
  }

  // Event listeners
  sphereMenu.addEventListener("change", () => { sphereMat = parseInt(sphereMenu.value); update(); });
  materialMenu.addEventListener("change", () => { planeMat = parseInt(materialMenu.value); update(); });
  texToggle.addEventListener("change", () => { useTexture = texToggle.checked ? 1 : 0; update(); });

  window.addEventListener("resize", () => {
    canvas.width = Math.min(window.innerWidth, 512); // Optional cap or full width
    canvas.height = Math.min(window.innerHeight, 512);
    update();
  });
  
  window.addEventListener("wheel", (e) => {
    e.preventDefault();
    cam_const *= (e.deltaY > 0 ? 0.95 : 1.05);
    update();
  }, { passive: false });

  // Initial
  update();
}

function showError(msg) {
  const container = document.getElementById("error-container");
  if (container) {
    container.style.display = "block";
    container.innerText = msg;
  }
  console.error(msg);
}