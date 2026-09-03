import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/android_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 原生桥回传的诊断信息必须一路活到 UI。
///
/// 之前 Android 侧把任意 `Throwable` 换成一句固定的
/// `Mihon extension operation failed`，Dart 侧又从不读 `PlatformException.details`，
/// 于是「点开漫画报错」在两端都查不出原因（BUG-1767）。这条用例把 code / message /
/// details 三者的透传钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('app.fushi.reader/mihon');
  const MihonExtensionRef extension = MihonExtensionRef(
    packageName: 'org.example.fixture',
    apkPath: 'extensions/org.example.fixture.ext',
  );
  const MihonSource source = MihonSource(
    extensionPackage: 'org.example.fixture',
    id: '1',
    name: 'Fixture',
    language: 'en',
    baseUrl: 'https://example.test',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('platform failures keep their code, message and native stack', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(
        code: 'RUNTIME_FAILURE',
        message: 'Mihon invoke/getDetailsManga failed: '
            'NoClassDefFoundError: kotlin.LazyKt',
        details: 'java.lang.NoClassDefFoundError\n\tat fixture.Stack',
      );
    });

    final AndroidMihonRuntime runtime = AndroidMihonRuntime();
    await expectLater(
      runtime.getDetails(
        extension,
        source,
        const MihonManga(url: '/manga/fixture', title: 'Fixture'),
      ),
      throwsA(
        isA<MihonRuntimeException>()
            .having(
                (MihonRuntimeException e) => e.code, 'code', 'RUNTIME_FAILURE')
            .having((MihonRuntimeException e) => e.message, 'message',
                contains('getDetailsManga'))
            .having((MihonRuntimeException e) => e.details, 'details',
                contains('at fixture.Stack'))
            .having((MihonRuntimeException e) => e.diagnostics, 'diagnostics',
                allOf(contains('kotlin.LazyKt'), contains('at fixture.Stack'))),
      ),
    );
  });

  test('a failure without native details still renders its message', () {
    const MihonRuntimeException error =
        MihonRuntimeException('IMAGE_HTTP', 'Source image request failed');
    expect(error.details, isNull);
    expect(error.diagnostics, error.toString());
    expect(
      error.toString(),
      'MihonRuntimeException(IMAGE_HTTP): Source image request failed',
    );
  });
}
