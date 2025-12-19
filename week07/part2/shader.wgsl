// Structures
struct Uniforms {
    aspect: f32,
    camera_constant: f32,
    gamma: f32,
    triangle_shader: u32,
    subpixels: u32,
    width: u32,
    height: u32,
    frame: u32,
    no_of_jitters: u32,
    enable_background: u32,
    eye_point: vec3f,
    b1: vec3f,
    b2: vec3f,
    v: vec3f,
}

struct Ray {
    origin: vec3f,
    direction: vec3f,
    tmin: f32,
    tmax: f32
}

struct HitInfo {
    has_hit: bool,
    distance: f32,
    position: vec3f,
    normal: vec3f,
    diffuse: vec3f,
    emission: vec3f,
    specular: vec3f,
    ior1_over_ior2: f32,
    shininess: f32,
    shader: u32,
    triangle_idx: u32,
    emit: bool,
    throughput: vec3f,
}

fn default_hitinfo() -> HitInfo {
    return HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0.0, 0.0, 0u, 0u, true, vec3f(0.0));
}

struct Material {
    emission: vec3f,
    diffuse: vec3f,
}

struct VertexInfo {
    position: vec3f,
    normal: vec3f,
}

struct Aabb {
    min: vec3f,
    max: vec3f,
}

struct Light {
    L_i: vec3f,
    w_i: vec3f,
    dist: f32
}

struct FSOut { 
    @location(0) frame: vec4f, 
    @location(1) accum: vec4f 
}

struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) coords: vec2f,
}

// Bindings
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var<storage> jitter: array<vec2f>;
@group(0) @binding(2) var<storage> vInfo: array<VertexInfo>;
@group(0) @binding(3) var<storage> meshFaces: array<vec4u>;
@group(0) @binding(4) var renderTexture: texture_2d<f32>;
@group(0) @binding(5) var<storage> materials: array<Material>;
@group(0) @binding(6) var<uniform> aabb: Aabb;

// BSP Bindings & Globals
@group(0) @binding(7) var<storage> treeIds: array<u32>;
@group(0) @binding(8) var<storage> bspTree: array<vec4u>;
@group(0) @binding(9) var<storage> bspPlanes: array<f32>;
@group(0) @binding(10) var<storage> lightIndices: array<u32>;

const MAX_LEVEL = 20u;
const BSP_LEAF = 3u;
const Pi = 3.1415926535;
var<private> branch_node: array<vec2u, MAX_LEVEL>;
var<private> branch_ray: array<vec2f, MAX_LEVEL>;

// PRNG
fn tea(val0: u32, val1: u32) -> u32 {
    const N = 16u;
    var v0 = val0; var v1 = val1; var s0 = 0u;
    for (var n = 0u; n < N; n++) {
        s0 += 0x9e3779b9;
        v0 += ((v1 << 4) + 0xa341316c) ^ (v1 + s0) ^ ((v1 >> 5) + 0xc8013ea4);
        v1 += ((v0 << 4) + 0xad90777d) ^ (v0 + s0) ^ ((v0 >> 5) + 0x7e95761e);
    }
    return v0;
}

fn mcg31(prev: ptr<function, u32>) -> u32 {
    const LCG_A = 1977654935u;
    *prev = (LCG_A * (*prev)) & 0x7FFFFFFF;
    return *prev;
}

fn rnd(prev: ptr<function, u32>) -> f32 {
    return f32(mcg31(prev)) / f32(0x80000000);
}

// Intersection Logic
fn intersect_min_max(r: ptr<function, Ray>) -> bool {
    let p1 = (aabb.min - r.origin) / r.direction;
    let p2 = (aabb.max - r.origin) / r.direction;
    let box_tmin = max(max(min(p1.x, p2.x), min(p1.y, p2.y)), min(p1.z, p2.z)) - 1.0e-3f;
    let box_tmax = min(min(max(p1.x, p2.x), max(p1.y, p2.y)), max(p1.z, p2.z)) + 1.0e-3f;
    if (box_tmin > box_tmax || box_tmin > r.tmax || box_tmax < r.tmin) { return false; }
    r.tmin = max(box_tmin, r.tmin);
    r.tmax = min(box_tmax, r.tmax);
    return true;
}

fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, i: u32) -> bool {
    let face = meshFaces[i];
    let v0 = vInfo[face.x].position;
    let e0 = vInfo[face.y].position - v0;
    let e1 = vInfo[face.z].position - v0;
    let n = cross(e0, e1);
    let q = dot(r.direction, n);
    if (abs(q) < 1e-8) { return false; }
    let a = v0 - r.origin;
    let t = dot(a, n) / q;
    if (t < r.tmin || t > r.tmax) { return false; }
    let b_p = cross(a, r.direction);
    let beta = dot(b_p, e1) / q;
    let gamma = -dot(b_p, e0) / q;
    if (beta < 0.0 || gamma < 0.0 || (beta + gamma) > 1.0) { return false; }
    hit.has_hit = true; hit.position = r.origin + r.direction * t; hit.distance = t;
    hit.normal = normalize(vInfo[face.x].normal * (1.0-beta-gamma) + vInfo[face.y].normal * beta + vInfo[face.z].normal * gamma);
    return true;
}

// BSP Traversal
fn intersect_trimesh(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    var branch_lvl = 0u;
    var node = 0u;
    for (var i = 0u; i <= MAX_LEVEL; i++) {
        let tree_node = bspTree[node];
        let axis_leaf = tree_node.x & 3u;
        if (axis_leaf == BSP_LEAF) {
            let count = tree_node.x >> 2u;
            let id = tree_node.y;
            var found = false;
            for (var j = 0u; j < count; j++) {
                let idx = treeIds[id + j];
                if (intersect_triangle(*r, hit, idx)) {
                    r.tmax = hit.distance;
                    hit.triangle_idx = idx;
                    found = true;
                }
            }
            if (found) { return true; }
            if (branch_lvl == 0u) { return false; }
            branch_lvl--;
            i = branch_node[branch_lvl].x;
            node = branch_node[branch_lvl].y;
            r.tmin = branch_ray[branch_lvl].x;
            r.tmax = branch_ray[branch_lvl].y;
            continue;
        }
        let axis_dir = r.direction[axis_leaf];
        let near = select(tree_node.w, tree_node.z, axis_dir >= 0.0);
        let far = select(tree_node.z, tree_node.w, axis_dir >= 0.0);
        let t = (bspPlanes[node] - r.origin[axis_leaf]) / select(axis_dir, 1e-8, abs(axis_dir) < 1e-8);
        if (t > r.tmax) { node = near; }
        else if (t < r.tmin) { node = far; }
        else {
            branch_node[branch_lvl] = vec2u(i, far);
            branch_ray[branch_lvl] = vec2f(t, r.tmax);
            branch_lvl++;
            r.tmax = t;
            node = near;
        }
    }
    return false;
}

fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    if (!intersect_min_max(r)) { return false; }
    if (intersect_trimesh(r, hit)) {
        let mat = materials[meshFaces[hit.triangle_idx].w];
        hit.diffuse = mat.diffuse;
        hit.emission = mat.emission;
        hit.shader = uniforms.triangle_shader;
        r.tmax = hit.distance;
    }
    return hit.has_hit;
}

