import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/prefs/fushi_pref_registry.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi_engine/sync/interconnect_service_config.dart';

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
/// 扫描面（窄而准）：`getPref*/setPref*` 的第一参——
///  - **字面量**：直接取键名；含 `$`（插值动态键）跳过，动态键族在登记表里声明；
///  - **命名常量**：解析回它的字符串值再查登记（同文件的 `const`，或全仓唯一取值的
///    `kXxx` 常量 / `Type.member` 静态常量）。只扫字面量时，`getPref(_keyFoo)` 这种写法
///    的新键完全不受管——存量里就这样漏了 60 个键和 1 个键族。
/// 先 [maskComments] 再匹配，注释里的示例键不算调用。解析不到常量的第一参（局部变量、
/// 参数、函数调用）是动态键，不在扫描面内；它们要等读写改成 `prefs.get(PrefKey)`（F2）
/// 才能从类型上管住。
void main() {
  final RegExp literalCallPattern = RegExp(
    r'(?:getPref|setPref|getPreference|setPreference)\w*(?:<[^>()]*>)?\(\s*'
    r"""(?:'([^']*)'|"([^"]*)")""",
  );
  final RegExp namedCallPattern = RegExp(
    r'(?:getPref|setPref|getPreference|setPreference)\w*(?:<[^>()]*>)?\(\s*'
    r'([A-Za-z_][\w.]*)\s*[,)]',
  );
  final RegExp constPattern = RegExp(
    r'const\s+(?:String\s+)?(\w+)\s*=\s*'
    r"""(?:'([^'$\\]*)'|"([^"$\\]*)")\s*;""",
  );
  final RegExp constantLikeName = RegExp(r'^_?k[A-Z]\w*$');
  final RegExp staticMemberExpr = RegExp(r'^_?[A-Z]\w*\.\w+$');

  List<String> extractPrefKeyLiterals(String source) {
    final String masked = maskComments(source);
    return <String>[
      for (final RegExpMatch m in literalCallPattern.allMatches(masked))
        (m.group(1) ?? m.group(2))!,
    ].where((String key) => !key.contains(r'$')).toList();
  }

  /// `const` 字符串声明：名字 → 取值集合。
  Map<String, Set<String>> extractStringConsts(String maskedSource) {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    for (final RegExpMatch m in constPattern.allMatches(maskedSource)) {
      out
          .putIfAbsent(m.group(1)!, () => <String>{})
          .add((m.group(2) ?? m.group(3))!);
    }
    return out;
  }

  /// 调用点里以命名常量作第一参的键：解析成字符串值。同文件声明优先；跨文件只认
  /// 「看起来就是常量」的写法（`kXxx` / `Type.member`）且全仓取值唯一，避免把同名的局部
  /// 变量 / 参数（`key`、`prefix`）误认成某个不相干的常量。
  List<String> resolveNamedPrefKeys(
    String maskedSource, {
    required Map<String, Set<String>> fileConsts,
    required Map<String, Set<String>> globalConsts,
  }) {
    final List<String> out = <String>[];
    for (final RegExpMatch m in namedCallPattern.allMatches(maskedSource)) {
      final String expr = m.group(1)!;
      final String name = expr.split('.').last;
      final Set<String>? local = expr.contains('.') ? null : fileConsts[name];
      if (local != null) {
        out.addAll(local);
        continue;
      }
      final bool constantLike =
          constantLikeName.hasMatch(expr) || staticMemberExpr.hasMatch(expr);
      final Set<String>? global = globalConsts[name];
      if (constantLike && global != null && global.length == 1) {
        out.add(global.single);
      }
    }
    return out;
  }

  List<File> libDartFiles() {
    final List<Directory> roots = <Directory>[
      Directory('lib'),
      ...Directory('../packages').listSync().whereType<Directory>().map(
        (Directory d) => Directory('${d.path}${Platform.pathSeparator}lib'),
      ),
    ].where((Directory d) => d.existsSync()).toList();
    expect(roots, isNotEmpty);
    return <File>[
      for (final Directory root in roots)
        for (final FileSystemEntity e in root.listSync(recursive: true))
          if (e is File &&
              e.path.endsWith('.dart') &&
              !e.path.endsWith('.g.dart') &&
              !e.path.endsWith('preference_keys.dart'))
            e,
    ];
  }

  String describe(Map<String, List<String>> violations) => violations.entries
      .map(
        (MapEntry<String, List<String>> e) =>
            '  ${e.key} ← ${e.value.toSet().join(', ')}',
      )
      .join('\n');

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

  test('扫描器自检：命名常量解析（同文件、全仓唯一的 k 常量、静态成员；局部同名不误认）', () {
    const String sample = '''
const String _keyLocal = 'local_const_key';
class Repo {
  static const String memberKey = 'member_const_key';
  static const _untyped = 'untyped_const_key';
  void f(Prefs p, String key, String prefix) {
    p.getPref(_keyLocal);
    p.setPref(_untyped, 1);
    p.getPref<bool>(kElsewhereKey, defaultValue: false);
    p.setPref(Other.sharedKey, 2);
    p.getPref(key);
    p.getPref(prefix);
    p.getPref(kAmbiguous);
    // p.getPref(_keyCommented);
  }
}
''';
    final String masked = maskComments(sample);
    final List<String> keys = resolveNamedPrefKeys(
      masked,
      fileConsts: extractStringConsts(masked),
      globalConsts: <String, Set<String>>{
        'kElsewhereKey': <String>{'elsewhere_key'},
        'sharedKey': <String>{'shared_member_key'},
        // 别的文件里恰好有叫 key / prefix 的常量：调用点的是参数，不能认成它们。
        'key': <String>{'unrelated_const'},
        'prefix': <String>{'unrelated_prefix'},
        'kAmbiguous': <String>{'one', 'two'},
        '_keyCommented': <String>{'commented_key'},
      },
    );
    expect(keys, <String>[
      'local_const_key',
      'untyped_const_key',
      'elsewhere_key',
      'shared_member_key',
    ]);
  });

  test('lib 全树：getPref*/setPref* 的字面量键与命名常量键必须有登记', () {
    final List<File> files = libDartFiles();
    final Map<String, String> masked = <String, String>{
      for (final File f in files) f.path: maskComments(f.readAsStringSync()),
    };
    final Map<String, Map<String, Set<String>>> constsByFile =
        <String, Map<String, Set<String>>>{
          for (final MapEntry<String, String> e in masked.entries)
            e.key: extractStringConsts(e.value),
        };
    final Map<String, Set<String>> globalConsts = <String, Set<String>>{};
    for (final Map<String, Set<String>> consts in constsByFile.values) {
      consts.forEach((String name, Set<String> values) {
        globalConsts.putIfAbsent(name, () => <String>{}).addAll(values);
      });
    }

    final Map<String, List<String>> literalViolations =
        <String, List<String>>{};
    final Map<String, List<String>> namedViolations = <String, List<String>>{};
    int namedResolved = 0;
    for (final File f in files) {
      for (final String key in extractPrefKeyLiterals(f.readAsStringSync())) {
        if (!isKnownPreferenceKey(key)) {
          literalViolations.putIfAbsent(key, () => <String>[]).add(f.path);
        }
      }
      for (final String key in resolveNamedPrefKeys(
        masked[f.path]!,
        fileConsts: constsByFile[f.path]!,
        globalConsts: globalConsts,
      )) {
        namedResolved++;
        // 常量也可能是一个键族的前缀（`getPrefsWithPrefix(kFooPrefix)`）：族登记算数。
        if (!isKnownPreferenceKey(key) &&
            !kFushiPrefRegistry.families.any(
              (PrefKeyFamily<Object?> family) =>
                  family.prefix == key && family.suffix.isEmpty,
            )) {
          namedViolations.putIfAbsent(key, () => <String>[]).add(f.path);
        }
      }
    }
    expect(files.length, greaterThan(100), reason: '扫描面塌了守卫就是假绿');
    expect(namedResolved, greaterThan(300), reason: '命名常量解析塌了守卫就是假绿');
    expect(
      literalViolations,
      isEmpty,
      reason:
          '发现未登记的偏好键。新键必须登记进偏好键登记表（lib/src/prefs/ 或所属域的 '
          'PrefKeyDef 清单，声明类型、默认值与各通道策略）。违规：\n'
          '${describe(literalViolations)}',
    );
    expect(
      namedViolations,
      isEmpty,
      reason:
          '发现经命名常量读写、却没有登记的偏好键。新键必须登记进偏好键登记表'
          '（lib/src/prefs/ 或所属域的 PrefKeyDef 清单）。违规：\n'
          '${describe(namedViolations)}',
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

  // 下面三组是还没迁进登记表的手写键名单。迁之前它们只减不增，而且名单里的每个固定键都
  // 必须有登记——名单里的键名和登记表对不上（改名、删键只改了一处）会在这里红。
  test('棘轮：作品级名单（WorkProfileScope / 主题键）只减不增，键都有登记', () {
    const String hint =
        '作品级归属还没迁进偏好键登记表（要先给 PrefPolicy 加作品级字段）。这份手写名单'
        '只减不增：新的作品级键等迁移时在登记表里声明，不往这里加；删了键就把上限调低。';
    final Map<String, (Set<String>, int)> lists = <String, (Set<String>, int)>{
      'WorkProfileScope.appLevelReaderPrefKeys': (
        WorkProfileScope.appLevelReaderPrefKeys,
        _kAppLevelReaderPrefKeysCeiling,
      ),
      'WorkProfileScope.videoSubtitleStylePrefKeys': (
        WorkProfileScope.videoSubtitleStylePrefKeys,
        _kVideoSubtitleStylePrefKeysCeiling,
      ),
      'WorkProfileScope.srsMiningPrefKeys': (
        WorkProfileScope.srsMiningPrefKeys,
        _kSrsMiningPrefKeysCeiling,
      ),
      'ThemeNotifier.profileThemePrefKeys': (
        ThemeNotifier.profileThemePrefKeys,
        _kProfileThemePrefKeysCeiling,
      ),
    };
    lists.forEach((String name, (Set<String>, int) entry) {
      final (Set<String> keys, int ceiling) = entry;
      expect(keys.length, lessThanOrEqualTo(ceiling), reason: '$name：$hint');
      for (final String key in keys) {
        expect(
          kFushiPrefRegistry.lookup(key) != null ||
              kKnownPreferenceKeys.contains(key),
          isTrue,
          reason: '$name 里的 $key 没有登记',
        );
        // 作品级键随配置走：登记成不随 Profile 的键放在这里是自相矛盾。
        expect(
          kFushiPrefRegistry.has(key, PrefTrait.outsideProfile),
          isFalse,
          reason: '$name 里的 $key 在登记表里不随 Profile，不可能是作品级键',
        );
      }
    });
  });

  test('棘轮：互联下发的外部服务身份键（engine）只减不增，键都有登记', () {
    const Set<String> shared =
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys;
    expect(
      shared.length,
      lessThanOrEqualTo(_kInterconnectSharedPrefKeysCeiling),
      reason:
          'InterconnectServiceConfigSnapshot.sharedPreferenceKeys 是 engine 里手写的键名单'
          '（键声明还在 app，engine 看不到登记表）。声明下沉到 core / engine 之前只减不增。',
    );
    expect(
      shared.where((String key) => !isKnownPreferenceKey(key)),
      isEmpty,
      reason: 'engine 名单里的键名必须与 app 的登记一致',
    );
  });

  test('棘轮：服务端字幕来源的同名键常量（fushi_server）只减不增，键都有登记', () {
    final File file = File(
      '../packages/fushi_server/lib/src/server_subtitle_providers.dart',
    );
    final Map<String, Set<String>> consts = extractStringConsts(
      maskComments(file.readAsStringSync()),
    );
    final List<String> prefKeys = <String>[
      for (final MapEntry<String, Set<String>> e in consts.entries)
        if (e.key.endsWith('Pref')) ...e.value,
    ];
    expect(prefKeys, isNotEmpty, reason: '解析塌了守卫就是假绿');
    expect(
      prefKeys.length,
      lessThanOrEqualTo(_kServerSubtitlePrefConstsCeiling),
      reason:
          'server_subtitle_providers.dart 的 k*Pref 是照抄 app 键名的常量（服务端看不到 app '
          '的登记表）。声明下沉到 core / engine 之前只减不增。',
    );
    expect(
      prefKeys.where((String key) => !isKnownPreferenceKey(key)),
      isEmpty,
      reason: '服务端照抄的键名必须与 app 的登记一致',
    );
  });
}

/// [kKnownPreferenceKeys] 的条数上限。2026-11-28 迁出有特殊策略的键后是 453；同日守卫
/// 补上命名常量扫描与手写名单对账，查出 76 个一直在用、从没登记过的存量键（60 个经命名
/// 常量读写，16 个主题键经 ThemeNotifier 自己的读写入口），按现状（默认策略）补登名字后
/// 是 529。此后只减不增。
const int _kKnownPreferenceKeysCeiling = 529;

/// 未声明类型的登记条数上限（2026-11-28 现值）。
const int _kUntypedPrefKeyDefsCeiling = 246;

/// 作品级手写名单的条数上限（2026-11-28 现值）。
const int _kAppLevelReaderPrefKeysCeiling = 3;
const int _kVideoSubtitleStylePrefKeysCeiling = 2;
const int _kSrsMiningPrefKeysCeiling = 4;
const int _kProfileThemePrefKeysCeiling = 26;

/// engine 互联下发名单的条数上限（2026-11-28 现值）。
const int _kInterconnectSharedPrefKeysCeiling = 15;

/// 服务端字幕来源照抄的键常量条数上限（2026-11-28 现值）。
const int _kServerSubtitlePrefConstsCeiling = 8;
