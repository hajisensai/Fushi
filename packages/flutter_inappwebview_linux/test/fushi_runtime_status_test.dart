import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/src/fushi_runtime_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'fushi/flutter_inappwebview_linux/runtime',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    LinuxWebViewRuntime.debugReset();
  });

  void answer(Object? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'status');
      return reply;
    });
  }

  test('reports the registrar status and caches it', () async {
    answer(<String, Object?>{'available': true, 'error': ''});
    final LinuxWebViewRuntimeStatus status = await LinuxWebViewRuntime.status();
    expect(status.available, isTrue);
    expect(LinuxWebViewRuntime.cached, same(status));
    await expectLater(LinuxWebViewRuntime.ensureAvailable(), completes);
  });

  test('a missing WPE implementation degrades with the dlerror reason',
      () async {
    answer(<String, Object?>{
      'available': false,
      'error': 'libWPEWebKit-2.0.so.1: cannot open shared object file',
    });
    final LinuxWebViewRuntimeStatus status = await LinuxWebViewRuntime.status();
    expect(status.available, isFalse);
    expect(status.isUserNamespaceRestriction, isFalse);
    await expectLater(
      LinuxWebViewRuntime.ensureAvailable(),
      throwsA(
        isA<LinuxWebViewUnavailableException>().having(
          (LinuxWebViewUnavailableException e) => e.toString(),
          'message',
          allOf(contains('libWPEWebKit-2.0.so.1'), contains('Install WPE')),
        ),
      ),
    );
  });

  test('a user-namespace restriction is not reported as "install WPE"',
      () async {
    answer(<String, Object?>{
      'available': false,
      'error': 'unprivileged user namespaces are not permitted here',
    });
    final LinuxWebViewRuntimeStatus status = await LinuxWebViewRuntime.status();
    expect(status.isUserNamespaceRestriction, isTrue);
    expect(
      const LinuxWebViewUnavailableException(
        'unprivileged user namespaces are not permitted here',
      ).toString(),
      isNot(contains('Install WPE')),
    );
  });

  test('no registrar at all (MissingPluginException) means unavailable',
      () async {
    final LinuxWebViewRuntimeStatus status = await LinuxWebViewRuntime.status();
    expect(status.available, isFalse);
    expect(status.error, contains('MissingPluginException'));
  });
}
