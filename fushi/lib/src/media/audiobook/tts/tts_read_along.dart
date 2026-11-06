/// TTS 朗读会话：把整书分句计划变成一组「每句一个按需合成的音频源 + 一条 cue」，
/// 交给现有有声书会话 [AudiobookSession] 播放。
///
/// 复用的是整条有声书链路：正文逐句高亮、跨章跟随、歌词模式、悬浮字幕、媒体通知、
/// 上一句 / 下一句、倍速、制卡取句子音频。TTS 特有的只有三件事：
/// 1. 音频源是 [TtsSentenceAudioSource]，播放器要到哪句才合成哪句（调度器预取后面
///    几句），没合成完播放器处于缓冲态；
/// 2. 一句合成完才知道真实时长：就地更新那条 cue 的 `endMs` 并让控制器重算时间轴，
///    未合成的句子用按字数估计的时长占位；
/// 3. 断点不存全书毫秒（估计时长会变），存「章 + 句首匹配坐标 + 句内毫秒 + 缓存键」。
///
/// 多声优：书在制作台配过角色声音时按句换声音（分派规则见
/// `tts_read_along_voices.dart`）；预取窗口覆盖当前章剩余 + 下一章（提前生成）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart'
    show kStudioSentenceMaxLength;
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along_voices.dart';
import 'package:fushi/src/media/audiobook/tts/tts_sentence_audio_source.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';

/// 朗读从哪里开始。
sealed class TtsStartPoint {
  const TtsStartPoint();
}

/// 阅读器当前位置（章 + 阅读进度单位偏移）。
class TtsStartAtReader extends TtsStartPoint {
  const TtsStartAtReader({required this.section, required this.studyOffset});
  final int section;
  final int studyOffset;
}

/// 指定的一句（按章 + 句首匹配坐标定位，换了分句计划也落在包含该坐标的那句）。
/// 播放中换声音而现有分句放不下新引擎的单次长度上限时，从当前句重起会话用它。
class TtsStartAtSentence extends TtsStartPoint {
  const TtsStartAtSentence({required this.section, required this.matchStart});
  final int section;
  final int matchStart;
}

/// 上次朗读的断点（没有断点时从当前位置）。
class TtsStartAtResume extends TtsStartPoint {
  const TtsStartAtResume({required this.fallback});
  final TtsStartAtReader fallback;
}

/// 启动失败的原因（UI 按它出文案）。
enum TtsStartProblem {
  noVoice,
  voiceIncomplete,
  emptyBook,

  /// 选角表里某个角色的声音被删了 / 引擎在本平台不可用 / 配置不完整。不悄悄换成
  /// 默认声音（那样角色会用错声音读），提示用户去改。
  castVoiceUnavailable,
}

class TtsStartException implements Exception {
  const TtsStartException(this.problem);
  final TtsStartProblem problem;
}

/// 朗读失败提示的时机：只有播放器正停在调度失败的那一句上时才暂停 + 提示，每次失败
/// 只提示一次（失败事件与播放器换句通知都会来问）。
///
/// 播放器会预读下一句（just_audio 提前向下一句的音频源要数据）：下一句失败时当前句
/// 还能读完，提前暂停等于把一次网络抖动放大成打断。
class TtsFailureReportGate {
  int? _reported;

  /// 调度停在 [failedIndex]（null = 没有失败），播放器在 [currentIndex]。
  bool shouldReport({required int? failedIndex, required int currentIndex}) {
    if (failedIndex == null) {
      _reported = null;
      return false;
    }
    if (failedIndex != currentIndex || _reported == failedIndex) return false;
    _reported = failedIndex;
    return true;
  }

  /// 调度已恢复（用户重试 / 离开失败句）：同一句再失败要重新提示。
  void reset() => _reported = null;
}

/// [TtsReadAlong.switchVoice] 的结果。
enum TtsVoiceSwitchOutcome {
  /// 与当前声音完全相同（含凭据），什么都没做。
  unchanged,

