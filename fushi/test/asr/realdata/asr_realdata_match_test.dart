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
///   ASR_REALDATA_SRT_REF   参照 SRT（SubPlz）；可缺省——没有参照时只报我们自己的
///                          匹配率与未命中分型（英语书通常没有 SubPlz 产物）
///   ASR_REALDATA_SRT_OURS  我们的 SRT（由 asr_transcribe_e2e_itest 产出，见 ASR_OUT）
///   ASR_REALDATA_LIMIT_MS  只比较该时间之前的 cue（裁过的音频），缺省不限
void main() {
  final String epubPath = Platform.environment['ASR_REALDATA_EPUB'] ?? '';
  final String refPath = Platform.environment['ASR_REALDATA_SRT_REF'] ?? '';
  final String oursPath = Platform.environment['ASR_REALDATA_SRT_OURS'] ?? '';
  final int limitMs =
      int.tryParse(Platform.environment['ASR_REALDATA_LIMIT_MS'] ?? '') ??
          1 << 62;
  final bool hasRef = refPath.isNotEmpty && File(refPath).existsSync();
  final bool available = epubPath.isNotEmpty &&
      oursPath.isNotEmpty &&
      File(epubPath).existsSync() &&
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

        final List<AudioCue> ref =
            hasRef ? await load(refPath) : const <AudioCue>[];
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
        String pct(MatchResult r) =>
            '${r.matchedCues}/${r.totalCues} (${(r.matchRate * 100).toStringAsFixed(1)}%)';
        MatchResult oursResult = run(ours, thresholds.first);
        for (final double th in thresholds) {
          final MatchResult o = run(ours, th);
          if (th == thresholds.first) oursResult = o;
          // ignore: avoid_print
          print(
            '[realdata] threshold=$th  '
            '${hasRef ? 'SubPlz ${pct(run(ref, th))}  ' : ''}ours ${pct(o)}',
          );
        }
        // 锚点间隙回填（导入链路经 EpubCueMatcher 门面默认启用）。
        for (final double th in thresholds) {
          final MatchResult o = EpubCueMatcher.match(
            sections: sections,
            cues: ours,
            similarityThreshold: th,
          );
          final String refPart = hasRef
              ? 'SubPlz ${pct(EpubCueMatcher.match(sections: sections, cues: ref, similarityThreshold: th))}  '
              : '';
          // ignore: avoid_print
          print('[realdata] +gapfill threshold=$th  ${refPart}ours ${pct(o)}');
          if (th == thresholds.first) oursResult = o;
        }
        // 导入链路默认 autoWindow：三档窗口探测取最高。
        for (final int w in EpubCueMatcher.defaultProbeWindows) {
          final MatchResult o = EpubSrtMatcher.match(
            sections: sections,
            cues: ours,
            searchWindow: w,
          );
          final String refPart = hasRef
              ? 'SubPlz ${(EpubSrtMatcher.match(sections: sections, cues: ref, searchWindow: w).matchRate * 100).toStringAsFixed(1)}%  '
              : '';
          // ignore: avoid_print
          print(
            '[realdata] window=$w  ${refPart}ours ${(o.matchRate * 100).toStringAsFixed(1)}%',
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
        // 失同步定位：每 500 条 cue 一桶的命中率（第一遍 Dice / 回填后），一眼看出
        // 游标从哪里开始丢。
        {
          final MatchResult raw = run(ours, thresholds.first);
          final StringBuffer b = StringBuffer();
          for (int s0 = 0; s0 < ours.length; s0 += 500) {
            final int e0 = (s0 + 500).clamp(0, ours.length);
            int hitRaw = 0;
            int hitFill = 0;
            for (int i = s0; i < e0; i++) {
              if (raw.matches[i].matched) hitRaw++;
              if (oursResult.matches[i].matched) hitFill++;
            }
            b.write(
              '\n  #$s0-$e0 (${ours[s0].startMs ~/ 60000}min) '
              'dice=${(hitRaw * 100 / (e0 - s0)).round()}% '
              'fill=${(hitFill * 100 / (e0 - s0)).round()}%',
            );
          }
          // ignore: avoid_print
          print('[realdata] buckets:$b');
        }
        // 未命中分型：对每条未命中（两侧都有已定位 cue 的），看它独占的正文间隙。
        final StringBuffer buf = StringBuffer();
        final List<int> secStarts = <int>[];
        for (final EpubSection sec in sections) {
          secStarts.add(buf.length);
          AudioTextNormalizer.appendNormalized(buf, sec.text);
        }
        final String big = buf.toString();
        int gStart(CueMatch m) => secStarts[m.sectionIndex] + m.normCharStart;
        int gEnd(CueMatch m) => secStarts[m.sectionIndex] + m.normCharEnd;
        final Map<String, int> kinds = <String, int>{};
        final List<String> samples = <String>[];
        for (int i = 0; i < ours.length; i++) {
          if (oursResult.matches[i].matched) continue;
          int l = i - 1;
          while (l >= 0 && !oursResult.matches[l].matched) {
            l--;
          }
          int r = i + 1;
          while (r < ours.length && !oursResult.matches[r].matched) {
            r++;
          }
          String kind;
          String detail = '';
          if (l < 0) {
            kind = 'no-left-anchor(片头)';
          } else if (r >= ours.length) {
            kind = 'no-right-anchor(尾)';
          } else {
            final int gs = gEnd(oursResult.matches[l]);
            final int ge = gStart(oursResult.matches[r]);
            final String nc = AudioTextNormalizer.normalize(ours[i].text);
            if (ge <= gs) {
              kind = 'gap-empty(邻句已吞)';
              final int regionStart = gStart(oursResult.matches[l]);
              final int regionEnd = gEnd(oursResult.matches[r]);
              detail =
                  'prev="${ours[l].text}"@${gStart(oursResult.matches[l])}-$gs '
                  'next="${ours[r].text}"@$ge-$regionEnd '
                  'region="${regionEnd > regionStart ? big.substring(regionStart, regionEnd) : '<<non-monotonic>>'}"';
            } else {
              final String gap = big.substring(gs, ge);
              final int run = r - l - 1;
              kind = run == 1
                  ? 'single-cue-gap ratio=${(gap.length / (nc.isEmpty ? 1 : nc.length)).toStringAsFixed(1)}'
                  : 'multi-cue-gap(run=$run)';
              final List<String> runLens = <String>[
                for (int k = l + 1; k < r; k++)
                  '${AudioTextNormalizer.normalize(ours[k].text)}(${AudioTextNormalizer.normalize(ours[k].text).length})',
              ];
              detail =
                  'gap="${gap.length > 40 ? '${gap.substring(0, 40)}…' : gap}" '
                  'run=${runLens.join('/')}';
            }
          }
          kinds[kind.split(' ').first] =
              (kinds[kind.split(' ').first] ?? 0) + 1;
          if (samples.length < 60) {
            samples.add(
              '${ours[i].startMs ~/ 1000}s [$kind] "${ours[i].text}" $detail',
            );
          }
        }
        // ASR_REALDATA_DUMP=<fromSec>-<toSec>：逐条打印该时段 cue 的命中区间，并把
        // 覆盖到的正文（含两侧 80 字）整段打出来，用来看伪锚点/边界渗入的实况。
        final String dumpSpec = Platform.environment['ASR_REALDATA_DUMP'] ?? '';
        if (dumpSpec.contains('-')) {
          final List<String> parts = dumpSpec.split('-');
          final int fromMs = int.parse(parts[0]) * 1000;
          final int toMs = int.parse(parts[1]) * 1000;
          int lo = big.length, hi = 0;
          final StringBuffer d = StringBuffer();
          for (int i = 0; i < ours.length; i++) {
            if (ours[i].startMs < fromMs || ours[i].startMs > toMs) continue;
            final CueMatch m = oursResult.matches[i];
            if (m.matched) {
              lo = lo < gStart(m) ? lo : gStart(m);
              hi = hi > gEnd(m) ? hi : gEnd(m);
            }
            d.write(
              '\n  ${ours[i].startMs ~/ 1000}s "${ours[i].text}" -> '
              '${m.matched ? '@${gStart(m)}-${gEnd(m)} "${big.substring(gStart(m), gEnd(m))}" score=${m.score.toStringAsFixed(2)}' : 'MISS'}',
            );
          }
          if (hi > lo) {
            final int a = (lo - 80).clamp(0, big.length);
            final int b = (hi + 80).clamp(0, big.length);
            d.write('\n  book[$a-$b]="${big.substring(a, b)}"');
          }
          // ignore: avoid_print
          print('[realdata] dump $dumpSpec:$d');
        }
        // ignore: avoid_print
        print('[realdata] unmatched kinds: $kinds');
        // ignore: avoid_print
        print('[realdata] unmatched samples:\n  ${samples.join('\n  ')}');
        final List<AudioCue> replaced = List<AudioCue>.of(ours);
        replaceMatchedCueTextWithBookText(
          sections: sections,
          cues: replaced,
          result: oursResult,
        );
        // ignore: avoid_print
        print(
          '[realdata] ours text→book (first 14): ${replaced.skip(9).take(14).map((AudioCue c) => c.text).join(' | ')}',
        );

        // 时间差：对我们的每条 cue，找参照里起点最近的一条（有参照时）。
        final List<int> refStarts = ref.map((AudioCue c) => c.startMs).toList()
          ..sort();
        final List<int> diffs = <int>[];
        for (final AudioCue c in hasRef ? ours : const <AudioCue>[]) {
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
    skip: available ? false : '需要 ASR_REALDATA_EPUB / _SRT_OURS 环境变量',
  );
}
