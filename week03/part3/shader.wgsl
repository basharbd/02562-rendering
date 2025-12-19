struct Uniforms_f {
  aspect: f32,
  cam_const: f32,
  sphere_mat: f32,
  plane_mat: f32,
  subdivs: f32,
};

struct Uniforms_ui {
  use_texture: u32,
};

@group(0) @binding(0) var<uniform> uf: Uniforms_f;
@group(0) @binding(1) var<uniform> uui: Uniforms_ui;
@group(0) @binding(2) var my_sampler: sampler;
@group(0) @binding(3) var my_texture: texture_2d<f32>;
@group(0) @binding(4) var<storage, read> jitter: array<vec2f>;

struct VSOut {
  @builtin(position) position: vec4f,
  @location(0) coords: vec2f,
};

@vertex
fn main_vs(@builtin(vertex_index) vid: u32) -> VSOut {
  let pos = array<vec2f, 4>(
    vec2f(-1.0, 1.0), vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(1.0, -1.0)
  );
  var out: VSOut;
  out.position = vec4f(pos[vid], 0.0, 1.0);
  out.coords = pos[vid];
  return out;
}

// Structs
struct Ray {
  origin: vec3f,
  direction: vec3f,
  tmin: f32,
  tmax: f32,
  ior: f32,
};

struct HitInfo {
  has_hit: bool,
  dist: f32,
  position: vec3f,
  normal: vec3f,
  diffuse: vec3f,
  ambient: vec3f,
  specular: vec3f,
  shininess: f32,
  ior: f32,
  shader: u32,
  continue_ray: bool,
};

struct Light {
  Li: vec3f,
  wi: vec3f,
  dist: f32,
};

struct Onb {
  tangent: vec3f,
  binormal: vec3f,
  normal: vec3f,
};

const PI = 3.14159265;
const EPS = 1e-3;

// Intersections
fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p0: vec3f, onb: Onb, use_tex: bool) {
  let denom = dot(r.direction, onb.normal);
  if (abs(denom) < 1e-8) { return; }
  
  let t = dot(p0 - r.origin, onb.normal) / denom;
  
  if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
    (*hit).has_hit = true;
    (*hit).dist = t;
    (*hit).position = r.origin + t * r.direction;
    (*hit).normal = normalize(onb.normal);
    
    // Texture mapping
    let plane_vec = (*hit).position - p0;
    let u = dot(plane_vec, onb.tangent);
    let v = dot(plane_vec, onb.binormal);
    let uv = vec2f(u, v) * 0.2;
    
    var base_color = vec3f(0.1, 0.7, 0.0);
    if (use_tex) {
      base_color = textureSampleLevel(my_texture, my_sampler, uv, 0.0).rgb;
    }
    
    (*hit).ambient = base_color * 0.1;
    (*hit).diffuse = base_color * 0.9;
    (*hit).specular = vec3f(0.0);
    (*hit).shininess = 0.0;
    (*hit).shader = u32(uf.plane_mat);
    (*hit).ior = 1.0;
  }
}

fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, v0: vec3f, v1: vec3f, v2: vec3f) {
  let e1 = v1 - v0;
  let e2 = v2 - v0;
  let pvec = cross(r.direction, e2);
  let det = dot(e1, pvec);
  if (abs(det) < 1e-8) { return; }
  let inv_det = 1.0 / det;
  let tvec = r.origin - v0;
  let u = dot(tvec, pvec) * inv_det;
  if (u < 0.0 || u > 1.0) { return; }
  let qvec = cross(tvec, e1);
  let v = dot(r.direction, qvec) * inv_det;
  if (v < 0.0 || u + v > 1.0) { return; }
  let t = dot(e2, qvec) * inv_det;

  if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
    (*hit).has_hit = true;
    (*hit).dist = t;
    (*hit).position = r.origin + t * r.direction;
    (*hit).normal = normalize(cross(e1, e2));
    
    let color = vec3f(0.4, 0.3, 0.2);
    (*hit).ambient = color * 0.1;
    (*hit).diffuse = color * 0.9;
    (*hit).specular = vec3f(0.0);
    (*hit).shader = 1u;
    (*hit).ior = 1.0;
  }
}

fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, c: vec3f, radius: f32, shader_id: u32) {
  let oc = r.origin - c;
  let b = dot(oc, r.direction);
  let cc = dot(oc, oc) - radius * radius;
  let disc = b * b - cc;
  if (disc >= 0.0) {
    let s = sqrt(disc);
    var t = -b - s;
    if (t < r.tmin) { t = -b + s; }
    
    if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
      (*hit).has_hit = true;
      (*hit).dist = t;
      (*hit).position = r.origin + t * r.direction;
      (*hit).normal = normalize((*hit).position - c);
      
      let color = vec3f(0.0);
      (*hit).ambient = color;
      (*hit).diffuse = color;
      (*hit).specular = vec3f(0.1);
      (*hit).shininess = 42.0;
      (*hit).ior = 1.5;
      (*hit).shader = shader_id;
    }
  }
}

fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
  (*hit).has_hit = false;
  (*hit).dist = (*r).tmax;

  let plane_onb = Onb(vec3f(-1.0, 0.0, 0.0), vec3f(0.0, 0.0, 1.0), vec3f(0.0, 1.0, 0.0));
  intersect_plane(*r, hit, vec3f(0.0), plane_onb, uui.use_texture != 0u);
  intersect_triangle(*r, hit, vec3f(-0.2, 0.1, 0.9), vec3f(0.2, 0.1, 0.9), vec3f(-0.2, 0.1, -0.1));
  intersect_sphere(*r, hit, vec3f(0.0, 0.5, 0.0), 0.3, u32(uf.sphere_mat));

  if ((*hit).has_hit) {
    (*r).tmax = (*hit).dist;
    return true;
  }
  return false;
}

fn is_occluded(r: Ray) -> bool {
  var temp_r = r;
  var temp_h: HitInfo;
  return intersect_scene(&temp_r, &temp_h);
}

// Shading
fn sample_light(pos: vec3f) -> Light {
  let light_pos = vec3f(0.0, 1.0, 0.0);
  let L = light_pos - pos;
  let d = length(L);
  let I = vec3f(PI); 
  return Light(I / (d*d), L/d, d);
}

fn shade_lambert(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  let L = sample_light((*hit).position);
  var Lo = (*hit).ambient;
  let shadow_ray = Ray((*hit).position + (*hit).normal * EPS, L.wi, EPS, L.dist - EPS, 1.0);
  if (!is_occluded(shadow_ray)) {
    let ndotl = max(dot((*hit).normal, L.wi), 0.0);
    Lo += ((*hit).diffuse / PI) * L.Li * ndotl;
  }
  return Lo;
}

fn shade_phong(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  let L = sample_light((*hit).position);
  var Lo = (*hit).ambient;
  let shadow_ray = Ray((*hit).position + (*hit).normal * EPS, L.wi, EPS, L.dist - EPS, 1.0);
  if (!is_occluded(shadow_ray)) {
    let N = normalize((*hit).normal);
    let V = normalize(-(*r).direction);
    let ndotl = max(dot(N, L.wi), 0.0);
    Lo += ((*hit).diffuse / PI) * L.Li * ndotl;
    
    let R = reflect(-L.wi, N);
    let spec = (*hit).specular * L.Li * pow(max(dot(R, V), 0.0), (*hit).shininess);
    Lo += spec;
  }
  return Lo;
}

fn shade_mirror(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  (*r).origin = (*hit).position + (*hit).normal * EPS;
  (*r).direction = reflect((*r).direction, (*hit).normal);
  (*r).tmin = EPS;
  (*r).tmax = 1e32;
  (*hit).continue_ray = true;
  return vec3f(0.0);
}

fn shade_refract(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  var N = normalize((*hit).normal);
  var n1 = (*r).ior;
  var n2 = (*hit).ior;
  if (dot((*r).direction, N) > 0.0) { N = -N; n2 = 1.0; }
  
  let eta = n1 / n2;
  let cos_i = dot(-(*r).direction, N);
  let k = 1.0 - eta*eta * (1.0 - cos_i*cos_i);
  
  if (k < 0.0) {
    (*r).direction = reflect((*r).direction, N);
  } else {
    (*r).direction = eta * (*r).direction + (eta * cos_i - sqrt(k)) * N;
    (*r).ior = n2;
  }
  (*r).origin = (*hit).position - N * EPS;
  (*r).tmin = EPS;
  (*r).tmax = 1e32;
  (*hit).continue_ray = true;
  return vec3f(0.0);
}

fn shade_glossy(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  let phong = shade_phong(r, hit);
  let unused = shade_refract(r, hit);
  return phong;
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  (*hit).continue_ray = false;
  switch((*hit).shader) {
    case 1u: { return shade_lambert(r, hit); }
    case 2u: { return shade_mirror(r, hit); }
    case 3u: { return shade_refract(r, hit); }
    case 4u: { return shade_phong(r, hit); }
    case 5u: { return shade_glossy(r, hit); }
    default: { return (*hit).diffuse; }
  }
}

// Main raytracing
fn get_camera_ray(coords: vec2f) -> Ray {
  let eye = vec3f(2.0, 1.5, 2.0);
  let at = vec3f(0.0, 0.5, 0.0);
  let up = vec3f(0.0, 1.0, 0.0);
  let v = normalize(at - eye);
  let b1 = normalize(cross(v, up));
  let b2 = cross(b1, v);
  let dir = normalize(coords.x * b1 + coords.y * b2 + uf.cam_const * v);
  return Ray(eye, dir, 0.001, 1e32, 1.0);
}

@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let uv_base = vec2f(coords.x * uf.aspect * 0.5, coords.y * 0.5);
  
  var accum_color = vec3f(0.0);
  let samples = u32(uf.subdivs * uf.subdivs);
  let bg = vec3f(0.1, 0.3, 0.6);

  for (var j = 0u; j < samples; j++) {
    let uv_jit = uv_base + jitter[j];
    var r = get_camera_ray(uv_jit);
    var sub_color = vec3f(0.0);

    for(var i=0; i<8; i++) {
      var hit: HitInfo;
      if (intersect_scene(&r, &hit)) {
        sub_color += shade(&r, &hit);
        if (!hit.continue_ray) { break; }
      } else {
        sub_color += bg;
        break;
      }
    }
    accum_color += sub_color;
  }

  let final_color = accum_color / f32(samples);
  return vec4f(pow(final_color, vec3f(1.0/2.2)), 1.0);
}