// Uniforms
struct Uniforms {
  aspect: f32,
  cam_const: f32,
  sphere_shader: f32,
  matt_shader: f32,
};
@group(0) @binding(0) var<uniform> U: Uniforms;

const PI: f32 = 3.14159265359;
const EPS: f32 = 1e-4;

// Vertex output
struct VSOut {
  @builtin(position) position: vec4f,
  @location(0) coords: vec2f,
};

@vertex
fn main_vs(@builtin(vertex_index) vid: u32) -> VSOut {
  let pos = array<vec2f, 4>(
    vec2f(-1.0,  1.0),
    vec2f(-1.0, -1.0),
    vec2f( 1.0,  1.0),
    vec2f( 1.0, -1.0)
  );
  var out: VSOut;
  out.position = vec4f(pos[vid], 0.0, 1.0);
  out.coords   = pos[vid];
  return out;
}

// Ray with index of refraction
struct Ray {
  origin: vec3f,
  direction: vec3f,
  tmin: f32,
  tmax: f32,
  ior: f32,
};

// Hit information with refraction
struct HitInfo {
  has_hit: bool,
  dist: f32,
  position: vec3f,
  normal: vec3f,
  
  rho_a: vec3f,
  rho_d: vec3f,
  shader: u32,
  
  eta: f32,
  
  continue_ray: bool,
};

// Light structure
struct Light {
  Li: vec3f,
  omega: vec3f,
  dist: f32,
};

// Initialize hit info
fn init_hit(r: Ray) -> HitInfo {
  return HitInfo(false, r.tmax, vec3f(0), vec3f(0), vec3f(0), vec3f(0), 0u, 1.0, false);
}

// Plane intersection
fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p0: vec3f, n: vec3f, shader_id: u32, base_col: vec3f) {
  let denom = dot(r.direction, n);
  if (abs(denom) > 1e-8) {
    let t = dot(p0 - r.origin, n) / denom;
    if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
      (*hit).has_hit = true;
      (*hit).dist = t;
      (*hit).position = r.origin + t * r.direction;
      (*hit).normal = normalize(n);
      (*hit).rho_a = base_col * 0.1;
      (*hit).rho_d = base_col * 0.9;
      (*hit).shader = shader_id;
    }
  }
}

// Sphere intersection
fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, c: vec3f, radius: f32, shader_id: u32, base_col: vec3f) {
  let oc = r.origin - c;
  let b  = dot(oc, r.direction);
  let cc = dot(oc, oc) - radius * radius;
  let disc = b * b - cc;

  if (disc >= 0.0) {
    let t = -b - sqrt(disc);
    if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
      (*hit).has_hit = true;
      (*hit).dist = t;
      (*hit).position = r.origin + t * r.direction;
      (*hit).normal = normalize((*hit).position - c);
      (*hit).rho_a = base_col * 0.1;
      (*hit).rho_d = base_col * 0.9;
      (*hit).shader = shader_id;
    }
  }
}

// Triangle intersection
fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, v0: vec3f, v1: vec3f, v2: vec3f, shader_id: u32, base_col: vec3f) {
  let e1 = v1 - v0;
  let e2 = v2 - v0;
  let h  = cross(r.direction, e2);
  let a  = dot(e1, h);

  if (abs(a) < 1e-8) { return; }
  let f = 1.0 / a;
  let s = r.origin - v0;
  let u = f * dot(s, h);
  if (u < 0.0 || u > 1.0) { return; }
  let q = cross(s, e1);
  let v = f * dot(r.direction, q);
  if (v < 0.0 || u + v > 1.0) { return; }

  let t = f * dot(e2, q);
  if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
    (*hit).has_hit = true;
    (*hit).dist = t;
    (*hit).position = r.origin + t * r.direction;
    (*hit).normal = normalize(cross(e1, e2));
    (*hit).rho_a = base_col * 0.1;
    (*hit).rho_d = base_col * 0.9;
    (*hit).shader = shader_id;
  }
}

// Scene intersection
fn intersect_scene(r: Ray) -> HitInfo {
  var h = init_hit(r);
  
  let matt_id = u32(U.matt_shader);
  let sphere_id = u32(U.sphere_shader);

  intersect_plane(r, &h, vec3f(0.0), vec3f(0.0, 1.0, 0.0), matt_id, vec3f(0.1, 0.7, 0.0));
  
  intersect_triangle(r, &h, 
    vec3f(-0.2, 0.1,  0.9),
    vec3f( 0.2, 0.1,  0.9),
    vec3f(-0.2, 0.1, -0.1),
    matt_id, vec3f(0.4, 0.3, 0.2));

  intersect_sphere(r, &h, vec3f(0.0, 0.5, 0.0), 0.3, sphere_id, vec3f(0.2, 0.2, 0.2));

  return h;
}

