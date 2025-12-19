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

function compute_jitters(jitterArray, pixelsize, subdivs) {
  const step = pixelsize / subdivs;
  if (subdivs < 2) {
    jitterArray[0] = 0.0; jitterArray[1] = 0.0;
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
  if (!adapter) { showError("WebGPU not supported."); return; }
  const device = await adapter.requestDevice();
  
  const canvas = document.getElementById("webgpu-canvas");
  const context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  let wgslCode = "";
  try {
    const response = await fetch("shader.wgsl");
    wgslCode = await response.text();
  } catch (err) { showError("Failed to load shader."); return; }

  const shaderModule = device.createShaderModule({ code: wgslCode });

  // Setup uniforms
  const ubF = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

  // Jitter buffer
  const maxSubdivs = 10;
  const jitterData = new Float32Array(maxSubdivs * maxSubdivs * 2);
  const ubJitter = device.createBuffer({
    size: jitterData.byteLength,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST
  });

  // Load texture
  const texture = await load_texture(device, "../../textures/grass.jpg");
  if (!texture) { showError("Texture missing."); return; }

  // Create pipeline
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "main_vs" },
    fragment: { module: shaderModule, entryPoint: "main_fs", targets: [{ format }] },
    primitive: { topology: "triangle-strip" },
  });

  // State
  let cam_const = 1.0;
  let sphereMat = 5;
  let planeMat = 1;
  let subdivs = 1;
  let scaleDivisor = 1.0;
  let gamma = 2.2;
  let useTexture = 1;
  let addrMode = "repeat";
  let filterMode = "linear";

  let bindGroup;

  function updateBindGroup() {
    const sampler = device.createSampler({
      addressModeU: addrMode,
      addressModeV: addrMode,
      minFilter: filterMode,
      magFilter: filterMode,
    });

    bindGroup = device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: ubF } },
        { binding: 1, resource: sampler },
        { binding: 2, resource: texture.createView() },
        { binding: 3, resource: { buffer: ubJitter } }
      ],
    });
  }

  // UI elements
  const displaySub = document.getElementById("subdivDisplay");
  const displayScale = document.getElementById("scaleVal");
  const displayGamma = document.getElementById("gammaVal");

  function update() {
    compute_jitters(jitterData, 1.0 / canvas.height, subdivs);
    device.queue.writeBuffer(ubJitter, 0, jitterData);

    const aspect = canvas.width / canvas.height;
    const tex_scale_val = 0.2 / scaleDivisor;
    
    const fData = new Float32Array([
      aspect, cam_const, sphereMat, planeMat, 
      subdivs, tex_scale_val, gamma, useTexture
    ]);
    device.queue.writeBuffer(ubF, 0, fData);

    displaySub.textContent = subdivs;
    displayScale.textContent = scaleDivisor.toFixed(1);
    displayGamma.textContent = gamma.toFixed(1);

    draw();
  }

  // Render function
  function draw() {
    if (!bindGroup) return;
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
  document.getElementById("btnInc").onclick = () => { if (subdivs < 10) subdivs++; update(); };
  document.getElementById("btnDec").onclick = () => { if (subdivs > 1) subdivs--; update(); };

  document.getElementById("sphereMenu").onchange = (e) => { sphereMat = parseInt(e.target.value); update(); };
  document.getElementById("texToggle").onchange = (e) => { useTexture = e.target.checked ? 1 : 0; update(); };
  
  document.getElementById("texScale").oninput = (e) => { scaleDivisor = parseFloat(e.target.value); update(); };
  document.getElementById("gammaRange").oninput = (e) => { gamma = parseFloat(e.target.value); update(); };

  document.getElementById("addrMode").onchange = (e) => { addrMode = e.target.value; updateBindGroup(); update(); };
  document.getElementById("filterMode").onchange = (e) => { filterMode = e.target.value; updateBindGroup(); update(); };

  window.onkeydown = (e) => {
    if(e.key === "ArrowUp") { cam_const *= 1.1; update(); }
    if(e.key === "ArrowDown") { cam_const /= 1.1; update(); }
  };

  addEventListener("wheel", (e) => {
    e.preventDefault();
    cam_const *= (e.deltaY > 0 ? 0.95 : 1.05);
    update();
  }, { passive: false });

  updateBindGroup();
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