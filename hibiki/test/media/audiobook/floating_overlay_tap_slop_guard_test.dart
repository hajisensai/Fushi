import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard for TODO-1268 — 「点击悬浮字幕文字没反应」的**更深根因**。
///
/// BUG-598 修好了点词后的 *启动*（background-activity-launch），但它假设点击已经
/// 送达 [FloatingLyricService.handleTap]。真正在高密度手机上把点击吞掉的，是
/// [BaseFloatingService] 里 tap/drag 的判别阈值：原来硬编码 `> 10` **物理像素**，
/// 远低于平台的 touch slop（`ViewConfiguration.getScaledTouchSlop()`，约 8dp ≈
/// 20-28px）。手指轻微滚动几 dp 的普通点击就被判成拖动，`ACTION_UP` 走了 drag 分支，
/// `onOverlayTapped` 从不触发 → 点词没反应。控制按钮走各自 `OnClickListener`，不经
/// 这条判别，所以「按钮正常、点字不灵」——正是用户反馈的现象。
///
/// 修复：阈值改用平台 tap/drag 边界 `getScaledTouchSlop()`。原生触摸无法在 host 上
/// 运行、也无法离屏复现悬浮窗时序，故这里在源码层钉住「阈值来源 = 平台 slop」防回归
/// （真机验收另行）。这条守卫同时覆盖复用 [BaseFloatingService] 的 FloatingDictService。
void main() {
  const String base =
      '../hibiki/android/app/src/main/java/app/hibiki/reader/BaseFloatingService.java';

  String read() => File(base).readAsStringSync().replaceAll('\r\n', '\n');

  /// setupDragListener 函数体（签名 → 紧随其后的 dragSlopPx helper 声明）。
  String dragListenerBody(String src) {
    const String sig = 'protected void setupDragListener()';
    final int at = src.indexOf(sig);
    expect(at, greaterThanOrEqualTo(0), reason: 'setupDragListener 必须存在');
    final int end = src.indexOf('private int dragSlopPx()', at);
    expect(end, greaterThan(at),
        reason: 'TODO-1268：拖动阈值必须解析自集中的 dragSlopPx helper');
    return src.substring(at, end);
  }

  group('TODO-1268 悬浮窗 tap/drag 判别用平台 touch slop', () {
    test('拖动阈值来源是 ViewConfiguration.getScaledTouchSlop()', () {
      final String src = read();
      expect(src.contains('import android.view.ViewConfiguration;'), isTrue,
          reason: '需引入 ViewConfiguration 才能取平台 tap/drag 边界');
      expect(src.contains('getScaledTouchSlop()'), isTrue,
          reason: '拖动阈值必须取平台 tap/drag 边界，否则普通点击被判成拖动、'
              '吞掉悬浮字幕点词');
    });

    test('drag-move 判别比较平台 slop，不再是 sub-slop 魔法数 10', () {
      final String body = dragListenerBody(read());
      expect(body.contains('dragSlopPx()'), isTrue,
          reason: 'ACTION_MOVE 的拖动判别必须比较解析出的平台 slop');
      // 绝不再出现 `> 10` 的裸阈值——10px 远低于 8dp touch slop，会把普通点击
      // 误判成拖动，onOverlayTapped 从不触发。
      expect(RegExp(r'>\s*10\b').hasMatch(body), isFalse,
          reason: '10px 远低于平台 touch slop，会把普通点击误判成拖动、吞掉查词');
    });

    test('touchSlop 在 onCreate 解析后，drag 判别绝不看到 -1 哨兵', () {
      final String src = read();
      // onCreate 里解析一次，且 helper 里有 <0 的懒解析兜底，任何触摸都拿到正值。
      expect(
          src.contains('touchSlopPx = ViewConfiguration.get(this)'
              '.getScaledTouchSlop();'),
          isTrue,
          reason: 'onCreate 必须解析一次平台 slop');
      expect(src.contains('if (touchSlopPx < 0)'), isTrue,
          reason: 'dragSlopPx 必须对哨兵 -1 懒解析兜底，避免「阈值 -1 → 一切皆拖动」');
    });
  });
}
