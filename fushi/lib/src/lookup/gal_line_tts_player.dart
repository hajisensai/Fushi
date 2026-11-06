/// Galgame 台词浮窗的 TTS 播放编排：换句打断、等配对证据、预合成、游戏原声来了就停。
///
/// 裁决全在 [decideGalLineTts]（纯函数）；这里只管生命周期：
///  - 新台词到达 → 立刻打断上一句（合成中的取消、播放中的停），不排队接着读；
///  - 裁决为「等」→ 先**预合成**（不播），等这一行的配对状态落定再裁决一次，
///    确定要读时音频多半已经合好，延迟只剩播放器开播；
///  - 正在读的这句后来配上了游戏原声（[GalLineVoiceEvidence.voiced]）→ 停，
///    除非这句是用户手动点的或被规则明确判为照读。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/lookup/global_lookup_log.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';

/// 合成一段文本并返回可播放的本地文件路径。失败抛 [TtsFailure] 或 [GalLineTtsUnavailable]。
typedef GalLineTtsSynthesizer =
    Future<String> Function(
      String text, {
      required String? presetId,
      required TtsCancelToken cancel,
    });

/// 播放到结束；返回 true = 自然播完，false = 没开播 / 被打断。[speed] 是倍速
/// （变速不变调）。
typedef GalLineTtsPlayToEnd =
    Future<bool> Function(String path, double volume, double speed);

typedef GalLineTtsStopPlayback = Future<void> Function();

/// 没有可用声音（没配 / 预设已删 / 引擎本平台不可用 / 参数不全）。
class GalLineTtsUnavailable implements Exception {
  const GalLineTtsUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'GalLineTtsUnavailable($reason)';
}

/// 一次朗读（一行）。
class _Utterance {
  _Utterance({
    required this.lineId,
    required this.rawText,
    required this.manual,
  });

  final String lineId;
  final String rawText;

  /// 用户手动点的「朗读」→ 后来配上原声也不停。
  ///
  /// 只升不降：自动朗读在等配对证据时已为这一行建了预合成的 utterance，用户此时
  /// 点「朗读」会复用它（省掉重合成），复用时必须把它提升为手动——否则它仍按
  /// 自动朗读处理，游戏原声一配上就被 [GalLineTtsPlayer.onLatestLine] 取消，
  /// 用户点了朗读却被打断。
  bool manual;
  final TtsCancelToken cancel = TtsCancelToken();

  /// 规则明确判为照读（read / voice）→ 后来配上原声也不停。
  bool forcedByRule = false;

  /// 已开始播放（停的时候要连播放器一起停）。
  bool playing = false;

  /// 预合成结果（文本 + 声音一致才复用）。
  ({String text, String? presetId, Future<List<String>> files})? prepared;
}

class GalLineTtsPlayer {
  GalLineTtsPlayer({
    required GalLineTtsSettings Function() settings,
    TtsServices Function()? services,
    GalLineTtsSynthesizer? synthesize,
    GalLineTtsPlayToEnd? playToEnd,
    GalLineTtsStopPlayback? stopPlayback,
    int Function(String? presetId)? maxInputLength,
  }) : _settings = settings,
       _synthesize =
           synthesize ??
           ((
             String text, {
             required String? presetId,
             required TtsCancelToken cancel,
           }) => synthesizeGalLineTtsWithServices(
             services!(),
             text,
             presetId: presetId,
             cancel: cancel,
           )),
       _playToEnd =
           playToEnd ??
           ((String path, double volume, double speed) =>
               DesktopAudioPlayback.playFileToEnd(
                 path,
                 volume: volume,
                 speed: speed,
               )),
       _stopPlayback = stopPlayback ?? DesktopAudioPlayback.stop,
       _maxInputLength =
           maxInputLength ??
           ((String? presetId) =>
               galLineTtsMaxInputLength(services!(), presetId));

  final GalLineTtsSettings Function() _settings;
  final GalLineTtsSynthesizer _synthesize;
  final GalLineTtsPlayToEnd _playToEnd;
  final GalLineTtsStopPlayback _stopPlayback;
  final int Function(String? presetId) _maxInputLength;

