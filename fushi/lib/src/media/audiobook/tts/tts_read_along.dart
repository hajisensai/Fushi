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

class TtsReadAlong extends ChangeNotifier {
  TtsReadAlong._({
    required this.bookKey,
    required this.plan,
    required this.preset,
    required this.descriptor,
    required TtsProvider provider,
    required TtsSynthesisScheduler scheduler,
    required TtsPresetStore store,
    required this.cues,
  }) : _provider = provider,
       _scheduler = scheduler,
       _store = store;

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
  final TtsVoicePreset preset;
  final TtsProviderDescriptor descriptor;

  /// 每句一条，与播放列表一一对应（`audioFileIndex == sentenceIndex == 下标`）。
  final List<AudioCue> cues;

  final TtsProvider _provider;
  final TtsSynthesisScheduler _scheduler;
  final TtsPresetStore _store;
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
    final TtsSynthesisScheduler scheduler = TtsSynthesisScheduler(
      provider: provider,
      cache: cache,
      texts: <String>[
        for (final TtsPlanSentence s in plan.sentences) s.spokenText,
      ],
      audioIdentity: voice.descriptor.audioIdentity(voice.preset),
      concurrency: ttsEffectiveConcurrency(voice.descriptor, voice.preset),
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
      cues: cues,
    );

    final ({int index, int offsetMs}) start = readAlong._resolveStart(
      startPoint,
    );
    // session.start 顶掉旧会话（录音有声书或上一次朗读）时会先调旧会话的释放回调。
    final AudiobookPlayerController? controller = await session.start(
      info: info,
      audioFiles: <File>[
        for (int i = 0; i < plan.length; i++) File(scheduler.audioPathOf(i)),
      ],
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
      audioSources: <TtsSentenceAudioSource>[
        for (int i = 0; i < plan.length; i++)
          TtsSentenceAudioSource(scheduler: scheduler, index: i),
      ],
      onReleased: readAlong._release,
    );
    if (controller == null) {
      await readAlong._release();
      throw StateError('audiobook session did not start');
    }
    readAlong._attach(controller);
    scheduler.setCursor(start.index);
    if (start.offsetMs > 0) {
      await controller.restoreToFileOffset(
        fileIndex: start.index,
        positionMs: start.offsetMs,
      );
      unawaited(controller.play());
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
