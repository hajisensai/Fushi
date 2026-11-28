import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 无头服务端的编译门在 pubspec 层的镜像：`packages/fushi_engine` 与
/// `packages/fushi_server` 会被 `dart build cli` 打成不含 Flutter 的 CLI bundle，
/// `fushi_core` / `fushi_audio` 整包零 Flutter（2026-09-30）。
///
/// 源码层的 import 纯度（禁 `package:flutter/…`、`dart:ui`、插件、反向
/// `package:fushi/…`、全 barrel，以及沿传递闭包走到 Flutter）已改由 analyzer
/// 插件规则 `fushi_pure_dart_package_imports`
/// （`packages/fushi_lints/lib/src/rules/pure_dart_package_imports.dart`）随
/// `dart analyze` 判定。这里只剩插件管不到的 YAML：pubspec 不得声明 Flutter。
///
/// 设计：docs/specs/2026-09-08-fushi-server-headless-design.md §3.1。
void main() {
  test('fushi_engine / fushi_server 的 pubspec 不声明 flutter sdk', () {
    for (final String path in <String>[
      '../packages/fushi_engine/pubspec.yaml',
      '../packages/fushi_server/pubspec.yaml',
      '../packages/fushi_core/pubspec.yaml',
      '../packages/fushi_audio/pubspec.yaml',
    ]) {
      final String text = File(path).readAsStringSync();
      expect(
        RegExp(
          r'^\s+flutter:\s*\n\s+sdk:\s*flutter',
          multiLine: true,
        ).hasMatch(text),
        isFalse,
        reason: '$path 声明了 flutter sdk 依赖',
      );
    }
  });

  test(
    'fushi_core / fushi_audio 的 pubspec 连 dev 依赖与 environment 都不带 Flutter',
    () {
      // dev_dependencies 里的 flutter_test 同样让解析依赖需要 Flutter SDK；包测试改用
      // package:test（CI 的 flutter_test_failures.dart runner 对纯 Dart 包照样能跑）。
      for (final String path in <String>[
        '../packages/fushi_core/pubspec.yaml',
        '../packages/fushi_audio/pubspec.yaml',
      ]) {
        final String text = File(path).readAsStringSync();
        expect(
          RegExp(r'^\s*sdk:\s*flutter\s*$', multiLine: true).hasMatch(text),
          isFalse,
          reason: '$path 仍有 `sdk: flutter` 依赖（含 dev_dependencies）',
        );
        expect(
          RegExp(r'^\s+flutter:\s*"', multiLine: true).hasMatch(text),
          isFalse,
          reason: '$path 的 environment 仍约束 flutter 版本',
        );
        for (final String plugin in <String>[
          'just_audio',
          'audio_session',
          'path_provider',
          'flutter_charset_detector',
          'sqlite3_flutter_libs',
        ]) {
          expect(
            RegExp('^\\s+$plugin:', multiLine: true).hasMatch(text),
            isFalse,
            reason: '$path 仍依赖 method-channel 插件 $plugin',
          );
        }
      }
    },
  );
}
