// BUG-5576：flutter_logs（底层 RxLogs）在 Android 上没给 logsExportDirectoryName 时，
// 把「导出目录」解析成 getExternalFilesDir(null) 根本身，zipsRetentionPeriodInDays
// （默认 3）到期后冷启动对它 deleteRecursively——Android/data/<包名>/files 整树删光，
// 外部书库 files/data、词典、有声书一起没了，数据库行还在（BUG-5492 / #4521）。
// 该插件已整个移除。本守卫防止它（或同源的 RxLogs）被重新引入。
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('flutter_logs 不再是依赖（它会定时整树删 Android 外部 files 根）', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^\s*flutter_logs\s*:', multiLine: true).hasMatch(pubspec),
      isFalse,
      reason:
          'flutter_logs 会把导出目录解析成 getExternalFilesDir 根并定时 '
          'deleteRecursively，见 BUG-5576。日志走 ErrorLogService。',
    );
    final File lock = File('../pubspec.lock');
    if (lock.existsSync()) {
      expect(
        lock.readAsStringSync(),
        isNot(contains('  flutter_logs:')),
        reason: 'flutter_logs 经传递依赖回来了，见 BUG-5576。',
      );
    }
  });

  test('lib 里不再引用 flutter_logs / FlutterLogs', () {
    final List<String> hits = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String src = e.readAsStringSync();
      if (src.contains('package:flutter_logs/') ||
          src.contains('FlutterLogs.')) {
        hits.add(e.path);
      }
    }
    expect(hits, isEmpty, reason: '见 BUG-5576');
  });
}
