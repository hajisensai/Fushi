import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-607 P0-1/①：main.dart 必须装 PlatformDispatcher.onError，并让致命级错误
/// （FlutterError / UncaughtZone / PlatformDispatcher）走同步 flush 落盘。
///
/// 此前 main.dart 只有 FlutterError.onError + runZonedGuarded 的 onError，平台/引擎
/// 层未捕获的异步错误（platform message handler、原生回调、microtask）不经这两条，
/// 走 PlatformDispatcher.onError——没装这个钩子时这类错误对错误日志完全不可见
/// （用户报「嵌套查词闪退、错误日志一片空白」的一类来源）。
///
/// native 闪退无法在 host 单测复现，用源码扫描守卫钉住这条启动配置不被回归删除
/// （与 BUG-070 media_kit pitch 守卫同范式）。
void main() {
  late String src;

  setUp(() {
    src = File('lib/main.dart').readAsStringSync();
  });

  test('main.dart 装载 PlatformDispatcher.instance.onError', () {
    expect(
      RegExp(r'PlatformDispatcher\.instance\.onError\s*=').hasMatch(src),
      isTrue,
      reason: '必须装 PlatformDispatcher.onError，否则平台层异步错误对错误日志不可见',
    );
  });

  test('PlatformDispatcher.onError 写错误日志（致命级同步落盘）并返回 true', () {
    // onError 回调体里必须把错误写进 ErrorLogService（致命级 logFatal）。
    expect(
      src.contains("ErrorLogService.instance.logFatal('PlatformDispatcher'"),
      isTrue,
      reason: 'PlatformDispatcher 异常必须经 logFatal 同步落盘',
    );
    // 必须返回 true，标记「已处理」，避免引擎再当未处理崩溃重复上报。
    expect(
      RegExp(r'PlatformDispatcher\.instance\.onError\s*=\s*\([^)]*\)\s*\{[^}]*return true;',
              dotAll: true)
          .hasMatch(src),
      isTrue,
      reason: 'onError 必须返回 true',
    );
  });

  test('致命级错误（FlutterError / UncaughtZone）走 logFatal 同步 flush', () {
    expect(
      src.contains(
              "ErrorLogService.instance.logFatal(\n        'FlutterError") ||
          RegExp(r"logFatal\(\s*'FlutterError").hasMatch(src),
      isTrue,
      reason: 'FlutterError 是致命级，须 logFatal 同步落盘（崩溃前存活）',
    );
    expect(
      RegExp(r"logFatal\('UncaughtZone'").hasMatch(src),
      isTrue,
      reason: 'runZonedGuarded 的 UncaughtZone 须 logFatal 同步落盘',
    );
  });

  test('logFatal 用 writeAsStringSync(flush:true) 同步落盘（崩溃前存活）', () {
    final String svc =
        File('lib/src/utils/misc/error_log_service.dart').readAsStringSync();
    final int idx = svc.indexOf('void logFatal(');
    expect(idx, isNonNegative, reason: '必须有 logFatal 方法');
    // logFatal 方法体内用同步 flush 写文件。
    final String body = svc.substring(idx, idx + 800);
    expect(
      RegExp(r'writeAsStringSync\([^;]*flush:\s*true', dotAll: true)
          .hasMatch(body),
      isTrue,
      reason: 'logFatal 必须同步 flush 落盘，否则崩溃前来不及写盘',
    );
  });
}
