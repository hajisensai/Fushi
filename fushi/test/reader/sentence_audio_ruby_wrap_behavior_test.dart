import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
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

  // BUG-2917：VN shell 曾自带一份逐段包裹、不补缝的实现，竖排注音处高亮断开。
  // 三个 shell 必须各自恰好带一份共享的分组 + 补缝实现，不能再各写各的。
  test('BUG-2917: every reader shell carries exactly one shared ruby-gap '
      'implementation', () {
    final Map<String, String> shells = <String, String>{
      'paginated': ReaderPaginationScripts.paginatedShellSource(),
      'continuous': ReaderPaginationScripts.continuousShellSource(),
      'vn': ReaderVisualNovelScripts.vnShellScript(),
    };
    for (final MapEntry<String, String> shell in shells.entries) {
      for (final String fn in <String>[
        'sentenceAudioWrapItems: function',
        'fillSentenceAudioRubyGaps: function',
        'clearSentenceAudioRubyGaps: function',
      ]) {
        expect(
          fn.allMatches(shell.value).length,
          1,
          reason: '${shell.key} shell must define $fn exactly once',
        );
      }
    }
    expect(
      shells['vn'],
      contains('this.fillSentenceAudioRubyGaps(wrappers)'),
      reason: 'VN must fill ruby gaps after activating a cue',
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
