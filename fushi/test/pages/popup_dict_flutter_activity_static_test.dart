import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String holderPath =
      'android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt';

  test('popup engine holder runs popupMain on a cached engine', () {
    final String src = File(holderPath).readAsStringSync();
    expect(src,
        contains('FlutterEngine(context.applicationContext, null, false)'));
    expect(src,
        contains('FloatingDictPluginRegistrant.registerWith(engine, context.applicationContext)'));
    expect(src, isNot(contains('GeneratedPluginRegistrant')));
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
      'android/app/src/main/java/app/fushi/reader/PopupDictFlutterActivity.kt';

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
    // BUG-1757：关闭回调改成**按注册方作用域**。旧写法 `setOnFinish(null)` 是裸字段，
    // 任何实例都能清掉任何实例的回调；Android 的「新实例 onCreate → 旧实例 onDestroy」
    // 顺序让「关一个查词窗、紧接着查下一个词」必然踩中，表现为弹窗关不掉。
    expect(src, contains('PopupEngineHolder.setOnFinish(this)'),
        reason: '注册必须带 owner，holder 才知道该不该让某个实例注销');
    expect(src, contains('PopupEngineHolder.clearOnFinish(this)'),
        reason: '注销必须带 owner——旧 Activity 不能清掉新窗刚注册的回调');
    expect(src, isNot(contains('setOnFinish(null)')),
        reason: '无条件清空入口存在多久，这个竞态就存在多久（BUG-1757 有意不留）');
  });

  // BUG-193 / TODO-110: the :popup Flutter engine renders dictionary entries in
  // a flutter_inappwebview WebView (DictionaryPopupWebView). The hand-written
  // FloatingDictPluginRegistrant (introduced by BUG-146 to drop the dev-only
  // integration_test plugin) must still register the runtime plugins the popup
  // render path actually uses, or the WebView platform view never builds and the
  // result area stays blank.
  test('floating dict registrant registers popup-render runtime plugins', () {
    const String registrantPath =
        'android/app/src/main/java/app/fushi/reader/FloatingDictPluginRegistrant.java';
    final String src = File(registrantPath).readAsStringSync();
    // Root cause: word entries render in an InAppWebView platform view.
    expect(
        src,
        contains(
            'com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin'),
        reason: 'popup 引擎用 InAppWebView 渲染词条，漏注册它结果区永久空白');
    // Word-entry external links call launchUrl (DictionaryPopupWebView).
    expect(src, contains('io.flutter.plugins.urllauncher.UrlLauncherPlugin'),
        reason: '词条外链点击走 url_launcher，缺它外链点击无反应');
    // Must NOT drag the dev-only integration_test plugin back in (BUG-146).
    expect(src, isNot(contains('integration_test')),
        reason: 'popup 引擎不得带回 integration_test dev 插件（BUG-146 初衷）');
    expect(src, isNot(contains('IntegrationTestPlugin')),
        reason: 'popup 引擎不得带回 integration_test dev 插件（BUG-146 初衷）');
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
