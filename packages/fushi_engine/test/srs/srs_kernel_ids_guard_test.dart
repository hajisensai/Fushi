// 根上的 ID 与同步目录名只向内核要（docs/specs/2026-11-11-srs-generation-break.md §5.1、§5.2、G5）。源码守卫：
//
// 1. 各包与 app 的 lib / bin / tool 里没有带盐派生：不拼「`<uid>/note/…`」「`<uid>/notetype/…`」「`<uid>/deck/…`」
//    「`<uid>/deck-alt/…`」「`<uid>/builtin-deck/…`」「`profile-merge/<uid>/…`」「`notetype-dup/…`」「`sync2/collection/…`」
//    这类名字，也不拿 Fushi 命名空间（`srsNamespace`）现算 ID——唯一的例外是修改记录 ID（`edit/<写入者>/<seq>`，不带盐）。
// 2. `SrsIds` 里不再有根上的规则（`note` / `notes` / `noteType` / `deck` / `deckAlternate` / `builtinDefaultDeck`）。
// 3. 内核那一侧的入口还在：`ffsrs_call` 分发 `ids`，规则在 gen4_ids/rules.rs。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 仓库根（本测试在 packages/fushi_engine 下跑）。
const String _kRepoRoot = '../..';

/// 带盐派生的名字片段（字符串字面量里出现即违规）。
final RegExp _kSaltedName = RegExp(
  r'''['"][^'"\n]*(/note/|/notetype/|/deck/|/deck-alt/|/builtin-deck/|profile-merge/|notetype-dup/|sync2/collection/)''',
);

/// 拿 Fushi 命名空间现算 ID。
final RegExp _kNamespaceDerive = RegExp(r'\(\s*srsNamespace\s*,');

/// 唯一允许的命名空间派生：修改记录 ID。
const String _kEditIdLine = "uuidV5(srsNamespace, 'edit/\$writerId/\$seq')";

const String _kIdsFile = 'packages/fushi_srs/lib/src/ids.dart';

List<Directory> _productionDirs() {
  final List<Directory> out = <Directory>[];
  final List<Directory> packages = <Directory>[
    Directory(p.join(_kRepoRoot, 'fushi')),
    ...Directory(
      p.join(_kRepoRoot, 'packages'),
    ).listSync().whereType<Directory>(),
  ];
  for (final Directory pkg in packages) {
    for (final String sub in const <String>['lib', 'bin', 'tool']) {
      final Directory d = Directory(p.join(pkg.path, sub));
      if (d.existsSync()) out.add(d);
    }
  }
  return out;
}

String _relative(String path) =>
    p.relative(path, from: _kRepoRoot).replaceAll(r'\', '/');

/// 一行里注释以外的部分（`//` 起头的整行注释与行尾注释去掉；字符串里的 `//` 不算）。
String _code(String line) {
  if (line.trimLeft().startsWith('//')) return '';
  bool inSingle = false;
  bool inDouble = false;
  for (int i = 0; i < line.length; i++) {
    final String c = line[i];
    if (c == r'\') {
      i++;
      continue;
    }
    if (c == "'" && !inDouble) inSingle = !inSingle;
    if (c == '"' && !inSingle) inDouble = !inDouble;
    if (!inSingle && !inDouble && line.startsWith('//', i)) {
      return line.substring(0, i);
    }
  }
  return line;
}

/// [lines] 里违规的行（`<文件>:<行号>: <原文>`）。
List<String> _offenders(String rel, List<String> lines) {
  final List<String> out = <String>[];
  for (int i = 0; i < lines.length; i++) {
    final String code = _code(lines[i]);
    if (code.isEmpty) continue;
    final bool salted = _kSaltedName.hasMatch(code);
    final bool ns =
        _kNamespaceDerive.hasMatch(code) &&
        !(rel == _kIdsFile && code.contains(_kEditIdLine));
    if (salted || ns) out.add('$rel:${i + 1}: ${lines[i].trim()}');
  }
  return out;
}

void main() {
  test('生产代码里没有带盐派生（根上的 ID 与同步目录名向内核要）', () {
    final List<Directory> dirs = _productionDirs();
    expect(
      <String>{for (final Directory d in dirs) _relative(d.path)},
      containsAll(<String>[
        'fushi/lib',
        'packages/fushi_engine/lib',
        'packages/fushi_srs/lib',
        'packages/fushi_server/lib',
      ]),
    );
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final Directory dir in dirs) {
      for (final File f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        scanned++;
        offenders.addAll(_offenders(_relative(f.path), f.readAsLinesSync()));
      }
    }
    expect(scanned, greaterThan(100));
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('守卫自检：改造前的写法都会被抓到', () {
    for (final String line in <String>[
      r"      uuidV5(srsNamespace, '$profileUid/builtin-deck/default');",
      r"  static String _noteName(String u, String g) => '$u/note/$g';",
      r"      uuidV5(srsNamespace, '$profileUid/notetype/$ankiNum');",
      r"        '$profileUid/deck-alt/$n/${normalizeDeckPath(fullPath)}',",
      r"      (srsNamespace, 'profile-merge/$newUid/writer/$o'),",
      r"    'notetype-dup/${src.ankiNum}/${srsCanonicalJson(m)}',",
      r'    "sync2/collection/$uid"',
    ]) {
      expect(_offenders('x.dart', <String>[line]), hasLength(1), reason: line);
    }
    // 注释与修改记录 ID 不算。
    expect(
      _offenders('x.dart', <String>[
        "/// 笔记：`v5(NS, uid/note/guid)`",
        "  // '\$uid/note/\$guid' 以前在 Dart 拼",
      ]),
      isEmpty,
    );
    expect(_offenders(_kIdsFile, <String>['      $_kEditIdLine;']), isEmpty);
    expect(
      _offenders('x.dart', <String>['      $_kEditIdLine;']),
      hasLength(1),
    );
  });

  test('SrsIds 里没有根上的规则；内核的 ids 入口与规则表都在', () {
    final String ids = File(p.join(_kRepoRoot, _kIdsFile)).readAsStringSync();
    for (final String gone in <String>[
      'static String note(',
      'static List<String> notes(',
      'static String noteType(',
      'static String deck(',
      'static String deckAlternate(',
      'static String builtinDefaultDeck(',
    ]) {
      expect(ids, isNot(contains(gone)), reason: gone);
    }
    final String lib = File(
      p.join(_kRepoRoot, 'native/fushi_fsrs/src/lib.rs'),
    ).readAsStringSync();
    expect(lib, contains('"ids" => gen4_ids::derive::derive(req)'));
    final String rules = File(
      p.join(_kRepoRoot, 'native/fushi_fsrs/src/gen4_ids/rules.rs'),
    ).readAsStringSync();
    expect(rules, contains('pub fn duplicate_note_type_anki_num('));
  });
}
