struct Uniforms_f {
  aspect: f32,
};

struct Uniforms_ui {
  use_repeat: u32,
  use_linear: u32,
};

struct VSOut {
  @builtin(position) position: vec4f,
  @location(0) coords: vec2f,
};

@group(0) @binding(0) var<uniform> uniforms_f: Uniforms_f;
@group(0) @binding(1) var<uniform> uniforms_ui: Uniforms_ui;
@group(0) @binding(2) var my_texture: texture_2d<f32>;

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
  out.coords = pos[vid];
  return out;
}

// Sampling helpers
fn get_coord(tex: texture_2d<f32>, coord: vec2i, repeat: bool) -> vec2i {
  let res = vec2i(textureDimensions(tex));
  if (repeat) {
    return ((coord % res) + res) % res;
  } else {
    return clamp(coord, vec2i(0), res - vec2i(1));
  }
}

// Nearest neighbor sampling
fn texture_nearest(tex: texture_2d<f32>, texcoords: vec2f, repeat: bool) -> vec3f {
  let res = vec2f(textureDimensions(tex));
  let coord = vec2i(floor(texcoords * res));
  let final_coord = get_coord(tex, coord, repeat);
  return textureLoad(tex, final_coord, 0).rgb;
}

// Bilinear interpolation
fn texture_linear(tex: texture_2d<f32>, texcoords: vec2f, repeat: bool) -> vec3f {
  let res = vec2f(textureDimensions(tex));
  let ab = texcoords * res - 0.5;
  let base = vec2i(floor(ab));
  let f = fract(ab);
  
  let c00 = textureLoad(tex, get_coord(tex, base + vec2i(0, 0), repeat), 0).rgb;
  let c10 = textureLoad(tex, get_coord(tex, base + vec2i(1, 0), repeat), 0).rgb;
  let c01 = textureLoad(tex, get_coord(tex, base + vec2i(0, 1), repeat), 0).rgb;
  let c11 = textureLoad(tex, get_coord(tex, base + vec2i(1, 1), repeat), 0).rgb;
  
  let top = mix(c00, c10, f.x);
  let bot = mix(c01, c11, f.x);
  
  return mix(top, bot, f.y);
}

// Fragment shader
@fragment
fn main_fs(@location(0) coords: vec2f) -> @location(0) vec4f {
  let aspect = uniforms_f.aspect;
  var uv = vec2f(coords.x * aspect * 0.5, coords.y * 0.5);
  let use_repeat = uniforms_ui.use_repeat != 0u;
  let use_linear = uniforms_ui.use_linear != 0u;
  
  var color: vec3f;
  if (use_linear) {
    color = texture_linear(my_texture, uv, use_repeat);
  } else {
    color = texture_nearest(my_texture, uv, use_repeat);
  }
  
  return vec4f(color, 1.0);
}