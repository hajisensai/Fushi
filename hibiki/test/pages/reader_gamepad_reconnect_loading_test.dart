import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

/// BUG-438 / TODO-889：手柄重连后阅读器无限 loading。
///
/// 根因链（investigator 已定位 file:line）：
///   reader_hibiki_page.dart didChangeMetrics → 旧实现每帧 postFrame 直连
///   _syncPageSize（未去抖）→ 手柄连/断引发系统 inset 抖动 → 宽变判定触发
///   _navigateToChapter → navigation.part.dart _beginNavigation 置
///   _readerContentReady=false 重挂 loading 遮罩，并调 _startContentReadyTimeout。
///   旧 _startContentReadyTimeout 每次 cancel 旧 8s timer 再起新 8s（相对 deadline），
///   抖动间隔 <8s 时兜底永远被推迟、到不了点 → loading 永挂（断+重连多次抖动 →
///   「重连概率更大」）。
///
/// 修复两处根因：
///   1. didChangeMetrics 改走与 _onReaderConstraintsChanged 同一条 ~50ms 尾沿防抖
///      （_resizeRepaginateDebounce），抖动不再每帧触发重导航。
///   2. _startContentReadyTimeout 改 wall-clock 绝对 deadline（纯函数
///      contentReadyTimeoutDeadline）：抖动重武装保留旧 deadline 不外推，兜底仍能
///      到点解除 loading。
///
/// 本文件：
///   A. 纯函数 contentReadyTimeoutDeadline 行为（含抖动场景，撤修复转红）。
///   B. 源码守卫，锁死两处根因不变式 + Android 焦点框重应用加固。
void main() {
  group('contentReadyTimeoutDeadline (BUG-438 wall-clock deadline)', () {
    final DateTime t0 = DateTime(2026, 6, 27, 12, 0, 0);

    test('null existing deadline opens a fresh now+8s window', () {
      final DateTime d = contentReadyTimeoutDeadline(
        now: t0,
        existingDeadline: null,
      );
      expect(d, t0.add(const Duration(seconds: 8)));
    });

    test('expired existing deadline opens a fresh now+8s window', () {
      // 上一周期 deadline 已过期（在 now 之前）。
      final DateTime expired = t0.subtract(const Duration(seconds: 1));
      final DateTime d = contentReadyTimeoutDeadline(
        now: t0,
        existingDeadline: expired,
      );
      expect(d, t0.add(const Duration(seconds: 8)));
    });

    test('deadline exactly equal to now is treated as expired (not in future)',
        () {
      final DateTime d = contentReadyTimeoutDeadline(
        now: t0,
        existingDeadline: t0,
      );
      expect(d, t0.add(const Duration(seconds: 8)));
    });

    test('future existing deadline is PRESERVED (jitter does not extend it)',
        () {
      // 第一次武装记下 t0+8s。
      final DateTime firstDeadline = contentReadyTimeoutDeadline(
        now: t0,
        existingDeadline: null,
      );
      expect(firstDeadline, t0.add(const Duration(seconds: 8)));

      // 关键回归：手柄抖动在 8s 内反复重武装——每次都必须返回同一个 firstDeadline，
      // 绝不外推。撤掉 wall-clock 修复（回到「每次重起 8s」）则下面任一断言转红。
      for (final int dtMs in <int>[10, 100, 1000, 3000, 5000, 7990]) {
        final DateTime later = t0.add(Duration(milliseconds: dtMs));
        final DateTime d = contentReadyTimeoutDeadline(
          now: later,
          existingDeadline: firstDeadline,
        );
        expect(
          d,
          firstDeadline,
          reason: '抖动 +${dtMs}ms 时 deadline 被外推 = 无限 loading 回归',
        );
      }
    });

    test('once original deadline passes, the next arm opens a new window', () {
      // 第一次武装记下 t0+8s（值见上一个用例，这里只关心「越过后重开新窗口」）。
      // 时间越过原 deadline 后（兜底已到点 → 实现里 deadline 被清空成 null），
      // 下一次真实导航重新拿到新窗口。
      final DateTime afterFire = t0.add(const Duration(seconds: 9));
      final DateTime d = contentReadyTimeoutDeadline(
        now: afterFire,
        existingDeadline: null,
      );
      expect(d, afterFire.add(const Duration(seconds: 8)));
    });
  });

  group('BUG-438 source guards', () {
    final String readerSrc = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    final String navSrc = File(
      'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
    ).readAsStringSync();
    final String mainActivitySrc = File(
      'android/app/src/main/java/app/hibiki/reader/MainActivity.java',
    ).readAsStringSync();

    String didChangeMetricsBody() {
      final int start = readerSrc.indexOf('void didChangeMetrics()');
      expect(start, isNonNegative, reason: '找不到 didChangeMetrics');
      final int end = readerSrc.indexOf('void didChangeAppLifecycleState');
      return readerSrc.substring(start, end > start ? end : readerSrc.length);
    }

    test('didChangeMetrics no longer calls _syncPageSize via raw postFrame',
        () {
      final String body = didChangeMetricsBody();
      // 旧的未去抖直连写法（postFrame 内直接 _syncPageSize）不得复活。
      expect(
        body.contains('addPostFrameCallback'),
        isFalse,
        reason: 'didChangeMetrics 不得再用 postFrame 直连 _syncPageSize（未去抖）',
      );
    });

    test('didChangeMetrics routes through the shared ~50ms resize debounce',
        () {
      final String body = didChangeMetricsBody();
      expect(body.contains('_resizeRepaginateDebounce'), isTrue,
          reason: 'didChangeMetrics 必须经 _resizeRepaginateDebounce 去抖');
      expect(body.contains('milliseconds: 50'), isTrue,
          reason: '去抖窗口必须是 ~50ms（对齐 _onReaderConstraintsChanged）');
    });

    test('_startContentReadyTimeout uses wall-clock absolute deadline', () {
      final int start = navSrc.indexOf('void _startContentReadyTimeout()');
      expect(start, isNonNegative, reason: '找不到 _startContentReadyTimeout');
      final int end = navSrc.indexOf('void _clearContentReadyTimeout()');
      expect(end, greaterThan(start),
          reason: '找不到 _clearContentReadyTimeout（清 deadline 的配套 helper）');
      final String body = navSrc.substring(start, end);
      expect(body.contains('contentReadyTimeoutDeadline'), isTrue,
          reason: '兜底超时必须用纯函数 contentReadyTimeoutDeadline 算绝对 deadline');
      expect(body.contains('_contentReadyDeadline'), isTrue,
          reason: '必须维护 _contentReadyDeadline 绝对截止时刻字段');
      // 旧的「每次固定起 8s 相对 timer」写法不得复活。
      expect(body.contains('Timer(const Duration(seconds: 8)'), isFalse,
          reason: '不得再用固定 8s 相对 timer（抖动会反复推迟兜底 = 无限 loading）');
    });

    test('MainActivity re-applies focus-highlight suppression on resume/config',
        () {
      // 症状1 加固：disableSystemFocusHighlight 不再只挂 onCreate。
      expect(
        mainActivitySrc.contains('onConfigurationChanged'),
        isTrue,
        reason: 'MainActivity 必须 override onConfigurationChanged 重应用焦点框抑制',
      );
      final int resumeStart =
          mainActivitySrc.indexOf('protected void onResume()');
      expect(resumeStart, isNonNegative, reason: '找不到 onResume');
      final int resumeEnd =
          mainActivitySrc.indexOf('private void resumePendingInstall');
      final String resumeBody = mainActivitySrc.substring(resumeStart,
          resumeEnd > resumeStart ? resumeEnd : mainActivitySrc.length);
      expect(
        resumeBody.contains('disableSystemFocusHighlight()'),
        isTrue,
        reason: 'onResume 必须重应用 disableSystemFocusHighlight()',
      );
    });
  });
}
