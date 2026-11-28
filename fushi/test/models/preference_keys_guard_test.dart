import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/prefs/fushi_pref_registry.dart';

import '../helpers/source_guard.dart';

/// `preferences` 表的**新增键必须有登记**（数据层重构 2026-08 P2 → 架构重构 F1）。
///
/// 登记有两处，按「只减不增」收敛到一处：
///  - 偏好键登记表 [kFushiPrefRegistry]（`lib/src/prefs/`）：键名 + 值类型 + 默认值 + 各通道
///    策略。凡是不按默认（随 Profile、可同步、进备份设置类）处理的键、全部动态键族都在这里，
///    新键一律加在这里；
///  - [kKnownPreferenceKeys]：只登记了名字、还没迁进登记表的存量键（默认策略）。它只许变少：
///    迁一个删一个，与登记表不相交，条数有上限（下面的棘轮）。
///
/// 字面量扫描（窄而准）：只扫 `getPref*/setPref*` 的**字面量**第一参；含 `$`（插值动态键）
/// 跳过——动态键族在登记表里声明；先 [maskComments] 再匹配，注释里的示例键不算调用；经命名
/// 常量引用的键不在扫描面内。
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
      keys,
      containsAll(<String>['real_key_a', 'real_key_b', 'real_key_c']),
    );
    expect(keys, isNot(contains('commented_out_key')), reason: '行注释里的键不算调用');
    expect(keys, isNot(contains('block_commented_key')), reason: '块注释里的键不算调用');
    expect(
      keys.where((String k) => k.startsWith('dyn_')),
      isEmpty,
      reason: '插值动态键跳过',
    );
  });

  test('lib 全树：getPref*/setPref* 的字面量键必须在注册表里', () {
    final List<Directory> roots = <Directory>[
      Directory('lib'),
      ...Directory('../packages').listSync().whereType<Directory>().map(
        (Directory d) => Directory('${d.path}${Platform.pathSeparator}lib'),
      ),
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
          if (!isKnownPreferenceKey(key)) {
            violations.putIfAbsent(key, () => <String>[]).add(e.path);
          }
        }
      }
    }
    expect(scanned, greaterThan(100), reason: '扫描面塌了守卫就是假绿');
    expect(
      violations,
      isEmpty,
      reason:
          '发现未登记的偏好键。新键必须登记进偏好键登记表（lib/src/prefs/ 或所属域的 '
          'PrefKeyDef 清单，声明类型、默认值与各通道策略）。违规：\n'
          '${violations.entries.map((e) => '  ${e.key} ← ${e.value.join(', ')}').join('\n')}',
    );
  });

  test('名字登记表纪律：按字母序、无空键、与偏好键登记表不相交', () {
    final List<String> keys = kKnownPreferenceKeys.toList();
    final List<String> sorted = List<String>.of(keys)..sort();
    expect(keys, sorted, reason: '注册表按字母序维护，插错位置合并冲突翻倍');
    expect(keys.any((String k) => k.isEmpty), isFalse);
    expect(
      keys.where((String k) => kFushiPrefRegistry.keyNamed(k) != null),
      isEmpty,
      reason: '迁进偏好键登记表的键必须从 kKnownPreferenceKeys 删掉，同一个键不登记两处',
    );
  });

  test('棘轮：只登记名字的存量键与未声明类型的登记只减不增', () {
    expect(
      kKnownPreferenceKeys.length,
      lessThanOrEqualTo(_kKnownPreferenceKeysCeiling),
      reason:
          'kKnownPreferenceKeys 只减不增：新键登记进偏好键登记表（PrefKey，带类型与策略）。'
          '迁走存量键后把上限同步调低到 ${kKnownPreferenceKeys.length}',
    );
    final int untyped = <PrefKeyDef>[
      ...kFushiPrefRegistry.keys,
      ...kFushiPrefRegistry.families,
    ].where((PrefKeyDef d) => d.isUntyped).length;
    expect(
      untyped,
      lessThanOrEqualTo(_kUntypedPrefKeyDefsCeiling),
      reason:
          '未声明类型的登记（PrefKey.untyped / PrefKeyFamily.untyped）只减不增：新登记写成 '
          'PrefKey<T>(..., defaultValue: ...)。类型化后把上限同步调低到 $untyped',
    );
  });
}

/// [kKnownPreferenceKeys] 的条数上限（2026-11-28 迁出有特殊策略的键后的现值）。
const int _kKnownPreferenceKeysCeiling = 453;

/// 未声明类型的登记条数上限（2026-11-28 现值）。
const int _kUntypedPrefKeyDefsCeiling = 246;
