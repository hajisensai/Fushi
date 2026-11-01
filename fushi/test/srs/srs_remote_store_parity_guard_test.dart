// 远程复习与本机复习功能一致的守卫（docs/specs/2026-11-01-srs-remote-review-design.md）。
//
// 远程复习时，复习页及它能打开的页面原样跑在 SrsRemoteStore 上（srs_remote_store_client.dart），没覆盖的
// SrsDbStore 成员在运行时才抛 UnsupportedError——新加一处 `store.xxx(` 而远程库没转发，本机测试全绿、
// 远程复习时那个功能却是坏的。这里按源码核对三件事：
// 1. 可达页面经 `store` / `_store` 用到的 SrsDbStore 成员，SrsRemoteStore 都覆盖了；
// 2. 可达页面用到的 SrsDbStore 扩展方法，若（连同它调用的扩展私有方法）直接读库（`db.` / `core.`）、
//    走内核命令（`sync2Command`）或调用远程库没覆盖的成员，就必须在开头按 SrsRemoteForwarding 转发；
// 3. 客户端调用的操作名主机都有。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _engine = '../packages/fushi_engine/lib/srs';

/// 远程复习会话里可达的页面与它们调用的引擎流程。新页面能从复习页 / 远程牌组列表打开时加进来。
const List<String> _reachable = <String>[
  'lib/src/pages/implementations/srs/srs_remote_review_page.dart',
  'lib/src/pages/implementations/srs/srs_review_page.dart',
  'lib/src/pages/implementations/srs/srs_review_edit_bar.dart',
  'lib/src/pages/implementations/srs/srs_review_layout_sheet.dart',
  'lib/src/pages/implementations/srs/srs_review_gestures_page.dart',
  'lib/src/pages/implementations/srs/srs_note_editor_page.dart',
  'lib/src/pages/implementations/srs/srs_deck_settings_page.dart',
  'lib/src/pages/implementations/srs/srs_template_editor_page.dart',
  'lib/src/pages/implementations/srs/srs_card_appearance_page.dart',
  'lib/src/pages/implementations/srs/srs_browse_page.dart',
  'lib/src/pages/implementations/srs/srs_browse_dialogs.dart',
  'lib/src/pages/implementations/srs/srs_browse_preview.dart',
  'lib/src/pages/implementations/srs/srs_field_ai_sheet.dart',
  'lib/src/pages/implementations/srs/srs_card_lookup.dart',
  'lib/src/pages/implementations/srs/srs_card_face.dart',
  'lib/src/pages/implementations/srs/srs_fushi_card_view.dart',
  'lib/src/pages/implementations/srs/srs_field_info_page.dart',
  'lib/src/pages/implementations/srs/srs_edit_history_page.dart',
  'lib/src/pages/implementations/srs/srs_change_note_type_page.dart',
  'lib/src/pages/implementations/srs/srs_note_preview.dart',
  'lib/src/pages/implementations/srs/srs_field_editors.dart',
  'lib/src/pages/implementations/srs/srs_visual_template_panel.dart',
  'lib/src/pages/implementations/srs/srs_html_layout_editor.dart',
  'lib/src/pages/implementations/srs/srs_ui.dart',
  'lib/src/srs/srs_custom_study_flow.dart',
  'lib/src/srs/srs_change_note_type.dart',
  '$_engine/srs_browse.dart',
  '$_engine/srs_browse_ops.dart',
];

String _read(String path) => File(path).readAsStringSync();

/// `head` 之后第一个 `{` 起、与之配对的 `}` 为止。
String _block(String src, int from) {
  final int open = src.indexOf('{', from);
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
  }
  throw StateError('unbalanced block');
}

String _classBody(String src, String head) {
  final int at = src.indexOf(head);
  if (at < 0) throw StateError('not found: $head');
  return _block(src, at);
}

Set<String> _storeMembers() {
  final String body = _classBody(
    _read('$_engine/srs_db_store.dart'),
    'class SrsDbStore implements',
  );
  return <String>{
    for (final RegExpMatch m in RegExp(
      r'^  (?:Future<.*?>|Stream<.*?>|bool|int|String\??|\(int, SrsTimeSource\)|'
      r'SrsRwkvScheduling\?|FsrsEngine\?) (?:get )?([a-z]\w*)\b',
      multiLine: true,
    ).allMatches(body))
      m.group(1)!,
  };
}

Set<String> _remoteOverrides() {
  final String body = _classBody(
    _read('lib/src/srs/srs_remote_store_client.dart'),
    'class SrsRemoteStore implements',
  );
  return <String>{
    for (final RegExpMatch m in RegExp(
      r'@override\s+(?:[\w<>?,(){} ]+?\s+)?(?:get\s+)?([a-z]\w*)\s*(?:<[^>]*>)?\s*(?:\(|=>|;)',
    ).allMatches(body))
      m.group(1)!,
  };
}

