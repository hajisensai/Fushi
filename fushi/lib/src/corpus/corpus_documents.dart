import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_music/fushi_music.dart' show LyricLine, LyricTimeline;

/// 曲库歌词搜索的语料文档构造（纯函数，后台 isolate 里也能跑）。
///
/// 定位字段：音乐 = 毫秒（见 [CorpusSourceKind.music]）。

/// 内容指纹：64 位 FNV-1a（十六进制）。只用来判「来源变没变」，不是安全用途。
String corpusFingerprint(Iterable<Object?> parts) {
  int h = 0xcbf29ce484222325;
  void feed(int byte) {
    h ^= byte & 0xFF;
    // Dart VM 的 int 是 64 位、乘法按二进制补码回绕，正是 FNV 要的 mod 2^64。
    h *= 0x100000001b3;
  }

  for (final Object? part in parts) {
    for (final int unit in '$part'.codeUnits) {
      feed(unit);
      feed(unit >> 8);
    }
    feed(0x1f);
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// 歌词行的展示文本：换行压成空格（一行就是一句）。
String _oneLine(String text) =>
    text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();

/// 一首歌的歌词 → 文档。时间按 [LyricTimeline.offsetMs]（正 = 歌词提前）折算回音频时间，
/// 背景和声行跳过（主唱行已经覆盖同一段时间）。
CorpusDocument lyricsDocument({
  required String trackUid,
  required String title,
  required LyricTimeline timeline,
  required String normalizer,
  required int updatedAt,
  String? fingerprint,
}) {
  final List<CorpusSentence> sentences = <CorpusSentence>[];
  for (final LyricLine line in timeline.lines) {
    if (line.isBackground) continue;
    final String text = _oneLine(line.text);
    if (text.isEmpty) continue;
    final int start = line.startMs - timeline.offsetMs;
    sentences.add(
      CorpusSentence(
        section: 0,
        pos: start < 0 ? 0 : start,
        len: line.endMs > line.startMs ? line.endMs - line.startMs : 0,
        text: text,
      ),
    );
  }
  return CorpusDocument(
    kind: CorpusSourceKind.music,
    key: trackUid,
    part: -1,
    title: title,
    // 调用方给了来源侧的指纹（音乐对账用歌词行元数据）就用它，否则按内容算。
    fingerprint:
        fingerprint ??
        corpusFingerprint(<Object?>[
          timeline.offsetMs,
          for (final CorpusSentence s in sentences) ...<Object?>[s.pos, s.text],
        ]),
    normalizer: normalizer,
    updatedAt: updatedAt,
    sentences: sentences,
  );
}