  /// 正在朗读（含合成中）——浮窗「朗读」键的高亮。
  final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);

  /// 最近一次失败原因（设置页 / toast 展示），成功开播后清空。
  final ValueNotifier<Object?> lastError = ValueNotifier<Object?>(null);

  _Utterance? _current;

  /// 自动朗读已裁决过（读了 / 跳过）的行 id，避免同一行的状态更新反复触发。
  String? _settledLineId;
  String? _settledLineText;

  @visibleForTesting
  String? get currentLineId => _current?.lineId;

  /// 会话的最新行变了（换句 / 就地扩写）或它的配对状态变了，每轮 sync 都可以调：
  /// 同一行同一文本只裁决到一次「读 / 跳过」，「等」会在后续调用里重新裁决。
  void onLatestLine(TexthookerLineEntry line) {
    final _Utterance? current = _current;
    final bool sameLine =
        line.id == _settledLineId && line.text == _settledLineText;
    final bool sameUtterance =
        current != null &&
        current.lineId == line.id &&
        current.rawText == line.text;
    if (!sameUtterance && !sameLine) {
      // 换句：上一句不管读到哪都打断（手动点的也一样——玩家已经翻页了）。
      _cancelCurrent();
      _settledLineId = null;
      _settledLineText = null;
    }
    final GalLineVoiceEvidence evidence = galLineVoiceEvidenceOf(line);
    final _Utterance? active = _current;
    if (active != null && active.lineId == line.id) {
      // 正在读的这句后来配上了游戏原声 → 让给原声。
      if (evidence == GalLineVoiceEvidence.voiced &&
          !active.manual &&
          !active.forcedByRule &&
          _settings().effectiveAutoPlay == GalLineTtsAutoPlay.unvoicedOnly) {
        glog('galtts: line=${line.id} got game voice, yielding');
        _cancelCurrent();
        _settledLineId = line.id;
        _settledLineText = line.text;
        return;
      }
      if (active.playing || active.manual) return;
    }
    if (sameLine) return;
    _decideAndRun(line, evidence, manual: false);
  }

  /// 浮窗「朗读」键：正在读就停；否则读这一行（不受自动朗读档位与 skip 规则限制）。
  void toggleManual(TexthookerLineEntry? line) {
    // 只看「在读」：自动朗读预合成中（等配对证据）的那句不算在读，点了就是要听。
    if (speaking.value) {
      _cancelCurrent();
      if (line != null) {
        _settledLineId = line.id;
        _settledLineText = line.text;
      }
      return;
    }
    if (line == null) return;
    _decideAndRun(line, galLineVoiceEvidenceOf(line), manual: true);
  }

  /// 停掉当前朗读（会话结束 / 浮窗收起 / 用户点了重播原声）。
  void stop() => _cancelCurrent();

  void dispose() {
    _cancelCurrent();
    speaking.dispose();
    lastError.dispose();
  }

  void _decideAndRun(
    TexthookerLineEntry line,
    GalLineVoiceEvidence evidence, {
    required bool manual,
  }) {
    final GalLineTtsSettings settings = _settings();
    final GalLineTtsDecision decision = decideGalLineTts(
      settings: settings,
      rawText: line.text,
      evidence: evidence,
      manual: manual,
    );
    switch (decision) {
      case GalLineTtsSkip(:final String reason):
        glog('galtts: line=${line.id} skip ($reason)');
        _settledLineId = line.id;
        _settledLineText = line.text;
        if (_current?.lineId == line.id) _cancelCurrent();
      case GalLineTtsWait():
        // 预合成：裁决「读」时文本与声音和这里一致（等的只是配对证据）。
        final _Utterance utterance =
            (_current?.lineId == line.id && _current?.rawText == line.text)
            ? _current!
            : _begin(line, manual: false);
        _prepare(
          utterance,
          text: galLineTtsText(settings, line.text),
          presetId: settings.presetId,
        );
      case GalLineTtsSpeak(:final String text, :final String? presetId):
        _settledLineId = line.id;
        _settledLineText = line.text;
        final _Utterance utterance =
            (_current?.lineId == line.id &&
                _current?.rawText == line.text &&
                !_current!.playing)
            ? _current!
            : _begin(line, manual: manual);
        // 复用预合成 utterance 时按这次触发提升（手动只升不降）。
        if (manual) utterance.manual = true;
        utterance.forcedByRule = _ruleForcesRead(settings, line.text);
        unawaited(_speak(utterance, text: text, presetId: presetId));
    }
  }

  bool _ruleForcesRead(GalLineTtsSettings settings, String rawText) {
    final GalLineSpeakerSplit split = splitGalLineSpeaker(
      rawText,
      customPattern: settings.speakerPattern,
    );
    for (final GalLineTtsRule rule in settings.rules) {
      if (rule.matches(rawText: rawText.trim(), speaker: split.speaker)) {
        return rule.action != GalLineTtsRuleAction.skip;
      }
    }
    return false;
  }

  _Utterance _begin(TexthookerLineEntry line, {required bool manual}) {
    _cancelCurrent();
    final _Utterance utterance = _Utterance(
      lineId: line.id,
      rawText: line.text,
      manual: manual,
    );
    _current = utterance;
    return utterance;
  }

  Future<List<String>> _prepare(
    _Utterance utterance, {
    required String text,
    required String? presetId,
  }) {
    final ({String text, String? presetId, Future<List<String>> files})?
    prepared = utterance.prepared;
    if (prepared != null &&
        prepared.text == text &&
        prepared.presetId == presetId) {
      return prepared.files;
    }
    final Future<List<String>> files = _synthesizeChunks(
      text,
      presetId: presetId,
      cancel: utterance.cancel,
    );
    // 预合成的失败等真正要读时再报；这里先把未处理异常吃进 Future 本身。
    unawaited(files.then((_) {}, onError: (Object _) {}));
    utterance.prepared = (text: text, presetId: presetId, files: files);
    return files;
  }

  Future<List<String>> _synthesizeChunks(
    String text, {
    required String? presetId,
    required TtsCancelToken cancel,
  }) async {
    final List<String> chunks = splitGalLineTtsText(
      text,
      maxLength: _maxInputLength(presetId),
    );
    final List<String> files = <String>[];
    for (final String chunk in chunks) {
      if (cancel.isCancelled) throw const TtsFailure(TtsFailureCode.cancelled);
      files.add(await _synthesize(chunk, presetId: presetId, cancel: cancel));
    }
    return files;
  }

  Future<void> _speak(
    _Utterance utterance, {
    required String text,
    required String? presetId,
  }) async {
    speaking.value = true;
    try {
      final List<String> files = await _prepare(
        utterance,
        text: text,
        presetId: presetId,
      );
      // 每段开播前现读：用户在设置里拖了音量 / 倍速，下一段（长台词分段）就生效。
      for (final String path in files) {
        if (!identical(_current, utterance) || utterance.cancel.isCancelled) {
          return;
        }
        utterance.playing = true;
        lastError.value = null;
        final GalLineTtsSettings settings = _settings();
        final bool finished = await _playToEnd(
          path,
          settings.volume,
          settings.speed,
        );
        if (!finished) break;
      }
    } on TtsFailure catch (failure) {
      if (failure.code != TtsFailureCode.cancelled &&
          identical(_current, utterance)) {
        glog('galtts: line=${utterance.lineId} failed ${failure.code}');
        lastError.value = failure;
      }
    } on GalLineTtsUnavailable catch (error) {
      glog('galtts: unavailable ${error.reason}');
      if (identical(_current, utterance)) lastError.value = error;
    } catch (error) {
      glog('galtts: line=${utterance.lineId} error $error');
      if (identical(_current, utterance)) lastError.value = error;
    } finally {
      if (identical(_current, utterance)) {
        _current = null;
        speaking.value = false;
      }
    }
  }

  void _cancelCurrent() {
    final _Utterance? current = _current;
    if (current == null) return;
    _current = null;
    current.cancel.cancel();
    if (current.playing) unawaited(_stopPlayback());
    speaking.value = false;
  }
}

