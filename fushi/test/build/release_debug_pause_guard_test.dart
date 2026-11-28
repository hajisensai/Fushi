import 'dart:io';

import 'package:test/test.dart';

/// 「暂停调试版自动发布」开关（仓库变量 `FUSHI_PAUSE_DEBUG_RELEASE`）的不变式。
///
/// 用途：测试版放出去试用期间，debug 通道不再出包——develop 上的 push 和手动
/// dispatch `channel=debug` 都停（2026-11-28：只停 push 时，有人手动 dispatch
/// debug 照样把滚动 debug 包推给了 debug 通道用户），手动 dispatch 的 beta / formal
/// 与 `release` 事件照常发。这条守卫钉住开关**只**作用于 debug 通道，每一条失守都是真事故：
///
/// 1. 每处引用都是同一个「变量 && (push || dispatch debug)」整体表达式。裸
///    `vars.FUSHI_PAUSE_DEBUG_RELEASE` 会把手动 beta / formal 一起停掉——正好在要发正式版的那天。
/// 2. push 事件在 release.yml 里只解析成 debug 通道，所以挡 push 只挡到 debug。
/// 3. release.yml 只挡 `build` / `publish-android`：`tests` 等 job 是 develop 唯一的
///    app 全量单测门，暂停期间必须照跑。
/// 4. release-desktop.yml 每个 job 都挡，`publish` 带 `always()` 必须自己挡
///    （否则上游全被跳过时它照样起跑、拿空产物去动 rolling release）。
/// 5. 服务端自动发布（tool/server_release_plan.py）用同名变量，只停 debug 候选，
///    formal / beta 候选排在暂停判断之前。
File _repoFile(String path) => File('../$path');

const String _pauseExpr =
    "!(vars.FUSHI_PAUSE_DEBUG_RELEASE == 'true' && (github.event_name == 'push' || github.event.inputs.channel == 'debug'))";
const String _varRef = 'vars.FUSHI_PAUSE_DEBUG_RELEASE';

final RegExp _jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');

/// job 名 → 它的 job 级 `if:` 表达式（没有则为 null）。
Map<String, String?> _jobConditions(String yaml) {
  final List<String> lines = yaml.split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  expect(jobsAt, isNot(-1), reason: '找不到 jobs:');
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

int _count(String haystack, String needle) =>
    needle.allMatches(haystack).length;

void main() {
  test('每处引用都是 debug 限定的整体表达式，不会波及 beta / formal', () {
    for (final String path in <String>[
      '.github/workflows/release.yml',
      '.github/workflows/release-desktop.yml',
    ]) {
      final String yaml = _repoFile(path).readAsStringSync();
      expect(
        _count(yaml, _varRef),
        _count(yaml, _pauseExpr),
        reason:
            '$path 里有不带 debug 限定的 $_varRef 引用：裸变量会把手动 dispatch 的 '
            'beta / formal 与 release 事件一起停掉。每一处都必须写成 $_pauseExpr',
      );
    }
  });

  test('release.yml 的 push 只解析成 debug 通道（停 push = 只停 debug）', () {
    final String yaml = _repoFile(
      '.github/workflows/release.yml',
    ).readAsStringSync();
    final int at = yaml.indexOf('          push)\n');
    expect(at, greaterThan(0), reason: 'channel 解析里找不到 push) 分支');
    final String branch = yaml.substring(at, yaml.indexOf(';;', at));
    expect(
      branch,
      contains('CHANNEL=debug'),
      reason: 'push 事件不再固定是 debug 通道，暂停开关的语义就不再是「只停调试版」',
    );
    expect(branch, isNot(contains('CHANNEL=beta')));
    expect(branch, isNot(contains('CHANNEL=formal')));
  });

  test('release.yml 只挡发包的两个 job，单测门照跑', () {
    final Map<String, String?> jobs = _jobConditions(
      _repoFile('.github/workflows/release.yml').readAsStringSync(),
    );
    for (final String job in <String>['build', 'publish-android']) {
      expect(jobs.containsKey(job), isTrue, reason: 'release.yml 没有 $job job');
      expect(
        jobs[job],
        startsWith('\${{ $_pauseExpr && '),
        reason: 'release.yml 的 $job 必须在 job 级 if 上判暂停（push 时连 runner 都不起）',
      );
    }
    for (final String job in <String>[
      'web-core-linux',
      'test-native-linux',
      'fushidicts-linux',
      'tests',
    ]) {
      expect(jobs.containsKey(job), isTrue, reason: 'release.yml 没有 $job job');
      expect(
        jobs[job] ?? '',
        isNot(contains(_varRef)),
        reason:
            '$job 是 develop 上 app 全量单测门的一部分，与发包无关，'
            '暂停调试版期间必须照跑',
      );
    }
  });

  test('release-desktop.yml 每个 job 都挡，publish 的 always() 之后紧跟暂停判断', () {
    final Map<String, String?> jobs = _jobConditions(
      _repoFile('.github/workflows/release-desktop.yml').readAsStringSync(),
    );
    expect(
      jobs.keys,
      containsAll(<String>[
        'windows',
        'macos',
        'flatpak-baseapp',
        'linux',
        'ios',
        'testflight',
        'publish',
      ]),
    );
    for (final MapEntry<String, String?> entry in jobs.entries) {
      final String expected = entry.key == 'publish'
          ? '\${{ always() && $_pauseExpr && '
          : '\${{ $_pauseExpr && ';
      expect(
        entry.value,
        startsWith(expected),
        reason:
            'release-desktop.yml 在 push 上整条都是发包（develop 的单测门在 release.yml），'
            '${entry.key} 必须在 job 级 if 上判暂停；带 always() 的 job 不会随 needs '
            '被跳过，必须自己挡',
      );
    }
  });

  test('服务端自动发布用同名变量，只停 debug 候选', () {
    final String workflow = _repoFile(
      '.github/workflows/release-server.yml',
    ).readAsStringSync();
    expect(
      workflow,
      contains(r'PAUSE_DEBUG_RELEASE: ${{ vars.FUSHI_PAUSE_DEBUG_RELEASE }}'),
      reason: 'release-server.yml 的 plan step 没把暂停开关交给 server_release_plan.py',
    );

    final String plan = _repoFile(
      'tool/server_release_plan.py',
    ).readAsStringSync();
    final int pauseAt = plan.indexOf('    if pause_debug:');
    final int betaAt = plan.indexOf('beta = _newest_beta(');
    final int developAt = plan.indexOf('commits/develop');
    expect(pauseAt, greaterThan(0), reason: 'plan_auto 不看 pause_debug');
    expect(
      pauseAt,
      allOf(greaterThan(betaAt), lessThan(developAt)),
      reason:
          '暂停判断必须排在 formal / beta 候选之后、develop debug 候选之前：'
          '放前面会把服务端正式版 / 测试版一起停掉',
    );
    expect(
      plan,
      contains(
        'pause_debug=debug_paused(os.environ.get("PAUSE_DEBUG_RELEASE", ""))',
      ),
    );
  });

  test('docs/agent/build.md 写明开关与恢复方法', () {
    final String doc = _repoFile('docs/agent/build.md').readAsStringSync();
    expect(doc, contains('### 暂停调试版自动发布'));
    expect(doc, contains('FUSHI_PAUSE_DEBUG_RELEASE'));
    expect(doc, contains('gh variable delete FUSHI_PAUSE_DEBUG_RELEASE'));
  });
}
