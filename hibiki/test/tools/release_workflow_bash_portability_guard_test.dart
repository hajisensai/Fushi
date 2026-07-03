// 守卫：release-desktop.yml 的 prune 步骤必须 bash 3.2 可移植。
//
// 背景（BUG-542）：GitHub Actions 的 macOS runner 自带 /bin/bash 仍是 bash 3.2
// （Apple 因 GPLv3 从未升级），没有 bash 4+ 的 `mapfile`/`readarray` builtin。
// 之前 apple job 的「Prune stale assets from rolling debug release」步骤用
// `mapfile -t VAR < <(cmd)`，在 macOS runner 上稳定 `mapfile: command not found`
// (exit 127)。修复是换成 `while IFS= read -r line; do VAR+=("$line"); done < <(cmd)`。
// 本守卫锁定：release-desktop.yml 里绝不能再出现 mapfile/readarray，否则 apple
// 发布任务会再次崩。
//
// 纯 dart:io，不依赖 Flutter 运行时；从 hibiki/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 .github/workflows/release-desktop.yml 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/.github/workflows/release-desktop.yml')
        .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 .github/workflows/release-desktop.yml 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

// 单词边界匹配 mapfile / readarray（避免误伤注释里恰好含子串的单词）。
final RegExp _bashOnlyBuiltinRe = RegExp(r'\b(mapfile|readarray)\b');

void main() {
  final root = _repoRoot();
  final workflow = File('${root.path}/.github/workflows/release-desktop.yml');

  test('release-desktop.yml 不得使用 bash4+ only 的 mapfile/readarray', () {
    expect(
      workflow.existsSync(),
      isTrue,
      reason: '缺 ${workflow.path}',
    );
    final content = workflow.readAsStringSync();
    final hits =
        _bashOnlyBuiltinRe.allMatches(content).map((m) => m.group(0)).toList();
    expect(
      hits,
      isEmpty,
      reason: 'release-desktop.yml 出现 bash 4+ builtin ${hits.toSet()}：GitHub '
          'Actions 的 macOS runner 是 bash 3.2（无 mapfile/readarray），apple '
          '发布 job 会 `command not found` (exit 127)。请改用可移植的 '
          'while-read 循环：VAR=(); while IFS= read -r line; do VAR+=("\$line"); '
          'done < <(cmd)（见 BUG-542）。',
    );
  });
}