  /// 已在本会话内热切换：从当前句句首用新声音续播。
  switched,

  /// 现有分句里有句子超出新引擎的单次长度上限，本会话放不下新声音：调用方从
  /// [TtsReadAlong.currentSentence] 用新声音重起会话（[TtsStartAtSentence]）。
  needsRestart,
}

class TtsReadAlong extends ChangeNotifier {
  TtsReadAlong._({
    required this.bookKey,
    required this.plan,
    required TtsVoicePreset preset,
    required TtsProviderDescriptor descriptor,
    required _TtsVoiceRig rig,
    required List<String> slots,
    required Map<String, TtsResolvedVoice> slotVoices,
    required TtsPresetStore store,
    required TtsAudioCache cache,
    required TtsHost host,
    required this.cues,
  }) : _preset = preset,
       _descriptor = descriptor,
       _rig = rig,
       _slots = slots,
       _slotVoices = slotVoices,
       _store = store,
       _cache = cache,
       _host = host;

  /// 不经有声书会话、不挂播放器的会话，只给测试驱动「换声音」的调度部分。
  @visibleForTesting
  static TtsReadAlong debugCreate({
    required TtsBookPlan plan,
    required TtsVoicePreset preset,
    required TtsProviderDescriptor descriptor,
    required TtsAudioCache cache,
    required TtsHost host,
    required TtsPresetStore store,
    String bookKey = 'debug',
    TtsCast? cast,
    Map<String, TtsResolvedVoice> slotVoices =
        const <String, TtsResolvedVoice>{},
  }) {
    final List<String> slots = <String>[
      for (final TtsPlanSentence s in plan.sentences) ttsVoiceSlotOf(cast, s),
    ];
    return TtsReadAlong._(
      bookKey: bookKey,
      plan: plan,
      preset: preset,
      descriptor: descriptor,
      rig: _TtsVoiceRig.build(
        plan: plan,
        slots: slots,
        defaultVoice: (preset: preset, descriptor: descriptor),
        slotVoices: slotVoices,
        cache: cache,
        host: host,
      ),
      slots: slots,
      slotVoices: slotVoices,
      store: store,
      cache: cache,
      host: host,
      cues: <AudioCue>[
        for (int i = 0; i < plan.length; i++)
          AudioCue()
            ..sentenceIndex = i
            ..text = plan.sentences[i].text
            ..startMs = 0
            ..endMs = estimateDurationMs(plan.sentences[i].spokenText)
            ..audioFileIndex = i,
      ],
    );
  }

  /// 当前正在进行的朗读会话（全应用至多一个，随有声书会话释放而清空）。
  static TtsReadAlong? get active => _active;
  static TtsReadAlong? _active;

  /// 是否是 [controller] 所属的朗读会话。
  static TtsReadAlong? forController(AudiobookPlayerController? controller) {
    final TtsReadAlong? current = _active;
    if (current == null || controller == null) return null;
    return identical(current._controller, controller) ? current : null;
  }

  final String bookKey;
  final TtsBookPlan plan;

  /// 当前声音。播放中可以换（[switchVoice]），所以不是会话开始时的快照。
  TtsVoicePreset get preset => _preset;
  TtsProviderDescriptor get descriptor => _descriptor;
  TtsVoicePreset _preset;
  TtsProviderDescriptor _descriptor;

  /// 每句一条，与播放列表一一对应（`audioFileIndex == sentenceIndex == 下标`）。
  final List<AudioCue> cues;

  /// 当前的调度器连同它用的引擎实例（换默认声音时整套换掉）。
  _TtsVoiceRig _rig;
  TtsSynthesisScheduler get _scheduler => _rig.scheduler;

  /// 每句的声音槽（与计划等长，会话内不变）与非默认槽的声音（单声音朗读时为空）。
  final List<String> _slots;
  final Map<String, TtsResolvedVoice> _slotVoices;

