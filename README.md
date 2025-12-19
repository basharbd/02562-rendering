


# 02562 Rendering (DTU) — Lab Journal + Final Project (WebGPU)

This repository contains my **WebGPU-based lab journal** (worksheets) and my final project for DTU 02562.

---

### 🌐 Live Page
**Lab Journal & Project:** [https://basharbd.github.io/02562-rendering/](https://basharbd.github.io/02562-rendering/)

---

### 📁 Repository Structure

```text
.
├── index.html                # Main wrapper index (links to weeks + project)
├── common/                   # Shared CSS + JS utilities (MV.js, OBJ parsers, BSP tree, etc.)
├── objects/                  # 3D models (.obj/.mtl)
├── backgrounds/              # HDR environment maps
├── week01/ ... week09/       # Lab journal weeks (each part has index.html + main.js + shader.wgsl)
└── project/
    └── part01/               # Final Project: Depth of Field implementation

```

Each lab part follows the same template:

* **`index.html`** (UI + layout)
* **`main.js`** (WebGPU setup + rendering logic)
* **`shader.wgsl`** (WGSL shaders)

---

### ✅ Project: Depth of Field in WebGPU



The project implements a physically based **Thin Lens Camera Model** within a progressive path tracer to simulate realistic depth of field. Unlike the traditional pinhole model, this introduces a finite aperture and focal plane.

* **Thin Lens Camera:** Stochastic aperture sampling to generate realistic bokeh and soft focus.
* **Path Tracing:** Robust Monte Carlo integrator with Next Event Estimation (NEE) and Russian Roulette.
* **Advanced Materials:** Dielectric BSDF (Glass) with Fresnel reflectance and Snell's law.
* **Volumetric Absorption:** Simulation of light attenuation inside glass using **Bouguer’s Law**.
* **Environment Mapping:** HDR lighting with holdout shadow catchers.

---

### ▶️ How to Run Locally

You can run everything locally with a simple static server:

```bash
python3 -m http.server

```

Then open:
[http://localhost:8000/](https://www.google.com/search?q=http://localhost:8000/)

*WebGPU requires a supported browser (Chrome 113+, Edge, or Firefox Nightly) with WebGPU enabled.*

---

### 🧪 Tested Environment

* **Browser:** Chrome (WebGPU enabled by default)
* **Platform:** macOS / Windows / Linux
* **Rendering:** WebGPU + WGSL

---

### 📄 Report

The project report is included in the submission package (**`1.pdf`**). It follows the required structure: Introduction, Method, Implementation, Results, Discussion, and includes:

* Link to **Lab Journal**
* Link to **Project implementation**
* Figures placed under the corresponding subsections