/// 按引擎单次输入上限切句：先按句末标点切，单句仍超长再硬切。
List<String> splitGalLineTtsText(String text, {required int maxLength}) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return const <String>[];
  if (maxLength <= 0 || trimmed.length <= maxLength) return <String>[trimmed];
  final List<String> sentences = <String>[
    for (final Match m in RegExp(
      r'[^。！？!?…\n]+[。！？!?…」』]*|[。！？!?…]+',
    ).allMatches(trimmed))
      if (m.group(0)!.trim().isNotEmpty) m.group(0)!.trim(),
  ];
  final List<String> out = <String>[];
  final StringBuffer buffer = StringBuffer();
  void flush() {
    if (buffer.isNotEmpty) out.add(buffer.toString());
    buffer.clear();
  }

  for (final String sentence in sentences) {
    if (sentence.length > maxLength) {
      flush();
      for (int i = 0; i < sentence.length; i += maxLength) {
        out.add(
          sentence.substring(
            i,
            i + maxLength > sentence.length ? sentence.length : i + maxLength,
          ),
        );
      }
      continue;
    }
    if (buffer.length + sentence.length > maxLength) flush();
    buffer.write(sentence);
  }
  flush();
  return out;
}

/// 解析这次要用的声音：[presetId] 指定的预设，否则「朗读声音」的当前声音。
({TtsVoicePreset preset, TtsProviderDescriptor descriptor})
resolveGalLineTtsVoice(TtsServices services, String? presetId) {
  TtsVoicePreset? preset;
  if (presetId != null) {
    for (final TtsVoicePreset p in services.store.loadPresets()) {
      if (p.id == presetId) preset = p;
    }
    if (preset == null) throw const GalLineTtsUnavailable('preset_missing');
  } else {
    preset = services.store.activePreset();
    if (preset == null) throw const GalLineTtsUnavailable('no_voice');
  }
  final TtsProviderDescriptor? descriptor =
      services.registry[preset.providerId];
  if (descriptor == null || !descriptor.isAvailable) {
    throw const GalLineTtsUnavailable('provider_unavailable');
  }
  if (descriptor.validate(preset).isNotEmpty) {
    throw const GalLineTtsUnavailable('not_configured');
  }
  return (preset: preset, descriptor: descriptor);
}

