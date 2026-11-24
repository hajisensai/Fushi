/// 镜台（diorama）用的最小 3D 数学：向量、四元数、SmoothDamp、种子随机。
///
/// 对应 folia `cameraPath.ts` 顶部的 vec 工具与 three.js 里实际用到的那几个 Quaternion /
/// Matrix4 操作。约定与 three.js 一致：右手系，相机看向本地 -Z，`fov` 是竖直视角。
library;

import 'dart:math' as math;

/// 不可变三维向量（相机 / 路径用；粒子逐点计算直接用 double，不建对象）。
class DioramaVec {
  const DioramaVec(this.x, this.y, this.z);

  static const DioramaVec zero = DioramaVec(0, 0, 0);
  static const DioramaVec worldUp = DioramaVec(0, 1, 0);

  final double x;
  final double y;
  final double z;

  DioramaVec operator +(DioramaVec o) => DioramaVec(x + o.x, y + o.y, z + o.z);
  DioramaVec operator -(DioramaVec o) => DioramaVec(x - o.x, y - o.y, z - o.z);
  DioramaVec operator *(double s) => DioramaVec(x * s, y * s, z * s);
  DioramaVec operator -() => DioramaVec(-x, -y, -z);

  double dot(DioramaVec o) => x * o.x + y * o.y + z * o.z;

