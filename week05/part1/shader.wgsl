// Bindings
@group(0) @binding(0) var<uniform> uniforms_f: Uniforms_f;
@group(0) @binding(1) var my_sampler: sampler;
@group(0) @binding(2) var my_texture: texture_2d<f32>;
@group(0) @binding(3) var<storage> jitter: array<vec2f>;
@group(0) @binding(4) var<storage> vPositions: array<vec3f>;
@group(0) @binding(5) var<storage> meshFaces: array<vec3u>; 

struct Uniforms_f {
    aspect: f32,
    cam_const: f32,
    sphere_material: f32,
    material: f32,
    jittersub: f32,
    scalingfactor: f32
};

struct Ray {
    origin: vec3f,
    direction: vec3f,
    tmin: f32,
    tmax: f32
};

struct HitInfo {
    has_hit: bool,
    dist: f32,
    position: vec3f,
    normal: vec3f,
    diffusecolor: vec3f,
    ambientcolor: vec3f,
    shader: f32,
    IoR: f32,
    texcoords: vec2f,
    use_texture: bool
};

struct Light {
    L_i: vec3f,
    w_i: vec3f,
    dist: f32
};

struct VSOut {
    @builtin(position) position: vec4f,
    @location(0) coords: vec2f,
};

// Orthonormal basis
struct Onb {
    normal: vec3f,
    tangent: vec3f,
    binormal: vec3f,
}

// Light sampling
fn sample_point_light(pos: vec3f) -> Light {
    var l = l_pos - pos;
    var L_i = vec3f(Pi)/ dot(l, l);
 
    let w_i = normalize(l);
    let dist = length(l);
    return Light(L_i, w_i, dist);
};

// Scene intersection
fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
    const planePosition = vec3f(0);
    const planeNormal = vec3f(0,1,0);
    const planeRGB = vec3f(0.1,0.7,0.0);
    const planeONB = Onb(vec3f(0,1,0), vec3f(-1.0, 0.0, 0.0), vec3f(0.0, 0.0, 1.0));

    const v0 = vec3f(-0.2,0.1,0.9);
    const v1 = vec3f(0.2,0.1,0.9);
    const v2 = vec3f(-0.2, 0.1, -0.1);
    const triangleRGB = vec3f(0.4,0.3,0.2);

    const sphereposition = vec3f(0.0,0.5,0.0);
    const sphereRadius = 0.3;
    const sphereRGB = vec3f(0,0,0);
    
    if (intersect_plane(*r, hit, planePosition, planeONB))
    {
        (*r).tmax = min((*hit).dist, (*r).tmax);
        (*hit).has_hit = true;
        (*hit).shader = uniforms_f.material;
        if ((*r).tmax == (*hit).dist) {
            (*hit).diffusecolor = planeRGB*0.9;
            (*hit).ambientcolor = planeRGB*0.1;
            (*hit).use_texture = true;
        }
    }
    if (intersect_triangle(*r, hit, meshFaces[0]))
    {
        (*r).tmax = min((*hit).dist, (*r).tmax);
        (*hit).has_hit = true;
        (*hit).shader = uniforms_f.material;
        if ((*r).tmax == (*hit).dist) 
        {
            (*hit).normal = normalize(cross(v1 - v0, v2 - v0));
            (*hit).diffusecolor = triangleRGB*0.9;
            (*hit).ambientcolor = triangleRGB*0.1;
            (*hit).use_texture = false;
        }
    }
    if (intersect_sphere(*r, hit, sphereposition, sphereRadius)) {
            (*r).tmax = min((*hit).dist, (*r).tmax);
            (*hit).has_hit = true;
            (*hit).shader = uniforms_f.sphere_material;
            if ((*r).tmax == (*hit).dist) {
                (*hit).diffusecolor = sphereRGB*0.9;
                (*hit).ambientcolor = sphereRGB*0.1;
                (*hit).use_texture = false;
            }
        }

    return (*hit).has_hit;
}

// Plane intersection
fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p: vec3f, onb: Onb) -> bool {
    let denom = dot(r.direction, onb.normal);
    var t = dot(p - r.origin, onb.normal) / denom;

    var objectHit = (t< r.tmax) & (t > r.tmin);

    if (objectHit) {
        if (abs(denom) > 0) {
            if ((*hit).dist > 0)
            {
                (*hit).dist = min((*hit).dist, t);
            }
            else {(*hit).dist = t;}
            (*hit).position = r.origin + t * r.direction;
            (*hit).normal = onb.normal;
            (*hit).texcoords = uniforms_f.scalingfactor * vec2f(dot((*hit).position - p, onb.tangent), dot((*hit).position - p, onb.binormal));
            
        }
    }
    return objectHit;
}