  /// 本会话按角色换声音（书有选角表且至少一句落在配了声音的角色上）。
  bool get isMultiVoice => _rig.voices.length > 1;

  /// 第 [index] 句用的声音。
  TtsResolvedVoice voiceAt(int index) =>
      _rig.voices[_scheduler.voiceIndexOf(index)];

  /// 调度停下时出错的那一句用的声音（失败提示里带声音名）；没有失败时为当前默认声音。
  TtsResolvedVoice get failedVoice {
    final int? index = _scheduler.failedIndex;
    return index == null
        ? (preset: _preset, descriptor: _descriptor)
        : voiceAt(index);
  }

  final TtsPresetStore _store;
  final TtsAudioCache _cache;
  final TtsHost _host;

  /// 换声音串行化：连点两个声音时第二次要等第一次的播放源替换落定。
  Future<void> _switchTail = Future<void>.value();
  AudiobookPlayerController? _controller;
  StreamSubscription<TtsSegmentEvent>? _eventsSub;
  bool _wasPlaying = false;
  bool _released = false;
  final TtsFailureReportGate _failureGate = TtsFailureReportGate();

  /// 调度因失败停下时的原因（UI 展示；用户按播放即重试）。
  TtsFailure? get failure => _scheduler.failure;

  /// 正在合成当前句（播放器在等）。
  bool get isWaitingForCurrent {
    final AudiobookPlayerController? c = _controller;
    if (c == null) return false;
    final int index = c.currentCue?.audioFileIndex ?? _scheduler.cursor;
    return _scheduler.readyAudio(index) == null && _scheduler.failure == null;
  }

  /// 失败提示回调（由入口装配，通常是 toast）。
  void Function(TtsFailure failure)? onFailure;

  /// 估计时长：日文约每字 140ms，加句尾停顿。只用于未合成句的时间轴占位。
  static int estimateDurationMs(String spokenText) =>
      300 + spokenText.length * 140;

