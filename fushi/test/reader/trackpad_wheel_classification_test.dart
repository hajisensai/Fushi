import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// BUG-1745：触摸板纵向翻页。
///
/// 症状：macOS 触摸板上下双指滑一次，翻 3~4 页（把「滚轮翻页间隔」调到下限
/// 150ms 时能翻十页）。
///
/// 根因：`ReaderWheelGestureGate`（一次惯性流聚合成一次翻页）此前只对
/// `axis == 'horizontal'` 生效，判据里隐含「纵向 = 鼠标滚轮」的假设。但 macOS
/// 触摸板上下滑同样是纵向，惯性流持续 1~1.5 秒，全部漏过闸门、只受 `_paginate`
/// 的固定 450ms 窗管 → 1500ms / 450ms ≈ 3 页。
///
/// 修复把闸门判据换成「输入设备」：触摸板（连续惯性流）进闸门，鼠标滚轮（离散
/// tick，一格一页是正确期望）保留固定窗节流。
///
/// 本文件覆盖闸门在**纵向**输入上的行为不变量；JS 侧的设备判别与主轴抖动余量由
/// `reader_mouse_paging_boundary_guard_static_test.dart` 的源码守卫锁定。
void main() {
  const Duration settle = Duration(milliseconds: 450);
  final DateTime t0 = DateTime(2026, 8, 19, 12);

  /// 模拟一段惯性流：[count] 个间隔 [stepMs] 毫秒的 tick，返回实际翻页次数。
  int turnsFor({
    required int count,
    required int stepMs,
    required ReaderWheelGestureGate gate,
    required DateTime start,
  }) {
    int turns = 0;
    for (int i = 0; i < count; i++) {
      final DateTime now = start.add(Duration(milliseconds: i * stepMs));
      if (gate.shouldStartNewGesture(
        now: now,
        settleInterval: settle,
        canTurnPage: true,
      )) {
        turns++;
      }
    }
    return turns;
  }

  test('一次 1.5 秒的纵向触摸板惯性只翻一页', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    // 触摸板惯性典型形态：~16ms 一拍，持续 1.5 秒。
    expect(
      turnsFor(count: 94, stepMs: 16, gate: gate, start: t0),
      1,
      reason: '整段惯性属于同一次手势；旧实现在纵向上会翻 3 页',
    );
  });

  test('把翻页间隔调到下限 150ms 也仍是一页（旧实现会翻十页）', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    int turns = 0;
    for (int i = 0; i < 94; i++) {
      if (gate.shouldStartNewGesture(
        now: t0.add(Duration(milliseconds: i * 16)),
        settleInterval: const Duration(milliseconds: 150),
        canTurnPage: true,
      )) {
        turns++;
      }
    }
    expect(turns, 1);
  });

  test('两次滑动之间有完整静默 → 各翻一页', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    expect(turnsFor(count: 30, stepMs: 16, gate: gate, start: t0), 1);
    // 上一段最后一拍在 t0+464ms；再静默一个完整 settle 窗后才算新手势。
    final DateTime second = t0.add(const Duration(milliseconds: 30 * 16 + 500));
    expect(turnsFor(count: 30, stepMs: 16, gate: gate, start: second), 1);
  });

  test('鼠标滚轮的离散 tick 不进闸门 —— 一格一页由固定窗节流决定', () {
    // 设备判别在 JS 侧（_isTrackpadWheel），Dart 侧只对 pointerKind=='trackpad'
    // 开闸门。这里锁的是闸门本身对「离散慢速 tick」不会误聚合：即便鼠标输入被
    // 误判成触摸板，间隔大于 settle 的 tick 仍各自成手势。
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    expect(turnsFor(count: 5, stepMs: 600, gate: gate, start: t0), 5);
  });

  test('翻不动页的 tick 不认领手势（BUG-1380 契约在纵向上同样成立）', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    // 换章加载覆盖了惯性开头：这些 tick 只查询、不认领。
    for (int i = 0; i < 20; i++) {
      gate.shouldStartNewGesture(
        now: t0.add(Duration(milliseconds: i * 16)),
        settleInterval: settle,
        canTurnPage: false,
      );
    }
    // 加载落定后，紧接着的下一拍必须仍能翻一页（不是零反馈）。
    expect(
      gate.shouldStartNewGesture(
        now: t0.add(const Duration(milliseconds: 20 * 16)),
        settleInterval: settle,
        canTurnPage: true,
      ),
      isTrue,
    );
  });
}
