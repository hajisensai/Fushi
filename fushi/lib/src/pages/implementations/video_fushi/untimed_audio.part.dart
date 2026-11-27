part of '../video_fushi_page.dart';

/// 无字幕时间时的句子音频（拍板台 lmJyeqpCaO）在视频页上的一次查词状态。
///
/// [cue] 是交给原有制卡链的**合成锚点 cue**（文本 = 被点的 OCR 句，时间 = 猜出的区间
/// 换回字幕文件坐标）；它就是 [_VideoFushiPageState._lastLookupCue]，按身份认，换了
/// 查词它自然就不是当前锚点了。[pendingRefinement] 是人声检测还在跑时的那个 Future。
class _UntimedAudioAnchor {
  _UntimedAudioAnchor({
    required this.cue,
    required this.window,
    required this.lookupPositionMs,
  });

  AudioCue cue;
  UntimedSentenceAudioWindow window;

  /// 查词那一刻的播放位置（播放器轴）：人声检测围着它找，封面「字幕开头」帧也取它——
  /// 画面上的那行字就是这一刻显示的，区间起点可能还是上一句的画面。
  final int lookupPositionMs;

  Future<void>? pendingRefinement;
}

/// 视频页「无字幕时间时的句子音频」：在画面 OCR 查词没有任何字幕时间可锚时，按设置
/// 猜一段区间交给原有制卡链（区间、试听、高级制卡、图片 / 片段都沿用同一条路）。
extension _VideoUntimedAudio on _VideoFushiPageState {
  /// 画面 OCR 查词拿不到图形字幕锚点时调用：设置开着、而且视频确实没有任何字幕时间
  /// （有效字幕流为空、没有当前句）就建一个合成锚点 cue 返回；否则 null（走原行为——
  /// 有文本字幕时按位置兜底取句，关着时只附静图）。
  ///
  /// 固定窗口当场算好；人声检测先给固定窗口当占位，后台检测完再把锚点换成检测结果
  /// （制卡 / 高级制卡会先等它，见 [_settleUntimedSentenceAudio]）。
  AudioCue? _beginUntimedSentenceAudio(
    VideoPlayerController controller,
    String sentence,
  ) {
    final UntimedSentenceAudioMode mode = appModel.miningUntimedAudioMode;
    if (mode == UntimedSentenceAudioMode.off) return null;
    if (controller.miningCues.isNotEmpty || controller.currentCue != null) {
      return null;
    }
    final int? positionMs = controller.positionMs;
    if (positionMs == null) return null;
    final int windowMs = appModel.miningUntimedAudioWindowMs;
    final bool voice = mode == UntimedSentenceAudioMode.voiceDetection;
    final UntimedSentenceAudioWindow fixed = untimedFixedWindow(
      positionMs: positionMs,
      windowMs: windowMs,
      durationMs: controller.durationMs,
      // 人声检测模式下固定窗口只是占位 / 失败兜底，来源按「检测失败」记，检测成功再换。
      origin: voice
          ? UntimedSentenceAudioOrigin.voiceDetectionFallback
          : UntimedSentenceAudioOrigin.fixedWindow,
    );
    final AudioCue? cue = _untimedAnchorCue(controller, sentence, fixed);
    if (cue == null) return null;
    final _UntimedAudioAnchor anchor = _UntimedAudioAnchor(
      cue: cue,
      window: fixed,
      lookupPositionMs: positionMs,
    );
    _untimedAudioAnchor = anchor;
    if (voice) {
      anchor.pendingRefinement = _refineUntimedAudioByVoice(
        controller,
        anchor,
        sentence: sentence,
        maxMs: windowMs,
      );
    }
    return cue;
  }

  /// 猜出的区间（播放器轴）→ 合成锚点 cue（字幕文件坐标）。制卡链按
  /// `delayMsForCue` 把 cue 逆变换回播放器轴；这条 cue 不属于任何字幕流，取的是
  /// [VideoPlayerController.miningDelayMs]，这里减同一个值，裁出来的正好是 [window]。
  AudioCue? _untimedAnchorCue(
    VideoPlayerController controller,
    String sentence,
    UntimedSentenceAudioWindow window,
  ) {
    final int delayMs = controller.miningDelayMs;
    return buildPlayerDecodedCue(
      text: sentence,
      startMs: window.startMs - delayMs,
      endMs: window.endMs - delayMs,
      positionMs: window.startMs - delayMs,
    );
  }

  /// [cue] 是本页当前的合成锚点时返回它的状态，否则 null。
  _UntimedAudioAnchor? _untimedAudioAnchorFor(AudioCue? cue) {
    final _UntimedAudioAnchor? anchor = _untimedAudioAnchor;
    if (cue == null || anchor == null || !identical(anchor.cue, cue)) {
      return null;
    }
    return anchor;
  }

  /// 当前查词锚点的人声检测还在跑。
  bool get _untimedSentenceAudioPending =>
      _untimedAudioAnchorFor(_lastLookupCue)?.pendingRefinement != null;

