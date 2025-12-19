struct Uniforms {
  aspect: f32,
  cam_const: f32,
  gamma: f32,
  _pad: f32, 
};

@group(0) @binding(0) var<uniform> U: Uniforms;

const PI = 3.14159265359;

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

// ------------------ Structs ------------------
struct Ray {
  origin: vec3f,
  direction: vec3f,
  tmin: f32,
  tmax: f32,
};

struct HitInfo {
  has_hit: bool,
  dist: f32,
  position: vec3f,
  normal: vec3f,
  color: vec3f,
};

struct Light {
  Li: vec3f,
  omega: vec3f,
  dist: f32,
};

// ------------------ Camera ------------------
fn get_camera_ray(coords: vec2f) -> Ray {
  let eye = vec3f(2.0, 1.5, 2.0);
  let p   = vec3f(0.0, 0.5, 0.0);
  let up  = vec3f(0.0, 1.0, 0.0);

  // Apply aspect ratio correction here in shader (as per previous parts)
  // coords.x comes in as [-1, 1], so we scale it.
  let ip = vec2f(coords.x * U.aspect * 0.5, coords.y * 0.5);

  let v  = normalize(p - eye);
  let b1 = normalize(cross(v, up));
  let b2 = cross(b1, v);

  // Use the uniform cam_const for zoom
  let dir = normalize(ip.x * b1 + ip.y * b2 + U.cam_const * v);

  return Ray(eye, dir, 0.001, 100.0);
}

// ------------------ Intersections ------------------

fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p0: vec3f, n: vec3f, col: vec3f) -> bool {
  let denom = dot(r.direction, n);
  if (abs(denom) > 1e-8) {
    let t = dot(p0 - r.origin, n) / denom;
    if (t >= r.tmin && t <= r.tmax) {
      let pos = r.origin + t * r.direction;
      *hit = HitInfo(true, t, pos, normalize(n), col);
      return true;
    }
  }
  return false;
}

fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, c: vec3f, radius: f32, col: vec3f) -> bool {
  let oc = r.origin - c;
  let b  = dot(oc, r.direction);
  let cc = dot(oc, oc) - radius * radius;
  let disc = b * b - cc;

  if (disc >= 0.0) {
    let t = -b - sqrt(disc);
    if (t >= r.tmin && t <= r.tmax) {
      let pos = r.origin + t * r.direction;
      *hit = HitInfo(true, t, pos, normalize(pos - c), col);
      return true;
    }
  }
  return false;
}

fn intersect_triangle(r: Ray, hit: ptr<function, HitInfo>, v0: vec3f, v1: vec3f, v2: vec3f, col: vec3f) -> bool {
  let e1 = v1 - v0;
  let e2 = v2 - v0;
  let h  = cross(r.direction, e2);
  let a  = dot(e1, h);

  if (abs(a) < 1e-8) { return false; }

  let f = 1.0 / a;
  let s = r.origin - v0;
  let u = f * dot(s, h);

  if (u < 0.0 || u > 1.0) { return false; }

  let q = cross(s, e1);
  let v = f * dot(r.direction, q);

  if (v < 0.0 || u + v > 1.0) { return false; }

  let t = f * dot(e2, q);
  if (t >= r.tmin && t <= r.tmax) {
    let pos = r.origin + t * r.direction;
    let n = normalize(cross(e1, e2));
    *hit = HitInfo(true, t, pos, n, col);
    return true;
  }
  return false;
}

fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
  (*hit).has_hit = false;

  // Plane (y=0)
  if (intersect_plane(*r, hit, vec3f(0.0), vec3f(0.0, 1.0, 0.0), vec3f(0.1, 0.7, 0.0))) {
    (*r).tmax = (*hit).dist;
  }

  // Triangle
  if (intersect_triangle(*r, hit, 
        vec3f(-0.2, 0.1,  0.9),
        vec3f( 0.2, 0.1,  0.9),
        vec3f(-0.2, 0.1, -0.1),
        vec3f(0.4, 0.3, 0.2))) {
    (*r).tmax = (*hit).dist;
  }

  // Sphere (Black)
  if (intersect_sphere(*r, hit, vec3f(0.0, 0.5, 0.0), 0.3, vec3f(0.0, 0.0, 0.0))) {
    (*r).tmax = (*hit).dist;
  }

  return (*hit).has_hit;
}

// ------------------ Lighting ------------------

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

fn shade_diffuse(hit: HitInfo) -> vec3f {
  let L = sample_point_light(hit.position);
  let cos_theta = max(0.0, dot(hit.normal, L.omega));
  return hit.color * L.Li * cos_theta; 
}

@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let bg_color = vec3f(0.1, 0.3, 0.6);
  var r = get_camera_ray(coords);
  var hit = HitInfo(false, 0.0, vec3f(0.0), vec3f(0.0), vec3f(0.0));
  var Lo = bg_color;

  if (intersect_scene(&r, &hit)) {
    Lo = shade_diffuse(hit);
  }

  // Apply gamma correction using uniform
  Lo = pow(Lo, vec3f(1.0 / U.gamma));

  return vec4f(Lo, 1.0);
}