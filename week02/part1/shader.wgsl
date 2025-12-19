// Uniforms
struct Uniforms {
  aspect: f32,
  cam_const: f32,
  gamma: f32,
  _pad: f32,
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

// Ray definition
struct Ray {
  origin: vec3f,
  direction: vec3f,
  tmin: f32,
  tmax: f32,
};

// Hit information with material
struct HitInfo {
  has_hit: bool,
  dist: f32,
  position: vec3f,
  normal: vec3f,
  
  rho_a: vec3f,
  rho_d: vec3f,
  rho_s: vec3f,
  shininess: f32,
  
  shader: u32,
};

// Light structure
struct Light {
  Li: vec3f,
  omega: vec3f,
  dist: f32,
};

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

  return Ray(eye, dir, 0.001, 1e32);
}

// Initialize hit info
fn init_hit() -> HitInfo {
  return HitInfo(false, 1e32, vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), vec3f(0.0), 0.0, 0u);
}

// Plane intersection
fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p0: vec3f, n: vec3f) {
  let denom = dot(r.direction, n);
  if (abs(denom) > 1e-8) {
    let t = dot(p0 - r.origin, n) / denom;
    if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
      (*hit).has_hit = true;
      (*hit).dist = t;
      (*hit).position = r.origin + t * r.direction;
      (*hit).normal = normalize(n);
    }
  }
}

// Sphere intersection
fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, c: vec3f, radius: f32) {
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
    }
  }
}

// Triangle intersection
fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, v0: vec3f, v1: vec3f, v2: vec3f) {
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
  }
}

// Scene intersection
fn intersect_scene(r: Ray) -> HitInfo {
  var h = init_hit();

  var h_temp = h;
  intersect_plane(r, &h_temp, vec3f(0.0), vec3f(0.0, 1.0, 0.0));
  if (h_temp.has_hit && h_temp.dist < h.dist) {
    h = h_temp;
    let base = vec3f(0.1, 0.7, 0.0);
    h.rho_a = base * 0.1;
    h.rho_d = base * 0.9;
    h.rho_s = vec3f(0.0);
    h.shininess = 0.0;
    h.shader = 1u;
  }

  h_temp = h;
  intersect_triangle(r, &h_temp, 
        vec3f(-0.2, 0.1,  0.9),
        vec3f( 0.2, 0.1,  0.9),
        vec3f(-0.2, 0.1, -0.1));
  if (h_temp.has_hit && h_temp.dist < h.dist) {
    h = h_temp;
    let base = vec3f(0.4, 0.3, 0.2);
    h.rho_a = base * 0.1;
    h.rho_d = base * 0.9;
    h.rho_s = vec3f(0.0);
    h.shininess = 0.0;
    h.shader = 1u;
  }

  h_temp = h;
  intersect_sphere(r, &h_temp, vec3f(0.0, 0.5, 0.0), 0.3);
  if (h_temp.has_hit && h_temp.dist < h.dist) {
    h = h_temp;
    let base = vec3f(0.0);
    h.rho_a = base * 0.1;
    h.rho_d = base * 0.9;
    h.rho_s = vec3f(0.1);
    h.shininess = 42.0;
    h.shader = 1u;
  }

  return h;
}

// Check occlusion
fn is_occluded(r: Ray) -> bool {
  var h = init_hit();
  
  intersect_plane(r, &h, vec3f(0.0), vec3f(0.0, 1.0, 0.0));
  if (h.has_hit) { return true; }

  intersect_triangle(r, &h, 
      vec3f(-0.2, 0.1,  0.9),
      vec3f( 0.2, 0.1,  0.9),
      vec3f(-0.2, 0.1, -0.1));
  if (h.has_hit) { return true; }

  intersect_sphere(r, &h, vec3f(0.0, 0.5, 0.0), 0.3);
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
  let omega = L_vec / dist;

  let Li = intensity / max(dist_sq, 1e-4);

  return Light(Li, omega, dist);
}

// Compute diffuse shading
fn shade_diffuse(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  let light = sample_point_light((*hit).position);
  
  var Lo = (*hit).rho_a;

  let shadow_origin = (*hit).position + (*hit).normal * EPS;
  let shadow_dir = light.omega;
  let shadow_ray = Ray(shadow_origin, shadow_dir, EPS, light.dist - EPS);

  if (!is_occluded(shadow_ray)) {
    let cos_theta = max(0.0, dot((*hit).normal, light.omega));
    Lo += ((*hit).rho_d / PI) * light.Li * cos_theta;
  }

  return Lo;
}

// Shader dispatch
fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> vec3f {
  switch ((*hit).shader) {
    case 1u: { return shade_diffuse(r, hit); }
    default: { return (*hit).rho_a; }
  }
}

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let bg_color = vec3f(0.1, 0.3, 0.6);
  var r = get_camera_ray(coords);
  
  var hit = intersect_scene(r);
  var Lo = bg_color;

  if (hit.has_hit) {
    Lo = shade(&r, &hit);
  }

  Lo = pow(Lo, vec3f(1.0 / U.gamma));

  return vec4f(Lo, 1.0);
}