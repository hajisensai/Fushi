import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';

/// 给没有 token 时间的 cue 补上确定性的逐 token 时间：按 UTF-16 码元切 1–3 个一组
/// （不切开代理对），偏移在 cue 时长里线性摊开。重切器的输入因此与设备端转录产物同形，
/// 模糊命中（听写 ≠ 正文）的 cue 会走编辑距离位置对齐。
List<AudioCue> withSyntheticTokens(List<AudioCue> cues) {
  final List<AudioCue> out = <AudioCue>[];
  for (int c = 0; c < cues.length; c++) {
    final AudioCue src = cues[c];
    final String text = src.text;
    final List<String> tokens = <String>[];
    int i = 0;
    int salt = c * 7 + 3;
    while (i < text.length) {
      int len = 1 + salt % 3;
      salt = (salt * 1103515245 + 12345) & 0x7fffffff;
      if (i + len > text.length) len = text.length - i;
      final int last = text.codeUnitAt(i + len - 1);
      if (last >= 0xD800 && last <= 0xDBFF && i + len < text.length) len++;
      tokens.add(text.substring(i, i + len));
      i += len;
    }
    final int dur = src.endMs - src.startMs;
    final AudioCue cue = AudioCue()
      ..bookKey = src.bookKey
      ..chapterHref = src.chapterHref
      ..sentenceIndex = src.sentenceIndex
      ..textFragmentId = src.textFragmentId
      ..text = src.text
      ..startMs = src.startMs
      ..endMs = src.endMs
      ..audioFileIndex = src.audioFileIndex
      ..tokenTiming = tokens.isEmpty
          ? null
          : CueTokenTiming(
              tokens: tokens,
              offsetsMs: <int>[
                for (int k = 0; k < tokens.length; k++)
                  dur <= 0 ? 0 : (k * dur) ~/ tokens.length,
              ],
            );
    out.add(cue);
  }
  return out;
}

/// 重切结果的规范文本：每条 cue 一行（起止、文本、token 偏移、匹配区间与分数），末行 stats。
String describeResegment(CueResegmentResult r) {
  final StringBuffer out = StringBuffer();
  for (int k = 0; k < r.cues.length; k++) {
    final AudioCue c = r.cues[k];
    final CueMatch m = r.result.matches[k];
    out
      ..write(c.sentenceIndex)
      ..write('\t')
      ..write(c.startMs)
      ..write('\t')
      ..write(c.endMs)
      ..write('\t')
      ..write(jsonEncode(c.text))
      ..write('\t')
      ..write(c.tokenTiming?.offsetsMs.join(',') ?? '-')
      ..write('\t')
      ..write(
        m.matched
            ? '${m.sectionIndex}:${m.normCharStart}-${m.normCharEnd}@${m.score}'
            : 'unmatched',
      )
      ..write('\n');
  }
  out.write(
    '${r.stats} matched=${r.result.matchedCues}/${r.result.totalCues}\n',
  );
  return out.toString();
}

/// realdata 夹具（`<名>.sections.json`）→ EPUB 章节。
List<EpubSection> readRealdataSections(String path) {
  final List<dynamic> js =
      jsonDecode(File(path).readAsStringSync()) as List<dynamic>;
  return <EpubSection>[
    for (final dynamic x in js)
      EpubSection(
        index: x['i'] as int,
        href: x['h'] as String,
        text: x['t'] as String,
        rubies: <EpubRubySpan>[
          for (final dynamic r in x['r'] as List<dynamic>)
            EpubRubySpan(
              start: r[0] as int,
              end: r[1] as int,
              reading: r[2] as String,
            ),
        ],
      ),
  ];
}
