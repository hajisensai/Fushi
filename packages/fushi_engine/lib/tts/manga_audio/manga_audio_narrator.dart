/// 克隆旁白：一卷里既有剪自关联有声书的句子、又有合成的句子时，合成句改用**那本
/// 有声书旁白的音色**（Irodori 参考音频克隆），免得同一个角色这句是真人旁白、下句
/// 是另一副 TTS 嗓子。
///
/// 规则：
/// - 参考音频只从本卷**实际会剪的有声书片段**里挑（[MangaAudioScript.audioPlanFor]
///   落成片段的会发声的行），不另外扫书；
/// - 只取一本书的片段（片段最多的那本，并列取先出现的），时长在
///   [kMangaNarratorRefMinMs, kMangaNarratorRefMaxMs] 之间，按时长从长到短取至多
///   [kMangaNarratorMaxRefs] 段，再按阅读顺序排（结果确定，缓存键稳定）；
/// - 一卷没有合格片段 = 不克隆（合成句照旧用各自指派的声音）；
/// - 单句指定了声音（[MangaScriptLine.voice]）的句子不改，其余合成句一律用旁白音色
///   （见 `manga_audio_render_plan.dart` 的 [mangaSynthVoiceFor]）。
///
/// 后端能不能克隆、怎么把片段做成参考音频，见 `MangaRenderBackend.canCloneNarrator`
/// / `prepareNarrator`；声音身份 [MangaNarratorVoice.id] 只由参考片段决定，片段变了
/// 声音 id 跟着变，清单里用旧旁白出的句子就会重出。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;

import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';

/// 旁白声音 id 的前缀（`narrator:<参考片段摘要>`）。
const String kMangaNarratorVoicePrefix = 'narrator:';

/// 参考片段的时长下限（太短的片段音色信息不够）。
const int kMangaNarratorRefMinMs = 2500;

/// 参考片段的时长上限（太长的 cue 常常夹着别的句子 / 停顿）。
const int kMangaNarratorRefMaxMs = 12000;

/// 至多取几段参考片段。
const int kMangaNarratorMaxRefs = 3;

/// 一卷的旁白声音：[refs] 是挑出的参考片段（已落成具体的书），[id] 是声音 id。
class MangaNarratorVoice {
  MangaNarratorVoice(List<MangaAudiobookClip> refs)
    : assert(refs.isNotEmpty, 'narrator needs at least one reference'),
      refs = List<MangaAudiobookClip>.unmodifiable(refs),
      id = mangaNarratorVoiceId(refs);

  final List<MangaAudiobookClip> refs;
  final String id;
}

/// 一段参考片段的稳定名字（参考音频文件名用）。
String mangaNarratorRefName(MangaAudiobookClip clip) => sha1
    .convert(
      utf8.encode(
        '${clip.bookKey ?? ''}#${clip.fileIndex}:${clip.startMs}-${clip.endMs}',
      ),
    )
    .toString()
    .substring(0, 16);

/// 由参考片段算出的声音 id。
String mangaNarratorVoiceId(List<MangaAudiobookClip> refs) =>
    '$kMangaNarratorVoicePrefix'
    '${sha1.convert(utf8.encode(refs.map(mangaNarratorRefName).join('|'))).toString().substring(0, 16)}';

bool isMangaNarratorVoice(String voice) =>
    voice.startsWith(kMangaNarratorVoicePrefix);

/// 从 [clips]（阅读顺序）里挑参考片段；没有合格的返回空表。纯函数。
List<MangaAudiobookClip> pickMangaNarratorRefs(List<MangaAudiobookClip> clips) {
  final List<(int, MangaAudiobookClip)> eligible = <(int, MangaAudiobookClip)>[
    for (int i = 0; i < clips.length; i++)
      if (clips[i].durationMs >= kMangaNarratorRefMinMs &&
          clips[i].durationMs <= kMangaNarratorRefMaxMs)
        (i, clips[i]),
  ];
  if (eligible.isEmpty) return const <MangaAudiobookClip>[];
  final Map<String, int> counts = <String, int>{};
  final List<String> order = <String>[];
  for (final (int, MangaAudiobookClip) e in eligible) {
    final String key = e.$2.bookKey ?? '';
    if (!counts.containsKey(key)) order.add(key);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  String book = order.first;
  for (final String key in order) {
    if (counts[key]! > counts[book]!) book = key;
  }
  final List<(int, MangaAudiobookClip)> fromBook =
      <(int, MangaAudiobookClip)>[
        for (final (int, MangaAudiobookClip) e in eligible)
          if ((e.$2.bookKey ?? '') == book) e,
      ]..sort(((int, MangaAudiobookClip) a, (int, MangaAudiobookClip) b) {
        final int byLength = b.$2.durationMs.compareTo(a.$2.durationMs);
        return byLength != 0 ? byLength : a.$1.compareTo(b.$1);
      });
  final List<(int, MangaAudiobookClip)> picked =
      fromBook.take(kMangaNarratorMaxRefs).toList()..sort(
        ((int, MangaAudiobookClip) a, (int, MangaAudiobookClip) b) =>
            a.$1.compareTo(b.$1),
      );
  return <MangaAudiobookClip>[
    for (final (int, MangaAudiobookClip) e in picked) e.$2,
  ];
}

/// 本卷的旁白声音；本卷没有会剪的有声书片段、或片段都不合格时返回 null。
/// [pageCount] 是 OCR 页数（越界的行不进成品，也不当参考）。
MangaNarratorVoice? mangaNarratorFor({
  required MangaAudioScript script,
  required int pageCount,
}) {
  final List<MangaAudiobookClip> clips = <MangaAudiobookClip>[
    for (final MangaScriptLine line in script.lines)
      if (line.kind.isAudible &&
          line.page < pageCount &&
          script.audioPlanFor(line) == MangaLineAudioPlan.audiobookClip)
        switch (line.audio) {
          final MangaAudiobookClip clip => MangaAudiobookClip(
            bookKey: script.clipBookKey(clip),
            fileIndex: clip.fileIndex,
            startMs: clip.startMs,
            endMs: clip.endMs,
          ),
          _ => throw StateError('audiobookClip plan without a clip'),
        },
  ];
  final List<MangaAudiobookClip> refs = pickMangaNarratorRefs(clips);
  return refs.isEmpty ? null : MangaNarratorVoice(refs);
}
