// Copyright 2021 Google LLC
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// 本文件是 Google material_color_utilities（Dart 包 0.13.0，即 Flutter SDK
// packages/flutter/pubspec.yaml 钉定的版本）中「种子色 -> M3 动态配色」所需子集的逐行 JS 移植：
//   utils（color_utils / math_utils）、hct（cam16 / viewing_conditions / hct / hct_solver）、
//   palettes/tonal_palette（含 KeyColor）、dislike、temperature_cache、contrast、
//   dynamiccolor（dynamic_color / dynamic_scheme / material_dynamic_colors / contrast_curve /
//   tone_delta_pair / variant）、scheme 全部 9 个 variant。
// 目的：扩展与 app（Flutter ColorScheme.fromSeed）对同一种子 / 明暗 / variant / 对比度给出逐位一致的
// ARGB。schemeFromSeed 的角色映射照抄 Flutter color_scheme.dart 的 fromSeed / _buildDynamicScheme
// （surfaceTint 取 MaterialDynamicColors.primary，onInverseSurface 取 inverseOnSurface）。
// 正确性由 material-color.test.js 用 Dart 原包跑出的真值逐角色精确比对守住。
//
// 移植要点：Dart int 是 64 位，JS 位运算是 32 位有符号，所以 ARGB 一律 >>> 0 成无符号；
// Dart 的 double.round() 是四舍五入远离零，这里出现 round 的位置入参都非负，与 Math.round 等价；
// Dart 的 double % 结果非负，原代码随后都有「<0 则 +360」或入参恒正，JS 的 % 结果一致。
// 经典脚本（非 ES module），可在 content script / 扩展页面 / service worker / node vm 中运行，
// 不依赖 DOM 与 chrome.*，挂在全局 fushiMaterialColor 上。
(function () {
  'use strict';
  var g = typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : globalThis);

  // ---------------------------------------------------------------------------
  // utils/math_utils.dart
  // ---------------------------------------------------------------------------
  var MathUtils = {
    signum: function (num) {
      if (num < 0) {
        return -1;
      } else if (num === 0) {
        return 0;
      } else {
        return 1;
      }
    },
    lerp: function (start, stop, amount) {
      return (1.0 - amount) * start + amount * stop;
    },
    clampInt: function (min, max, input) {
      if (input < min) {
        return min;
      } else if (input > max) {
        return max;
      }
      return input;
    },
    clampDouble: function (min, max, input) {
      if (input < min) {
        return min;
      } else if (input > max) {
        return max;
      }
      return input;
    },
    sanitizeDegreesInt: function (degrees) {
      degrees = degrees % 360;
      if (degrees < 0) {
        degrees = degrees + 360;
      }
      return degrees;
    },
    sanitizeDegreesDouble: function (degrees) {
      degrees = degrees % 360.0;
      if (degrees < 0) {
        degrees = degrees + 360.0;
      }
      return degrees;
    },
    rotationDirection: function (from, to) {
      var increasingDifference = MathUtils.sanitizeDegreesDouble(to - from);
      return increasingDifference <= 180.0 ? 1.0 : -1.0;
    },
    differenceDegrees: function (a, b) {
      return 180.0 - Math.abs(Math.abs(a - b) - 180.0);
    },
    matrixMultiply: function (row, matrix) {
      var a = row[0] * matrix[0][0] + row[1] * matrix[0][1] + row[2] * matrix[0][2];
      var b = row[0] * matrix[1][0] + row[1] * matrix[1][1] + row[2] * matrix[1][2];
      var c = row[0] * matrix[2][0] + row[1] * matrix[2][1] + row[2] * matrix[2][2];
      return [a, b, c];
    },
  };

  // ---------------------------------------------------------------------------
  // utils/color_utils.dart
  // ---------------------------------------------------------------------------
  var SRGB_TO_XYZ = [
    [0.41233895, 0.35762064, 0.18051042],
    [0.2126, 0.7152, 0.0722],
    [0.01932141, 0.11916382, 0.95034478],
  ];
  var XYZ_TO_SRGB = [
    [3.2413774792388685, -1.5376652402851851, -0.49885366846268053],
    [-0.9691452513005321, 1.8758853451067872, 0.04156585616912061],
    [0.05562093689691305, -0.20395524564742123, 1.0571799111220335],
  ];
  var WHITE_POINT_D65 = [95.047, 100.0, 108.883];

  function labF(t) {
    var e = 216.0 / 24389.0;
    var kappa = 24389.0 / 27.0;
    if (t > e) {
      return Math.pow(t, 1.0 / 3.0);
    } else {
      return (kappa * t + 16) / 116;
    }
  }

  function labInvf(ft) {
    var e = 216.0 / 24389.0;
    var kappa = 24389.0 / 27.0;
    var ft3 = ft * ft * ft;
    if (ft3 > e) {
      return ft3;
    } else {
      return (116 * ft - 16) / kappa;
    }
  }

  var ColorUtils = {
    argbFromRgb: function (red, green, blue) {
      return ((255 << 24) | ((red & 255) << 16) | ((green & 255) << 8) | (blue & 255)) >>> 0;
    },
    argbFromLinrgb: function (linrgb) {
      var r = ColorUtils.delinearized(linrgb[0]);
      var g2 = ColorUtils.delinearized(linrgb[1]);
      var b = ColorUtils.delinearized(linrgb[2]);
      return ColorUtils.argbFromRgb(r, g2, b);
    },
    alphaFromArgb: function (argb) {
      return (argb >> 24) & 255;
    },
    redFromArgb: function (argb) {
      return (argb >> 16) & 255;
    },
    greenFromArgb: function (argb) {
      return (argb >> 8) & 255;
    },
    blueFromArgb: function (argb) {
      return argb & 255;
    },
    isOpaque: function (argb) {
      return ColorUtils.alphaFromArgb(argb) >= 255;
    },
    argbFromXyz: function (x, y, z) {
      var matrix = XYZ_TO_SRGB;
      var linearR = matrix[0][0] * x + matrix[0][1] * y + matrix[0][2] * z;
      var linearG = matrix[1][0] * x + matrix[1][1] * y + matrix[1][2] * z;
      var linearB = matrix[2][0] * x + matrix[2][1] * y + matrix[2][2] * z;
      var r = ColorUtils.delinearized(linearR);
      var g2 = ColorUtils.delinearized(linearG);
      var b = ColorUtils.delinearized(linearB);
      return ColorUtils.argbFromRgb(r, g2, b);
    },
    xyzFromArgb: function (argb) {
      var r = ColorUtils.linearized(ColorUtils.redFromArgb(argb));
      var g2 = ColorUtils.linearized(ColorUtils.greenFromArgb(argb));
      var b = ColorUtils.linearized(ColorUtils.blueFromArgb(argb));
      return MathUtils.matrixMultiply([r, g2, b], SRGB_TO_XYZ);
    },
    argbFromLab: function (l, a, b) {
      var whitePoint = WHITE_POINT_D65;
      var fy = (l + 16.0) / 116.0;
      var fx = a / 500.0 + fy;
      var fz = fy - b / 200.0;
      var xNormalized = labInvf(fx);
      var yNormalized = labInvf(fy);
      var zNormalized = labInvf(fz);
      var x = xNormalized * whitePoint[0];
      var y = yNormalized * whitePoint[1];
      var z = zNormalized * whitePoint[2];
      return ColorUtils.argbFromXyz(x, y, z);
    },
    labFromArgb: function (argb) {
      var linearR = ColorUtils.linearized(ColorUtils.redFromArgb(argb));
      var linearG = ColorUtils.linearized(ColorUtils.greenFromArgb(argb));
      var linearB = ColorUtils.linearized(ColorUtils.blueFromArgb(argb));
      var matrix = SRGB_TO_XYZ;
      var x = matrix[0][0] * linearR + matrix[0][1] * linearG + matrix[0][2] * linearB;
      var y = matrix[1][0] * linearR + matrix[1][1] * linearG + matrix[1][2] * linearB;
      var z = matrix[2][0] * linearR + matrix[2][1] * linearG + matrix[2][2] * linearB;
      var whitePoint = WHITE_POINT_D65;
      var xNormalized = x / whitePoint[0];
      var yNormalized = y / whitePoint[1];
      var zNormalized = z / whitePoint[2];
      var fx = labF(xNormalized);
      var fy = labF(yNormalized);
      var fz = labF(zNormalized);
      var l = 116.0 * fy - 16;
      var a = 500.0 * (fx - fy);
      var b = 200.0 * (fy - fz);
      return [l, a, b];
    },
    argbFromLstar: function (lstar) {
      var y = ColorUtils.yFromLstar(lstar);
      var component = ColorUtils.delinearized(y);
      return ColorUtils.argbFromRgb(component, component, component);
    },
    lstarFromArgb: function (argb) {
      var y = ColorUtils.xyzFromArgb(argb)[1];
      return 116.0 * labF(y / 100.0) - 16.0;
    },
    yFromLstar: function (lstar) {
      return 100.0 * labInvf((lstar + 16.0) / 116.0);
    },
    lstarFromY: function (y) {
      return labF(y / 100.0) * 116.0 - 16.0;
    },
    linearized: function (rgbComponent) {
      var normalized = rgbComponent / 255.0;
      if (normalized <= 0.040449936) {
        return normalized / 12.92 * 100.0;
      } else {
        return Math.pow((normalized + 0.055) / 1.055, 2.4) * 100.0;
      }
    },
    delinearized: function (rgbComponent) {
      var normalized = rgbComponent / 100.0;
      var delinearized = 0.0;
      if (normalized <= 0.0031308) {
        delinearized = normalized * 12.92;
      } else {
        delinearized = 1.055 * Math.pow(normalized, 1.0 / 2.4) - 0.055;
      }
      return MathUtils.clampInt(0, 255, dartRound(delinearized * 255.0));
    },
    whitePointD65: function () {
      return WHITE_POINT_D65;
    },
  };

  // Dart double.round()：四舍五入远离零（Math.round 对负的 .5 向正无穷取整，这里补齐负数分支）。
  function dartRound(x) {
    return x < 0 ? -Math.round(-x) : Math.round(x);
  }

  // ---------------------------------------------------------------------------
  // hct/viewing_conditions.dart
  // ---------------------------------------------------------------------------
  function makeViewingConditions(whitePoint, adaptingLuminance, backgroundLstar, surround, discountingIlluminant) {
    if (whitePoint == null) whitePoint = ColorUtils.whitePointD65();
    if (adaptingLuminance == null) adaptingLuminance = -1.0;
    if (backgroundLstar == null) backgroundLstar = 50.0;
    if (surround == null) surround = 2.0;
    if (discountingIlluminant == null) discountingIlluminant = false;
    adaptingLuminance =
      adaptingLuminance > 0.0
        ? adaptingLuminance
        : (200.0 / Math.PI * ColorUtils.yFromLstar(50.0) / 100.0);
    backgroundLstar = Math.max(0.1, backgroundLstar);
    var xyz = whitePoint;
    var rW = xyz[0] * 0.401288 + xyz[1] * 0.650173 + xyz[2] * -0.051461;
    var gW = xyz[0] * -0.250268 + xyz[1] * 1.204414 + xyz[2] * 0.045854;
    var bW = xyz[0] * -0.002079 + xyz[1] * 0.048952 + xyz[2] * 0.953127;
    var f = 0.8 + (surround / 10.0);
    var c =
      f >= 0.9
        ? MathUtils.lerp(0.59, 0.69, (f - 0.9) * 10.0)
        : MathUtils.lerp(0.525, 0.59, (f - 0.8) * 10.0);
    var d = discountingIlluminant
      ? 1.0
      : f * (1.0 - ((1.0 / 3.6) * Math.exp((-adaptingLuminance - 42.0) / 92.0)));
    d = d > 1.0 ? 1.0 : (d < 0.0 ? 0.0 : d);
    var nc = f;
    var rgbD = [
      d * (100.0 / rW) + 1.0 - d,
      d * (100.0 / gW) + 1.0 - d,
      d * (100.0 / bW) + 1.0 - d,
    ];
    var k = 1.0 / (5.0 * adaptingLuminance + 1.0);
    var k4 = k * k * k * k;
    var k4F = 1.0 - k4;
    var fl = (k4 * adaptingLuminance) + (0.1 * k4F * k4F * Math.pow(5.0 * adaptingLuminance, 1.0 / 3.0));
    var n = ColorUtils.yFromLstar(backgroundLstar) / whitePoint[1];
    var z = 1.48 + Math.sqrt(n);
    var nbb = 0.725 / Math.pow(n, 0.2);
    var ncb = nbb;
    var rgbAFactors = [
      Math.pow(fl * rgbD[0] * rW / 100.0, 0.42),
      Math.pow(fl * rgbD[1] * gW / 100.0, 0.42),
      Math.pow(fl * rgbD[2] * bW / 100.0, 0.42),
    ];
    var rgbA = [
      (400.0 * rgbAFactors[0]) / (rgbAFactors[0] + 27.13),
      (400.0 * rgbAFactors[1]) / (rgbAFactors[1] + 27.13),
      (400.0 * rgbAFactors[2]) / (rgbAFactors[2] + 27.13),
    ];
    var aw = (40.0 * rgbA[0] + 20.0 * rgbA[1] + rgbA[2]) / 20.0 * nbb;
    return {
      whitePoint: whitePoint,
      adaptingLuminance: adaptingLuminance,
      backgroundLstar: backgroundLstar,
      surround: surround,
      discountingIlluminant: discountingIlluminant,
      backgroundYTowhitePointY: n,
      aw: aw,
      nbb: nbb,
      ncb: ncb,
      c: c,
      nC: nc,
      drgbInverse: [0.0, 0.0, 0.0],
      rgbD: rgbD,
      fl: fl,
      fLRoot: Math.pow(fl, 0.25),
      z: z,
    };
  }
  var VIEWING_SRGB = makeViewingConditions();
  var VIEWING_STANDARD = VIEWING_SRGB;

  // ---------------------------------------------------------------------------
  // hct/cam16.dart（只移植 HCT 用到的部分：fromInt / fromXyzInViewingConditions / fromJch / toInt）
  // ---------------------------------------------------------------------------
  function Cam16(hue, chroma, j, q, m, s, jstar, astar, bstar) {
    this.hue = hue;
    this.chroma = chroma;
    this.j = j;
    this.q = q;
    this.m = m;
    this.s = s;
    this.jstar = jstar;
    this.astar = astar;
    this.bstar = bstar;
  }

  Cam16.fromInt = function (argb) {
    return Cam16.fromIntInViewingConditions(argb, VIEWING_SRGB);
  };

  Cam16.fromIntInViewingConditions = function (argb, viewingConditions) {
    var xyz = ColorUtils.xyzFromArgb(argb);
    return Cam16.fromXyzInViewingConditions(xyz[0], xyz[1], xyz[2], viewingConditions);
  };

  Cam16.fromXyzInViewingConditions = function (x, y, z, viewingConditions) {
    var rC = 0.401288 * x + 0.650173 * y - 0.051461 * z;
    var gC = -0.250268 * x + 1.204414 * y + 0.045854 * z;
    var bC = -0.002079 * x + 0.048952 * y + 0.953127 * z;
    var rD = viewingConditions.rgbD[0] * rC;
    var gD = viewingConditions.rgbD[1] * gC;
    var bD = viewingConditions.rgbD[2] * bC;
    var rAF = Math.pow(viewingConditions.fl * Math.abs(rD) / 100.0, 0.42);
    var gAF = Math.pow(viewingConditions.fl * Math.abs(gD) / 100.0, 0.42);
    var bAF = Math.pow(viewingConditions.fl * Math.abs(bD) / 100.0, 0.42);
    var rA = MathUtils.signum(rD) * 400.0 * rAF / (rAF + 27.13);
    var gA = MathUtils.signum(gD) * 400.0 * gAF / (gAF + 27.13);
    var bA = MathUtils.signum(bD) * 400.0 * bAF / (bAF + 27.13);
    var a = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    var b = (rA + gA - 2.0 * bA) / 9.0;
    var u = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0;
    var p2 = (40.0 * rA + 20.0 * gA + bA) / 20.0;
    var atan2 = Math.atan2(b, a);
    var atanDegrees = atan2 * 180.0 / Math.PI;
    var hue = atanDegrees < 0
      ? atanDegrees + 360.0
      : (atanDegrees >= 360 ? atanDegrees - 360 : atanDegrees);
    var hueRadians = hue * Math.PI / 180.0;
    var ac = p2 * viewingConditions.nbb;
    var J = 100.0 * Math.pow(ac / viewingConditions.aw, viewingConditions.c * viewingConditions.z);
    var Q = (4.0 / viewingConditions.c) *
      Math.sqrt(J / 100.0) *
      (viewingConditions.aw + 4.0) *
      (viewingConditions.fLRoot);
    var huePrime = hue < 20.14 ? hue + 360 : hue;
    var eHue = (1.0 / 4.0) * (Math.cos(huePrime * Math.PI / 180.0 + 2.0) + 3.8);
    var p1 = 50000.0 / 13.0 * eHue * viewingConditions.nC * viewingConditions.ncb;
    var t = p1 * Math.sqrt(a * a + b * b) / (u + 0.305);
    var alpha = Math.pow(t, 0.9) *
      Math.pow(1.64 - Math.pow(0.29, viewingConditions.backgroundYTowhitePointY), 0.73);
    var C = alpha * Math.sqrt(J / 100.0);
    var M = C * viewingConditions.fLRoot;
    var s = 50.0 * Math.sqrt((alpha * viewingConditions.c) / (viewingConditions.aw + 4.0));
    var jstar = (1.0 + 100.0 * 0.007) * J / (1.0 + 0.007 * J);
    var mstar = Math.log(1.0 + 0.0228 * M) / 0.0228;
    var astar = mstar * Math.cos(hueRadians);
    var bstar = mstar * Math.sin(hueRadians);
    return new Cam16(hue, C, J, Q, M, s, jstar, astar, bstar);
  };

  Cam16.fromJch = function (j, c, h) {
    return Cam16.fromJchInViewingConditions(j, c, h, VIEWING_SRGB);
  };

  Cam16.fromJchInViewingConditions = function (J, C, h, viewingConditions) {
    var Q = (4.0 / viewingConditions.c) *
      Math.sqrt(J / 100.0) *
      (viewingConditions.aw + 4.0) *
      (viewingConditions.fLRoot);
    var M = C * viewingConditions.fLRoot;
    var alpha = C / Math.sqrt(J / 100.0);
    var s = 50.0 * Math.sqrt((alpha * viewingConditions.c) / (viewingConditions.aw + 4.0));
    var hueRadians = h * Math.PI / 180.0;
    var jstar = (1.0 + 100.0 * 0.007) * J / (1.0 + 0.007 * J);
    var mstar = 1.0 / 0.0228 * Math.log(1.0 + 0.0228 * M);
    var astar = mstar * Math.cos(hueRadians);
    var bstar = mstar * Math.sin(hueRadians);
    return new Cam16(h, C, J, Q, M, s, jstar, astar, bstar);
  };

  Cam16.prototype.toInt = function () {
    return this.viewed(VIEWING_SRGB);
  };

  Cam16.prototype.viewed = function (viewingConditions) {
    var xyz = this.xyzInViewingConditions(viewingConditions);
    return ColorUtils.argbFromXyz(xyz[0], xyz[1], xyz[2]);
  };

  Cam16.prototype.xyzInViewingConditions = function (viewingConditions) {
    var alpha = (this.chroma === 0.0 || this.j === 0.0) ? 0.0 : this.chroma / Math.sqrt(this.j / 100.0);
    var t = Math.pow(
      alpha / Math.pow(1.64 - Math.pow(0.29, viewingConditions.backgroundYTowhitePointY), 0.73),
      1.0 / 0.9
    );
    var hRad = this.hue * Math.PI / 180.0;
    var eHue = 0.25 * (Math.cos(hRad + 2.0) + 3.8);
    var ac = viewingConditions.aw *
      Math.pow(this.j / 100.0, 1.0 / viewingConditions.c / viewingConditions.z);
    var p1 = eHue * (50000.0 / 13.0) * viewingConditions.nC * viewingConditions.ncb;
    var p2 = ac / viewingConditions.nbb;
    var hSin = Math.sin(hRad);
    var hCos = Math.cos(hRad);
    var gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin);
    var a = gamma * hCos;
    var b = gamma * hSin;
    var rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
    var gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
    var bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;
    var rCBase = Math.max(0, (27.13 * Math.abs(rA)) / (400.0 - Math.abs(rA)));
    var rC = MathUtils.signum(rA) * (100.0 / viewingConditions.fl) * Math.pow(rCBase, 1.0 / 0.42);
    var gCBase = Math.max(0, (27.13 * Math.abs(gA)) / (400.0 - Math.abs(gA)));
    var gC = MathUtils.signum(gA) * (100.0 / viewingConditions.fl) * Math.pow(gCBase, 1.0 / 0.42);
    var bCBase = Math.max(0, (27.13 * Math.abs(bA)) / (400.0 - Math.abs(bA)));
    var bC = MathUtils.signum(bA) * (100.0 / viewingConditions.fl) * Math.pow(bCBase, 1.0 / 0.42);
    var rF = rC / viewingConditions.rgbD[0];
    var gF = gC / viewingConditions.rgbD[1];
    var bF = bC / viewingConditions.rgbD[2];
    var x = 1.86206786 * rF - 1.01125463 * gF + 0.14918677 * bF;
    var y = 0.38752654 * rF + 0.62144744 * gF - 0.00897398 * bF;
    var z = -0.01584150 * rF - 0.03412294 * gF + 1.04996444 * bF;
    return [x, y, z];
  };

  // ---------------------------------------------------------------------------
  // hct/src/hct_solver.dart
  // ---------------------------------------------------------------------------
  var SCALED_DISCOUNT_FROM_LINRGB = [
    [0.001200833568784504, 0.002389694492170889, 0.0002795742885861124],
    [0.0005891086651375999, 0.0029785502573438758, 0.0003270666104008398],
    [0.00010146692491640572, 0.0005364214359186694, 0.0032979401770712076],
  ];
  var LINRGB_FROM_SCALED_DISCOUNT = [
    [1373.2198709594231, -1100.4251190754821, -7.278681089101213],
    [-271.815969077903, 559.6580465940733, -32.46047482791194],
    [1.9622899599665666, -57.173814538844006, 308.7233197812385],
  ];
  var Y_FROM_LINRGB = [0.2126, 0.7152, 0.0722];
  var CRITICAL_PLANES = [
    0.015176349177441876, 0.045529047532325624, 0.07588174588720938, 0.10623444424209313,
    0.13658714259697685, 0.16693984095186062, 0.19729253930674434, 0.2276452376616281,
    0.2579979360165119, 0.28835063437139563, 0.3188300904430532, 0.350925934958123,
    0.3848314933096426, 0.42057480301049466, 0.458183274052838, 0.4976837250274023,
    0.5391024159806381, 0.5824650784040898, 0.6277969426914107, 0.6751227633498623,
    0.7244668422128921, 0.775853049866786, 0.829304845476233, 0.8848452951698498,
    0.942497089126609, 1.0022825574869039, 1.0642236851973577, 1.1283421258858297,
    1.1946592148522128, 1.2631959812511864, 1.3339731595349034, 1.407011200216447,
    1.4823302800086415, 1.5599503113873272, 1.6398909516233677, 1.7221716113234105,
    1.8068114625156377, 1.8938294463134073, 1.9832442801866852, 2.075074464868551,
    2.1693382909216234, 2.2660538449872063, 2.36523901573795, 2.4669114995532007,
    2.5710888059345764, 2.6777882626779785, 2.7870270208169257, 2.898822059350997,
    3.0131901897720907, 3.1301480604002863, 3.2497121605402226, 3.3718988244681087,
    3.4967242352587946, 3.624204428461639, 3.754355295633311, 3.887192587735158,
    4.022731918402185, 4.160988767090289, 4.301978482107941, 4.445716283538092,
    4.592217266055746, 4.741496401646282, 4.893568542229298, 5.048448422192488,
    5.20615066083972, 5.3666897647573375, 5.5300801301023865, 5.696336044816294,
    5.865471690767354, 6.037501145825082, 6.212438385869475, 6.390297286737924,
    6.571091626112461, 6.7548350853498045, 6.941541251256611, 7.131223617812143,
    7.323895587840543, 7.5195704746346665, 7.7182615035334345, 7.919981813454504,
    8.124744458384042, 8.332562408825165, 8.543448553206703, 8.757415699253682,
    8.974476575321063, 9.194643831691977, 9.417930041841839, 9.644347703669503,
    9.873909240696694, 10.106627003236781, 10.342513269534024, 10.58158024687427,
    10.8238400726681, 11.069304815507364, 11.317986476196008, 11.569896988756009,
    11.825048221409341, 12.083451977536606, 12.345119996613247, 12.610063955123938,
    12.878295467455942, 13.149826086772048, 13.42466730586372, 13.702830557985108,
    13.984327217668513, 14.269168601521828, 14.55736596900856, 14.848930523210871,
    15.143873411576273, 15.44220572664832, 15.743938506781891, 16.04908273684337,
    16.35764934889634, 16.66964922287304, 16.985093187232053, 17.30399201960269,
    17.62635644741625, 17.95219714852476, 18.281524751807332, 18.614349837764564,
    18.95068293910138, 19.290534541298456, 19.633915083172692, 19.98083495742689,
    20.331304511189067, 20.685334046541502, 21.042933821039977, 21.404114048223256,
    21.76888489811322, 22.137256497705877, 22.50923893145328, 22.884842241736916,
    23.264076429332462, 23.6469514538663, 24.033477234264016, 24.42366364919083,
    24.817520537484558, 25.21505769858089, 25.61628489293138, 26.021211842414342,
    26.429848230738664, 26.842203703840827, 27.258287870275353, 27.678110301598522,
    28.10168053274597, 28.529008062403893, 28.96010235337422, 29.39497283293396,
    29.83362889318845, 30.276079891419332, 30.722335150426627, 31.172403958865512,
    31.62629557157785, 32.08401920991837, 32.54558406207592, 33.010999283389665,
    33.4802739966603, 33.953417292456834, 34.430438229418264, 34.911345834551085,
    35.39614910352207, 35.88485700094671, 36.37747846067349, 36.87402238606382,
    37.37449765026789, 37.87891309649659, 38.38727753828926, 38.89959975977785,
    39.41588851594697, 39.93615253289054, 40.460400508064545, 40.98864111053629,
    41.520882981230194, 42.05713473317016, 42.597404951718396, 43.141702194811224,
    43.6900349931913, 44.24241185063697, 44.798841244188324, 45.35933162437017,
    45.92389141541209, 46.49252901546552, 47.065252796817916, 47.64207110610409,
    48.22299226451468, 48.808024568002054, 49.3971762874833, 49.9904556690408,
    50.587870934119984, 51.189430279724725, 51.79514187861014, 52.40501387947288,
    53.0190544071392, 53.637271562750364, 54.259673423945976, 54.88626804504493,
    55.517063457223934, 56.15206766869424, 56.79128866487574, 57.43473440856916,
    58.08241284012621, 58.734331877617365, 59.39049941699807, 60.05092333227251,
    60.715611475655585, 61.38457167773311, 62.057811747619894, 62.7353394731159,
    63.417162620860914, 64.10328893648692, 64.79372614476921, 65.48848194977529,
    66.18756403501224, 66.89098006357258, 67.59873767827808, 68.31084450182222,
    69.02730813691093, 69.74813616640164, 70.47333615344107, 71.20291564160104,
    71.93688215501312, 72.67524319850172, 73.41800625771542, 74.16517879925733,
    74.9167682708136, 75.67278210128072, 76.43322770089146, 77.1981124613393,
    77.96744375590167, 78.74122893956174, 79.51947534912904, 80.30219030335869,
    81.08938110306934, 81.88105503125999, 82.67721935322541, 83.4778813166706,
    84.28304815182372, 85.09272707154808, 85.90692527145302, 86.72564993000343,
    87.54890820862819, 88.3767072518277, 89.2090541872801, 90.04595612594655,
    90.88742016217518, 91.73345337380438, 92.58406282226491, 93.43925555268066,
    94.29903859396902, 95.16341895893969, 96.03240364439274, 96.9059996312159,
    97.78421388448044, 98.6670533535366, 99.55452497210776,
  ];

  function sanitizeRadians(angle) {
    return (angle + Math.PI * 8) % (Math.PI * 2);
  }

  function trueDelinearized(rgbComponent) {
    var normalized = rgbComponent / 100.0;
    var delinearized = 0.0;
    if (normalized <= 0.0031308) {
      delinearized = normalized * 12.92;
    } else {
      delinearized = 1.055 * Math.pow(normalized, 1.0 / 2.4) - 0.055;
    }
    return delinearized * 255.0;
  }

  function chromaticAdaptation(component) {
    var af = Math.pow(Math.abs(component), 0.42);
    return MathUtils.signum(component) * 400.0 * af / (af + 27.13);
  }

  function hueOf(linrgb) {
    var scaledDiscount = MathUtils.matrixMultiply(linrgb, SCALED_DISCOUNT_FROM_LINRGB);
    var rA = chromaticAdaptation(scaledDiscount[0]);
    var gA = chromaticAdaptation(scaledDiscount[1]);
    var bA = chromaticAdaptation(scaledDiscount[2]);
    var a = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    var b = (rA + gA - 2.0 * bA) / 9.0;
    return Math.atan2(b, a);
  }

  function areInCyclicOrder(a, b, c) {
    var deltaAB = sanitizeRadians(b - a);
    var deltaAC = sanitizeRadians(c - a);
    return deltaAB < deltaAC;
  }

  function intercept(source, mid, target) {
    return (mid - source) / (target - source);
  }

  function lerpPoint(source, t, target) {
    return [
      source[0] + (target[0] - source[0]) * t,
      source[1] + (target[1] - source[1]) * t,
      source[2] + (target[2] - source[2]) * t,
    ];
  }

  function setCoordinate(source, coordinate, target, axis) {
    var t = intercept(source[axis], coordinate, target[axis]);
    return lerpPoint(source, t, target);
  }

  function isBounded(x) {
    return 0.0 <= x && x <= 100.0;
  }

  function nthVertex(y, n) {
    var kR = Y_FROM_LINRGB[0];
    var kG = Y_FROM_LINRGB[1];
    var kB = Y_FROM_LINRGB[2];
    var coordA = n % 4 <= 1 ? 0.0 : 100.0;
    var coordB = n % 2 === 0 ? 0.0 : 100.0;
    if (n < 4) {
      var g1 = coordA;
      var b1 = coordB;
      var r1 = (y - g1 * kG - b1 * kB) / kR;
      if (isBounded(r1)) {
        return [r1, g1, b1];
      } else {
        return [-1.0, -1.0, -1.0];
      }
    } else if (n < 8) {
      var b2 = coordA;
      var r2 = coordB;
      var g2 = (y - r2 * kR - b2 * kB) / kG;
      if (isBounded(g2)) {
        return [r2, g2, b2];
      } else {
        return [-1.0, -1.0, -1.0];
      }
    } else {
      var r3 = coordA;
      var g3 = coordB;
      var b3 = (y - r3 * kR - g3 * kG) / kB;
      if (isBounded(b3)) {
        return [r3, g3, b3];
      } else {
        return [-1.0, -1.0, -1.0];
      }
    }
  }

  function bisectToSegment(y, targetHue) {
    var left = [-1.0, -1.0, -1.0];
    var right = left;
    var leftHue = 0.0;
    var rightHue = 0.0;
    var initialized = false;
    var uncut = true;
    for (var n = 0; n < 12; n++) {
      var mid = nthVertex(y, n);
      if (mid[0] < 0) {
        continue;
      }
      var midHue = hueOf(mid);
      if (!initialized) {
        left = mid;
        right = mid;
        leftHue = midHue;
        rightHue = midHue;
        initialized = true;
        continue;
      }
      if (uncut || areInCyclicOrder(leftHue, midHue, rightHue)) {
        uncut = false;
        if (areInCyclicOrder(leftHue, targetHue, midHue)) {
          right = mid;
          rightHue = midHue;
        } else {
          left = mid;
          leftHue = midHue;
        }
      }
    }
    return [left, right];
  }

  function midpoint(a, b) {
    return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2];
  }

  function criticalPlaneBelow(x) {
    return Math.floor(x - 0.5);
  }

  function criticalPlaneAbove(x) {
    return Math.ceil(x - 0.5);
  }

  function bisectToLimit(y, targetHue) {
    var segment = bisectToSegment(y, targetHue);
    var left = segment[0];
    var leftHue = hueOf(left);
    var right = segment[1];
    for (var axis = 0; axis < 3; axis++) {
      if (left[axis] !== right[axis]) {
        var lPlane = -1;
        var rPlane = 255;
        if (left[axis] < right[axis]) {
          lPlane = criticalPlaneBelow(trueDelinearized(left[axis]));
          rPlane = criticalPlaneAbove(trueDelinearized(right[axis]));
        } else {
          lPlane = criticalPlaneAbove(trueDelinearized(left[axis]));
          rPlane = criticalPlaneBelow(trueDelinearized(right[axis]));
        }
        for (var i = 0; i < 8; i++) {
          if (Math.abs(rPlane - lPlane) <= 1) {
            break;
          } else {
            var mPlane = Math.floor((lPlane + rPlane) / 2.0);
            var midPlaneCoordinate = CRITICAL_PLANES[mPlane];
            var mid = setCoordinate(left, midPlaneCoordinate, right, axis);
            var midHue = hueOf(mid);
            if (areInCyclicOrder(leftHue, targetHue, midHue)) {
              right = mid;
              rPlane = mPlane;
            } else {
              left = mid;
              leftHue = midHue;
              lPlane = mPlane;
            }
          }
        }
      }
    }
    return midpoint(left, right);
  }

  function inverseChromaticAdaptation(adapted) {
    var adaptedAbs = Math.abs(adapted);
    var base = Math.max(0, 27.13 * adaptedAbs / (400.0 - adaptedAbs));
    return MathUtils.signum(adapted) * Math.pow(base, 1.0 / 0.42);
  }

  function findResultByJ(hueRadians, chroma, y) {
    var j = Math.sqrt(y) * 11.0;
    var viewingConditions = VIEWING_STANDARD;
    var tInnerCoeff = 1 / Math.pow(1.64 - Math.pow(0.29, viewingConditions.backgroundYTowhitePointY), 0.73);
    var eHue = 0.25 * (Math.cos(hueRadians + 2.0) + 3.8);
    var p1 = eHue * (50000.0 / 13.0) * viewingConditions.nC * viewingConditions.ncb;
    var hSin = Math.sin(hueRadians);
    var hCos = Math.cos(hueRadians);
    for (var iterationRound = 0; iterationRound < 5; iterationRound++) {
      var jNormalized = j / 100.0;
      var alpha = chroma === 0.0 || j === 0.0 ? 0.0 : chroma / Math.sqrt(jNormalized);
      var t = Math.pow(alpha * tInnerCoeff, 1.0 / 0.9);
      var ac = viewingConditions.aw *
        Math.pow(jNormalized, 1.0 / viewingConditions.c / viewingConditions.z);
      var p2 = ac / viewingConditions.nbb;
      var gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin);
      var a = gamma * hCos;
      var b = gamma * hSin;
      var rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
      var gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
      var bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;
      var rCScaled = inverseChromaticAdaptation(rA);
      var gCScaled = inverseChromaticAdaptation(gA);
      var bCScaled = inverseChromaticAdaptation(bA);
      var linrgb = MathUtils.matrixMultiply([rCScaled, gCScaled, bCScaled], LINRGB_FROM_SCALED_DISCOUNT);
      if (linrgb[0] < 0 || linrgb[1] < 0 || linrgb[2] < 0) {
        return 0;
      }
      var kR = Y_FROM_LINRGB[0];
      var kG = Y_FROM_LINRGB[1];
      var kB = Y_FROM_LINRGB[2];
      var fnj = kR * linrgb[0] + kG * linrgb[1] + kB * linrgb[2];
      if (fnj <= 0) {
        return 0;
      }
      if (iterationRound === 4 || Math.abs(fnj - y) < 0.002) {
        if (linrgb[0] > 100.01 || linrgb[1] > 100.01 || linrgb[2] > 100.01) {
          return 0;
        }
        return ColorUtils.argbFromLinrgb(linrgb);
      }
      j = j - (fnj - y) * j / (2 * fnj);
    }
    return 0;
  }

  var HctSolver = {
    solveToInt: function (hueDegrees, chroma, lstar) {
      if (chroma < 0.0001 || lstar < 0.0001 || lstar > 99.9999) {
        return ColorUtils.argbFromLstar(lstar);
      }
      hueDegrees = MathUtils.sanitizeDegreesDouble(hueDegrees);
      var hueRadians = hueDegrees / 180 * Math.PI;
      var y = ColorUtils.yFromLstar(lstar);
      var exactAnswer = findResultByJ(hueRadians, chroma, y);
      if (exactAnswer !== 0) {
        return exactAnswer;
      }
      var linrgb = bisectToLimit(y, hueRadians);
      return ColorUtils.argbFromLinrgb(linrgb);
    },
    solveToCam: function (hueDegrees, chroma, lstar) {
      return Cam16.fromInt(HctSolver.solveToInt(hueDegrees, chroma, lstar));
    },
  };

  // ---------------------------------------------------------------------------
  // hct/hct.dart（只读；Dart 版的 hue/chroma/tone setter 在动态配色路径上不用）
  // ---------------------------------------------------------------------------
  function Hct(argb) {
    argb = argb >>> 0;
    var cam16 = Cam16.fromInt(argb);
    this._argb = argb;
    this.hue = cam16.hue;
    this.chroma = cam16.chroma;
    this.tone = ColorUtils.lstarFromArgb(argb);
  }
  Hct.from = function (hue, chroma, tone) {
    return new Hct(HctSolver.solveToInt(hue, chroma, tone));
  };
  Hct.fromInt = function (argb) {
    return new Hct(argb);
  };
  Hct.prototype.toInt = function () {
    return this._argb;
  };

  // ---------------------------------------------------------------------------
  // palettes/tonal_palette.dart（含 KeyColor）
  // ---------------------------------------------------------------------------
  function KeyColor(hue, requestedChroma) {
    this.hue = hue;
    this.requestedChroma = requestedChroma;
    this._chromaCache = new Map();
    this._maxChromaValue = 200.0;
  }
  KeyColor.prototype.create = function () {
    var pivotTone = 50;
    var toneStepSize = 1;
    var epsilon = 0.01;
    var lowerTone = 0;
    var upperTone = 100;
    while (lowerTone < upperTone) {
      var midTone = Math.trunc((lowerTone + upperTone) / 2);
      var isAscending = this._maxChroma(midTone) < this._maxChroma(midTone + toneStepSize);
      var sufficientChroma = this._maxChroma(midTone) >= this.requestedChroma - epsilon;
      if (sufficientChroma) {
        if (Math.abs(lowerTone - pivotTone) < Math.abs(upperTone - pivotTone)) {
          upperTone = midTone;
        } else {
          if (lowerTone === midTone) {
            return Hct.from(this.hue, this.requestedChroma, lowerTone);
          }
          lowerTone = midTone;
        }
      } else {
        if (isAscending) {
          lowerTone = midTone + toneStepSize;
        } else {
          upperTone = midTone;
        }
      }
    }
    return Hct.from(this.hue, this.requestedChroma, lowerTone);
  };
  KeyColor.prototype._maxChroma = function (tone) {
    var cached = this._chromaCache.get(tone);
    if (cached !== undefined) return cached;
    var value = Hct.from(this.hue, this._maxChromaValue, tone).chroma;
    this._chromaCache.set(tone, value);
    return value;
  };

  // keyColor 在 Dart 里构造即求值；这里改成首次访问才求（纯函数、结果相同），
  // 省掉动态配色路径上用不到它的二分搜索开销。
  function TonalPalette(hue, chroma, keyColorHct) {
    this.hue = hue;
    this.chroma = chroma;
    this._keyColor = keyColorHct || null;
    this._cache = new Map();
  }
  Object.defineProperty(TonalPalette.prototype, 'keyColor', {
    get: function () {
      if (!this._keyColor) this._keyColor = new KeyColor(this.hue, this.chroma).create();
      return this._keyColor;
    },
  });
  TonalPalette.of = function (hue, chroma) {
    return new TonalPalette(hue, chroma, null);
  };
  TonalPalette.fromHueAndChroma = TonalPalette.of;
  TonalPalette.fromHct = function (hct) {
    return new TonalPalette(hct.hue, hct.chroma, hct);
  };
  // Dart 的 get(int) 与 getHct(double) 都等价于 Hct.from(hue, chroma, tone)（缓存只是记忆化）。
  TonalPalette.prototype.tone = function (tone) {
    var cached = this._cache.get(tone);
    if (cached !== undefined) return cached;
    var argb = HctSolver.solveToInt(this.hue, this.chroma, tone);
    this._cache.set(tone, argb);
    return argb;
  };
  TonalPalette.prototype.get = TonalPalette.prototype.tone;
  TonalPalette.prototype.getHct = function (tone) {
    return Hct.fromInt(this.tone(tone));
  };

  // ---------------------------------------------------------------------------
  // dislike/dislike_analyzer.dart
  // ---------------------------------------------------------------------------
  var DislikeAnalyzer = {
    isDisliked: function (hct) {
      var huePasses = dartRound(hct.hue) >= 90.0 && dartRound(hct.hue) <= 111.0;
      var chromaPasses = dartRound(hct.chroma) > 16.0;
      var tonePasses = dartRound(hct.tone) < 65.0;
      return huePasses && chromaPasses && tonePasses;
    },
    fixIfDisliked: function (hct) {
      if (DislikeAnalyzer.isDisliked(hct)) {
        return Hct.from(hct.hue, hct.chroma, 70.0);
      }
      return hct;
    },
  };

  // ---------------------------------------------------------------------------
  // temperature/temperature_cache.dart（Map<Hct, double> 以 ARGB 为键，与 Dart Hct == 同口径）
  // ---------------------------------------------------------------------------
  function TemperatureCache(input) {
    this.input = input;
    this._hctsByTemp = [];
    this._hctsByHue = [];
    this._tempsByHct = null;
    this._inputRelativeTemperature = -1.0;
    this._complement = null;
  }
  TemperatureCache.isBetween = function (angle, a, b) {
    if (a < b) {
      return a <= angle && angle <= b;
    }
    return a <= angle || angle <= b;
  };
  TemperatureCache.rawTemperature = function (color) {
    var lab = ColorUtils.labFromArgb(color.toInt());
    var hue = MathUtils.sanitizeDegreesDouble(Math.atan2(lab[2], lab[1]) * 180.0 / Math.PI);
    var chroma = Math.sqrt((lab[1] * lab[1]) + (lab[2] * lab[2]));
    var temperature = -0.5 +
      0.02 *
      Math.pow(chroma, 1.07) *
      Math.cos(MathUtils.sanitizeDegreesDouble(hue - 50.0) * Math.PI / 180.0);
    return temperature;
  };
  TemperatureCache.prototype.warmest = function () {
    var list = this.hctsByTemp();
    return list[list.length - 1];
  };
  TemperatureCache.prototype.coldest = function () {
    return this.hctsByTemp()[0];
  };
  TemperatureCache.prototype.tempOf = function (hct) {
    return this.tempsByHct().get(hct.toInt());
  };
  TemperatureCache.prototype.analogous = function (count, divisions) {
    if (count == null) count = 5;
    if (divisions == null) divisions = 12;
    var startHue = dartRound(this.input.hue);
    var hctsByHue = this.hctsByHue();
    var startHct = hctsByHue[startHue];
    var lastTemp = this.relativeTemperature(startHct);
    var allColors = [startHct];
    var absoluteTotalTempDelta = 0.0;
    var i;
    for (i = 0; i < 360; i++) {
      var hue0 = MathUtils.sanitizeDegreesInt(startHue + i);
      var hct0 = hctsByHue[hue0];
      var temp0 = this.relativeTemperature(hct0);
      var tempDelta0 = Math.abs(temp0 - lastTemp);
      lastTemp = temp0;
      absoluteTotalTempDelta += tempDelta0;
    }
    var hueAddend = 1;
    var tempStep = absoluteTotalTempDelta / divisions;
    var totalTempDelta = 0.0;
    lastTemp = this.relativeTemperature(startHct);
    while (allColors.length < divisions) {
      var hue = MathUtils.sanitizeDegreesInt(startHue + hueAddend);
      var hct = hctsByHue[hue];
      var temp = this.relativeTemperature(hct);
      var tempDelta = Math.abs(temp - lastTemp);
      totalTempDelta += tempDelta;
      var desiredTotalTempDeltaForIndex = allColors.length * tempStep;
      var indexSatisfied = totalTempDelta >= desiredTotalTempDeltaForIndex;
      var indexAddend = 1;
      while (indexSatisfied && allColors.length < divisions) {
        allColors.push(hct);
        var desired = (allColors.length + indexAddend) * tempStep;
        indexSatisfied = totalTempDelta >= desired;
        indexAddend++;
      }
      lastTemp = temp;
      hueAddend++;
      if (hueAddend > 360) {
        while (allColors.length < divisions) {
          allColors.push(hct);
        }
        break;
      }
    }
    var answers = [this.input];
    var increaseHueCount = Math.floor((count - 1) / 2.0);
    var index;
    for (i = 1; i < (increaseHueCount + 1); i++) {
      index = 0 - i;
      while (index < 0) {
        index = allColors.length + index;
      }
      if (index >= allColors.length) {
        index = index % allColors.length;
      }
      answers.unshift(allColors[index]);
    }
    var decreaseHueCount = count - increaseHueCount - 1;
    for (i = 1; i < (decreaseHueCount + 1); i++) {
      index = i;
      while (index < 0) {
        index = allColors.length + index;
      }
      if (index >= allColors.length) {
        index = index % allColors.length;
      }
      answers.push(allColors[index]);
    }
    return answers;
  };
  TemperatureCache.prototype.complement = function () {
    if (this._complement != null) {
      return this._complement;
    }
    var coldest = this.coldest();
    var warmest = this.warmest();
    var coldestHue = coldest.hue;
    var coldestTemp = this.tempOf(coldest);
    var warmestHue = warmest.hue;
    var warmestTemp = this.tempOf(warmest);
    var range = warmestTemp - coldestTemp;
    var startHueIsColdestToWarmest = TemperatureCache.isBetween(this.input.hue, coldestHue, warmestHue);
    var startHue = startHueIsColdestToWarmest ? warmestHue : coldestHue;
    var endHue = startHueIsColdestToWarmest ? coldestHue : warmestHue;
    var directionOfRotation = 1.0;
    var smallestError = 1000.0;
    var hctsByHue = this.hctsByHue();
    var answer = hctsByHue[dartRound(this.input.hue)];
    var complementRelativeTemp = 1.0 - this.inputRelativeTemperature();
    for (var hueAddend = 0.0; hueAddend <= 360.0; hueAddend += 1.0) {
      var hue = MathUtils.sanitizeDegreesDouble(startHue + directionOfRotation * hueAddend);
      if (!TemperatureCache.isBetween(hue, startHue, endHue)) {
        continue;
      }
      var possibleAnswer = hctsByHue[dartRound(hue)];
      var relativeTemp = (this.tempOf(possibleAnswer) - coldestTemp) / range;
      var error = Math.abs(complementRelativeTemp - relativeTemp);
      if (error < smallestError) {
        smallestError = error;
        answer = possibleAnswer;
      }
    }
    this._complement = answer;
    return this._complement;
  };
  TemperatureCache.prototype.relativeTemperature = function (hct) {
    var range = this.tempOf(this.warmest()) - this.tempOf(this.coldest());
    var differenceFromColdest = this.tempOf(hct) - this.tempOf(this.coldest());
    if (range === 0.0) {
      return 0.5;
    }
    return differenceFromColdest / range;
  };
  TemperatureCache.prototype.inputRelativeTemperature = function () {
    if (this._inputRelativeTemperature >= 0.0) {
      return this._inputRelativeTemperature;
    }
    var coldestTemp = this.tempOf(this.coldest());
    var range = this.tempOf(this.warmest()) - coldestTemp;
    var differenceFromColdest = this.tempOf(this.input) - coldestTemp;
    var inputRelativeTemp = range === 0.0 ? 0.5 : differenceFromColdest / range;
    this._inputRelativeTemperature = inputRelativeTemp;
    return this._inputRelativeTemperature;
  };
  TemperatureCache.prototype.hctsByTemp = function () {
    if (this._hctsByTemp.length > 0) {
      return this._hctsByTemp;
    }
    var hcts = this.hctsByHue().slice();
    hcts.push(this.input);
    var temps = this.tempsByHct();
    hcts.sort(function (a, b) {
      var ta = temps.get(a.toInt());
      var tb = temps.get(b.toInt());
      return ta < tb ? -1 : (ta > tb ? 1 : 0);
    });
    this._hctsByTemp = hcts;
    return this._hctsByTemp;
  };
  TemperatureCache.prototype.tempsByHct = function () {
    if (this._tempsByHct) {
      return this._tempsByHct;
    }
    var allHcts = this.hctsByHue().slice();
    allHcts.push(this.input);
    var map = new Map();
    for (var i = 0; i < allHcts.length; i++) {
      map.set(allHcts[i].toInt(), TemperatureCache.rawTemperature(allHcts[i]));
    }
    this._tempsByHct = map;
    return this._tempsByHct;
  };
  TemperatureCache.prototype.hctsByHue = function () {
    if (this._hctsByHue.length > 0) {
      return this._hctsByHue;
    }
    var hcts = [];
    for (var hue = 0.0; hue <= 360.0; hue += 1.0) {
      hcts.push(Hct.from(hue, this.input.chroma, this.input.tone));
    }
    this._hctsByHue = hcts;
    return this._hctsByHue;
  };

  // ---------------------------------------------------------------------------
  // contrast/contrast.dart
  // ---------------------------------------------------------------------------
  function ratioOfYs(y1, y2) {
    var lighter = y1 > y2 ? y1 : y2;
    var darker = lighter === y2 ? y1 : y2;
    return (lighter + 5.0) / (darker + 5.0);
  }
  var Contrast = {
    ratioOfTones: function (toneA, toneB) {
      toneA = MathUtils.clampDouble(0.0, 100.0, toneA);
      toneB = MathUtils.clampDouble(0.0, 100.0, toneB);
      return ratioOfYs(ColorUtils.yFromLstar(toneA), ColorUtils.yFromLstar(toneB));
    },
    lighter: function (tone, ratio) {
      if (tone < 0.0 || tone > 100.0) {
        return -1.0;
      }
      var darkY = ColorUtils.yFromLstar(tone);
      var lightY = ratio * (darkY + 5.0) - 5.0;
      var realContrast = ratioOfYs(lightY, darkY);
      var delta = Math.abs(realContrast - ratio);
      if (realContrast < ratio && delta > 0.04) {
        return -1;
      }
      var returnValue = ColorUtils.lstarFromY(lightY) + 0.4;
      if (returnValue < 0 || returnValue > 100) {
        return -1;
      }
      return returnValue;
    },
    darker: function (tone, ratio) {
      if (tone < 0.0 || tone > 100.0) {
        return -1.0;
      }
      var lightY = ColorUtils.yFromLstar(tone);
      var darkY = ((lightY + 5.0) / ratio) - 5.0;
      var realContrast = ratioOfYs(lightY, darkY);
      var delta = Math.abs(realContrast - ratio);
      if (realContrast < ratio && delta > 0.04) {
        return -1;
      }
      var returnValue = ColorUtils.lstarFromY(darkY) - 0.4;
      if (returnValue < 0 || returnValue > 100) {
        return -1;
      }
      return returnValue;
    },
    lighterUnsafe: function (tone, ratio) {
      var lighterSafe = Contrast.lighter(tone, ratio);
      return lighterSafe < 0.0 ? 100.0 : lighterSafe;
    },
    darkerUnsafe: function (tone, ratio) {
      var darkerSafe = Contrast.darker(tone, ratio);
      return darkerSafe < 0.0 ? 0.0 : darkerSafe;
    },
  };

  // ---------------------------------------------------------------------------
  // dynamiccolor/src/contrast_curve.dart、tone_delta_pair.dart、variant.dart
  // ---------------------------------------------------------------------------
  function ContrastCurve(low, normal, medium, high) {
    this.low = low;
    this.normal = normal;
    this.medium = medium;
    this.high = high;
  }
  ContrastCurve.prototype.get = function (contrastLevel) {
    if (contrastLevel <= -1.0) {
      return this.low;
    } else if (contrastLevel < 0.0) {
      return MathUtils.lerp(this.low, this.normal, (contrastLevel - (-1)) / 1);
    } else if (contrastLevel < 0.5) {
      return MathUtils.lerp(this.normal, this.medium, (contrastLevel - 0) / 0.5);
    } else if (contrastLevel < 1.0) {
      return MathUtils.lerp(this.medium, this.high, (contrastLevel - 0.5) / 0.5);
    } else {
      return this.high;
    }
  };

  var TonePolarity = { darker: 'darker', lighter: 'lighter', nearer: 'nearer', farther: 'farther' };

  function ToneDeltaPair(roleA, roleB, delta, polarity, stayTogether) {
    this.roleA = roleA;
    this.roleB = roleB;
    this.delta = delta;
    this.polarity = polarity;
    this.stayTogether = stayTogether;
  }

  var Variant = {
    monochrome: 'monochrome',
    neutral: 'neutral',
    tonalSpot: 'tonalSpot',
    vibrant: 'vibrant',
    expressive: 'expressive',
    content: 'content',
    fidelity: 'fidelity',
    rainbow: 'rainbow',
    fruitSalad: 'fruitSalad',
  };

  // ---------------------------------------------------------------------------
  // dynamiccolor/dynamic_color.dart
  // （Dart 的 _hctCache 以 scheme 为键做记忆化；这里改为挂在 scheme 上的 Map，结果相同）
  // ---------------------------------------------------------------------------
  function DynamicColor(opts) {
    this.name = opts.name || '';
    this.palette = opts.palette;
    this.tone = opts.tone;
    this.isBackground = !!opts.isBackground;
    this.background = opts.background || null;
    this.secondBackground = opts.secondBackground || null;
    this.contrastCurve = opts.contrastCurve || null;
    this.toneDeltaPair = opts.toneDeltaPair || null;
  }
  DynamicColor.fromPalette = function (opts) {
    return new DynamicColor(opts);
  };
  DynamicColor.prototype.getArgb = function (scheme) {
    return this.getHct(scheme).toInt();
  };
  DynamicColor.prototype.getHct = function (scheme) {
    var cache = scheme._hctCache;
    var cachedAnswer = cache.get(this);
    if (cachedAnswer) {
      return cachedAnswer;
    }
    var tone = this.getTone(scheme);
    var answer = this.palette(scheme).getHct(tone);
    cache.set(this, answer);
    return answer;
  };
  DynamicColor.prototype.getTone = function (scheme) {
    var decreasingContrast = scheme.contrastLevel < 0;
    if (this.toneDeltaPair != null) {
      var pair = this.toneDeltaPair(scheme);
      var roleA = pair.roleA;
      var roleB = pair.roleB;
      var delta = pair.delta;
      var polarity = pair.polarity;
      var stayTogether = pair.stayTogether;
      var bg = this.background(scheme);
      var bgTone = bg.getTone(scheme);
      var aIsNearer =
        polarity === TonePolarity.nearer ||
        (polarity === TonePolarity.lighter && !scheme.isDark) ||
        (polarity === TonePolarity.darker && scheme.isDark);
      var nearer = aIsNearer ? roleA : roleB;
      var farther = aIsNearer ? roleB : roleA;
      var amNearer = this.name === nearer.name;
      var expansionDir = scheme.isDark ? 1 : -1;
      var nContrast = nearer.contrastCurve.get(scheme.contrastLevel);
      var fContrast = farther.contrastCurve.get(scheme.contrastLevel);
      var nInitialTone = nearer.tone(scheme);
      var nTone = Contrast.ratioOfTones(bgTone, nInitialTone) >= nContrast
        ? nInitialTone
        : DynamicColor.foregroundTone(bgTone, nContrast);
      var fInitialTone = farther.tone(scheme);
      var fTone = Contrast.ratioOfTones(bgTone, fInitialTone) >= fContrast
        ? fInitialTone
        : DynamicColor.foregroundTone(bgTone, fContrast);
      if (decreasingContrast) {
        nTone = DynamicColor.foregroundTone(bgTone, nContrast);
        fTone = DynamicColor.foregroundTone(bgTone, fContrast);
      }
      if ((fTone - nTone) * expansionDir >= delta) {
        // Good! Tones satisfy the constraint; no change needed.
      } else {
        fTone = MathUtils.clampDouble(0, 100, nTone + delta * expansionDir);
        if ((fTone - nTone) * expansionDir >= delta) {
          // Good! Tones now satisfy the constraint; no change needed.
        } else {
          nTone = MathUtils.clampDouble(0, 100, fTone - delta * expansionDir);
        }
      }
      if (50 <= nTone && nTone < 60) {
        if (expansionDir > 0) {
          nTone = 60;
          fTone = Math.max(fTone, nTone + delta * expansionDir);
        } else {
          nTone = 49;
          fTone = Math.min(fTone, nTone + delta * expansionDir);
        }
      } else if (50 <= fTone && fTone < 60) {
        if (stayTogether) {
          if (expansionDir > 0) {
            nTone = 60;
            fTone = Math.max(fTone, nTone + delta * expansionDir);
          } else {
            nTone = 49;
            fTone = Math.min(fTone, nTone + delta * expansionDir);
          }
        } else {
          if (expansionDir > 0) {
            fTone = 60;
          } else {
            fTone = 49;
          }
        }
      }
      return amNearer ? nTone : fTone;
    } else {
      var answer = this.tone(scheme);
      if (this.background == null) {
        return answer;
      }
      var bgTone2 = this.background(scheme).getTone(scheme);
      var desiredRatio = this.contrastCurve.get(scheme.contrastLevel);
      if (Contrast.ratioOfTones(bgTone2, answer) >= desiredRatio) {
        // Don't "improve" what's good enough.
      } else {
        answer = DynamicColor.foregroundTone(bgTone2, desiredRatio);
      }
      if (decreasingContrast) {
        answer = DynamicColor.foregroundTone(bgTone2, desiredRatio);
      }
      if (this.isBackground && 50 <= answer && answer < 60) {
        if (Contrast.ratioOfTones(49, bgTone2) >= desiredRatio) {
          answer = 49;
        } else {
          answer = 60;
        }
      }
      if (this.secondBackground != null) {
        var bgTone1 = this.background(scheme).getTone(scheme);
        var bgToneB = this.secondBackground(scheme).getTone(scheme);
        var upper = Math.max(bgTone1, bgToneB);
        var lower = Math.min(bgTone1, bgToneB);
        if (Contrast.ratioOfTones(upper, answer) >= desiredRatio &&
          Contrast.ratioOfTones(lower, answer) >= desiredRatio) {
          return answer;
        }
        var lightOption = Contrast.lighter(upper, desiredRatio);
        var darkOption = Contrast.darker(lower, desiredRatio);
        var availables = [];
        if (lightOption !== -1) availables.push(lightOption);
        if (darkOption !== -1) availables.push(darkOption);
        var prefersLight =
          DynamicColor.tonePrefersLightForeground(bgTone1) ||
          DynamicColor.tonePrefersLightForeground(bgToneB);
        if (prefersLight) {
          return lightOption < 0 ? 100 : lightOption;
        }
        if (availables.length === 1) {
          return availables[0];
        }
        return darkOption < 0 ? 0 : darkOption;
      }
      return answer;
    }
  };
  DynamicColor.foregroundTone = function (bgTone, ratio) {
    var lighterTone = Contrast.lighterUnsafe(bgTone, ratio);
    var darkerTone = Contrast.darkerUnsafe(bgTone, ratio);
    var lighterRatio = Contrast.ratioOfTones(lighterTone, bgTone);
    var darkerRatio = Contrast.ratioOfTones(darkerTone, bgTone);
    var preferLighter = DynamicColor.tonePrefersLightForeground(bgTone);
    if (preferLighter) {
      var negligibleDifference =
        Math.abs(lighterRatio - darkerRatio) < 0.1 &&
        lighterRatio < ratio &&
        darkerRatio < ratio;
      return lighterRatio >= ratio || lighterRatio >= darkerRatio || negligibleDifference
        ? lighterTone
        : darkerTone;
    } else {
      return darkerRatio >= ratio || darkerRatio >= lighterRatio
        ? darkerTone
        : lighterTone;
    }
  };
  DynamicColor.enableLightForeground = function (tone) {
    if (DynamicColor.tonePrefersLightForeground(tone) && !DynamicColor.toneAllowsLightForeground(tone)) {
      return 49.0;
    }
    return tone;
  };
  DynamicColor.tonePrefersLightForeground = function (tone) {
    return dartRound(tone) < 60;
  };
  DynamicColor.toneAllowsLightForeground = function (tone) {
    return dartRound(tone) <= 49;
  };

  // ---------------------------------------------------------------------------
  // dynamiccolor/dynamic_scheme.dart
  // ---------------------------------------------------------------------------
  function DynamicScheme(opts) {
    this.sourceColorHct = opts.sourceColorHct;
    this.sourceColorArgb = opts.sourceColorHct.toInt();
    this.variant = opts.variant;
    this.contrastLevel = opts.contrastLevel == null ? 0.0 : opts.contrastLevel;
    this.isDark = opts.isDark;
    this.primaryPalette = opts.primaryPalette;
    this.secondaryPalette = opts.secondaryPalette;
    this.tertiaryPalette = opts.tertiaryPalette;
    this.neutralPalette = opts.neutralPalette;
    this.neutralVariantPalette = opts.neutralVariantPalette;
    this.errorPalette = opts.errorPalette || TonalPalette.of(25.0, 84.0);
    this._hctCache = new Map();
  }
  DynamicScheme.getRotatedHue = function (sourceColor, hues, rotations) {
    var sourceHue = sourceColor.hue;
    if (rotations.length === 1) {
      return MathUtils.sanitizeDegreesDouble(sourceColor.hue + rotations[0]);
    }
    var size = hues.length;
    for (var i = 0; i <= (size - 2); i++) {
      var thisHue = hues[i];
      var nextHue = hues[i + 1];
      if (thisHue < sourceHue && sourceHue < nextHue) {
        return MathUtils.sanitizeDegreesDouble(sourceHue + rotations[i]);
      }
    }
    return sourceHue;
  };
  DynamicScheme.prototype.getHct = function (dynamicColor) {
    return dynamicColor.getHct(this);
  };
  DynamicScheme.prototype.getArgb = function (dynamicColor) {
    return dynamicColor.getArgb(this);
  };

  // ---------------------------------------------------------------------------
  // dynamiccolor/material_dynamic_colors.dart
  // ---------------------------------------------------------------------------
  function isFidelity(scheme) {
    return scheme.variant === Variant.fidelity || scheme.variant === Variant.content;
  }
  function isMonochrome(scheme) {
    return scheme.variant === Variant.monochrome;
  }
  function findDesiredChromaByTone(hue, chroma, tone, byDecreasingTone) {
    var answer = tone;
    var closestToChroma = Hct.from(hue, chroma, tone);
    if (closestToChroma.chroma < chroma) {
      var chromaPeak = closestToChroma.chroma;
      while (closestToChroma.chroma < chroma) {
        answer += byDecreasingTone ? -1.0 : 1.0;
        var potentialSolution = Hct.from(hue, chroma, answer);
        if (chromaPeak > potentialSolution.chroma) {
          break;
        }
        if (Math.abs(potentialSolution.chroma - chroma) < 0.4) {
          break;
        }
        var potentialDelta = Math.abs(potentialSolution.chroma - chroma);
        var currentDelta = Math.abs(closestToChroma.chroma - chroma);
        if (potentialDelta < currentDelta) {
          closestToChroma = potentialSolution;
        }
        chromaPeak = Math.max(chromaPeak, potentialSolution.chroma);
      }
    }
    return answer;
  }

  var MDC = {};
  MDC.contentAccentToneDelta = 15.0;
  MDC.highestSurface = function (s) {
    return s.isDark ? MDC.surfaceBright : MDC.surfaceDim;
  };
  function dc(opts) {
    return DynamicColor.fromPalette(opts);
  }
  function neutral(s) { return s.neutralPalette; }
  function neutralVariant(s) { return s.neutralVariantPalette; }
  function primaryP(s) { return s.primaryPalette; }
  function secondaryP(s) { return s.secondaryPalette; }
  function tertiaryP(s) { return s.tertiaryPalette; }
  function errorP(s) { return s.errorPalette; }

  MDC.primaryPaletteKeyColor = dc({
    name: 'primary_palette_key_color',
    palette: primaryP,
    tone: function (s) { return s.primaryPalette.keyColor.tone; },
  });
  MDC.secondaryPaletteKeyColor = dc({
    name: 'secondary_palette_key_color',
    palette: secondaryP,
    tone: function (s) { return s.secondaryPalette.keyColor.tone; },
  });
  MDC.tertiaryPaletteKeyColor = dc({
    name: 'tertiary_palette_key_color',
    palette: tertiaryP,
    tone: function (s) { return s.tertiaryPalette.keyColor.tone; },
  });
  MDC.neutralPaletteKeyColor = dc({
    name: 'neutral_palette_key_color',
    palette: neutral,
    tone: function (s) { return s.neutralPalette.keyColor.tone; },
  });
  MDC.neutralVariantPaletteKeyColor = dc({
    name: 'neutral_variant_palette_key_color',
    palette: neutralVariant,
    tone: function (s) { return s.neutralVariantPalette.keyColor.tone; },
  });
  MDC.background = dc({
    name: 'background',
    palette: neutral,
    tone: function (s) { return s.isDark ? 6 : 98; },
    isBackground: true,
  });
  MDC.onBackground = dc({
    name: 'on_background',
    palette: neutral,
    tone: function (s) { return s.isDark ? 90 : 10; },
    background: function () { return MDC.background; },
    contrastCurve: new ContrastCurve(3, 3, 4.5, 7),
  });
  MDC.surface = dc({
    name: 'surface',
    palette: neutral,
    tone: function (s) { return s.isDark ? 6 : 98; },
    isBackground: true,
  });
  MDC.surfaceDim = dc({
    name: 'surface_dim',
    palette: neutral,
    tone: function (s) { return s.isDark ? 6 : new ContrastCurve(87, 87, 80, 75).get(s.contrastLevel); },
    isBackground: true,
  });
  MDC.surfaceBright = dc({
    name: 'surface_bright',
    palette: neutral,
    tone: function (s) { return s.isDark ? new ContrastCurve(24, 24, 29, 34).get(s.contrastLevel) : 98; },
    isBackground: true,
  });
  MDC.surfaceContainerLowest = dc({
    name: 'surface_container_lowest',
    palette: neutral,
    tone: function (s) { return s.isDark ? new ContrastCurve(4, 4, 2, 0).get(s.contrastLevel) : 100; },
    isBackground: true,
  });
  MDC.surfaceContainerLow = dc({
    name: 'surface_container_low',
    palette: neutral,
    tone: function (s) {
      return s.isDark
        ? new ContrastCurve(10, 10, 11, 12).get(s.contrastLevel)
        : new ContrastCurve(96, 96, 96, 95).get(s.contrastLevel);
    },
    isBackground: true,
  });
  MDC.surfaceContainer = dc({
    name: 'surface_container',
    palette: neutral,
    tone: function (s) {
      return s.isDark
        ? new ContrastCurve(12, 12, 16, 20).get(s.contrastLevel)
        : new ContrastCurve(94, 94, 92, 90).get(s.contrastLevel);
    },
    isBackground: true,
  });
  MDC.surfaceContainerHigh = dc({
    name: 'surface_container_high',
    palette: neutral,
    tone: function (s) {
      return s.isDark
        ? new ContrastCurve(17, 17, 21, 25).get(s.contrastLevel)
        : new ContrastCurve(92, 92, 88, 85).get(s.contrastLevel);
    },
    isBackground: true,
  });
  MDC.surfaceContainerHighest = dc({
    name: 'surface_container_highest',
    palette: neutral,
    tone: function (s) {
      return s.isDark
        ? new ContrastCurve(22, 22, 26, 30).get(s.contrastLevel)
        : new ContrastCurve(90, 90, 84, 80).get(s.contrastLevel);
    },
    isBackground: true,
  });
  MDC.onSurface = dc({
    name: 'on_surface',
    palette: neutral,
    tone: function (s) { return s.isDark ? 90 : 10; },
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.surfaceVariant = dc({
    name: 'surface_variant',
    palette: neutralVariant,
    tone: function (s) { return s.isDark ? 30 : 90; },
    isBackground: true,
  });
  MDC.onSurfaceVariant = dc({
    name: 'on_surface_variant',
    palette: neutralVariant,
    tone: function (s) { return s.isDark ? 80 : 30; },
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  MDC.inverseSurface = dc({
    name: 'inverse_surface',
    palette: neutral,
    tone: function (s) { return s.isDark ? 90 : 20; },
  });
  MDC.inverseOnSurface = dc({
    name: 'inverse_on_surface',
    palette: neutral,
    tone: function (s) { return s.isDark ? 20 : 95; },
    background: function () { return MDC.inverseSurface; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.outline = dc({
    name: 'outline',
    palette: neutralVariant,
    tone: function (s) { return s.isDark ? 60 : 50; },
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1.5, 3, 4.5, 7),
  });
  MDC.outlineVariant = dc({
    name: 'outline_variant',
    palette: neutralVariant,
    tone: function (s) { return s.isDark ? 30 : 80; },
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
  });
  MDC.shadow = dc({
    name: 'shadow',
    palette: neutral,
    tone: function () { return 0; },
  });
  MDC.scrim = dc({
    name: 'scrim',
    palette: neutral,
    tone: function () { return 0; },
  });
  MDC.surfaceTint = dc({
    name: 'surface_tint',
    palette: primaryP,
    tone: function (s) { return s.isDark ? 80 : 40; },
    isBackground: true,
  });
  function primaryPair() {
    return new ToneDeltaPair(MDC.primaryContainer, MDC.primary, 10, TonePolarity.nearer, false);
  }
  MDC.primary = dc({
    name: 'primary',
    palette: primaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 100 : 0;
      }
      return s.isDark ? 80 : 40;
    },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: primaryPair,
  });
  MDC.onPrimary = dc({
    name: 'on_primary',
    palette: primaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 10 : 90;
      }
      return s.isDark ? 20 : 100;
    },
    background: function () { return MDC.primary; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.primaryContainer = dc({
    name: 'primary_container',
    palette: primaryP,
    tone: function (s) {
      if (isFidelity(s)) {
        return s.sourceColorHct.tone;
      }
      if (isMonochrome(s)) {
        return s.isDark ? 85 : 25;
      }
      return s.isDark ? 30 : 90;
    },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: primaryPair,
  });
  MDC.onPrimaryContainer = dc({
    name: 'on_primary_container',
    palette: primaryP,
    tone: function (s) {
      if (isFidelity(s)) {
        return DynamicColor.foregroundTone(MDC.primaryContainer.tone(s), 4.5);
      }
      if (isMonochrome(s)) {
        return s.isDark ? 0 : 100;
      }
      return s.isDark ? 90 : 30;
    },
    background: function () { return MDC.primaryContainer; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  MDC.inversePrimary = dc({
    name: 'inverse_primary',
    palette: primaryP,
    tone: function (s) { return s.isDark ? 40 : 80; },
    background: function () { return MDC.inverseSurface; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
  });
  function secondaryPair() {
    return new ToneDeltaPair(MDC.secondaryContainer, MDC.secondary, 10, TonePolarity.nearer, false);
  }
  MDC.secondary = dc({
    name: 'secondary',
    palette: secondaryP,
    tone: function (s) { return s.isDark ? 80 : 40; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: secondaryPair,
  });
  MDC.onSecondary = dc({
    name: 'on_secondary',
    palette: secondaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 10 : 100;
      } else {
        return s.isDark ? 20 : 100;
      }
    },
    background: function () { return MDC.secondary; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.secondaryContainer = dc({
    name: 'secondary_container',
    palette: secondaryP,
    tone: function (s) {
      var initialTone = s.isDark ? 30.0 : 90.0;
      if (isMonochrome(s)) {
        return s.isDark ? 30 : 85;
      }
      if (!isFidelity(s)) {
        return initialTone;
      }
      return findDesiredChromaByTone(
        s.secondaryPalette.hue,
        s.secondaryPalette.chroma,
        initialTone,
        s.isDark ? false : true
      );
    },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: secondaryPair,
  });
  MDC.onSecondaryContainer = dc({
    name: 'on_secondary_container',
    palette: secondaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 90 : 10;
      }
      if (!isFidelity(s)) {
        return s.isDark ? 90 : 30;
      }
      return DynamicColor.foregroundTone(MDC.secondaryContainer.tone(s), 4.5);
    },
    background: function () { return MDC.secondaryContainer; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  function tertiaryPair() {
    return new ToneDeltaPair(MDC.tertiaryContainer, MDC.tertiary, 10, TonePolarity.nearer, false);
  }
  MDC.tertiary = dc({
    name: 'tertiary',
    palette: tertiaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 90 : 25;
      }
      return s.isDark ? 80 : 40;
    },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: tertiaryPair,
  });
  MDC.onTertiary = dc({
    name: 'on_tertiary',
    palette: tertiaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 10 : 90;
      }
      return s.isDark ? 20 : 100;
    },
    background: function () { return MDC.tertiary; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.tertiaryContainer = dc({
    name: 'tertiary_container',
    palette: tertiaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 60 : 49;
      }
      if (!isFidelity(s)) {
        return s.isDark ? 30 : 90;
      }
      var proposedHct = s.tertiaryPalette.getHct(s.sourceColorHct.tone);
      return DislikeAnalyzer.fixIfDisliked(proposedHct).tone;
    },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: tertiaryPair,
  });
  MDC.onTertiaryContainer = dc({
    name: 'on_tertiary_container',
    palette: tertiaryP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 0 : 100;
      }
      if (!isFidelity(s)) {
        return s.isDark ? 90 : 30;
      }
      return DynamicColor.foregroundTone(MDC.tertiaryContainer.tone(s), 4.5);
    },
    background: function () { return MDC.tertiaryContainer; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  function errorPair() {
    return new ToneDeltaPair(MDC.errorContainer, MDC.error, 10, TonePolarity.nearer, false);
  }
  MDC.error = dc({
    name: 'error',
    palette: errorP,
    tone: function (s) { return s.isDark ? 80 : 40; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(3, 4.5, 7, 7),
    toneDeltaPair: errorPair,
  });
  MDC.onError = dc({
    name: 'on_error',
    palette: errorP,
    tone: function (s) { return s.isDark ? 20 : 100; },
    background: function () { return MDC.error; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.errorContainer = dc({
    name: 'error_container',
    palette: errorP,
    tone: function (s) { return s.isDark ? 30 : 90; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: errorPair,
  });
  MDC.onErrorContainer = dc({
    name: 'on_error_container',
    palette: errorP,
    tone: function (s) {
      if (isMonochrome(s)) {
        return s.isDark ? 90 : 10;
      }
      return s.isDark ? 90 : 30;
    },
    background: function () { return MDC.errorContainer; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  function primaryFixedPair() {
    return new ToneDeltaPair(MDC.primaryFixed, MDC.primaryFixedDim, 10, TonePolarity.lighter, true);
  }
  MDC.primaryFixed = dc({
    name: 'primary_fixed',
    palette: primaryP,
    tone: function (s) { return isMonochrome(s) ? 40.0 : 90.0; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: primaryFixedPair,
  });
  MDC.primaryFixedDim = dc({
    name: 'primary_fixed_dim',
    palette: primaryP,
    tone: function (s) { return isMonochrome(s) ? 30.0 : 80.0; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: primaryFixedPair,
  });
  MDC.onPrimaryFixed = dc({
    name: 'on_primary_fixed',
    palette: primaryP,
    tone: function (s) { return isMonochrome(s) ? 100.0 : 10.0; },
    background: function () { return MDC.primaryFixedDim; },
    secondBackground: function () { return MDC.primaryFixed; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.onPrimaryFixedVariant = dc({
    name: 'on_primary_fixed_variant',
    palette: primaryP,
    tone: function (s) { return isMonochrome(s) ? 90.0 : 30.0; },
    background: function () { return MDC.primaryFixedDim; },
    secondBackground: function () { return MDC.primaryFixed; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  function secondaryFixedPair() {
    return new ToneDeltaPair(MDC.secondaryFixed, MDC.secondaryFixedDim, 10, TonePolarity.lighter, true);
  }
  MDC.secondaryFixed = dc({
    name: 'secondary_fixed',
    palette: secondaryP,
    tone: function (s) { return isMonochrome(s) ? 80.0 : 90.0; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: secondaryFixedPair,
  });
  MDC.secondaryFixedDim = dc({
    name: 'secondary_fixed_dim',
    palette: secondaryP,
    tone: function (s) { return isMonochrome(s) ? 70.0 : 80.0; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: secondaryFixedPair,
  });
  MDC.onSecondaryFixed = dc({
    name: 'on_secondary_fixed',
    palette: secondaryP,
    tone: function () { return 10.0; },
    background: function () { return MDC.secondaryFixedDim; },
    secondBackground: function () { return MDC.secondaryFixed; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.onSecondaryFixedVariant = dc({
    name: 'on_secondary_fixed_variant',
    palette: secondaryP,
    tone: function (s) { return isMonochrome(s) ? 25.0 : 30.0; },
    background: function () { return MDC.secondaryFixedDim; },
    secondBackground: function () { return MDC.secondaryFixed; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });
  function tertiaryFixedPair() {
    return new ToneDeltaPair(MDC.tertiaryFixed, MDC.tertiaryFixedDim, 10, TonePolarity.lighter, true);
  }
  MDC.tertiaryFixed = dc({
    name: 'tertiary_fixed',
    palette: tertiaryP,
    tone: function (s) { return isMonochrome(s) ? 40.0 : 90.0; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: tertiaryFixedPair,
  });
  MDC.tertiaryFixedDim = dc({
    name: 'tertiary_fixed_dim',
    palette: tertiaryP,
    tone: function (s) { return isMonochrome(s) ? 30.0 : 80.0; },
    isBackground: true,
    background: MDC.highestSurface,
    contrastCurve: new ContrastCurve(1, 1, 3, 4.5),
    toneDeltaPair: tertiaryFixedPair,
  });
  MDC.onTertiaryFixed = dc({
    name: 'on_tertiary_fixed',
    palette: tertiaryP,
    tone: function (s) { return isMonochrome(s) ? 100.0 : 10.0; },
    background: function () { return MDC.tertiaryFixedDim; },
    secondBackground: function () { return MDC.tertiaryFixed; },
    contrastCurve: new ContrastCurve(4.5, 7, 11, 21),
  });
  MDC.onTertiaryFixedVariant = dc({
    name: 'on_tertiary_fixed_variant',
    palette: tertiaryP,
    tone: function (s) { return isMonochrome(s) ? 90.0 : 30.0; },
    background: function () { return MDC.tertiaryFixedDim; },
    secondBackground: function () { return MDC.tertiaryFixed; },
    contrastCurve: new ContrastCurve(3, 4.5, 7, 11),
  });

  // ---------------------------------------------------------------------------
  // scheme/scheme_*.dart（9 个 variant）
  // ---------------------------------------------------------------------------
  function schemeTonalSpot(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.tonalSpot,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, 36.0),
      secondaryPalette: TonalPalette.of(sourceColorHct.hue, 16.0),
      tertiaryPalette: TonalPalette.of(MathUtils.sanitizeDegreesDouble(sourceColorHct.hue + 60.0), 24.0),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, 6.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, 8.0),
    });
  }

  function schemeFidelity(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.fidelity,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, sourceColorHct.chroma),
      secondaryPalette: TonalPalette.of(
        sourceColorHct.hue,
        Math.max(sourceColorHct.chroma - 32.0, sourceColorHct.chroma * 0.5)
      ),
      tertiaryPalette: TonalPalette.fromHct(
        DislikeAnalyzer.fixIfDisliked(new TemperatureCache(sourceColorHct).complement())
      ),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, sourceColorHct.chroma / 8.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, (sourceColorHct.chroma / 8.0) + 4.0),
    });
  }

  function schemeMonochrome(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.monochrome,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
      secondaryPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
      tertiaryPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
    });
  }

  function schemeNeutral(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.neutral,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, 12.0),
      secondaryPalette: TonalPalette.of(sourceColorHct.hue, 8.0),
      tertiaryPalette: TonalPalette.of(sourceColorHct.hue, 16.0),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, 2.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, 2.0),
    });
  }

  var VIBRANT_HUES = [0, 41, 61, 101, 131, 181, 251, 301, 360];
  var VIBRANT_SECONDARY_ROTATIONS = [18, 15, 10, 12, 15, 18, 15, 12, 12];
  var VIBRANT_TERTIARY_ROTATIONS = [35, 30, 20, 25, 30, 35, 30, 25, 25];
  function schemeVibrant(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.vibrant,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, 200.0),
      secondaryPalette: TonalPalette.of(
        DynamicScheme.getRotatedHue(sourceColorHct, VIBRANT_HUES, VIBRANT_SECONDARY_ROTATIONS),
        24.0
      ),
      tertiaryPalette: TonalPalette.of(
        DynamicScheme.getRotatedHue(sourceColorHct, VIBRANT_HUES, VIBRANT_TERTIARY_ROTATIONS),
        32.0
      ),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, 10.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, 12.0),
    });
  }

  var EXPRESSIVE_HUES = [0, 21, 51, 121, 151, 191, 271, 321, 360];
  var EXPRESSIVE_SECONDARY_ROTATIONS = [45, 95, 45, 20, 45, 90, 45, 45, 45];
  var EXPRESSIVE_TERTIARY_ROTATIONS = [120, 120, 20, 45, 20, 15, 20, 120, 120];
  function schemeExpressive(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.expressive,
      primaryPalette: TonalPalette.of(MathUtils.sanitizeDegreesDouble(sourceColorHct.hue + 240.0), 40.0),
      secondaryPalette: TonalPalette.of(
        DynamicScheme.getRotatedHue(sourceColorHct, EXPRESSIVE_HUES, EXPRESSIVE_SECONDARY_ROTATIONS),
        24.0
      ),
      tertiaryPalette: TonalPalette.of(
        DynamicScheme.getRotatedHue(sourceColorHct, EXPRESSIVE_HUES, EXPRESSIVE_TERTIARY_ROTATIONS),
        32.0
      ),
      neutralPalette: TonalPalette.of(sourceColorHct.hue + 15.0, 8.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue + 15.0, 12.0),
    });
  }

  function schemeContent(sourceColorHct, isDark, contrastLevel) {
    var analogous = new TemperatureCache(sourceColorHct).analogous(3, 6);
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.content,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, sourceColorHct.chroma),
      secondaryPalette: TonalPalette.of(
        sourceColorHct.hue,
        Math.max(sourceColorHct.chroma - 32.0, sourceColorHct.chroma * 0.5)
      ),
      tertiaryPalette: TonalPalette.fromHct(DislikeAnalyzer.fixIfDisliked(analogous[analogous.length - 1])),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, sourceColorHct.chroma / 8.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, (sourceColorHct.chroma / 8.0) + 4.0),
    });
  }

  function schemeRainbow(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.rainbow,
      primaryPalette: TonalPalette.of(sourceColorHct.hue, 48.0),
      secondaryPalette: TonalPalette.of(sourceColorHct.hue, 16.0),
      tertiaryPalette: TonalPalette.of(MathUtils.sanitizeDegreesDouble(sourceColorHct.hue + 60.0), 24.0),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, 0.0),
    });
  }

  function schemeFruitSalad(sourceColorHct, isDark, contrastLevel) {
    return new DynamicScheme({
      sourceColorHct: sourceColorHct,
      isDark: isDark,
      contrastLevel: contrastLevel,
      variant: Variant.fruitSalad,
      primaryPalette: TonalPalette.of(MathUtils.sanitizeDegreesDouble(sourceColorHct.hue - 50.0), 48.0),
      secondaryPalette: TonalPalette.of(MathUtils.sanitizeDegreesDouble(sourceColorHct.hue - 50.0), 36.0),
      tertiaryPalette: TonalPalette.of(sourceColorHct.hue, 36.0),
      neutralPalette: TonalPalette.of(sourceColorHct.hue, 10.0),
      neutralVariantPalette: TonalPalette.of(sourceColorHct.hue, 16.0),
    });
  }

  var SCHEME_BUILDERS = {
    tonalSpot: schemeTonalSpot,
    fidelity: schemeFidelity,
    monochrome: schemeMonochrome,
    neutral: schemeNeutral,
    vibrant: schemeVibrant,
    expressive: schemeExpressive,
    content: schemeContent,
    rainbow: schemeRainbow,
    fruitSalad: schemeFruitSalad,
  };
  var VARIANTS = ['tonalSpot', 'fidelity', 'monochrome', 'neutral', 'vibrant', 'expressive', 'content', 'rainbow', 'fruitSalad'];

  // Flutter ColorScheme.fromSeed 的角色 -> MaterialDynamicColors 映射（color_scheme.dart 原样，
  // 不含已废弃的 background / onBackground / surfaceVariant）。
  var FLUTTER_ROLES = [
    ['primary', MDC.primary],
    ['onPrimary', MDC.onPrimary],
    ['primaryContainer', MDC.primaryContainer],
    ['onPrimaryContainer', MDC.onPrimaryContainer],
    ['primaryFixed', MDC.primaryFixed],
    ['primaryFixedDim', MDC.primaryFixedDim],
    ['onPrimaryFixed', MDC.onPrimaryFixed],
    ['onPrimaryFixedVariant', MDC.onPrimaryFixedVariant],
    ['secondary', MDC.secondary],
    ['onSecondary', MDC.onSecondary],
    ['secondaryContainer', MDC.secondaryContainer],
    ['onSecondaryContainer', MDC.onSecondaryContainer],
    ['secondaryFixed', MDC.secondaryFixed],
    ['secondaryFixedDim', MDC.secondaryFixedDim],
    ['onSecondaryFixed', MDC.onSecondaryFixed],
    ['onSecondaryFixedVariant', MDC.onSecondaryFixedVariant],
    ['tertiary', MDC.tertiary],
    ['onTertiary', MDC.onTertiary],
    ['tertiaryContainer', MDC.tertiaryContainer],
    ['onTertiaryContainer', MDC.onTertiaryContainer],
    ['tertiaryFixed', MDC.tertiaryFixed],
    ['tertiaryFixedDim', MDC.tertiaryFixedDim],
    ['onTertiaryFixed', MDC.onTertiaryFixed],
    ['onTertiaryFixedVariant', MDC.onTertiaryFixedVariant],
    ['error', MDC.error],
    ['onError', MDC.onError],
    ['errorContainer', MDC.errorContainer],
    ['onErrorContainer', MDC.onErrorContainer],
    ['outline', MDC.outline],
    ['outlineVariant', MDC.outlineVariant],
    ['surface', MDC.surface],
    ['surfaceDim', MDC.surfaceDim],
    ['surfaceBright', MDC.surfaceBright],
    ['surfaceContainerLowest', MDC.surfaceContainerLowest],
    ['surfaceContainerLow', MDC.surfaceContainerLow],
    ['surfaceContainer', MDC.surfaceContainer],
    ['surfaceContainerHigh', MDC.surfaceContainerHigh],
    ['surfaceContainerHighest', MDC.surfaceContainerHighest],
    ['onSurface', MDC.onSurface],
    ['onSurfaceVariant', MDC.onSurfaceVariant],
    ['inverseSurface', MDC.inverseSurface],
    ['onInverseSurface', MDC.inverseOnSurface],
    ['inversePrimary', MDC.inversePrimary],
    ['shadow', MDC.shadow],
    ['scrim', MDC.scrim],
    ['surfaceTint', MDC.primary],
  ];

  // 与 Flutter ColorScheme.fromSeed(seedColor, brightness, dynamicSchemeVariant, contrastLevel)
  // 同一结果；未知 variant 回落 tonalSpot（Flutter 默认值）。
  function schemeFromSeed(seedArgb, isDark, variant, contrastLevel) {
    var builder = SCHEME_BUILDERS[variant] || schemeTonalSpot;
    var level = typeof contrastLevel === 'number' && isFinite(contrastLevel) ? contrastLevel : 0.0;
    var scheme = builder(Hct.fromInt(seedArgb >>> 0), !!isDark, level);
    var out = {};
    for (var i = 0; i < FLUTTER_ROLES.length; i++) {
      out[FLUTTER_ROLES[i][0]] = FLUTTER_ROLES[i][1].getArgb(scheme) >>> 0;
    }
    return out;
  }

  function rgbFromArgb(argb) {
    return { r: ColorUtils.redFromArgb(argb), g: ColorUtils.greenFromArgb(argb), b: ColorUtils.blueFromArgb(argb) };
  }

  function hexFromArgb(argb) {
    var s = ((argb >>> 0) & 0xffffff).toString(16);
    while (s.length < 6) s = '0' + s;
    return '#' + s;
  }

  // 接受 '#rgb' / '#rrggbb' / '#aarrggbb'（前导 # 可省）；非法返回 null。结果强制不透明。
  function argbFromHex(str) {
    if (typeof str !== 'string') return null;
    var s = str.trim().replace(/^#/, '');
    if (!/^[0-9a-fA-F]+$/.test(s)) return null;
    if (s.length === 3) {
      s = s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1) + s.charAt(2) + s.charAt(2);
    } else if (s.length === 8) {
      s = s.slice(2);
    } else if (s.length !== 6) {
      return null;
    }
    return (0xff000000 | parseInt(s, 16)) >>> 0;
  }

  g.fushiMaterialColor = {
    Hct: {
      fromInt: function (argb) { return Hct.fromInt(argb); },
      from: function (hue, chroma, tone) { return Hct.from(hue, chroma, tone); },
    },
    TonalPalette: {
      fromHueAndChroma: function (hue, chroma) { return TonalPalette.of(hue, chroma); },
    },
    argbFromRgb: function (r, g2, b) { return ColorUtils.argbFromRgb(r, g2, b); },
    rgbFromArgb: rgbFromArgb,
    hexFromArgb: hexFromArgb,
    argbFromHex: argbFromHex,
    VARIANTS: VARIANTS.slice(),
    schemeFromSeed: schemeFromSeed,
  };
})();