  /// 建计划、起会话、定位到起点。失败抛 [TtsStartException] / 透传会话加载异常。
  static Future<TtsReadAlong> start({
    required AudiobookSession session,
    required TtsServices services,
    required EpubBook book,
    required SessionBookInfo info,
    required TtsStartPoint startPoint,
    bool autoplay = true,
    TtsCast? cast,
  }) async {
    final TtsServices tts = services;
    final ({TtsVoicePreset preset, TtsProviderDescriptor descriptor})? voice =
        tts.activeVoice();
    if (voice == null) throw const TtsStartException(TtsStartProblem.noVoice);
    if (voice.descriptor.validate(voice.preset).isNotEmpty) {
      throw const TtsStartException(TtsStartProblem.voiceIncomplete);
    }
    final TtsCast? castInUse = cast == null || cast.voices.isEmpty
        ? null
        : cast;
    // 多声优：分句必须与制作台同一口径（选角表按制作台计划的句首坐标记说话人），
    // 否则坐标对不上、查不到角色。
    final TtsBookPlan basePlan = await buildTtsBookPlan(
      book,
      maxLength: castInUse == null
          ? voice.descriptor.capabilities.maxInputLength
          : kStudioSentenceMaxLength,
      pronunciation: tts.pronunciation.load(),
    );
    final Map<String, TtsResolvedVoice> slotVoices = castInUse == null
        ? const <String, TtsResolvedVoice>{}
        : _resolveSlotVoices(tts, castInUse, basePlan);
    int maxLength = voice.descriptor.capabilities.maxInputLength;
    for (final TtsResolvedVoice v in slotVoices.values) {
      final int limit = v.descriptor.capabilities.maxInputLength;
      if (limit < maxLength) maxLength = limit;
    }
    final TtsBookPlan plan = mergeShortTtsSentences(
      basePlan,
      maxLength: maxLength,
      voiceSlotOf: castInUse == null
          ? null
          : (TtsPlanSentence s) => ttsVoiceSlotOf(castInUse, s),
    );
    if (plan.isEmpty) throw const TtsStartException(TtsStartProblem.emptyBook);
    final List<String> slots = <String>[
      for (final TtsPlanSentence s in plan.sentences)
        ttsVoiceSlotOf(castInUse, s),
    ];

    final TtsAudioCache cache = await tts.cache();
    final _TtsVoiceRig rig = _TtsVoiceRig.build(
      plan: plan,
      slots: slots,
      defaultVoice: voice,
      slotVoices: slotVoices,
      cache: cache,
      host: tts.host,
    );
    final TtsSynthesisScheduler scheduler = rig.scheduler;
    final List<AudioCue> cues = <AudioCue>[
      for (int i = 0; i < plan.length; i++)
        AudioCue()
          ..bookKey = info.bookKey
          ..chapterHref = plan.sentences[i].href
          ..sentenceIndex = i
          ..text = plan.sentences[i].text
          ..textFragmentId = SubtitleRematchCodec.encodeHit(
            sectionIndex: plan.sentences[i].section,
            normCharStart: plan.sentences[i].matchStart,
            normCharEnd: plan.sentences[i].matchEnd,
          )
          ..startMs = 0
          ..endMs = estimateDurationMs(plan.sentences[i].spokenText)
          ..audioFileIndex = i,
    ];
    final TtsReadAlong readAlong = TtsReadAlong._(
      bookKey: info.bookKey,
      plan: plan,
      preset: voice.preset,
      descriptor: voice.descriptor,
      rig: rig,
      slots: slots,
      slotVoices: slotVoices,
      store: tts.store,
      cache: cache,
      host: tts.host,
      cues: cues,
    );

    final ({int index, int offsetMs}) start = readAlong._resolveStart(
      startPoint,
    );
    // session.start 顶掉旧会话（录音有声书或上一次朗读）时会先调旧会话的释放回调。
    final AudiobookPlayerController? controller = await session.start(
      info: info,
      audioFiles: _filesFor(scheduler),
      prefs: SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: tts.store.speed,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: SessionPersistCallbacks(
        onPositionWrite: readAlong._persistPosition,
        onDelayPersist: (_) async {},
        onSpeedPersist: tts.store.setSpeed,
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      ),
      cues: cues,
      audioSources: _sourcesFor(scheduler),
      onReleased: readAlong._release,
    );
    if (controller == null) {
      await readAlong._release();
      throw StateError('audiobook session did not start');
    }
    readAlong._attach(controller);
    scheduler.setCursor(start.index);
    if (start.offsetMs > 0 || !autoplay) {
      await controller.restoreToFileOffset(
        fileIndex: start.index,
        positionMs: start.offsetMs,
      );
      if (autoplay) unawaited(controller.play());
    } else {
      await controller.playCueAndContinue(cues[start.index]);
    }
    return readAlong;
  }

  /// 计划里实际用到的角色槽 → 声音。任何一个解析不到（预设被删 / 引擎不可用 /
  /// 配置不完整，或单次长度上限放不下制作台口径的分句）都抛
  /// [TtsStartProblem.castVoiceUnavailable]。
  static Map<String, TtsResolvedVoice> _resolveSlotVoices(
    TtsServices tts,
    TtsCast cast,
    TtsBookPlan plan,
  ) {
    final Map<String, TtsVoicePreset> presets = <String, TtsVoicePreset>{
      for (final TtsVoicePreset p in tts.store.loadPresets()) p.id: p,
    };
    final Map<String, TtsResolvedVoice> out = <String, TtsResolvedVoice>{};
    for (final TtsPlanSentence s in plan.sentences) {
      final String slot = ttsVoiceSlotOf(cast, s);
      if (slot == kTtsDefaultVoiceSlot || out.containsKey(slot)) continue;
      final TtsVoicePreset? preset = presets[cast.voices[slot]];
      final TtsProviderDescriptor? descriptor = preset == null
          ? null
          : tts.registry[preset.providerId];
      if (preset == null ||
          descriptor == null ||
          !descriptor.isAvailable ||
          descriptor.validate(preset).isNotEmpty ||
          descriptor.capabilities.maxInputLength < kStudioSentenceMaxLength) {
        throw const TtsStartException(TtsStartProblem.castVoiceUnavailable);
      }
      out[slot] = (preset: preset, descriptor: descriptor);
    }
    return out;
  }

