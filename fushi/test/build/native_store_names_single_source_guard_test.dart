import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：原生产物持久库（`.github/actions/native-artifact-store`）的名字只有一种算法，
/// 且 PR 门读的每一份件在可信 ref（develop）上都有生产方。
///
/// 持久库按**名字精确匹配**取件，只信 develop / main 的 run。两类失效都是静默的：
///
/// * 生产方和消费方各算一遍名字，一边多哈希一个目录 / 少一个工具链钉版，两边就永远
///   对不上——PR 照常冷编、全绿，只是持久库形同虚设；反过来少哈希一个输入，则会把
///   旧输入编出的件喂给新源码。所以名字只许由 `.github/actions/native-store-names`
///   （`names.sh`）算，workflow 里不得再内联拼名字。
/// * build-multiplatform.yml 在 develop push 上不跑，它读的件若没有别的 workflow 在
///   develop 上存，每条新 PR 首跑都 miss（2026-09-30 的「信任缺口」）。所以 PR 门
///   restore 的每个（平台, 件）都必须由 release-desktop.yml 或 native-cache-warm.yml
///   在**同一种 runner、同样的 CC/CXX** 下 save。
///
/// 按行解析（同 workflow_job_timeout_guard_test.dart，不引入 package:yaml）：`jobs:`
/// 下两格缩进是 job，六格缩进的 `- ` 是 step。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');
  final File namesScript = File(
    '../.github/actions/native-store-names/names.sh',
  );
  final File namesAction = File(
    '../.github/actions/native-store-names/action.yml',
  );

  final Map<String, List<_Job>> jobsByWorkflow = <String, List<_Job>>{};
  if (workflowsDir.existsSync()) {
    for (final File f in workflowsDir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.yml') && !f.path.endsWith('.yaml')) continue;
      final String name = f.uri.pathSegments.last;
      jobsByWorkflow[name] = _parseJobs(name, f.readAsStringSync());
    }
  }
  final List<_Job> allJobs = jobsByWorkflow.values
      .expand((List<_Job> j) => j)
      .toList();
  final List<_Job> storeJobs = allJobs
      .where((_Job j) => j.storeSteps.isNotEmpty)
      .toList();

  test('前置：脚本、action 与持久库步骤都扫到了（守卫没跑空）', () {
    expect(namesScript.existsSync(), isTrue, reason: namesScript.path);
    expect(namesAction.existsSync(), isTrue, reason: namesAction.path);
    final int steps = storeJobs.fold<int>(
      0,
      (int n, _Job j) => n + j.storeSteps.length,
    );
    expect(
      steps,
      greaterThanOrEqualTo(30),
      reason: '只扫到 $steps 个 native-artifact-store 步骤；按行解析失效了？',
    );
    for (final String wf in <String>[
      'build-multiplatform.yml',
      'release-desktop.yml',
      'native-cache-warm.yml',
    ]) {
      expect(
        (jobsByWorkflow[wf] ?? <_Job>[]).any(
          (_Job j) => j.storeSteps.isNotEmpty,
        ),
        isTrue,
        reason: '$wf 里一个持久库步骤都没扫到',
      );
    }
  });

  test('持久库步骤的 name 一律取自 native-store-names 的输出', () {
    final List<String> offenders = <String>[];
    for (final _Job job in storeJobs) {
      for (final _StoreStep s in job.storeSteps) {
        if (s.key == null) {
          offenders.add('${job.where}：${s.rawName}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '持久库名字必须是 `\${{ steps.native_store.outputs.<key> }}`，'
          '不许在 workflow 里内联拼：\n${offenders.join('\n')}',
    );
  });

  test('每个用持久库的 job 都由 native-store-names action 算名字（不内联）', () {
    final List<String> offenders = <String>[];
    for (final _Job job in storeJobs) {
      final List<_Step> resolvers = job.steps
          .where((_Step s) => s.id == 'native_store')
          .toList();
      if (resolvers.length != 1) {
        offenders.add(
          '${job.where}：id: native_store 的步骤有 ${resolvers.length} 个',
        );
        continue;
      }
      final _Step r = resolvers.single;
      if (!r.text.contains('uses: ./.github/actions/native-store-names') ||
          job.platform == null) {
        offenders.add(
          '${job.where}：native_store 步骤没有 uses '
          './.github/actions/native-store-names + platform',
        );
      }
    }
    // 任何地方都不许再有别的「native_store」式内联计算。
    for (final _Job job in allJobs) {
      for (final _Step s in job.steps) {
        if (s.id == 'native_store' &&
            !s.text.contains('uses: ./.github/actions/native-store-names')) {
          offenders.add('${job.where}：内联计算的 native_store 步骤');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('用到的每个 key 都由 names.sh 在对应平台分支里产出', () {
    final String script = namesScript.readAsStringSync();
    final List<String> offenders = <String>[];
    for (final _Job job in storeJobs) {
      final String? platform = job.platform;
      if (platform == null) continue;
      final String? branch = _caseBranch(script, platform);
      if (branch == null) {
        offenders.add('${job.where}：names.sh 没有 `$platform)` 分支');
        continue;
      }
      for (final _StoreStep s in job.storeSteps) {
        final String? key = s.key;
        if (key == null) continue;
        if (!branch.contains('"$key=')) {
          offenders.add(
            '${job.where}：key `$key` 不在 names.sh 的 $platform 分支里'
            '（输出会是空串，restore 永远 miss）',
          );
        }
      }
    }
    final String action = namesAction.readAsStringSync();
    for (final String key in _allKeys(storeJobs)) {
      if (!RegExp('^  $key:\\s*\$', multiLine: true).hasMatch(action)) {
        offenders.add('action.yml 没声明输出 `$key`');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('名字哈希不吃 Markdown：改 README 不得让各端原生件全部重编', () {
    final String script = namesScript.readAsStringSync();
    expect(
      script,
      contains(
        r"git ls-tree -r --full-tree HEAD -- "
        '"\$@"'
        r" | grep -viE '\.md$'",
      ),
      reason:
          'tree_hash 必须在哈希前滤掉 .md（2026-10-07 一次 README 改动让四端 libtorrent 冷编）',
    );
  });

  test('fushi_p2p 的 Rust 钉版只在 names.sh 一处（进名字的哈希）', () {
    final List<String> offenders = <String>[];
    for (final _Job job in storeJobs) {
      for (final _Step s in job.steps) {
        if (!s.text.contains('uses: dtolnay/rust-toolchain')) continue;
        if (!s.text.contains(
          r'toolchain: ${{ steps.native_store.outputs.p2p_rust }}',
        )) {
          offenders.add('${job.where}：${s.firstLine}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '用持久库的 job 里，Rust 工具链必须读 native_store.outputs.p2p_rust：'
          '写死的钉版改了不会让名字变，旧工具链编的件会被当成新的复用。\n'
          '${offenders.join('\n')}',
    );
  });

  test('save 只在 restore 未命中之后发生（同 job、同 key）', () {
    final List<String> offenders = <String>[];
    for (final _Job job in storeJobs) {
      final Map<String, String> restoreIdByKey = <String, String>{};
      for (final _StoreStep s in job.storeSteps) {
        final String? key = s.key;
        if (key == null) continue;
        if (s.mode == 'restore') {
          if (s.step.id == null) {
            offenders.add('${job.where}：restore `$key` 没有 id，save 无从判断命中');
          } else {
            restoreIdByKey[key] = s.step.id!;
          }
        } else if (s.mode == 'save') {
          final String? rid = restoreIdByKey[key];
          if (rid == null) {
            offenders.add('${job.where}：save `$key` 之前没有同 key 的 restore');
            continue;
          }
          if (!s.step.text.contains("steps.$rid.outputs.hit != 'true'")) {
            offenders.add(
              '${job.where}：save `$key` 没挂 '
              "`if: steps.$rid.outputs.hit != 'true'`",
            );
          }
        } else {
          offenders.add('${job.where}：未知 mode ${s.mode}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('PR 门读的每份件都在 develop 上有同环境的生产方（信任缺口）', () {
    final List<_Job> producers = <_Job>[
      ...?jobsByWorkflow['release-desktop.yml'],
      ...?jobsByWorkflow['native-cache-warm.yml'],
    ];
    final List<String> offenders = <String>[];
    int checked = 0;
    for (final _Job consumer
        in jobsByWorkflow['build-multiplatform.yml'] ?? <_Job>[]) {
      for (final _StoreStep s in consumer.storeSteps) {
        if (s.mode != 'restore' || s.key == null) continue;
        checked++;
        final bool produced = producers.any(
          (_Job p) =>
              p.platform == consumer.platform &&
              p.runsOn == consumer.runsOn &&
              p.compilerEnv == consumer.compilerEnv &&
              p.storeSteps.any(
                (_StoreStep ps) => ps.mode == 'save' && ps.key == s.key,
              ),
        );
        if (!produced) {
          offenders.add(
            '${consumer.where}：(${consumer.platform}, ${s.key}) '
            'runs-on=${consumer.runsOn} env=${consumer.compilerEnv}',
          );
        }
      }
    }
    expect(
      checked,
      greaterThanOrEqualTo(8),
      reason: 'build-multiplatform.yml 只扫到 $checked 个 restore',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '这些 PR 门读的件在 develop 上没有生产方（或生产方的 runner / CC/CXX '
          '与消费方不同，名字对不上）：每条新 PR 首跑都会冷编。在 '
          'native-cache-warm.yml 里补上同环境的 restore→build→verify→save：\n'
          '${offenders.join('\n')}',
    );
  });

  test('native-cache-warm 在 develop push 上跑，且路径覆盖所有名字输入', () {
    final String warm = File(
      '${workflowsDir.path}/native-cache-warm.yml',
    ).readAsStringSync();
    expect(warm, contains("branches: ['develop']"));
    expect(
      warm,
      contains('schedule:'),
      reason: '名字带 runner 镜像版本，镜像换代与 push 无关，要靠定时补齐',
    );
    // names.sh 哈希的每个目录 + 基建本身，改了都必须触发预热。
    for (final String path in <String>[
      'native/fushi_torrent/**',
      'native/fushi_p2p/**',
      'native/fushi_anki_sync/**',
      '.github/actions/setup-fushi-anki-sync/**',
      '.github/actions/native-artifact-store/**',
      '.github/actions/native-store-names/**',
    ]) {
      expect(warm, contains("- '$path'"), reason: '缺 push path $path');
    }
  });
}

/// `names.sh` 里 `  <platform>)` 到下一个 `;;` 之间的文本。
String? _caseBranch(String script, String platform) {
  final int start = script.indexOf('\n  $platform)\n');
  if (start == -1) return null;
  final int end = script.indexOf(';;', start);
  return end == -1 ? null : script.substring(start, end);
}

Set<String> _allKeys(List<_Job> jobs) => <String>{
  for (final _Job j in jobs)
    for (final _StoreStep s in j.storeSteps)
      if (s.key != null) s.key!,
  'p2p_rust',
};

final RegExp _jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
// 步骤列表项可能是四格（release.yml）也可能是六格（其余 workflow）起头；只认六格时
// release.yml 的持久库步骤整个看不见，守卫对它形同虚设（2026-09-30 实测）。
final RegExp _stepStart = RegExp(r'^( {4}| {6})- ');
final RegExp _storeName = RegExp(
  r'^\$\{\{ steps\.native_store\.outputs\.([a-z0-9_]+) \}\}$',
);

List<_Job> _parseJobs(String workflow, String yaml) {
  final List<String> lines = yaml.replaceAll('\r\n', '\n').split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  if (jobsAt == -1) return <_Job>[];
  final List<_Job> jobs = <_Job>[];
  _Job? job;
  List<String>? step;
  int stepIndent = 6;
  void closeStep() {
    final _Job? j = job;
    final List<String>? s = step;
    if (j != null && s != null) j.steps.add(_Step(s));
    step = null;
  }

  for (int i = jobsAt + 1; i < lines.length; i++) {
    final String line = lines[i];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      break;
    }
    final RegExpMatch? m = _jobHeader.firstMatch(line);
    if (m != null) {
      closeStep();
      job = _Job(workflow, m.group(1)!);
      jobs.add(job);
      continue;
    }
    final _Job? current = job;
    if (current == null) continue;
    final RegExpMatch? stepMatch = _stepStart.firstMatch(line);
    if (stepMatch != null) {
      closeStep();
      stepIndent = stepMatch.group(1)!.length;
      step = <String>[line];
      continue;
    }
    if (step != null) {
      // step 体比列表项多缩进两格及以上（或空行 / 注释）；回到 job 级就收尾。
      if (line.startsWith(' ' * (stepIndent + 2)) || line.trim().isEmpty) {
        step!.add(line);
        continue;
      }
      if (line.trimLeft().startsWith('#')) continue;
      closeStep();
    }
    current.jobLines.add(line);
  }
  closeStep();
  return jobs;
}

class _Job {
  _Job(this.workflow, this.name);

  final String workflow;
  final String name;
  final List<String> jobLines = <String>[];
  final List<_Step> steps = <_Step>[];

  String get where => '$workflow#$name';

  String? get runsOn {
    for (final String l in jobLines) {
      final RegExpMatch? m = RegExp(r'^    runs-on:\s*(.+)$').firstMatch(l);
      if (m != null) return m.group(1)!.trim();
    }
    return null;
  }

  /// job 级 env 里的 CC / CXX（它们进了名字的哈希，生产方与消费方必须一致）。
  String get compilerEnv {
    final List<String> vars = <String>[];
    bool inEnv = false;
    for (final String l in jobLines) {
      if (l == '    env:') {
        inEnv = true;
        continue;
      }
      if (inEnv) {
        final RegExpMatch? m = RegExp(
          r'^      (CC|CXX):\s*(.+)$',
        ).firstMatch(l);
        if (m != null) vars.add('${m.group(1)}=${m.group(2)!.trim()}');
        if (l.startsWith('    ') && !l.startsWith('      ')) inEnv = false;
      }
    }
    vars.sort();
    return vars.join(' ');
  }

  String? get platform {
    for (final _Step s in steps) {
      if (s.id != 'native_store') continue;
      final RegExpMatch? m = RegExp(
        r'^\s+platform:\s*(\w+)\s*$',
        multiLine: true,
      ).firstMatch(s.text);
      return m?.group(1);
    }
    return null;
  }

  List<_StoreStep> get storeSteps => <_StoreStep>[
    for (final _Step s in steps)
      if (s.text.contains('uses: ./.github/actions/native-artifact-store'))
        _StoreStep(s),
  ];
}

class _Step {
  _Step(this.lines);

  final List<String> lines;

  String get text => lines.join('\n');

  String get firstLine => lines.first.trim();

  String? get id {
    for (final String l in lines) {
      final RegExpMatch? m = RegExp(
        r'^\s+(?:- )?id:\s*(\S+)\s*$',
      ).firstMatch(l);
      if (m != null) return m.group(1);
    }
    return null;
  }
}

class _StoreStep {
  _StoreStep(this.step);

  final _Step step;

  /// `with:` 下的 `name:`。step 自己的名字在首行 `- name:` 上，所以跳过首行；缩进随
  /// workflow 不同（release.yml 八格、其余十格），不按固定缩进认。
  String get rawName {
    for (final String l in step.lines.skip(1)) {
      final RegExpMatch? m = RegExp(r'^\s+name:\s*(.+)$').firstMatch(l);
      if (m != null) return m.group(1)!.trim();
    }
    return '<no name>';
  }

  String? get key => _storeName.firstMatch(rawName)?.group(1);

  String? get mode {
    for (final String l in step.lines) {
      final RegExpMatch? m = RegExp(r'^\s+mode:\s*(\w+)\s*$').firstMatch(l);
      if (m != null) return m.group(1);
    }
    return null;
  }
}
