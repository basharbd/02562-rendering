// -------------------------------------------------------------------------
// Structs and Data Layouts
// -------------------------------------------------------------------------
struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) coords: vec2f,
}

struct FSOut { 
    @location(0) frame: vec4f, 
    @location(1) accum: vec4f 
}

struct Uniforms {
    aspect: f32,
    camera_constant: f32,
    gamma: f32,
    triangle_shader: u32,
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
    extinction: vec3f,
}

struct Material {
    emission: vec4f,
    diffuse: vec4f,
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

// -------------------------------------------------------------------------
// Bind Group Definitions
// -------------------------------------------------------------------------
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(2) var<storage> vInfo: array<VertexInfo>;
@group(0) @binding(3) var<storage> meshFaces: array<vec4u>;
@group(0) @binding(4) var renderTexture: texture_2d<f32>;
@group(0) @binding(5) var<storage> materials: array<Material>;
@group(0) @binding(6) var<uniform> aabb: Aabb;
@group(0) @binding(7) var<storage> treeIds: array<u32>;
@group(0) @binding(8) var<storage> bspTree: array<vec4u>;
@group(0) @binding(9) var<storage> bspPlanes: array<f32>;
@group(0) @binding(10) var<storage> lightIndices: array<u32>;

const MAX_LEVEL = 20u;
const BSP_LEAF = 3u;
const Pi = 3.1415926535;

var<private> branch_node: array<vec2u, MAX_LEVEL>;
var<private> branch_ray: array<vec2f, MAX_LEVEL>;

// -------------------------------------------------------------------------
// Helper Functions and Random Number Generation
// -------------------------------------------------------------------------
fn default_hitinfo() -> HitInfo {
    return HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0.0, 0.0, 0u, 0u, true, vec3f(1.0), vec3f(0.0));
}

fn tea(val0: u32, val1: u32) -> u32 {
    var v0 = val0; var v1 = val1; var s0 = 0u;
    for (var n = 0u; n < 16u; n++) {
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

fn rotate_to_normal(n: vec3f, v: vec3f) -> vec3f {
    let s = sign(n.z + 1e-16);
    let a = -1.0 / (1.0 + abs(n.z));
    let b = n.x * n.y * a;
    return vec3f(1.0 + n.x * n.x * a, b, -s * n.x) * v.x + vec3f(s * b, s * (1.0 + n.y * n.y * a), -n.y) * v.y + n * v.z;
}

fn sample_cosine_weighted_direction(n: vec3f, t: ptr<function, u32>) -> vec3f {
    let r1 = rnd(t); let r2 = rnd(t);
    let theta = acos(sqrt(1.0 - r1));
    let phi = 2.0 * Pi * r2;
    return rotate_to_normal(n, vec3f(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)));
}

// -------------------------------------------------------------------------
// Intersection Logic (Scene, BVH, Primitives)
// -------------------------------------------------------------------------
fn intersect_min_max(r: ptr<function, Ray>) -> bool {
    let p1 = (aabb.min - r.origin) / r.direction;
    let p2 = (aabb.max - r.origin) / r.direction;
    let t_min = max(max(min(p1.x, p2.x), min(p1.y, p2.y)), min(p1.z, p2.z)) - 1e-3;
    let t_max = min(min(max(p1.x, p2.x), max(p1.y, p2.y)), max(p1.z, p2.z)) + 1e-3;
    if (t_min > t_max || t_min > r.tmax || t_max < r.tmin) { return false; }
    r.tmin = max(t_min, r.tmin); r.tmax = min(t_max, r.tmax);
    return true;
}

fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, i: u32) -> bool {
    let face = meshFaces[i];
    let v0 = vInfo[face.x].position;
    let e0 = vInfo[face.y].position - v0;
    let e1 = vInfo[face.z].position - v0;
    let n_tri = cross(e0, e1);
    let q = dot(r.direction, n_tri);
    if (abs(q) < 1e-8) { return false; }
    let a = v0 - r.origin;
    let t = dot(a, n_tri) / q;
    if (t < r.tmin || t > r.tmax) { return false; }
    let b_p = cross(a, r.direction);
    let beta = dot(b_p, e1) / q;
    let gamma = -dot(b_p, e0) / q;
    if (beta < 0.0 || gamma < 0.0 || (beta + gamma) > 1.0) { return false; }
    hit.has_hit = true; hit.position = r.origin + r.direction * t; hit.distance = t;
    hit.normal = normalize(vInfo[face.x].normal * (1.0-beta-gamma) + vInfo[face.y].normal * beta + vInfo[face.z].normal * gamma);
    return true;
}