// Triangle intersection
fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, index: vec3u) -> bool {
    var e0 = vPositions[index.y] - vPositions[index.x];
    var e1 = vPositions[index.z] - vPositions[index.x];
    var n = cross(e0, e1);

    var t = (dot((vPositions[index.x] - r.origin), n)) / dot(r.direction, n);

    var objectHit = false;
    if ((t < r.tmax) & (t > r.tmin)) {
        var beta = dot(cross((vPositions[index.x]-r.origin), r.direction), e1)/dot(r.direction, n);
        var gamma = -dot(cross((vPositions[index.x]-r.origin), r.direction), e0)/dot(r.direction, n);
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
        (*hit).normal = n;
    }
    return objectHit;
}

// Sphere intersection
fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, position: vec3f, radius: f32) -> bool {
    var e = r.origin;
    var d = r.direction;
    var disc = (dot(d, (e - position)) * dot(d, (e - position))) - dot(d, d) * (dot((e - position), (e - position)) - (radius*radius));
    var objectHit = (disc >= 0);
    var t1 = dot(-d, (e - position)) - sqrt(disc) / dot(d, d);
    var t2 = dot(-d, (e - position)) + sqrt(disc) / dot(d, d);
    if (t1 < r.tmax && t1 > r.tmin) {
        if ((*hit).dist > 0) {
            (*hit).dist = min((*hit).dist, t1);
        }
        else {
            (*hit).dist = t1;
        }
        (*hit).position = r.origin + t1 * r.direction;
        (*hit).normal = normalize((*hit).position - position);
    }
    else if (t2 < r.tmax && t2 > r.tmin) {
        if ((*hit).dist > 0) {
            (*hit).dist = min((*hit).dist, t2);
        }
        else {
            (*hit).dist = t2;
        }
        (*hit).position = r.origin + t2 * r.direction;
        (*hit).normal = normalize((*hit).position - position);
    }
    else {
        objectHit = false;
    }
    
    return objectHit;
}

// Lambertian shading
fn lambertian(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    var light = sample_point_light((*hit).position);
    var ray = Ray(l_pos, -light.w_i, 0.0, light.dist-0.01);
    var temp = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0, 1, vec2f(0.0), false);

    if (intersect_scene(&ray, &temp)) 
    {
        return vec3f(0.0);
    }
    else 
    {
        return ((*hit).diffusecolor/Pi) * light.L_i * (max(0, dot((*hit).normal, light.w_i)));
    }
}

// Mirror reflection
fn mirror(r: ptr<function, Ray>, hit: ptr<function,HitInfo>) -> vec3f {
    (*r).direction = 2*(-dot((*r).direction, (*hit).normal))*(*hit).normal + (*r).direction;
    (*r).origin = (*hit).position;
    (*r).tmin = 0.0001;

    (*hit).has_hit = false;
    return vec3f(0,0,0);
}

// Refraction/Fresnel
fn refrection(r:ptr<function, Ray>, hit: ptr<function,HitInfo>) -> vec3f {
    if (dot((*r).direction, (*hit).normal) < 0) {
        (*hit).IoR = 1.0/sphereIR;
    }
    else {
        (*hit).IoR = sphereIR;
        (*hit).normal = -(*hit).normal;
    }
    
    var cosSqTheta = 1 - (*hit).IoR * (*hit).IoR * (1 - dot((*r).direction, (*hit).normal) * dot((*r).direction, (*hit).normal));

    if (cosSqTheta < 0) {
        return mirror(r,hit);
    }
    else {
        (*r).direction = (*hit).IoR * (dot(-(*r).direction, (*hit).normal) * (*hit).normal + (*r).direction) - (*hit).normal * sqrt(cosSqTheta);
        (*hit).has_hit = false;
        (*r).origin = (*hit).position;
        (*r).tmin = 0.0001;
        (*r).tmax = 1.0e32;
        return vec3f(0,0,0);
    }
}

// Phong shading
fn phong(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
    var light = sample_point_light((*hit).position);
    var Lr = ((*hit).diffusecolor/Pi + specualarReflectance * (sphereShininess + 2)/
    (2*Pi) * pow(max(0, dot(-(*r).direction, reflect(-light.w_i, (*hit).normal))), sphereShininess)) *
    light.L_i * max(0, dot(light.w_i, (*hit).normal));

    return Lr;
}

