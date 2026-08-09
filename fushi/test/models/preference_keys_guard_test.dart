import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';

import '../helpers/source_guard.dart';

/// 数据层重构 2026-08 P2 守卫：`preferences` 表的**新增键必须过注册表**。
///
/// 病灶：`(key, value)` 万能表的键以 ~140 个裸字符串字面量散落全代码库，无集中
/// 定义、无类型注解，拼错键名静默读到默认值。全量迁移到类型化门面 = 百文件级
/// churn 且不消灭任何 bug（存量键都活着），所以走「存量冻结、增量设门」：
/// [kKnownPreferenceKeys] 是唯一入口，本守卫扫 `getPref*/setPref*` 调用点的
/// 字面量键，不在注册表里的新键直接红。
///
/// 判据（窄而准）：
///  - 只扫**字面量**第一参（单/双引号）；含 `$`（插值动态键）跳过——动态键
///    形态登记在 [kKnownPreferenceKeyPrefixes]，不在本守卫扫描面内；
///  - 先 [maskComments] 再匹配：注释里的示例键不算调用（守卫可信度的底线，
///    否则「把键写进注释」既能骗红也能骗绿）；
///  - 经命名常量引用的键（`getPref(kSomeKey)`）不在扫描面内——那已经是比裸
///    字面量更好的形态，不设门。
void main() {
  final RegExp callPattern = RegExp(
    r'(?:getPref|setPref|getPreference|setPreference)\w*(?:<[^>()]*>)?\(\s*'
    r"""(?:'([^']*)'|"([^"]*)")""",
  );

  List<String> extractPrefKeyLiterals(String source) {
    final String masked = maskComments(source);
    return <String>[
      for (final RegExpMatch m in callPattern.allMatches(masked))
        (m.group(1) ?? m.group(2))!,
    ].where((String key) => !key.contains(r'$')).toList();
  }

  test('扫描器自检：注释掩码 + 动态键跳过 + 双引号形态', () {
    const String sample = '''
void f(Prefs p) {
  p.getPref('real_key_a');
  p.setPref("real_key_b", 1);
  p.getPref<int>('real_key_c');
  // p.getPref('commented_out_key');
  /* p.setPref('block_commented_key', 0); */
  p.getPref('dyn_\$suffix');
}
''';
    final List<String> keys = extractPrefKeyLiterals(sample);
    expect(
        keys, containsAll(<String>['real_key_a', 'real_key_b', 'real_key_c']));
    expect(keys, isNot(contains('commented_out_key')), reason: '行注释里的键不算调用');
    expect(keys, isNot(contains('block_commented_key')), reason: '块注释里的键不算调用');
    expect(keys.where((String k) => k.startsWith('dyn_')), isEmpty,
        reason: '插值动态键跳过');
  });

  test('lib 全树：getPref*/setPref* 的字面量键必须在注册表里', () {
    final List<Directory> roots = <Directory>[
      Directory('lib'),
      ...Directory('../packages').listSync().whereType<Directory>().map(
          (Directory d) => Directory('${d.path}${Platform.pathSeparator}lib')),
    ].where((Directory d) => d.existsSync()).toList();
    expect(roots, isNotEmpty);

    final Map<String, List<String>> violations = <String, List<String>>{};
    int scanned = 0;
    for (final Directory root in roots) {
      for (final FileSystemEntity e in root.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('.g.dart')) continue;
        if (e.path.endsWith('preference_keys.dart')) continue;
        scanned++;
        for (final String key in extractPrefKeyLiterals(e.readAsStringSync())) {
          if (!kKnownPreferenceKeys.contains(key)) {
            violations.putIfAbsent(key, () => <String>[]).add(e.path);
          }
        }
      }
    }
    expect(scanned, greaterThan(100), reason: '扫描面塌了守卫就是假绿');
    expect(
      violations,
      isEmpty,
      reason: '发现未登记的偏好键。新键必须先登记进 '
          'lib/src/models/preference_keys.dart 的 kKnownPreferenceKeys'
          '（按字母序），并在调用点旁注释类型与用途。违规：\n'
          '${violations.entries.map((e) => '  ${e.key} ← ${e.value.join(', ')}').join('\n')}',
    );
  });

  test('注册表纪律：键按字母序、无空键、前缀表无空前缀', () {
    final List<String> keys = kKnownPreferenceKeys.toList();
    final List<String> sorted = List<String>.of(keys)..sort();
    expect(keys, sorted, reason: '注册表按字母序维护，插错位置合并冲突翻倍');
    expect(keys.any((String k) => k.isEmpty), isFalse);
    expect(kKnownPreferenceKeyPrefixes.any((String p) => p.isEmpty), isFalse);
    expect(kCredentialPreferenceKeys.difference(kKnownPreferenceKeys), isEmpty,
        reason: '凭据键是注册表子集');
  });
}