fn intersect_trimesh(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    var branch_lvl = 0u; var node = 0u;
    for (var i = 0u; i <= MAX_LEVEL; i++) {
        let tree_node = bspTree[node]; let axis_leaf = tree_node.x & 3u;
        if (axis_leaf == BSP_LEAF) {
            let count = tree_node.x >> 2u; let id = tree_node.y; var found = false;
            for (var j = 0u; j < count; j++) {
                let idx = treeIds[id + j];
                if (intersect_triangle(*r, hit, idx)) { r.tmax = hit.distance; hit.triangle_idx = idx; found = true; }
            }
            if (found) { return true; }
            if (branch_lvl == 0u) { return false; }
            branch_lvl--; i = branch_node[branch_lvl].x; node = branch_node[branch_lvl].y;
            r.tmin = branch_ray[branch_lvl].x; r.tmax = branch_ray[branch_lvl].y;
            continue;
        }
        let axis_dir = r.direction[axis_leaf];
        let near = select(tree_node.w, tree_node.z, axis_dir >= 0.0);
        let far = select(tree_node.z, tree_node.w, axis_dir >= 0.0);
        let t_split = (bspPlanes[node] - r.origin[axis_leaf]) / select(axis_dir, 1e-8, abs(axis_dir) < 1e-8);
        if (t_split >= r.tmax) { node = near; }
        else if (t_split <= r.tmin) { node = far; }
        else { branch_node[branch_lvl] = vec2u(i, far); branch_ray[branch_lvl] = vec2f(t_split, r.tmax); branch_lvl++; r.tmax = t_split; node = near; }
    }
    return false;
}

fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, center: vec3f, radius: f32) -> bool {
    let oc = r.origin - center; let bhalf = dot(oc, r.direction);
    let discriminant = bhalf * bhalf - (dot(oc, oc) - radius * radius);
    if (discriminant < 1e-8) { return false; }
    let s_disc = sqrt(discriminant); var t = -bhalf - s_disc;
    if (t < r.tmin || t > r.tmax) { t = -bhalf + s_disc; }
    if (t < r.tmin || t > r.tmax) { return false; }
    hit.has_hit = true; hit.distance = t; hit.position = r.origin + r.direction * t; hit.normal = normalize(hit.position - center);
    return true;
}

fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    if (!intersect_min_max(r)) { return false; }
    if (intersect_sphere(*r, hit, vec3f(420.0, 90.0, 370.0), 90.0)) { hit.shader = 3u; r.tmax = hit.distance; }
    if (intersect_sphere(*r, hit, vec3f(130.0, 90.0, 250.0), 90.0)) { 
        hit.ior1_over_ior2 = 1.0 / 1.5; hit.shader = 6u; 
        hit.extinction = vec3f(0.01, 1.0, 0.0); // Green Tint
        r.tmax = hit.distance; 
    }
    if (intersect_trimesh(r, hit)) {
        let mat = materials[meshFaces[hit.triangle_idx].w];
        hit.diffuse = mat.diffuse.rgb; hit.emission = mat.emission.rgb; hit.shader = uniforms.triangle_shader; r.tmax = hit.distance;
    }
    return hit.has_hit;
}

// -------------------------------------------------------------------------
// Shading, Lighting, and Material Functions
// -------------------------------------------------------------------------
fn fresnel_R(costhetai: f32, costhetat: f32, ior_i_over_t: f32) -> f32 {
    let r_per = (ior_i_over_t * costhetai - costhetat) / (ior_i_over_t * costhetai + costhetat);
    let r_par = (costhetai - ior_i_over_t * costhetat) / (costhetai + ior_i_over_t * costhetat);
    return 0.5 * (r_per * r_per + r_par * r_par);
}

fn sample_area_light(pos: vec3f, t: ptr<function, u32>) -> Light {
    var light = Light(vec3f(0.0), vec3f(0.0), 0.0); let numLights = arrayLength(&lightIndices);
    if (numLights == 0u) { return light; }
    let l_idx = lightIndices[u32(rnd(t) * f32(numLights))]; let face = meshFaces[l_idx];
    let v0 = vInfo[face.x].position; let v1 = vInfo[face.y].position; let v2 = vInfo[face.z].position;
    let r1 = rnd(t); let r2 = rnd(t); let alpha = 1.0-sqrt(r1); let beta = (1.0-r2)*sqrt(r1); let gamma = r2*sqrt(r1);
    let light_pos = v0*alpha + v1*beta + v2*gamma;
    let n_light = normalize(vInfo[face.x].normal*alpha + vInfo[face.y].normal*beta + vInfo[face.z].normal*gamma);
    light.w_i = normalize(light_pos - pos); light.dist = length(light_pos - pos);
    light.L_i = max(dot(-light.w_i, n_light), 0.0) * materials[meshFaces[l_idx].w].emission.rgb * (length(cross(v1-v0, v2-v0))*0.5) * f32(numLights);
    return light;
}