// Shading dispatcher
fn shade(r: ptr<function, Ray>, hit: ptr<function,HitInfo>) -> vec3f {
    switch i32((*hit).shader) {
        case 1 {return (lambertian(r,hit) + (*hit).ambientcolor);}
        case 2 {return mirror(r,hit);}
        case 3 {return refrection(r,hit);}
        case 4 {return phong(r,hit);}
        case 5{ return phong(r,hit) + refrection(r,hit);}
        case 6{ return phong(r,hit) + mirror(r,hit);}
        case default { return (*hit).ambientcolor + (*hit).diffusecolor; }
    }
}

// Camera ray generation
fn get_camera_ray(ipcoords: vec2f) -> Ray {
    const eye = vec3f(2.0, 1.5, 2.0);
    const p = vec3f(0.0, 0.5, 0.0);
    const up = vec3f(0.0, 1.0, 0.0);
    const d = 1.0;
    
    let v = normalize(p-eye);
    let b1 = normalize(cross(v,up));
    let b2 = cross(b1,v);
    const origin = eye;
    let direction = normalize(ipcoords.x*b1+ipcoords.y*b2+v*uniforms_f.cam_const);
    
    return Ray(origin, direction, 0.0, 1.0e32);
}

// Nearest-neighbor sampling
fn texture_nearest(texture: texture_2d<f32>, texcoords: vec2f, repeat: bool) -> vec3f {
    let res = textureDimensions(texture);
    let st = select(clamp(texcoords, vec2f(0), vec2f(1)), texcoords - floor(texcoords), repeat);
    let ab = st*vec2f(res);       
    let UV = vec2u(ab + 0.5) % res;      
    let texcolor = textureLoad(texture, UV, 0);      
    return texcolor.rgb;     
}    

// Bilinear sampling
fn texture_linear(texture: texture_2d<f32>, texcoords: vec2f, repeat: bool) -> vec3f {
    let res = textureDimensions(texture);
    let st = select(clamp(texcoords, vec2f(0), vec2f(1)), texcoords - floor(texcoords), repeat);
    let ab = st * vec2f(res) - 0.5;
    let iuv = vec2i(floor(ab));
    let fuv = fract(ab);
    
    let uv00 = (iuv + vec2i(0, 0)) % vec2i(res);
    let uv10 = (iuv + vec2i(1, 0)) % vec2i(res);
    let uv01 = (iuv + vec2i(0, 1)) % vec2i(res);
    let uv11 = (iuv + vec2i(1, 1)) % vec2i(res);
    
    let c00 = textureLoad(texture, uv00, 0).rgb;
    let c10 = textureLoad(texture, uv10, 0).rgb;
    let c01 = textureLoad(texture, uv01, 0).rgb;
    let c11 = textureLoad(texture, uv11, 0).rgb;
    
    let texcolor = mix(mix(c00, c10, fuv.x), mix(c01, c11, fuv.x), fuv.y);

    return texcolor.rgb;      
}

// Constants
const l_pos = vec3f(0,1,0);
const sphereIR = 1.5;
const sphereShininess = 42;
const specualarReflectance = 0.1;
const Pi = 3.1415;

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
    
    const bgcolor = vec4f(0.1, 0.3, 0.6, 1.0);
    const max_depth = 10;
    var result = vec3f(0.0);

    for (var j = 0u; j< u32(uniforms_f.jittersub * uniforms_f.jittersub); j++)
    {
        let uv = vec2f(coords.x * uniforms_f.aspect * 0.5f, coords.y * 0.5f);
        var r = get_camera_ray(uv + jitter[j]);
        var textured = vec3f(0.0);
        var hit = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0),0, 1, vec2f(0.0),false);

        for (var i = 0; i < max_depth; i++) {
            if (intersect_scene(&r, &hit)) {
                if (hit.use_texture) { textured += shade(&r, &hit); }
                else {result += shade(&r, &hit);}
            } 
            else {
                if (hit.use_texture) {textured += bgcolor.rgb;}
                else {result += bgcolor.rgb;}
                break;
            }
            if (hit.has_hit) {break;}
        }

        let texColor = textureSample(my_texture, my_sampler, hit.texcoords).rgb;
        result += textured * texColor;
    }
    result /= uniforms_f.jittersub * uniforms_f.jittersub;
    return vec4f(pow(result, vec3f(1.0)), bgcolor.a);
} 

// Vertex Shader
@vertex
fn main_vs(@builtin(vertex_index) VertexIndex : u32) -> VSOut
{
    const pos = array<vec2f, 4>(vec2f(-1.0, 1.0), vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(1.0, -1.0));
    var vsOut: VSOut;
    vsOut.position = vec4f(pos[VertexIndex], 0.0, 1.0);
    vsOut.coords = pos[VertexIndex];
    return vsOut;
}