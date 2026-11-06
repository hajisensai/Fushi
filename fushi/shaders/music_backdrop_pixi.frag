// 歌词页「Pixi」流体背景：四层旋转封面在全分辨率逐像素合成。
//
// 观感对齐 QPlayer 的 pixi 背景（本文件自写，只对齐算法思路与观感参数）：
// - 取样坐标先过一道「S 形弯曲」：画布上下两条边各有一个大半径鼓包（一个靠右上、
//   一个靠左下），四层旋转方块被拉成几道斜向的长色带，而不是一团团圆斑；
// - 封面贴图是 32px 小图、直接双线性取样：色块边界保持清楚，不再额外糊；
// - 四层方块边缘按短边 11.5% 羽化；每首歌的四个初始角度与弯曲方向随机（uAngles /
//   uBend，由 Dart 侧按歌定），换歌后形态不同；
// - 调色：饱和 ×2.2 → 色度封顶（荧光封面不至于顶成纯原色）→ 整体压暗 → 提对比
//   → 亮度封顶（浅色封面也不会把白字洗掉）。主题压暗在 Dart 侧对 pixi 不再叠加。
//
// 四层几何与转速见 music_lyrics_backdrop.dart 的 `_paintPixi` 注释。
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform vec2 uTexSize;
uniform vec4 uAngles;
uniform float uBend;
uniform sampler2D uTex;

out vec4 fragColor;

// 以 center 为心、半径 radius 的鼓包：圈内的点按距离比例非线性往外推。
vec2 swell(vec2 p, vec2 center, float radius) {
  vec2 d = p - center;
  float r = length(d);
  if (r > 0.0001 && r < radius) {
    float k = r / radius;
    d *= mix(1.0, smoothstep(0.0, 1.0 / k, k), 0.75);
  }
  return center + d;
}

vec2 bendCoord(vec2 p) {
  float radius = (uSize.x + uSize.y) * 0.5;
  float lower = uBend > 0.0 ? 0.25 : 0.75;
  p = swell(p, vec2((1.0 - lower) * uSize.x, 0.0), radius);
  return swell(p, vec2(lower * uSize.x, uSize.y), radius);
}

// 一层：中心 c、边长 side、旋转 rot；返回颜色 + 羽化 alpha。
vec4 layer(vec2 p, vec2 c, float side, float rot, float featherPx) {
  float cs = cos(rot);
  float sn = sin(rot);
  vec2 d = p - c;
  vec2 local = vec2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / side + 0.5;
  float inside = 0.5 - max(abs(local.x - 0.5), abs(local.y - 0.5));
  float f = featherPx / side;
  float a = smoothstep(-f, f, inside);
  vec2 uv = clamp(local, 0.5 / uTexSize, 1.0 - 0.5 / uTexSize);
  return vec4(texture(uTex, uv).rgb, a);
}

vec3 grade(vec3 rgb) {
  float y = dot(rgb, vec3(0.3, 0.59, 0.11));
  rgb = vec3(y) + (rgb - vec3(y)) * 2.2;
  y = dot(rgb, vec3(0.3, 0.59, 0.11));
  vec3 chroma = rgb - vec3(y);
  float amount = max(max(abs(chroma.r), abs(chroma.g)), abs(chroma.b));
  float limit = 0.28;
  if (amount > limit) chroma *= limit / amount;
  rgb = clamp(vec3(y) + chroma, 0.0, 1.0);
  rgb = clamp(rgb * 0.6 * 1.3 - 0.15, 0.0, 1.0);
  float y2 = dot(rgb, vec3(0.3, 0.59, 0.11));
  float lumaLimit = 0.42;
  if (y2 > lumaLimit) rgb *= lumaLimit / y2;
  return rgb;
}

void main() {
  vec2 p = bendCoord(FlutterFragCoord().xy);
  float w = uSize.x;
  float h = uSize.y;
  float m = max(w, h);
  float t = uTime;
  float feather = min(w, h) * 0.115;

  vec3 col = layer(p, uSize * 0.5, m * 1.41421356, uAngles.x + 0.06 * t, feather).rgb;
  vec4 l2 = layer(p, uSize / 2.5, m * 0.8, uAngles.y - 0.12 * t, feather);
  col = mix(col, l2.rgb, l2.a);
  float travel = cos(t * 0.045) * w * 0.25;
  vec4 l3 = layer(p, uSize * 0.5 + vec2(travel), m * 0.5, uAngles.z + 0.06 * t, feather);
  col = mix(col, l3.rgb, l3.a);
  float drift = w * 0.025 + cos(t * 0.27);
  vec4 l4 = layer(p, uSize * 0.5 + vec2(drift), m * 0.25, uAngles.w - 0.08 * t, feather);
  col = mix(col, l4.rgb, l4.a);

  col = grade(col);
  // 抖动：大片缓变渐变在 8 位下会出色带。
  float n = fract(sin(dot(FlutterFragCoord().xy, vec2(12.9898, 78.233))) * 43758.5453);
  col += (n - 0.5) / 255.0;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
