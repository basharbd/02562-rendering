// Uniforms
struct Uniforms {
  aspect: f32,
  cam_const: f32,
  _pad0: f32,
  _pad1: f32,
};
@group(0) @binding(0) var<uniform> U: Uniforms;

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

// Hit information
struct HitInfo {
  has_hit: bool,
  dist: f32,
  color: vec3f,
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
  return Ray(eye, dir, 0.001, 1000.0);
}

// Plane intersection
fn intersect_plane(r: Ray, hit: ptr<function, HitInfo>, p0: vec3f, n: vec3f, col: vec3f) -> bool {
  let denom = dot(r.direction, n);
  if (abs(denom) > 1e-8) {
    let t = dot(p0 - r.origin, n) / denom;
    if (t >= r.tmin && t <= r.tmax) {
      (*hit).has_hit = true;
      (*hit).dist = t;
      (*hit).color = col;
      return true;
    }
  }
  return false;
}

// Sphere intersection
fn intersect_sphere(r: Ray, hit: ptr<function, HitInfo>, c: vec3f, r_val: f32, col: vec3f) -> bool {
  let oc = r.origin - c;
  let b  = dot(oc, r.direction);
  let cc = dot(oc, oc) - r_val * r_val;
  let disc = b * b - cc;

  if (disc >= 0.0) {
    let t = -b - sqrt(disc);
    if (t >= r.tmin && t <= r.tmax) {
      (*hit).has_hit = true;
      (*hit).dist = t;
      (*hit).color = col;
      return true;
    }
  }
  return false;
}

// Triangle intersection
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
    (*hit).has_hit = true;
    (*hit).dist = t;
    (*hit).color = col;
    return true;
  }
  return false;
}

// Intersect scene objects
fn intersect_scene(r: ptr<function, Ray>, hit: ptr<function, HitInfo>) -> bool {
  (*hit).has_hit = false;

  if (intersect_plane(*r, hit, vec3f(0.0, 0.0, 0.0), vec3f(0.0, 1.0, 0.0), vec3f(0.1, 0.7, 0.0))) {
    (*r).tmax = (*hit).dist;
  }

  if (intersect_triangle(*r, hit, 
        vec3f(-0.2, 0.1,  0.9),
        vec3f( 0.2, 0.1,  0.9),
        vec3f(-0.2, 0.1, -0.1),
        vec3f(0.4, 0.3, 0.2))) {
    (*r).tmax = (*hit).dist;
  }

  if (intersect_sphere(*r, hit, vec3f(0.0, 0.5, 0.0), 0.3, vec3f(0.0, 0.0, 0.0))) {
    (*r).tmax = (*hit).dist;
  }

  return (*hit).has_hit;
}

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  var r = get_camera_ray(coords);
  var hit = HitInfo(false, 0.0, vec3f(0.0));

  let bg_color = vec3f(0.1, 0.3, 0.6);

  if (intersect_scene(&r, &hit)) {
    return vec4f(hit.color, 1.0);
  }
  return vec4f(bg_color, 1.0);
}