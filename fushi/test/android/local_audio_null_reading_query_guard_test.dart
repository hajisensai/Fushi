import 'dart:io';

import 'package:test/test.dart';

/// 应用内反馈 Dd9HikrfRx source-scan guard：本地音频库的「读音精确优先」查询在
/// Dart（[LocalAudioDb]，桌面端）与 Android 原生（`TtsChannelHandler`）各有一份。
/// Yomitan 本地音频库里 forvo 行的 reading 全是 NULL；旧写法 `reading = ?` 在别的
/// 子来源有一行读音精确命中时把 forvo 整体排除，日语词永远出不了 Forvo。两端必须
/// 用同一条把 NULL 读音算作命中的 SQL —— Android 原生 SQLiteDatabase 在这里跑不了，
/// 故逐字比对 Java 源码里的 SQL 与 Dart 侧那条。
void main() {
  final File dartDb = File('lib/src/utils/misc/local_audio_db.dart');
  final File ttsHandler = File(
    'android/app/src/main/java/app/fushi/reader/TtsChannelHandler.java',
  );

  /// 把源码里相邻字符串字面量拼接（Dart 的 `'a' 'b'` / Java 的 `"a" + "b"`）后
  /// 压成单行，便于逐字比对 SQL。
  String joinedLiterals(File f, String quote) {
    final String src = f.readAsStringSync();
    final RegExp lit = RegExp('$quote([^$quote\\n]*)$quote');
    return lit.allMatches(src).map((Match m) => m.group(1)!).join('\u0000');
  }

  const String exactSql =
      'SELECT file, source FROM entries '
      'WHERE expression = ? AND (reading = ? OR reading IS NULL) '
      'ORDER BY reading IS NULL, rowid';

  test('Dart query treats a NULL reading as a match', () {
    final String dart = joinedLiterals(dartDb, "'").replaceAll('\u0000', '');
    expect(dart, contains(exactSql));
    expect(dart, isNot(contains('AND reading = ?')));
  });

  test('Android native query uses the very same SQL', () {
    final String java = joinedLiterals(
      ttsHandler,
      '"',
    ).replaceAll('\u0000', '');
    expect(java, contains(exactSql));
    expect(java, isNot(contains('AND reading = ?')));
    expect(
      RegExp(
        r'rawQuery\(\s*LOCAL_AUDIO_READING_MATCH_SQL\b',
      ).allMatches(ttsHandler.readAsStringSync()).length,
      2,
      reason: '单条查询与「选择音频源」全量查询两处都必须用这条带 NULL 读音行的 SQL',
    );
  });
}