  /// 等当前锚点的人声检测跑完（没在跑立即返回）。检测本身不抛错（失败记日志、保留
  /// 固定窗口），这里不会失败。
  Future<void> _settleUntimedSentenceAudio() async {
    final Future<void>? pending = _untimedAudioAnchorFor(
      _lastLookupCue,
    )?.pendingRefinement;
    if (pending != null) await pending;
  }

  /// 人声检测：截暂停位置前后一段音频跑 Silero VAD，取包含暂停位置（或紧挨在前）的
  /// 那段人声替换占位的固定窗口。来源测不了（网络流）/ 模型下不来 / 解不出音频 / 没有
  /// 人声 → 保留固定窗口，来源记「人声检测失败」，原因进错误日志。
  Future<void> _refineUntimedAudioByVoice(
    VideoPlayerController controller,
    _UntimedAudioAnchor anchor, {
    required String sentence,
    required int maxMs,
  }) async {
    try {
      final ({String source, int? audioStreamIndex, int? audioStreamCount})?
      input = _untimedVoiceInput(controller);
      if (input == null) return;
      final ({int startMs, int durationMs}) analysis =
          untimedVoiceAnalysisWindow(
            positionMs: anchor.lookupPositionMs,
            maxMs: maxMs,
            durationMs: controller.durationMs,
          );
      final List<({int startMs, int endMs})> segments =
          await SileroUntimedVoiceSegmentDetector.shared.detect(
            source: input.source,
            audioStreamIndex: input.audioStreamIndex,
            audioStreamCount: input.audioStreamCount,
            startMs: analysis.startMs,
            durationMs: analysis.durationMs,
          );
      final UntimedSentenceAudioWindow? picked = untimedVoiceWindow(
        segments: segments,
        positionMs: anchor.lookupPositionMs,
        maxMs: maxMs,
        headPadMs: appModel.miningAudioHeadPadMs,
        tailPadMs: appModel.miningAudioTailPadMs,
      );
      if (picked == null) return;
      // 检测期间换集 / 关页 / 又查了别的词：结果作废，不碰新的锚点。
      if (!mounted ||
          !identical(_controller, controller) ||
          !identical(_untimedAudioAnchor, anchor)) {
        return;
      }
      final AudioCue? cue = _untimedAnchorCue(controller, sentence, picked);
      if (cue == null) return;
      final bool current = identical(_lastLookupCue, anchor.cue);
      anchor
        ..cue = cue
        ..window = picked;
      if (current) _lastLookupCue = cue;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'VideoFushiPage.untimedVoiceDetection',
        error,
        stack,
      );
    } finally {
      anchor.pendingRefinement = null;
    }
  }

  /// 人声检测读哪份音频：外挂 / 分离的音频源优先（它只有一条音轨），否则视频本身的
  /// 当前播放音轨。只测本地文件——网络流要走播放器中继与防盗链头，这里不为几秒的检测
  /// 再拉一次流，退回固定窗口。
  ({String source, int? audioStreamIndex, int? audioStreamCount})?
  _untimedVoiceInput(VideoPlayerController controller) {
    final String? audioOnly = controller.miningAudioSource;
    final String? source = audioOnly ?? controller.miningSource;
    if (source == null || isNetworkStreamUri(source) || !p.isAbsolute(source)) {
      return null;
    }
    return (
      source: source,
      audioStreamIndex: audioOnly == null
          ? controller.currentAudioStreamIndex
          : null,
      audioStreamCount: audioOnly == null
          ? controller.realAudioStreamCount
          : null,
    );
  }

  /// 高级制卡句子音频区那行「来源」小字；当前锚点不是猜的区间时 null。
  String? _untimedAudioOriginNote() {
    final _UntimedAudioAnchor? anchor = _untimedAudioAnchorFor(_lastLookupCue);
    if (anchor == null) return null;
    return switch (anchor.window.origin) {
      UntimedSentenceAudioOrigin.voiceDetection =>
        t.mining_untimed_audio_origin_voice,
      UntimedSentenceAudioOrigin.fixedWindow =>
        t.mining_untimed_audio_origin_fixed,
      UntimedSentenceAudioOrigin.voiceDetectionFallback =>
        t.mining_untimed_audio_origin_fallback,
    };
  }

  /// 快速制卡（没进高级制卡）用了猜出的区间：弹一次提示，说清是怎么截的、多长。
  void _noticeUntimedSentenceAudio(_UntimedAudioAnchor anchor) {
    final String seconds = (anchor.window.durationMs / 1000).toStringAsFixed(1);
    final String message = switch (anchor.window.origin) {
      UntimedSentenceAudioOrigin.voiceDetection =>
        t.mining_untimed_audio_notice_voice(seconds: seconds),
      UntimedSentenceAudioOrigin.fixedWindow =>
        t.mining_untimed_audio_notice_fixed(seconds: seconds),
      UntimedSentenceAudioOrigin.voiceDetectionFallback =>
        t.mining_untimed_audio_notice_fallback(seconds: seconds),
    };
    _showOsd(message, icon: FushiIcons.audio);
  }
}
