// 歌词页「Pixi」流体背景：四层旋转封面在全分辨率逐像素合成。
//
// 封面先缩成边长十几像素的小贴图，这里用 B 样条双三次取样（4 次双线性取样
// 拼出来，C2 连续）放大——等价一次超大模糊、且没有双线性放大那种方格折痕。
// 四层的几何与转速见 music_lyrics_backdrop.dart 的 `_paintPixi` 注释。
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform vec2 uTexSize;
uniform sampler2D uTex;

out vec4 fragColor;

vec4 bspline(float v) {
  vec4 n = vec4(1.0, 2.0, 3.0, 4.0) - v;
  vec4 s = n * n * n;
  float x = s.x;
  float y = s.y - 4.0 * s.x;
  float z = s.z - 4.0 * s.y + 6.0 * s.x;
  float w = 6.0 - x - y - z;
  return vec4(x, y, z, w) * (1.0 / 6.0);
}

vec3 sampleSmooth(vec2 uv) {
  vec2 tc = uv * uTexSize - 0.5;
  vec2 f = fract(tc);
  tc -= f;
  vec4 xc = bspline(f.x);
  vec4 yc = bspline(f.y);
  vec4 c = tc.xxyy + vec2(-0.5, 1.5).xyxy;
  vec4 s = vec4(xc.xz + xc.yw, yc.xz + yc.yw);
  vec4 o = (c + vec4(xc.yw, yc.yw) / s) / uTexSize.xxyy;
  o = clamp(o, 0.0, 1.0);
  vec3 s0 = texture(uTex, o.xz).rgb;
  vec3 s1 = texture(uTex, o.yz).rgb;
  vec3 s2 = texture(uTex, o.xw).rgb;
  vec3 s3 = texture(uTex, o.yw).rgb;
  float sx = s.x / (s.x + s.y);
  float sy = s.z / (s.z + s.w);
  return mix(mix(s3, s2, sx), mix(s1, s0, sx), sy);
}

// 一层：中心 c、边长 side、旋转 rot（与画布 rotate 同向）；返回颜色 + 羽化 alpha。
vec4 layer(vec2 p, vec2 c, float side, float rot, float feather) {
  float cs = cos(rot);
  float sn = sin(rot);
  vec2 d = p - c;
  vec2 local = vec2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / side + 0.5;
  vec2 e = abs(local - 0.5);
  float a = 1.0 - smoothstep(0.5 - feather, 0.5, max(e.x, e.y));
  return vec4(sampleSmooth(clamp(local, 0.0, 1.0)), a);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float w = uSize.x;
  float h = uSize.y;
  float m = max(w, h);
  float t = uTime;
  float orbit = cos(t * 0.045);

  vec3 col = layer(p, vec2(w * 0.5, h * 0.5), m * 1.41421356, 0.06 * t, 0.0).rgb;
  vec4 l2 = layer(p, vec2(w / 2.5, h / 2.5), m * 0.8, -0.12 * t, 0.35);
  col = mix(col, l2.rgb, l2.a);
  vec4 l3 = layer(p, vec2(w * 0.5 + w * 0.25 * orbit, h * 0.5 + w * 0.25 * orbit), m * 0.5, 0.06 * t, 0.4);
  col = mix(col, l3.rgb, l3.a);
  vec4 l4 = layer(p, vec2(w * 0.5 + w / 40.0, h * 0.5 + w / 40.0), m * 0.25, -0.08 * t, 0.45);
  col = mix(col, l4.rgb, l4.a);

  // 饱和度 ×1.5、对比度 ×1.2（围绕中灰）。
  float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = mix(vec3(luma), col, 1.5);
  col = (col - 0.5) * 1.2 + 0.5;
  // 抖动：大片缓变渐变在 8 位下会出色带。
  float n = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
  col += (n - 0.5) / 255.0;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