// Check occlusion
fn is_occluded(r: Ray) -> bool {
  var h = init_hit(r);
  intersect_plane(r, &h, vec3f(0.0), vec3f(0.0, 1.0, 0.0), 0u, vec3f(0.0));
  if (h.has_hit) { return true; }
  
  intersect_triangle(r, &h, 
    vec3f(-0.2, 0.1,  0.9),
    vec3f( 0.2, 0.1,  0.9),
    vec3f(-0.2, 0.1, -0.1), 0u, vec3f(0.0));
  if (h.has_hit) { return true; }

  intersect_sphere(r, &h, vec3f(0.0, 0.5, 0.0), 0.3, 0u, vec3f(0.0));
  if (h.has_hit) { return true; }
  
  return false;
}

// Sample point light
fn sample_point_light(pos: vec3f) -> Light {
  let light_pos = vec3f(0.0, 1.0, 0.0);
  let intensity = vec3f(PI); 
  let L_vec = light_pos - pos;
  let dist_sq = dot(L_vec, L_vec);
  let dist = sqrt(dist_sq);
  return Light(intensity / max(dist_sq, 1e-4), L_vec / dist, dist);
}

// Base color shader
fn shade_base(hit: HitInfo) -> vec3f {
  return hit.rho_a + hit.rho_d;
}

// Lambertian shader
fn shade_lambert(hit: HitInfo) -> vec3f {
  let L = sample_point_light(hit.position);
  var Lo = hit.rho_a;

  let shadow_origin = hit.position + hit.normal * EPS;
  let shadow_ray = Ray(shadow_origin, L.omega, EPS, L.dist - EPS, 1.0);

  if (!is_occluded(shadow_ray)) {
    let cos_theta = max(0.0, dot(hit.normal, L.omega));
    Lo += (hit.rho_d / PI) * L.Li * cos_theta;
  }
  return Lo;
}

// Mirror shader
fn shade_mirror(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  (*r).origin = hit.position + hit.normal * EPS;
  (*r).direction = reflect((*r).direction, hit.normal);
  (*r).tmin = EPS;
  (*r).tmax = 1e32;
  (*hit).continue_ray = true;
  return vec3f(0.0);
}

// Refraction shader
fn shade_refract(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  let n_glass = 1.5;
  var N = normalize(hit.normal);
  
  var n1 = (*r).ior;
  var n2 = n_glass;
  
  if (dot((*r).direction, N) > 0.0) {
    N = -N;
    n2 = 1.0;
  }
  
  let eta = n1 / n2;
  (*hit).eta = eta;

  let cos_i = dot(-(*r).direction, N);
  let k_val = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
  
  if (k_val < 0.0) {
    (*r).direction = reflect((*r).direction, N);
  } else {
    (*r).direction = eta * (*r).direction + (eta * cos_i - sqrt(k_val)) * N;
    (*r).ior = n2;
  }

  (*r).origin = hit.position - N * EPS;
  (*r).tmin = EPS;
  (*r).tmax = 1e32;
  (*hit).continue_ray = true;
  
  return vec3f(0.0);
}

// Shader dispatch
fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  switch ((*hit).shader) {
    case 0u: { return shade_base(*hit); }
    case 1u: { return shade_lambert(*hit); }
    case 2u: { return shade_mirror(r, hit); }
    case 3u: { return shade_refract(r, hit); }
    default: { return vec3f(0.0); }
  }
}

// Compute camera ray
fn get_camera_ray(coords: vec2f) -> Ray {
  let eye = vec3f(2.0, 1.5, 2.0);
  let p   = vec3f(0.0, 0.5, 0.0);
  let up  = vec3f(0.0, 1.0, 0.0);
  
  let ip = vec2f(coords.x * U.aspect * 0.5, coords.y * 0.5);
  let v  = normalize(p - eye);
  let b1 = normalize(cross(v, up));
  let b2 = cross(b1, v);
  let dir = normalize(ip.x * b1 + ip.y * b2 + U.cam_const * v);

  return Ray(eye, dir, 0.001, 1e32, 1.0);
}

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let bg_color = vec3f(0.1, 0.3, 0.6);
  var r = get_camera_ray(coords);
  
  var final_color = vec3f(0.0);
  const MAX_BOUNCES = 8;
  
  for (var i = 0; i < MAX_BOUNCES; i++) {
    var hit = intersect_scene(r);
    
    if (!hit.has_hit) {
      final_color += bg_color;
      break;
    }
    
    let c = shade(&r, &hit);
    final_color += c;
    
    if (!hit.continue_ray) {
      break;
    }
  }

  final_color = pow(final_color, vec3f(1.0 / 2.2));
  return vec4f(final_color, 1.0);
}