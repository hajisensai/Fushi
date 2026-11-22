/// 漫画有声成品的生成计划（纯函数）：演出稿 + OCR → 逐句「念什么、用哪个声音 / 哪段
/// 有声书、种子多少、文件叫什么」。生成端（`manga_audio_renderer.dart`）按它跑，测试
/// 直接对它断言。
///
/// 规则来源：设计 §5 / §6 / §9 与 handoff「已经踩过的坑」：
/// - 文件名按行身份 [MangaScriptLine.lineId]（页 + 块下标），不用行序号；
/// - 模型单条上限 30 秒：长台词按句末切成 ≤ [kMangaSegmentMaxChars] 字的片段，各片段
///   分别合成后拼回同一句的一个文件（片段序号进缓存键，不单独成文件）；
/// - 不挂 LoRA 的声音在 20 字以内的短句上会念两遍：生成端按
///   `irodori_voice_pack.dart` 的 `irodoriManualSeconds` 直接给定时长（唯一实现），只在
///   引擎声明支持给定时长时生效（`tts_direction.dart`）；
/// - 音源策略：有声书优先（命中的句子剪有声书）/ 只用有声书（没命中的不读）/ 只合成。
///   「不读」不是未配音：不进成品、不进未配音账本、没有自动重试。
/// - 克隆旁白（`manga_audio_narrator.dart`）：本卷有会剪的有声书片段、后端又能克隆
///   时，没单句指定声音的合成句改用旁白音色（[mangaSynthVoiceFor]）。
library;

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/tts_text_split.dart';

/// 一个合成片段的字数上限（30 秒模型上限对应的保守字数，handoff `split_long`）。
const int kMangaSegmentMaxChars = 70;

/// 把一句切成合成片段（按句末标点，单句仍超长再硬切）。
List<String> splitMangaLineSegments(String text) =>
    splitTtsTextForInputLimit(text, maxLength: kMangaSegmentMaxChars);

/// 一句成品音频的文件名（相对清单目录）。
String mangaLineFileName(String lineId) => '$lineId.m4a';

/// 一句占位静音的文件名。
String mangaPlaceholderFileName(String lineId) => '$lineId.ph.wav';

/// 单句换种子重生成的候选文件名（保留后就是这句的文件，撤回则删掉）。
String mangaCandidateFileName(String lineId, int seed) => '$lineId.s$seed.m4a';

/// 剪有声书的句子在清单 `voice` 字段里的标记（区分「合成」与「有声书片段」，也让片段
/// 区间变了能被识别出来重剪）。
const String kMangaClipVoicePrefix = 'audiobook:';

String mangaClipVoiceTag(MangaAudiobookClip clip) =>
    '$kMangaClipVoicePrefix${clip.bookKey ?? ''}#${clip.fileIndex}:'
    '${clip.startMs}-${clip.endMs}';

/// 换上本地音频的句子在清单 `voice` 字段里的标记（带内容指纹：换了另一段音频就能被
/// 识别出来重新整形）。
const String kMangaLocalVoicePrefix = 'file:';

String mangaLocalVoiceTag(MangaLocalAudio audio) =>
    '$kMangaLocalVoicePrefix${audio.sig}';

/// 换上本地音频后这句的成品文件名（带内容指纹：与原文件不同名，原文件留到清单不再
/// 引用时才清，撤销据此认出「还是这次换上的音频」）。
String mangaLocalLineFileName(String lineId, MangaLocalAudio audio) =>
    '$lineId.f${audio.sig}.m4a';

/// 本地音频保留副本的绝对路径（成品目录 [directory] 下的 [kMangaLocalAudioDirName]）。
String mangaLocalAudioSourcePath(String directory, MangaLocalAudio audio) =>
    p.join(directory, kMangaLocalAudioDirName, '${audio.sig}${audio.ext}');

/// 一句的音源（计划层）。
sealed class MangaRenderSource {
  const MangaRenderSource();
}

/// 合成：[voice] 是解析后的声音预设 id（已把「当前朗读声音」落成具体 id）。
final class MangaRenderSynth extends MangaRenderSource {
  const MangaRenderSynth({
    required this.voice,
    required this.seed,
    required this.segments,
  });

  final String voice;
  final int seed;

