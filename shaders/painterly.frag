// Painterly filter for the Painted style: a Kuwahara filter turns smooth 3D
// shading into soft, flat patches of colour with crisp boundaries, the way a
// background painter lays in a surface with a few brush strokes. A light
// paper grain sits on top.
//
// Runs after tone mapping (display-referred colour).
uniform sampler2D input_color;

uniform PostFrameInfo {
  vec2 resolution;
  vec2 texel_size;
  float time;
  float _pad;
}
frame;

uniform PainterlyParams {
  float radius;   // brush size in pixels (sampled with a stride)
  float strength; // 0 = off, 1 = full painterly
  float grain;    // paper grain amount
  float stride;   // pixels between samples (lets a big brush stay cheap)
}
params;

in vec2 v_uv;
out vec4 frag_color;

// One quadrant of the Kuwahara window: mean colour and its variance.
void Quadrant(vec2 dir, out vec3 mean, out float variance) {
  vec3 sum = vec3(0.0);
  vec3 sum2 = vec3(0.0);
  float n = 0.0;
  for (int y = 0; y <= 4; y++) {
    for (int x = 0; x <= 4; x++) {
      if (float(x) > params.radius || float(y) > params.radius) continue;
      vec2 offset = vec2(float(x), float(y)) * dir * params.stride;
      vec3 c = texture(input_color, v_uv + offset * frame.texel_size).rgb;
      sum += c;
      sum2 += c * c;
      n += 1.0;
    }
  }
  mean = sum / n;
  vec3 v = abs(sum2 / n - mean * mean);
  variance = v.r + v.g + v.b;
}

float Hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main() {
  vec4 original = texture(input_color, v_uv);
  if (params.strength <= 0.0) {
    frag_color = original;
    return;
  }

  vec3 m0, m1, m2, m3;
  float v0, v1, v2, v3;
  Quadrant(vec2(-1.0, -1.0), m0, v0);
  Quadrant(vec2(1.0, -1.0), m1, v1);
  Quadrant(vec2(-1.0, 1.0), m2, v2);
  Quadrant(vec2(1.0, 1.0), m3, v3);

  // Take the calmest quadrant: smooths within shapes, keeps their edges.
  vec3 paint = m0;
  float best = v0;
  if (v1 < best) { best = v1; paint = m1; }
  if (v2 < best) { best = v2; paint = m2; }
  if (v3 < best) { best = v3; paint = m3; }

  vec3 colour = mix(original.rgb, paint, params.strength);

  // Paper: fine grain plus a soft, larger-scale mottling, like watercolour
  // board under gouache. Stays put on screen, like paper would.
  vec2 px = v_uv * frame.resolution;
  float fine = Hash(floor(px)) - 0.5;
  float blot = Hash(floor(px / 9.0)) * 0.6 + Hash(floor(px / 23.0)) * 0.4 - 0.5;
  colour *= 1.0 + (fine * 0.6 + blot * 0.8) * params.grain;

  frag_color = vec4(clamp(colour, 0.0, 1.0), original.a);
}