/// SrsDbStore 扩展里的方法（含私有）→ 方法体。
Map<String, String> _extensionMethods() {
  final Map<String, String> out = <String, String>{};
  for (final FileSystemEntity f in Directory(_engine).listSync()) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    final String src = f.readAsStringSync();
    for (final RegExpMatch ext in RegExp(
      r'^extension \w+ on SrsDbStore',
      multiLine: true,
    ).allMatches(src)) {
      final String body = _block(src, ext.start);
      // 只认两格缩进、同一行里「返回类型 名字(」的声明；调用行（`await f(`、`return f(`、续行的 `f(`）
      // 不算——否则同名调用会覆盖真声明，结果随文件枚举顺序变（Windows 绿、Linux 红）。
      final List<RegExpMatch> decls = RegExp(
        r'^  (?!(?:return|await|final|var|if|for|while|switch|throw|else|case)\b)'
        r'(?:Future<[^\n]*?>+|[\w<>?,()][\w<>?,() ]*?)[ \t]+(?:get[ \t]+)?'
        r'(_?[a-z]\w*)[ \t]*(?:<[^>\n]*>)?\(',
        multiLine: true,
      ).allMatches(body).toList();
      for (int i = 0; i < decls.length; i++) {
        final int end = i + 1 < decls.length ? decls[i + 1].start : body.length;
        final String name = decls[i].group(1)!;
        if (out.containsKey(name)) throw StateError('重复的扩展方法：$name');
        out[name] = body.substring(decls[i].start, end);
      }
    }
  }
  return out;
}

void main() {
  final Set<String> members = _storeMembers();
  final Set<String> overrides = _remoteOverrides();
  final Map<String, String> extensions = _extensionMethods();
  final RegExp storeUse = RegExp(r'\b(?:store|_store)[!?]?\.([a-z]\w*)\b');

  final Map<String, Set<String>> used = <String, Set<String>>{};
  for (final String path in _reachable) {
    for (final RegExpMatch m in storeUse.allMatches(_read(path))) {
      used.putIfAbsent(m.group(1)!, () => <String>{}).add(path);
    }
  }

  test('可达页面用到的复习库成员，远程库都已转发', () {
    expect(members, contains('answerAndStudy'), reason: '成员解析失效');
    expect(overrides, contains('answerAndStudy'), reason: '覆盖解析失效');
    final Map<String, Set<String>> missing = <String, Set<String>>{
      for (final MapEntry<String, Set<String>> e in used.entries)
        if (members.contains(e.key) && !overrides.contains(e.key))
          e.key: e.value,
    };
    expect(missing, isEmpty);
  });

  test('可达页面用到的扩展方法：碰本机库 / 内核命令的都按 SrsRemoteForwarding 转发', () {
    expect(extensions, contains('saveTemplateEdits'), reason: '扩展解析失效');
    final Map<String, List<String>> offenders = <String, List<String>>{};
    for (final String name in used.keys.where(extensions.containsKey)) {
      final String body = extensions[name]!;
      if (body.contains('SrsRemoteForwarding')) continue;
      // 连同它调用的扩展方法（含私有）一起看。
      final Set<String> seen = <String>{};
      final List<String> stack = <String>[name];
      final List<String> problems = <String>[];
      while (stack.isNotEmpty) {
        final String m = stack.removeLast();
        if (!seen.add(m)) continue;
        final String b = extensions[m]!;
        if (b.contains('SrsRemoteForwarding') && m != name) continue;
        if (RegExp(r'(?<![.\w])(?:db|core)\.').hasMatch(b)) {
          problems.add('$m: db/core');
        }
        if (b.contains('sync2Command(')) problems.add('$m: sync2Command');
        for (final RegExpMatch c in RegExp(
          r'(?<![.\w])(_?[a-z]\w*)\(',
        ).allMatches(b)) {
          final String callee = c.group(1)!;
          if (extensions.containsKey(callee)) stack.add(callee);
          if (members.contains(callee) && !overrides.contains(callee)) {
            problems.add('$m → $callee');
          }
        }
      }
      if (problems.isNotEmpty) offenders[name] = problems;
    }
    expect(offenders, isEmpty);
  });

  test('客户端调用的操作名主机都有', () {
    final Set<String> hostOps = <String>{
      for (final RegExpMatch m in RegExp(
        r"^    '(\w+)': _Op\(",
        multiLine: true,
      ).allMatches(_read('$_engine/srs_remote_store.dart')))
        m.group(1)!,
    };
    final Set<String> clientOps = <String>{
      for (final RegExpMatch m in RegExp(
        r"_(?:read|write|cardWrite)\(\s*'(\w+)'",
      ).allMatches(_read('lib/src/srs/srs_remote_store_client.dart')))
        m.group(1)!,
    };
    expect(hostOps, contains('answerAndStudy'), reason: '操作表解析失效');
    expect(clientOps.difference(hostOps), isEmpty);
  });
}
