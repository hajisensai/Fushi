import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：PR 关闭 / 合并后，取消它还在排队 / 在跑的 CI，并删掉它 PR ref 下的缓存。
///
/// 起因（2026-09-30 实测）：PR 的 concurrency 只在同一 PR 再推提交时才
/// cancel-in-progress，合并不会取消任何东西。某一时刻排队 / 在跑的 PR run 覆盖 15 个
/// 分支，只有 1 个 PR 还开着；另外 14 个已合并 PR 占着约 39 条 run，外加一个卡死的
/// appSmoke 占了一个槽位 250 分钟——在 ~20 个并发槽位的公开仓库里，这就是「一直在堵」。
///
/// **为什么不用 `pull_request_target`**：79% 的 PR 来自 fork，其 `pull_request` token
/// 只读；#1829 为此把 cache-cleanup 改成 `pull_request_target`，结果它**一次都没再跑**——
/// `pull_request_target` 的 workflow 定义取自**默认分支 main**，main 落后 develop 一百多个
/// 提交、agent 不碰它，而 main 上那份只认 `pull_request`。于是两头都不触发，连同仓 PR 也
/// 失去了清理。现在的分工：
/// * 合并的 PR（不论来源）→ `merged-pr-cleanup.yml`，挂在 push 到 develop 上（合并就是
///   push，跑的是 develop 自己的 workflow、token 可写）；
/// * 同仓 PR 未合并就关掉 → `cache-cleanup.yml`（`pull_request: closed`）。
///
/// 共用脚本 `tool/cleanup_pr_ci.sh` 钉住的边界，任何一条松了要么失效、要么误伤：
/// * 只取消 `pull_request` / `pull_request_target` 触发的 run，develop 的 push 发布不碰；
/// * 校验 run 的 `head_repository` 就是这个 PR 的 head 仓库——分支**名**不唯一；
/// * 只按 status 查询，分支在 bash 里比（runs API 带 `branch=` 回过过期结果集）；
/// * 普通 cancel 停不下 always() job，等一轮后 force-cancel；取消排在删缓存之前。
void main() {
  String read(String path) => File('../$path').readAsStringSync();

  test('脚本：取消判据（事件 / head 仓库 / 分支都在 bash 里比）与先取消后删缓存', () {
    final String sh = read('tool/cleanup_pr_ci.sh');
    expect(
      sh,
      contains(
        'select(.event == "pull_request" or .event == "pull_request_target")',
      ),
    );
    expect(
      sh,
      contains(r'[ "$head_branch" = "$head_branch_want" ] || continue'),
    );
    expect(sh, contains(r'[ "$head_repo" = "$head_repo_want" ] || continue'));
    expect(sh, contains(r'case " ${SKIP_WORKFLOW_PATHS:-} " in *" $path "*)'));
    for (final String param in <String>['-f branch=', '?branch=', '&branch=']) {
      expect(sh, isNot(contains(param)), reason: param);
    }
    final int cancel = sh.indexOf(r'/actions/runs/$id/cancel"');
    final int force = sh.indexOf(r'/actions/runs/$id/force-cancel');
    final int caches = sh.indexOf(r'actions/caches?per_page=100&ref=$ref');
    expect(cancel, greaterThan(0));
    expect(force, greaterThan(cancel));
    expect(caches, greaterThan(force), reason: '先把还在跑、可能继续写缓存的 run 停掉，再删缓存');
  });

  test('脚本：按 push 找被合并的 PR——只认真合并进本分支的', () {
    final String sh = read('tool/cleanup_pr_ci.sh');
    expect(sh, contains(r'gh api "repos/$REPO/commits/$sha/pulls"'));
    expect(sh, contains(r'[ -n "$merged_at" ] || continue'));
    expect(sh, contains(r'[ "$base" = "$BASE_BRANCH" ] || continue'));
  });

  test('merged-pr-cleanup.yml：push 到 develop 触发，覆盖 fork PR', () {
    final String yaml = read('.github/workflows/merged-pr-cleanup.yml');
    expect(yaml, contains("on:\n  push:\n    branches: ['develop']"));
    expect(yaml, isNot(contains('\n  pull_request_target:')));
    expect(yaml, contains('actions: write'));
    expect(yaml, contains('timeout-minutes:'));
    expect(yaml, contains(r'AFTER: ${{ github.event.after }}'));
    expect(yaml, contains('MERGED_BY_SHAS='));
    expect(yaml, contains('bash tool/cleanup_pr_ci.sh'));
    expect(
      yaml,
      contains('SKIP_WORKFLOW_PATHS: .github/workflows/cache-cleanup.yml'),
    );
  });

  test(
    'cache-cleanup.yml：pull_request closed、只管同仓 PR、不用 pull_request_target',
    () {
      final String yaml = read('.github/workflows/cache-cleanup.yml');
      expect(yaml, contains('\n  pull_request:\n    types: [closed]'));
      expect(
        yaml,
        isNot(contains('\n  pull_request_target:')),
        reason: 'pull_request_target 取默认分支 main 上的定义，main 不同步就永远不跑',
      );
      expect(
        yaml,
        contains(
          'if: github.event.pull_request.head.repo.full_name == github.repository',
        ),
        reason: 'fork PR 在 pull_request 下的 token 只读，取消 / 删缓存全是 403',
      );
      expect(yaml, contains(r'ref: ${{ github.event.pull_request.base.ref }}'));
      expect(yaml, contains('bash tool/cleanup_pr_ci.sh'));
      expect(yaml, contains('actions: write'));
      expect(
        yaml,
        contains('SKIP_WORKFLOW_PATHS: .github/workflows/cache-cleanup.yml'),
      );
    },
  );
}
