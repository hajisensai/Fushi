import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：develop / main 的新 push 把「正在跑、但还很年轻」的旧发布 run 取消掉。
///
/// 演进（都是 2026-09-30 真实 CI 上抓到的）：
/// 1. 最初是两条发布 workflow 里各一个 `cancel-superseded` job。所有者的 #1798 随后把
///    push run 按分支分组（cancel-in-progress: false）：新 run 连同其中任何 job 都 pending
///    到旧 run 跑完，那个 job 永远等不到该出手的时刻——静默失效，每次还白占一个 job。
///    所以取消逻辑搬进独立的 `supersede-develop-releases.yml`：不在发布的 concurrency
///    组里，push 一来就跑；发布 workflow 里**不许**再长回这个 job。
/// 2. 判据按 2026-09 全月 542 次触发发布的 develop push + 分片后实测耗时模拟取最优：
///    旧 run 第一个 job 开始得比新 run 创建早不足 8 分钟（5~11 是平台区；「总是砍」
///    会在 push 密集时饿死发布，p90 等待翻倍），且此刻不足 10 分钟（最早的上传在
///    Android build job 约 10.7 分钟处，别砍在上传途中）。量的是 job 实际开始时刻，
///    不是 `run_started_at`（那只是创建时刻，job 排队时照样走表）。
/// 3. runs API 带 `branch=` 回过过期结果集（09-30 拿到 09-07 的数据），候选永远为空而
///    job 照样绿——查询只按 status 过滤，分支 / 事件 / sha 在 bash 里比。
/// 4. 普通 cancel 停不下 `if: always()` 的 job / step（桌面 publish、macOS 签名），等一轮
///    后 force-cancel。
void main() {
  final String script = File(
    '../tool/cancel_superseded_runs.sh',
  ).readAsStringSync();
  final String workflow = File(
    '../.github/workflows/supersede-develop-releases.yml',
  ).readAsStringSync();

  for (final String name in <String>['release.yml', 'release-desktop.yml']) {
    test('$name 里没有（必然失效的）取消 job', () {
      final String yaml = File('../.github/workflows/$name').readAsStringSync();
      expect(yaml, isNot(contains('cancel-superseded:')));
      expect(yaml, isNot(contains('cancel_superseded_runs.sh')));
    });
  }

  test('独立 workflow：push 触发、不进发布的 concurrency 组、参数 8 / 10', () {
    expect(workflow, contains("branches: ['main', 'develop']"));
    expect(workflow, contains('actions: write'));
    // 进了任何 concurrency 组都可能被 pending 住；发布组更是必然。
    expect(workflow, isNot(contains('\nconcurrency:')));
    expect(workflow, isNot(contains('fushi-release-')));
    expect(workflow, contains('WORKFLOWS: release.yml release-desktop.yml'));
    expect(workflow, contains("SUPERSEDE_WINDOW_MINUTES: '8'"));
    expect(workflow, contains("SUPERSEDE_MAX_ELAPSED_MINUTES: '10'"));
    expect(workflow, contains(r'HEAD_SHA: ${{ github.sha }}'));
    expect(workflow, contains('run: bash tool/cancel_superseded_runs.sh'));
    expect(workflow, isNot(contains('SUPERSEDE_DRY_RUN')));
  });

  test('脚本：只按 status 查询，分支 / 事件 / sha 在 bash 里比', () {
    expect(script, contains(r'-f status="$st"'));
    for (final String param in <String>[
      '-f branch=',
      '?branch=',
      '&branch=',
      '-f event=',
      '?event=',
      '&event=',
    ]) {
      expect(script, isNot(contains(param)), reason: param);
    }
    expect(
      script,
      contains(
        r'[ "$sha" = "$HEAD_SHA" ] && [ "$br" = "$BRANCH" ] && [ "$ev" = "push" ]',
      ),
    );
    expect(
      script,
      contains(
        r'[ "$br" = "$BRANCH" ] && [ "$ev" = "push" ] && [ "$id" -lt "$new_id" ] || continue',
      ),
    );
    // 这次 push 没触发发布（paths 过滤）就什么都不砍：旧 run 仍是最新的有效发布。
    expect(script, contains('created no active run'));
  });

  test('脚本：job 实际开始时刻 vs 新 run 创建时刻，外加安全上限', () {
    expect(script, contains(r'window="${SUPERSEDE_WINDOW_MINUTES:-8}"'));
    expect(
      script,
      contains(r'max_elapsed="${SUPERSEDE_MAX_ELAPSED_MINUTES:-10}"'),
    );
    expect(script, contains(r'date -u -d "$new_created - ${window} minutes"'));
    expect(script, contains(r'/actions/runs/$id/jobs'));
    expect(script, isNot(contains('.run_started_at')));
    expect(
      script,
      contains(r'"$first" > "$push_cutoff" && "$first" > "$safety_cutoff"'),
    );
  });

  test('脚本：普通 cancel 停不下 always() job 时改用 force-cancel', () {
    expect(script, contains(r'/actions/runs/$id/cancel'));
    expect(script, contains(r'/actions/runs/$id/force-cancel'));
    expect(
      script,
      contains(r'force_after="${SUPERSEDE_FORCE_AFTER_SECONDS:-90}"'),
    );
    expect(
      script.indexOf(r'/actions/runs/$id/cancel'),
      lessThan(script.indexOf(r'/actions/runs/$id/force-cancel')),
    );
  });
}
