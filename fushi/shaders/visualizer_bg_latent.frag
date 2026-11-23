// 全屏歌词动画背景「隐现」（folia backgrounds/latent/）：下层流体渐变（六个封面 / 主题色点
// 漂移、按距离加权混色，扭曲 + 旋涡），上层按 4×4 Bayer 有序抖动的像素图案（翘曲噪声），
// 两层以 soft-light 叠合，最后可叠一层底色提升可读性。
//
// folia 用的是 @paper-design/shaders 的 MeshGradient / Dithering；那套源码不随包、许可也不同，
// 这里是自写的同类算法，只对齐参数语义（速度 / 扭曲 / 旋涡 / 像素尺寸 / 图层透明度）与观感。
// Dart 侧（latent_background.dart）逐帧算好平滑后的音频量与动画时间；着色器加载失败（widget
// 测试）时 Dart 侧用同一套公式在粗网格上走 CPU 近似。
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uMeshTime;
uniform float uDitherTime;
uniform float uDistortion;
uniform float uSwirl;
uniform float uPxSize;
uniform float uDitherOpacity;
uniform float uShowMesh;
uniform float uShowDither;
uniform float uMeshScale;
uniform float uDitherScale;
uniform float uMeshSaturate;
uniform float uMeshBrightness;
uniform float uOverlay;
uniform vec3 uC0;
uniform vec3 uC1;
uniform vec3 uC2;
uniform vec3 uC3;
uniform vec3 uC4;
uniform vec3 uC5;
uniform vec3 uDitherBack;
uniform vec3 uDitherFront;
uniform vec3 uBg;

out vec4 fragColor;

// 第 i 个色点的位置（以画布高为 1 的坐标，原点在中心）。
vec2 meshPoint(float i, float t, float aspect) {
  float a = t * 0.4 * (1.0 + 0.13 * i) + i * 1.7;
  float b = t * 0.33 * (1.0 + 0.11 * i) + i * 2.3;
  return vec2(0.36 * aspect * cos(a), 0.36 * sin(b));
}

float meshWeight(vec2 p, vec2 c) {
  float d = length(p - c);
  return 1.0 / (pow(d, 2.5) + 0.0005);
}

vec3 meshAt(vec2 frag) {
  float aspect = uSize.x / max(uSize.y, 1.0);
  vec2 p = (frag - 0.5 * uSize) / max(uSize.y, 1.0) / uMeshScale;
  float t = uMeshTime;
  p += uDistortion * 0.08 * vec2(sin(p.y * 4.0 + t * 0.6), cos(p.x * 4.0 - t * 0.5));
  float r = length(p);
  float ang = uSwirl * 3.0 * (1.0 - smoothstep(0.0, 0.9, r));
  float cs = cos(ang);
  float sn = sin(ang);
  p = vec2(cs * p.x - sn * p.y, sn * p.x + cs * p.y);
  float w0 = meshWeight(p, meshPoint(0.0, t, aspect));
  float w1 = meshWeight(p, meshPoint(1.0, t, aspect));
  float w2 = meshWeight(p, meshPoint(2.0, t, aspect));
  float w3 = meshWeight(p, meshPoint(3.0, t, aspect));
  float w4 = meshWeight(p, meshPoint(4.0, t, aspect));
  float w5 = meshWeight(p, meshPoint(5.0, t, aspect));
  vec3 c = uC0 * w0 + uC1 * w1 + uC2 * w2 + uC3 * w3 + uC4 * w4 + uC5 * w5;
  c /= (w0 + w1 + w2 + w3 + w4 + w5);
  float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(vec3(lum), c, uMeshSaturate) * uMeshBrightness;
  return clamp(c, 0.0, 1.0);
}

float bayer2(vec2 a) {
  a = floor(a);
  return fract(dot(a, vec2(0.5, a.y * 0.75)));
}

float bayer4(vec2 a) {
  return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

// 翘曲噪声图案 0–1。
float warpPattern(vec2 q, float t) {
  for (int k = 0; k < 4; k++) {
    float fk = float(k);
    q += 0.4 * vec2(sin(q.y * 1.7 + t + fk), cos(q.x * 1.3 - t * 0.8 + fk * 1.3));
  }
  return 0.5 + 0.5 * sin(q.x + q.y * 0.7 + t * 0.5);
}

vec3 ditherAt(vec2 frag) {
  vec2 f = (frag - 0.5 * uSize) / uDitherScale + 0.5 * uSize;
  float px = max(uPxSize, 0.5);
  vec2 cell = floor(f / px);
  vec2 q = cell * px / max(uSize.y, 1.0) * 3.0;
  float v = warpPattern(q, uDitherTime);
  float on = step(bayer4(cell), v);
  return mix(uDitherBack, uDitherFront, on);
}

float softLightChannel(float d, float s) {
  if (s <= 0.5) {
    return d - (1.0 - 2.0 * s) * d * (1.0 - d);
  }
  float g = d <= 0.25 ? ((16.0 * d - 12.0) * d + 4.0) * d : sqrt(d);
  return d + (2.0 * s - 1.0) * (g - d);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec3 color = uBg;
  if (uShowMesh > 0.5) {
    color = meshAt(frag);
  }
  if (uShowDither > 0.5) {
    vec3 d = ditherAt(frag);
    if (uShowMesh > 0.5) {
      vec3 s = vec3(
        softLightChannel(color.r, d.r),
        softLightChannel(color.g, d.g),
        softLightChannel(color.b, d.b));
      color = mix(color, s, clamp(uDitherOpacity, 0.0, 1.0));
    } else {
      color = d;
    }
  }
  color = mix(color, uBg, clamp(uOverlay, 0.0, 1.0));
  fragColor = vec4(color, 1.0);
}
