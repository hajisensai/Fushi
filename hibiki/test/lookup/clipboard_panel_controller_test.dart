// spec 2026-07-10 — ClipboardPanelController 的可离屏部分：rect 记忆纯函数、
// paused 语义（× 后仅 hotkey 显式意图解除）、面板栏高度跨端契约、
// dispatcher panel 分区接线守卫。运行时链（真窗口/真查词）归 M4 真机 gate。

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

    test('paused 语义：仅 hotkey 显式意图穿透暂停', () {
      expect(
        controllerSrc
            .contains('paused && request.origin != DesktopLookupOrigin.hotkey'),
        isTrue,
        reason: '× 后剪贴板事件不再打扰；Ctrl+Shift+D（显式意图）重唤并继续',
      );
    });

    test('九根 DEFERRED 桥经共享权威 handler（红线：不复制）', () {
      expect(
          controllerSrc.contains('maybeHandleOverlayDeferredBridge'), isTrue);
      expect(controllerSrc.contains('resolveBridge: _channel.resolveBridge'),
          isTrue,
          reason: '回传必须走面板自己的 channel，与瞬态窗互不串线');
    });

    test('渲染走 layoutMode panel + backdrop 门控 alpha', () {
      expect(controllerSrc.contains("layoutMode: 'panel'"), isTrue);
      expect(
        controllerSrc
            .contains('_backdropApplied ? model.clipboardPanelOpacity : 1.0'),
        isTrue,
        reason: 'backdrop 不可用时恒 alpha=1（spec §6 降级）',
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
