import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：`fushi/lib/i18n/strings.g.dart` 不入库，凡是要编 app 的地方都先生成它。
///
/// 这份 Slang 生成文件 37 MB、两千多个版本（历史约 676 MB），2026-11 起不再入库，
/// 由 `fushi/tool/gen_i18n.dart`（slang + dart format，带戳记）从 17 份 i18n json 生成。
/// 文件没了以后，漏接生成的那条路径会在 analyze / test / build 时成片报
/// `strings.g.dart` 找不到——而且只在那条路径（某个 CI job、dist worker、新 worktree）上红。
/// 这里钉死：文件不被跟踪且被忽略；本地 bootstrap（ps1 / sh / melos 钩子）、dist worker
/// 的 prepare、本地重活入口 `fushi/tool/heavy.dart`、`tool/setup_worktree.ps1`、git
/// post-checkout / post-merge 钩子，以及每个编 app 或在 fushi/ 下跑
/// `flutter|dart analyze|test|run` 的 workflow job 都在 pub get 之后、第一条这类命令之前
/// 调了生成入口；不编 app 的 job（无头服务端：fushi_server 的依赖闭包不含 package:fushi）
/// 不调——尤其 release-server.yml 是带 source_ref 的 workflow_call，可能检出还没有这个
/// action 的旧提交，不能引用它。
void main() {
  const String genScript = 'fushi/tool/gen_i18n.dart';
  const String genAction = 'uses: ./.github/actions/gen-i18n';

  String stripComments(String text) => text
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('#'))
      .join('\n');

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

  test('解析器自检：echo 段、cd / working-directory、非 fushi/ 目录', () {
    const String wf = r'''
jobs:
  echo_then_test:
    runs-on: x
    steps:
      - name: t
        working-directory: fushi
        run: echo "::group::flutter build ipa && x" && flutter test --no-pub
  echo_only:
    runs-on: x
    steps:
      - run: |
          echo "run flutter build ipa first; then flutter analyze"
          printf '%s\n' "dart test"
  server_pkg:
    runs-on: x
    steps:
      - working-directory: packages/fushi_server
        run: |
          dart analyze
          dart ../../fushi/tool/flutter_test_failures.dart
      - run: (cd packages/fushi_dictionary && flutter test x_test.dart) 2>&1 | tee log
      - run: dart build cli --target packages/fushi_server/bin/fushi_server.dart
  cd_into_fushi:
    runs-on: x
    steps:
    - run: cd fushi && dart run build_runner build
  pwsh_location:
    runs-on: x
    steps:
      - shell: pwsh
        run: |
          Set-Location "${{ github.workspace }}/fushi"; dart analyze lib
  emulator:
    runs-on: x
    steps:
      - uses: reactivecircus/android-emulator-runner@v2
        with:
          script: bash ci/comprehensive-test.sh --platform=android
''';
    final Map<String, _JobI18n> got = _analyzeWorkflow(wf);
    expect(got['echo_then_test']!.needs?.text, startsWith('flutter test'));
    expect(got['echo_only']!.needs, isNull);
    expect(got['server_pkg']!.needs, isNull);
    expect(got['cd_into_fushi']!.needs?.cwd, 'fushi');
    expect(got['pwsh_location']!.needs?.cwd, 'fushi');
    expect(got['emulator']!.needs, isNotNull);
  });

  test('编 app / 在 fushi/ 跑 analyze|test|run 的 job 都先生成；其余 job 不生成', () {
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
      final Map<String, _JobI18n> jobs = _analyzeWorkflow(
        stripComments(wf.readAsStringSync().replaceAll('\r\n', '\n')),
      );
      for (final MapEntry<String, _JobI18n> job in jobs.entries) {
        final _JobI18n j = job.value;
        final String where = '$name: ${job.key}';
        final _Cmd? needs = j.needs;
        final int? gen = j.genStep;
        if (needs == null) {
          if (gen != null) {
            problems.add(
              '$where 不编 app、也不在 fushi/ 跑 analyze/test/run，却调了 gen-i18n'
              '（白跑一步；workflow_call 检出旧 ref 时还会找不到这个 action）',
            );
          }
          continue;
        }
        covered.add('$where  <- `${needs.text}` @ ${needs.cwd}');
        if (gen == null) {
          problems.add(
            '$where 没有 $genAction（`${needs.text}` 需要 strings.g.dart）',
          );
          continue;
        }
        final int? pub = j.pubGetStep;
        if (pub == null || gen < pub) {
          problems.add('$where 的 gen-i18n 必须在 flutter pub get 之后');
        }
        if (j.needsStep! <= gen) {
          problems.add('$where 的 gen-i18n 必须在 `${needs.text}` 之前');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
    // 规模哨兵：解析写错会让本守卫一个 job 都不查。
    expect(
      covered.length,
      greaterThanOrEqualTo(12),
      reason: '只枚举到 ${covered.length} 个 job：\n${covered.join('\n')}',
    );
  });

  test('release-server.yml（workflow_call + source_ref）不引用 gen-i18n', () {
    final String text = stripComments(
      read('.github/workflows/release-server.yml'),
    );
    expect(
      text,
      isNot(contains('gen-i18n')),
      reason:
          'release-server 被独立发布仓按 source_ref 调用，可能检出没有 '
          '.github/actions/gen-i18n 的旧提交；它只编无头服务端，也不需要 strings.g.dart',
    );
  });
}

/// 一条需要 strings.g.dart 的命令，及其所在目录（相对仓库根，根为 `.`）。
class _Cmd {
  const _Cmd(this.cwd, this.text);
  final String cwd;
  final String text;
}

/// 一个 job 的生成相关事实（下标是 step 序号）。
class _JobI18n {
  int? genStep;
  int? pubGetStep;
  int? needsStep;
  _Cmd? needs;
}

/// 在 fushi/ 下需要 strings.g.dart 的命令：flutter analyze|test|drive|build|run、
/// dart analyze|test|run、包着 flutter test 的执行器、gradle 出包。
final RegExp _underFushiCmd = RegExp(
  r'''(?:^|[\s/"'&])(?:flutter(?:\.bat)?"?\s+(?:-\S+\s+)*(?:analyze|test|drive|build|run)\b'''
  r'''|dart(?:\.bat|\.exe)?"?\s+(?:-\S+\s+)*(?:analyze|test|run)\b'''
  r'''|dart(?:\.bat|\.exe)?"?\s+(?:\S*/)?(?:flutter_test_failures|comprehensive_test_runner)\.dart'''
  r'''|gradlew(?:\.bat)?\s+.*\b(?:assemble|bundle))''',
);

/// 不论在哪个目录调都会编 / 跑 app 的入口脚本（它自己 cd fushi）。
final RegExp _anywhereAppCmd = RegExp(r'ci/comprehensive-test\.sh\b');

final RegExp _pubGet = RegExp(
  r'''(?:^|[\s/"'&])(?:flutter|dart)(?:\.bat|\.exe)?"?\s+(?:-\S+\s+)*pub\s+get\b''',
);

/// 按 step 解析 [workflow]（已剥注释）里的每个 job。
Map<String, _JobI18n> _analyzeWorkflow(String workflow) {
  final List<String> lines = workflow.split('\n');
  final int start = lines.indexWhere((String l) => l.startsWith('jobs:'));
  if (start < 0) return <String, _JobI18n>{};
  final Map<String, List<String>> jobs = <String, List<String>>{};
  final RegExp head = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
  String? name;
  for (final String l in lines.skip(start + 1)) {
    final RegExpMatch? m = head.firstMatch(l);
    if (m != null) {
      name = m.group(1)!;
      jobs[name] = <String>[];
      continue;
    }
    if (name != null) jobs[name]!.add(l);
  }
  return <String, _JobI18n>{
    for (final MapEntry<String, List<String>> j in jobs.entries)
      j.key: _analyzeJob(j.value),
  };
}

int _indentOf(String l) => l.length - l.trimLeft().length;

_JobI18n _analyzeJob(List<String> body) {
  final _JobI18n out = _JobI18n();
  final int stepsAt = body.indexWhere(
    (String l) => RegExp(r'^\s+steps:\s*$').hasMatch(l),
  );
  if (stepsAt < 0) return out;
  // job 级 defaults.run.working-directory。
  String jobCwd = '.';
  for (final String l in body.take(stepsAt)) {
    final RegExpMatch? m = RegExp(
      r'^\s+working-directory:\s*(.+)$',
    ).firstMatch(l);
    if (m != null) jobCwd = _resolveDir('.', m.group(1)!);
  }
  final int stepsIndent = _indentOf(body[stepsAt]);
  int? dash;
  final List<List<String>> steps = <List<String>>[];
  for (final String l in body.skip(stepsAt + 1)) {
    if (l.trim().isEmpty) {
      if (steps.isNotEmpty) steps.last.add(l);
      continue;
    }
    final int ind = _indentOf(l);
    final bool isDash = l.trimLeft().startsWith('- ');
    if (dash == null) {
      if (!isDash) break;
      dash = ind;
    }
    if (ind < stepsIndent || ind < dash || (ind == dash && !isDash)) break;
    if (ind == dash) {
      // `- key: v` → 与同 step 其余键同缩进的 `  key: v`。
      steps.add(<String>['${' ' * (dash + 2)}${l.trimLeft().substring(2)}']);
    } else {
      steps.last.add(l);
    }
  }
  if (dash == null) return out;
  final int keyIndent = dash + 2;
  final RegExp kvLine = RegExp(r'^(\s*)([A-Za-z_-]+):\s*(.*)$');
  for (int i = 0; i < steps.length; i++) {
    final List<String> step = steps[i];
    String cwd = jobCwd;
    final List<String> scripts = <String>[];
    for (int k = 0; k < step.length; k++) {
      final RegExpMatch? kv = kvLine.firstMatch(step[k]);
      if (kv == null) continue;
      final int ind = kv.group(1)!.length;
      final String key = kv.group(2)!;
      final String value = kv.group(3)!.trim();
      if (ind == keyIndent &&
          key == 'uses' &&
          RegExp(r'^\./\.github/actions/gen-i18n/?$').hasMatch(value)) {
        out.genStep ??= i;
      }
      if (ind == keyIndent && key == 'working-directory') {
        cwd = _resolveDir('.', value);
      }
      // run:（step 键）/ script:（android-emulator-runner 的 with 键）。
      if ((ind == keyIndent && key == 'run') ||
          (ind > keyIndent && key == 'script')) {
        if (RegExp(r'^[|>][-+]?$').hasMatch(value)) {
          final StringBuffer b = StringBuffer();
          for (int n = k + 1; n < step.length; n++) {
            final String c = step[n];
            if (c.trim().isNotEmpty && _indentOf(c) <= ind) break;
            b.writeln(c);
          }
          scripts.add(b.toString());
        } else {
          scripts.add(_unquote(value));
        }
      }
    }
    for (final String script in scripts) {
      for (final _Cmd c in _commandsOf(script, cwd)) {
        if (_pubGet.hasMatch(c.text)) {
          if (c.cwd == '.' || _underFushi(c.cwd)) out.pubGetStep ??= i;
          continue;
        }
        final bool needs =
            _anywhereAppCmd.hasMatch(c.text) ||
            (_underFushi(c.cwd) && _underFushiCmd.hasMatch(c.text));
        if (needs && out.needs == null) {
          out.needs = c;
          out.needsStep = i;
        }
      }
    }
  }
  return out;
}

bool _underFushi(String cwd) => cwd == 'fushi' || cwd.startsWith('fushi/');

String _unquote(String s) {
  final String t = s.trim();
  if (t.length >= 2 &&
      ((t.startsWith('"') && t.endsWith('"')) ||
          (t.startsWith("'") && t.endsWith("'")))) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

/// 把 cd / working-directory 的参数 [arg] 解析成相对仓库根的目录。
String _resolveDir(String cwd, String arg) {
  String a = _unquote(arg).replaceAll(r'\', '/');
  bool absolute = false;
  for (final String root in <String>[
    r'${{ github.workspace }}',
    r'${GITHUB_WORKSPACE}',
    r'$GITHUB_WORKSPACE',
    r'$env:GITHUB_WORKSPACE',
  ]) {
    if (a.startsWith(root)) {
      a = a.substring(root.length);
      absolute = true;
    }
  }
  final List<String> parts = <String>[
    if (!absolute && cwd != '.') ...cwd.split('/'),
  ];
  for (final String seg in a.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.isEmpty ? '.' : parts.join('/');
}

/// 把一段 shell / pwsh 脚本拆成命令段（`&&` `||` `;` `|` 处断开，引号内不断），跟踪
/// cd / pushd / Set-Location / Push-Location（行首 `(` 的子 shell 里的 cd 只作用于该行）；
/// echo / printf / Write-Host 段整段丢弃——报错文案里的 `flutter build ipa` 不是命令，
/// 但 `echo ... && flutter test` 的后半段是。
List<_Cmd> _commandsOf(String script, String stepCwd) {
  final List<_Cmd> out = <_Cmd>[];
  final String joined = script
      .replaceAll(RegExp(r'\\\r?\n'), ' ')
      .replaceAll(RegExp(r'`\r?\n'), ' ');
  String cwd = stepCwd;
  final RegExp lead = RegExp(
    r'^(?:[({!]\s*|(?:then|do|else|if|while|until|exec|time)\s+|&\s+)+',
  );
  final RegExp envAssign = RegExp(r'^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+');
  for (final String raw in joined.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final bool subshell = line.startsWith('(');
    String lineCwd = cwd;
    for (final String part in _splitSegments(line)) {
      final String seg = part
          .trim()
          .replaceFirst(lead, '')
          .replaceFirst(envAssign, '');
      if (seg.isEmpty) continue;
      final String first = seg.split(RegExp(r'\s+')).first;
      final String rest = seg.substring(first.length).trim();
      switch (first.toLowerCase()) {
        case 'echo':
        case 'printf':
        case 'write-host':
        case 'write-output':
          continue;
        case 'cd':
        case 'pushd':
        case 'set-location':
        case 'push-location':
          final RegExpMatch? q = RegExp(
            r'''^("[^"]*"|'[^']*')''',
          ).firstMatch(rest);
          final String target =
              (q?.group(1) ?? rest.split(RegExp(r'\s+')).first).replaceAll(
                RegExp(r'[)}]+$'),
                '',
              );
          lineCwd = target.isEmpty || target == '-'
              ? stepCwd
              : _resolveDir(lineCwd, target);
          continue;
        case 'popd':
        case 'pop-location':
          lineCwd = stepCwd;
          continue;
      }
      out.add(_Cmd(lineCwd, seg));
    }
    if (!subshell) cwd = lineCwd;
  }
  return out;
}

List<String> _splitSegments(String line) {
  final List<String> segs = <String>[];
  final StringBuffer b = StringBuffer();
  String? quote;
  for (int i = 0; i < line.length; i++) {
    final String ch = line[i];
    if (quote != null) {
      b.write(ch);
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      b.write(ch);
      continue;
    }
    final bool amp2 = ch == '&' && i + 1 < line.length && line[i + 1] == '&';
    if (ch == ';' || ch == '|' || amp2) {
      segs.add(b.toString());
      b.clear();
      if (i + 1 < line.length && (line[i + 1] == '&' || line[i + 1] == '|')) {
        i++;
      }
      continue;
    }
    b.write(ch);
  }
  segs.add(b.toString());
  return segs;
}
