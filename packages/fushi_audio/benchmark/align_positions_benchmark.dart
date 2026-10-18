// 有声书 cue 重切的位置对齐基准：删除前的纯 Dart `_alignPositions`（原样复制在下面，逐条
// 调用）vs native/fushi_compute 的 `ffc_text_align_positions`（整本一次调用）。两条路径
// 的映射逐值比对，不一致退出 1。
//
// 用法（在 packages/fushi_audio 下；AOT 更接近 app）：
//   dart compile exe benchmark/align_positions_benchmark.dart -o <out>.exe && <out>.exe [realdata 目录]
//
// 输入：真实书（FUSHI_MATCH_REALDATA_DIR 格式：`<名>.sections.json` + `<名>.srt`）匹配后，
// 每条命中 cue 的「归一化听写 vs 命中的正文切片」里不相等的那些对（= 重切器实际要对齐的
// 模糊命中）。每项先预热一次，再跑 5 次取中位数。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_compute/fushi_compute.dart';

import '../test/matching/support/reseg_golden_support.dart';

const int _maxAlignCells = 400000;

int _medianUs(String label, void Function() body) {
  body();
  final List<int> us = <int>[];
  for (int i = 0; i < 5; i++) {
    final Stopwatch sw = Stopwatch()..start();
    body();
    us.add(sw.elapsedMicroseconds);
  }
  us.sort();
  final int median = us[us.length ~/ 2];
  stdout.writeln(
    '  ${label.padRight(44)} ${(median / 1000).toStringAsFixed(3).padLeft(10)} ms',
  );
  return median;
}

Future<void> main(List<String> args) async {
  FushiCompute.require();
  stdout.writeln(
    '${Platform.operatingSystem} dart ${Platform.version.split(' ').first}',
  );
  final String dir = args.isNotEmpty
      ? args.first
      : (Platform.environment['FUSHI_MATCH_REALDATA_DIR'] ?? '');
  if (dir.isEmpty) {
    stderr.writeln('usage: align_positions_benchmark <realdata dir>');
    exit(2);
  }
  final List<File> books =
      Directory(dir)
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.sections.json'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File f in books) {
    final String stem = f.path.substring(
      0,
      f.path.length - '.sections.json'.length,
    );
    final List<EpubSection> sections = readRealdataSections(f.path);
    final List<AudioCue> cues = await SrtParser.parse(
      srtFile: File('$stem.srt'),
      bookKey: 'bench',
    );
    final MatchResult matched = EpubSrtMatcher.match(
      sections: sections,
      cues: cues,
    );
    final List<String> norms = <String>[
      for (final EpubSection s in sections)
        AudioTextNormalizer.normalizeWithOffsets(s.text).text,
    ];
    final List<String> heard = <String>[];
    final List<String> read = <String>[];
    int cells = 0;
    for (int k = 0; k < cues.length; k++) {
      final CueMatch m = matched.matches[k];
      if (!m.matched || m.sectionIndex >= norms.length) continue;
      final String norm = norms[m.sectionIndex];
      if (m.normCharEnd > norm.length || m.normCharEnd < m.normCharStart) {
        continue;
      }
      final String a = AudioTextNormalizer.normalize(cues[k].text);
      final String b = norm.substring(m.normCharStart, m.normCharEnd);
      if (a == b) continue;
      heard.add(a);
      read.add(b);
      cells += a.length * b.length;
    }
    stdout.writeln(
      '${stem.split(Platform.pathSeparator).last}: ${cues.length} cues, '
      '${heard.length} fuzzy pairs, ${cells ~/ heard.length.clamp(1, 1 << 30)} DP cells/pair avg',
    );
    late List<List<int>> old;
    late List<Int32List> neu;
    final int o = _medianUs('Dart _alignPositions (per cue)', () {
      old = <List<int>>[
        for (int i = 0; i < heard.length; i++)
          _alignPositions(heard[i], read[i], _maxAlignCells),
      ];
    });
    final int n = _medianUs('ffc_text_align_positions (one batch)', () {
      neu = FushiComputeText.instance.alignPositions(
        heard,
        read,
        maxCells: _maxAlignCells,
      );
    });
    stdout.writeln(
      '  ${'=> speedup'.padRight(44)} ${(o / n).toStringAsFixed(1).padLeft(10)} x',
    );
    for (int i = 0; i < old.length; i++) {
      if (old[i].length != neu[i].length) {
        stderr.writeln('MISMATCH pair $i length');
        exit(1);
      }
      for (int j = 0; j < old[i].length; j++) {
        if (old[i][j] != neu[i][j]) {
          stderr.writeln('MISMATCH pair $i at $j');
          exit(1);
        }
      }
    }
  }
  stdout.writeln('all maps identical');
}

// ======== 原样复制：cue_sentence_resegmenter.dart `_alignPositions`（删除前；maxAlignCells 改为参数）========
List<int> _alignPositions(String a, String b, int maxAlignCells) {
  final int n = a.length;
  final int m = b.length;
  final List<int> map = List<int>.filled(n + 1, m);
  if (n == 0) return map;
  if (m == 0) {
    for (int i = 0; i <= n; i++) {
      map[i] = 0;
    }
    return map;
  }
  if (n * m > maxAlignCells) {
    for (int i = 0; i <= n; i++) {
      map[i] = (i * m / n).round();
    }
    return map;
  }
  final int w = m + 1;
  final List<int> dp = List<int>.filled((n + 1) * w, 0);
  for (int i = 1; i <= n; i++) {
    dp[i * w] = i;
  }
  for (int j = 1; j <= m; j++) {
    dp[j] = j;
  }
  for (int i = 1; i <= n; i++) {
    final int ca = a.codeUnitAt(i - 1);
    for (int j = 1; j <= m; j++) {
      final int sub =
          dp[(i - 1) * w + j - 1] + (ca == b.codeUnitAt(j - 1) ? 0 : 1);
      final int del = dp[(i - 1) * w + j] + 1;
      final int ins = dp[i * w + j - 1] + 1;
      dp[i * w + j] = math.min(sub, math.min(del, ins));
    }
  }
  int i = n;
  int j = m;
  while (i > 0) {
    final int cur = dp[i * w + j];
    if (j > 0 &&
        cur ==
            dp[(i - 1) * w + j - 1] +
                (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1)) {
      map[i - 1] = j - 1;
      i--;
      j--;
    } else if (cur == dp[(i - 1) * w + j] + 1) {
      map[i - 1] = j;
      i--;
    } else {
      j--;
    }
  }
  return map;
}
