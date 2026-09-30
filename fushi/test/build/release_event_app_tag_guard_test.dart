import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（BUG-2817）：`release: published` 触发的 workflow，每个会在 release 事件上
/// 跑的 job 都只给**应用 release**（tag = `v<数字>…`）干活。
///
/// 起因：2026-09-21 手动发布模型资产 release `manga-panel-detector-onnx-v1` 时，
/// release.yml / release-desktop.yml 对 tag 不设防，整套 Android / Windows / macOS /
/// iOS 构建全跑了一遍，还把 2.8.0 的安装包和 3 个 APK 挂到了模型 release 上。本仓的
/// 模型与依赖资产 release（`vendor-libmpv`、`voice-hook-helper`、`*-onnx-v1`…）都
/// 是手动发的 `release` 事件，而应用 release 的 tag 一律 `v<语义版本>`。
///
/// GitHub 表达式没有正则，判据只能逐个列 `startsWith(tag, 'v0')` .. `'v9'`——
/// 裸 `startsWith(tag, 'v')` 会把 `vendor-libmpv` / `voice-hook-helper` 放进来。
/// 按行解析而不引入 package:yaml（与 workflow_job_timeout_guard_test 同法）：
/// `jobs:` 下两格缩进的键是 job，四格缩进的 `if:` 属于该 job。
const String _appTagGuard =
    "(github.event_name != 'release' || "
    "startsWith(github.event.release.tag_name, 'v0') || "
    "startsWith(github.event.release.tag_name, 'v1') || "
    "startsWith(github.event.release.tag_name, 'v2') || "
    "startsWith(github.event.release.tag_name, 'v3') || "
    "startsWith(github.event.release.tag_name, 'v4') || "
    "startsWith(github.event.release.tag_name, 'v5') || "
    "startsWith(github.event.release.tag_name, 'v6') || "
    "startsWith(github.event.release.tag_name, 'v7') || "
    "startsWith(github.event.release.tag_name, 'v8') || "
    "startsWith(github.event.release.tag_name, 'v9'))";

/// 只在手动 dispatch 下才跑的 job 本来就碰不到 release 事件。
const String _dispatchOnly = "github.event_name == 'workflow_dispatch' &&";

final RegExp _jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');

/// job 名 → 它的 job 级 `if:` 表达式（没有则为 null）。
Map<String, String?> _jobConditions(String yaml) {
  final List<String> lines = yaml.split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  if (jobsAt == -1) return <String, String?>{};
  final Map<String, String?> jobs = <String, String?>{};
  String? job;
  for (int i = jobsAt + 1; i < lines.length; i++) {
    final String line = lines[i];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      break;
    }
    final RegExpMatch? m = _jobHeader.firstMatch(line);
    if (m != null) {
      job = m.group(1);
      jobs[job!] = null;
      continue;
    }
    if (job != null && line.startsWith('    if:')) {
      jobs[job] = line.substring('    if:'.length).trim();
    }
  }
  return jobs;
}

bool _triggeredByRelease(String yaml) {
  final int onAt = yaml.indexOf('\non:');
  final int jobsAt = yaml.indexOf('\njobs:');
  if (onAt == -1 || jobsAt == -1) return false;
  return RegExp(
    r'^\s{2}release:',
    multiLine: true,
  ).hasMatch(yaml.substring(onAt, jobsAt));
}

/// 不满足守卫的 job。
List<String> _unguardedJobs(String yaml) => <String>[
  for (final MapEntry<String, String?> job in _jobConditions(yaml).entries)
    if (!(job.value?.contains(_appTagGuard) ?? false) &&
        !(job.value?.contains(_dispatchOnly) ?? false))
      job.key,
];

/// 按守卫表达式里列出的前缀判定：这个 tag 的 release 事件会不会跑构建。
bool _runsFor(String guard, String tag) => RegExp(
  r"startsWith\(github\.event\.release\.tag_name, '([^']+)'\)",
).allMatches(guard).any((RegExpMatch m) => tag.startsWith(m.group(1)!));

Directory _workflowsDir() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    final Directory candidate = Directory('${dir.path}/.github/workflows');
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到 .github/workflows（从 ${Directory.current.path} 向上）');
}

void main() {
  test('判据自校验（合成语料）', () {
    const String yaml =
        '''
name: x
on:
  release:
    types: [published]
jobs:
  guarded:
    if: \${{ github.event.inputs.x != 'true' && $_appTagGuard }}
    runs-on: ubuntu-latest
  dispatch:
    if: \${{ github.event_name == 'workflow_dispatch' && github.event.inputs.y == 'true' }}
    runs-on: ubuntu-latest
  bare:
    runs-on: ubuntu-latest
    steps:
      - if: \${{ $_appTagGuard }}
        run: echo step-level guard does not count
  loose:
    if: \${{ github.event_name != 'release' || startsWith(github.event.release.tag_name, 'v') }}
    runs-on: ubuntu-latest
''';
    expect(_triggeredByRelease(yaml), isTrue);
    expect(_unguardedJobs(yaml), <String>['bare', 'loose']);
  });

  test('守卫表达式：应用 tag 放行，模型 / 依赖资产 tag 一律跳过', () {
    for (final String tag in <String>[
      'v0.5.0',
      'v1.0.0',
      'v2.2.4',
      'v2.8.0',
      'v2.9.0-beta.1',
      'v2.9.0-debug.2114+4f77a8c',
      'v10.0.0',
    ]) {
      expect(_runsFor(_appTagGuard, tag), isTrue, reason: tag);
    }
    for (final String tag in <String>[
      'manga-panel-detector-onnx-v1',
      'manga-ocr-kv-onnx-v1',
      'vendor-libmpv',
      'voice-hook-helper',
      'debug-rolling',
      'v',
    ]) {
      expect(_runsFor(_appTagGuard, tag), isFalse, reason: tag);
    }
  });

  test('release 事件触发的 workflow：每个 job 都带应用 tag 守卫', () {
    final List<File> workflows =
        _workflowsDir()
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.yml'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    final List<String> releaseTriggered = <String>[];
    final List<String> offenders = <String>[];
    for (final File file in workflows) {
      final String yaml = file.readAsStringSync().replaceAll('\r\n', '\n');
      if (!_triggeredByRelease(yaml)) continue;
      final String name = file.uri.pathSegments.last;
      releaseTriggered.add(name);
      for (final String job in _unguardedJobs(yaml)) {
        offenders.add('$name › $job');
      }
    }
    // 三条都在：少了一条说明解析失效或 workflow 被改名，守卫会静默变空。
    expect(
      releaseTriggered,
      containsAll(<String>[
        'mirror-releases.yml',
        'release-desktop.yml',
        'release.yml',
      ]),
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '这些 job 在 release 事件上不看 tag：手动发布模型 / 依赖资产 release 时会整套'
          '构建并把安装包挂上去（BUG-2817）。在 job 级 if 里并上 $_appTagGuard',
    );
  });
}
