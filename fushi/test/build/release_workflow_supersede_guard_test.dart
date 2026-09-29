import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：两条发布 workflow 在 push 时把「被新 push 取代、且开始不足 5 分钟」的旧 run 取消。
///
/// 起因（2026-09-30 实测 9/27–9/29）：develop 65 次 push 里 20 次间隔 < 5 分钟，而发布
/// workflow 的 concurrency 按 sha 分组、`cancel-in-progress: false`，每次 push 都完整跑完。
/// 公开仓库的瓶颈是并发 runner 槽位，死 run 占着槽位让别人的 job 排队 30~86 分钟。
///
/// 守的三件事，任何一件松了都是静默失效：
/// * job 只在 `push` 上跑——正式版（`release: published`）与手动 dispatch 绝不能被取消；
/// * 窗口是 5 分钟——放宽到「无条件取消」会把正在上传 TestFlight / Release 资产 / 更新清单
///   的 run 砍成半发布状态；
/// * 脚本查询不带 `event=push`——与 `branch=` 同用时 runs API 回的是过期结果集
///   （同日实测停在 09-07），候选永远为空而 job 照样绿。
void main() {
  const List<String> releaseWorkflows = <String>[
    'release.yml',
    'release-desktop.yml',
  ];

  for (final String name in releaseWorkflows) {
    test('$name 在 push 上取消 5 分钟内被取代的旧 run', () {
      final String yaml = File('../.github/workflows/$name').readAsStringSync();
      final int at = yaml.indexOf('\n  cancel-superseded:\n');
      expect(at, isNot(-1), reason: '$name 没有 cancel-superseded job');
      final int next = yaml.indexOf(RegExp(r'\n  [a-z][a-z0-9-]*:\n'), at + 1);
      final String job = yaml.substring(at, next == -1 ? yaml.length : next);

      expect(job, contains("if: github.event_name == 'push'"));
      expect(job, contains('actions: write'));
      expect(job, contains("SUPERSEDE_WINDOW_MINUTES: '5'"));
      expect(job, contains('run: bash tool/cancel_superseded_runs.sh'));
      expect(job, isNot(contains('SUPERSEDE_DRY_RUN')));
    });
  }

  test('脚本只取消本分支更早的 push run，且查询不带 event=push', () {
    final String script = File(
      '../tool/cancel_superseded_runs.sh',
    ).readAsStringSync();

    expect(script, contains('if [ "\$event" != "push" ]; then'));
    expect(script, contains(r'select(.event == \"push\" and .id < $RUN_ID)'));
    expect(script, contains(r'runs?branch=$branch&status=$status'));
    expect(script, isNot(contains('&event=push')));
  });
}
