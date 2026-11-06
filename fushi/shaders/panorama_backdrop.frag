// 媒体库全景的背景：随镜头转动的星空 + 星系中心的暖色光晕。
//
// 光晕画在最底层，封面 / 词都盖在它上面：光晕只照亮背景，封面内部永远不会被它铺到
// （辉光的唯一另一个来源是封面图集里预烘焙的边框光）。强度由 uHalo.w 给，Rust 侧全程固定，
// 只在镜头进到光晕所在的球心时收掉。
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
// x, y, 半径（像素）, 强度
uniform vec4 uHalo;
uniform vec3 uForward;
uniform vec3 uRight;
uniform vec3 uUp;
uniform float uFocal;
uniform float uTime;

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// 方向 d 上一层星：经纬网格里每格至多一颗，亮度随到星心的角距衰减。
float stars(vec3 d, float density, float size) {
  float theta = atan(d.z, d.x);
  float phi = asin(clamp(d.y, -1.0, 1.0));
  vec2 uv = vec2(theta * density, phi * density);
  vec2 cell = floor(uv);
  vec2 f = fract(uv) - 0.5;
  float h = hash(cell);
  if (h < 0.82) {
    return 0.0;
  }
  vec2 jitter = vec2(hash(cell + 7.1), hash(cell + 3.7)) - 0.5;
  float dist = length(f - jitter * 0.6);
  float twinkle = 0.75 + 0.25 * sin(uTime * (1.0 + h * 3.0) + h * 40.0);
  return smoothstep(size, 0.0, dist) * (h - 0.82) * 5.5 * twinkle;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 c = uSize * 0.5;
  vec3 dir = normalize(uForward * uFocal + uRight * (p.x - c.x) - uUp * (p.y - c.y));

  // 深蓝底，朝「上」略亮。
  vec3 col = mix(vec3(0.012, 0.016, 0.040), vec3(0.030, 0.040, 0.085), dir.y * 0.5 + 0.5);
  float s = stars(dir, 60.0, 0.10) + stars(dir.zxy, 140.0, 0.16) * 0.6;
  col += vec3(0.85, 0.9, 1.0) * s;

  if (uHalo.w > 0.0 && uHalo.z > 0.0) {
    float r = length(p - uHalo.xy) / uHalo.z;
    float glow = exp(-r * r * 2.2) * 0.85 + exp(-r * 7.0) * 0.6;
    col += vec3(1.0, 0.66, 0.34) * glow * uHalo.w;
  }
  fragColor = vec4(col, 1.0);
}
