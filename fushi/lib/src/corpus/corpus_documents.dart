import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_corpus/fushi_corpus.dart';
import 'package:fushi_engine/stats/study_char_count.dart';
import 'package:fushi_music/fushi_music.dart' show LyricLine, LyricTimeline;

/// 「我库里的例句」各模块的文档构造（纯函数，后台 isolate 里也能跑）。
///
/// 定位字段的语义按 [CorpusSourceKind] 各值的注释：书 = 章 + 章内学习单位（阅读器
/// `charAnchor` 同一把尺子），视频 / 音乐 = 毫秒，游戏 = 收到台词的时刻。

/// 单句上限（UTF-16 码元）：更长的段落在逗号处 / 硬切再拆。只影响例句的长度，
/// 不丢内容（每一段都进索引）。
const int kCorpusMaxSentenceUnits = 240;

/// 一章正文 → 句子：切句在 Rust（`fcorp_split`），起止换算成学习单位前缀一次 FFI
/// （`studyCharPrefixTotals`）。一章两次 FFI，不逐句跨边界。
List<CorpusSentence> bookChapterSentences(int chapterIndex, String text) {
  final List<({int start, int end})> spans = splitCorpusSentences(
    text,
    maxUnits: kCorpusMaxSentenceUnits,
  );
  if (spans.isEmpty) return const <CorpusSentence>[];
  final List<int> offsets = <int>[
    for (final ({int start, int end}) s in spans) ...<int>[s.start, s.end],
  ];
  final List<int> units = studyCharPrefixTotals(text, offsets);
  return <CorpusSentence>[
    for (int i = 0; i < spans.length; i++)
      CorpusSentence(
        section: chapterIndex,
        pos: units[2 * i],
        len: units[2 * i + 1] - units[2 * i],
        text: text.substring(spans[i].start, spans[i].end),
      ),
  ];
}

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

/// 字幕行的展示文本：换行压成空格（一条 cue 就是一句）。
String _oneLine(String text) =>
    text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();

/// 一集字幕 → 文档。key = `bookUid`，part = section = 集下标（单视频 0）。
/// 纯绘图 cue（ASS 矢量、无文本）与空行跳过。
CorpusDocument videoCuesDocument({
  required String bookUid,
  required int episodeIndex,
  required String title,
  required List<AudioCue> cues,
  required String normalizer,
  required int updatedAt,
}) {
  final List<CorpusSentence> sentences = <CorpusSentence>[];
  for (final AudioCue cue in cues) {
    if (cue.isRenderOnly) continue;
    final String text = _oneLine(cue.text);
    if (text.isEmpty) continue;
    sentences.add(
      CorpusSentence(
        section: episodeIndex,
        pos: cue.startMs,
        len: cue.endMs > cue.startMs ? cue.endMs - cue.startMs : 0,
        text: text,
      ),
    );
  }
  return CorpusDocument(
    kind: CorpusSourceKind.video,
    key: bookUid,
    part: episodeIndex,
    title: title,
    fingerprint: corpusFingerprint(<Object?>[
      for (final CorpusSentence s in sentences) ...<Object?>[s.pos, s.text],
    ]),
    normalizer: normalizer,
    updatedAt: updatedAt,
    sentences: sentences,
  );
}

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

/// 一本书的指纹：只用元数据（读正文要解压解析整本书，太贵）。重新导入 / 换文件
/// 都会改 importedAt 或章数。
String bookFingerprint({
  required String uid,
  required int importedAt,
  required int chapterCount,
  required String extractDir,
}) => corpusFingerprint(<Object?>[uid, importedAt, chapterCount, extractDir]);

/// 游戏台词块文档的指纹前缀：v130 起游戏文档由 `galgame_text_lines` 派生，指纹带这个
/// 前缀；没有它的是 L4 首版直接存在语料里的台词（迁移时读回进表）。
const String kGameChunkFingerprintPrefix = 'db:';

/// 一块游戏台词的指纹（只增不改的表：行数 + 最大 id 不变，内容就不变）。
String gameChunkFingerprint({required int count, required int maxId}) =>
    '$kGameChunkFingerprintPrefix$count:$maxId';

/// 游戏台词块 → 文档。pos = 第一次收到台词的时刻（毫秒时间戳），len = 0。
CorpusDocument gameLinesDocument({
  required String gameId,
  required String title,
  required int part,
  required List<({String text, int atMs})> lines,
  required String normalizer,
  required int updatedAt,
  String? fingerprint,
}) {
  final List<CorpusSentence> sentences = <CorpusSentence>[
    for (final ({String text, int atMs}) line in lines)
      if (_oneLine(line.text).isNotEmpty)
        CorpusSentence(
          section: 0,
          pos: line.atMs,
          len: 0,
          text: _oneLine(line.text),
        ),
  ];
  return CorpusDocument(
    kind: CorpusSourceKind.game,
    key: gameId,
    part: part,
    title: title,
    fingerprint:
        fingerprint ??
        corpusFingerprint(<Object?>[
          for (final CorpusSentence s in sentences) ...<Object?>[s.pos, s.text],
        ]),
    normalizer: normalizer,
    updatedAt: updatedAt,
    sentences: sentences,
  );
}

/// 换一个归一口径（[CorpusDocument.normalizer]）的同一份文档。
CorpusDocument withNormalizer(CorpusDocument doc, String normalizer) =>
    CorpusDocument(
      kind: doc.kind,
      key: doc.key,
      part: doc.part,
      title: doc.title,
      fingerprint: doc.fingerprint,
      normalizer: normalizer,
      updatedAt: doc.updatedAt,
      sentences: doc.sentences,
    );
