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
  const info = await shaderModule.getCompilationInfo();
  if (info.messages.some(m => m.type === "error")) {
    showError("WGSL compilation failed. Check console.");
    console.error(info.messages);
    return;
  }

  // UI elements
  const zoomSlider = document.getElementById("zoom");
  const zoomVal = document.getElementById("zoomVal");
  const gammaSlider = document.getElementById("gamma");
  const gammaVal = document.getElementById("gammaVal");

  // Setup uniforms
  const aspect = canvas.width / canvas.height;
  let cam_const = parseFloat(zoomSlider.value);
  let gamma = parseFloat(gammaSlider.value);

  const uniformData = new Float32Array([aspect, cam_const, gamma, 0.0]);

  const uniformBuffer = device.createBuffer({
    size: uniformData.byteLength,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  device.queue.writeBuffer(uniformBuffer, 0, uniformData);

  // Create pipeline
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "main_vs" },
    fragment: { module: shaderModule, entryPoint: "main_fs", targets: [{ format }] },
    primitive: { topology: "triangle-strip" },
  });

  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: uniformBuffer } }],
  });

  // Render function
  function draw() {
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

  // Update uniforms
  function updateUniforms() {
    uniformData[1] = cam_const;
    uniformData[2] = gamma;
    device.queue.writeBuffer(uniformBuffer, 0, uniformData);
    draw();
  }

  function syncUI() {
    zoomVal.textContent = cam_const.toFixed(2);
    gammaVal.textContent = gamma.toFixed(2);
    zoomSlider.value = cam_const;
    gammaSlider.value = gamma;
  }

  // Event listeners
  zoomSlider.addEventListener("input", () => {
    cam_const = parseFloat(zoomSlider.value);
    syncUI();
    updateUniforms();
  });

  gammaSlider.addEventListener("input", () => {
    gamma = parseFloat(gammaSlider.value);
    syncUI();
    updateUniforms();
  });

  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const speed = 1.05;
    if (e.deltaY < 0) {
      cam_const *= speed;
    } else {
      cam_const /= speed;
    }
    
    cam_const = Math.max(parseFloat(zoomSlider.min), Math.min(parseFloat(zoomSlider.max), cam_const));
    
    syncUI();
    updateUniforms();
  }, { passive: false });

  syncUI();
  draw();
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