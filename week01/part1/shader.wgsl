// Uniforms
struct Uniforms {
  aspect: f32,
  cam_const: f32,
  gamma: f32,
  _pad: f32,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

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
};

// Compute camera ray for fragment
fn get_camera_ray(ip: vec2f) -> Ray {
  let eye = vec3f(2.0, 1.5, 2.0);
  let p   = vec3f(0.0, 0.5, 0.0);
  let up  = vec3f(0.0, 1.0, 0.0);
  let v  = normalize(p - eye);
  let b1 = normalize(cross(v, up));
  let b2 = cross(b1, v);
  let uv = vec2f(ip.x * uniforms.aspect * 0.5, ip.y * 0.5);
  let dir = normalize(uv.x * b1 + uv.y * b2 + uniforms.cam_const * v);
  return Ray(eye, dir);
}

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let r = get_camera_ray(coords);
  var col = 0.5 * (r.direction + vec3f(1.0));
  col = pow(col, vec3f(1.0 / uniforms.gamma));
  return vec4f(col, 1.0);
}