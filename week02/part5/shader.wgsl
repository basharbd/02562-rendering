struct Uniforms {
  aspect: f32,
  cam_const: f32,
  sphere_shader: f32, 
  matt_shader: f32,   
};
@group(0) @binding(0) var<uniform> U: Uniforms;

const PI: f32 = 3.14159265359;
const EPS: f32 = 1e-4;

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
  rho_a: vec3f,
  rho_d: vec3f,
  rho_s: vec3f,
  shininess: f32,
  ior: f32,
  shader: u32,
  continue_ray: bool,
};

struct Light {
  Li: vec3f,
  omega: vec3f,
  dist: f32,
};

// Intersection helpers
fn hit_update(r: Ray, hit: ptr<function, HitInfo>, t: f32, p: vec3f, n: vec3f, 
              ra: vec3f, rd: vec3f, rs: vec3f, sh: f32, ior: f32, id: u32) {
  if (t >= r.tmin && t <= r.tmax && t < (*hit).dist) {
    (*hit).has_hit = true;
    (*hit).dist = t;
    (*hit).position = p;
    (*hit).normal = normalize(n);
    (*hit).rho_a = ra;
    (*hit).rho_d = rd;
    (*hit).rho_s = rs;
    (*hit).shininess = sh;
    (*hit).ior = ior;
    (*hit).shader = id;
    (*hit).continue_ray = false;
  }
}

fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p0: vec3f, n: vec3f, 
                   ra: vec3f, rd: vec3f, rs: vec3f, sh: f32, id: u32) {
  let denom = dot(r.direction, n);
  if (abs(denom) > 1e-8) {
    let t = dot(p0 - r.origin, n) / denom;
    hit_update(r, hit, t, r.origin + t * r.direction, n, ra, rd, rs, sh, 1.0, id);
  }
}

fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, v0: vec3f, v1: vec3f, v2: vec3f, 
                      ra: vec3f, rd: vec3f, rs: vec3f, sh: f32, id: u32) {
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
  hit_update(r, hit, t, r.origin + t * r.direction, cross(e1,e2), ra, rd, rs, sh, 1.0, id);
}

fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, c: vec3f, radius: f32, 
                    ra: vec3f, rd: vec3f, rs: vec3f, sh: f32, ior: f32, id: u32) {
  let oc = r.origin - c;
  let b  = dot(oc, r.direction);
  let cc = dot(oc, oc) - radius * radius;
  let disc = b * b - cc;

  if (disc >= 0.0) {
    let s = sqrt(disc);
    let t1 = -b - s;
    // Check closest valid t
    var t = t1;
    if (t < r.tmin) { t = -b + s; }
    
    hit_update(r, hit, t, r.origin + t * r.direction, (r.origin + t * r.direction) - c, ra, rd, rs, sh, ior, id);
  }
}

// Scene traversal
fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, light_pos_out: ptr<function, vec3f>) -> bool {
  *light_pos_out = vec3f(0.0, 1.0, 0.0);
  (*hit).has_hit = false;
  (*hit).dist = (*r).tmax;

  let matt_id = u32(U.matt_shader);
  let sphere_id = u32(U.sphere_shader);

  let plane_c = vec3f(0.1, 0.7, 0.0);
  let tri_c   = vec3f(0.4, 0.3, 0.2);
  let sph_c   = vec3f(0.0, 0.0, 0.0);
  let sph_s   = vec3f(0.1, 0.1, 0.1);
  let sph_shininess = 42.0;
  let sph_ior = 1.5;

  intersect_plane(*r, hit, vec3f(0.0), vec3f(0.0, 1.0, 0.0), 
                  plane_c * 0.1, plane_c * 0.9, vec3f(0.0), 0.0, matt_id);
  
  intersect_triangle(*r, hit, 
    vec3f(-0.2, 0.1,  0.9), vec3f( 0.2, 0.1,  0.9), vec3f(-0.2, 0.1, -0.1),
    tri_c * 0.1, tri_c * 0.9, vec3f(0.0), 0.0, matt_id);

  intersect_sphere(*r, hit, vec3f(0.0, 0.5, 0.0), 0.3, 
                   sph_c * 0.1, sph_c * 0.9, sph_s, sph_shininess, sph_ior, sphere_id);

  if ((*hit).has_hit) {
    (*r).tmax = (*hit).dist;
    return true;
  }
  return false;
}

// ------------------------------
// Occlusion Check (Fixed)
// ------------------------------

