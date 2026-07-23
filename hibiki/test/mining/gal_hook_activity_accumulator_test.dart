import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_activity_accumulator.dart';

/// [GalHookActivityAccumulator] 纯累计逻辑守卫：字符累加、活跃时长间隔封顶、中途
/// flush 阈值、drain 保留计时连续性、reset 整体复位。
void main() {
  group('GalHookActivityAccumulator', () {
    test('字符累加，非正字符数忽略', () {
      final GalHookActivityAccumulator acc = GalHookActivityAccumulator();
      acc.recordLine(5, 0);
      acc.recordLine(6, 1000);
      acc.recordLine(0, 2000); // 忽略字符累加
      acc.recordLine(-3, 3000); // 忽略字符累加
      expect(acc.pendingChars, 11);
    });

    test('相邻行间隔计入活跃时长；首行无前置间隔', () {
      final GalHookActivityAccumulator acc = GalHookActivityAccumulator();
      acc.recordLine(1, 1000); // 首行：无时长
      expect(acc.pendingDurationMs, 0);
      acc.recordLine(1, 6000); // +5000
      acc.recordLine(1, 8000); // +2000
      expect(acc.pendingDurationMs, 7000);
    });

    test('间隔超过 idleGapMs 的挂机段不计入活跃时长', () {
      final GalHookActivityAccumulator acc =
          GalHookActivityAccumulator(idleGapMs: 30000);
      acc.recordLine(1, 0);
      acc.recordLine(1, 20000); // 20s 在阈值内 → +20000
      acc.recordLine(1, 100000); // 80s 挂机 → 不计
      acc.recordLine(1, 105000); // 5s 恢复 → +5000
      expect(acc.pendingDurationMs, 25000);
    });

    test('零/负间隔（乱序时间戳）不计入活跃时长', () {
      final GalHookActivityAccumulator acc = GalHookActivityAccumulator();
      acc.recordLine(1, 5000);
      acc.recordLine(1, 5000); // gap 0 → 不计
      acc.recordLine(1, 4000); // gap 负 → 不计
      expect(acc.pendingDurationMs, 0);
    });

    test('shouldFlush：满字符阈值', () {
      final GalHookActivityAccumulator acc =
          GalHookActivityAccumulator(flushChars: 500, flushDurationMs: 60000);
      acc.recordLine(499, 0);
      expect(acc.shouldFlush, isFalse);
      acc.recordLine(1, 100);
      expect(acc.pendingChars, 500);
      expect(acc.shouldFlush, isTrue);
    });

    test('shouldFlush：满活跃时长阈值', () {
      final GalHookActivityAccumulator acc = GalHookActivityAccumulator(
          flushChars: 500, flushDurationMs: 60000, idleGapMs: 30000);
      // 每段间隔 <= idleGapMs 才计入；用两段 30s 累到 60s（59s 单跳会被挂机封顶剔除）。
      acc.recordLine(1, 0);
      acc.recordLine(1, 30000); // +30000 = 30s < 60s
      expect(acc.pendingDurationMs, 30000);
      expect(acc.shouldFlush, isFalse);
      acc.recordLine(1, 60000); // +30000 = 60s
      expect(acc.pendingDurationMs, 60000);
      expect(acc.shouldFlush, isTrue);
    });

    test('无字符累计时不 flush（duration 单独不触发）', () {
      final GalHookActivityAccumulator acc =
          GalHookActivityAccumulator(flushChars: 500, flushDurationMs: 60000);
      // chars 全为 0 → shouldFlush 恒 false（防空 flush）。
      acc.recordLine(0, 0);
      acc.recordLine(0, 70000);
      expect(acc.shouldFlush, isFalse);
    });

    test('drain 取出并清零，但保留计时连续性（跨 flush 的间隔仍计）', () {
      final GalHookActivityAccumulator acc = GalHookActivityAccumulator();
      acc.recordLine(10, 0);
      acc.recordLine(10, 5000); // dur 5000
      final (int chars, int durationMs) = acc.drain();
      expect(chars, 20);
      expect(durationMs, 5000);
      expect(acc.hasPending, isFalse);
      expect(acc.pendingChars, 0);
      expect(acc.pendingDurationMs, 0);
      // drain 后下一行与上一行（5000）的间隔仍应计入新段。
      acc.recordLine(10, 7000); // gap 2000 计入
      expect(acc.pendingChars, 10);
      expect(acc.pendingDurationMs, 2000);
    });

    test('reset 整体复位（含计时锚点），下一段从零重计', () {
      final GalHookActivityAccumulator acc = GalHookActivityAccumulator();
      acc.recordLine(10, 0);
      acc.recordLine(10, 5000);
      acc.reset();
      expect(acc.hasPending, isFalse);
      // reset 后首行无前置间隔（计时锚点已清）。
      acc.recordLine(3, 9000);
      expect(acc.pendingChars, 3);
      expect(acc.pendingDurationMs, 0);
    });
  });
}
