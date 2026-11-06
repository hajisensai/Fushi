/// 系统语音原生半边的静态守卫（「Fushi 用系统语音读不到系统 TTS 引擎」）。
///
/// 这些地方写错**不会报错**：清单少一条 `<queries>` 时 app 照样编译、照样跑，只是
/// 第三方 TTS 引擎对 Fushi 不可见（targetSdk 30+ 包可见性）——用户看到的是「别的软件
/// 能用系统 TTS、Fushi 不能」；iOS 的 Swift 漏登记进 pbxproj 时本机与 CI 的 Dart 测试
/// 全绿，要到 Mac 上编译才发现。所以逐条钉住。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test('Android 清单在 <queries> 里声明了 TTS_SERVICE（第三方引擎可见）', () {
    final String manifest = maskComments(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final int start = manifest.indexOf('<queries>');
    final int end = manifest.indexOf('</queries>');
    expect(start, isNonNegative);
    expect(
      manifest.substring(start, end),
      contains('<action android:name="android.intent.action.TTS_SERVICE" />'),
    );
  });

  test('Android 原生：列引擎 / 列声音 / 按引擎与声音合成三条都接上了', () {
    final String handler = maskComments(
      File(
        'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
      ).readAsStringSync(),
    );
    final String controller = maskComments(
      File(
        'android/app/src/main/java/app/fushi/reader/SystemTtsController.java',
      ).readAsStringSync(),
    );
    expect(handler, contains('case "getEngines":'));
    expect(handler, contains('case "getVoices":'));
    expect(handler, contains('call.argument("engine")'));
    expect(handler, contains('call.argument("voice")'));
    // 按包名绑引擎；只用两参构造器就又只能绑默认引擎了。
    expect(controller, contains('new TextToSpeech(context, listener, engine)'));
    // 列引擎问 PackageManager（与清单那条查询声明配对）。
    expect(
      controller,
      contains('TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE'),
    );
    expect(controller, contains('"VOICE_UNAVAILABLE"'));
    // handler 拆除时释放引擎实例、答复排队请求。
    expect(handler, contains('systemTts.destroy()'));
  });

  test('iOS：FushiSystemTts 注册到同名通道并登记进 Xcode 工程（四处齐全）', () {
    final String swift = maskComments(
      File('ios/Runner/FushiSystemTts.swift').readAsStringSync(),
    );
    final String dartChannel = File(
      'lib/src/utils/misc/channel_constants.dart',
    ).readAsStringSync();
    expect(dartChannel, contains("MethodChannel('\$_prefix/tts')"));
    expect(swift, contains('"app.fushi.reader/tts"'));
    expect(swift, contains('case "ttsToFile":'));
    expect(swift, contains('case "getVoices":'));
    expect(
      File('ios/Runner/AppDelegate.swift').readAsStringSync(),
      contains('FushiSystemTts.register(binaryMessenger:'),
    );
    final String pbx = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(pbx, contains('path = FushiSystemTts.swift;'));
    expect(
      pbx,
      contains('/* FushiSystemTts.swift in Sources */ = {isa = PBXBuildFile;'),
    );
    expect('/* FushiSystemTts.swift */,'.allMatches(pbx).length, 1);
    expect('/* FushiSystemTts.swift in Sources */,'.allMatches(pbx).length, 1);
  });

  test('Dart 侧 iOS 的语音方法走原生通道（不是桌面实现）', () {
    final String channel = File(
      'lib/src/utils/misc/tts_channel.dart',
    ).readAsStringSync();
    expect(
      channel,
      contains(
        'static bool get _nativeSpeech => Platform.isAndroid || Platform.isIOS;',
      ),
    );
  });
}
