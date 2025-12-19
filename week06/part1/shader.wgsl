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
}

fn default_hitinfo() -> HitInfo {
    return HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0.0, 0.0, 0u);
}

struct Material {
    emission: vec3f,
    diffuse: vec3f,
}

struct Aabb {
    min: vec3f,
    max: vec3f,
}

struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) coords: vec2f,
}

// Bindings
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(2) var<storage> jitter: array<vec2f>;
@group(0) @binding(3) var<storage> vPositions: array<vec3f>;
@group(0) @binding(4) var<storage> meshFaces: array<vec3u>;
@group(0) @binding(5) var<storage> meshNormals: array<vec3f>;
@group(0) @binding(6) var<storage> materials: array<Material>;
@group(0) @binding(7) var<storage> matIndices: array<u32>;
@group(0) @binding(8) var<storage> lightIndices: array<u32>;
@group(0) @binding(9) var<uniform> aabb: Aabb;

// Ray-AABB Intersection
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

// Scene Intersection Logic
fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, i: u32) -> bool {
    let face = meshFaces[i];
    let v0 = vPositions[face.x];
    let v1 = vPositions[face.y];
    let v2 = vPositions[face.z];
    let n0 = meshNormals[face.x];
    let n1 = meshNormals[face.y];
    let n2 = meshNormals[face.z];

    let e0 = v1 - v0;
    let e1 = v2 - v0;
    let n = cross(e0, e1);
    let q = dot(r.direction, n);
    if (abs(q) < 0.0001) { return false; }

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
    return true;
}

fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    let numTriangles = arrayLength(&meshFaces);
    for (var i = 0u; i < numTriangles; i++) {
        if (intersect_triangle(*r, hit, i)) {
            let mat = materials[matIndices[i]];
            hit.diffuse = mat.diffuse;
            hit.emission = mat.emission;
            hit.shader = uniforms.triangle_shader;
            r.tmax = hit.distance;
        }
    }
    return hit.has_hit;
}

// Shading Logic
fn lambertian(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    let dir = normalize(vec3f(- 1.0));
    let light_L_i = vec3f(1.0) * 3.14;
    let light_w_i = -dir;

    var shadow_ray = Ray(hit.position, light_w_i, 0.001, 1e30);
    var shadow_hit = default_hitinfo();
    if (intersect_scene(&shadow_ray, &shadow_hit)) {
        return hit.emission;
    }
    return (hit.diffuse / 3.14) * light_L_i * max(dot(hit.normal, light_w_i), 0.0) + hit.emission;
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    switch hit.shader {
        case 1 { return lambertian(r, hit); }
        case default { return hit.diffuse + hit.emission; }
    }
}

// Fragment Shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
    const bgcolor = vec4f(0.1, 0.3, 0.6, 1.0);
    let uv = vec2f(coords.x * uniforms.aspect * 0.5f, coords.y * 0.5f);
    let subpixels = uniforms.subpixels * uniforms.subpixels;
    var result = vec3f(0.0);
    for (var p = 0u; p < subpixels; p++) {
        let jit = jitter[p];
        var r = get_camera_ray(uv + jit);
        if (!intersect_min_max(&r)) {
            result += bgcolor.rgb;
            continue;
        }
        var hit = default_hitinfo();
        if (intersect_scene(&r, &hit)) {
            result += shade(&r, &hit);
        } else {
            result += bgcolor.rgb;
        }
    }
    return vec4f(pow(result / f32(subpixels), vec3f(1.0 / uniforms.gamma)), bgcolor.a);
}