  /// 合成片段（空 = 没有可念的文字）。
  final List<String> segments;
}

/// 剪关联有声书的一段。
final class MangaRenderClip extends MangaRenderSource {
  const MangaRenderClip(this.clip);

  final MangaAudiobookClip clip;
}

/// 整形用户换上的本地音频（[MangaLocalAudio]）。
final class MangaRenderLocal extends MangaRenderSource {
  const MangaRenderLocal(this.audio);

  final MangaLocalAudio audio;
}

/// 计划里的一句。
class MangaRenderItem {
  const MangaRenderItem({
    required this.line,
    required this.text,
    required this.source,
  });

  final MangaScriptLine line;

  /// 要念的文字（手填 `say` 优先，否则 OCR 拼出来的）。
  final String text;
  final MangaRenderSource source;

  String get lineId => line.lineId;

  /// 写进清单 `voice` 的值（合成 = 声音 id；有声书 = [mangaClipVoiceTag]）。
  String get voiceTag => switch (source) {
    MangaRenderSynth(:final String voice) => voice,
    MangaRenderClip(:final MangaAudiobookClip clip) => mangaClipVoiceTag(clip),
    MangaRenderLocal(:final MangaLocalAudio audio) => mangaLocalVoiceTag(audio),
  };

  /// 写进清单 `seed` 的值（有声书片段没有种子）。
  int? get seed => switch (source) {
    MangaRenderSynth(:final int seed) => seed,
    MangaRenderClip() || MangaRenderLocal() => null,
  };

  /// 账本里记的「指派的声音」（有声书片段记 null）。
  String? get assignedVoice => switch (source) {
    MangaRenderSynth(:final String voice) => voice,
    MangaRenderClip() || MangaRenderLocal() => null,
  };

  /// 由这句生成清单行（文件 / 时长 / 是否占位 / 整形版本由生成端给；占位静音不整形，
  /// [shape] 传 null）。
  MangaRenderedLine rendered({
    required String file,
    required int durationMs,
    required String? shape,
    bool placeholder = false,
  }) => MangaRenderedLine(
    lineId: lineId,
    page: line.page,
    blocks: line.blocks,
    speaker: line.speaker,
    kind: line.kind,
    beatMs: line.beatMs,
    file: file,
    durationMs: durationMs,
    text: text,
    placeholder: placeholder,
    voice: voiceTag,
    seed: seed,
    shape: shape,
  );

  /// [old] 的音频能不能原样沿用：不是占位、念的文字 / 声音 / 种子都没变，且出音频时的
  /// 整形版本就是这次的 [shape]（`MangaRenderBackend.shapeVersion`）。整形参数（裁静音 /
  /// 淡变 / 响度）变了，旧音频与新出的句子混排会忽大忽小，必须重出；没记整形版本的历史
  /// 清单行（null）一律算版本不符。说话人、类型、一拍这类不影响音频的字段变了照样沿用
  /// （清单行按新值重建）。
  bool canReuse(MangaRenderedLine old, {required String shape}) =>
      !old.placeholder &&
      old.lineId == lineId &&
      old.text == text &&
      old.voice == voiceTag &&
      old.seed == seed &&
      old.shape == shape;
}

/// 一卷的生成计划。
class MangaRenderPlan {
  const MangaRenderPlan({
    required this.items,
    required this.notRead,
    this.outOfRange = const <String>[],
  });

  /// 要进成品的句子，按阅读顺序。
  final List<MangaRenderItem> items;

  /// 按音源策略不读的句子（只用有声书、而这句没命中）。
  final List<String> notRead;

  /// 页码超出 OCR 页数的句子（演出稿与 OCR 对不上；正常情况下签名判定会先拦住）。
  /// 不进成品——清单要求行页码在页数之内。
  final List<String> outOfRange;

  Set<String> get lineIds => <String>{
    for (final MangaRenderItem i in items) i.lineId,
  };
}

/// 一句该用的声音 id：单句指定 → 本卷叠系列的指派表 → [defaultVoice]（当前朗读声音）。
String mangaResolvedVoice(
  MangaAudioScript script,
  MangaScriptLine line,
  String defaultVoice,
) => script.voiceFor(line) ?? defaultVoice;

