import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// TODO-1392 观测性根治守卫：查词弹窗 JS 渲染路径（`renderPopup` / `__hibikiContainer`）
/// 抛异常此前只 `console.error` → `onConsoleMessage` → `debugPrint`（永不进错误日志），
/// uncaught 更彻底静默（popup.js 无 `window.onerror`）。BUG-706 那类 `__hibikiRoot` 命名
/// 冲突致 renderPopup TypeError 中止渲染时，用户看到「弹窗空白 + 错误日志为空」无从排查。
///
/// 根治：popup.js 顶层装全局 `window.onerror` / `unhandledrejection` + 渲染 catch，经
/// `window.flutter_inappwebview.callHandler('reportJsError', {source,message,stack})` 桥回传，
/// Dart 侧 `DictionaryPopupWebView` 注册 `reportJsError` handler → [logPopupJsError] →
/// [ErrorLogService.log]（错误日志页可见，复用 TODO-1383 序列化落盘链）。
///
/// 三层验证：
///  ① 行为：JS 报错 payload → [logPopupJsError] → error_log 有 `PopupJs.<source>` 记录
///     （含 message + stack）。这是「报错中止了，为什么错误日志是空的」的正向证据。
///  ② 源码守卫（JS）：三镜像 popup.js 都装了全局 error/unhandledrejection 监听 + 渲染 catch
///     路由，且经 reportJsError 桥上报——防回归把观测性摘掉。
///  ③ 源码守卫（Dart）：弹窗 WebView 注册 reportJsError handler 并调 logPopupJsError。
///
/// flutter test cwd 为 hibiki 包根。
void main() {
  group('① 行为：JS 报错 → error_log 有记录（TODO-1392）', () {
    setUp(() async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('popup_js_err_test');
      await ErrorLogService.instance.init(directoryOverride: tmp);
      await ErrorLogService.instance.clear();
    });

    test('uncaught renderPopup 报错 payload 落进 entries（含 message + stack）', () {
      final ErrorLogService svc = ErrorLogService.instance;
      expect(svc.entries, isEmpty, reason: 'clear 后应为空');

      // 模拟 popup.js window.onerror 捕获 BUG-706 那类 renderPopup 中止异常后经桥回传的 args。
      logPopupJsError(svc, <dynamic>[
        <String, dynamic>{
          'source': 'window.onerror',
          'message': 'TypeError: window.__hibikiRoot is not a function',
          'stack': 'at __hibikiContainer (popup.js:6:44)\n'
              'at renderPopup (popup.js:2750:23)',
        },
      ]);

      expect(svc.entries.length, 1, reason: 'JS 报错必须进用户可见错误日志（不再静默空白）');
      final ErrorLogEntry e = svc.entries.single;
      expect(e.source, 'PopupJs.window.onerror');
      expect(e.error, contains('TypeError'));
      expect(e.error, contains('__hibikiRoot'));
      expect(e.stackTrace, isNotNull);
      expect(e.stackTrace, contains('renderPopup'));
    });

    test('渲染 catch（renderPopup.firstEntry）与未处理 rejection 都能落日志', () {
      final ErrorLogService svc = ErrorLogService.instance;
      logPopupJsError(svc, <dynamic>[
        <String, dynamic>{
          'source': 'renderPopup.firstEntry',
          'message': 'RangeError: bad glossary index',
          'stack': 'at buildEntryElement (popup.js:1200:9)',
        },
      ]);
      logPopupJsError(svc, <dynamic>[
        <String, dynamic>{
          'source': 'unhandledrejection',
          'message': 'lookup FFI rejected',
          'stack': '',
        },
      ]);
      expect(svc.entries.length, 2);
      expect(
          svc.entries.map((ErrorLogEntry e) => e.source),
          containsAll(<String>[
            'PopupJs.renderPopup.firstEntry',
            'PopupJs.unhandledrejection'
          ]));
      // 空 stack 不带栈（不伪造），message 仍在。
      final ErrorLogEntry rej = svc.entries.firstWhere(
          (ErrorLogEntry e) => e.source == 'PopupJs.unhandledrejection');
      expect(rej.stackTrace, isNull);
      expect(rej.error, contains('lookup FFI rejected'));
    });

    test('缺字段 / 非 Map args 也稳健（永不抛、留占位）', () {
      final ErrorLogService svc = ErrorLogService.instance;
      logPopupJsError(svc, <dynamic>[]); // 空 args
      logPopupJsError(svc, <dynamic>['not-a-map']); // 非 Map
      logPopupJsError(svc, <dynamic>[<String, dynamic>{}]); // 空对象
      expect(svc.entries.length, 3, reason: '每条都进日志，不吞');
      for (final ErrorLogEntry e in svc.entries) {
        expect(e.source, 'PopupJs.unknown');
        expect(e.error, '(no message)');
      }
    });
  });

  group('② 源码守卫（popup.js 三镜像装了全局 JS 错误上报）', () {
    const List<String> mirrors = <String>[
      'assets/popup/popup.js',
      'assets/browser_extension/vendor/popup.js',
      '../tools/browser-extension/vendor/popup.js',
    ];

    for (final String rel in mirrors) {
      test('[$rel] 装全局 error/unhandledrejection 监听 + reportJsError 桥', () {
        final String js = File(rel).readAsStringSync();
        expect(js.contains('window.__hibikiReportJsError'), isTrue,
            reason: '$rel 丢了全局上报入口 __hibikiReportJsError（观测性回归）');
        expect(js.contains("window.addEventListener('error'"), isTrue,
            reason: '$rel 丢了 window.onerror 监听（uncaught JS 错误又会静默）');
        expect(
            js.contains("window.addEventListener('unhandledrejection'"), isTrue,
            reason: '$rel 丢了未处理 Promise rejection 监听');
        expect(js.contains("callHandler('reportJsError'"), isTrue,
            reason: '$rel 未经 reportJsError 桥上报到 Dart');
        // 渲染 catch 路由：BUG-706 那类 renderPopup 中止必须能被上报。
        expect(js.contains("'renderPopup.firstEntry'"), isTrue,
            reason: '$rel renderPopup first-entry catch 未路由到错误上报');
      });
    }
  });

  group('③ 源码守卫（Dart 弹窗 WebView 注册 reportJsError → error_log）', () {
    test('DictionaryPopupWebView 注册 reportJsError 并调 logPopupJsError', () {
      final String src =
          File('lib/src/pages/implementations/dictionary_popup_webview.dart')
              .readAsStringSync();
      expect(src.contains("handlerName: 'reportJsError'"), isTrue,
          reason: '弹窗 WebView 必须注册 reportJsError handler（否则 JS 上报无处落）');
      expect(src.contains('logPopupJsError(ErrorLogService.instance, args)'),
          isTrue,
          reason:
              'reportJsError handler 必须调 logPopupJsError 写进 ErrorLogService');
    });
  });
}
