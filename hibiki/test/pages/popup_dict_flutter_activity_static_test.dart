import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String holderPath =
      'android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt';

  test('popup engine holder runs popupMain on a cached engine', () {
    final String src = File(holderPath).readAsStringSync();
    expect(src, contains('FlutterEngine(context.applicationContext, null, false)'));
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
}
