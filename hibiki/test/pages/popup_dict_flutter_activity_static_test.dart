import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String holderPath =
      'android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt';

  test('popup engine holder runs popupMain on a cached engine', () {
    final String src = File(holderPath).readAsStringSync();
    expect(src,
        contains('FlutterEngine(context.applicationContext, null, false)'));
    expect(src, contains('GeneratedPluginRegistrant.registerWith(engine)'));
    expect(src, contains('"popupMain"'));
    expect(src, contains('executeDartEntrypoint'));
    expect(src, contains('FlutterEngineCache.getInstance()'));
    expect(src, contains('ChannelNames.POPUP'));
    final int handlerIdx = src.indexOf('setMethodCallHandler');
    final int executeIdx = src.indexOf('executeDartEntrypoint');
    expect(handlerIdx, isNonNegative);
    expect(executeIdx, isNonNegative);
    expect(handlerIdx, lessThan(executeIdx),
        reason: 'handler 必须在 executeDartEntrypoint 之前注册，否则 Dart '
            'getInitialProcessText 轮询拿不到首词');
    expect(src, contains('getInitialProcessText'));
    expect(src, contains('finishPopup'));
  });

  const String activityPath =
      'android/app/src/main/java/app/hibiki/reader/PopupDictFlutterActivity.kt';

  test('popup flutter activity is transparent, cached-engine, pushes text', () {
    final String src = File(activityPath).readAsStringSync();
    expect(src, contains('class PopupDictFlutterActivity : FlutterActivity()'));
    expect(src,
        contains('getCachedEngineId(): String = PopupEngineHolder.ENGINE_ID'));
    expect(src, contains('shouldDestroyEngineWithHost(): Boolean = false'));
    expect(src, contains('BackgroundMode.transparent'));
    expect(
        src,
        contains(
            'import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode'));
    // The :popup WebView must use its own data directory (crbug.com/558377),
    // configured before the engine renders any WebView (top of onCreate).
    expect(src, contains('WebView.setDataDirectorySuffix("popup")'));
    final int configCallIdx = src.lastIndexOf('configureWebViewDataDir()');
    final int setPendingIdx = src.indexOf('PopupEngineHolder.setPendingText');
    final int ensureIdx = src.indexOf('PopupEngineHolder.ensureEngine');
    expect(configCallIdx, isNonNegative);
    expect(configCallIdx, lessThan(setPendingIdx),
        reason: 'WebView 数据目录后缀必须在引擎/取词前配置，避免多进程 WebView 冲突');
    expect(setPendingIdx, isNonNegative);
    expect(ensureIdx, isNonNegative);
    expect(setPendingIdx, lessThan(ensureIdx),
        reason: '冷启动 executeDartEntrypoint 前必须先 setPendingText');
    expect(src, contains('PopupEngineHolder.pushProcessText'));
    expect(src, contains('override fun onNewIntent('));
    final String extractSrc = _functionSource(
      src,
      'private fun extractProcessText(intent: Intent?): String? {',
      '\n}',
    );
    final int pIdx = extractSrc.indexOf('EXTRA_PROCESS_TEXT');
    final int tIdx = extractSrc.indexOf('EXTRA_TEXT');
    final int uIdx = extractSrc.indexOf('"lookup"');
    expect(pIdx, isNonNegative);
    expect(tIdx, greaterThan(pIdx));
    expect(uIdx, greaterThan(tIdx));
    expect(src, contains('PopupEngineHolder.setOnFinish(null)'));
  });
}

String _functionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(end, greaterThan(start),
      reason: 'missing $endToken after $startToken');
  return source.substring(start, end);
}
