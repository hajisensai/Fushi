// 阅读器「卷页」翻页：把一张页面快照（uSheet）沿圆柱卷起。
//
// 几何在「未镜像空间」里算：书脊在左、被拎起的角在右（从左往右读的前进翻页）。
// 从右往左读（竖排 / RTL / 漫画右开）时 uMirror = 1，片元先水平镜像再算，采样时
// 再镜像回去——同一套几何覆盖两种阅读方向。
//
// 模型：纸面在卷轴线（法向 n 指向被拎起的那一侧）之前是平的；越过轴线后绕一个半径 r
// 的圆柱卷上去，卷过半圈后以背面朝上平铺回轴线这一侧（高度 2r）。投影到屏幕上：
//   s ∈ [0, πr]   x = r·sin(s/r)          （圆柱，正面朝下半圈 / 背面朝上半圈）
//   s > πr        x = −(s − πr)           （背面平铺）
// 其中 s 是纸面上离轴线的弧长、x 是屏幕上离轴线的距离。片元按「最上层优先」取：
// 背面平铺 → 圆柱背面 → 圆柱正面 → 平铺正面 → 底图（uHasBase = 0 时透明，露出下面
// 活的 WebView）。
//
// 拎起的角 uCorner 当前在 uPoint：轴线是两点连线的「卷曲中垂线」——取
// a = (|C − F| − πr)/2，使角点刚好落在 F（r 随拖动距离收缩，避免起手时角点跳动）。
#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform vec2 uCorner;
uniform vec2 uPoint;
uniform float uRadius;
uniform float uMirror;
uniform float uHasBase;
// 纸张背面的底色（阅读器背景色，rgb 0..1；a 为背面透出正文的程度）。
uniform vec4 uBack;
uniform sampler2D uSheet;
uniform sampler2D uBase;

out vec4 fragColor;

const float PI = 3.14159265;

// 越出页面多远（0 = 在页内）。阴影按它衰减。
float outside(vec2 q) {
  vec2 lo = max(-q, vec2(0.0));
  vec2 hi = max(q - uSize, vec2(0.0));
  return max(max(lo.x, lo.y), max(hi.x, hi.y));
}

vec4 sheetAt(vec2 q) {
  vec2 uv = clamp(q / uSize, vec2(0.0), vec2(1.0));
  if (uMirror > 0.5) {
    uv.x = 1.0 - uv.x;
  }
  vec4 c = texture(uSheet, uv);
  return vec4(c.rgb, 1.0);
}

// 背面：底色上透出一点镜像的正文（采样点本身就是镜像过来的）。
vec4 backAt(vec2 q) {
  vec4 c = sheetAt(q);
  return vec4(mix(uBack.rgb, c.rgb, uBack.a), 1.0);
}

vec4 under(vec2 frag, float shadow) {
  if (uHasBase > 0.5) {
    vec4 b = texture(uBase, clamp(frag / uSize, vec2(0.0), vec2(1.0)));
    return vec4(b.rgb * (1.0 - shadow), 1.0);
  }
  // 预乘输出：纯黑 × 阴影浓度，叠在活的 WebView 上。
  return vec4(0.0, 0.0, 0.0, shadow);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 p = frag;
  if (uMirror > 0.5) {
    p.x = uSize.x - p.x;
  }
  vec2 v = uCorner - uPoint;
  float len = length(v);
  if (len < 0.5) {
    fragColor = sheetAt(p);
    return;
  }
  vec2 n = v / len;
  float r = max(0.5, min(uRadius, len / PI));
  float a = (len - PI * r) * 0.5;
  vec2 axisPoint = uPoint + n * a;
  float d = dot(p - axisPoint, n);

  if (d <= 0.0) {
    // 最上层：卷过来平铺的背面。
    vec2 qBack = p + n * (PI * r - 2.0 * d);
    float outBack = outside(qBack);
    if (outBack <= 0.0) {
      // 贴近轴线的那一窄条略暗，表现卷起处的弧度。
      float rim = smoothstep(0.0, r * 0.8, -d);
      vec4 c = backAt(qBack);
      fragColor = vec4(c.rgb * mix(0.93, 1.0, rim), 1.0);
      return;
    }
    // 平铺正面，翻起的那片在它上面投下软阴影。
    float shadow = 0.16 * (1.0 - smoothstep(0.0, max(r * 0.5, 6.0), outBack));
    vec4 c = sheetAt(p);
    fragColor = vec4(c.rgb * (1.0 - shadow), 1.0);
    return;
  }

  if (d <= r) {
    float theta = asin(clamp(d / r, 0.0, 1.0));
    // 圆柱上半圈（背面朝上，离视线更近）。
    float sBack = r * (PI - theta);
    vec2 qBack = p + n * (sBack - d);
    if (outside(qBack) <= 0.0) {
      // 顶端（d≈r）最亮，往轴线回落处渐暗。
      float light = mix(0.9, 1.03, d / r);
      vec4 c = backAt(qBack);
      fragColor = vec4(min(c.rgb * light, vec3(1.0)), 1.0);
      return;
    }
    // 圆柱下半圈（正面，向上翘起）：越往上越背光。
    float sFront = r * theta;
    vec2 qFront = p + n * (sFront - d);
    float outFront = outside(qFront);
    if (outFront <= 0.0) {
      float k = d / r;
      vec4 c = sheetAt(qFront);
      fragColor = vec4(c.rgb * mix(1.0, 0.8, k * k), 1.0);
      return;
    }
    fragColor = under(frag, 0.0);
    return;
  }

  // 卷曲之外：底下的页，靠近卷起处有一道阴影。只在卷起的纸面「投影」覆盖得到的
  // 范围里画（沿轴线方向越出页面就不画），不会在空白处凭空出现一条暗带。
  vec2 qEdge = p + n * (r * PI * 0.5 - d);
  float along = outside(qEdge - n * dot(qEdge - axisPoint, n));
  float fall = 1.0 - smoothstep(0.0, r * 0.9 + 8.0, d - r);
  float alongFade = 1.0 - smoothstep(0.0, 24.0, along);
  fragColor = under(frag, 0.2 * fall * fall * alongFade);
}