  ({int index, int offsetMs}) _resolveStart(TtsStartPoint point) {
    TtsStartAtReader reader;
    switch (point) {
      case TtsStartAtReader():
        reader = point;
      case TtsStartAtSentence(:final int section, :final int matchStart):
        final int index = plan.indexAtMatchStart(section, matchStart);
        return (index: index < 0 ? 0 : index, offsetMs: 0);
      case TtsStartAtResume(:final TtsStartAtReader fallback):
        final TtsResumePoint? resume = _store.resumeFor(bookKey);
        if (resume != null) {
          final int index = plan.indexAtMatchStart(
            resume.section,
            resume.matchStart,
          );
          if (index >= 0) {
            // 只有同一份音频（同声音、同文本）才复用句内毫秒；声音改过就从句首读。
            final bool sameAudio = _scheduler.keyOf(index) == resume.audioKey;
            return (index: index, offsetMs: sameAudio ? resume.offsetMs : 0);
          }
        }
        reader = fallback;
    }
    final int index = plan.indexAtStudyOffset(
      reader.section,
      reader.studyOffset,
    );
    return (index: index < 0 ? 0 : index, offsetMs: 0);
  }

  static List<File> _filesFor(TtsSynthesisScheduler scheduler) => <File>[
    for (int i = 0; i < scheduler.length; i++) File(scheduler.audioPathOf(i)),
  ];

  static List<TtsSentenceAudioSource> _sourcesFor(
    TtsSynthesisScheduler scheduler,
  ) => <TtsSentenceAudioSource>[
    for (int i = 0; i < scheduler.length; i++)
      TtsSentenceAudioSource(scheduler: scheduler, index: i),
  ];

  /// 正在读（或停在）的那一句的下标。
  int get currentIndex {
    final int? index = _controller?.currentCue?.audioFileIndex;
    if (index != null && index >= 0 && index < plan.length) return index;
    return _scheduler.cursor;
  }

  /// 正在读的那一句（换声音需要重起会话时按它定位）。
  TtsPlanSentence? get currentSentence =>
      plan.isEmpty ? null : plan.sentences[currentIndex];

  /// 调度器（测试观察换声音后的合成走向）。
  @visibleForTesting
  TtsSynthesisScheduler get debugScheduler => _scheduler;

  /// 现有分句里最长的一句（朗读用文本）。新引擎的单次长度上限比它小时本会话
  /// 换不了声音（那一句会被引擎拒掉），只能按新上限重新分句。
  late final int _longestSpokenLength = plan.sentences.fold<int>(
    0,
    (int longest, TtsPlanSentence s) =>
        s.spokenText.length > longest ? s.spokenText.length : longest,
  );