fn is_occluded(r: Ray) -> bool {
  var ray_temp = r;
  var h: HitInfo;
  h.dist = r.tmax;
  h.has_hit = false;
  h.continue_ray = false;
  var dummy_light: vec3f;
  if(intersect_scene(&ray_temp, &h, &dummy_light)) { 
    return true;
  }
  return false;
}

// Shading
fn sample_point_light(light_pos: vec3f, pos: vec3f) -> Light {
  let intensity = vec3f(PI); 
  let L_vec = light_pos - pos;
  let dist_sq = dot(L_vec, L_vec);
  let dist = sqrt(dist_sq);
  return Light(intensity / max(dist_sq, 1e-4), L_vec / dist, dist);
}

fn shade_base(hit: HitInfo) -> vec3f {
  return hit.rho_a + hit.rho_d;
}

fn shade_lambert(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, light_pos: vec3f) -> vec3f {
  let L = sample_point_light(light_pos, (*hit).position);
  var Lo = (*hit).rho_a;

  let shadow_ray = Ray((*hit).position + (*hit).normal * EPS, L.omega, EPS, L.dist - EPS, 1.0);
  if (!is_occluded(shadow_ray)) {
    let cos_theta = max(0.0, dot((*hit).normal, L.omega));
    Lo += ((*hit).rho_d / PI) * L.Li * cos_theta;
  }
  return Lo;
}

fn shade_phong(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, light_pos: vec3f) -> vec3f {
  let L = sample_point_light(light_pos, (*hit).position);
  var Lo = (*hit).rho_a;
  let shadow_ray = Ray((*hit).position + (*hit).normal * EPS, L.omega, EPS, L.dist - EPS, 1.0);
  if (!is_occluded(shadow_ray)) {
    let N = normalize((*hit).normal);
    let V = normalize(-(*r).direction);
    let cos_theta = max(0.0, dot(N, L.omega));
    Lo += ((*hit).rho_d / PI) * L.Li * cos_theta;
    let R = reflect(-L.omega, N);
    let r_dot_v = max(0.0, dot(R, V));
    let spec = (*hit).rho_s * L.Li * pow(r_dot_v, (*hit).shininess);
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
  var n2 = (*hit).ior; // From hit info (1.5)

  if (dot((*r).direction, N) > 0.0) {
    N = -N;
    n2 = 1.0;
  }
  
  let eta = n1 / n2;
  let cos_i = dot(-(*r).direction, N);
  let k_val = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
  
  if (k_val < 0.0) {
    (*r).direction = reflect((*r).direction, N);
  } else {
    (*r).direction = eta * (*r).direction + (eta * cos_i - sqrt(k_val)) * N;
    (*r).ior = n2;
  }

  (*r).origin = (*hit).position - N * EPS;
  (*r).tmin = EPS;
  (*r).tmax = 1e32;
  (*hit).continue_ray = true;
  return vec3f(0.0);
}

fn shade_glossy(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, light_pos: vec3f) -> vec3f {
  let highlight = shade_phong(r, hit, light_pos);
  let unused = shade_refract(r, hit);
  return highlight;
}

fn shade(r: ptr<function, Ray>, hit: ptr<function, HitInfo>, light_pos: vec3f) -> vec3f {
  switch ((*hit).shader) {
    case 0u: { return shade_base(*hit); }
    case 1u: { return shade_lambert(r, hit, light_pos); }
    case 2u: { return shade_phong(r, hit, light_pos); }
    case 3u: { return shade_mirror(r, hit); }
    case 4u: { return shade_refract(r, hit); }
    case 5u: { return shade_glossy(r, hit, light_pos); }
    default: { return vec3f(0.0); }
  }
}

// Main raytracing
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

@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let bg_color = vec3f(0.1, 0.3, 0.6);
  var r = get_camera_ray(coords);
  var final_color = vec3f(0.0);
  const MAX_BOUNCES = 8;
  for (var i = 0; i < MAX_BOUNCES; i++) {
    var hit: HitInfo;
    var light_pos: vec3f;
    if (!intersect_scene(&r, &hit, &light_pos)) {
      final_color += bg_color;
      break;
    }
    let c = shade(&r, &hit, light_pos);
    final_color += c;
    if (!hit.continue_ray) {
      break;
    }
  }
  // Gamma correction
  final_color = pow(final_color, vec3f(1.0 / 2.2));
  return vec4f(final_color, 1.0);
}