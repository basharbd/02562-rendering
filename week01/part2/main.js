"use strict";

window.onload = () => main();

async function main() {
  if (!navigator.gpu) {
    showError("WebGPU not supported in this browser.");
    return;
  }

  const canvas = document.getElementById("webgpu-canvas");
  const context = canvas.getContext("webgpu");

  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    showError("No GPU adapter found.");
    return;
  }
  const device = await adapter.requestDevice();

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
  
  // Check shader compilation
  const info = await shaderModule.getCompilationInfo();
  if (info.messages.some(m => m.type === "error")) {
    showError("WGSL compilation failed. Check console.");
    console.error(info.messages);
    return;
  }

  // Camera setup
  const eye = vec3(2.0, 1.5, 2.0);
  const p   = vec3(0.0, 0.5, 0.0);
  const up  = vec3(0.0, 1.0, 0.0);

  const v  = normalize(subtract(p, eye));
  const b1 = normalize(cross(v, up));
  const b2 = cross(b1, v);

  // Setup uniforms
  const aspect = canvas.width / canvas.height;
  const cam_const = 1.0; 
  const gamma = 2.2;

  const u = new Float32Array([
    aspect, cam_const, gamma, 0.0,
    eye[0], eye[1], eye[2], 0.0,
    b1[0],  b1[1],  b1[2],  0.0,
    b2[0],  b2[1],  b2[2],  0.0,
    v[0],   v[1],   v[2],   0.0,
  ]);

  const uniformBuffer = device.createBuffer({
    size: u.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  device.queue.writeBuffer(uniformBuffer, 0, u);

  // Setup bind group
  const bindGroupLayout = device.createBindGroupLayout({
    entries: [{
      binding: 0,
      visibility: GPUShaderStage.FRAGMENT,
      buffer: { type: "uniform" },
    }],
  });

  const bindGroup = device.createBindGroup({
    layout: bindGroupLayout,
    entries: [{ binding: 0, resource: { buffer: uniformBuffer } }],
  });

  // Create pipeline
  const pipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] }),
    vertex: { module: shaderModule, entryPoint: "main_vs" },
    fragment: { module: shaderModule, entryPoint: "main_fs", targets: [{ format }] },
    primitive: { topology: "triangle-strip" },
  });

  // Render
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginRenderPass({
    colorAttachments: [{
      view: context.getCurrentTexture().createView(),
      clearValue: { r: 0, g: 0, b: 0, a: 1 },
      loadOp: "clear",
      storeOp: "store",
    }],
  });

  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.draw(4);
  pass.end();

  device.queue.submit([encoder.finish()]);
}

// Display error messages
function showError(msg) {
  const container = document.getElementById("error-container");
  if (container) {
    container.style.display = "block";
    container.innerText = msg;
  }
  console.error(msg);
}