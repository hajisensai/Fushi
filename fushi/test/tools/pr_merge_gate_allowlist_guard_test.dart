import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR 合并白名单守卫。
///
/// 用户 2026-09-07 指示：除 `hajisensai`（仓库所有者）与 `W1ght`（长期协作者）
/// 之外，任何人的 PR 都不得在没有明确许可的情况下被合并。
///
/// 这条守卫钉的是 `.github/workflows/pr-merge-gate.yml` 的三个不变式，防止名单
/// 被悄悄放宽、放行条件被悄悄加宽、或整条 workflow 被删掉后没人发现：
///
/// 1. 白名单**恰好**是那两个 login——多一个少一个都要红。这里刻意用等值断言而不是
///    `contains`：加人是需要用户点头的产品决策，不该由改代码的人顺手完成。
/// 2. 唯一的例外通道是 `merge-approved` 标签（打标签需要写权限，动作留在 PR
///    时间线上可追溯）。
/// 3. 名单外作者且没有该标签时，job 必须以非零退出——check 得真的红，不能只打印
///    一句警告就 exit 0。
///
/// 不断言「这条 check 是 required」：仓库当前刻意不设分支保护（日常大量直推
/// develop），把它变成硬门是用户决策，见 workflow 文件头的说明。
File _workflowFile() {
  // 测试的 cwd 是 fushi/，workflow 在仓库根。
  final File file = File('../.github/workflows/pr-merge-gate.yml');
  expect(file.existsSync(), isTrue,
      reason: 'PR 合并白名单门 .github/workflows/pr-merge-gate.yml 不存在——'
          '它被删掉意味着「非白名单作者的 PR 会静默地可合并」，正是本守卫要防的事');
  return file;
}

void main() {
  test('合并白名单恰好是 hajisensai 与 W1ght，一个不多一个不少', () {
    final String yaml = _workflowFile().readAsStringSync();

    final RegExp allowed = RegExp(r"ALLOWED_AUTHORS:\s*'([^']*)'");
    final RegExpMatch? match = allowed.firstMatch(yaml);
    expect(match, isNotNull,
        reason: '找不到 ALLOWED_AUTHORS——白名单的单一真相源不能改名或改写法，'
            '否则这条守卫会在无人察觉的情况下失去判据');

    final List<String> authors = match!
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toList();

    expect(authors, <String>['hajisensai', 'W1ght'],
        reason: '白名单被改动。加人/减人是用户决策（2026-09-07 拍板只放这两个），'
            '不是改代码时顺手能做的事——要改请连同本用例一起改，并在提交里说明是谁授权的');
  });

  test('唯一的例外通道是 merge-approved 标签', () {
    final String yaml = _workflowFile().readAsStringSync();

    expect(yaml, contains("APPROVAL_LABEL: 'merge-approved'"),
        reason: '许可通道必须是这个具体标签名；改名会让既有的「已许可」PR 突然变红');
    expect(yaml, contains("contains(github.event.pull_request.labels.*.name, 'merge-approved')"),
        reason: '标签判定必须直接读 PR 的 labels；换成别的信号（评论、作者关联度、'
            '是否有 approve review）都会把「许可」这件事从可追溯动作变成可推断状态');
  });

  test('名单外且无许可时必须以非零退出（check 要真的红）', () {
    final String yaml = _workflowFile().readAsStringSync();

    // 脚本尾部是拒绝分支：报错 + exit 1。只打印不 exit 会让 check 变绿，
    // 等于这条门形同虚设——这正是「空壳断言」类失效的典型形态。
    final int errorAt = yaml.indexOf('::error title=Merge not permitted::');
    expect(errorAt, greaterThan(-1),
        reason: '拒绝分支必须打出 GitHub 的 error 注解，PR 页面上才看得见原因');

    final String tail = yaml.substring(errorAt);
    expect(tail, contains('exit 1'),
        reason: '拒绝分支必须 exit 1。只 echo 不退出 = check 恒绿 = 这条门等于没有');

    // 放行分支同样要显式 exit 0，避免后续追加步骤时把拒绝路径漏成 fallthrough。
    expect(yaml, contains('is on the merge allowlist'),
        reason: '放行分支要留下可读日志，排查「为什么这条 PR 是绿的」时用得上');
  });

  test('只在 main / develop 的 PR 上生效', () {
    final String yaml = _workflowFile().readAsStringSync();

    expect(yaml, contains("branches: ['main', 'develop']"),
        reason: '两条受保护主干都要覆盖：只挂 develop 会让 main 上的 PR 绕过这道门');
    expect(yaml, contains('pull_request_target:'),
        reason: 'fork PR 的 pull_request 事件拿不到仓库上下文，必须用 '
            'pull_request_target——而本门要挡的恰恰就是 fork PR');
  });
}
