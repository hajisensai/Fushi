import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3663 source-scan guard：Android app 外查词（PROCESS_TEXT / 悬浮字幕点字 /
/// 截屏识字）跑在 `:popup` 进程的副 FlutterEngine（`PopupEngineHolder` →
/// `popupMain`）。发音的本地音频库查询走 `TtsChannel.queryLocalAudio` →
/// `app.fushi.reader/tts` MethodChannel，该 channel 原先只在
/// `MainActivity.configureFlutterEngine` 的主 engine 注册：副 engine 上
/// `invokeMethod('queryLocalAudio')` 抛 MissingPluginException，被 TtsChannel 吞成
/// null，用户点 ♪ 只看到「暂无发音」，而 app 内同一个词有发音。
///
/// 真机 MethodChannel 注册跑在 Android 原生层（这里跑不了），故守注册机制：副 engine
/// 的唯一插件注册点必须注册 TtsChannelHandler，而 TtsChannelHandler 必须能只拿
/// Context 构造（副 engine 没有 Activity）。
void main() {
  final File registrant = File(
    'android/app/src/main/java/app/fushi/reader/FloatingDictPluginRegistrant.java',
  );
  final File ttsHandler = File(
    'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
  );

  String compact(File f) =>
      f.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');

  test('popup engine registrant registers the tts channel', () {
    expect(
      RegExp(
        r'new TtsChannelHandler\(context\)\s*\.register\(flutterEngine\)',
      ).hasMatch(compact(registrant)),
      isTrue,
      reason:
          'BUG-3663: 副 engine 不注册 app.fushi.reader/tts 时，app 外查词的'
          '本地音频库查询抛 MissingPluginException → 「暂无发音」。',
    );
  });

  test('TtsChannelHandler needs only a Context (no Activity)', () {
    final String src = compact(ttsHandler);
    expect(
      src.contains('public TtsChannelHandler(Context context)'),
      isTrue,
      reason: 'BUG-3663: 副 engine 只有 applicationContext，构造器不能要求 Activity。',
    );
    expect(
      RegExp(r'\bactivity\.').hasMatch(src),
      isFalse,
      reason:
          'BUG-3663: handler 不得再调用 Activity 专属 API（runOnUiThread 等），'
          '否则在副 engine 上无法构造。',
    );
  });
}
