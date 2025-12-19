// Bindings
@group(0) @binding(0) var<uniform> uniforms : Uniforms;
@group(0) @binding(1) var<storage> jitter: array<vec2f>; 
@group(0) @binding(2) var<storage> vbuffer: array<vec3f>; 
@group(0) @binding(3) var<storage> ibuffer: array<vec3u>; 
@group(0) @binding(4) var<storage> nbuffer: array<vec3f>;
@group(0) @binding(5) var<storage> mibuffer: array<u32>;    
@group(0) @binding(6) var<storage> mcbuffer: array<vec4f>;  
@group(0) @binding(7) var<storage> mebuffer: array<vec4f>;  
@group(0) @binding(8) var<storage> libuffer: array<u32>;    

// Constants
const Pi = 3.141592; 
const lightPosition = vec3f(0.0, 1.0, 0.0);
const epsilon = 0.0001;

// Structs
struct Uniforms {
    aspect: f32,
    camera_constant: f32,
    jitterSub: f32,
};

struct VSOut
{
    @builtin(position) position: vec4f,
    @location(0) coords : vec2f
};

struct Ray 
{
    origin: vec3f,
    direction: vec3f,
    tmin: f32,
    tmax: f32
};

struct Light
{
    L_i: vec3f,
    direction: vec3f,
    dist: f32
};

struct HitInfo
{
    has_hit: bool,
    dist: f32,
    position: vec3f,
    normal: vec3f,
    diffusecolor: vec3f,
    emission: vec3f,
};

// Fragment Shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f
{
    const bgcolor = vec4f(0.1, 0.3, 0.6, 1.0);
    const max_depth = 10;

    var result = vec3f(0.0);
    for (var j = 0u; j < u32(uniforms.jitterSub*uniforms.jitterSub); j++) 
    {
        let uv = vec2f(coords.x*uniforms.aspect*0.5f, coords.y*0.5f);
        var r = get_camera_ray(uv+jitter[j]);
        var hit = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0));

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

// Vertex Shader
@vertex
fn main_vs(@builtin(vertex_index) VertexIndex : u32) -> VSOut
{
    let unused = nbuffer[0];
    const pos = array<vec2f, 4>(vec2f(-1.0, 1.0), vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(1.0, -1.0));
    var vsOut: VSOut;
    vsOut.position = vec4f(pos[VertexIndex], 0.0, 1.0);
    vsOut.coords = pos[VertexIndex];
    return vsOut;
}


// Ray Generation
fn get_camera_ray(uv: vec2f) -> Ray
{
    const eye = vec3f(277.0, 275.0, -570.0);
    const point = vec3f(277.0, 275.0, 0.0);
    const up = vec3f(0.0, 1.0, 0.0);
    var d = uniforms.camera_constant;
    var v = normalize(point-eye);
    var b1 = normalize(cross(v, up));
    var b2 = cross(b1, v);
    var q = b1 * uv.x + b2 * uv.y + v * d;
    var omega = normalize(q);
    
    var ray = Ray(eye, omega, 0.0, 1.0e32);
    return ray;
}

// Lighting Functions
fn sample_point_light(pos: vec3f) -> Light
    {
        var lightIntensity = vec3f(0.0); 
        
        var lightPosition = vec3f(0.0);

        for (var i = 0; i < 2; i++) 
        {
            let temp = ibuffer[libuffer[i]];
            lightPosition += vbuffer[temp.x] + vbuffer[temp.y] + vbuffer[temp.z];
            lightIntensity += mebuffer[mibuffer[libuffer[i]]].rgb;
        }
        lightPosition /= 6.0;

        var l = (pos - lightPosition);
        
        var dist = length(l);

        var L_i = vec3f(0.0);
        var area = 0.0;
        var n = vec3f(0.0);
        
        for (var i = 0; i < 2; i++) 
        {
            let temp = ibuffer[libuffer[i]]; 
            var e0 = (vbuffer[temp.y] - vbuffer[temp.x]);
            var e1 = (vbuffer[temp.z] - vbuffer[temp.x]);
            n = cross(e0, e1);
            area += length(n)/2;
        }
        L_i = dot(normalize(l), normalize(n)) * lightIntensity * area;
        
        var light = Light(L_i, normalize(l), dist);
        return light;
    }

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


// Intersection Logic
fn intersect_scene(r: ptr<function, Ray>, hit : ptr<function, HitInfo>) -> bool
{
    for (var i = 0u; i < arrayLength(&ibuffer); i++) 
    {
        if (intersect_triangle(*r, hit, i)) {
            (*r).tmax = min((*hit).dist, (*r).tmax);
            (*hit).has_hit = true;
            if ((*r).tmax == (*hit).dist) {
                (*hit).diffusecolor = mcbuffer[mibuffer[i]].rgb;
                (*hit).emission = mebuffer[mibuffer[i]].rgb;
            }
        }
    }
    return (*hit).has_hit;
}

fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, index: u32) -> bool 
{
    let temp = ibuffer[index]; 
    var e0 = vbuffer[temp.y] - vbuffer[temp.x];
    var e1 = vbuffer[temp.z] - vbuffer[temp.x];
    var n = cross(e0, e1);
    
    var t = (dot((vbuffer[temp.x] - r.origin), n)) / dot(r.direction, n);
    
    var objectHit = false;
    if ((t < r.tmax) & (t > r.tmin)) {
        var beta = dot(cross((vbuffer[temp.x]-r.origin), r.direction), e1)/dot(r.direction, n);
        var gamma = -dot(cross((vbuffer[temp.x]-r.origin), r.direction), e0)/dot(r.direction, n);
        objectHit = (beta >= 0) & (gamma >= 0) & ((beta + gamma) <= 1);

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
    }
    
    return objectHit;
    
}

// Shading Logic
fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f
    {       
        var light = sample_point_light((*hit).position);

        var ray = Ray((*hit).position, -light.direction, 10, light.dist-100);
        var temp = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0));
        var result = (*hit).emission;
        if (intersect_scene(&ray, &temp)) { return (vec3f(0.0)); }
        else {
            result += ((*hit).diffusecolor/Pi) * (1 / (light.dist*light.dist)) * dot(-light.direction, (*hit).normal) * light.L_i;
        }
        return result;
    }