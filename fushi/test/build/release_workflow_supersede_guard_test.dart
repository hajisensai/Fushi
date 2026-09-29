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
///
/// 2026-09-30 合入后的真实闭环又抓到一处：旧版拿「现在 − 5 分钟」比 `run_started_at`。
/// 可本 job 自己要排队等 runner（实测 6 分钟），等它开跑，间隔只有 2.3 分钟的旧 run
/// 已「跑了 8 分钟」，于是没砍；而 `run_started_at` 只是 run 的创建时刻，job 在排队时
/// 它照样走表。所以判据改为：旧 run **job 的实际开始时刻**对比**本 run 的创建时刻**
/// （5 分钟），外加一道「此刻已跑满 9 分钟就不砍」的安全上限——最快的上传步骤在
/// Android build job（≥ 10.7 分钟）末尾，桌面 publish 要等三条腿（≥ 12 分钟）。
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
      expect(job, contains("SUPERSEDE_MAX_ELAPSED_MINUTES: '9'"));
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

  test('脚本按旧 run 的 job 实际开始时刻、以本 run 创建时刻为基准判断', () {
    final String script = File(
      '../tool/cancel_superseded_runs.sh',
    ).readAsStringSync();

    // 以本 run 的 created_at 为基准，而不是本 job 开跑的「现在」。
    expect(
      script,
      contains('[.workflow_id, .head_branch, .event, .created_at]'),
    );
    expect(script, contains(r'date -u -d "$created - ${window} minutes"'));
    // 量的是旧 run 的 job（去掉它自己的 cancel-superseded），不是 run_started_at。
    expect(script, contains(r'/actions/runs/$id/jobs'));
    expect(script, contains('select(.name != "cancel-superseded"'));
    expect(script, isNot(contains('run_started_at //')));
    // 安全上限两个条件都要满足才砍。
    expect(
      script,
      contains(r'max_elapsed="${SUPERSEDE_MAX_ELAPSED_MINUTES:-9}"'),
    );
    expect(
      script,
      contains(r'"$first" > "$push_cutoff" && "$first" > "$safety_cutoff"'),
    );
  });
}
