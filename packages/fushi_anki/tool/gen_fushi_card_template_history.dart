// 从 lib/src/fushi_card_template_data.dart 的 git 历史（加上工作区当前内容）生成
// lib/src/fushi_card_template_history.dart：内置 Fushi 卡片模板每一版的样式哈希与正背面
// 切分规格。
//
// 用法（在 packages/fushi_anki/ 下）：dart run tool/gen_fushi_card_template_history.dart
//
// 登记表**只追加不改删**：已有条目原样保留（顺序、内容都不动），只把还没登记的版本按
// 时间顺序追加到末尾。改了模板数据（tool/gen_fushi_card_template.dart 重新生成后）要再跑
// 一次本脚本；忘了跑由 test/fushi_card_template_history_guard_test.dart 守着。
//
// 为什么要登记：内置模板一旦有修改记录（外观页调区块、导入、同步……）就冻成记录里的全文，
// 之后内置模板再升级，这份冻住的旧版本在逐字比较下就不再是「内置」，原生卡面整张回退
// WebView。登记表让新代码认得每一版旧模板（见 fushi_card_blocks.dart 的
// fushiCardLayoutProbe / fushiCardCssIsBuiltin）。
import 'dart:convert';
import 'dart:io';

import 'package:fushi_anki/src/fushi_card_blocks.dart';
import 'package:fushi_anki/src/fushi_card_template_history.dart';

const String _dataPath = 'lib/src/fushi_card_template_data.dart';
const String _outPath = 'lib/src/fushi_card_template_history.dart';

/// 区块加 `data-fc-block` 标记之前（3f48498f85 起）背面区块的切法：起止标记之间的原文。
const List<(String, String, String)> _legacyBackCuts =
    <(String, String, String)>[
      ('term', '<div class="fc-term">', '</div>'),
      ('reading', '<div class="fc-reading-row">', '</div>'),
      ('picture', '{{#Media}}', '{{/Media}}'),
      ('sentence', '{{#Sentence}}', '{{/Sentence}}'),
      ('definitions', '<section class="fc-defs">', '</section>'),
      ('frequency', '{{#Frequency}}', '{{/Frequency}}'),
      ('source', '{{#Source}}', '{{/Source}}'),
    ];

String? _constant(String source, String name) {
  final Match? m = RegExp(
    'const String $name = r\'\'\'([\\s\\S]*?)\'\'\';',
  ).firstMatch(source);
  return m?.group(1);
}

/// 一版模板数据 [source] 的登记条目；读不出三个常量时为 null。
FushiCardTemplateVersion? _versionOf(String commit, String source) {
  final String? front = _constant(source, 'kFushiCardFrontTemplate');
  final String? back = _constant(source, 'kFushiCardBackTemplate');
  final String? css = _constant(source, 'kFushiCardStylingCss');
  if (front == null || back == null || css == null) return null;
  return FushiCardTemplateVersion(
    commit: commit,
    cssSha256: fushiCardSha256(fushiCardNormalizeCss(css)),
    front: _sideSpec(front, legacyCuts: null),
    back: _sideSpec(back, legacyCuts: _legacyBackCuts),
  );
}

FushiCardSideSpec _sideSpec(
  String template, {
  required List<(String, String, String)>? legacyCuts,
}) {
  if (template.contains('data-fc-block')) {
    final String? skeleton = fushiCardMarkedSkeletonOf(template);
    if (skeleton == null) {
      throw StateError('built-in template has broken block markup');
    }
    return FushiCardSideSpec.markers(fushiCardSha256(skeleton));
  }
  final String u = fushiCardNormalizeTemplate(template);
  if (legacyCuts != null) {
    final List<(String, String)> snippets = <(String, String)>[];
    for (final (String block, String start, String end) in legacyCuts) {
      final int s = template.indexOf(start);
      final int e = s < 0 ? -1 : template.indexOf(end, s + start.length);
      if (e < 0) break;
      snippets.add((
        block,
        fushiCardNormalizeTemplate(template.substring(s, e + end.length)),
      ));
    }
    if (snippets.length == legacyCuts.length) {
      final ({String rest, List<String> order})? sk =
          fushiCardSnippetSkeletonOf(u, snippets);
      final String expected = <String>[
        for (final (String b, String _) in snippets) b,
      ].join(',');
      if (sk != null && sk.order.join(',') == expected) {
        return FushiCardSideSpec.snippets(fushiCardSha256(sk.rest), snippets);
      }
    }
  }
  return FushiCardSideSpec.fixed(fushiCardSha256(u));
}

