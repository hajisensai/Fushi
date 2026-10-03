import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：本地钉的 Flutter（`fushi/.fvmrc`）与 CI 各 workflow 的 `flutter-version`
/// 必须是**同一个版本**。
///
/// 起因（2026-09-30）：CLAUDE.md 长期写着「本地 `.fvmrc` 3.41.6，CI 3.44.0」。
/// 两个版本的 analyzer / lint 结论不同，于是「本地 analyze 过了、CI 还红」
/// 成了照章办事就会发生的事；3.41.6 跑 `pub get` 还会把 lockfile 切走（本机实测）。
/// `tool/pre_push_check.dart` 第 0 步拿本地 SDK 比 CI 的钉版，这条守卫保证钉版
/// 本身只有一个：只改一边，本地与 CI 同时红。
void main() {
  test('fushi/.fvmrc 与全部 workflow 的 flutter-version 一致', () {
    final Object? fvmrc = jsonDecode(File('.fvmrc').readAsStringSync());
    expect(fvmrc, isA<Map<String, Object?>>());
    final String pinned =
        (fvmrc! as Map<String, Object?>)['flutter']! as String;

    final RegExp versionLine = RegExp(
      r'''flutter-version:\s*['"]?([0-9][0-9A-Za-z.+-]*)['"]?''',
    );
    final Map<String, Set<String>> byWorkflow = <String, Set<String>>{};
    for (final File f in Directory(
      '../.github/workflows',
    ).listSync().whereType<File>()) {
      if (!f.path.endsWith('.yml') && !f.path.endsWith('.yaml')) continue;
      for (final RegExpMatch m in versionLine.allMatches(
        f.readAsStringSync(),
      )) {
        byWorkflow
            .putIfAbsent(f.uri.pathSegments.last, () => <String>{})
            .add(m.group(1)!);
      }
    }
    // 规模哨兵：正则或目录塌了时「零处引用」与「全部一致」退出码一样。
    expect(byWorkflow.length, greaterThanOrEqualTo(3));

    final List<String> drift = <String>[
      for (final MapEntry<String, Set<String>> e in byWorkflow.entries)
        for (final String v in e.value)
          if (v != pinned) '${e.key}: $v',
    ];
    expect(
      drift,
      isEmpty,
      reason:
          'fushi/.fvmrc 钉 $pinned，这些 workflow 用的不是它（本地与 CI 必须同版本，'
          '升级时两边一起改）：\n${drift.join('\n')}',
    );
  });
}
