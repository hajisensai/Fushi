// 把 i18n json 里**新增**的 key 按既有格式补进 `lib/i18n/strings.g.dart`，不重生成整文件。
//
// 为什么需要它：`dart run slang` 重生成 + `dart format` 的输出风格取决于本机 Dart 版本
// （3.7+ 是 tall 风格），与仓库存量的短风格不一致，会产生几十万行 diff。在整仓统一
// formatter 之前，新增 key 走这条路：
//
//   dart run tool/i18n_sync.dart --add <key> <en> <zh>      # 17 个 json
//   dart run tool/i18n_patch_generated.dart <key> [<key>…]  # 补 strings.g.dart
//
// 对每个 `_StringsXx` 语言类：在 json 顺序里紧挨新 key 之前、且已存在于生成文件的那个
// key 的 getter / 方法之后插一行 `String get <key> => '<value>';`；对每个语言类的
// `_flatMapFunction` switch：在同一个前驱 key 的 `case` 分支之后补 `case '<key>': return
// '<value>';`。值按语言从各 json 读取，`'` / `\` / `$` 转义与 slang 一致。只处理无参数的
// 纯字符串 key（带 `$var` 占位的 key 请重生成或手工处理）。幂等：已存在的 key 跳过。
import 'dart:convert';
import 'dart:io';

const String _i18nDir = 'lib/i18n';
const String _generated = 'lib/i18n/strings.g.dart';

/// 语言类在 strings.g.dart 里的顺序 → 对应 json 文件（slang 按 locale 排序生成）。
const List<(String, String)> _classes = <(String, String)>[
  ('_StringsEn', 'strings.i18n.json'),
  ('_StringsAr', 'strings_ar.i18n.json'),
  ('_StringsDe', 'strings_de.i18n.json'),
  ('_StringsEs', 'strings_es.i18n.json'),
  ('_StringsFr', 'strings_fr.i18n.json'),
  ('_StringsId', 'strings_id.i18n.json'),
  ('_StringsIt', 'strings_it.i18n.json'),
  ('_StringsJa', 'strings_ja.i18n.json'),
  ('_StringsKo', 'strings_ko.i18n.json'),
  ('_StringsNl', 'strings_nl.i18n.json'),
  ('_StringsPtBr', 'strings_pt-BR.i18n.json'),
  ('_StringsRu', 'strings_ru.i18n.json'),
  ('_StringsTh', 'strings_th.i18n.json'),
  ('_StringsTr', 'strings_tr.i18n.json'),
  ('_StringsVi', 'strings_vi.i18n.json'),
  ('_StringsZhCn', 'strings_zh-CN.i18n.json'),
  ('_StringsZhHk', 'strings_zh-HK.i18n.json'),
];

String _dartString(String v) {
  final String escaped = v
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');
  return "'$escaped'";
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/i18n_patch_generated.dart <key> [<key>...]');
    exit(64);
  }
  final File genFile = File(_generated);
  final List<String> lines = genFile.readAsStringSync().split('\n');
  final Map<String, dynamic> base = jsonDecode(
    File('$_i18nDir/strings.i18n.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final List<String> order = base.keys.toList();
  final Map<String, Map<String, dynamic>> perLocale = <String, Map<String, dynamic>>{
    for (final (String cls, String file) in _classes)
      cls: jsonDecode(File('$_i18nDir/$file').readAsStringSync())
          as Map<String, dynamic>,
  };

  int inserted = 0;
  for (final String key in args) {
    if (!order.contains(key)) {
      stderr.writeln('key not in $_i18nDir/strings.i18n.json: $key');
      exit(65);
    }
    if (base[key] is! String) {
      stderr.writeln('only plain string keys are supported: $key');
      exit(65);
    }
    final String joined = lines.join('\n');
    if (joined.contains(' get $key => ') || joined.contains(" case '$key':")) {
      stdout.writeln('skip (already present): $key');
      continue;
    }
    // 前驱 key：json 顺序里紧挨之前、且已在生成文件里的 key。
    String? anchor;
    for (int i = order.indexOf(key) - 1; i >= 0; i--) {
      final String k = order[i];
      if (joined.contains(' get $k => ') ||
          joined.contains(' String $k(') ||
          joined.contains(' TextSpan $k(')) {
        anchor = k;
        break;
      }
    }
    if (anchor == null) {
      stderr.writeln('no anchor key found before $key');
      exit(65);
    }
    _insertGetters(lines, key, anchor, perLocale);
    _insertCases(lines, key, anchor, perLocale);
    inserted++;
    stdout.writeln('inserted $key after $anchor');
  }
  genFile.writeAsStringSync(lines.join('\n'));
  stdout.writeln('done: $inserted key(s)');
}

/// 每个语言类：找到 anchor 的 getter / 方法（`String get anchor =>` 或 `String anchor(`），
/// 吃到语句结束（以 `;` 结尾的行），其后插入新 getter。
void _insertGetters(
  List<String> lines,
  String key,
  String anchor,
  Map<String, Map<String, dynamic>> perLocale,
) {
  String? currentClass;
  int i = 0;
  while (i < lines.length) {
    final String line = lines[i];
    final RegExpMatch? cls = RegExp(r'^class (_Strings[A-Za-z]+) ').firstMatch(line);
    if (cls != null) currentClass = cls.group(1);
    final bool isAnchor = line.startsWith('  String get $anchor => ') ||
        line.startsWith('  String $anchor(') ||
        line.startsWith('  TextSpan $anchor(');
    if (isAnchor && currentClass != null && perLocale.containsKey(currentClass)) {
      int j = i;
      while (!lines[j].trimRight().endsWith(';')) {
        j++;
      }
      final String value = (perLocale[currentClass]![key] ?? '') as String;
      lines.insert(j + 1, '  String get $key => ${_dartString(value)};');
      i = j + 2;
      continue;
    }
    i++;
  }
}

/// 每个语言类的 flat-map switch：`case 'anchor':` 的 return 语句（可能折行）之后补一对
/// `case/return`。switch 属于哪个类按出现顺序与 [_classes] 对齐。
void _insertCases(
  List<String> lines,
  String key,
  String anchor,
  Map<String, Map<String, dynamic>> perLocale,
) {
  int classIdx = 0;
  int i = 0;
  while (i < lines.length) {
    if (lines[i].trim() == "case '$anchor':") {
      int j = i + 1;
      while (!lines[j].trimRight().endsWith(';')) {
        j++;
      }
      final String cls = _classes[classIdx].$1;
      final String value = (perLocale[cls]![key] ?? '') as String;
      lines.insert(j + 1, "      case '$key':");
      lines.insert(j + 2, '        return ${_dartString(value)};');
      classIdx++;
      i = j + 3;
      continue;
    }
    i++;
  }
  if (classIdx != _classes.length) {
    stderr.writeln('warning: patched $classIdx flat-map switches for $key '
        '(expected ${_classes.length})');
  }
}
