/// 悬浮球的平台通道 `app.fushi.reader/floating_ball`（契约见
/// `docs/specs/2026-09-28-floating-ball.md`）。
///
/// Android：原生系统悬浮球服务 + MediaProjection 截屏 OCR；iOS：截自己的窗口 +
/// App Intent 查词入口。其它平台原生侧没有实现，这里一律按「没有」处理，不抛错。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

class FloatingBallChannel {
  FloatingBallChannel._();

  static const MethodChannel channel = MethodChannel(
    'app.fushi.reader/floating_ball',
  );

  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error, stack) {
      ErrorLogService.instance.log('floating_ball.$method', error, stack);
      return null;
    }
  }

  // ── Android ──────────────────────────────────────────────────────────

  static Future<bool> canDrawOverlays() async =>
      await _invoke<bool>('canDrawOverlays') ?? false;

  static Future<void> requestOverlayPermission() =>
      _invoke<void>('requestOverlayPermission');

  /// 启动系统悬浮球；没有悬浮窗权限时返回 false。[labels] 是按钮文案（原生侧
  /// 不维护多语言），键为动作 id 加 `open_app` / `close` / `notification`。
  static Future<bool> startSystemBall({
    required List<String> actions,
    required Map<String, String> labels,
    required String ocrLanguage,
  }) async =>
      await _invoke<bool>('startSystemBall', <String, Object?>{
        'actions': actions,
        'labels': labels,
        'ocrLanguage': ocrLanguage,
      }) ??
      false;

  static Future<void> stopSystemBall() => _invoke<void>('stopSystemBall');

  static Future<bool> isSystemBallRunning() async =>
      await _invoke<bool>('isSystemBallRunning') ?? false;

  /// Fushi 在前台时原生球隐藏（由 Flutter 球接管），退到后台再露出来。
  static Future<void> setAppForeground(bool foreground) => _invoke<void>(
    'setAppForeground',
    <String, Object?>{'foreground': foreground},
  );

  /// 走原生截屏 OCR 流程（系统同意框 → 截一帧 → 识别 → 点字查词）。返回流程
  /// 是否已启动；false 多半是缺悬浮窗权限。
  static Future<bool> startScreenOcr({
    required String language,
    required Map<String, String> labels,
  }) async =>
      await _invoke<bool>('startScreenOcr', <String, Object?>{
        'language': language,
        'labels': labels,
      }) ??
      false;

  // ── iOS ─────────────────────────────────────────────────────────────

  /// 截 app 自己的窗口，返回物理像素 PNG；失败返回 null。
  static Future<Uint8List?> captureScreen() =>
      _invoke<Uint8List>('captureScreen');

  // ── 原生 → Dart ─────────────────────────────────────────────────────

  static bool _handlerInstalled = false;

  /// 装原生回调：
  ///  - `lookupFromIntent {word}`（iOS App Intent「在 Fushi 中查词」）→ [onLookup]；
  ///  - `screenOcrFinished`（Android 截屏 OCR 已截到帧或已放弃）→ [onScreenOcrFinished]。
  ///
  /// 必须先装 handler、再取冷启动时排队的那个词：iOS 原生侧把这次 take 当作
  /// 「Dart 已就绪」的信号，之后才会直接推送。
  static Future<void> installHandler({
    required void Function(String word) onLookup,
    required void Function() onScreenOcrFinished,
  }) async {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'lookupFromIntent':
          final Object? args = call.arguments;
          final Object? word = args is Map ? args['word'] : null;
          if (word is String && word.trim().isNotEmpty) onLookup(word.trim());
        case 'screenOcrFinished':
          onScreenOcrFinished();
      }
      return null;
    });
    if (!Platform.isIOS) return;
    final String? pending = await _invoke<String>('takePendingIntentLookup');
    if (pending != null && pending.trim().isNotEmpty) {
      onLookup(pending.trim());
    }
  }

  @visibleForTesting
  static void debugResetHandler() {
    _handlerInstalled = false;
    channel.setMethodCallHandler(null);
  }
}
