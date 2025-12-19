// Uniforms and storage buffers
struct Uniforms {
    aspect: f32,
    camera_constant: f32,
    jitterSub: f32,
};

@group(0) @binding(0) var<uniform> uniforms : Uniforms;
@group(0) @binding(1) var<storage> jitter: array<vec2f>; 
@group(0) @binding(2) var<storage> triangle: array<vec3f>; 
@group(0) @binding(3) var<storage> face: array<vec3u>; 

// Vertex Shader Output
struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) coords : vec2f
};

// Vertex Shader: Generates a full-screen quad
@vertex
fn main_vs(@builtin(vertex_index) VertexIndex : u32) -> VSOut
{
    const pos = array<vec2f, 4>(vec2f(-1.0, 1.0), vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(1.0, -1.0));
    var vsOut: VSOut;
    vsOut.position = vec4f(pos[VertexIndex], 0.0, 1.0);
    vsOut.coords = pos[VertexIndex];
    return vsOut;
}

const Pi = 3.1415926535;
const lightPosition = vec3f(0.0, 1.0, 0.0);
const epsilon = 0.0001;

// Ray definition
struct Ray {
    origin: vec3f,
    direction: vec3f,
    tmin: f32,
    tmax: f32
};
    
// Generates a ray from the camera through the pixel coordinates
fn get_camera_ray(uv: vec2f) -> Ray
{
    const e = vec3f(0.15, 1.5, 10.0);
    const p = vec3f(0.15, 1.5, 0.0);
    const u = vec3f(0.0, 1.0, 0.0);
    var d = uniforms.camera_constant;
    var v = normalize(p-e);
    var b1 = normalize(cross(v, u));
    var b2 = cross(b1, v);
    var q = b1 * uv.x + b2 * uv.y + v * d;
    var omega = normalize(q);
    
    var ray = Ray(e, omega, 0.0, 1.0e32);
    return ray;
}

// Light definition
struct Light {
    L_i: vec3f,
    direction: vec3f,
    dist: f32
};

// Sample a point light source
fn sample_point_light(pos: vec3f) -> Light
{
    const lightIntensity = vec3f(Pi, Pi, Pi); 
    
    var L_i = lightIntensity / dot((lightPosition - pos), (lightPosition - pos));
    var l = lightPosition - pos;
    var dist = length(l);
    
    var light = Light(L_i, normalize(l), dist);
    return light;
}

// Sample a directional light source
fn sample_directional_light() -> Light 
{
    const intensityGAINS = 1;
    const lightIntensity = vec3f(Pi*intensityGAINS, Pi*intensityGAINS, Pi*intensityGAINS);

    var L_i = lightIntensity;
    var l = normalize(vec3f(-1.0, -1.0, -1.0));
    var dist = 1e32;

    var light = Light(L_i, l, dist);
    return light;
}

// Intersection data
struct HitInfo {
    has_hit: bool,
    dist: f32,
    position: vec3f,
    normal: vec3f,
    ambientColor: vec3f,
    diffuseColor: vec3f,
    shader: f32,
    ior1_over_ior2: f32,
    rho_s: f32,
    s: f32,
};

// Iterate over all scene geometry
fn intersect_scene(r: ptr<function, Ray>, hit : ptr<function, HitInfo>) -> bool
{
    var triangleRGB = vec3f(0.9);
    (*r).tmin = epsilon;
    for (var i = 0u; i < arrayLength(&face); i++) 
    {
        if (intersect_triangle(*r, hit, i)) {
            (*r).tmax = min((*hit).dist, (*r).tmax);
            (*hit).has_hit = true;
            (*hit).has_hit = true;
            if ((*r).tmax == (*hit).dist) {
                (*hit).diffuseColor = triangleRGB;
            }
        }
    }
    return (*hit).has_hit;
}

// Ray-Triangle intersection
fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, index: u32) -> bool 
{
    let temp = face[index]; 
    var e0 = triangle[temp.y] - triangle[temp.x];
    var e1 = triangle[temp.z] - triangle[temp.x];
    var n = cross(e0, e1);
    
    var t = (dot((triangle[temp.x] - r.origin), n)) / dot(r.direction, n);
    
    var objectHit = false;
    if ((t < r.tmax) & (t > r.tmin)) {
        var beta = dot(cross((triangle[temp.x]-r.origin), r.direction), e1)/dot(r.direction, n);
        var gamma = -dot(cross((triangle[temp.x]-r.origin), r.direction), e0)/dot(r.direction, n);
        objectHit = (beta >= 0) & (gamma >= 0) & ((beta + gamma) <= 1);
    }
    
    if (objectHit) {
        if ((*hit).dist > 0) {
            (*hit).dist = min((*hit).dist, t);
        }
        else {
            (*hit).dist = t;
        }
        (*hit).position = r.origin + t * r.direction;
        (*hit).normal = normalize(n);
    }
    return objectHit;
}

// Calculate shading (Lambertian)
fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f
{   
    var light = sample_directional_light();

    var ray = Ray((*hit).position, -light.direction, 0.0, light.dist);
    var temp = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0, 0, 0, 0);

    return ((*hit).diffuseColor/Pi) * 1 * light.L_i * dot(-light.direction, (*hit).normal);
}

// Fragment Shader: Main entry point
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f
{
    const bgcolor = vec4f(0.1, 0.3, 0.6, 1.0);
    const max_depth = 10;
    var result = vec3f(0.0);
    
    // Sub-pixel jitter loop
    for (var j = 0u; j < u32(uniforms.jitterSub*uniforms.jitterSub); j++) 
    {
        let uv = vec2f(coords.x*uniforms.aspect*0.5f, coords.y*0.5f);
        var r = get_camera_ray(uv+jitter[j]);
        var hit = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0, 0, 0, 0);

        // Ray bounce loop
        for(var i = 0; i < max_depth; i++) 
        {
            if(intersect_scene(&r, &hit)) { 
                result += shade(&r, &hit);
            }
            else { 
                result += bgcolor.rgb;
                break; 
            }

            if(hit.has_hit) { break; }
        }
    }
    result /= uniforms.jitterSub*uniforms.jitterSub;
    return vec4f(pow(result, vec3f(0.66)), bgcolor.a);
}