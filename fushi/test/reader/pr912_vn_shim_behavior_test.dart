import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/source_guard.dart';

/// PR#912 / BUG-1742·1743 收口：VN host-compat shim 的**行为级**覆盖。
///
/// 既有的 `vn_shell_smoke_test.dart` / `vn_non_sasayaki_follow_guard_test.dart`
/// 全是源码字符串扫描——它们证明得了「那段代码在」，证明不了「那段代码算对了」。
/// 本 PR 里最容易算错的恰恰是**坐标换算**：搜索命中下标是「拼接后的原始文本」
/// 坐标，而屏索引吃的是 `countChars` 过的**可匹配字符**坐标，两者在任何含空白的
/// 章节上系统性偏移。把它算错，全套源码守卫照样全绿。
///
/// 这里走仓库已有的 `Process.run(node, ...)` 范式（先例：
/// `test/anki/exported_glossary_anchor_deeplink_test.dart`），把
/// [ReaderVisualNovelScripts.vnShellScript] 生成的 **shim IIFE 原文**丢进 node 真跑，
/// 用替身补齐 VN 对象的协作者，断言：
/// ① `scrollToSearchMatch` 交给屏索引的是 countChars 坐标（不是原始下标）；
/// ② 命中后真的建了 `fushi-search` 高亮，且 Range 落在正确的屏内文本节点/偏移上；
/// ③ `highlightSelectorCue` 会 await `ensureReady()`——章节加载期到达的 cue 不再丢；
/// ④ `restoreToCharOffset` 走共享 helper，且**保留**了 restore 独有的进度兜底。
void main() {
  test('VN shim 行为级：搜索坐标换算 / 搜索高亮 / cue await ready / restore 兜底', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    final Directory temp =
        Directory.systemTemp.createTempSync('hibiki-pr912-vn-js-');
    final File payload = File('${temp.path}/payload.json')
      ..writeAsStringSync(jsonEncode(<String, String>{'shell': shell}));
    // 跑手与本文件同名同目录（范式同 test/anki/exported_glossary_anchor_deeplink_test）。
    final File runner = File('test/reader/pr912_vn_shim_behavior_test.js');
    expect(runner.existsSync(), isTrue,
        reason: 'behavior harness ${runner.path} must exist');
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>[runner.path, payload.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason: 'VN shim behavior runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });

  test('两段式屏查找只剩共享 helper 一份（restoreToCharOffset 不再内联重写）', () {
    // 生成物是 JS，先用共享的词法掩码把注释换成等长空白：注释里出现同一串字面量
    // 不算数（也不会把这条守卫在「实现完全正确」时误判成红）。
    final String shell =
        maskJsComments(ReaderVisualNovelScripts.vnShellScript());
    // 这是那套「章内字符偏移 → 屏」两段式查找第一段的形状（形参名 target 把它与
    // 有声书 cue 那条同形但不同语义的查找 `…(this.screens[i], start)` 分开）。
    // 它曾同时活在 screenIndexForCharOffset 与 restoreToCharOffset 里，且已经分叉
    // （旧拷贝有 screenIndexForProgress 兜底、helper 没有）。
    int occurrences = 0;
    const String needle =
        'this.screenContainsCharOffset(this.screens[i], target)';
    int i = shell.indexOf(needle);
    while (i >= 0) {
      occurrences++;
      i = shell.indexOf(needle, i + needle.length);
    }
    expect(occurrences, 1, reason: '两段式「偏移 → 屏」查找只能有一份实现；第二份 = 分叉的起点');
  });
}
