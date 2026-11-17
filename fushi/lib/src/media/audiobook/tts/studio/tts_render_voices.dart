/// 多声优配音：每句用哪份声音预设，以及合成的并发闸门。
library;

import 'dart:async';
import 'dart:collection';

import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';

/// 解析好的一份声音预设（每份预设只解析一次）。
class TtsRenderVoice {
  const TtsRenderVoice({
    required this.preset,
    required this.descriptor,
    required this.identity,
  });

  final TtsVoicePreset preset;
  final TtsProviderDescriptor descriptor;

  /// 进缓存键的音色身份。
  final Map<String, Object?> identity;
}

/// 按 id 解析声音预设：缺失 / 引擎不可用 / 配置不完整分别抛 `voice_missing` /
/// `voice_unavailable` / `voice_incomplete`（[TtsRenderFailure]）。[presets] 是制作侧
/// 可选的全部声音（`ttsProductionPresets`：声音预设 + 声音包虚拟预设）。
TtsRenderVoice resolveTtsRenderVoice(
  TtsServices tts,
  String presetId, {
  required Iterable<TtsVoicePreset> presets,
}) {
  TtsVoicePreset? preset;
  for (final TtsVoicePreset candidate in presets) {
    if (candidate.id == presetId) preset = candidate;
  }
  if (preset == null) throw const TtsRenderFailure('voice_missing');
  final TtsProviderDescriptor? descriptor = tts.productionDescriptor(
    preset.providerId,
  );
  if (descriptor == null || !descriptor.isAvailable) {
    throw const TtsRenderFailure('voice_unavailable');
  }
  if (descriptor.validate(preset).isNotEmpty) {
    throw const TtsRenderFailure('voice_incomplete');
  }
  return TtsRenderVoice(
    preset: preset,
    descriptor: descriptor,
    identity: descriptor.audioIdentity(preset),
  );
}

/// [indices] 里每句（计划下标）的预设 id：选角表给了就用选角表的，否则任务的默认
/// 声音 [defaultPresetId]（旁白 / 没分配声音的角色 / 没标注的句子）。
Map<int, String> resolveTtsSentencePresets({
  required List<TtsPlanSentence> sentences,
  required Iterable<int> indices,
  required TtsCast cast,
  required String defaultPresetId,
}) => <int, String>{
  for (final int i in indices)
    i:
        cast.presetFor(sentences[i].section, sentences[i].matchStart) ??
        defaultPresetId,
};

/// 计数信号量：同时最多 [capacity] 个持有者，其余按先来后到排队。
class TtsRenderGate {
  TtsRenderGate(this.capacity) : assert(capacity > 0);

  final int capacity;
  int _held = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_held < capacity) {
      _held++;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // 名额直接转给队首，持有数不变。
      _waiters.removeFirst().complete();
    } else {
      _held--;
    }
  }
}

/// 整个任务同时在途的合成请求上限（各引擎自己的上限之外再加一道总闸）。
const int kTtsRenderMaxParallel = 8;
