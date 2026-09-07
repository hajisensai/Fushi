// CI 注入 secret 时生成的 Dart 源码，**必须**能过 analyze 门。
//
// 真实事故（2026-09-07，develop 连红两条 PR）：provide-baked-secrets 里
// OpenSubtitles 那一步照抄了 google_oauth_secret.dart 的 `json.dumps` 写法，
// 产出双引号字面量并整份覆写文件：
//
//     const String kBuiltinOpenSubtitlesApiKey = "<key>";
//
// google_oauth_secret.dart / log_upload_secret.dart 这么写没事，**只因为**它们
// 在 fushi/analysis_options.yaml 的 analyzer.exclude 里。opensubtitles_default_key.dart
// 不在 exclude 里，于是双引号触发 prefer_single_quotes（info），而 CI 的
// analyze 门把 info 也当失败 → 每个带该 secret 的 run 必红。本地
// `flutter analyze` 看到的是**入库的单引号占位**，所以本地永远绿、只有 CI 红。
//
// 这条守卫钉死那个不变式：composite action 每个写 Dart 文件的步骤，其目标要么
// 在 analyzer.exclude 名单里，要么不得产生双引号字面量。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 仓库根（本测试从 `fushi/` 下跑）。
Directory get _repoRoot => Directory.current.path.endsWith('fushi')
    ? Directory.current.parent
    : Directory.current;

File get _actionFile => File(
      '${_repoRoot.path}/.github/actions/provide-baked-secrets/action.yml',
    );

File get _analysisOptions =>
    File('${_repoRoot.path}/fushi/analysis_options.yaml');

/// analysis_options.yaml 的 `analyzer.exclude` 里列出的文件名（basename）。
Set<String> _excludedBasenames() {
  final List<String> lines = _analysisOptions.readAsLinesSync();
  final Set<String> out = <String>{};
  bool inExclude = false;
  for (final String raw in lines) {
    final String line = raw.trimRight();
    if (line.trimLeft().startsWith('exclude:')) {
      inExclude = true;
      continue;
    }
    if (inExclude) {
      final String t = line.trim();
      if (!t.startsWith('- ')) {
        // 缩进回退到下一个 key，exclude 段结束。
        if (t.isNotEmpty) inExclude = false;
        continue;
      }
      out.add(t.substring(2).replaceAll("'", '').replaceAll('**/', ''));
    }
  }
  return out;
}

/// 去掉 python 源码里的模块 docstring 与 `#` 注释，只留可执行代码。
///
/// 守卫要判的是「脚本**做**了什么」，不是「注释里**提**到什么」——解释本 bug
/// 成因的那段说明必然会写到 json.dumps，裸字串匹配会把它自己判成违规。
String _stripPythonComments(String source) {
  String out = source;
  final int open = out.indexOf('"""');
  if (open >= 0) {
    final int close = out.indexOf('"""', open + 3);
    if (close > open) out = out.substring(close + 3);
  }
  return out
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('#'))
      .join('\n');
}

void main() {
  test('action.yml 存在（路径没被挪走，守卫不会静默失效）', () {
    expect(_actionFile.existsSync(), isTrue,
        reason: '${_actionFile.path} 不在了；守卫失去扫描对象');
    expect(_analysisOptions.existsSync(), isTrue);
  });

  test('exclude 名单解析出了 google_oauth / log_upload（解析器自身没坏）', () {
    final Set<String> excluded = _excludedBasenames();
    expect(excluded, contains('google_oauth_secret.dart'),
        reason: '解析 analyzer.exclude 失败，后面的断言会变成恒真');
    expect(excluded, contains('log_upload_secret.dart'));
  });

  test('写入不在 analyzer.exclude 里的 Dart 文件时，不得产生双引号字面量', () {
    final String yaml = _actionFile.readAsStringSync();
    final Set<String> excluded = _excludedBasenames();

    // 每个步骤都以 `dst=<路径>` 声明目标文件；按 dst 切段，逐段判定。
    final RegExp dstPattern = RegExp(r'dst=(\S+\.dart)');
    final List<RegExpMatch> hits = dstPattern.allMatches(yaml).toList();
    expect(hits, isNotEmpty, reason: '没扫到任何 dst=，守卫恒真了');

    final List<String> offenders = <String>[];
    for (int i = 0; i < hits.length; i++) {
      final String dst = hits[i].group(1)!;
      final String basename = dst.split('/').last;
      if (excluded.contains(basename)) continue;

      final int start = hits[i].start;
      final int end = i + 1 < hits.length ? hits[i + 1].start : yaml.length;
      final String body = yaml.substring(start, end);

      // json.dumps 一定产出双引号；printf 模板里直接写 `= "` 同理。
      if (body.contains('json.dumps') ||
          body.contains(r'kBuiltin') && body.contains('= \\"')) {
        offenders.add(
          '$dst：该文件不在 analyzer.exclude 里，写它的步骤却会产出双引号字面量'
          '（prefer_single_quotes → CI analyze 门 exit 1）',
        );
      }
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('OpenSubtitles key 走独立脚本，且脚本产出单引号', () {
    final File writer = File(
      '${_repoRoot.path}/.github/actions/provide-baked-secrets/'
      'write_opensubtitles_key.py',
    );
    expect(writer.existsSync(), isTrue,
        reason: '生成脚本不在了；action.yml 会在 CI 上直接报 file not found');

    final String src = writer.readAsStringSync();
    expect(src.contains("kBuiltinOpenSubtitlesApiKey = '%s'"), isTrue,
        reason: '生成模板必须是单引号 Dart 字面量');
    // 只看**真实代码**：脚本的文档注释本来就要解释「为什么不用 json.dumps」，
    // 拿裸字串判定会把那段说明本身判成违规。
    expect(_stripPythonComments(src).contains('json.dumps('), isFalse,
        reason: 'json.dumps 产出双引号，正是本 bug 的成因');
    // 单引号字符串里 $ 仍是插值符，必须转义，否则 `abc$id` 形态的 key 编译失败。
    expect(src.contains(r"replace('$'"), isTrue,
        reason: '缺 \$ 转义：含 \$ 的 key 会被当成 Dart 插值');
  });
}
