@Tags(<String>['realdata'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 真实数据对照（不入 CI，缺环境变量自动 skip）：
///
/// 把「我们转录出来的 SRT」与「SubPlz 生成的 SRT」分别对同一本 EPUB 跑既有的
/// Dice 匹配器，打印匹配率；再按起点时间把两份 cue 就近配对，打印时间差分布。
/// 这是回答「质量有没有超过 SubPlz」唯一可信的量具——匹配率是阅读器真正消费的
/// 指标，时间差是 cue 边界准不准。
///
///   ASR_REALDATA_EPUB      EPUB 路径
///   ASR_REALDATA_SRT_REF   参照 SRT（SubPlz）
///   ASR_REALDATA_SRT_OURS  我们的 SRT（由 asr_transcribe_e2e_itest 产出，见 ASR_OUT）
///   ASR_REALDATA_LIMIT_MS  只比较该时间之前的 cue（裁过的音频），缺省不限
void main() {
  final String epubPath = Platform.environment['ASR_REALDATA_EPUB'] ?? '';
  final String refPath = Platform.environment['ASR_REALDATA_SRT_REF'] ?? '';
  final String oursPath = Platform.environment['ASR_REALDATA_SRT_OURS'] ?? '';
  final int limitMs =
      int.tryParse(Platform.environment['ASR_REALDATA_LIMIT_MS'] ?? '') ??
      1 << 62;
  final bool available =
      epubPath.isNotEmpty &&
      refPath.isNotEmpty &&
      oursPath.isNotEmpty &&
      File(epubPath).existsSync() &&
      File(refPath).existsSync() &&
      File(oursPath).existsSync();

  test(
    '我们的 SRT 与 SubPlz SRT 对同一 EPUB 的匹配率与时间差',
    () async {
      final Directory extract = await Directory.systemTemp.createTemp(
        'asr_realdata_epub_',
      );
      try {
        final EpubBook book = EpubParser.parseSyncFromPath(
          epubPath,
          extract.path,
        );
        final List<EpubSection> sections = List<EpubSection>.generate(
          book.chapters.length,
          (int i) => EpubSection(
            index: i,
            href: book.chapters[i].href,
            text: book.chapterPlainText(i),
          ),
        );
        final int bookChars = sections.fold<int>(
          0,
          (int a, EpubSection s) => a + s.text.length,
        );
        // ignore: avoid_print
        print('[realdata] epub sections=${sections.length} chars=$bookChars');

        Future<List<AudioCue>> load(String path) async {
          final List<AudioCue> cues = await SrtParser.parse(
            srtFile: File(path),
            bookKey: 'realdata',
          );
          return cues.where((AudioCue c) => c.startMs < limitMs).toList();
        }

        final List<AudioCue> ref = await load(refPath);
        final List<AudioCue> ours = await load(oursPath);

        final List<double> thresholds =
            (Platform.environment['ASR_REALDATA_THRESHOLDS'] ?? '0.8')
                .split(',')
                .map((String v) => double.parse(v.trim()))
                .toList();
        MatchResult run(List<AudioCue> cues, double threshold) =>
            EpubSrtMatcher.match(
              sections: sections,
              cues: cues,
              similarityThreshold: threshold,
            );
        MatchResult oursResult = run(ours, thresholds.first);
        for (final double th in thresholds) {
          final MatchResult r = run(ref, th);
          final MatchResult o = run(ours, th);
          if (th == thresholds.first) oursResult = o;
          // ignore: avoid_print
          print(
            '[realdata] threshold=$th  SubPlz ${r.matchedCues}/${r.totalCues} '
            '(${(r.matchRate * 100).toStringAsFixed(1)}%)  ours ${o.matchedCues}/${o.totalCues} '
            '(${(o.matchRate * 100).toStringAsFixed(1)}%)',
          );
        }
        // 导入链路默认 autoWindow：三档窗口探测取最高。
        for (final int w in EpubCueMatcher.defaultProbeWindows) {
          final MatchResult r = EpubSrtMatcher.match(
            sections: sections,
            cues: ref,
            searchWindow: w,
          );
          final MatchResult o = EpubSrtMatcher.match(
            sections: sections,
            cues: ours,
            searchWindow: w,
          );
          // ignore: avoid_print
          print(
            '[realdata] window=$w  SubPlz ${(r.matchRate * 100).toStringAsFixed(1)}%  '
            'ours ${(o.matchRate * 100).toStringAsFixed(1)}%',
          );
        }
        // 前 30 条逐条：命中章节 / 归一化偏移 / 分数（看游标怎么走的）。
        final Map<int, CueMatch> byCue = <int, CueMatch>{
          for (final CueMatch m in oursResult.matches) m.cueSentenceIndex: m,
        };
        final StringBuffer trace = StringBuffer();
        for (final AudioCue c in ours.take(30)) {
          final CueMatch? m = byCue[c.sentenceIndex];
          trace.write(
            '\n  #${c.sentenceIndex} ${c.startMs ~/ 1000}s ${c.text} -> '
            '${m == null || m.sectionIndex < 0 ? 'MISS' : 's${m.sectionIndex}@${m.normCharStart}-${m.normCharEnd} score=${m.score.toStringAsFixed(2)}'}',
          );
        }
        // ignore: avoid_print
        print('[realdata] ours trace:$trace');
        // 未命中的 cue 长什么样（默认阈值）。
        final Set<int> hit = oursResult.matches
            .where((CueMatch m) => m.sectionIndex >= 0)
            .map((CueMatch m) => m.cueSentenceIndex)
            .toSet();
        final List<String> misses = <String>[];
        for (final AudioCue c in ours) {
          if (!hit.contains(c.sentenceIndex)) {
            misses.add('${c.startMs ~/ 1000}s ${c.text}');
          }
        }
        // ignore: avoid_print
        print(
          '[realdata] ours unmatched (${misses.length}): ${misses.take(40).join(' | ')}',
        );

        // 时间差：对我们的每条 cue，找参照里起点最近的一条。
        final List<int> refStarts = ref.map((AudioCue c) => c.startMs).toList()
          ..sort();
        final List<int> diffs = <int>[];
        for (final AudioCue c in ours) {
          int lo = 0, hi = refStarts.length;
          while (lo < hi) {
            final int mid = (lo + hi) >> 1;
            if (refStarts[mid] < c.startMs) {
              lo = mid + 1;
            } else {
              hi = mid;
            }
          }
          int best = 1 << 30;
          for (final int k in <int>[lo - 1, lo]) {
            if (k >= 0 && k < refStarts.length) {
              final int d = (refStarts[k] - c.startMs).abs();
              if (d < best) best = d;
            }
          }
          if (best < (1 << 30)) diffs.add(best);
        }
        diffs.sort();
        if (diffs.isNotEmpty) {
          int pct(int p) => diffs[(diffs.length - 1) * p ~/ 100];
          // ignore: avoid_print
          print(
            '[realdata] start-time |Δ| vs SubPlz: p50=${pct(50)}ms p80=${pct(80)}ms '
            'p95=${pct(95)}ms max=${diffs.last}ms (n=${diffs.length})',
          );
        }
        // ignore: avoid_print
        print(
          '[realdata] ours first cues: ${ours.take(8).map((AudioCue c) => '${c.startMs}-${c.endMs} ${c.text}').join(' | ')}',
        );
        expect(oursResult.totalCues, greaterThan(0));
      } finally {
        if (extract.existsSync()) await extract.delete(recursive: true);
      }
    },
    skip: available
        ? false
        : '需要 ASR_REALDATA_EPUB / _SRT_REF / _SRT_OURS 环境变量',
  );
}
