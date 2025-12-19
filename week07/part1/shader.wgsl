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

struct FSOut {
    @location(0) frame: vec4f,
    @location(1) accum: vec4f,
}

struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) coords: vec2f,
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
    let v1 = vInfo[face.y].position;
    let v2 = vInfo[face.z].position;
    let n0 = vInfo[face.x].normal;
    let n1 = vInfo[face.y].normal;
    let n2 = vInfo[face.z].normal;
    let e0 = v1 - v0;
    let e1 = v2 - v0;
    let n = cross(e0, e1);
    let q = dot(r.direction, n);
    if (abs(q) < 1e-8) { return false; }
    let a = v0 - r.origin;
    let t = dot(a, n) / q;
    if (t < r.tmin || t > r.tmax) { return false; }
    let beta = dot(cross(a, r.direction), e1) / q;
    let gamma = - dot(cross(a, r.direction), e0) / q;
    if (beta < 0.0 || gamma < 0.0 || (1.0 - beta - gamma) < 0.0) { return false; }
    hit.has_hit = true;
    hit.position = r.origin + r.direction * t;
    hit.distance = t;
    hit.normal = normalize(n0 * (1.0 - beta - gamma) + n1 * beta + n2 * gamma);
    return hit.has_hit;
}

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
    }
    else {
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

// BSP Traversal
fn intersect_trimesh(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    var branch_lvl = 0u;
    var near_node = 0u;
    var far_node = 0u;
    var t = 0.0f;
    var node = 0u;
    for (var i = 0u; i <= MAX_LEVEL; i++) {
        let tree_node = bspTree[node];
        let node_axis_leaf = tree_node.x & 3u;
        if (node_axis_leaf == BSP_LEAF) {
            let node_count = tree_node.x >> 2u;
            let node_id = tree_node.y;
            var found = false;
            for (var j = 0u; j < node_count; j++) {
                let obj_idx = treeIds[node_id + j];
                if (intersect_triangle(*r, hit, obj_idx)) {
                    r.tmax = hit.distance;
                    hit.triangle_idx = obj_idx;
                    found = true;
                }
            }
            if (found) { return true; }
            else if (branch_lvl == 0u) { return false; }
            else {
                branch_lvl--;
                i = branch_node[branch_lvl].x;
                node = branch_node[branch_lvl].y;
                r.tmin = branch_ray[branch_lvl].x;
                r.tmax = branch_ray[branch_lvl].y;
                continue;
            }
        }
        let axis_direction = r.direction[node_axis_leaf];
        let axis_origin = r.origin[node_axis_leaf];
        if (axis_direction >= 0.0f) {
            near_node = tree_node.z;
            far_node = tree_node.w;
        }
        else {
            near_node = tree_node.w;
            far_node = tree_node.z;
        }
        let node_plane = bspPlanes[node];
        let denom = select(axis_direction, 1.0e-8f, abs(axis_direction) < 1.0e-8f);
        t = (node_plane - axis_origin) / denom;
        if (t > r.tmax) { node = near_node; }
        else if (t < r.tmin) { node = far_node; }
        else {
            branch_node[branch_lvl].x = i;
            branch_node[branch_lvl].y = far_node;
            branch_ray[branch_lvl].x = t;
            branch_ray[branch_lvl].y = r.tmax;
            branch_lvl++;
            r.tmax = t;
            node = near_node;
        }
    }
    return false;
}

fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, position: vec3f, normal: vec3f) -> bool {
    var q = dot(r.direction, normal);
    if (abs(q) < 1e-4) { return false; }
    var t = dot(position - r.origin, normal) / q;
    if (t < r.tmin || t > r.tmax) { return false; }
    hit.has_hit = true;
    hit.position = r.origin + r.direction * t;
    hit.distance = t;
    hit.normal = normal;
    return true;
}

// Scene Intersection Dispatcher
fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    if (!intersect_min_max(r)) { return false; }
    if (intersect_trimesh(r, hit)) {
        let mat = materials[meshFaces[hit.triangle_idx].w];
        hit.diffuse = mat.diffuse;
        hit.emission = mat.emission;
        hit.specular = vec3f(0.0, 0.0, 0.0);
        hit.shader = uniforms.triangle_shader;
        r.tmax = hit.distance;
    }
    return hit.has_hit;
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
    const t_max = 1e10;
    var q = uniforms.b1 * ipcoords.x + uniforms.b2 * ipcoords.y + uniforms.v * uniforms.camera_constant;
    var w = normalize(q);
    return Ray(uniforms.eye_point, w, 1e-4, t_max);
}

