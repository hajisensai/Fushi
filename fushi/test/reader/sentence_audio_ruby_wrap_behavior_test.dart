import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ruby_gap_script.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-2780：有声书跟随高亮在带振假名的词上断开留缝（iOS 真机「会|釈|をす」）或
/// 叠出一条深色带（iOS 26.5 模拟器，ruby 背景盒与后文 span 叠 7.7px）。
///
/// 根因：`applySentenceAudioCues` 把整句拆成「每段文字一个 span + 每个 ruby 各加 class」
/// 分别刷背景，长注音撑出的间距归谁由引擎决定。修法：同一父节点下连续的文字与整颗
/// ruby 合进同一个 wrapper，由它一次刷背景。
///
/// node 真执行从 reader_pagination_scripts.dart 切出的真实函数，在 fake DOM 上断言：
/// 整句一个 wrapper、ruby 被移入而非克隆、不再加 ruby class、部分文本节点边界正确
/// 切分、ruby 嵌在书自带元素里时不拆书的元素、块级兄弟不被吞进 span、多组基字的
/// ruby 只算一次。撤掉修复即红。
void main() {
  test('BUG-2780: sentence audio highlight wraps text and rubies in one '
      'wrapper (executes reader JS via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final ProcessResult result = await Process.run(nodeExe, <String>[
      'test/reader/sentence_audio_ruby_wrap_behavior_test.js',
    ], workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  // BUG-2917：VN shell 曾自带一份逐段包裹的实现，竖排注音处高亮断开。三个 shell 必须
  // 各自恰好带一份共享的分组包裹实现，不能再各写各的。注音撑出的缝不再逐 wrapper 用
  // box-shadow 补：2026-10-15 起底色由窄条层画、同一行并成一条（highlight_lanes_test）。
  test('BUG-2917: every reader shell carries exactly one shared grouping '
      'implementation and no per-wrapper gap fill', () {
    final Map<String, String> shells = <String, String>{
      'paginated': ReaderPaginationScripts.paginatedShellSource(),
      'continuous': ReaderPaginationScripts.continuousShellSource(),
      'vn': ReaderVisualNovelScripts.vnShellScript(),
    };
    for (final MapEntry<String, String> shell in shells.entries) {
      for (final String fn in <String>[
        'sentenceAudioWrapItems: function',
        'wrapSentenceAudioGroup: function',
        'rubyForNode: function',
      ]) {
        expect(
          fn.allMatches(shell.value).length,
          1,
          reason: '${shell.key} shell must define $fn exactly once',
        );
      }
      expect(
        shell.value,
        isNot(contains('SentenceAudioRubyGaps')),
        reason: '${shell.key}: the lane layer joins a cue line, no gap fill',
      );
    }
  });

  // BUG-3326 审查（#2115 / #2119 同类）：句子包裹曾用 Range.extractContents——它把切点两侧的
  // 文字复制成新文本节点、原节点就地截短，VN 播放中懒包裹时查词选区的「节点 + 偏移」越界、收藏 /
  // 搜索高亮与原生选区塌缩。三个 shell 必须都走共享的 wrapSentenceAudioGroup，正文的切开 / 搬移
  // 只经选区脚本里的 __fushiLiveRanges（行为由同名 .js 用 node 真跑）。
  test('BUG-3326 review: sentence wrapping splits and moves text only through '
      '__fushiLiveRanges, never extractContents', () {
    String slice(String source, String from, String to) {
      final int start = source.indexOf(from);
      expect(start, isNonNegative, reason: 'missing $from');
      final int end = source.indexOf(to, start);
      expect(end, greaterThan(start), reason: 'missing $to after $from');
      return source.substring(start, end);
    }

    final Map<String, String> wrapBodies = <String, String>{
      'paginated': slice(
        ReaderPaginationScripts.paginatedShellSource(),
        'applySentenceAudioCues: function',
        'highlightSentenceAudioCue: function',
      ),
      'continuous': slice(
        ReaderPaginationScripts.continuousShellSource(),
        'applySentenceAudioCues: function',
        'highlightSentenceAudioCue: function',
      ),
      'vn': slice(
        ReaderVisualNovelScripts.vnShellScript(),
        'wrapSentenceAudioCueRanges: function',
        'prepareSentenceAudioInlineTargets: function',
      ),
    };
    for (final MapEntry<String, String> body in wrapBodies.entries) {
      expect(
        RegExp(
          r'(this|self)\.wrapSentenceAudioGroup\(items\[g\], wrapper\)',
        ).hasMatch(body.value),
        isTrue,
        reason: '${body.key} must wrap through the shared helper',
      );
      // BUG-3432：整章逐句包裹在一个 live-range 批里跑，原生选区只读一次。
      expect(
        body.value,
        contains('withLiveRangeBatch('),
        reason: '${body.key} must wrap a whole chapter inside one batch',
      );
      expect(
        body.value,
        isNot(contains('extractContents(')),
        reason: '${body.key} must not copy book text with extractContents',
      );
    }
    expect(kSentenceAudioRubyGapJs, isNot(contains('extractContents(')));
    expect(
      RegExp(r'(?<!guard)\.splitText\(').hasMatch(kSentenceAudioRubyGapJs),
      isFalse,
      reason: 'text nodes are split only via __fushiLiveRanges.splitText',
    );
    expect(kSentenceAudioRubyGapJs, contains('guard.moveNodes('));

    final String selection = ReaderSelectionScripts.source();
    final int guardAt = selection.indexOf('if (!window.__fushiLiveRanges) {');
    expect(guardAt, isNonNegative);
    expect(
      guardAt,
      lessThan(
        selection.indexOf(
          "if (typeof window.__fushiEnsureHighlightPaintable !== 'function')",
        ),
      ),
      reason: 'the guard is installed before the helper that uses it',
    );
    expect(
      selection,
      contains('window.__fushiLiveRanges.moveNodes([node], function() {'),
      reason:
          'the <fushi-hl-text> move keeps live Ranges and the native '
          'selection',
    );
  });
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
