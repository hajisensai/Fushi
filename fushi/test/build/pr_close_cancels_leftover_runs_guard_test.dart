import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：PR 关闭（含合并）时，取消它还在排队 / 在跑的 CI。
///
/// 起因（2026-09-30 实测）：PR 的 concurrency 只在同一 PR 再推提交时才
/// cancel-in-progress，合并不会取消任何东西。某一时刻排队 / 在跑的 PR run 覆盖 15 个
/// 分支，只有 1 个 PR 还开着；另外 14 个已合并 PR 占着约 39 条 run，外加一个卡死的
/// appSmoke 占了一个槽位 250 分钟——在 ~20 个并发槽位的公开仓库里，这就是「一直在堵」。
///
/// 钉住的边界，任何一条松了要么失效、要么误伤：
/// * 只取消 `pull_request` / `pull_request_target` 触发的 run，develop 的 push 发布不碰；
/// * 校验 `head_repository` 是本仓库——分支**名**不唯一，fork 上同名分支（例如
///   `develop`）发起的 PR 也会被 `branch=` 匹配到；
/// * 不取消本 workflow 自己（它还要接着删这个 PR 的缓存）；
/// * 分支名走 `-f branch=`，不拼进 URL / jq。
void main() {
  test('cache-cleanup.yml 在 PR 关闭时取消该 PR 分支的剩余 CI', () {
    final String yaml = File(
      '../.github/workflows/cache-cleanup.yml',
    ).readAsStringSync();

    expect(yaml, contains('types: [closed]'));
    expect(yaml, contains('actions: write'));
    expect(yaml, contains("Cancel this PR's still-queued / running CI"));
    expect(
      yaml,
      contains(
        'select(.event == "pull_request" or .event == "pull_request_target")',
      ),
    );
    expect(yaml, contains(r'[ "$head_repo" = "$REPO" ] || continue'));
    expect(yaml, contains(r'[ "$name" = "$SELF_WORKFLOW" ] && continue'));
    expect(yaml, contains(r'-f branch="$HEAD_BRANCH"'));
    expect(yaml, isNot(contains(r'runs?branch=$HEAD_BRANCH')));
    // 普通 cancel 停不下 always() job：等一轮后对还在跑的 force-cancel。
    expect(yaml, contains(r'/actions/runs/$id/cancel"'));
    expect(yaml, contains(r'/actions/runs/$id/force-cancel'));
    expect(
      yaml.indexOf(r'/actions/runs/$id/cancel"'),
      lessThan(yaml.indexOf(r'/actions/runs/$id/force-cancel')),
    );
    // 取消必须排在删缓存之前：先把还在跑、可能继续写缓存的 run 停掉。
    expect(
      yaml.indexOf("Cancel this PR's still-queued / running CI"),
      lessThan(yaml.indexOf('Delete caches scoped to this PR ref')),
    );
  });
}