// Lighting & Shading
fn sample_area_light(pos: vec3f, t: ptr<function, u32>) -> Light {
    var light = Light(vec3f(0.0), vec3f(0.0), 0.0);
    let numLights = arrayLength(&lightIndices);
    let l_idx = lightIndices[u32(rnd(t) * f32(numLights))];
    let face = meshFaces[l_idx];
    let v0 = vInfo[face.x].position;
    let v1 = vInfo[face.y].position;
    let v2 = vInfo[face.z].position;
    let xi1 = rnd(t); let xi2 = rnd(t);
    let alpha = 1.0 - sqrt(xi1);
    let beta = (1.0 - xi2) * sqrt(xi1);
    let gamma = xi2 * sqrt(xi1);
    let light_pos = v0 * alpha + v1 * beta + v2 * gamma;
    let n = normalize(vInfo[face.x].normal * alpha + vInfo[face.y].normal * beta + vInfo[face.z].normal * gamma);
    let area = length(cross(v1 - v0, v2 - v0)) * 0.5;
    let w_i = normalize(light_pos - pos);
    let dist = length(light_pos - pos);
    light.L_i = max(dot(-w_i, n), 0.0) * materials[meshFaces[l_idx].w].emission * area * f32(numLights);
    light.w_i = w_i;
    light.dist = dist;
    return light;
}

fn lambertian(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, t: ptr<function, u32>) -> vec3f {
    let light = sample_area_light(hit.position, t);
    var shadow_ray = Ray(hit.position, light.w_i, 0.001, light.dist - 0.001);
    var shadow_hit = default_hitinfo();
    if (intersect_scene(&shadow_ray, &shadow_hit)) { return hit.emission; }
    return (hit.diffuse / Pi) * light.L_i * max(dot(hit.normal, light.w_i), 0.0) + hit.emission;
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, t: ptr<function, u32>) -> vec3f {
    switch hit.shader {
        case 1 { return lambertian(r, hit, t); }
        case default { return hit.diffuse + hit.emission; }
    }
}

// Ray Generation
fn get_camera_ray(ipcoords: vec2f) -> Ray {
    var q = uniforms.b1 * ipcoords.x + uniforms.b2 * ipcoords.y + uniforms.v * uniforms.camera_constant;
    return Ray(uniforms.eye_point, normalize(q), 1e-4, 1e10);
}

// Vertex Shader
@vertex
fn main_vs(@builtin(vertex_index) VertexIndex: u32) -> VSOut {
    const pos = array<vec2f, 4>(vec2f(-1.0, 1.0), vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(1.0, -1.0));
    var vsOut: VSOut;
    vsOut.position = vec4f(pos[VertexIndex], 0.0, 1.0);
    vsOut.coords = pos[VertexIndex];
    return vsOut;
}

// Fragment Shader
@fragment
fn main_fs(@builtin(position) fragcoord: vec4f, @location(0) coords: vec2f) -> FSOut {
    let launch_idx = u32(fragcoord.y) * uniforms.width + u32(fragcoord.x);
    var t = tea(launch_idx, uniforms.frame);
    let prog_jitter = vec2f(rnd(&t), rnd(&t)) / (f32(uniforms.height) * sqrt(f32(uniforms.no_of_jitters)));
    const cornflower = vec4f(0.1, 0.3, 0.6, 1.0);
    let bgcolor = select(vec4f(0.0, 0.0, 0.0, 1.0), cornflower, uniforms.enable_background == 1u);
    let uv = vec2f(coords.x * uniforms.aspect * 0.5, coords.y * 0.5);
    let subpixels = uniforms.subpixels * uniforms.subpixels;
    var result = vec3f(0.0);
    for (var p = 0u; p < subpixels; p++) {
        var r = get_camera_ray(uv + jitter[p] + prog_jitter);
        var hit = default_hitinfo();
        for (var i = 0; i < 10; i++) {
            if (intersect_scene(&r, &hit)) { result += shade(&r, &hit, &t); }
            else { result += bgcolor.rgb; break; }
            if (hit.has_hit) { break; }
        }
    }
    result /= f32(subpixels);
    let curr_sum = textureLoad(renderTexture, vec2u(fragcoord.xy), 0).rgb * f32(uniforms.frame);
    let accum_color = (result + curr_sum) / f32(uniforms.frame + 1u);
    return FSOut(vec4f(pow(accum_color, vec3f(1.0 / uniforms.gamma)), 1.0), vec4f(accum_color, 1.0));
}