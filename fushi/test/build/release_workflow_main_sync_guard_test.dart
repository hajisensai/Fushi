import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：正式版发布后自动把 `main` 同步成 `develop` 的那一步（2026-09-08 用户要求）。
///
/// 不变式：
/// 1. 只在 `release.yml` 有这一步，`release-desktop.yml` 没有——两条正式版 workflow 并行，
///    各推一次就是两条合并提交。
/// 2. 只在正式通道跑（`manifest_channel == 'formal'`）：debug / beta / 手动 prerelease
///    绝不能动 main。
/// 3. 排在更新清单发布之后：清单落地 = 资产上传完，那才是「发布成功后」。
/// 4. 合并方式是 `git merge --no-ff -X theirs`，失败走 `merge --abort` 报错；**绝不 force-push**：
///    main 上的机器人图表提交让它永远不是 develop 的祖先，纯快进永远失败；而 force 会
///    抹掉 main 的历史。
/// 5. 用 GITHUB_TOKEN 推（不级联触发 main 的 push 构建，不会因此多发一版）。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');
  const String stepName = 'Sync main to develop after formal release';

  String read(String name) =>
      File('${workflowsDir.path}/$name').readAsStringSync();

  /// 取某个 step 从 `- name:` 到下一个 `- name:`（或下一个顶层 job）之间的文本。
  String stepBody(String yaml, String name) {
    final int at = yaml.indexOf('    - name: $name\n');
    expect(at, isNot(-1), reason: '找不到 step `$name`');
    final int next = yaml.indexOf('\n    - name: ', at + 1);
    final int nextJob = yaml.indexOf('\n  tests:', at + 1);
    int end = yaml.length;
    if (next != -1) end = next;
    if (nextJob != -1 && nextJob < end) end = nextJob;
    return yaml.substring(at, end);
  }

  test('只在 release.yml 有同步步，release-desktop.yml 没有', () {
    expect(read('release.yml'), contains('- name: $stepName'));
    expect(read('release-desktop.yml'), isNot(contains(stepName)),
        reason: '两条正式版 workflow 并行，各推一次 main 就是两条合并提交；只留 release.yml 那一份');
  });

  test('只在正式通道跑，且排在更新清单发布之后', () {
    final String yaml = read('release.yml');
    final String body = stepBody(yaml, stepName);
    expect(body,
        contains("if: steps.channel.outputs.manifest_channel == 'formal'"),
        reason: 'debug / beta / 手动 prerelease 绝不能动 main');
    final int manifestAt =
        yaml.indexOf('- name: Publish mirror update manifest (Android assets)');
    final int syncAt = yaml.indexOf('- name: $stepName');
    expect(manifestAt, isNot(-1));
    expect(syncAt, greaterThan(manifestAt),
        reason: '清单落地 = 资产上传完；同步 main 必须在它之后，否则「发布失败但 main 已推进」');
  });

  test('合并方式：--no-ff -X theirs，失败 abort 报错，绝不 force-push', () {
    final String body = stepBody(read('release.yml'), stepName);
    expect(body, contains('git -C "\$WORK" merge --no-ff -X theirs'),
        reason: 'main 上的机器人图表提交让纯快进永远失败；-X theirs 只让图表 SVG 取 develop 的');
    expect(body, contains('merge --abort'));
    expect(body, contains('::error title=main sync failed::'));
    expect(body, contains('merge-base --is-ancestor origin/develop HEAD'),
        reason: 'develop 已在 main 里时要幂等跳过，不能空合并');
    expect(RegExp(r'push[^\n]*(--force|-f\b|\+refs/heads/main)').hasMatch(body),
        isFalse,
        reason: 'force-push 会抹掉 main 的历史（人工合并提交与图表提交）');
    expect(body, contains('x-access-token:\${GITHUB_TOKEN}@github.com'),
        reason: '必须用 GITHUB_TOKEN 推：它的 push 不级联触发 main 的 push 构建');
  });
}
