import 'dart:io';

import 'package:test/test.dart';

/// PR 主门分层（.github/workflows/main.yml 的 plan job）：PR 上默认只跑快门
/// （analyze + 受影响测试），全量按需 / 合并后跑。这里钉住让这个取舍成立的几条不变量。
void main() {
  late String mainWorkflow;
  late String releaseWorkflow;

  setUpAll(() {
    mainWorkflow = File('../.github/workflows/main.yml').readAsStringSync();
    releaseWorkflow = File(
      '../.github/workflows/release.yml',
    ).readAsStringSync();
  });

  /// `  <name>:` 开头到下一个顶层 job 之间的文本。
  String job(String name) {
    final int start = mainWorkflow.indexOf('\n  $name:\n');
    expect(start, greaterThanOrEqualTo(0), reason: 'main.yml 缺少 job $name');
    final Match? next = RegExp(
      r'\n  [a-z][a-z0-9-]*:\n',
    ).firstMatch(mainWorkflow.substring(start + 1));
    return next == null
        ? mainWorkflow.substring(start)
        : mainWorkflow.substring(start, start + 1 + next.start);
  }

  /// [text] 里 `pattern='^(...)'` 的各个备选分支。
  List<String> alternatives(String text) {
    final Match? m = RegExp(r"pattern='\^\((.+)\)'").firstMatch(text);
    expect(m, isNotNull, reason: '找不到 pattern= 行');
    // 只在顶层的 | 处切：`(json|py)` 这种分组里的不算。
    final List<String> out = <String>[];
    final StringBuffer cur = StringBuffer();
    int depth = 0;
    for (final String ch in m!.group(1)!.split('')) {
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == '|' && depth == 0) {
        out.add(cur.toString());
        cur.clear();
      } else {
        cur.write(ch);
      }
    }
    out.add(cur.toString());
    return out;
  }

  test('全量与快门互斥：unit-tests 只在 full 时跑，affected-tests 只在非 full 时跑', () {
    expect(
      job('unit-tests'),
      contains("if: needs.plan.outputs.full == 'true'"),
    );
    expect(
      job('affected-tests'),
      contains("if: needs.plan.outputs.full != 'true'"),
    );
    for (final String name in <String>['unit-tests', 'affected-tests']) {
      expect(job(name), contains('needs: [plan, '), reason: name);
    }
  });

  test('plan 判不出来时一律跑全量（fail safe）', () {
    final String plan = job('plan');
    // 非 PR 事件、进 main、fork、标签、清单取不到 / 为空 / 可能被截断。
    for (final String guard in <String>[
      r'[ "$EVENT_NAME" = "pull_request" ] || full ',
      r'[ "$BASE_REF" = "develop" ] || full ',
      r'[ "$IS_FORK" != "true" ] || full ',
      r'[ "$HAS_FULL_LABEL" != "true" ] || full ',
      'full "could not list the changed files of this PR"',
      r'[ -n "$changed" ] || full ',
      '-lt 3000 ] || full ',
    ]) {
      expect(plan, contains(guard));
    }
    // full() 同时打开包测试：R8 / JVM 校验要的 Android .so 由那几步编。
    final String fullFn = plan.substring(
      plan.indexOf('full() {'),
      plan.indexOf('exit 0'),
    );
    expect(fullFn, contains('echo "full=true"'));
    expect(fullFn, contains('echo "packages=true"'));
  });

  test('plan 的全量 pattern 是 R8 门 pattern 的超集', () {
    // build job 的 R8 / JVM 步骤按 steps.r8 的 pattern 决定跑不跑，而它们要的原生库只在
    // packages == true 时编；R8 门命中却没判全量，这两步会因缺库失败。
    final List<String> plan = alternatives(job('plan'));
    final List<String> r8 = alternatives(job('build'));
    expect(r8.length, greaterThanOrEqualTo(8), reason: 'R8 pattern 解析塌了');
    for (final String alt in r8) {
      expect(plan, contains(alt), reason: 'plan pattern 缺 R8 门的分支 $alt');
    }
    // 选测看不见影响面的测试基础设施：改了就全量。
    for (final String alt in <String>[
      'fushi/tool/',
      r'fushi/dart_test\.yaml$',
      r'fushi/test/flutter_test_config\.dart$',
      r'docs/agent/fast-workflow\.md$',
    ]) {
      expect(plan, contains(alt));
    }
  });

  test('包测试及其原生库步骤在 packages 没改动时跳过，改了就跑', () {
    final String build = job('build');
    const String gate = "if: needs.plan.outputs.packages == 'true'";
    for (final String step in <String>[
      'Build fushi_fsrs (Linux x64, id_audit + raw_sql) for package tests',
      'Build fushi_compute (Linux .so + Android arm64-v8a)',
      'Build fushi_rwkv (Linux .so + Android arm64-v8a)',
      'Build fushi_music (Linux .so + Android arm64-v8a)',
      'Build fushi_corpus (Linux .so + Android arm64-v8a)',
      'Run package tests',
    ]) {
      final int at = build.indexOf('- name: $step\n');
      expect(at, greaterThanOrEqualTo(0), reason: 'build job 缺步骤 $step');
      final String head = build.substring(at).split('\n').take(2).join('\n');
      expect(head, contains(gate), reason: '$step 没挂 packages 门');
    }
    expect(job('plan'), contains("grep -qE '^packages/'"));
    // analyze 与 JS 测试不挂门：每个 PR 都跑。
    final int analyze = build.indexOf('- name: Run dart analyze\n');
    expect(analyze, greaterThanOrEqualTo(0));
    expect(
      build.substring(analyze).split('\n').take(3).join('\n'),
      isNot(contains('if:')),
    );
  });

  test('快门用本地预检同一份选测，且放开 hub 上限', () {
    final String affected = job('affected-tests');
    final String line = affected
        .split('\n')
        .firstWhere(
          (String l) => l.contains('tool/pre_push_check.dart'),
          orElse: () => '',
        );
    for (final String flag in <String>[
      '--gate=0',
      '--skip-analyze',
      '--app-tests-only',
      '--hub-limit=1000000',
      '--files-from=',
    ]) {
      expect(line, contains(flag));
    }
    // --wide / --quick 会换掉选测规则；--list 只列不跑。
    for (final String flag in <String>['--wide', '--quick', '--list']) {
      expect(line, isNot(contains(flag)));
    }
    final String tool = File('tool/pre_push_check.dart').readAsStringSync();
    expect(tool, contains("args.contains('--app-tests-only')"));
  });

  test('Flutter GPU 测试只在相关改动时跑（拍板 pr4211-ci-mesa=b），全量 / 快门各挂一处', () {
    // 每次都 apt 装 mesa 跑 lavapipe 只增加开销与外部软件源依赖；但相关改动时必须真跑，
    // 全量模式（改 pubspec / 本 workflow 等）下 affected-tests 不跑，所以第 0 片那一步也要挂同一个门。
    final String plan = job('plan');
    expect(plan, contains(r'gpu: ${{ steps.gpu.outputs.run }}'));
    expect(plan, contains('id: gpu\n'));
    for (final String guard in <String>[
      r'[ "$EVENT_NAME" = "pull_request" ] || run true ',
      'run true "could not list the changed files of this PR"',
      r'[ -n "$changed" ] || run true ',
      '-lt 3000 ] || run true ',
    ]) {
      expect(plan, contains(guard), reason: 'gpu 判定缺 fail safe：$guard');
    }
    for (final String alt in <String>[
      'shaders/',
      'hook/',
      'lib/src/media/music/lyrics/visualizer/',
      'test/media/music/visualizer/',
      r'pubspec\.lock$',
      r'\.github/workflows/main\.yml$',
    ]) {
      expect(plan, contains(alt), reason: 'gpu 判定缺路径 $alt');
    }
    const String gate = "needs.plan.outputs.gpu == 'true'";
    final Map<String, String> steps = <String, String>{
      'unit-tests': 'Flutter GPU tests',
      'affected-tests': 'Flutter GPU tests (when GPU rendering changed)',
    };
    steps.forEach((String jobName, String step) {
      final String body = job(jobName);
      final int at = body.indexOf('- name: $step\n');
      expect(at, greaterThanOrEqualTo(0), reason: '$jobName 缺步骤 $step');
      final String head = body.substring(at).split('\n').take(2).join('\n');
      expect(head, contains(gate), reason: '$jobName 的 $step 没挂 gpu 门');
    });
    // mesa 只在这两步里装：别处再出现就是又加回了无条件的那一步。
    expect(
      'mesa-vulkan-drivers'.allMatches(mainWorkflow).length,
      2,
      reason: 'mesa 安装只应出现在两个挂了 gpu 门的步骤里',
    );
  });

  test('合并后的全量兜底还在：release.yml 在 develop 的 push 上跑 4 片单测', () {
    // 快门选不到只经传递依赖受影响的测试；这条兜底没了，分层就是在裸奔。
    final String on = releaseWorkflow.substring(
      releaseWorkflow.indexOf('\non:\n'),
      releaseWorkflow.indexOf('\nconcurrency:\n'),
    );
    expect(on, contains('  push:\n'));
    expect(on, contains("branches: ['main', 'develop']"));
    expect(
      releaseWorkflow,
      contains(
        'dart run tool/flutter_test_failures.dart '
        r'--file-shard=${{ matrix.part }}/4',
      ),
    );
  });
}
