import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_test_closure.dart';

/// `flutter test` 起步就要约 3.3 GB（flutter_tools + 平台 kernel，2026-11-05
/// 实测），`dart test` 跑同一个纯 Dart 测试约 0.8 GB。所以 import 闭包碰不到
/// `dart:ui` 的测试一律用 `package:test` 写：`tool/heavy.dart` 发现一批目标都是
/// 这种测试时，本机直接改用 `dart test` 跑（CI 仍用 flutter test 跑全部）。
///
/// 红了：这个测试只因为 `import 'package:flutter_test/flutter_test.dart'` 才
/// 需要 Flutter。改成 `import 'package:test/test.dart'`（`Fake` 在
/// `package:test/fake.dart`；`throwsAssertionError` 写成
/// `throwsA(isA<AssertionError>())`）。真要用组件测试 API 的（下面
/// [_flutterTestOnly] 认得出来）不在此列。
const String _flutterTestImport = 'package:flutter_test/flutter_test.dart';

/// flutter_test 独有、package:test 里没有的 API：用到它们的测试留在
/// flutter_test。
final RegExp _flutterTestOnly = RegExp(
  r'\btestWidgets\b|WidgetTester|TestWidgetsFlutterBinding|\bfinds[A-Z]\w*'
  r'|matchesGoldenFile|TestDefaultBinaryMessenger|\bfind\.'
  r'|throwsAssertionError|throwsFlutterError|isAssertionError',
);

void main() {
  test('闭包不碰 dart:ui 的测试用 package:test，不用 flutter_test', () {
    final TestClosureWalker walker = TestClosureWalker.open(
      Directory.current.path,
    )!;
    final List<File> tests =
        Directory('test')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('_test.dart'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    expect(tests.length, greaterThan(1000), reason: '扫描范围不对');
    final List<String> offenders = <String>[];
    for (final File f in tests) {
      final String src = f.readAsStringSync();
      if (!src.contains("import '$_flutterTestImport';")) continue;
      if (_flutterTestOnly.hasMatch(src)) continue;
      final TestClosure? closure = walker.closureOf(
        <String>[f.path],
        rootSkipUris: const <String>{_flutterTestImport},
        stopAtFlutter: true,
      );
      if (closure != null && !closure.needsFlutter) {
        offenders.add(f.path.replaceAll(r'\', '/'));
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '这些测试只因为 import flutter_test 才要 Flutter，改用 '
          "import 'package:test/test.dart'（见文件头）",
    );
  });
}
