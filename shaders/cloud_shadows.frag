// Drifting cloud shadows: soft dark patches that slide across the city with
// the wind, the way fair-weather cumulus shade a hillside town.
//
// Runs on the linear HDR scene colour right after the scene is drawn. Each
// pixel's world position comes from the engine's linear depth; it is traced
// toward the sun up to a cloud layer, where a drifting noise field decides
// whether a cloud sits between it and the sun. Sky pixels are left alone.
uniform sampler2D input_color;
uniform sampler2D input_depth;

// Same layout as the engine's PostCameraInfo: (tan(fovX/2), tan(fovY/2),
// near, far), the view basis, and the camera position.
uniform PostCameraInfo {
  vec4 projection;
  vec4 camera_right;
  vec4 camera_up;
  vec4 camera_forward;
  vec4 camera_position;
}
cam;

uniform CloudShadowParams {
  vec4 sun;   // xyz: unit direction toward the sun; w: shadow strength
  vec4 cloud; // xy: wind offset (m); z: cloud size (m); w: coverage 0..1
}
params;

in vec2 v_uv;
out vec4 frag_color;

float cs_hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float cs_noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(cs_hash(i), cs_hash(i + vec2(1.0, 0.0)), f.x),
             mix(cs_hash(i + vec2(0.0, 1.0)), cs_hash(i + vec2(1.0, 1.0)), f.x),
             f.y);
}

float cs_fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * cs_noise(p);
    p = p * 2.03 + vec2(17.1, 9.2);
    a *= 0.5;
  }
  return v;
}

void main() {
  vec4 scene = texture(input_color, v_uv);
  float depth = texture(input_depth, v_uv).r;
  if (params.sun.w <= 0.0 || depth <= 0.0 || depth >= cam.projection.w * 0.98) {
    frag_color = scene;
    return;
  }
  vec2 ndc = vec2(2.0 * v_uv.x - 1.0, 1.0 - 2.0 * v_uv.y);
  vec3 view = vec3(ndc * cam.projection.xy * depth, depth);
  vec3 world = cam.camera_position.xyz + cam.camera_right.xyz * view.x +
               cam.camera_up.xyz * view.y + cam.camera_forward.xyz * view.z;

  // Up the sun ray to the cloud layer, so shadows lean with a low sun.
  const float layer = 1400.0;
  vec3 l = params.sun.xyz;
  vec2 at = world.xz + l.xz * (layer - world.y) / max(l.y, 0.12);

  vec2 p = (at + params.cloud.xy) / params.cloud.z;
  float shape = cs_fbm(p);
  float threshold = 0.72 - params.cloud.w * 0.5;
  float cloud = smoothstep(threshold, threshold + 0.12, shape);

  frag_color = vec4(scene.rgb * (1.0 - params.sun.w * cloud), scene.a);
}