fn lambertian(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, t: ptr<function, u32>) -> vec3f {
    let light = sample_area_light(hit.position, t);
    var shadow_ray = Ray(hit.position, light.w_i, 1e-3, light.dist - 1e-3);
    var shadow_hit = default_hitinfo();
    let V = !intersect_scene(&shadow_ray, &shadow_hit);
    let direct = select(vec3f(0.0), (hit.diffuse / Pi) * light.L_i * max(dot(hit.normal, light.w_i), 0.0), V);
    hit.throughput *= hit.diffuse; let Pd = (hit.throughput.r + hit.throughput.g + hit.throughput.b) / 3.0;
    if (rnd(t) < Pd) {
        hit.throughput /= Pd; r.origin = hit.position; r.direction = sample_cosine_weighted_direction(hit.normal, t);
        r.tmin = 1e-3; r.tmax = 1e6; hit.emit = false; hit.has_hit = false;
    }
    return direct + hit.emission;
}

fn mirror(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    hit.emit = true; hit.has_hit = false;
    r.origin = hit.position; r.direction = reflect(r.direction, hit.normal);
    r.tmin = 1e-3; r.tmax = 1e6;
    return vec3f(0.0);
}

fn transparent(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, t: ptr<function, u32>) -> vec3f {
    hit.emit = true; var eta = hit.ior1_over_ior2; var n = hit.normal; var costhetai = dot(-r.direction, n);
    if (costhetai < 0.0) { 
        eta = 1.0/eta; n = -n; costhetai = -costhetai;
        let Tr = exp(-hit.extinction * hit.distance);
        let prob = (Tr.x + Tr.y + Tr.z) / 3.0;
        if (rnd(t) < prob) { hit.throughput *= (Tr / prob); }
        else { return vec3f(0.0); }
    }
    let sin2thetat = (eta * eta) * (1.0 - costhetai * costhetai);
    if (sin2thetat > 1.0) { return mirror(r, hit); }
    let costhetat = sqrt(1.0 - sin2thetat); let R = fresnel_R(costhetai, costhetat, eta);
    hit.has_hit = false; r.origin = hit.position; r.tmin = 1e-3; r.tmax = 1e6;
    if (rnd(t) < R) { r.direction = reflect(r.direction, hit.normal); }
    else { r.direction = normalize(eta * (costhetai * n - (-r.direction)) - n * costhetat); }
    return vec3f(0.0);
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, t: ptr<function, u32>) -> vec3f {
    switch hit.shader {
        case 1 { return lambertian(r, hit, t); }
        case 3 { return mirror(r, hit); }
        case 6 { return transparent(r, hit, t); }
        case default { return hit.diffuse + hit.emission; }
    }
}

// -------------------------------------------------------------------------
// Shader Entry Points
// -------------------------------------------------------------------------
@vertex
fn main_vs(@builtin(vertex_index) VertexIndex: u32) -> VSOut {
    const pos = array<vec2f, 4>(vec2f(-1, 1), vec2f(-1, -1), vec2f(1, 1), vec2f(1, -1));
    var vsOut: VSOut; vsOut.position = vec4f(pos[VertexIndex], 0.0, 1.0); vsOut.coords = pos[VertexIndex];
    return vsOut;
}

@fragment
fn main_fs(@builtin(position) fragcoord: vec4f, @location(0) coords: vec2f) -> FSOut {
    var t = tea(u32(fragcoord.y) * uniforms.width + u32(fragcoord.x), uniforms.frame);
    let prog_jitter = vec2f(rnd(&t), rnd(&t)) / (f32(uniforms.height) * 2.0);
    const bgcolor = vec4f(0.1, 0.3, 0.6, 1.0);
    let uv = vec2f(coords.x * uniforms.aspect * 0.5, coords.y * 0.5);
    var res = vec3f(0.0); var r = Ray(uniforms.eye_point, normalize(uniforms.b1 * (uv.x + prog_jitter.x) + uniforms.b2 * (uv.y + prog_jitter.y) + uniforms.v * uniforms.camera_constant), 1e-4, 1e10);
    var hit = default_hitinfo();
    for (var i = 0; i < 10; i++) {
        if (intersect_scene(&r, &hit)) { res += hit.throughput * shade(&r, &hit, &t); }
        else { res += hit.throughput * select(vec3f(0.0), bgcolor.rgb, uniforms.enable_background == 1u); break; }
        if (hit.has_hit) { break; }
    }
    let curr_sum = textureLoad(renderTexture, vec2u(fragcoord.xy), 0).rgb * f32(uniforms.frame);
    let accum_color = (res + curr_sum) / f32(uniforms.frame + 1u);
    return FSOut(vec4f(pow(accum_color, vec3f(1.0 / uniforms.gamma)), 1.0), vec4f(accum_color, 1.0));
}