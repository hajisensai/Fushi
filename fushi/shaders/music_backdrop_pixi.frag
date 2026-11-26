// 歌词页「Pixi」流体背景：四层旋转封面在全分辨率逐像素合成。
//
// 观感对齐 QPlayer 的 pixi 背景（本文件自写，只对齐算法思路与观感参数）：
// - 取样坐标先过一道「S 形弯曲」：画布上下两条边各有一个大半径鼓包（一个靠右上、
//   一个靠左下），四层旋转方块被拉成几道斜向的长色带，而不是一团团圆斑；
// - 封面贴图是 32px 小图、直接双线性取样：色块边界保持清楚，不再额外糊；
// - 四层方块边缘按短边 11.5% 羽化；每首歌的四个初始角度与弯曲方向随机（uAngles* /
//   uBend*，由 Dart 侧按歌定），换歌后形态不同；
// - 调色：饱和 ×2.2 → 色度封顶（荧光封面不至于顶成纯原色）→ 整体压暗 → 提对比
//   → 亮度封顶（浅色封面也不会把白字洗掉）。之后乘主题调色矩阵（uColor*）。
//
// 换歌交叉淡化在这一个 pass 里做（A = 旧歌、B = 新歌，uMix = B 的权重），不再让两个
// 全屏场景各跑一遍再叠不透明度；主题调色矩阵也在这里乘，不再给整屏另叠 ColorFilter。
//
// uniform 布局（Dart 侧 `_BackdropPainter._drawShader` 按这个顺序 setFloat）：
//   0-1 uSize · 2 uTime · 3-4 uTexSize · 5-8 uAnglesA · 9 uBendA · 10-13 uAnglesB ·
//   14 uBendB · 15 uMix · 16 uAlpha · 17-20 uColorR · 21-24 uColorG · 25-28 uColorB
//   （调色矩阵前三行：r, g, b 系数 + 0–1 偏移）。采样器 0 = A 层封面、1 = B 层封面。
//
// 四层几何与转速见 music_lyrics_backdrop.dart 的 `_paintPixi` 注释。
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform vec2 uTexSize;
uniform vec4 uAnglesA;
uniform float uBendA;
uniform vec4 uAnglesB;
uniform float uBendB;
uniform float uMix;
uniform float uAlpha;
uniform vec4 uColorR;
uniform vec4 uColorG;
uniform vec4 uColorB;
uniform sampler2D uTexA;
uniform sampler2D uTexB;

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

vec2 bendCoord(vec2 p, float bend) {
  float radius = (uSize.x + uSize.y) * 0.5;
  float lower = bend > 0.0 ? 0.25 : 0.75;
  p = swell(p, vec2((1.0 - lower) * uSize.x, 0.0), radius);
  return swell(p, vec2(lower * uSize.x, uSize.y), radius);
}

// 一层：中心 c、边长 side、旋转 rot；返回贴图坐标（xy）+ 羽化 alpha（z）。
vec3 layerUv(vec2 p, vec2 c, float side, float rot, float featherPx) {
  float cs = cos(rot);
  float sn = sin(rot);
  vec2 d = p - c;
  vec2 local = vec2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / side + 0.5;
  float inside = 0.5 - max(abs(local.x - 0.5), abs(local.y - 0.5));
  float f = featherPx / side;
  float a = smoothstep(-f, f, inside);
  vec2 uv = clamp(local, 0.5 / uTexSize, 1.0 - 0.5 / uTexSize);
  return vec3(uv, a);
}

vec3 sampleTex(bool useB, vec2 uv) {
  if (useB) {
    return texture(uTexB, uv).rgb;
  }
  return texture(uTexA, uv).rgb;
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

// 一首歌的四层合成（useB 选 B 层的封面与形态，否则 A 层）。
vec3 compose(vec2 frag, bool useB) {
  vec4 angles = useB ? uAnglesB : uAnglesA;
  vec2 p = bendCoord(frag, useB ? uBendB : uBendA);
  float w = uSize.x;
  float h = uSize.y;
  float m = max(w, h);
  float t = uTime;
  float feather = min(w, h) * 0.115;

  vec3 l1 = layerUv(p, uSize * 0.5, m * 1.41421356, angles.x + 0.06 * t, feather);
  vec3 col = sampleTex(useB, l1.xy);
  vec3 l2 = layerUv(p, uSize / 2.5, m * 0.8, angles.y - 0.12 * t, feather);
  col = mix(col, sampleTex(useB, l2.xy), l2.z);
  float travel = cos(t * 0.045) * w * 0.25;
  vec3 l3 = layerUv(p, uSize * 0.5 + vec2(travel), m * 0.5, angles.z + 0.06 * t, feather);
  col = mix(col, sampleTex(useB, l3.xy), l3.z);
  float drift = w * 0.025 + cos(t * 0.27);
  vec3 l4 = layerUv(p, uSize * 0.5 + vec2(drift), m * 0.25, angles.w - 0.08 * t, feather);
  col = mix(col, sampleTex(useB, l4.xy), l4.z);
  return grade(col);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec3 col;
  // uMix 对整屏一致（uniform 分支）：不在淡化中时只算一首。
  if (uMix <= 0.0) {
    col = compose(frag, false);
  } else if (uMix >= 1.0) {
    col = compose(frag, true);
  } else {
    col = mix(compose(frag, false), compose(frag, true), uMix);
  }
  col = clamp(
    vec3(
      dot(uColorR.xyz, col) + uColorR.w,
      dot(uColorG.xyz, col) + uColorG.w,
      dot(uColorB.xyz, col) + uColorB.w
    ),
    0.0,
    1.0
  );
  // 抖动：大片缓变渐变在 8 位下会出色带。
  float n = fract(sin(dot(frag, vec2(12.9898, 78.233))) * 43758.5453);
  col = clamp(col + (n - 0.5) / 255.0, 0.0, 1.0);
  // 预乘输出。
  fragColor = vec4(col * uAlpha, uAlpha);
}
