import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：两条发布 workflow 的 `push:` 分支清单必须**完全一致**。
///
/// 起因（2026-09-05 用户报「我怎么还是 13384 版本说是最新版本」）：
/// `release-desktop.yml` 的 push 触发被从 `['main', 'develop']` 收窄成 `['main']`，
/// 依据写的是「合进 develop 后再出一份桌面/Apple 产物是纯冗余」。那句话是事实错误——
/// `release.yml` 只有 `build`(Android APK) 与 `tests` 两个 job，从来不产桌面/Apple 产物。
/// 于是收窄掉的不是重复，而是 develop 上桌面 debug 包的**唯一来源**。
///
/// 实测后果：`fushi-debug-rolling` 里 Android APK 一路跟到 13529，而
/// `windows-setup.exe` / `macos.zip` / `ios.ipa` 全部停在 13384（09-03 之后再没更新过）。
/// 桌面用户的更新器诚实地报「已是最新」——确实没有更新的桌面包。
///
/// 这类失效**与「没人推代码」完全同形**，且现有守卫一条都拦不住：
/// `release_workflow_path_filter_guard_test.dart` 只校验 paths 指向的路径真实存在，
/// 压根不看 `branches`。所以必须专门钉这条不变式。
///
/// 不变式本身：**两条 workflow 产出的平台集合不相交**（一条出 Android，另一条出
/// Windows/macOS/iOS），因此任何一条的分支清单少一项，都等于那些平台在该分支上静默断更。
/// 守的是「一致」而不是「必须含 develop」——将来若有意把两条一起收窄到 main，
/// 改一处即可，守卫不会挡路；而只改一条就必红。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');

  const String androidWorkflow = 'release.yml';
  const String desktopWorkflow = 'release-desktop.yml';

  /// 取 `on:` → `push:` 段里那行 `branches: [...]` 的清单。
  ///
  /// 只认**未被注释掉**的那一行：`# branches:` 是停用状态，停用就等于不触发，
  /// 拿它当数据会让守卫在「整个 push 块被注释掉」时静默全绿。
  List<String> pushBranches(String yaml, String label) {
    final List<String> lines = yaml.split('\n');
    int pushAt = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trimRight() == '  push:') {
        pushAt = i;
        break;
      }
    }
    expect(pushAt, isNot(-1),
        reason: '$label 里找不到启用中的 `  push:` 触发块——'
            '整块被注释掉或缩进变了，这条守卫的对象就没了，先修锚点');

    for (int i = pushAt + 1; i < lines.length; i++) {
      final String line = lines[i];
      // 走出 push 块：回到 `  xxx:` 这一级（release: / workflow_dispatch: ...）。
      if (RegExp(r'^  \S').hasMatch(line) && !line.startsWith('  push:')) break;
      final RegExpMatch? m =
          RegExp(r'^\s+branches:\s*\[(.*)\]\s*$').firstMatch(line);
      if (m == null) continue;
      return m
          .group(1)!
          .split(',')
          .map((String s) => s.trim().replaceAll("'", '').replaceAll('"', ''))
          .where((String s) => s.isNotEmpty)
          .toList()
        ..sort();
    }
    fail('$label 的 push 块里没有启用中的 `branches: [...]` 行');
  }

  test('前置：两条发布 workflow 都在', () {
    expect(File('${workflowsDir.path}/$androidWorkflow').existsSync(), isTrue);
    expect(File('${workflowsDir.path}/$desktopWorkflow').existsSync(), isTrue);
  });

  test('两条发布 workflow 产出的平台集合确实不相交（否则本守卫的前提就没了）', () {
    final String android =
        File('${workflowsDir.path}/$androidWorkflow').readAsStringSync();
    final String desktop =
        File('${workflowsDir.path}/$desktopWorkflow').readAsStringSync();

    // 顶层 job 名 = 各自真正产出的东西。这一条是本守卫的**自校验**：
    // 哪天 release.yml 自己也开始出桌面产物了，「少一个分支就断更」的推理不再成立，
    // 这条会先红，提醒改守卫而不是让它继续守一个过期的理由。
    List<String> jobNames(String yaml) => yaml
        .split('\n')
        .where((String l) => RegExp(r'^  [a-z][a-z0-9_-]*:$').hasMatch(l))
        .map((String l) => l.trim().replaceAll(':', ''))
        .where((String n) =>
            n != 'push' && n != 'release' && n != 'workflow_dispatch')
        .toList();

    final List<String> androidJobs = jobNames(android);
    final List<String> desktopJobs = jobNames(desktop);

    expect(androidJobs, contains('build'),
        reason: '$androidWorkflow 应有 Android 构建 job');
    expect(desktopJobs, containsAll(<String>['windows', 'macos']),
        reason: '$desktopWorkflow 应有桌面构建 job');
    expect(androidJobs.any((String j) => desktopJobs.contains(j)), isFalse,
        reason: '两条 workflow 的 job 名出现重叠，说明产出可能不再不相交，'
            '请重新评估本守卫的前提');
  });

  test('push 分支清单必须一致——只改一条就是让另一批平台静默断更', () {
    final String android =
        File('${workflowsDir.path}/$androidWorkflow').readAsStringSync();
    final String desktop =
        File('${workflowsDir.path}/$desktopWorkflow').readAsStringSync();

    final List<String> androidBranches = pushBranches(android, androidWorkflow);
    final List<String> desktopBranches = pushBranches(desktop, desktopWorkflow);

    expect(androidBranches, isNotEmpty);
    expect(desktopBranches, androidBranches,
        reason: '$desktopWorkflow 的 push 分支是 $desktopBranches，'
            '而 $androidWorkflow 是 $androidBranches。两者产出的平台不相交：'
            '前者出 Windows/macOS/iOS，后者只出 Android APK。分支清单不一致'
            '= 差集里的分支上，某一批平台的包**再也不会被构建**，而症状与'
            '「没人推代码」完全同形（2026-09-05：桌面包停在 13384 而 Android 到 13529）。');
  });
}