// Lighting & Shading
fn sample_point_light(pos: vec3f) -> Light {
    var light = Light();
    const light_position = vec3f(0.0, 1.0, 0.0);
    const intensity = vec3f(1.0, 1.0, 1.0) * 3.14;
    light.dist = length(light_position - pos);
    light.w_i = normalize(light_position - pos);
    light.L_i = intensity / (light.dist * light.dist);
    return light;
}

fn sample_directional_light(pos: vec3f) -> Light {
    var light = Light();
    let dir = normalize(vec3f(- 1.0));
    const intensity = vec3f(1.0) * 3.14;
    light.w_i = - dir;
    light.L_i = intensity;
    light.dist = 1.0e32;
    return light;
}

fn sample_area_light(pos: vec3f) -> Light {
    var light = Light();
    var light_position = vec3f(0.0);
    var light_intensity = vec3f(0.0);
    let numLights = arrayLength(&lightIndices);
    for (var i = 0u; i < numLights; i++) {
        let lightIndex = lightIndices[i];
        let face = meshFaces[lightIndex];
        let v0 = vInfo[face.x].position;
        let v1 = vInfo[face.y].position;
        let v2 = vInfo[face.z].position;
        let n0 = vInfo[face.x].normal;
        let n1 = vInfo[face.y].normal;
        let n2 = vInfo[face.z].normal;
        let center = (v0 + v1 + v2) / 3.0;
        let n = normalize(n0 + n1 + n2);
        light_position += center;
        let edge1 = v1 - v0;
        let edge2 = v2 - v0;
        let area = length(cross(edge1, edge2)) * 0.5;
        let w_i = normalize(center - pos);
        light_intensity += dot(- w_i, n) * materials[meshFaces[lightIndex].w].emission * area;
    }
    light_position /= f32(numLights);
    light.dist = length(light_position - pos);
    light.w_i = normalize(light_position - pos);
    light.L_i = light_intensity / (light.dist * light.dist);
    return light;
}

fn lambertian(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    let light = sample_area_light(hit.position);
    var shadow_ray = Ray(hit.position, light.w_i, 0.001, light.dist - 0.001);
    var shadow_hit = default_hitinfo();
    if (intersect_scene(&shadow_ray, & shadow_hit)) { return hit.emission; }
    return (hit.diffuse / 3.14) * light.L_i * dot(hit.normal, light.w_i) + hit.emission;
}

fn phong(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    let light = sample_point_light(hit.position);
    var shadow_ray = Ray(hit.position, light.w_i, 0.0001, light.dist);
    var shadow_hit = default_hitinfo();
    if (intersect_scene(&shadow_ray, & shadow_hit)) { return hit.emission; }
    let n = normalize(hit.normal);
    let wi = light.w_i;
    let wr = normalize(reflect(- wi, n));
    let wo = - r.direction;
    let wo_dot_wr = max(dot(wo, wr), 0);
    let Lr = ((hit.diffuse / 3.14) + (hit.specular * (hit.shininess + 2.0) / (2 * 3.14) * pow(wo_dot_wr, hit.shininess))) * light.L_i * dot(light.w_i, n);
    return Lr;
}

fn mirror(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    let reflected_dir = reflect(r.direction, hit.normal);
    hit.has_hit = false;
    r.origin = hit.position;
    r.direction = reflected_dir;
    r.tmin = 1e-2;
    r.tmax = 1e+6;
    return vec3f(0.0, 0.0, 0.0);
}

