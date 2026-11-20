/// 朗读会话的两件纯计算：多声优的声音分派、提前生成的范围。
///
/// - **多声优**：书在制作台标过说话人、给角色配过声音（选角表 [TtsCast]，含系列里
///   记住的声音与单句指定的声音）时，实时朗读按句换声音。句子先归到「声音槽」：槽 =
///   这句解析出的声音预设 id（[TtsCast.presetFor]：单句 → 角色本书 → 系列），解析不到
///   的（旁白、没配声音的角色、没标注的句子）归默认槽，用会话当前的朗读声音。同一份
///   预设只建一个引擎实例、共用一个并发上限（与制作台同口径）。
/// - **提前生成**：朗读一开始就把当前章剩余部分与下一章排进合成队列（播放器从缓存读），
///   不只是播放位置之后几十秒。合成比听得快时缓冲越攒越多，倍速 / 网络抖动不再断。
library;

import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// 默认声音槽（会话当前的朗读声音）。
const String kTtsDefaultVoiceSlot = '';

/// 一份可用的声音：预设 + 它的引擎。
typedef TtsResolvedVoice = ({
  TtsVoicePreset preset,
  TtsProviderDescriptor descriptor,
});

/// [sentence] 归哪个声音槽：选角表给这句解析出声音 → 那份预设 id；否则默认槽。
/// [cast] 为 null（单声音朗读）时一律默认槽。
String ttsVoiceSlotOf(TtsCast? cast, TtsPlanSentence sentence) {
  if (cast == null) return kTtsDefaultVoiceSlot;
  final String? presetId = cast.presetFor(
    sentence.section,
    sentence.matchStart,
  );
  return presetId == null || presetId.isEmpty ? kTtsDefaultVoiceSlot : presetId;
}

/// 选角表里有没有任何一层给过声音（本书角色、系列、单句）。没有就按单声音朗读。
bool ttsCastAssignsVoices(TtsCast cast) {
  if (cast.voices.values.any((String v) => v.isNotEmpty)) return true;
  if (cast.lines.values.any((TtsCastLine l) => l.voice != null)) return true;
  final CastVoiceAssignment? series = cast.series;
  return series != null &&
      (series.narrationVoice != null ||
          series.defaultVoice != null ||
          series.byCharacter.isNotEmpty ||
          series.byCharacterKind.isNotEmpty);
}

/// 把每句（[slots]，与计划等长）分到声音：返回按预设 id 去重后的声音表（下标 0 恒为
/// [defaultVoice]）与每句所用声音的下标。[slotVoices] 缺某个非默认槽时按默认声音读
/// ——调用方在起会话时已经校验过每个用到的槽都解析得到声音。
({List<TtsResolvedVoice> voices, List<int> voiceOf}) assignTtsVoices({
  required List<String> slots,
  required TtsResolvedVoice defaultVoice,
  required Map<String, TtsResolvedVoice> slotVoices,
}) {
  final List<TtsResolvedVoice> voices = <TtsResolvedVoice>[defaultVoice];
  final Map<String, int> indexByPresetId = <String, int>{
    defaultVoice.preset.id: 0,
  };
  final Map<String, int> indexBySlot = <String, int>{kTtsDefaultVoiceSlot: 0};
  final List<int> voiceOf = <int>[
    for (final String slot in slots)
      indexBySlot.putIfAbsent(slot, () {
        final TtsResolvedVoice? voice = slotVoices[slot];
        if (voice == null) return 0;
        return indexByPresetId.putIfAbsent(voice.preset.id, () {
          voices.add(voice);
          return voices.length - 1;
        });
      }),
  ];
  return (voices: voices, voiceOf: voiceOf);
}

/// 提前生成到哪一句（含）：[from] 所在章的剩余部分 + 下一章。书末不足时到最后一句。
int ttsPrerenderEnd(List<TtsPlanSentence> sentences, int from) {
  if (sentences.isEmpty) return -1;
  final int start = from.clamp(0, sentences.length - 1);
  int chaptersLeft = 2;
  int section = sentences[start].section;
  for (int i = start + 1; i < sentences.length; i++) {
    if (sentences[i].section != section) {
      chaptersLeft--;
      if (chaptersLeft == 0) return i - 1;
      section = sentences[i].section;
    }
  }
  return sentences.length - 1;
}
