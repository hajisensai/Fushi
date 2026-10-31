import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 首次启动向导（onboarding）的本地化守卫（issue #2716：非中文系统的用户反馈
/// 「onboarding 有些地方没翻译」）。
///
/// 实测根因有两类，各钉一条：
///  1. **译文缺失**：向导里 39 个 key 在 15 种非中英语言里存的是英文原文（i18n_sync
///     `--add` 只写 en/zh，其余语言先填英文，之后没人补），i18n 完整性测试只查 key 齐不齐，
///     查不出「值就是英文」。这里对**向导实际用到的每个 key**（源码里 `t.<key>` 现场枚举
///     + 全部 `onboarding_*` key）断言：非英语语言的值不得与英文逐字相同，除非在
///     [_kIdenticalAllowed] 里写明这个词在该语言里本来就这么写（品牌名 / 外来词）。
///  2. **写死在代码里的界面文字**：向导源码里不得有直接塞进 `Text(...)` / `title:` 等
///     可见位置的字面量，也不得有任何 CJK 字面量（原先 `AnkiConnect（host:port）` 的全角
///     括号对所有语言都生效）。
void main() {
  final String i18nDir = p.join('lib', 'i18n');

  Map<String, dynamic> readLocale(String fileName) =>
      jsonDecode(File(p.join(i18nDir, fileName)).readAsStringSync())
          as Map<String, dynamic>;

  List<File> onboardingSources() {
    final List<File> files =
        Directory(p.join('lib', 'src', 'onboarding'))
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'))
            .toList()
          ..add(
            File(
              p.join(
                'lib',
                'src',
                'pages',
                'implementations',
                'onboarding_wizard_page.dart',
              ),
            ),
          );
    files.sort((File a, File b) => a.path.compareTo(b.path));
    return files;
  }

  test('onboarding keys are actually translated in every locale', () {
    final Map<String, dynamic> en = readLocale('strings.i18n.json');
    final Set<String> keys = <String>{
      for (final String key in en.keys)
        if (key.startsWith('onboarding_')) key,
    };
    final RegExp keyUse = RegExp(r'\bt\.([a-z][a-z0-9_]*)');
    for (final File file in onboardingSources()) {
      final String code = maskComments(file.readAsStringSync());
      for (final RegExpMatch m in keyUse.allMatches(code)) {
        if (en.containsKey(m.group(1))) keys.add(m.group(1)!);
      }
    }
    expectScanScale(
      keys.length,
      what: 'onboarding i18n keys',
      atLeast: 200,
      measured: 270,
    );

    final List<File> locales =
        Directory(i18nDir)
            .listSync()
            .whereType<File>()
            .where(
              (File f) =>
                  p.basename(f.path).startsWith('strings_') &&
                  f.path.endsWith('.i18n.json'),
            )
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    expectScanScale(
      locales.length,
      what: 'translation files',
      atLeast: 14,
      measured: 16,
    );

    final List<String> untranslated = <String>[];
    for (final File file in locales) {
      final String lang = p
          .basename(file.path)
          .replaceFirst('strings_', '')
          .replaceFirst('.i18n.json', '');
      final Map<String, dynamic> values = readLocale(p.basename(file.path));
      for (final String key in keys.toList()..sort()) {
        final Object? english = en[key];
        if (english is! String || !_hasWords(english)) continue;
        if (values[key] != english) continue;
        if (_kIdenticalAllowed[key]?.contains(lang) ?? false) continue;
        if (_kIdenticalAllowed[key]?.contains('*') ?? false) continue;
        untranslated.add('$lang: $key = "$english"');
      }
    }
    expect(
      untranslated,
      isEmpty,
      reason:
          'onboarding strings still carry the English text in a non-English '
          'locale. Translate them in strings_<lang>.i18n.json (keep key '
          'order); only list a key in _kIdenticalAllowed when the word is '
          'genuinely spelled the same in that language.\n'
          '${untranslated.join('\n')}',
    );
  });

  test('allowlist entries are still needed (no stale exemptions)', () {
    final Map<String, dynamic> en = readLocale('strings.i18n.json');
    final List<String> stale = <String>[];
    _kIdenticalAllowed.forEach((String key, Set<String> langs) {
      for (final String lang in langs) {
        if (lang == '*') continue;
        final Map<String, dynamic> values = readLocale(
          'strings_$lang.i18n.json',
        );
        if (values[key] != en[key]) stale.add('$lang: $key');
      }
    });
    expect(
      stale,
      isEmpty,
      reason: 'drop allowlist entries that are translated now: $stale',
    );
  });

  test('no hard-coded user-visible text in onboarding sources', () {
    final List<File> files = onboardingSources();
    expectScanScale(
      files.length,
      what: 'onboarding source files',
      atLeast: 10,
      measured: 13,
    );
    final List<String> hits = <String>[];
    for (final File file in files) {
      final String name = p.basename(file.path);
      final String source = file.readAsStringSync();
      for (final String hit in findVisibleLiterals(source)) {
        if (_kBrandLiterals.contains(hit)) continue;
        hits.add('$name: visible literal "$hit"');
      }
      if (!_kCjkLiteralFiles.contains(name)) {
        for (final String hit in findCjkLiterals(source)) {
          hits.add('$name: CJK literal "$hit"');
        }
      }
    }
    expect(
      hits,
      isEmpty,
      reason:
          'user-visible onboarding text must come from i18n (t.<key>); '
          'add keys with `dart run tool/i18n_sync.dart --add`.\n'
          '${hits.join('\n')}',
    );
  });

  group('literal detectors catch synthetic violations', () {
    test('visible-position literals', () {
      expect(findVisibleLiterals("Text('Next step')"), <String>['Next step']);
      expect(findVisibleLiterals('Text(\n  "Skip",\n)'), <String>['Skip']);
      expect(findVisibleLiterals("title: 'Learn a language',"), <String>[
        'Learn a language',
      ]);
      expect(findVisibleLiterals("tooltip: 'Close'"), <String>['Close']);
      // 纯插值 / 数字 / 符号不是界面文字。
      expect(findVisibleLiterals(r"label: '${current + 1} / $total'"), isEmpty);
      expect(findVisibleLiterals('Text(t.onboarding_skip)'), isEmpty);
      // 注释里的不算。
      expect(findVisibleLiterals("// Text('Next step')"), isEmpty);
    });

    test('CJK literals', () {
      expect(findCjkLiterals("return 'AnkiConnect（\$host）';"), <String>[
        'AnkiConnect（\$host）',
      ]);
      expect(findCjkLiterals("final String s = '下一步';"), <String>['下一步']);
      // #2716 修复前的原文：相邻字面量拼接 + 插值里的全角括号。
      expect(
        findCjkLiterals(
          "return 'AnkiConnect'\n"
          "    '（\${settings.ankiConnectHost}:\${settings.ankiConnectPort}）';",
        ),
        isNotEmpty,
      );
      // 注释里的中文不算字面量。
      expect(findCjkLiterals('// 下一步\nfinal int x = 1;'), isEmpty);
      expect(findCjkLiterals("final String s = 'plain';"), isEmpty);
    });
  });
}

