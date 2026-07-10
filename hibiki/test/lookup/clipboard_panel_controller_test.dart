// spec 2026-07-10 — ClipboardPanelController 的可离屏部分：rect 记忆纯函数、
// 关面板不永久暂停（BUG-717：× 只清当前卡，下一条剪贴板复制重开）、面板栏高度
// 跨端契约、dispatcher panel 分区接线守卫。运行时链（真窗口/真查词）归 M4 真机 gate。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/clipboard_panel_controller.dart';

void main() {
  group('parseClipboardPanelRect / encodeClipboardPanelRect', () {
    test('roundtrip', () {
      const Rect r = Rect.fromLTWH(120.5, 80.0, 380.0, 560.0);
      expect(parseClipboardPanelRect(encodeClipboardPanelRect(r)), r);
    });

    test('非法格式回退 null（用默认位）', () {
      expect(parseClipboardPanelRect(''), isNull);
      expect(parseClipboardPanelRect('1,2,3'), isNull);
      expect(parseClipboardPanelRect('a,b,c,d'), isNull);
      expect(parseClipboardPanelRect('0,0,NaN,100'), isNull);
    });

    test('过小尺寸=损坏记忆，弃用', () {
      expect(parseClipboardPanelRect('0,0,50,560'), isNull);
      expect(parseClipboardPanelRect('0,0,380,50'), isNull);
    });
  });

  test('面板栏高度与 host.js PANEL_BAR_HEIGHT 一致（跨端几何契约）', () {
    final String hostJs =
        File('assets/popup/global_lookup_host.js').readAsStringSync();
    expect(
      hostJs.contains(
          'var PANEL_BAR_HEIGHT = ${kClipboardPanelBarHeight.toInt()};'),
      isTrue,
      reason: 'Dart 视口计算（height - bar）与 host root shell top 偏移必须同源',
    );
  });

  group('源码接线守卫', () {
    final String controllerSrc =
        File('lib/src/lookup/clipboard_panel_controller.dart')
            .readAsStringSync();
    final String dispatcherSrc =
        File('lib/src/lookup/desktop_lookup_dispatcher.dart')
            .readAsStringSync();

    test('BUG-717：× 关面板不永久暂停，下一条剪贴板复制重开', () {
      // 旧的 paused 门（× 后丢弃非 hotkey 事件、直到 Ctrl+Shift+D 才解除）整条移除：
      // 用户「第一个关掉了第二个就出不来」的根因就是这个门。
      expect(controllerSrc.contains('bool paused'), isFalse,
          reason: 'BUG-717：paused 字段必须移除');
      expect(
        controllerSrc.contains('request.origin != DesktopLookupOrigin.hotkey'),
        isFalse,
        reason: 'BUG-717：不得再有「paused 时丢弃非 hotkey 剪贴板事件」的门',
      );
      // 正向契约：update 见 !_visible 无条件 _showPanel，故关面板（_visible=false）
      // 后下一条剪贴板复制会重开面板。
      final int updAt = controllerSrc.indexOf('Future<void> update(');
      final int visAt = controllerSrc.indexOf('if (!_visible) {', updAt);
      final int showAt =
          controllerSrc.indexOf('await _showPanel(model);', visAt);
      expect(visAt, greaterThan(updAt),
          reason: 'update 必须在 !_visible 时重新显示面板（关掉后重开的机制）');
      expect(showAt, greaterThan(visAt));
    });

    test('hidePanel 只藏窗、不设阻塞标志（关掉后下一条复制照弹）', () {
      final int hideAt = controllerSrc.indexOf('Future<void> hidePanel()');
      expect(hideAt, greaterThanOrEqualTo(0),
          reason: 'BUG-717：hidePanel 无参（不再有 pause 开关）');
      final int end = controllerSrc.indexOf('}', hideAt);
      final String body = controllerSrc.substring(hideAt, end);
      expect(body.contains('_visible = false'), isTrue);
      expect(body.contains('paused'), isFalse, reason: 'hidePanel 不得设任何暂停标志');
    });

    test('九根 DEFERRED 桥经共享权威 handler（红线：不复制）', () {
      expect(
          controllerSrc.contains('maybeHandleOverlayDeferredBridge'), isTrue);
      expect(controllerSrc.contains('resolveBridge: _channel.resolveBridge'),
          isTrue,
          reason: '回传必须走面板自己的 channel，与瞬态窗互不串线');
    });

    test('渲染走 layoutMode panel；透明=整窗 LWA_ALPHA（spec §6 真机修正）', () {
      expect(controllerSrc.contains("layoutMode: 'panel'"), isTrue);
      expect(controllerSrc.contains('setWindowAlpha'), isTrue,
          reason: '真透视=整窗 alpha；acrylic 实测经 windowed WebView2 不透明');
      expect(controllerSrc.contains('cardBgAlpha: 1.0'), isTrue,
          reason: '卡背景恒不透明，避免与整窗 alpha 双重变淡');
      expect(controllerSrc.contains('applyBackdrop'), isFalse,
          reason: 'acrylic backdrop 路线废弃（毛玻璃≠透视），面板不再调用');
    });

    test('update 每次复核 native isShowing（防渲染进被系统藏掉的隐形窗）', () {
      expect(
        controllerSrc.contains('!_visible || !await _channel.isShowing()'),
        isTrue,
        reason: '真机症状「只显示一次」：窗口被藏后 Dart _visible 仍 true，'
            '后续更新全进隐形窗',
      );
    });

    test('dispatcher panel 分区调 ClipboardPanelController.update', () {
      expect(
        dispatcherSrc.contains('ClipboardPanelController.instance.update'),
        isTrue,
      );
    });
  });
}
