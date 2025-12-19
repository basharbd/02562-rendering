// Structures
struct Uniforms {
    aspect: f32,
    camera_constant: f32,
    gamma: f32,
    triangle_shader: u32,
    subpixels: u32,
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
}

fn default_hitinfo() -> HitInfo {
    return HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0.0, 0.0, 0u, 0u);
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

struct VSOut { 
    @builtin(position) position: vec4f, 
    @location(0) coords: vec2f 
}

struct Light { 
    L_i: vec3f, 
    w_i: vec3f, 
    dist: f32 
}

// Bindings
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var<storage> jitter: array<vec2f>;
@group(0) @binding(2) var<storage> vInfo: array<VertexInfo>;
@group(0) @binding(3) var<storage> meshFaces: array<vec4u>;
@group(0) @binding(5) var<storage> materials: array<Material>;
@group(0) @binding(6) var<uniform> aabb: Aabb;

// BSP Bindings & Globals
@group(0) @binding(7) var<storage> treeIds: array<u32>;
@group(0) @binding(8) var<storage> bspTree: array<vec4u>;
@group(0) @binding(9) var<storage> bspPlanes: array<f32>;
@group(0) @binding(10) var<storage> lightIndices: array<u32>;

const MAX_LEVEL = 20u;
const BSP_LEAF = 3u;
var<private> branch_node: array<vec2u, MAX_LEVEL>;
var<private> branch_ray: array<vec2f, MAX_LEVEL>;

// Intersection Logic (AABB & Triangles)
fn intersect_min_max(r: ptr<function, Ray>) -> bool {
    let p1 = (aabb.min - r.origin) / r.direction;
    let p2 = (aabb.max - r.origin) / r.direction;
    let pmin = min(p1, p2);
    let pmax = max(p1, p2);
    let box_tmin = max(pmin.x, max(pmin.y, pmin.z)) - 1.0e-3f;
    let box_tmax = min(pmax.x, min(pmax.y, pmax.z)) + 1.0e-3f;
    if (box_tmin > box_tmax || box_tmin > r.tmax || box_tmax < r.tmin) {
        return false;
    }
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
    let gamma = - dot(b_p, e0) / q;
    if (beta < 0.0 || gamma < 0.0 || (1.0 - beta - gamma) < 0.0) { return false; }
    hit.has_hit = true;
    hit.position = r.origin + r.direction * t;
    hit.distance = t;
    hit.normal = normalize(vInfo[face.x].normal * (1.0 - beta - gamma) + vInfo[face.y].normal * beta + vInfo[face.z].normal * gamma);
    return true;
}