/// 值与英文逐字相同、但在该语言里本来就这么写的条目。`*` = 所有语言（纯品牌名）。
const Map<String, Set<String>> _kIdenticalAllowed = <String, Set<String>>{
  // 产品名。
  'onboarding_review_anki_title': <String>{'*'},
  // 拉丁字母语言里 Manga / Video / Galgames 就是本地写法（外来词）。
  'onboarding_feature_manga': <String>{
    'de',
    'es',
    'fr',
    'id',
    'it',
    'nl',
    'tr',
  },
  'onboarding_feature_video': <String>{'de', 'id', 'it', 'nl', 'tr', 'vi'},
  'onboarding_feature_games': <String>{'de', 'es', 'fr', 'nl', 'pt-BR'},
  'onboarding_action_badge_optional': <String>{'de'},
  'onboarding_permission_notifications_label': <String>{'fr'},
  'onboarding_step_backup_title': <String>{'it', 'pt-BR'},
  'nav_web': <String>{'de', 'it', 'nl'},
  // 外部服务名 + 括号插值，没有可译的词；括号写法由各语言自己的值决定。
  'onboarding_anki_backend_ankiconnect': <String>{'*'},
};

/// 在线服务列表里的服务名（品牌，不翻译）。
const Set<String> _kBrandLiterals = <String>{
  'AniDB',
  'MAL / Jikan · AniList',
  'TMDB',
  'Jimaku',
  'OpenSubtitles',
  'SubDL',
  'DanDanPlay',
  'Torznab · Jellyfin / Emby · OPDS',
};

/// 允许出现 CJK 字面量的文件：示例句按**学习语言**给出（日 / 中 / 韩原文本身就是内容，
/// 不是界面文字）。
const Set<String> _kCjkLiteralFiles = <String>{'onboarding_sample_text.dart'};

bool _hasWords(String value) => RegExp(
  r'[A-Za-z]{3,}',
).hasMatch(value.replaceAll(RegExp(r'\$\{[^}]*\}|\$\w+'), ''));

/// 落在可见位置（`Text(` 首参、`title:` / `label:` 等命名参数）的字面量，
/// 内容至少含一个由字母组成的词（插值与符号剔除后）。
List<String> findVisibleLiterals(String source) {
  final String code = maskComments(source);
  final RegExp visible = RegExp(
    r'''(?:\b(?:Text|SelectableText|Tooltip)\(\s*|\b(?:title|subtitle|label|labelText|hintText|helperText|tooltip|message|semanticLabel|semanticsLabel|description|actionLabel)\s*:\s*)(['"])((?:(?!\1)[^\\\n]|\\.)*)\1''',
  );
  return <String>[
    for (final RegExpMatch m in visible.allMatches(code))
      if (_hasLetters(m.group(2)!)) m.group(2)!,
  ];
}

bool _hasLetters(String literal) => RegExp(
  r'\p{L}{2,}',
  unicode: true,
).hasMatch(literal.replaceAll(RegExp(r'\$\{[^}]*\}|\$\w+'), ''));

/// 字符串字面量内容里出现的 CJK 字符（含全角标点）。按词法区分字面量与注释：
/// [maskComments] 与 [maskCommentsAndStrings] 的差异位即字面量内容。
List<String> findCjkLiterals(String source) {
  final String withStrings = maskComments(source);
  final String withoutStrings = maskCommentsAndStrings(source);
  final RegExp cjk = RegExp(r'[　-ヿ㐀-鿿가-힯＀-￯]');
  final List<String> hits = <String>[];
  final StringBuffer run = StringBuffer();
  void flush() {
    // 掩码也覆盖了引号本身，差异段两端带着引号；去掉后才是字面量内容。
    final String literal = run.toString().replaceAll(
      RegExp(r'''^['"]+|['"]+$'''),
      '',
    );
    if (cjk.hasMatch(literal)) hits.add(literal);
    run.clear();
  }

  for (int i = 0; i < withStrings.length; i++) {
    if (withStrings[i] != withoutStrings[i] && withStrings[i] != '\n') {
      run.write(withStrings[i]);
    } else if (run.isNotEmpty) {
      flush();
    }
  }
  if (run.isNotEmpty) flush();
  return hits;
}