  /// 播放中换声音：从**当前句句首**起用新声音。
  ///
  /// 旧声音排队 / 在途的合成全部取消（调度器连同它的请求一起换掉）；播放器的
  /// 音频源整列换成新调度器的源——just_audio 已经预读、缓冲的旧声音音频随旧源
  /// 一起丢弃，不会再播出半句旧声音。已经合成好的旧声音文件留在磁盘缓存里
  /// （缓存键含声音身份），换回来时直接复用。cue 对象身份不变，阅读器高亮、
  /// 歌词、断点照常；各句时长重置为估计值，新声音合成完逐句校正。
  ///
  /// 声音不完整抛 [TtsStartException]；分句放不下新声音返回
  /// [TtsVoiceSwitchOutcome.needsRestart]（本会话不变）。
  Future<TtsVoiceSwitchOutcome> switchVoice(
    TtsVoicePreset preset,
    TtsProviderDescriptor descriptor,
  ) {
    final Future<TtsVoiceSwitchOutcome> result = _switchTail.then(
      (_) => _switchVoice(preset, descriptor),
    );
    _switchTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<TtsVoiceSwitchOutcome> _switchVoice(
    TtsVoicePreset preset,
    TtsProviderDescriptor descriptor,
  ) async {
    if (_released) return TtsVoiceSwitchOutcome.unchanged;
    if (descriptor.validate(preset).isNotEmpty) {
      throw const TtsStartException(TtsStartProblem.voiceIncomplete);
    }
    if (jsonEncode(preset.toJson()) == jsonEncode(_preset.toJson())) {
      return TtsVoiceSwitchOutcome.unchanged;
    }
    if (descriptor.capabilities.maxInputLength < _longestSpokenLength) {
      return TtsVoiceSwitchOutcome.needsRestart;
    }

    final AudiobookPlayerController? controller = _controller;
    final int index = currentIndex;
    final bool wasPlaying = controller?.isPlaying ?? false;
    final _TtsVoiceRig oldRig = _rig;
    final TtsSynthesisScheduler oldScheduler = oldRig.scheduler;
    final StreamSubscription<TtsSegmentEvent>? oldEvents = _eventsSub;

    // 只换默认声音；角色声音不变（缓存键不变，已合成的角色台词直接命中缓存）。
    final _TtsVoiceRig rig = _TtsVoiceRig.build(
      plan: plan,
      slots: _slots,
      defaultVoice: (preset: preset, descriptor: descriptor),
      slotVoices: _slotVoices,
      cache: _cache,
      host: _host,
    );
    final TtsSynthesisScheduler scheduler = rig.scheduler;
    _preset = preset;
    _descriptor = descriptor;
    _rig = rig;
    _eventsSub = scheduler.events.listen(_onSegmentEvent);
    // 新调度器已经接管：旧调度器 / 旧引擎此后不再被本会话引用，无论换源成功、
    // 失败（超时 / 长度校验）还是中途会话被释放（[_release] 只释放当前的新调度器），
    // 都必须在 finally 里关掉，否则旧调度器的 pin 与在途合成、旧引擎连接一直泄漏。
    try {
      await oldEvents?.cancel();
      if (_released) return TtsVoiceSwitchOutcome.unchanged;
      // 新调度器先从当前句开始合成（命中缓存的句子立即就绪），播放器换源后来要
      // 这一句时多半已经在路上了。
      scheduler
        ..setCursor(index)
        ..setLookahead(oldScheduler.lookahead);

      // 旧声音的真实时长不再适用：退回估计值，新声音一句句合成完再校正。
      for (int i = 0; i < cues.length; i++) {
        cues[i].endMs = estimateDurationMs(plan.sentences[i].spokenText);
      }
      controller?.refreshCueTimings();
      if (controller != null) {
        // 先换播放源、后关旧调度器：旧调度器关闭时会让挂起的旧源请求以「已取消」
        // 失败，那时播放器已经不再引用旧源。
        await controller.replaceStreamSources(
          audioFiles: _filesFor(scheduler),
          audioSources: _sourcesFor(scheduler),
          fileIndex: index,
          play: wasPlaying,
        );
      }
    } finally {
      await oldRig.dispose();
    }
    if (_released) return TtsVoiceSwitchOutcome.unchanged;
    notifyListeners();
    return TtsVoiceSwitchOutcome.switched;
  }

  void _attach(AudiobookPlayerController controller) {
    _active = this;
    _controller = controller;
    controller.addListener(_onControllerChanged);
    _eventsSub = _scheduler.events.listen(_onSegmentEvent);
    _wasPlaying = controller.isPlaying;
  }

  void _onControllerChanged() {
    final AudiobookPlayerController? c = _controller;
    if (c == null) return;
    final int? index = c.currentCue?.audioFileIndex;
    _updateLookahead(c);
    if (index != null && index != _scheduler.cursor) {
      _scheduler.setCursor(index);
      // 失败停在某句时用户跳到了别的句子：那是显式离开失败句，调度继续合成新位置
      // （失败句本身不被跳过——回到它时会重新请求）。
      final int? failed = _scheduler.failedIndex;
      if (failed != null && failed != index) {
        _resumeAfterFailure();
      }
      // 播放器预读下一句时它失败了，当时还在读上一句没有打断；现在播到它了才停下提示。
      _reportFailureIfOnFailedSentence();
    }
    final bool playing = c.isPlaying;
    // 失败停下后用户再按播放 = 重试。
    if (playing && !_wasPlaying && _scheduler.failure != null) {
      _resumeAfterFailure();
    }
    _wasPlaying = playing;
  }

  void _resumeAfterFailure() {
    _scheduler.resume();
    _failureGate.reset();
    notifyListeners();
  }

  /// 调度停在失败句上、且播放器正停在那一句：暂停并提示（每次失败只提示一次）。
  /// 失败句不是当前句（播放器预读后一句 / 后台预取）时不打断正在播放的句子。
  void _reportFailureIfOnFailedSentence() {
    final TtsFailure? failure = _scheduler.failure;
    if (failure == null) return;
    if (!_failureGate.shouldReport(
      failedIndex: _scheduler.failedIndex,
      currentIndex: currentIndex,
    )) {
      return;
    }
    unawaited(_controller?.pause());
    onFailure?.call(failure);
  }

  /// 预取窗口取两者中大的那个：
  /// - 按「播放时长」算的缓冲：2 倍速下同样 3 句只够 1/2 的时间，合成稍有波动
  ///   （自建 GPU 服务单句延迟忽高忽低）就断。当前句之后至少
  ///   [kBufferPlaybackSeconds] 秒（按当前倍速换算）的音频都在合成或已合成；
  /// - **提前生成**：当前章剩余 + 下一章（[ttsPrerenderEnd]）。合成比听得快时缓冲
  ///   一路攒到下一章末，倍速 / 网络抖动吃的是攒下的余量。
  static const int kBufferPlaybackSeconds = 60;
  static const int _kMinLookahead = 3;

  /// 窗口上限（一章几百句 + 下一章；超长章节只提前生成这么多句）。
  static const int kMaxLookahead = 1500;

  void _updateLookahead(AudiobookPlayerController c) {
    _scheduler.setLookahead(
      lookaheadFor(
        current: c.currentCue?.audioFileIndex ?? _scheduler.cursor,
        speed: c.speed,
      ),
    );
  }

  /// 播放器停在 [current]、倍速 [speed] 时的预取句数。
  @visibleForTesting
  int lookaheadFor({required int current, required double speed}) {
    final double rate = speed > 0 ? speed : 1.0;
    final int targetMs = (kBufferPlaybackSeconds * 1000 * rate).round();
    int sum = 0;
    int byTime = 0;
    for (int i = current + 1; i < cues.length && sum < targetMs; i++) {
      sum += cues[i].endMs - cues[i].startMs;
      byTime++;
    }
    final int byChapter = ttsPrerenderEnd(plan.sentences, current) - current;
    final int count = byTime > byChapter ? byTime : byChapter;
    return count.clamp(_kMinLookahead, kMaxLookahead);
  }

  /// 当前句之后已经合成好、连续可播的音频时长（毫秒，按 1 倍速）：提前生成攒下的余量。
  int get bufferedAheadMs {
    int sum = 0;
    for (int i = currentIndex + 1; i < cues.length; i++) {
      if (_scheduler.readyAudio(i) == null) break;
      sum += cues[i].endMs - cues[i].startMs;
    }
    return sum;
  }

  void _onSegmentEvent(TtsSegmentEvent event) {
    final AudiobookPlayerController? c = _controller;
    switch (event) {
      case TtsSegmentReady(:final int index, :final TtsCachedAudio audio):
        if (index < 0 || index >= cues.length) return;
        if (cues[index].endMs != audio.durationMs) {
          cues[index].endMs = audio.durationMs;
          c?.refreshCueTimings();
        }
      case TtsSegmentFailed():
        // 后台预取失败（blocking 为假）不打断播放：调度器记下这句，播放器要到它时
        // 重新请求。播放器要的句子失败才可能需要停下，且只在播到它时停。
        _reportFailureIfOnFailedSentence();
    }
    notifyListeners();
  }

  /// 控制器周期 / 停止时的位置写入：把全书毫秒拆回（句, 句内毫秒）存断点。
  Future<void> _persistPosition(String _, int globalMs) async {
    final AudiobookPlayerController? c = _controller;
    if (c == null || cues.isEmpty) return;
    final List<int> durations = c.fileDurationsMs;
    if (durations.isEmpty) return;
    final ({int fileIndex, int offsetMs}) at =
        AudiobookPlayerController.splitGlobalMs(globalMs, durations);
    final int index = at.fileIndex.clamp(0, plan.length - 1);
    final TtsPlanSentence sentence = plan.sentences[index];
    await _store.saveResume(
      bookKey,
      TtsResumePoint(
        section: sentence.section,
        matchStart: sentence.matchStart,
        offsetMs: at.offsetMs,
        audioKey: _scheduler.keyOf(index),
      ),
    );
  }

  /// 会话释放（原生播放器已放掉之后）：停调度、解除缓存 pin、关引擎连接。
  Future<void> _release() async {
    if (_released) return;
    _released = true;
    if (identical(_active, this)) _active = null;
    _controller?.removeListener(_onControllerChanged);
    _controller = null;
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _rig.dispose();
    notifyListeners();
  }
}

/// 一套调度器 + 它用到的引擎实例（每份预设一个）。换默认声音时整套替换。
class _TtsVoiceRig {
  _TtsVoiceRig._(this.scheduler, this.voices, this.providers);