// BSP Traversal
fn intersect_trimesh(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    var branch_lvl = 0u;
    var node = 0u;
    for (var i = 0u; i <= MAX_LEVEL; i++) {
        let tree_node = bspTree[node];
        let node_axis_leaf = tree_node.x & 3u;
        if (node_axis_leaf == BSP_LEAF) {
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
        let axis_dir = r.direction[node_axis_leaf];
        let near = select(tree_node.w, tree_node.z, axis_dir >= 0.0);
        let far = select(tree_node.z, tree_node.w, axis_dir >= 0.0);
        let t = (bspPlanes[node] - r.origin[node_axis_leaf]) / select(axis_dir, 1e-8, abs(axis_dir) < 1e-8);
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

// Vertex Shader
@vertex
fn main_vs(@builtin(vertex_index) VertexIndex: u32) -> VSOut {
    const pos = array<vec2f, 4>(vec2f(- 1.0, 1.0), vec2f(- 1.0, - 1.0), vec2f(1.0, 1.0), vec2f(1.0, - 1.0));
    var vsOut: VSOut;
    vsOut.position = vec4f(pos[VertexIndex], 0.0, 1.0);
    vsOut.coords = pos[VertexIndex];
    return vsOut;
}

// Ray Generation
fn get_camera_ray(ipcoords: vec2f) -> Ray {
    var q = uniforms.b1 * ipcoords.x + uniforms.b2 * ipcoords.y + uniforms.v * uniforms.camera_constant;
    return Ray(uniforms.eye_point, normalize(q), 1e-4, 1e10);
}

// Sphere Intersection
fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, center: vec3f, radius: f32) -> bool {
    let oc = r.origin - center;
    let bhalf = dot(oc, r.direction);
    let c = dot(oc, oc) - radius * radius;
    let discriminant = bhalf * bhalf - c;
    if (discriminant < 1e-8) { return false; }
    let sqrt_disc = sqrt(discriminant);
    let t1 = - bhalf - sqrt_disc;
    if (t1 >= r.tmin && t1 <= r.tmax) {
        hit.has_hit = true;
        hit.distance = t1;
        hit.position = r.origin + r.direction * t1;
        hit.normal = normalize(hit.position - center);
        return true;
    } else {
        let t2 = - bhalf + sqrt_disc;
        if (t2 >= r.tmin && t2 <= r.tmax) {
            hit.has_hit = true;
            hit.distance = t2;
            hit.position = r.origin + r.direction * t2;
            hit.normal = normalize(hit.position - center);
            return true;
        }
    }
    return false;
}

// Main Intersection Dispatcher
fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    if (!intersect_min_max(r)) { return false; }
    
    // Hardcoded spheres
    if (intersect_sphere(*r, hit, vec3f(420.0, 90.0, 370.0), 90.0)) { hit.shader = 3u; r.tmax = hit.distance; }
    if (intersect_sphere(*r, hit, vec3f(130.0, 90.0, 250.0), 90.0)) { hit.ior1_over_ior2 = 1 / 1.5; hit.shader = 4u; r.tmax = hit.distance; }
    
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
fn sample_area_light(pos: vec3f) -> Light {
    var light = Light();
    var light_pos = vec3f(0.0);
    var light_int = vec3f(0.0);
    let numL = arrayLength(&lightIndices);
    for (var i = 0u; i < numL; i++) {
        let lIdx = lightIndices[i];
        let face = meshFaces[lIdx];
        let v0 = vInfo[face.x].position;
        let center = (v0 + vInfo[face.y].position + vInfo[face.z].position) / 3.0;
        let n = normalize(vInfo[face.x].normal + vInfo[face.y].normal + vInfo[face.z].normal);
        light_pos += center;
        let area = length(cross(vInfo[face.y].position - v0, vInfo[face.z].position - v0)) * 0.5;
        let w_i = normalize(center - pos);
        light_int += dot(- w_i, n) * materials[meshFaces[lIdx].w].emission * area;
    }
    light_pos /= f32(numL);
    light.dist = length(light_pos - pos);
    light.w_i = normalize(light_pos - pos);
    light.L_i = light_int / (light.dist * light.dist);
    return light;
}

fn lambertian(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    let light = sample_area_light(hit.position);
    var shadow_ray = Ray(hit.position, light.w_i, 0.001, light.dist - 0.001);
    var shadow_hit = default_hitinfo();
    if (intersect_scene(&shadow_ray, & shadow_hit)) { return hit.emission; }
    return (hit.diffuse / 3.14) * light.L_i * dot(hit.normal, light.w_i) + hit.emission;
}

fn mirror(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    hit.has_hit = false;
    r.origin = hit.position;
    r.direction = reflect(r.direction, hit.normal);
    r.tmin = 1e-2;
    r.tmax = 1e+6;
    return vec3f(0.0);
}

fn refraction(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    var eta = hit.ior1_over_ior2;
    var n = hit.normal;
    var costhetai = dot(- r.direction, n);
    if (costhetai < 0.0) { eta = 1 / hit.ior1_over_ior2; n = - hit.normal; }
    costhetai = dot(- r.direction, n);
    let sin2thetai = 1.0 - costhetai * costhetai;
    let cos2thetat = 1.0 - eta * eta * sin2thetai;
    if (cos2thetat < 0.0) { return mirror(r, hit); }
    hit.has_hit = false;
    r.origin = hit.position;
    r.direction = normalize(eta * (costhetai * n - (- r.direction)) - n * sqrt(cos2thetat));
    r.tmin = 1e-2;
    r.tmax = 1e+6;
    return vec3f(0.0);
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    switch hit.shader {
        case 1 { return lambertian(r, hit); }
        case 3 { return mirror(r, hit); }
        case 4 { return refraction(r, hit); }
        case default { return hit.diffuse + hit.emission; }
    }
}

// Fragment Shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
    const bg = vec4f(0.1, 0.3, 0.6, 1.0);
    let uv = vec2f(coords.x * uniforms.aspect * 0.5f, coords.y * 0.5f);
    let sub = uniforms.subpixels * uniforms.subpixels;
    var res = vec3f(0.0);
    for (var p = 0u; p < sub; p++) {
        var r = get_camera_ray(uv + jitter[p]);
        var hit = default_hitinfo();
        for (var i = 0; i < 10; i++) {
            if (intersect_scene(&r, & hit)) { res += shade(&r, & hit); }
            else { res += bg.rgb; break; }
            if (hit.has_hit) { break; }
        }
    }
    return vec4f(pow(res / f32(sub), vec3f(1.0 / uniforms.gamma)), bg.a);
}