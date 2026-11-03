// 阅读器「卷页」翻页：把一张页面快照（uSheet）里的纸面矩形沿圆柱卷起。
//
// 纸面 = 覆盖层里的矩形 uOrigin + [0, uSize]（小说是整个视口；漫画只是页图本身，
// 黑边不是纸、不卷，直接露出下面）。几何在「纸面局部、未镜像空间」里算：书脊在
// x = 0、被拎起的角在 x = uSize.x（从左往右读的前进翻页）。从右往左读（竖排 / RTL /
// 漫画右开）时 uMirror = 1，片元先在纸面内水平镜像再算，采样时再镜像回去——同一套
// 几何覆盖两种阅读方向。
//
// 模型：纸面在卷轴线（法向 n 指向被拎起的那一侧）之前是平的；越过轴线后绕一个半径 r
// 的圆柱卷上去，卷过半圈后以背面朝上平铺回轴线这一侧（高度 2r）。投影到屏幕上：
//   s ∈ [0, πr]   x = r·sin(s/r)          （圆柱，正面朝下半圈 / 背面朝上半圈）
//   s > πr        x = −(s − πr)           （背面平铺）
// 其中 s 是纸面上离轴线的弧长、x 是屏幕上离轴线的距离。片元按「最上层优先」取：
// 背面平铺 → 圆柱背面 → 圆柱正面 → 平铺正面 → 底图（uHasBase = 0 时透明，露出下面
// 活的 WebView）。
//
// 纸背不透出正文（透字看起来像穿帮）：背面是纸色略暗，翻起的那片靠背面明暗、
// 卷边一道细线和它投在下面的阴影与正面区分开。
//
// 拎起的角 uCorner 当前在 uPoint：轴线是两点连线的「卷曲中垂线」——取
// a = (|C − F| − πr)/2，使角点刚好落在 F（r 随拖动距离收缩，避免起手时角点跳动）。
#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// 覆盖层（视口）尺寸。
uniform vec2 uView;
// 纸面矩形左上角（屏幕坐标）与尺寸。
uniform vec2 uOrigin;
uniform vec2 uSize;
uniform vec2 uCorner;
uniform vec2 uPoint;
uniform float uRadius;
uniform float uMirror;
uniform float uHasBase;
// 纸背：rgb = 纸色（0..1），a = 纸背相对纸色的明度。
uniform vec4 uBack;
uniform sampler2D uSheet;
uniform sampler2D uBase;

out vec4 fragColor;

const float PI = 3.14159265;

// 越出纸面多远（0 = 在纸面内）。阴影按它衰减。
float outside(vec2 q) {
  vec2 lo = max(-q, vec2(0.0));
  vec2 hi = max(q - uSize, vec2(0.0));
  return max(max(lo.x, lo.y), max(hi.x, hi.y));
}

// 纸面内离最近一条纸边多远（纸面外为 0）。
float inside(vec2 q) {
  vec2 m = min(q, uSize - q);
  return max(0.0, min(m.x, m.y));
}

// 纸面局部坐标 → 快照纹理坐标。
vec2 sheetUv(vec2 q) {
  vec2 c = clamp(q, vec2(0.0), uSize);
  if (uMirror > 0.5) {
    c.x = uSize.x - c.x;
  }
  return clamp((uOrigin + c) / uView, vec2(0.0), vec2(1.0));
}

vec3 sheetAt(vec2 q) {
  return texture(uSheet, sheetUv(q)).rgb;
}

// 纸背：纸色 × 明度。卷边（纸的外缘）压一道细线，翻起的那片在同色纸上也看得出轮廓。
vec4 backAt(vec2 q, float shade) {
  float edge = mix(0.86, 1.0, smoothstep(0.0, 1.5, inside(q)));
  return vec4(uBack.rgb * (uBack.a * shade * edge), 1.0);
}

vec4 under(vec2 frag, float shadow) {
  if (uHasBase > 0.5) {
    vec4 b = texture(uBase, clamp(frag / uView, vec2(0.0), vec2(1.0)));
    return vec4(b.rgb * (1.0 - shadow), 1.0);
  }
  // 预乘输出：纯黑 × 阴影浓度，叠在活的 WebView 上。
  return vec4(0.0, 0.0, 0.0, shadow);
}

// 平铺的正面（纸面外露出下面），带上方翻起那片投下的阴影。
vec4 flatAt(vec2 p, vec2 frag, float shadow) {
  if (outside(p) > 0.0) {
    return under(frag, shadow);
  }
  return vec4(sheetAt(p) * (1.0 - shadow), 1.0);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 p = frag - uOrigin;
  if (uMirror > 0.5) {
    p.x = uSize.x - p.x;
  }
  vec2 v = uCorner - uPoint;
  float len = length(v);
  if (len < 0.5) {
    fragColor = flatAt(p, frag, 0.0);
    return;
  }
  vec2 n = v / len;
  float r = max(0.5, min(uRadius, len / PI));
  float a = (len - PI * r) * 0.5;
  vec2 axisPoint = uPoint + n * a;
  float d = dot(p - axisPoint, n);

  if (d <= 0.0) {
    // 最上层：卷过来平铺的背面。贴近卷起处略暗（纸从这里弯下去）。
    vec2 qBack = p + n * (PI * r - 2.0 * d);
    float outBack = outside(qBack);
    if (outBack <= 0.0) {
      float shade = mix(0.94, 1.0, smoothstep(0.0, r * 1.2, -d));
      fragColor = backAt(qBack, shade);
      return;
    }
    // 翻起的那片投在下面的软阴影（贴着它的外缘最浓）。
    float s = 1.0 - smoothstep(0.0, max(r * 0.6, 10.0), outBack);
    fragColor = flatAt(p, frag, 0.24 * s * s);
    return;
  }

  if (d <= r) {
    float k = d / r;
    float theta = asin(clamp(k, 0.0, 1.0));
    // 圆柱上半圈（背面朝上，盖在最上面）：顶上与平铺的背面接续，往圆柱侧面
    // （k → 1）转离视线渐暗。
    vec2 qBack = p + n * (r * (PI - theta) - d);
    if (outside(qBack) <= 0.0) {
      fragColor = backAt(qBack, mix(0.94, 0.8, k * k));
      return;
    }
    // 圆柱下半圈（正面，向上翘起）：底部与平铺的正面接续，越往侧面越背光。
    vec2 qFront = p + n * (r * theta - d);
    if (outside(qFront) <= 0.0) {
      fragColor = vec4(sheetAt(qFront) * mix(1.0, 0.78, k * k), 1.0);
      return;
    }
    fragColor = under(frag, 0.0);
    return;
  }

  // 卷曲之外：底下的页，靠近卷起处有一道阴影。只在卷起的纸面「投影」覆盖得到的
  // 范围里画（沿轴线方向越出纸面就不画），不会在空白处凭空出现一条暗带。
  vec2 qEdge = p + n * (r * PI * 0.5 - d);
  float along = outside(qEdge - n * dot(qEdge - axisPoint, n));
  float fall = 1.0 - smoothstep(0.0, r * 0.9 + 8.0, d - r);
  float alongFade = 1.0 - smoothstep(0.0, 24.0, along);
  fragColor = under(frag, 0.22 * fall * fall * alongFade);
}