  factory _TtsVoiceRig.build({
    required TtsBookPlan plan,
    required List<String> slots,
    required TtsResolvedVoice defaultVoice,
    required Map<String, TtsResolvedVoice> slotVoices,
    required TtsAudioCache cache,
    required TtsHost host,
  }) {
    final ({List<TtsResolvedVoice> voices, List<int> voiceOf}) assigned =
        assignTtsVoices(
          slots: slots,
          defaultVoice: defaultVoice,
          slotVoices: slotVoices,
        );
    final List<TtsProvider> providers = <TtsProvider>[
      for (final TtsResolvedVoice v in assigned.voices)
        v.descriptor.create(v.preset, host),
    ];
    final TtsSynthesisScheduler scheduler = TtsSynthesisScheduler.voices(
      voices: <TtsSchedulerVoice>[
        for (int i = 0; i < assigned.voices.length; i++)
          TtsSchedulerVoice(
            provider: providers[i],
            audioIdentity: assigned.voices[i].descriptor.audioIdentity(
              assigned.voices[i].preset,
            ),
            concurrency: ttsEffectiveConcurrency(
              assigned.voices[i].descriptor,
              assigned.voices[i].preset,
            ),
          ),
      ],
      voiceOf: assigned.voiceOf,
      cache: cache,
      texts: <String>[
        for (final TtsPlanSentence s in plan.sentences) s.spokenText,
      ],
    );
    return _TtsVoiceRig._(scheduler, assigned.voices, providers);
  }

  final TtsSynthesisScheduler scheduler;
  final List<TtsResolvedVoice> voices;
  final List<TtsProvider> providers;

  /// 先停调度（等在途合成收尾），再关引擎连接。
  Future<void> dispose() async {
    await scheduler.dispose();
    for (final TtsProvider provider in providers) {
      await provider.dispose();
    }
  }
}
