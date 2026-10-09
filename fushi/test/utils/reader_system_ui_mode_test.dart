import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

import '../helpers/source_guard.dart';

/// BUG-3077 守卫：小说阅读器正文就绪时声明的系统 UI 模式。
///
/// Flutter 3.47 的 Android `PlatformPlugin.enableEdgeToEdge()` 先
/// `decorView.setSystemUiVisibility(0)`，会清掉 `openMedia` 设下的
/// IMMERSIVE_STICKY；阅读器内容就绪时原先的裸 `edgeToEdge` 因此把状态栏 /
/// 导航栏叫了回来，`viewPadding.top` 从挖孔安全区涨到状态栏高，经
/// `_readerTopOffset` → `--chrome-top-inset` 原样加进正文 padding-top（用户报
/// 「顶部边距变大」）。这里钉两件事：helper 发出的模式按平台正确（行为测试，走
/// 真实 SystemChannels.platform），以及阅读器不再绕过 helper 裸设系统 UI 模式
/// （源码守卫——host runner 上 Platform.isAndroid 恒 false，Android 分支只能靠
/// 显式参数与源码守卫覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<List<MethodCall>> captureModeCalls(
    Future<void> Function() action,
  ) async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          calls.add(call);
          return null;
        });
    await action();
    return calls
        .where(
          (MethodCall c) =>
              c.method.startsWith('SystemChrome.setEnabledSystemUI'),
        )
        .toList();
  }

  test(
    'Android reader keeps the system bars hidden (immersiveSticky, never edgeToEdge)',
    () async {
      final List<MethodCall> modeCalls = await captureModeCalls(
        () => setReaderSystemUiMode(android: true),
      );
      expect(
        modeCalls,
        hasLength(1),
        reason: 'the reader declares exactly one system-UI mode',
      );
      expect(modeCalls.single.method, 'SystemChrome.setEnabledSystemUIMode');
      expect(
        modeCalls.single.arguments,
        SystemUiMode.immersiveSticky.toString(),
        reason:
            'Flutter 3.47 edgeToEdge clears IMMERSIVE_STICKY on Android: the '
            'status bar comes back and its height lands in the text top inset',
      );
    },
  );

  test('iOS / desktop reader keeps edgeToEdge (unchanged behaviour)', () async {
    final List<MethodCall> modeCalls = await captureModeCalls(
      () => setReaderSystemUiMode(android: false),
    );
    expect(modeCalls, hasLength(1));
    expect(modeCalls.single.arguments, SystemUiMode.edgeToEdge.toString());
  });

  test('readerSystemUiMode maps the platform to the declared mode', () {
    expect(readerSystemUiMode(android: true), SystemUiMode.immersiveSticky);
    expect(readerSystemUiMode(android: false), SystemUiMode.edgeToEdge);
  });

  test('reader page never sets a system-UI mode around the helper', () {
    final List<File> readerSources = <File>[
      File('lib/src/pages/implementations/reader_fushi_page.dart'),
      ...Directory('lib/src/pages/implementations/reader_fushi')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart')),
    ];
    expect(readerSources.length, greaterThan(1));
    for (final File file in readerSources) {
      final String src = file.readAsStringSync();
      expect(
        src.contains('setEnabledSystemUIMode'),
        isFalse,
        reason:
            '${file.path} sets a system-UI mode directly; the novel reader '
            'must go through setReaderSystemUiMode() (BUG-3077)',
      );
    }
    final String navigation = File(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    ).readAsStringSync();
    expect(
      navigation.contains('setReaderSystemUiMode()'),
      isTrue,
      reason: 'content-ready must declare the reader system-UI mode',
    );
  });

  test('helper on Android sends immersiveSticky, not a bare edgeToEdge', () {
    final String src = File(
      'lib/src/utils/misc/platform_utils.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');
    expect(
      src.contains(
        'android?SystemUiMode.immersiveSticky:SystemUiMode.edgeToEdge',
      ),
      isTrue,
    );
    expect(
      src.contains('readerSystemUiMode(android:android??Platform.isAndroid)'),
      isTrue,
      reason: 'the running platform must pick the mode on device',
    );
  });

  test(
    'late content-ready cannot hide home system bars during reader exit',
    () {
      final String navigation = File(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      ).readAsStringSync();
      final String body = methodBody(navigation, 'void _onRestoreComplete()');
      expect(
        body,
        matches(
          RegExp(
            r'if\s*\(\s*!_popInProgress\s*\)\s*\{\s*'
            r'unawaited\(setReaderSystemUiMode\(\)\);\s*\}',
          ),
        ),
        reason: 'mounted stays true during the reverse route animation',
      );
    },
  );
}