ProcessResult _run(List<String> args) {
  final ProcessResult r = Process.runSync(
    'git',
    args,
    stdoutEncoding: null,
    stderrEncoding: utf8,
  );
  if (r.exitCode != 0) {
    throw ProcessException('git', args, '${r.stderr}', r.exitCode);
  }
  return r;
}

String _gitText(List<String> args) =>
    utf8.decode(_run(args).stdout as List<int>);

String _key(FushiCardTemplateVersion v) =>
    '${v.cssSha256}|${v.front.kind.name}:${v.front.sha256}|'
    '${v.back.kind.name}:${v.back.sha256}';

String _lit(String s) {
  final String e = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return "'$e'";
}

String _specCode(FushiCardSideSpec s) {
  switch (s.kind) {
    case FushiCardSideSpecKind.fixed:
      return 'FushiCardSideSpec.fixed(${_lit(s.sha256)})';
    case FushiCardSideSpecKind.markers:
      return 'FushiCardSideSpec.markers(${_lit(s.sha256)})';
    case FushiCardSideSpecKind.snippets:
      final StringBuffer b = StringBuffer()
        ..writeln(
          'FushiCardSideSpec.snippets(${_lit(s.sha256)}, '
          '<(String, String)>[',
        );
      for (final (String block, String snip) in s.snippets) {
        b.writeln('      (${_lit(block)}, ${_lit(snip)}),');
      }
      b.write('    ])');
      return b.toString();
  }
}

String _render(List<FushiCardTemplateVersion> versions) {
  final StringBuffer b = StringBuffer()
    ..writeln(
      '// GENERATED by tool/gen_fushi_card_template_history.dart — '
      '只追加不改删，不要手改。',
    )
    ..writeln()
    ..writeln('/// 内置 Fushi 卡片模板的历史版本登记（旧的在前）：每版的样式哈希与正背面切分规格。')
    ..writeln(
      '/// 怎么用、为什么要登记见 fushi_card_blocks.dart 的 fushiCardLayoutProbe 与生成脚本头注释。',
    )
    ..writeln('library;')
    ..writeln()
    ..writeln("import 'fushi_card_blocks.dart';")
    ..writeln()
    ..writeln(
      'const List<FushiCardTemplateVersion> kFushiCardTemplateHistory =',
    )
    ..writeln('    <FushiCardTemplateVersion>[');
  for (final FushiCardTemplateVersion v in versions) {
    b
      ..writeln('  FushiCardTemplateVersion(')
      ..writeln('    commit: ${_lit(v.commit)},')
      ..writeln('    cssSha256: ${_lit(v.cssSha256)},')
      ..writeln('    front: ${_specCode(v.front)},')
      ..writeln('    back: ${_specCode(v.back)},')
      ..writeln('  ),');
  }
  b.writeln('];');
  return b.toString();
}

void main() {
  final List<FushiCardTemplateVersion> out = <FushiCardTemplateVersion>[
    ...kFushiCardTemplateHistory,
  ];
  final Set<String> seen = <String>{
    for (final FushiCardTemplateVersion v in out) _key(v),
  };
  void add(FushiCardTemplateVersion? v) {
    if (v != null && seen.add(_key(v))) out.add(v);
  }

  final List<String> commits =
      _gitText(<String>['log', '--reverse', '--format=%h', '--', _dataPath])
          .split('\n')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
  for (final String c in commits) {
    add(_versionOf(c, _gitText(<String>['show', '$c:./$_dataPath'])));
  }
  add(_versionOf('worktree', File(_dataPath).readAsStringSync()));
  File(_outPath).writeAsStringSync(_render(out));
  stdout.writeln('wrote $_outPath (${out.length} versions)');
}
