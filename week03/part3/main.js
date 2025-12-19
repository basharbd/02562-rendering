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

// Compute stratified jitter offsets
function compute_jitters(jitterArray, pixelsize, subdivs) {
  const step = pixelsize / subdivs;
  
  // Optimization for 1x1
  if (subdivs < 2) {
    jitterArray[0] = 0.0; 
    jitterArray[1] = 0.0;
    return;
  }

  for (let i = 0; i < subdivs; ++i) {
    for (let j = 0; j < subdivs; ++j) {
      const idx = (i * subdivs + j) * 2;
      jitterArray[idx]     = (Math.random() + j) * step - pixelsize * 0.5;
      jitterArray[idx + 1] = (Math.random() + i) * step - pixelsize * 0.5;
    }
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

  let wgslCode = "";
  try {
    const response = await fetch("shader.wgsl");
    wgslCode = await response.text();
  } catch (err) {
    showError("Failed to load shader file.");
    return;
  }

  const shaderModule = device.createShaderModule({ code: wgslCode });
  
  // Setup uniforms
  const ubF = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const ubUI = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

  // Jitter storage buffer
  const maxSubdivs = 10;
  const jitterData = new Float32Array(maxSubdivs * maxSubdivs * 2);
  const ubJitter = device.createBuffer({
    size: jitterData.byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
  });

  // Load texture
  const texture = await load_texture(device, "../../textures/grass.jpg");
  if (!texture) {
    showError("Texture not found: ../../textures/grass.jpg");
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
      { binding: 3, resource: texture.createView() },
      { binding: 4, resource: { buffer: ubJitter } }
    ],
  });

  // State
  let cam_const = 1.0;
  let sphereMat = 5;
  let planeMat = 1;
  let useTexture = 1;
  let subdivs = 4;

  const display = document.getElementById("subdivDisplay");

  function update() {
    const aspect = canvas.width / canvas.height;
    
    compute_jitters(jitterData, 1.0 / canvas.height, subdivs);
    device.queue.writeBuffer(ubJitter, 0, jitterData);

    const fData = new Float32Array([aspect, cam_const, sphereMat, planeMat, subdivs, 0, 0, 0]);
    device.queue.writeBuffer(ubF, 0, fData);

    const uiData = new Uint32Array([useTexture, 0, 0, 0]);
    device.queue.writeBuffer(ubUI, 0, uiData);

    display.textContent = subdivs;

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
  document.getElementById("btnInc").onclick = () => {
    if (subdivs < 10) { subdivs++; update(); }
  };
  document.getElementById("btnDec").onclick = () => {
    if (subdivs > 1) { subdivs--; update(); }
  };

  document.getElementById("sphereMenu").onchange = (e) => { sphereMat = parseInt(e.target.value); update(); };
  document.getElementById("materialMenu").onchange = (e) => { planeMat = parseInt(e.target.value); update(); };
  document.getElementById("texToggle").onchange = (e) => { useTexture = e.target.checked ? 1 : 0; update(); };

  window.onresize = () => {
    update();
  };
  
  window.onkeydown = (e) => {
    if(e.key === "ArrowUp") { cam_const *= 1.1; update(); }
    if(e.key === "ArrowDown") { cam_const /= 1.1; update(); }
  };

  addEventListener("wheel", (e) => {
    e.preventDefault();
    cam_const *= (e.deltaY > 0 ? 0.95 : 1.05);
    update();
  }, { passive: false });

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