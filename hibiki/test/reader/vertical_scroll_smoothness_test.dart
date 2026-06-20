import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-629 ②：阅读器竖排连续（滚动）模式滚轮「刷新率低/一格一格跳」。
///
/// 根因：竖排连续模式滚轮的主 delta 被投影到横向内容轴，但旧实现逐 wheel 事件
/// `window.scrollBy({left: ..., behavior: 'auto'})`——瞬时离散跳，每事件一次 deltaY
/// 颗粒、丢弃浏览器原生平滑/惯性，看着像低刷新率。修复：wheel 事件只累积目标
/// scrollLeft，由 `requestAnimationFrame` 每帧调用 [ReaderPaginationScripts.smoothScrollStep]
/// 指数逼近，消除颗粒感。横排（轴 = 纵向，与 deltaY 同轴）仍放行原生滚动；
/// TODO-627 的跨章边界判定（continuousWheelBoundaryDirection）不变。
///
/// headless WebView 不可用：按项目测试范式，缓动步进抽成纯函数在此锁定语义
/// （逐帧逼近·单调·收敛不超调），JS 接线与「不再裸 scrollBy(behavior:auto)」由
/// 源码守卫锁定（见 swipe_page_turn_no_animation_test.dart）。
void main() {
  double step(double current, double target,
          {double factor = 0.18, double snap = 0.5}) =>
      ReaderPaginationScripts.smoothScrollStep(
        current: current,
        target: target,
        factor: factor,
        snap: snap,
      );

  group('smoothScrollStep（rAF 缓动步进，正向：横向 scrollLeft 增大）', () {
    test('单帧朝目标推进剩余距离的 factor 比例', () {
      // current=0, target=100, factor=0.2 → 下一帧 = 0 + 100*0.2 = 20。
      expect(step(0, 100, factor: 0.2), closeTo(20, 1e-9));
    });

    test('逐帧迭代单调逼近且不超调，最终收敛到目标', () {
      const double target = 480;
      double pos = 0;
      double? prev;
      var frames = 0;
      while (pos != target) {
        final double next = step(pos, target);
        // 单调：每帧都更接近目标（剩余距离绝对值严格不增）。
        expect((target - next).abs(), lessThanOrEqualTo((target - pos).abs()),
            reason: '缓动必须单调逼近，不得抖动远离目标');
        // 不超调：正向逼近不得越过目标。
        expect(next, lessThanOrEqualTo(target), reason: '正向缓动不得越过目标（超调）');
        prev = pos;
        pos = next;
        frames++;
        expect(frames, lessThan(1000), reason: '必须在有限帧内收敛');
      }
      expect(pos, target, reason: '吸附阈值内必须精确落到目标');
      expect(prev, isNotNull);
    });
  });

  group('smoothScrollStep（负向：vertical-rl forward = scrollLeft 减小）', () {
    test('单帧朝负目标推进剩余距离的 factor 比例', () {
      // vertical-rl 前进，target 为负（如 -100）。
      expect(step(0, -100, factor: 0.2), closeTo(-20, 1e-9));
    });

    test('逐帧迭代单调逼近负目标且不超调（不越过更负）', () {
      const double target = -640;
      double pos = 0;
      var frames = 0;
      while (pos != target) {
        final double next = step(pos, target);
        expect((target - next).abs(), lessThanOrEqualTo((target - pos).abs()));
        // 不超调：负向逼近不得越过目标（不得比目标更负）。
        expect(next, greaterThanOrEqualTo(target), reason: '负向缓动不得越过目标（超调）');
        pos = next;
        frames++;
        expect(frames, lessThan(1000));
      }
      expect(pos, target);
    });
  });

  group('smoothScrollStep（收尾吸附 / 退化）', () {
    test('剩余距离在 snap 阈值内直接吸附到目标（消除亚像素抖动）', () {
      expect(step(99.7, 100, snap: 0.5), 100,
          reason: '不足吸附阈值的尾巴必须一次落到目标，避免无限趋近抖动');
      expect(step(-100.3, -100, snap: 0.5), -100);
    });

    test('已在目标 → 返回目标本身（remaining=0 走吸附分支）', () {
      expect(step(100, 100), 100);
      expect(step(-50, -50), -50);
    });

    test('factor=1 一帧直达目标', () {
      expect(step(0, 100, factor: 1.0), 100);
    });
  });
}
