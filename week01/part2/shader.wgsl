// Uniforms
struct Uniforms {
  aspect: f32,
  cam_const: f32,
  gamma: f32,
  _pad0: f32,

  eye: vec4f,
  b1:  vec4f,
  b2:  vec4f,
  v:   vec4f,
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

// Compute camera ray
fn get_camera_ray(coords: vec2f) -> Ray {
  let uv = vec2f(coords.x * U.aspect * 0.5, coords.y * 0.5);

  let origin = U.eye.xyz;
  let dir = normalize(uv.x * U.b1.xyz + uv.y * U.b2.xyz + U.cam_const * U.v.xyz);

  return Ray(origin, dir, 0.001, 1e6);
}

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let r = get_camera_ray(coords);

  var col = 0.5 * (r.direction + vec3f(1.0));

  col = pow(col, vec3f(1.0 / U.gamma));

  return vec4f(col, 1.0);
}