/// 一句合成时实际用的声音：本卷在克隆旁白（[narrator] 非空）且这句没单句指定声音 →
/// 旁白；否则同 [mangaResolvedVoice]。整卷生成、补回、换种子重生成都只认这一个函数。
String mangaSynthVoiceFor(
  MangaAudioScript script,
  MangaScriptLine line,
  String defaultVoice,
  MangaNarratorVoice? narrator,
) => narrator != null && line.voice == null
    ? narrator.id
    : mangaResolvedVoice(script, line, defaultVoice);

/// 这句怎么出声；null = 不读。出声方式只认 [MangaAudioScript.audioPlanFor]（用户亲手
/// 定的音源 → 作品音源策略）；有声书片段在这里落成具体的书（旧行没有 `k` 时取第一本
/// 关联书，见 [MangaAudioScript.clipBookKey]），生成端按 `bookKey` + `fileIndex` 取
/// 那本书 `audioFilesInCueOrder` 里的文件。
MangaRenderSource? mangaRenderSourceFor({
  required MangaAudioScript script,
  required MangaScriptLine line,
  required String text,
  required String defaultVoice,
  MangaNarratorVoice? narrator,
}) {
  switch (script.audioPlanFor(line)) {
    case MangaLineAudioPlan.silent:
      return null;
    case MangaLineAudioPlan.audiobookClip:
      final MangaAudiobookClip clip = line.audio as MangaAudiobookClip;
      return MangaRenderClip(
        MangaAudiobookClip(
          bookKey: script.clipBookKey(clip),
          fileIndex: clip.fileIndex,
          startMs: clip.startMs,
          endMs: clip.endMs,
          byUser: clip.byUser,
        ),
      );
    case MangaLineAudioPlan.localAudio:
      return MangaRenderLocal(line.audio as MangaLocalAudio);
    case MangaLineAudioPlan.synthesize:
      return MangaRenderSynth(
        voice: mangaSynthVoiceFor(script, line, defaultVoice, narrator),
        seed: line.effectiveSeed(script.defaultSeed),
        segments: splitMangaLineSegments(text),
      );
  }
}

/// 整卷计划：「不读」类型的行不进计划；其余按音源策略分成合成 / 有声书片段 / 不读。
/// [pageBlocks] 是 OCR 的逐页块（`MokuroPayload.images[i].blocks`），其长度就是页数。
/// 没有可念文字的行照样进计划（生成端记成未配音，可以手动填写补回）。[narrator] 是
/// 后端已准备好的旁白声音（null = 不克隆）。
MangaRenderPlan planMangaRender({
  required MangaAudioScript script,
  required List<List<MokuroBlock>> pageBlocks,
  required String defaultVoice,
  MangaNarratorVoice? narrator,
}) {
  final List<MangaRenderItem> items = <MangaRenderItem>[];
  final List<String> notRead = <String>[];
  final List<String> outOfRange = <String>[];
  for (final MangaScriptLine line in script.lines) {
    if (!line.kind.isAudible) continue;
    if (line.page >= pageBlocks.length) {
      outOfRange.add(line.lineId);
      continue;
    }
    final String text = mangaLineText(
      line,
      pageBlocks,
      substitutions: script.substitutions,
    );
    final MangaRenderSource? source = mangaRenderSourceFor(
      script: script,
      line: line,
      text: text,
      defaultVoice: defaultVoice,
      narrator: narrator,
    );
    if (source == null) {
      notRead.add(line.lineId);
      continue;
    }
    items.add(MangaRenderItem(line: line, text: text, source: source));
  }
  return MangaRenderPlan(
    items: items,
    notRead: notRead,
    outOfRange: outOfRange,
  );
}

/// 一句要念的文字（页码越界时只认手填）。
String mangaLineText(
  MangaScriptLine line,
  List<List<MokuroBlock>> pageBlocks, {
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
}) {
  final String? say = line.say;
  // 手动填写的念法是用户写好的最终文字：不过替换表。
  if (say != null) return say.trim();
  return applyCastSubstitutions(
    resolveMangaLineText(
      line,
      line.page < pageBlocks.length
          ? pageBlocks[line.page]
          : const <MokuroBlock>[],
    ).trim(),
    substitutions,
  );
}
