import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/app_icon_apply.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// BUG-4326：原生 createCustomShortcut 抛错（如「already exists but disabled」）时，
/// Dart 侧要把它转成 [AppIconApplyException] 交给调用方给出可见失败，不能漏成
/// 未捕获的 PlatformException 落到 UncaughtZone。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannel channel = FushiChannels.iconSwitch;
  final List<MethodCall> calls = <MethodCall>[];

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) {
          calls.add(call);
          return handler(call);
        });
  }

  final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);

  test('原生返回 true：以 imageBytes 调 createCustomShortcut 并回传成功', () async {
    mockChannel((MethodCall call) async => true);

    expect(await requestAndroidCustomIconShortcut(bytes), isTrue);
    expect(calls.single.method, 'createCustomShortcut');
    expect((calls.single.arguments as Map)['imageBytes'], bytes);
  });

  test('原生返回 false / null：回传失败而不抛', () async {
    mockChannel((MethodCall call) async => false);
    expect(await requestAndroidCustomIconShortcut(bytes), isFalse);

    mockChannel((MethodCall call) async => null);
    expect(await requestAndroidCustomIconShortcut(bytes), isFalse);
  });

  test('原生抛 PlatformException：转成 AppIconApplyException 交给调用方', () async {
    const String nativeMessage =
        'Shortcut hibiki_custom_icon already exists but disabled';
    mockChannel((MethodCall call) async {
      throw PlatformException(code: 'error', message: nativeMessage);
    });

    await expectLater(
      requestAndroidCustomIconShortcut(bytes),
      throwsA(
        isA<AppIconApplyException>()
            .having(
              (AppIconApplyException e) => e.message,
              'message',
              nativeMessage,
            )
            .having(
              (AppIconApplyException e) => e.cause,
              'cause',
              isA<PlatformException>(),
            ),
      ),
    );
  });

  test('PlatformException 没有 message 时用 code 作失败原因', () async {
    mockChannel((MethodCall call) async {
      throw PlatformException(code: 'IllegalStateException');
    });

    await expectLater(
      requestAndroidCustomIconShortcut(bytes),
      throwsA(
        isA<AppIconApplyException>().having(
          (AppIconApplyException e) => e.message,
          'message',
          'IllegalStateException',
        ),
      ),
    );
  });

  // 设置页必须接住 AppIconApplyException 并给出可见提示。
  test('设置页接住 AppIconApplyException 并提示失败', () {
    final String page = File(
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ).readAsStringSync();
    expect(page, contains('on AppIconApplyException catch (e)'));
    expect(page, contains('t.icon_shortcut_failed(error: e.message)'));
  });
}
