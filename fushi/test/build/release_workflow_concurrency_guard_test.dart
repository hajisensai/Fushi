import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：两条发布 workflow 的 concurrency 组名必须**各自带上 workflow 名**，
/// 且都是 `cancel-in-progress: false`。
///
/// 起因（2026-09-08 用户要求「发正式版包的时候并行发包」）：`release.yml`（Android）与
/// `release-desktop.yml`（Windows/macOS/iOS）此前的 concurrency 组名写法完全相同——
/// `fushi-release-<tag|sha>`。GitHub 的 concurrency 组是**仓库级**而非 workflow 级：
/// 两条 workflow 只要组名算出来一样就串行；同组「1 个 in-progress + 1 个 pending」的语义
/// 还会让第二个 pending 把第一个 pending **取消**（2026-09-03 实测：同 sha 先后 dispatch
/// Android beta 与桌面 beta，Android 那条 5 秒内 `cancelled`、0 个 job）。正式版靠
/// `release: published` 同时点燃两条、同 tag 同组必串行——桌面/Apple 包要等 Android 整条
/// 跑完才开始（v2.2.4：Android 13:44 上传，Windows/macOS/iOS 14:52）。
///
/// 组名带上 `${{ github.workflow }}` 后两条 workflow 分属不同组、真并行；同一条 workflow
/// 内仍按 tag/sha 串行。并行上传同一个 Release 的安全性依赖三处既有设计（守在各自的
/// 测试里）：rolling debug prune 只删本平台资产（TODO-1131）、softprops 建 release 撞车
/// 重取、`publish_update_manifest.sh` 的重取合并循环（TODO-781，
/// `update_manifest_publish_race_test.dart`）。
///
/// 守「两条都带 workflow 名」而不是守「组名不相等」：后者在有人把其中一条改成
/// `fushi-release-x-<sha>` 之类的临时名时也绿，而那会让同一条 workflow 失去按 tag 串行。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');
  const List<String> releaseWorkflows = <String>[
    'release.yml',
    'release-desktop.yml',
  ];

  /// 取顶层 `concurrency:` 块里的 `group:` 与 `cancel-in-progress:` 两行。
  /// 只认未被注释掉、顶格的 `concurrency:`——job 级的 concurrency 缩进不同，不是本守卫对象。
  ({String group, String cancel}) topLevelConcurrency(
    String yaml,
    String label,
  ) {
    final List<String> lines = yaml.split('\n');
    final int at =
        lines.indexWhere((String l) => l.trimRight() == 'concurrency:');
    expect(at, isNot(-1), reason: '$label 没有顶层 `concurrency:` 块');
    String? group;
    String? cancel;
    for (int i = at + 1; i < lines.length; i++) {
      final String line = lines[i];
      if (line.isNotEmpty && !line.startsWith(' ')) break; // 下一个顶层键
      final String t = line.trim();
      if (t.startsWith('#') || t.isEmpty) continue;
      if (t.startsWith('group:')) group = t.substring('group:'.length).trim();
      if (t.startsWith('cancel-in-progress:')) {
        cancel = t.substring('cancel-in-progress:'.length).trim();
      }
    }
    expect(group, isNotNull, reason: '$label 的 concurrency 块里没有 group:');
    expect(cancel, isNotNull,
        reason: '$label 的 concurrency 块里没有 cancel-in-progress:');
    return (group: group!, cancel: cancel!);
  }

  for (final String name in releaseWorkflows) {
    test('$name 的 concurrency 组名带 workflow 名、按 tag/sha 分组、不取消 in-progress', () {
      final File f = File('${workflowsDir.path}/$name');
      expect(f.existsSync(), isTrue, reason: '$name 不在了');
      final ({String group, String cancel}) c =
          topLevelConcurrency(f.readAsStringSync(), name);

      expect(c.group, contains(r'${{ github.workflow }}'),
          reason: '$name 的 concurrency 组名 `${c.group}` 没带 workflow 名。'
              'GitHub 的 concurrency 组是仓库级的：与另一条发布 workflow 同名就会串行，'
              '正式版 `release: published` 同时点燃两条时桌面/Apple 要等 Android 整条跑完，'
              '而且同组第二个 pending 会把第一个 pending 取消（2026-09-03 实测 cancelled + 0 job）。');
      expect(c.group, contains('github.sha'),
          reason: '$name 的组名必须仍按 tag/sha 分组：同一条 workflow 同 tag 两次 dispatch '
              '要串行，否则两次同 tag 发布会互相踩资产。');
      expect(c.group, contains('github.event.release.tag_name'),
          reason: '$name 的组名要优先用 release 事件的 tag：同一个 tag 上 release 事件与'
              '手动 dispatch 必须落在同一组里串行。');
      expect(c.cancel, 'false',
          reason: '$name 不能 cancel-in-progress：正在上传资产的发布被取消会留下半个 release。');
    });
  }

  test('两条发布 workflow 的 name 不同——否则 `github.workflow` 分不开它们', () {
    final List<String> names = <String>[];
    for (final String name in releaseWorkflows) {
      final String yaml = File('${workflowsDir.path}/$name').readAsStringSync();
      final RegExpMatch? m =
          RegExp(r'^name:\s*(.+?)\s*$', multiLine: true).firstMatch(yaml);
      expect(m, isNotNull, reason: '$name 没有顶层 name:');
      names.add(m!.group(1)!);
    }
    expect(names.toSet().length, names.length,
        reason: '两条 workflow 的 name 相同（$names）：组名里的 `github.workflow` 就是这个 '
            'name，相同就又回到同一个组里串行了。');
  });
}
