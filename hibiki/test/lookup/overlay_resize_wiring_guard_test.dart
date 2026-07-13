import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Phase C（弹窗尺寸精细化 2026-07-13）源码级 guard。
///
/// 「app 外瞬态覆盖查词窗拖角 resize」这条链横跨三个无法在本环境运行验证的表面：
/// host.js（渲染 grip）→ C++（模态 size 循环 + 回报 rect + 拖拽期挂起区域裁剪）→
/// Dart controller（windowMoved → 倒推 → 解锁 + 写 overlay 键）。纯函数倒推由
/// [effective_lookup_size_test.dart] 单测守住；本 guard 直接对三处源码断言接线令牌
/// 存在，捕获「接线被删/改名」这一行为测试照样绿的失败场景。重命名回调可同步更新清单。
void main() {
  group('Phase C 覆盖窗 resize 接线', () {
    test('host.js — 瞬态 overlay ROOT 卡渲染右下角 resize grip 发 beginWindowResize',
        () {
      final File file = File('assets/popup/global_lookup_host.js');
      expect(file.existsSync(), isTrue);
      final String src = file.readAsStringSync();
      // grip 元素 + 创建函数 + 发同一 native 通路 + 只在 cascade（非 panel）ROOT 挂。
      expect(src.contains('global-lookup-resize-grip'), isTrue,
          reason: 'grip 的 class/CSS 被删——覆盖窗拖不动');
      expect(src.contains('function createResizeGrip'), isTrue,
          reason: 'createResizeGrip 接线被删');
      expect(src.contains("postToHost('beginWindowResize'"), isTrue,
          reason: 'grip 未发 beginWindowResize——进不了 native 模态 size 循环');
      expect(src.contains("layoutMode !== 'panel'"), isTrue,
          reason: 'grip 未按 cascade 门控——会漏挂到面板或漏挂瞬态窗');
    });

    test('controller — windowMoved 落 overlay 键（拖即解锁）且不串 panel/app 内键', () {
      final File file = File('lib/src/lookup/global_lookup_controller.dart');
      expect(file.existsSync(), isTrue);
      final String src = file.readAsStringSync();
      expect(src.contains("handler == 'windowMoved'"), isTrue,
          reason: 'overlay 未接 windowMoved 回报——拖完不落库');
      expect(src.contains('resolveOverlayResizeFromWindow'), isTrue,
          reason: '倒推未走同源纯函数');
      expect(src.contains('setOverlayLookupIndependentSize'), isTrue,
          reason: '拖动未解锁 overlay 独立尺寸');
      expect(src.contains('setOverlayLookupMaxWidth'), isTrue);
      expect(src.contains('setOverlayLookupMaxHeight'), isTrue);
      // 红线：覆盖窗 controller 绝不写另外两个表面的真值。
      expect(src.contains('setClipboardPanelRect'), isFalse,
          reason: '覆盖窗 resize 串写了剪贴板面板 rect——破坏面板');
      expect(src.contains('setPopupMaxWidth'), isFalse,
          reason: '覆盖窗 resize 串写了 app 内共享键——破坏 app 内弹窗');
      // 松手即时填充：_onOverlayResized 方法体内必须重触发 _renderStack，当前卡才即时
      // 长到新尺寸（否则回落到「下次查词才生效」）。切到方法边界内断言，避免全局误命中。
      final int mStart = src.indexOf('void _onOverlayResized(');
      expect(mStart, greaterThanOrEqualTo(0),
          reason: '_onOverlayResized 方法不存在/改名');
      final int mEnd = src.indexOf('void _onJsMessage(', mStart);
      final String body = src.substring(mStart, mEnd < 0 ? src.length : mEnd);
      expect(body.contains('_renderStack('), isTrue,
          reason: '拖完未重排当前卡——松手即时填充失效，退回下次查词才生效');
    });

    test('C++ — 瞬态窗放开模态 resize + 拖拽期挂起 shell 区域裁剪', () {
      final File file = File('windows/runner/global_lookup_window.cpp');
      expect(file.existsSync(), isTrue);
      final String src = file.readAsStringSync();
      expect(src.contains('WM_ENTERSIZEMOVE'), isTrue,
          reason: '未在进入模态 size 循环时挂起区域裁剪');
      expect(src.contains('resizing_'), isTrue,
          reason: 'resizing_ 门控被删——拖拽时窗口区域钉死旧卡，看不到变大');
      // 回报最终 rect 的通道保留（WM_EXITSIZEMOVE + windowMoved）。
      expect(src.contains('WM_EXITSIZEMOVE'), isTrue);
      expect(src.contains('windowMoved'), isTrue,
          reason: 'WM_EXITSIZEMOVE 不再回报窗口 rect——拖完不落库');
    });

    test('C++ header — resizing_ 成员存在', () {
      final File file = File('windows/runner/global_lookup_window.h');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync().contains('bool resizing_'), isTrue);
    });
  });
}