fn refraction(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    var eta = hit.ior1_over_ior2;
    var n = hit.normal;
    var costhetai = dot(- r.direction, n);
    if (costhetai < 0.0) {
        eta = 1 / hit.ior1_over_ior2;
        n = - hit.normal;
    }
    costhetai = dot(- r.direction, n);
    let sin2thetai = 1.0 - costhetai * costhetai;
    let sinthetat = eta * sqrt(sin2thetai);
    let cos2thetat = 1.0 - eta * eta * sin2thetai;
    if (cos2thetat < 0.0) { return mirror(r, hit); }
    let t = (costhetai * n - (- r.direction)) / sqrt(sin2thetai);
    let tsinthetat = eta * (costhetai * n - (- r.direction));
    let refracted_dir = normalize(tsinthetat - n * sqrt(cos2thetat));
    hit.has_hit = false;
    r.origin = hit.position;
    r.direction = refracted_dir;
    r.tmin = 1e-2;
    r.tmax = 1e+6;
    return vec3f(0.0, 0.0, 0.0);
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    switch hit.shader {
        case 1 { return lambertian(r, hit); }
        case 2 { return phong(r, hit); }
        case 3 { return mirror(r, hit); }
        case 4 { return refraction(r, hit); }
        case 5 { return phong(r, hit) + refraction(r, hit); }
        case default { return hit.diffuse + hit.emission; }
    }
}

// PRNG & Utils
fn tea(val0: u32, val1: u32) -> u32 {
    const N = 16u;
    var v0 = val0;
    var v1 = val1;
    var s0 = 0u;
    for (var n = 0u; n < N; n++) {
        s0 += 0x9e3779b9;
        v0 += ((v1 << 4) + 0xa341316c) ^ (v1 + s0) ^ ((v1 >> 5) + 0xc8013ea4);
        v1 += ((v0 << 4) + 0xad90777d) ^ (v0 + s0) ^ ((v0 >> 5) + 0x7e95761e);
    }
    return v0;
}

fn mcg31(prev: ptr<function, u32>) -> u32 {
    const LCG_A = 1977654935u;
    * prev = (LCG_A * (*prev)) & 0x7FFFFFFF;
    return * prev;
}

fn rnd(prev: ptr<function, u32>) -> f32 {
    return f32(mcg31(prev)) / f32(0x80000000);
}

fn spherical_direction(sin_theta: f32, cos_theta: f32, phi: f32) -> vec3f {
    return vec3f(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta);
}

fn rotate_to_normal(n: vec3f, v: vec3f) -> vec3f {
    let s = sign(n.z + 1.0e-16f);
    let a = - 1.0f / (1.0f + abs(n.z));
    let b = n.x * n.y * a;
    return vec3f(1.0f + n.x * n.x * a, b, - s * n.x) * v.x + vec3f(s * b, s * (1.0f + n.y * n.y * a), - n.y) * v.y + n * v.z;
}

// Fragment Shader
@fragment
fn main_fs(@builtin(position) fragcoord: vec4f, @location(0) coords: vec2f) -> FSOut {
    let launch_idx = u32(fragcoord.y) * uniforms.width + u32(fragcoord.x);
    var t = tea(launch_idx, uniforms.frame);
    let prog_jitter = vec2f(rnd(&t), rnd(&t)) / (f32(uniforms.height) * sqrt(f32(uniforms.no_of_jitters)));

    const bgcolor = vec4f(0.1, 0.3, 0.6, 1.0);
    const max_depth = 10;
    let uv = vec2f(coords.x * uniforms.aspect * 0.5f, coords.y * 0.5f);
    let subpixels = uniforms.subpixels * uniforms.subpixels;
    var result = vec3f(0.0);
    for (var p = 0u; p < subpixels; p++) {
        let jit = jitter[p];
        var r = get_camera_ray(uv + jit + prog_jitter);
        var hit = default_hitinfo();
        for (var i = 0; i < max_depth; i++) {
            if (intersect_scene(&r, & hit)) {
                result += shade(&r, & hit);
            }
            else {
                result += bgcolor.rgb;
                break;
            }
            if (hit.has_hit) {
                break;
            }
        }
    }

    result = result / f32(subpixels);
    let curr_sum = textureLoad(renderTexture, vec2u(fragcoord.xy), 0).rgb * f32(uniforms.frame);
    let accum_color = (result + curr_sum) / f32(uniforms.frame + 1u);

    var fsOut: FSOut;
    fsOut.frame = vec4f(pow(accum_color, vec3f(1.0 / uniforms.gamma)), bgcolor.a);
    fsOut.accum = vec4f(accum_color, 1.0);
    return fsOut;
}