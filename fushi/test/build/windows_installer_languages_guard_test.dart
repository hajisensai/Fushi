import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// issue #2716 回归守卫：Windows 安装器必须跟随系统界面语言，覆盖 app 的全部界面语言。
///
/// 修复前的根因（四处叠加，任何一处回来都会让非中文用户重新看到整屏中文）：
///  1. `fushi.iss` 的 `[Languages]` 只列了 `chinesesimplified` 一项——没有别的语言可选；
///  2. `[Messages]` 不带语言前缀——不带前缀的条目会套到**所有**语言上；
///  3. `[Code]` 里的提示框 / 数据目录页 / MD3 页眉全是写死的中文字面量；
///  4. Inno 默认 `UsePreviousLanguage=yes`：存量用户每次升级都会被上次记下的语言
///     （旧版只可能是简体中文）钉住，自动检测永远不生效。
///
/// 这里逐条钉住：语言清单与 `lib/i18n` 一一对应、语言选择三条设置、非编译器自带的
/// 语言文件入库、每种语言的自定义消息键齐全、`[Messages]` 一律带前缀、`[Code]` 不再
/// 有 CJK 字面量。
void main() {
  final String installerDir = p.join('windows', 'installer');

  String read(String name) {
    final File file = File(p.join(installerDir, name));
    expect(file.existsSync(), isTrue, reason: 'expected ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('[Languages] covers every app UI language, english first', () {
    final Set<String> appLocales = <String>{
      for (final FileSystemEntity f in Directory(
        p.join('lib', 'i18n'),
      ).listSync())
        if (f is File && p.basename(f.path).endsWith('.i18n.json'))
          _appLocaleOf(p.basename(f.path)),
    };
    expect(
      appLocales,
      _kInstallerLanguageOf.keys.toSet(),
      reason:
          'app 的界面语言集合变了：给 fushi.iss [Languages] 加上（或删掉）对应的 '
          'Inno 语言，并同步 messages.iss 与本守卫的 _kInstallerLanguageOf。',
    );

    final List<_IssLanguage> languages = parseIssLanguages(read('fushi.iss'));
    final List<String> names = <String>[
      for (final _IssLanguage l in languages) l.name,
    ];
    expect(
      names.toSet(),
      _kInstallerLanguageOf.values.toSet(),
      reason: 'fushi.iss [Languages] must list exactly the app languages',
    );
    expect(names, hasLength(_kInstallerLanguageOf.length));
    expect(names.first, 'english', reason: 'Inno 在系统语言匹配不上时用列表第一项，必须是 english');
    expect(
      names.indexOf('chinesetraditional'),
      lessThan(names.indexOf('chinesesimplified')),
      reason:
          'app 的繁体是 zh-HK（\$0C04），只能靠主语言匹配命中，Inno 取列表中'
          '第一个主语言相同的项，所以繁体必须排在简体前面',
    );
  });

  test('language selection follows the Windows UI language every run', () {
    final Map<String, String> setup = parseIssSection(
      read('fushi.iss'),
      'Setup',
    );
    expect(setup['LanguageDetectionMethod'], 'uilanguage');
    expect(setup['ShowLanguageDialog'], 'auto');
    expect(
      setup['UsePreviousLanguage'],
      'no',
      reason:
          'Inno 默认沿用上次安装记下的语言；旧版只有简体中文，不关掉的话存量'
          '用户每次升级都会被钉回中文',
    );
  });

  test('every language file is either bundled with ISCC 6.7.3 or vendored', () {
    final List<_IssLanguage> languages = parseIssLanguages(read('fushi.iss'));
    final List<String> problems = <String>[];
    for (final _IssLanguage l in languages) {
      if (l.messagesFile.startsWith('compiler:')) {
        final String rel = l.messagesFile.substring('compiler:'.length);
        if (rel != 'Default.isl' &&
            !_kInno673BundledLanguages.contains(rel.replaceAll(r'\', '/'))) {
          problems.add(
            '${l.name}: $rel 不随 Inno 6.7.3 官方安装包附带，CI 编译机上没有'
            '——入库到 windows/installer/languages/',
          );
        }
        continue;
      }
      final File file = File(
        p.joinAll(<String>[installerDir, ...l.messagesFile.split(r'\')]),
      );
      if (!file.existsSync()) {
        problems.add('${l.name}: ${file.path} 不存在');
      } else if (!file.readAsStringSync().contains('LanguageName=')) {
        problems.add('${l.name}: ${file.path} 不是 Inno 语言文件');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('custom messages are complete for every language', () {
    final String messages = read('messages.iss');
    final List<String> languageNames = <String>[
      for (final _IssLanguage l in parseIssLanguages(read('fushi.iss'))) l.name,
    ];
    final _Messages custom = parseMessages(messages, 'CustomMessages');
    final Map<String, String> fallback = custom.unprefixed;
    expect(
      fallback.length,
      greaterThanOrEqualTo(30),
      reason: 'the unprefixed English fallback set looks truncated',
    );

    // [Code] / [Tasks] / [Registry] 引用到的自家消息都必须有英文兜底。
    final String code = <String>[
      read('fushi.iss'),
      read('md3_layout.iss'),
      read('md3_controls.iss'),
    ].join('\n');
    final Set<String> referenced = <String>{
      for (final RegExpMatch m in RegExp(
        r'''CustomMessage\('(Fushi\w+)'\)|\{cm:(Fushi\w+)''',
      ).allMatches(code))
        m.group(1) ?? m.group(2)!,
    };
    expect(referenced, isNotEmpty);
    expect(
      referenced.difference(fallback.keys.toSet()),
      isEmpty,
      reason: 'messages referenced from the installer without a definition',
    );

    final List<String> problems = <String>[];
    for (final String prefix in custom.byLanguage.keys) {
      if (!languageNames.contains(prefix)) {
        problems.add('[CustomMessages] unknown language prefix "$prefix"');
      }
    }
    for (final String lang in languageNames) {
      final Map<String, String> own =
          custom.byLanguage[lang] ?? <String, String>{};
      for (final String key in fallback.keys) {
        if (_kPerLanguageOptional.contains(key)) continue;
        if (lang != 'english' && !own.containsKey(key)) {
          problems.add('$lang.$key missing (would fall back to English)');
        }
      }
      for (final String key in own.keys) {
        if (!fallback.containsKey(key)) {
          problems.add('$lang.$key has no English fallback');
        }
        final String english = fallback[key] ?? '';
        for (final String arg in <String>['%1', '%2']) {
          if (english.contains(arg) != own[key]!.contains(arg)) {
            problems.add('$lang.$key: placeholder $arg mismatch with English');
          }
        }
        if (lang != 'english' &&
            !_kPerLanguageOptional.contains(key) &&
            own[key] == english &&
            RegExp('[A-Za-z]{4,}').hasMatch(english) &&
            !_kSameInEveryLanguage.contains(key)) {
          problems.add('$lang.$key is still the English text');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('[Messages] entries are always language-prefixed', () {
    final List<String> languageNames = <String>[
      for (final _IssLanguage l in parseIssLanguages(read('fushi.iss'))) l.name,
    ];
    final List<String> problems = <String>[];
    for (final String file in <String>['fushi.iss', 'messages.iss']) {
      final _Messages m = parseMessages(read(file), 'Messages');
      for (final String key in m.unprefixed.keys) {
        problems.add(
          '$file: [Messages] $key has no language prefix — it would '
          'override every language',
        );
      }
      for (final String prefix in m.byLanguage.keys) {
        if (!languageNames.contains(prefix)) {
          problems.add('$file: unknown [Messages] language prefix "$prefix"');
        }
      }
    }
    final _Messages page = parseMessages(read('messages.iss'), 'Messages');
    final Set<String> englishKeys =
        page.byLanguage['english']?.keys.toSet() ?? <String>{};
    expect(englishKeys, isNotEmpty);
    for (final String lang in languageNames) {
      final Set<String> own = page.byLanguage[lang]?.keys.toSet() ?? <String>{};
      final Set<String> missing = englishKeys.difference(own);
      if (missing.isNotEmpty) {
        problems.add(
          '$lang: page text $missing missing — that page would mix the '
          'stock .isl wording with ours',
        );
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('no hard-coded CJK text in installer [Code]', () {
    final Map<String, String> sources = <String, String>{
      'fushi.iss': _codeSection(read('fushi.iss')),
      'md3_layout.iss': read('md3_layout.iss'),
      'md3_controls.iss': read('md3_controls.iss'),
      'process_control.iss': read('process_control.iss'),
    };
    expect(
      sources['fushi.iss']!.length,
      greaterThan(10000),
      reason: '[Code] section of fushi.iss not found or truncated',
    );
    final List<String> hits = <String>[
      for (final MapEntry<String, String> e in sources.entries)
        for (final String literal in pascalCjkLiterals(e.value))
          '${e.key}: \'$literal\'',
    ];
    expect(
      hits,
      isEmpty,
      reason:
          'user-visible installer text belongs in messages.iss '
          '(CustomMessage / FmtMessage), not in [Code] literals:\n'
          '${hits.join('\n')}',
    );
  });

  group('parsers catch synthetic violations', () {
    test('pascalCjkLiterals', () {
      // #2716 修复前的写法。
      expect(pascalCjkLiterals("MsgBox('数据目录不可写。', mbError, MB_OK);"), <String>[
        '数据目录不可写。',
      ]);
      expect(pascalCjkLiterals("S := 'it''s ' + '安装';"), <String>['安装']);
      // 注释里的中文不算。
      expect(pascalCjkLiterals('{ 中文注释 } X := 1;'), isEmpty);
      expect(
        pascalCjkLiterals("// 'quoted 中文' in a comment\nX := 1;"),
        isEmpty,
      );
      expect(pascalCjkLiterals("(* 注释 *) S := 'plain';"), isEmpty);
      // 字符串里的花括号不是注释开头。
      expect(pascalCjkLiterals("S := '{app}' + '中';"), <String>['中']);
    });

    test('parseMessages', () {
      final _Messages m = parseMessages(
        '[Messages]\n; comment\nWizardReady=就绪\nenglish.WizardReady=Ready\n'
            '[CustomMessages]\nFushiX=x\n',
        'Messages',
      );
      expect(m.unprefixed.keys, <String>['WizardReady']);
      expect(m.byLanguage['english'], <String, String>{'WizardReady': 'Ready'});
    });

    test('parseIssLanguages', () {
      final List<_IssLanguage> l = parseIssLanguages(
        '[Languages]\n; c\nName: "chinesesimplified"; '
        'MessagesFile: "ChineseSimplified.isl"\n[Tasks]\n',
      );
      expect(l.single.name, 'chinesesimplified');
      expect(l.single.messagesFile, 'ChineseSimplified.isl');
    });
  });
}

/// app 语言（`lib/i18n` 文件名里的 locale）→ Inno `[Languages]` 的 Name。
const Map<String, String> _kInstallerLanguageOf = <String, String>{
  'en': 'english',
  'ar': 'arabic',
  'pt-BR': 'brazilianportuguese',
  'zh-HK': 'chinesetraditional',
  'zh-CN': 'chinesesimplified',
  'nl': 'dutch',
  'fr': 'french',
  'de': 'german',
  'id': 'indonesian',
  'it': 'italian',
  'ja': 'japanese',
  'ko': 'korean',
  'ru': 'russian',
  'es': 'spanish',
  'th': 'thai',
  'tr': 'turkish',
  'vi': 'vietnamese',
};

/// Inno Setup 6.7.3 官方安装包随附的 `Languages\*.isl`（本机 6.7.3 安装目录实测）。
/// CI 编译机装的是同一个钉死 SHA-256 的 6.7.3；不在表里的必须入库。
const Set<String> _kInno673BundledLanguages = <String>{
  'Languages/Arabic.isl',
  'Languages/Armenian.isl',
  'Languages/BrazilianPortuguese.isl',
  'Languages/Bulgarian.isl',
  'Languages/Catalan.isl',
  'Languages/Corsican.isl',
  'Languages/Czech.isl',
  'Languages/Danish.isl',
  'Languages/Dutch.isl',
  'Languages/Finnish.isl',
  'Languages/French.isl',
  'Languages/German.isl',
  'Languages/Hebrew.isl',
  'Languages/Hungarian.isl',
  'Languages/Italian.isl',
  'Languages/Japanese.isl',
  'Languages/Korean.isl',
  'Languages/Norwegian.isl',
  'Languages/Polish.isl',
  'Languages/Portuguese.isl',
  'Languages/Russian.isl',
  'Languages/Slovak.isl',
  'Languages/Slovenian.isl',
  'Languages/Spanish.isl',
  'Languages/Swedish.isl',
  'Languages/Tamil.isl',
  'Languages/Thai.isl',
  'Languages/Turkish.isl',
  'Languages/Ukrainian.isl',
};

/// 只在需要换字体的语言里覆盖（CJK / 阿拉伯 / 泰文），其余用英文兜底的字体名。
const Set<String> _kPerLanguageOptional = <String>{'FushiUiFont'};

/// 各语言里写法确实与英文一样的消息（文件类型名一类专有名）。
const Set<String> _kSameInEveryLanguage = <String>{};

String _appLocaleOf(String fileName) {
  if (fileName == 'strings.i18n.json') return 'en';
  return fileName.replaceFirst('strings_', '').replaceFirst('.i18n.json', '');
}

class _IssLanguage {
  const _IssLanguage(this.name, this.messagesFile);
  final String name;
  final String messagesFile;
}

class _Messages {
  final Map<String, String> unprefixed = <String, String>{};
  final Map<String, Map<String, String>> byLanguage =
      <String, Map<String, String>>{};
}

/// 返回某个 `[Section]` 的正文行（不含注释与空行）。同名段出现多次时拼在一起。
List<String> _sectionLines(String iss, String section) {
  final List<String> out = <String>[];
  bool inSection = false;
  for (final String raw in iss.split('\n')) {
    final String line = raw.trim();
    final RegExpMatch? header = RegExp(r'^\[([A-Za-z]+)\]$').firstMatch(line);
    if (header != null) {
      inSection = header.group(1) == section;
      continue;
    }
    if (!inSection || line.isEmpty || line.startsWith(';')) continue;
    out.add(line);
  }
  return out;
}

Map<String, String> parseIssSection(String iss, String section) {
  return <String, String>{
    for (final String line in _sectionLines(iss, section))
      if (line.contains('='))
        line.substring(0, line.indexOf('=')).trim(): line
            .substring(line.indexOf('=') + 1)
            .trim(),
  };
}

List<_IssLanguage> parseIssLanguages(String iss) {
  final RegExp entry = RegExp(
    r'Name:\s*"([^"]+)";\s*MessagesFile:\s*"([^"]+)"',
  );
  return <_IssLanguage>[
    for (final String line in _sectionLines(iss, 'Languages'))
      if (entry.firstMatch(line) case final RegExpMatch m)
        _IssLanguage(m.group(1)!, m.group(2)!),
  ];
}

_Messages parseMessages(String iss, String section) {
  final _Messages result = _Messages();
  final RegExp entry = RegExp(r'^(?:([a-z]+)\.)?([A-Za-z0-9_]+)=(.*)$');
  for (final String line in _sectionLines(iss, section)) {
    final RegExpMatch? m = entry.firstMatch(line);
    if (m == null) continue;
    final String? prefix = m.group(1);
    if (prefix == null) {
      result.unprefixed[m.group(2)!] = m.group(3)!;
    } else {
      (result.byLanguage[prefix] ??= <String, String>{})[m.group(2)!] = m.group(
        3,
      )!;
    }
  }
  return result;
}

/// `fushi.iss` 里 `[Code]` 段到文件末尾的部分（[Code] 是最后一段）。
String _codeSection(String iss) {
  final int start = iss.indexOf('\n[Code]');
  return start < 0 ? '' : iss.substring(start);
}

/// Pascal Script 源码里含 CJK（含全角标点）的字符串字面量。按词法跳过
/// `{ }`、`(* *)`、`//` 三种注释；`''` 是字面量里的单引号。
List<String> pascalCjkLiterals(String source) {
  final RegExp cjk = RegExp(r'[　-ヿ㐀-鿿가-힯＀-￯]');
  final List<String> hits = <String>[];
  int i = 0;
  while (i < source.length) {
    final String c = source[i];
    if (c == '{') {
      final int end = source.indexOf('}', i + 1);
      i = end < 0 ? source.length : end + 1;
    } else if (source.startsWith('(*', i)) {
      final int end = source.indexOf('*)', i + 2);
      i = end < 0 ? source.length : end + 2;
    } else if (source.startsWith('//', i)) {
      final int end = source.indexOf('\n', i);
      i = end < 0 ? source.length : end + 1;
    } else if (c == "'") {
      final StringBuffer literal = StringBuffer();
      i++;
      while (i < source.length) {
        if (source[i] == "'") {
          if (i + 1 < source.length && source[i + 1] == "'") {
            literal.write("'");
            i += 2;
            continue;
          }
          i++;
          break;
        }
        if (source[i] == '\n') break;
        literal.write(source[i]);
        i++;
      }
      final String text = literal.toString();
      if (cjk.hasMatch(text)) hits.add(text);
    } else {
      i++;
    }
  }
  return hits;
}