  DioramaVec cross(DioramaVec o) =>
      DioramaVec(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  DioramaVec get normalized {
    final double l = length;
    if (l == 0) return const DioramaVec(0, 0, 0);
    return DioramaVec(x / l, y / l, z / l);
  }

  double distanceTo(DioramaVec o) {
    final double dx = x - o.x;
    final double dy = y - o.y;
    final double dz = z - o.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// 夹角（弧度）。
  double angleTo(DioramaVec o) {
    final double denom = length * o.length;
    if (denom == 0) return math.pi / 2;
    return math.acos((dot(o) / denom).clamp(-1.0, 1.0));
  }

  @override
  String toString() => 'DioramaVec($x, $y, $z)';
}

/// 单位四元数（three.js 的 Quaternion 子集）。
class DioramaQuat {
  const DioramaQuat(this.x, this.y, this.z, this.w);

  static const DioramaQuat identity = DioramaQuat(0, 0, 0, 1);

  final double x;
  final double y;
  final double z;
  final double w;

  /// 绕单位轴 [axis] 转 [angle]。
  factory DioramaQuat.axisAngle(DioramaVec axis, double angle) {
    final double h = angle / 2;
    final double s = math.sin(h);
    return DioramaQuat(axis.x * s, axis.y * s, axis.z * s, math.cos(h));
  }

  /// 三列基向量（本地 +X / +Y / +Z 在世界里的方向）组成的旋转（three `makeBasis` +
  /// `setFromRotationMatrix`）。
  factory DioramaQuat.fromBasis(
    DioramaVec xAxis,
    DioramaVec yAxis,
    DioramaVec zAxis,
  ) {
    final double m11 = xAxis.x, m12 = yAxis.x, m13 = zAxis.x;
    final double m21 = xAxis.y, m22 = yAxis.y, m23 = zAxis.y;
    final double m31 = xAxis.z, m32 = yAxis.z, m33 = zAxis.z;
    final double trace = m11 + m22 + m33;
    if (trace > 0) {
      final double s = 0.5 / math.sqrt(trace + 1.0);
      return DioramaQuat(
        (m32 - m23) * s,
        (m13 - m31) * s,
        (m21 - m12) * s,
        0.25 / s,
      );
    } else if (m11 > m22 && m11 > m33) {
      final double s = 2.0 * math.sqrt(1.0 + m11 - m22 - m33);
      return DioramaQuat(
        0.25 * s,
        (m12 + m21) / s,
        (m13 + m31) / s,
        (m32 - m23) / s,
      );
    } else if (m22 > m33) {
      final double s = 2.0 * math.sqrt(1.0 + m22 - m11 - m33);
      return DioramaQuat(
        (m12 + m21) / s,
        0.25 * s,
        (m23 + m32) / s,
        (m13 - m31) / s,
      );
    }
    final double s = 2.0 * math.sqrt(1.0 + m33 - m11 - m22);
    return DioramaQuat(
      (m13 + m31) / s,
      (m23 + m32) / s,
      0.25 * s,
      (m21 - m12) / s,
    );
  }

  /// 相机朝向：从 [eye] 看 [target]，[up] 定滚转（three `Object3D.lookAt` 对相机的行为）。
  factory DioramaQuat.lookAt(DioramaVec eye, DioramaVec target, DioramaVec up) {
    DioramaVec z = eye - target;
    if (z.length == 0) z = const DioramaVec(0, 0, 1);
    z = z.normalized;
    DioramaVec x = up.cross(z);
    if (x.length == 0) {
      // 视线与 up 平行：轻推一下 z（three 同样处理）。
      z =
          (math.max(z.x.abs(), z.z.abs()) < 1e-6
                  ? DioramaVec(z.x + 1e-4, z.y, z.z)
                  : DioramaVec(z.x, z.y, z.z + 1e-4))
              .normalized;
      x = up.cross(z);
    }
    x = x.normalized;
    final DioramaVec y = z.cross(x);
    return DioramaQuat.fromBasis(x, y, z);
  }

  DioramaQuat operator *(DioramaQuat b) => DioramaQuat(
    x * b.w + w * b.x + y * b.z - z * b.y,
    y * b.w + w * b.y + z * b.x - x * b.z,
    z * b.w + w * b.z + x * b.y - y * b.x,
    w * b.w - x * b.x - y * b.y - z * b.z,
  );

  DioramaQuat get conjugate => DioramaQuat(-x, -y, -z, w);

  /// 用这个旋转转一个向量。
  DioramaVec rotate(DioramaVec v) {
    // t = 2 * cross(q.xyz, v); v' = v + w * t + cross(q.xyz, t)
    final double tx = 2 * (y * v.z - z * v.y);
    final double ty = 2 * (z * v.x - x * v.z);
    final double tz = 2 * (x * v.y - y * v.x);
    return DioramaVec(
      v.x + w * tx + (y * tz - z * ty),
      v.y + w * ty + (z * tx - x * tz),
      v.z + w * tz + (x * ty - y * tx),
    );
  }

  /// three `Quaternion.slerp`：走最短弧。
  DioramaQuat slerp(DioramaQuat b, double t) {
    if (t <= 0) return this;
    if (t >= 1) return b;
    double bx = b.x, by = b.y, bz = b.z, bw = b.w;
    double cosHalf = w * bw + x * bx + y * by + z * bz;
    if (cosHalf < 0) {
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
      cosHalf = -cosHalf;
    }
    if (cosHalf >= 1.0) return this;
    final double sqrSin = 1.0 - cosHalf * cosHalf;
    if (sqrSin <= 2.220446049250313e-16) {
      final double s = 1 - t;
      return DioramaQuat(
        s * x + t * bx,
        s * y + t * by,
        s * z + t * bz,
        s * w + t * bw,
      ).normalized;
    }
    final double sinHalf = math.sqrt(sqrSin);
    final double halfTheta = math.atan2(sinHalf, cosHalf);
    final double ra = math.sin((1 - t) * halfTheta) / sinHalf;
    final double rb = math.sin(t * halfTheta) / sinHalf;
    return DioramaQuat(
      x * ra + bx * rb,
      y * ra + by * rb,
      z * ra + bz * rb,
      w * ra + bw * rb,
    );
  }

  DioramaQuat get normalized {
    final double l = math.sqrt(x * x + y * y + z * z + w * w);
    if (l == 0) return identity;
    return DioramaQuat(x / l, y / l, z / l, w / l);
  }
}

double dioramaClamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double dioramaSmoothstep01(double t) {
  final double c = dioramaClamp01(t);
  return c * c * (3 - 2 * c);
}

/// 确定性的 [0, 1) 伪随机（folia `seededUnit`：同一下标永远同一个值，拖进度不会重排）。
double dioramaSeededUnit(double seed) {
  final double x = math.sin(seed * 12.9898) * 43758.5453;
  return x - x.floorToDouble();
}

/// 歌曲种子压到 folia 数值种子的量级（它对字符串 id 取 `% 100000`），让各处 `base * 0.017`
/// 之类的相位保持同样的变化幅度。
int dioramaHashSeed(int seed) {
  final int h = seed.abs() % 100000;
  return h == 0 ? 1 : h;
}

/// 字符串种子（folia `hashSeed` 的字符串分支）。
int dioramaHashString(String s) {
  int hash = 0;
  for (final int c in s.codeUnits) {
    hash = (hash * 31 + c) % 100000;
  }
  return hash == 0 ? 1 : hash;
}

/// Unity 式临界阻尼 SmoothDamp（单轴），返回 (新值, 新速度)。
(double, double) dioramaSmoothDamp(
  double current,
  double target,
  double velocity,
  double smoothTime,
  double deltaSeconds,
) {
  final double t = math.max(0.0001, smoothTime);
  final double omega = 2 / t;
  final double x = omega * deltaSeconds;
  final double exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
  final double change = current - target;
  final double temp = (velocity + omega * change) * deltaSeconds;
  final double newVelocity = (velocity - omega * temp) * exp;
  final double value = target + (change + temp) * exp;
  return (value, newVelocity);
}

/// 快起慢落包络一步（folia `stepEnvelope`）。
double dioramaStepEnvelope(
  double current,
  double target,
  double attack,
  double release,
  double delta,
) =>
    current +
    (target - current) *
        (1 - math.exp(-(target > current ? attack : release) * delta));
