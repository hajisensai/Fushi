import 'dart:math' as math;

/// 分段选择器（MD3 胶囊分段 [FushiPillSegmentedButton] 与 Apple 分段
/// [FushiAppleSegmentedControl]）的段宽分配，两套设计系统共用这一份。
///
/// 反馈 GaI5uPQEbF（睡眠定时「播完本曲」被截成「播完…」）：旧实现两套都是
/// 「各段等宽、取最宽段」，总宽放不下时**所有段等比缩窄**，于是最长的那段先被
/// 省略号截断，而短段（「关闭」「15 分钟」）里还空着大片留白。按下面的顺序退让，
/// 每一级都只在上一级放不下时才启用：
///
/// 1. **等宽**：每段 = 最宽段的自然宽（选中胶囊在段间切换时宽度不跳）。[fill]
///    为 true（宿主要求撑满）时等分 [available]。
/// 2. **按内容分宽**：总宽 = [available]，窄段先被抬到同一宽度（注水），
///    宽段保持自然宽——谁都不截断。
/// 3. **收内边距**：各段按比例收掉 [extra]（首选内边距超出最小内边距的那部分），
///    文字仍完整。
/// 4. **仍放不下**：只压最宽的段（削峰），短段保持完整；压窄的段由调用方决定
///    换行（MD3）或省略（Apple 固定高度）。
///
/// [content] 是每段在**最小**内边距下的自然宽，[extra] 是首选内边距额外多占的
/// 宽；两者同序同长。[available] 为无穷大时按第 1 级返回（无界宽宿主按内容取宽）。
List<double> fushiSegmentWidths({
  required List<double> content,
  required List<double> extra,
  required double available,
  bool fill = false,
}) {
  assert(content.length == extra.length);
  final int n = content.length;
  if (n == 0) return const <double>[];
  final List<double> natural = <double>[
    for (int i = 0; i < n; i++) content[i] + extra[i],
  ];
  final double widest = natural.reduce(math.max);
  if (!available.isFinite) return List<double>.filled(n, widest);
  if (widest * n <= available) {
    return List<double>.filled(n, fill ? available / n : widest);
  }
  final double naturalSum = natural.fold(0, (double a, double b) => a + b);
  if (naturalSum <= available) {
    final double floor = _raiseFloorTo(natural, available);
    return <double>[for (final double w in natural) math.max(w, floor)];
  }
  final double contentSum = content.fold(0, (double a, double b) => a + b);
  if (contentSum <= available) {
    final double extraSum = naturalSum - contentSum;
    final double t = extraSum <= 0 ? 0 : (available - contentSum) / extraSum;
    return <double>[for (int i = 0; i < n; i++) content[i] + extra[i] * t];
  }
  final double cap = _lowerCapTo(content, math.max(0, available));
  return <double>[for (final double w in content) math.min(w, cap)];
}

/// 求 `w` 使 `Σ max(values[i], w) == target`（要求 `target >= Σ values`）。
double _raiseFloorTo(List<double> values, double target) {
  final List<double> sorted = List<double>.of(values)..sort();
  final int n = sorted.length;
  // 最小的 k 段被抬到同一水位 w，其余保持原宽：w = (target − 其余之和) / k。
  double untouched = sorted.fold(0, (double a, double b) => a + b);
  for (int k = 1; k <= n; k++) {
    untouched -= sorted[k - 1];
    final double level = (target - untouched) / k;
    if (k == n || level <= sorted[k]) return math.max(level, sorted[k - 1]);
  }
  return sorted.last;
}

/// 求 `c` 使 `Σ min(values[i], c) == target`（要求 `target < Σ values`）。
double _lowerCapTo(List<double> values, double target) {
  final List<double> sorted = List<double>.of(values)..sort();
  double rest = target;
  for (int i = 0; i < sorted.length; i++) {
    final int remaining = sorted.length - i;
    final double level = rest / remaining;
    if (level <= sorted[i]) return level;
    rest -= sorted[i];
  }
  return sorted.last;
}