/// 生产合成：经全应用共用的 [TtsAudioCache]（同句同音色只合一次，回看重读零延迟）。
Future<String> synthesizeGalLineTtsWithServices(
  TtsServices services,
  String text, {
  required String? presetId,
  required TtsCancelToken cancel,
}) async {
  // 从没配过声音时与「朗读声音」页同一份开箱默认（微软 Edge）。
  await services.seedBuiltinVoiceIfUnset();
  final ({TtsVoicePreset preset, TtsProviderDescriptor descriptor}) voice =
      resolveGalLineTtsVoice(services, presetId);
  final TtsProvider provider = voice.descriptor.create(
    voice.preset,
    services.host,
  );
  try {
    final TtsAudioCache cache = await services.cache();
    final String key = TtsAudioCache.keyFor(
      voice.descriptor.audioIdentity(voice.preset),
      text,
    );
    final TtsCachedAudio audio = await cache.obtain(
      key,
      (String out) =>
          provider.synthesize(text, outputPath: out, cancel: cancel),
    );
    return audio.path;
  } finally {
    await provider.dispose();
  }
}

/// 生产的单次输入上限（取声音所属引擎的 [TtsCapabilities.maxInputLength]）。
int galLineTtsMaxInputLength(TtsServices services, String? presetId) {
  try {
    return resolveGalLineTtsVoice(
      services,
      presetId,
    ).descriptor.capabilities.maxInputLength;
  } on GalLineTtsUnavailable {
    return 0;
  }
}
