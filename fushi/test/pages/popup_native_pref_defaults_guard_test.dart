import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2397 根因③：Android 原生独立弹窗词典（`:popup` 进程的 `PopupDictActivity`，
/// 系统级选词/悬浮查词入口）自己起一个 WebView 加载同一份 `popup.js`，偏好由
/// `PopupDbReader.readPrefs` 直接读 SQLite `preferences` 表。
///
/// 坑在于：Dart 侧 `PreferencesRepository.getPref(key, defaultValue: ...)` 的默认值
/// **只活在 Dart 内存里，从不落库**——用户没主动点过某个开关时，`preferences` 表里
/// 根本没有那一行。Kotlin 侧原来写的是 `prefs[key] == "true"`，缺行判成 `false`，
/// 于是三个 Dart 默认为 `true` 的开关（音调去重 / 调和频率 / 折叠词典）在设置页上
/// 显示「开」，在系统级弹窗里却全是关的——用户报的「音调去重没用」正是这一档。
///
/// 这条链路跑在独立进程 + 真 Android WebView 上，widget 测试够不到，只能在源码层
/// 钉住不变式：**Kotlin 读到的每个布尔偏好，其缺行默认值必须等于 Dart 同名键的
/// `defaultValue`**，且不许退回裸 `== "true"` 的写法。
void main() {
  final File dartPrefs = File('lib/src/models/preferences_repository.dart');
  final File kotlinReader =
      File('android/app/src/main/java/app/fushi/reader/PopupDbReader.kt');

  // Kotlin data class 的构造默认值（DB 打不开 / readPrefs 抛异常时走它）也必须对齐，
  // 否则「读失败」这一档又会退回相反的行为。字段名 → 偏好键。
  const Map<String, String> fieldToKey = <String, String>{
    'deduplicatePitch': 'deduplicate_pitch_accents',
    'harmonicFrequency': 'harmonic_frequency',
    'collapseDictionaries': 'collapse_dictionaries',
    'showExpressionTags': 'show_expression_tags',
  };

  Map<String, bool> dartDefaults() {
    final String src = dartPrefs.readAsStringSync();
    final RegExp re = RegExp(
      r"getPref\(\s*'([a-z0-9_]+)'\s*,\s*defaultValue:\s*(true|false)\s*\)",
    );
    return <String, bool>{
      for (final RegExpMatch m in re.allMatches(src))
        m.group(1)!: m.group(2) == 'true',
    };
  }

  test('the native popup reader falls back to the SAME defaults as Dart', () {
    expect(dartPrefs.existsSync(), isTrue);
    expect(kotlinReader.existsSync(), isTrue);

    final String kt = kotlinReader.readAsStringSync();
    final Map<String, bool> dart = dartDefaults();
    expect(
      dart['deduplicate_pitch_accents'],
      isNotNull,
      reason: 'the regex must actually find Dart bool prefs; a silent zero '
          'match would make this whole guard vacuous',
    );

    final RegExp re = RegExp(
      r'boolPref\(prefs,\s*"([a-z0-9_]+)",\s*(true|false)\)',
    );
    final Iterable<RegExpMatch> reads = re.allMatches(kt);
    expect(
      reads.length,
      greaterThanOrEqualTo(fieldToKey.length),
      reason: 'every boolean preference the native popup reads must go through '
          'boolPref(prefs, key, default)',
    );

    for (final RegExpMatch m in reads) {
      final String key = m.group(1)!;
      final bool ktDefault = m.group(2) == 'true';
      expect(
        dart.containsKey(key),
        isTrue,
        reason: 'the native popup reads "$key" but Dart has no getPref for it; '
            'if Dart stopped owning this preference the native side must follow',
      );
      expect(
        ktDefault,
        dart[key],
        reason: 'BUG-2397: "$key" defaults to ${dart[key]} in Dart but '
            '$ktDefault in PopupDbReader. The Dart default never reaches the '
            'preferences table, so a mismatch means the system-level popup '
            'behaves the OPPOSITE of what the settings page shows.',
      );
    }
  });

  test('the native popup reader does not read bool prefs with a bare == "true"',
      () {
    final String kt = kotlinReader.readAsStringSync();
    // 裸 `prefs["x"] == "true"` 就是本 bug 的原状：把「这一行不存在」和「用户显式
    // 关掉了」混为一谈。所有布尔偏好必须走 boolPref 显式声明默认值。
    final RegExp bare = RegExp(r'prefs\["[a-z0-9_]+"\]\s*==\s*"true"');
    expect(
      bare.allMatches(kt).map((RegExpMatch m) => m.group(0)).toList(),
      isEmpty,
      reason: 'a bare == "true" read treats a missing row as false, which is '
          'wrong for every preference whose Dart default is true',
    );
  });

  test('PopupPrefs construction defaults match Dart too (DB-failure path)', () {
    final String kt = kotlinReader.readAsStringSync();
    final Map<String, bool> dart = dartDefaults();
    fieldToKey.forEach((String field, String key) {
      final RegExpMatch? m =
          RegExp('val $field: Boolean = (true|false)').firstMatch(kt);
      expect(
        m,
        isNotNull,
        reason: 'PopupPrefs must still declare $field with an explicit default',
      );
      expect(
        m!.group(1) == 'true',
        dart[key],
        reason: 'PopupPrefs.$field is the value used when the database cannot '
            'be opened at all; it must match the Dart default for "$key"',
      );
    });
  });
}
