import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：`fushi/lib/i18n/strings.g.dart` 不入库，凡是要编 app 的地方都先生成它。
///
/// 这份 Slang 生成文件 37 MB、两千多个版本（历史约 676 MB），2026-11 起不再入库，
/// 由 `fushi/tool/gen_i18n.dart`（slang + dart format，带戳记）从 17 份 i18n json 生成。
/// 文件没了以后，漏接生成的那条路径会在 analyze / test / build 时成片报
/// `strings.g.dart` 找不到——而且只在那条路径（某个 CI job、dist worker、新 worktree）上红。
/// 这里钉死：文件不被跟踪且被忽略；本地 bootstrap（ps1 / sh / melos 钩子）、dist worker
/// 的 prepare、以及每个在 fushi/ 解析 workspace 或跑 app 的 Flutter 命令的 workflow job
/// 都在 pub get 之后、第一条 analyze / test / build 之前调了生成入口。
void main() {
  const String genScript = 'fushi/tool/gen_i18n.dart';
  const String genAction = 'uses: ./.github/actions/gen-i18n';
  final RegExp genActionLine = RegExp(
    r'^\s*uses: \./\.github/actions/gen-i18n\s*$',
    multiLine: true,
  );

  /// 在 fushi/ 解析 workspace（后面才有东西可编）。
  final RegExp flutterPubGet = RegExp(r'flutter (?:-\S+ +)*pub get\b');

  /// 编 app 的 Flutter 命令：analyze / test / drive / 任意 build，以及包着 flutter test 的执行器。
  final RegExp appFlutterRun = RegExp(
    r'flutter (?:-\S+ +)*(?:analyze|test|drive|build)\b|'
    r'flutter_test_failures\.dart|comprehensive_test_runner\.dart',
  );

  String stripComments(String text) => text
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('#'))
      .join('\n');

  /// workflow 里每个 job 的源码（剥注释后）。
  Map<String, String> jobsOf(String workflow) {
    final List<String> lines = stripComments(
      workflow.replaceAll('\r\n', '\n'),
    ).split('\n');
    final int start = lines.indexWhere((String l) => l.startsWith('jobs:'));
    final Map<String, String> out = <String, String>{};
    if (start < 0) return out;
    final RegExp head = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
    String? name;
    final StringBuffer body = StringBuffer();
    for (final String l in lines.skip(start + 1)) {
      final RegExpMatch? m = head.firstMatch(l);
      if (m != null) {
        if (name != null) out[name] = body.toString();
        name = m.group(1);
        body.clear();
      }
      body.writeln(l);
    }
    if (name != null) out[name] = body.toString();
    return out;
  }

  String read(String repoPath) =>
      File('../$repoPath').readAsStringSync().replaceAll('\r\n', '\n');

  test('strings.g.dart 不被 git 跟踪，且被 .gitignore 忽略', () {
    final ProcessResult tracked = Process.runSync('git', <String>[
      'ls-files',
      '--',
      'lib/i18n/strings.g.dart',
    ]);
    expect(tracked.exitCode, 0, reason: '${tracked.stderr}');
    expect(
      (tracked.stdout as String).trim(),
      isEmpty,
      reason:
          'strings.g.dart 又被提交了：它由 tool/gen_i18n.dart 生成，'
          '`git rm --cached fushi/lib/i18n/strings.g.dart`',
    );
    final ProcessResult ignored = Process.runSync('git', <String>[
      'check-ignore',
      '-q',
      '--no-index',
      'lib/i18n/strings.g.dart',
    ]);
    expect(
      ignored.exitCode,
      0,
      reason: 'fushi/.gitignore 必须忽略 /lib/i18n/strings.g.dart',
    );
  });

  test('生成入口跑 slang + dart format，带戳记', () {
    final String gen = read(genScript);
    expect(gen, contains("<String>['run', 'slang']"));
    expect(gen, contains("<String>['format', _output]"));
    expect(gen, contains("'lib/i18n/strings.g.dart'"));
    final String action = read('.github/actions/gen-i18n/action.yml');
    expect(stripComments(action), contains(genScript));
  });

  /// [text] 里 [first] 出现在 [gen] 之前、[gen] 出现在 [last] 之前（[last] 可缺省）。
  void expectOrdered(
    String where,
    String text, {
    required Pattern first,
    required Pattern gen,
    Pattern? last,
  }) {
    final int a = text.indexOf(first);
    final int g = text.indexOf(gen);
    expect(a, greaterThanOrEqualTo(0), reason: '$where 找不到 $first');
    expect(g, greaterThan(a), reason: '$where 必须在 $first 之后调 $genScript');
    if (last != null) {
      final int z = text.indexOf(last);
      expect(z, greaterThan(g), reason: '$where 必须在 $last 之前调 $genScript');
    }
  }

  test('本地 bootstrap（ps1 / sh / melos 钩子）在打补丁后生成', () {
    expectOrdered(
      'tool/bootstrap.ps1',
      stripComments(read('tool/bootstrap.ps1')),
      first: 'ci/apply-patches.sh',
      gen: genScript,
      last: 'native_libs.ps1',
    );
    expectOrdered(
      'tool/bootstrap.sh',
      stripComments(read('tool/bootstrap.sh')),
      first: 'bash ci/apply-patches.sh',
      gen: genScript,
    );
    final String pubspec = stripComments(read('pubspec.yaml'));
    final int post = pubspec.indexOf('post: |');
    expect(post, greaterThanOrEqualTo(0), reason: 'melos bootstrap post 钩子没了');
    expectOrdered(
      'pubspec.yaml melos bootstrap post 钩子',
      pubspec.substring(post),
      first: 'bash ci/apply-patches.sh',
      gen: genScript,
    );
  });

  test('dist worker 的 prepare 每次都生成，且在 Windows 提前退出与预热测试之前', () {
    final String prepare = stripComments(
      read('fushi/tool/dist_test/worker_prepare.sh'),
    );
    expectOrdered(
      'worker_prepare.sh',
      prepare,
      first: 'bash ci/apply-patches.sh',
      gen: genScript,
      last: r'case "$(uname -s)" in',
    );
    expectOrdered(
      'worker_prepare.sh',
      prepare,
      first: 'bash ci/apply-patches.sh',
      gen: genScript,
      last: 'flutter test --no-pub',
    );
    // 不能只在依赖变了的分支里生成：`git clean` 不带 -x，上一个快照的生成物会留下来。
    final int gen = prepare.indexOf(genScript);
    final int elseBranch = prepare.indexOf('dependencies unchanged');
    final int fi = prepare.indexOf('\nfi\n', elseBranch);
    expect(
      gen,
      greaterThan(fi),
      reason: '生成必须在 pub.key 判断的 if/else 之外，每次 prepare 都跑',
    );
  });

  test('每个在 fushi/ 解析 workspace 或编 app 的 workflow job 都先生成', () {
    final Directory dir = Directory('../.github/workflows');
    final List<File> workflows =
        dir
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    final List<String> covered = <String>[];
    final List<String> problems = <String>[];
    for (final File wf in workflows) {
      final String name = wf.uri.pathSegments.last;
      final Map<String, String> jobs = jobsOf(wf.readAsStringSync());
      for (final MapEntry<String, String> job in jobs.entries) {
        // 报错文案里提到 `flutter build ipa` 的 echo 不是命令（release-desktop.yml 的
        // testflight job 只下载已签名的 IPA，不编 app）。
        final String body = job.value
            .split('\n')
            .where((String l) => !l.trimLeft().startsWith('echo '))
            .join('\n');
        final RegExpMatch? pub = flutterPubGet.firstMatch(body);
        final RegExpMatch? run = appFlutterRun.firstMatch(body);
        if (pub == null && run == null) continue;
        final String where = '$name: ${job.key}';
        covered.add(where);
        final int gen = body.indexOf(genActionLine);
        if (gen < 0) {
          problems.add('$where 没有 $genAction');
          continue;
        }
        if (pub == null || gen < pub.start) {
          problems.add('$where 的 gen-i18n 必须在 flutter pub get 之后');
        }
        if (run != null && run.start < gen) {
          problems.add('$where 的 gen-i18n 必须在 `${run.group(0)}` 之前');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
    // 规模哨兵：枚举写错会让本守卫一个 job 都不查。2026-11-01 实测 18 个 job。
    expect(
      covered.length,
      greaterThanOrEqualTo(15),
      reason: '只枚举到 ${covered.length} 个 job：\n${covered.join('\n')}',
    );
  });
}
