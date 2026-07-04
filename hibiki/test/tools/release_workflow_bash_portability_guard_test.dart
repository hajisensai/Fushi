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

// 终端位置的 test-then-emit 惯用法：`[ ... ] && echo`/`[ ... ] && printf`。
// 当它是 pipefail 管道 / brace-group 的最后一条命令、且 test 为假时整条返回 1，
// pipefail 传播 + set -e 静默杀脚本（TODO-1129）。改用无 else 的 `if` 消除特例。
// 只匹配向 stdout 发射的 echo/printf（这才是会进 brace-group 供 sort 的危险形式），
// 不误伤 in_keep 里安全的 `[ "$k" = "$target" ] && return 0`（函数末尾非管道）。
// 逐行剥掉注释（`#` 后内容）再匹配，避免误伤本注释块里引用的惯用法字面量。
final RegExp _terminalTestEmitRe = RegExp(r'\]\s*&&\s*(echo|printf)\b');

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

  test('release-desktop.yml prune 步骤不得用 `] && echo/printf` 终端惯用法', () {
    expect(workflow.existsSync(), isTrue, reason: '缺 ${workflow.path}');
    // 逐行剥掉 `#` 起的注释，只扫真正会执行的脚本正文。
    final hits = <String>[];
    for (final rawLine in workflow.readAsLinesSync()) {
      final hashIdx = rawLine.indexOf('#');
      final code = hashIdx >= 0 ? rawLine.substring(0, hashIdx) : rawLine;
      if (_terminalTestEmitRe.hasMatch(code)) {
        hits.add(rawLine.trim());
      }
    }
    expect(
      hits,
      isEmpty,
      reason: 'release-desktop.yml 出现 `[ ... ] && echo/printf` 惯用法：$hits。'
          '当它处于 pipefail 管道 / brace-group 末尾且 test 为假时（空 CURRENT_SEQ '
          '或末尾无 -debug.<seq> 的 legacy 资产），整条返回 1，pipefail 传播、'
          'set -e 静默杀掉 prune 步骤（apple/windows 发布 job 无输出退 1）。请改用无 '
          'else 的 if：if [ -n "\$X" ]; then echo "\$X"; fi（见 TODO-1129）。',
    );
  });
}
