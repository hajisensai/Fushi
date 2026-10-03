import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：push / pull_request / pull_request_target 触发的 workflow，每个 job 都必须
/// 显式写 `timeout-minutes`。
///
/// 起因（2026-09-30 实测）：build-multiplatform 的 android job 没有超时，一次
/// appSmoke 模拟器卡死后占着一个槽位跑了 250 分钟——GitHub 的默认上限是 360 分钟。
/// 公开仓库只有约 20 个并发槽位（macOS 5 个），一个卡死的 job 就是几小时的排队。
/// 超时按历史实测最大耗时留约 1.5~2 倍余量（见各 job 旁的数值），只兜卡死，不卡正常
/// 慢构建。定时 / 手动 / `workflow_call` 的 workflow 不在此列：它们不和 PR / develop
/// 抢日常槽位。
///
/// 按行解析而不引入 package:yaml（fushi 不直接依赖它）：`jobs:` 下两格缩进的键是
/// job，四格缩进的 `timeout-minutes:` / `uses:` 属于该 job。
final RegExp _jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');

List<String> _jobsWithoutTimeout(String yaml) {
  final List<String> lines = yaml.split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  if (jobsAt == -1) return <String>[];
  final List<String> missing = <String>[];
  String? job;
  bool ok = false;
  void close() {
    final String? current = job;
    if (current != null && !ok) missing.add(current);
  }

  for (int i = jobsAt + 1; i < lines.length; i++) {
    final String line = lines[i];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      break; // 下一个顶层键
    }
    final RegExpMatch? m = _jobHeader.firstMatch(line);
    if (m != null) {
      close();
      job = m.group(1);
      ok = false;
      continue;
    }
    if (line.startsWith('    timeout-minutes:') ||
        line.startsWith('    uses:')) {
      ok = true;
    }
  }
  close();
  return missing;
}

bool _sharesDailySlots(String yaml) {
  final int onAt = yaml.indexOf('\non:');
  final int jobsAt = yaml.indexOf('\njobs:');
  if (onAt == -1 || jobsAt == -1) return false;
  final String on = yaml.substring(onAt, jobsAt);
  return RegExp(
    r'^\s{2}(push|pull_request|pull_request_target):',
    multiLine: true,
  ).hasMatch(on);
}

void main() {
  test('判据自校验（合成语料）', () {
    const String yaml = '''
name: x
on:
  pull_request:
jobs:
  good:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - run: echo
  reusable:
    uses: ./.github/workflows/other.yml
  bad:
    runs-on: ubuntu-latest
    steps:
      - name: step with nested timeout-minutes does not count
        timeout-minutes: 5
        run: echo
''';
    expect(_sharesDailySlots(yaml), isTrue);
    expect(_jobsWithoutTimeout(yaml), <String>['bad']);
    expect(
      _sharesDailySlots('on:\n  schedule:\n    - cron: "0 0 * * *"\njobs:\n'),
      isFalse,
    );
  });

  test('PR / push 触发的 workflow 每个 job 都有 timeout-minutes', () {
    final List<File> workflows = Directory('../.github/workflows')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
        .toList();
    expect(workflows.length, greaterThan(10)); // 规模哨兵
    int scanned = 0;
    final List<String> offenders = <String>[];
    for (final File f in workflows) {
      final String yaml = f.readAsStringSync();
      if (!_sharesDailySlots(yaml)) continue;
      scanned++;
      for (final String job in _jobsWithoutTimeout(yaml)) {
        offenders.add('${f.uri.pathSegments.last}: $job');
      }
    }
    expect(scanned, greaterThan(5)); // 规模哨兵：判据塌了就扫不到任何 workflow
    expect(
      offenders,
      isEmpty,
      reason:
          '没有 timeout-minutes 的 job 卡死时占一个槽位到 360 分钟（2026-09-30 '
          'appSmoke 实测 250 分钟）。按历史最大耗时留余量补上：\n'
          '${offenders.join('\n')}',
    );
  });
}
