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

  // TODO-1131：per-platform prune 过滤后，把本平台资产从 PLATFORM_ASSETS 中转回
  // ASSET_NAMES 用 `ASSET_NAMES=("${PLATFORM_ASSETS[@]}")`。当本平台在 rolling
  // release 上暂无资产（掉队 / 首发场景，正是本 fix 目标）时 PLATFORM_ASSETS 为
  // 空数组，`("${empty[@]}")` 在 macOS bash 3.2（apple job）+ set -u 下报
  // unbound variable 退 1。必须在该重赋值之前先用 `${#PLATFORM_ASSETS[@]}`（求长对
  // 空数组安全）判空早退。本守卫锁定：两个 workflow 里每个 ASSET_NAMES 重赋值前
  // 都得有对应的长度判空，防 3.2 复崩。
  final releaseYml = File('${root.path}/.github/workflows/release.yml');
  final reassignRe = RegExp(r'ASSET_NAMES=\("\$\{PLATFORM_ASSETS\[@\]\}"\)');
  final guardRe = RegExp(r'\$\{#PLATFORM_ASSETS\[@\]\}"?\s*-eq\s*0');
  for (final wf in [releaseYml, workflow]) {
    test(
        '${wf.uri.pathSegments.last} 的 PLATFORM_ASSETS 重赋值前必须先判空（防 macOS '
        'bash 3.2 空数组 set -u 崩）', () {
      expect(wf.existsSync(), isTrue, reason: '缺 ${wf.path}');
      final content = wf.readAsStringSync();
      final reassigns = reassignRe.allMatches(content).toList();
      // 有 per-platform 过滤才需要守卫；无则跳过（不强制存在，避免过度耦合）。
      if (reassigns.isEmpty) return;
      for (final m in reassigns) {
        // 只看重赋值之前一小段窗口（同一 prune 块内），避免上一块的判空替下一块
        // 背书造成漏检。
        final windowStart = m.start - 600 < 0 ? 0 : m.start - 600;
        final before = content.substring(windowStart, m.start);
        expect(
          guardRe.hasMatch(before),
          isTrue,
          reason: '${wf.path} 在 `ASSET_NAMES=("\${PLATFORM_ASSETS[@]}")`（偏移 '
              '${m.start}）之前没有 `[ "\${#PLATFORM_ASSETS[@]}" -eq 0 ]` 判空早退：'
              '本平台在 rolling 上暂无资产时 PLATFORM_ASSETS 为空，`("\${empty[@]}")` '
              '在 macOS bash 3.2（apple job）+ set -u 下报 unbound variable 退 1，'
              '正好在本 fix 目标场景（掉队 / 首发平台）反向引入新崩点。请先 '
              'if [ "\${#PLATFORM_ASSETS[@]}" -eq 0 ]; then echo ...; exit 0; fi '
              '再重赋值（见 TODO-1131 / BUG-542）。',
        );
      }
    });
  }
}
