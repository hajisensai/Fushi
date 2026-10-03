import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_sentence_audio_ownership_script.dart';

/// BUG-2907：有声书当前句高亮不含句末「。」与句首「「」。
///
/// cue 坐标只数可匹配字，两条高亮路径都把首个到末个可匹配字映射回 DOM。现在三种
/// view mode 共用 [kSentenceAudioOwnershipJs]（标点归属对齐 Hoshi Reader Android）放宽
/// 首尾。行为在 node 里真跑生产常量；接线由源码断言钉住——漏接任何一条路径，那种
/// 模式的高亮就悄悄退回旧样子。
void main() {
  test('标点归属行为级（node）', () {
    final Directory temp = Directory.systemTemp.createTempSync(
      'hibiki-bug2890-ownership-',
    );
    final File payload = File('${temp.path}/payload.json')
      ..writeAsStringSync(
        jsonEncode(<String, String>{'script': kSentenceAudioOwnershipJs}),
      );
    final File runner = File(
      'test/reader/sentence_audio_ownership_behavior_test.js',
    );
    expect(runner.existsSync(), isTrue);
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
      reason:
          'sentence audio ownership runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });

  test('三种 shell 都装上并用上标点归属', () {
    for (final bool vn in <bool>[false, true]) {
      for (final bool continuous in <bool>[false, true]) {
        final String engine = ReaderPaginationScripts.engineShell(
          vnMode: vn,
          continuousMode: continuous,
        );
        final int install = engine.indexOf(
          'window.fushiSentenceAudioOwnership = (function()',
        );
        expect(install, isNonNegative, reason: 'vn=$vn continuous=$continuous');
        expect(
          install,
          lessThan(engine.indexOf('window.__fushiShells = {};')),
          reason: '必须在任何 shell 安装之前定义',
        );
      }
    }
    final String paged = ReaderPaginationScripts.paginatedShellSource();
    final String collect = paged.substring(
      paged.indexOf('collectSentenceAudioCueRanges: function'),
      paged.indexOf('applySentenceAudioCues: function'),
    );
    expect(
      collect,
      contains('window.fushiSentenceAudioOwnership.extendSegments('),
    );
    final String vnSource = File(
      'lib/src/reader/reader_visual_novel_scripts.dart',
    ).readAsStringSync();
    final String vnCollect = vnSource.substring(
      vnSource.indexOf('collectMatchableCueRanges: function'),
      vnSource.indexOf('collectMatchableSegments: function'),
    );
    expect(
      vnCollect,
      contains('window.fushiSentenceAudioOwnership.extendSegments('),
    );
  });
}
