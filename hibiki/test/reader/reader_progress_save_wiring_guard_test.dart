import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-736 接线守卫（源码扫描）：锁住 B-3/B-4/用户输入通道的纯函数确实**被调用**，
/// 而不只是定义在文件里（纯函数真值表单测保证逻辑正确，本守卫保证它们接进了真实路径）。
void main() {
  final String webview = File(
    'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
  ).readAsStringSync();
  final String navigation = File(
    'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
  ).readAsStringSync();
  final String chrome = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
  ).readAsStringSync();
  final String page = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  group('必补点1：用户输入时间戳通道', () {
    test('setup 脚本三处输入监听都打 onReaderUserInput', () {
      expect(webview, contains('_hoshiNotifyUserInput'),
          reason: 'setup 脚本须有节流的用户输入回传 helper');
      expect(webview, contains("callHandler('onReaderUserInput')"),
          reason: 'helper 必须回传 onReaderUserInput');
      // touchstart / pointerdown / wheel 三处都调 _hoshiNotifyUserInput()。
      final int calls =
          RegExp(r'_hoshiNotifyUserInput\(\)').allMatches(webview).length;
      expect(calls, greaterThanOrEqualTo(3),
          reason:
              'touchstart/pointerdown/wheel 三处输入监听都须调 _hoshiNotifyUserInput()');
    });

    test('Dart 注册 onReaderUserInput handler 写 _lastUserInputAt', () {
      expect(webview, contains("handlerName: 'onReaderUserInput'"),
          reason: '必须注册 onReaderUserInput handler');
      expect(webview, contains('_lastUserInputAt = DateTime.now()'),
          reason: 'handler 必须更新 _lastUserInputAt 时间戳');
    });
  });

  group('B-3：settle 尾沿去抖接进 _handleReaderScroll', () {
    test('_handleReaderScroll 进门调 readerScrollWithinReanchorSettle 并 return',
        () {
      final int idx = navigation.indexOf('void _handleReaderScroll() {');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = navigation.indexOf('\n  }', idx);
      final String body = navigation.substring(idx, end);
      expect(body, contains('readerScrollWithinReanchorSettle'),
          reason: '_handleReaderScroll 必须先判 settle 去抖窗');
      expect(body, contains('_reanchorClearedAt'),
          reason: '去抖判据须读 _reanchorClearedAt');
    });
  });

  group('B-4：突降伪归零接进 _refreshProgress 的落库闸门', () {
    test('_refreshProgress 调 readerProgressDropIsSpurious 并据此 gate 落库', () {
      expect(navigation, contains('readerProgressDropIsSpurious'),
          reason: '_refreshProgress 必须调突降伪归零判定');
      expect(navigation, contains('if (!spuriousDrop)'),
          reason: '伪归零必须跳过 _debouncedSavePosition 落库（非伪才落）');
      expect(navigation, contains('_lastUserInputAt'),
          reason: 'B-4 判据须读 _lastUserInputAt 算近期输入');
    });
  });

  group('B-1：样式重锚两阶段编排接进 _applyStylesLive', () {
    test('_applyStylesLive 调 _reanchorForStyleChange', () {
      expect(page, contains('_reanchorForStyleChange'),
          reason: '_applyStylesLive 必须走样式重锚编排');
    });

    test('_reanchorForStyleChange 用样式专入口 + 编排 + 打 _reanchorClearedAt', () {
      final int idx = chrome.indexOf('Future<void> _reanchorForStyleChange(');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = chrome.indexOf('\n  }\n', idx);
      final String body = chrome.substring(idx, end < 0 ? chrome.length : end);
      expect(body, contains('runUiScaleReanchorOrchestration'),
          reason: '复用两阶段 begin→commit settle-aware 编排');
      expect(body, contains('beginStyleReanchorInvocation'),
          reason: '用样式专用 begin 入口（不复用 appUiScale 那对）');
      expect(body, contains('commitStyleReanchorInvocation'),
          reason: '用样式专用 commit 入口');
      expect(body, contains('readerStyleReanchorAllowed'),
          reason: '门控走 readerStyleReanchorAllowed（两模式都放行）');
      expect(body, contains('_reanchorClearedAt = DateTime.now()'),
          reason: 'commit 完成须打 _reanchorClearedAt 供 B-3 去抖');
    });
  });
}
