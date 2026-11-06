// 增强 LRC（每行带词级 `<MM:SS.xx>` 时间标签）解析的端到端耗时：`LrcParser.parseString`
// 整份一次，含行切分、时间标签、行内标签剥离（打包 / FFI / 拆回）与 cue 组装。
// 预热一次后取 5 次中位数。
//
// 用法（在 packages/fushi_audio 下）：
//   dart compile exe benchmark/lrc_enhanced_benchmark.dart -o <out>.exe && <out>.exe [行数]
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart';

String _clock(int ms) {
  final int m = ms ~/ 60000;
  final int s = (ms ~/ 1000) % 60;
  final int cs = (ms ~/ 10) % 100;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.'
      '${cs.toString().padLeft(2, '0')}';
}

void main(List<String> args) {
  FushiCompute.require();
  final int lines = args.isEmpty ? 20000 : int.parse(args.first);
  const List<String> words = <String>['吾輩は', '猫で', 'ある。', '名前は', 'まだ', '無い。'];
  final StringBuffer lrc = StringBuffer('[ti:bench]\n[ar:fushi]\n');
  for (int i = 0; i < lines; i++) {
    final int start = i * 3000;
    lrc.write('[${_clock(start)}]');
    for (int w = 0; w < words.length; w++) {
      lrc.write('<${_clock(start + w * 400)}>${words[(i + w) % words.length]}');
    }
    lrc.write('\n');
  }
  final String content = lrc.toString();
  int checksum = 0;
  void once() {
    final List<AudioCue> cues = LrcParser.parseString(
      content: content,
      bookKey: 'bench',
    );
    checksum += cues.length + cues.last.text.length;
  }

  once();
  final List<int> us = <int>[];
  for (int i = 0; i < 5; i++) {
    final Stopwatch sw = Stopwatch()..start();
    once();
    us.add(sw.elapsedMicroseconds);
  }
  us.sort();
  stdout.writeln(
    'LrcParser.parseString enhanced x$lines lines: '
    '${(us[2] / 1000).toStringAsFixed(2)} ms median '
    '(min ${(us.first / 1000).toStringAsFixed(2)}, '
    'max ${(us.last / 1000).toStringAsFixed(2)}) checksum=$checksum',
  );
}
