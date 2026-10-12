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
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_synthesis_scheduler.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
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
enum TtsStartProblem { noVoice, voiceIncomplete, emptyBook }

class TtsStartException implements Exception {
  const TtsStartException(this.problem);
  final TtsStartProblem problem;
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
    required TtsProvider provider,
    required TtsSynthesisScheduler scheduler,
    required TtsPresetStore store,
    required TtsAudioCache cache,
    required TtsHost host,
    required this.cues,
  }) : _preset = preset,
       _descriptor = descriptor,
       _provider = provider,
       _scheduler = scheduler,
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
  }) {
    final TtsProvider provider = descriptor.create(preset, host);
    return TtsReadAlong._(
      bookKey: bookKey,
      plan: plan,
      preset: preset,
      descriptor: descriptor,
      provider: provider,
      scheduler: _newScheduler(
        plan: plan,
        provider: provider,
        cache: cache,
        preset: preset,
        descriptor: descriptor,
      ),
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

  static TtsSynthesisScheduler _newScheduler({
    required TtsBookPlan plan,
    required TtsProvider provider,
    required TtsAudioCache cache,
    required TtsVoicePreset preset,
    required TtsProviderDescriptor descriptor,
  }) => TtsSynthesisScheduler(
    provider: provider,
    cache: cache,
    texts: <String>[
      for (final TtsPlanSentence s in plan.sentences) s.spokenText,
    ],
    audioIdentity: descriptor.audioIdentity(preset),
    concurrency: ttsEffectiveConcurrency(descriptor, preset),
  );

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

  TtsProvider _provider;
  TtsSynthesisScheduler _scheduler;
  final TtsPresetStore _store;
  final TtsAudioCache _cache;
  final TtsHost _host;

  /// 换声音串行化：连点两个声音时第二次要等第一次的播放源替换落定。
  Future<void> _switchTail = Future<void>.value();
  AudiobookPlayerController? _controller;
  StreamSubscription<TtsSegmentEvent>? _eventsSub;
  bool _wasPlaying = false;
  bool _released = false;

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
  }) async {
    final TtsServices tts = services;
    final ({TtsVoicePreset preset, TtsProviderDescriptor descriptor})? voice =
        tts.activeVoice();
    if (voice == null) throw const TtsStartException(TtsStartProblem.noVoice);
    if (voice.descriptor.validate(voice.preset).isNotEmpty) {
      throw const TtsStartException(TtsStartProblem.voiceIncomplete);
    }
    final int maxLength = voice.descriptor.capabilities.maxInputLength;
    final TtsBookPlan plan = mergeShortTtsSentences(
      await buildTtsBookPlan(
        book,
        maxLength: maxLength,
        pronunciation: tts.pronunciation.load(),
      ),
      maxLength: maxLength,
    );
    if (plan.isEmpty) throw const TtsStartException(TtsStartProblem.emptyBook);

    final TtsAudioCache cache = await tts.cache();
    final TtsProvider provider = voice.descriptor.create(
      voice.preset,
      tts.host,
    );
    final TtsSynthesisScheduler scheduler = _newScheduler(
      plan: plan,
      provider: provider,
      cache: cache,
      preset: voice.preset,
      descriptor: voice.descriptor,
    );
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
      provider: provider,
      scheduler: scheduler,
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
    final TtsProvider oldProvider = _provider;
    final TtsSynthesisScheduler oldScheduler = _scheduler;
    final StreamSubscription<TtsSegmentEvent>? oldEvents = _eventsSub;

    final TtsProvider provider = descriptor.create(preset, _host);
    final TtsSynthesisScheduler scheduler = _newScheduler(
      plan: plan,
      provider: provider,
      cache: _cache,
      preset: preset,
      descriptor: descriptor,
    );
    _preset = preset;
    _descriptor = descriptor;
    _provider = provider;
    _scheduler = scheduler;
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
      await oldScheduler.dispose();
      await oldProvider.dispose();
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
        _scheduler.resume();
        notifyListeners();
      }
    }
    final bool playing = c.isPlaying;
    // 失败停下后用户再按播放 = 重试。
    if (playing && !_wasPlaying && _scheduler.failure != null) {
      _scheduler.resume();
      notifyListeners();
    }
    _wasPlaying = playing;
  }

  /// 预取缓冲按「播放时长」而不是句数算：2 倍速下同样 3 句只够 1/2 的时间，合成
  /// 稍有波动（自建 GPU 服务单句延迟忽高忽低）就断。目标是当前句之后至少
  /// [kBufferPlaybackSeconds] 秒（按当前倍速换算）的音频都在合成或已合成。
  static const int kBufferPlaybackSeconds = 60;
  static const int _kMinLookahead = 3;
  static const int _kMaxLookahead = 60;

  void _updateLookahead(AudiobookPlayerController c) {
    final double speed = c.speed > 0 ? c.speed : 1.0;
    final int targetMs = (kBufferPlaybackSeconds * 1000 * speed).round();
    final int from = (c.currentCue?.audioFileIndex ?? _scheduler.cursor) + 1;
    int sum = 0;
    int count = 0;
    for (int i = from; i < cues.length && sum < targetMs; i++) {
      sum += cues[i].endMs - cues[i].startMs;
      count++;
    }
    _scheduler.setLookahead(count.clamp(_kMinLookahead, _kMaxLookahead));
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
      case TtsSegmentFailed(:final TtsFailure failure):
        unawaited(c?.pause());
        onFailure?.call(failure);
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
    await _scheduler.dispose();
    await _provider.dispose();
    notifyListeners();
  }
}
