#version 460 core

// 商籁（folia sonnet）整体后处理：透镜桶形扭曲 + 径向色散（sonnetLensFilter.ts）→
// 固定 RGB 错位 → 半调网点 → 暗角（sonnetPrintFilters.ts），顺序与 folia 的滤镜链一致。
// uScene 是这一帧场景的离屏图；没有加载成功时 Dart 侧走 CPU 近似（无扭曲 / 网点）。

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uDistortion;
uniform float uDispersion;
uniform float uRgbShift;
uniform float uHalftone;
uniform float uVignette;
uniform sampler2D uScene;

out vec4 fragColor;

vec4 sampleInside(vec2 uv) {
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
    return vec4(0.0);
  }
  return texture(uScene, uv);
}

vec4 lensAt(vec2 screenUv) {
  if (uDistortion <= 0.0 && uDispersion <= 0.0) {
    return sampleInside(screenUv);
  }
  vec2 centered = screenUv - 0.5;
  float aspect = uSize.x / max(uSize.y, 1.0);
  centered.x *= aspect;
  float r2 = dot(centered, centered);
  float curvature = uDistortion * 0.32;
  float radialScale = 1.0 - curvature * r2 + curvature * 0.16 * r2 * r2;
  vec2 lensCentered = centered * radialScale;
  lensCentered.x /= aspect;
  vec2 lensUv = lensCentered + 0.5;
  float radius = sqrt(r2);
  vec2 dir = radius > 0.0001 ? centered / radius : vec2(0.0);
  float edgeWeight = smoothstep(0.12, 0.9, radius);
  vec2 dispersion = dir * uDispersion * 0.012 * edgeWeight;
  dispersion.x /= aspect;
  vec4 center = sampleInside(lensUv);
  vec4 redSample = sampleInside(lensUv + dispersion);
  vec4 blueSample = sampleInside(lensUv - dispersion);
  float alpha = max(center.a, max(redSample.a, blueSample.a));
  float coreWeight = 0.84 - clamp(uDispersion, 0.0, 1.0) * 0.18;
  vec3 core = center.rgb * coreWeight;
  vec3 separated = vec3(redSample.r, center.g, blueSample.b);
  return vec4(max(core, separated), alpha);
}

float dotScreen(vec2 coord, float angle, float value, float cellSize, float edge) {
  float c = cos(angle);
  float s = sin(angle);
  vec2 rotated = mat2(c, s, -s, c) * coord;
  float dist = length(fract(rotated / cellSize) - 0.5) * cellSize;
  float radius = sqrt(clamp(value, 0.0, 1.0)) * cellSize * 0.62;
  return 1.0 - smoothstep(radius - edge, radius + edge, dist);
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = fragCoord / uSize;
  vec4 color;
  if (uRgbShift > 0.0) {
    vec2 offset = vec2(0.9063, 0.4226) * uRgbShift * 3.0 / uSize;
    vec4 redSample = lensAt(uv + offset);
    vec4 center = lensAt(uv);
    vec4 blueSample = lensAt(uv - offset);
    float alpha = max(center.a, max(redSample.a, blueSample.a));
    float coreWeight = 0.84 - clamp(uRgbShift, 0.0, 1.0) * 0.18;
    color = vec4(max(center.rgb * coreWeight, vec3(redSample.r, center.g, blueSample.b)), alpha);
  } else {
    color = lensAt(uv);
  }
  if (uHalftone > 0.0) {
    if (color.a > 0.0) {
      color.rgb /= color.a;
    }
    vec3 screened = vec3(
      dotScreen(fragCoord, radians(15.0), color.r, 5.0, 0.6),
      dotScreen(fragCoord, radians(75.0), color.g, 5.0, 0.6),
      dotScreen(fragCoord, radians(0.0), color.b, 5.0, 0.6)
    );
    color.rgb = mix(color.rgb, screened, uHalftone);
    color.rgb *= color.a;
  }
  if (uVignette > 0.0) {
    vec2 centered = uv - 0.5;
    float v = clamp(smoothstep(0.52, 1.08, length(centered)) * uVignette * 0.6, 0.0, 1.0);
    color = mix(color, vec4(0.0, 0.0, 0.0, 1.0), v);
  }
  fragColor = color;
}
