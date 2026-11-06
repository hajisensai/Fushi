import 'package:fushi_audio/fushi_audio.dart';

/// 匹配结果的逐位序列化（对拍夹具用）：`总数/命中数|` 后每条 cue 一段
/// `cueSentenceIndex,sectionIndex,normCharStart,normCharEnd,score`，`;` 分隔；
/// [CueMatch.unmatched] 记作 `-`。`score` 用 Dart 的最短往返十进制表示，字符串相等
/// 即 double 逐位相等。
String encodeMatchResultForGolden(MatchResult r) {
  final StringBuffer b = StringBuffer()
    ..write(r.totalCues)
    ..write('/')
    ..write(r.matchedCues)
    ..write('|');
  for (int i = 0; i < r.matches.length; i++) {
    final CueMatch m = r.matches[i];
    if (i > 0) b.write(';');
    if (m.cueSentenceIndex == -1 &&
        m.sectionIndex == -1 &&
        m.normCharStart == -1 &&
        m.normCharEnd == -1 &&
        m.score == 0) {
      b.write('-');
      continue;
    }
    b
      ..write(m.cueSentenceIndex)
      ..write(',')
      ..write(m.sectionIndex)
      ..write(',')
      ..write(m.normCharStart)
      ..write(',')
      ..write(m.normCharEnd)
      ..write(',')
      ..write(m.score);
  }
  return b.toString();
}
