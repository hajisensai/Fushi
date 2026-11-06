part of '../video_fushi_page.dart';

/// 视频制卡「句子音频来源」（反馈 pNF2ZL7Kfc）：设置 / 高级制卡临时覆盖 → 这一次怎么抽
/// （[planSentenceAudioSource]），以及取不到所选来源时的提示。
///
/// 决策本身是引擎包里的纯函数；这里只负责从播放器读出事实（当前播放音轨、各音轨的
/// 声道布局）和把回退原因说给用户。
extension _VideoSentenceAudioSource on _VideoFushiPageState {
  /// 这一张卡用的来源：高级制卡的覆盖项优先，否则设置。
  SentenceAudioSourcePick _sentenceAudioSourcePickFor(
    MiningRequestOverrides? overrides,
  ) =>
      SentenceAudioSourcePick.tryFromWireName(overrides?.audioSource) ??
      appModel.videoMiningAudioSource;

  /// 真实音轨（去掉 libmpv 的 auto/no 伪轨，顺序 = ffmpeg `0:a:N`）的声道事实。
  /// 布局取 mpv `demux-channels`，声道数取 `demux-channel-count`（都是源文件的，
  /// 不是下混后的输出）。
  List<SentenceAudioTrackInfo> _sentenceAudioTracksOf(
    VideoPlayerController controller,
  ) => <SentenceAudioTrackInfo>[
    for (final AudioTrack track in controller.audioTracks)
      if (track.id != 'auto' && track.id != 'no')
        SentenceAudioTrackInfo(
          channelLayout: track.channels,
          channelCount: track.channelscount,
        ),
  ];

  /// 这一次句子音频怎么抽（见 [planSentenceAudioSource]）。不要音频时恒为现状。
  SentenceAudioSourcePlan _planVideoSentenceAudio(
    VideoPlayerController controller, {
    required SentenceAudioSourcePick pick,
    required bool omitAudio,
  }) {
    final int? playing = controller.currentAudioStreamIndex;
    if (omitAudio) return SentenceAudioSourcePlan(audioStreamIndex: playing);
    return planSentenceAudioSource(
      pick: pick,
      playingIndex: playing,
      tracks: _sentenceAudioTracksOf(controller),
    );
  }

  /// 高级制卡对话框里的来源选项：当前播放音轨、中置声道、这个视频的每条音轨；设置里
  /// 选的来源若不在其中（例如设的是第 5 条而这个视频只有 2 条）也列出来，让「当前
  /// 选中」看得见——确认时照样回退并提示。
  AdvancedMiningAudioSources _advancedMiningAudioSources(
    VideoPlayerController controller,
  ) {
    final SentenceAudioSourcePick setting = appModel.videoMiningAudioSource;
    final List<SentenceAudioSourcePick> choices =
        sentenceAudioSourceDialogChoices(controller.realAudioStreamCount);
    return AdvancedMiningAudioSources(
      choices: choices.contains(setting)
          ? choices
          : <SentenceAudioSourcePick>[...choices, setting],
      defaultPick: setting,
    );
  }

  /// 落卡之后补一句回退提示。制卡结果的 OSD 刚由 [_landVideoMine] 弹出时，把提示
  /// 接在同一条后面（OSD 只有一个槽位，另弹一条会把「已制卡」顶掉）；没弹（静默 /
  /// 用户关了制卡提示）就单独弹一条警告——回退必须让用户知道，不受制卡提示开关管。
  void _reportSentenceAudioFallback({
    required SentenceAudioFallbackReason? reason,
    required SentenceAudioSourcePick pick,
    required _VideoOsdMessage? osdBeforeLanding,
    required bool silent,
  }) {
    if (reason == null || silent || !mounted) return;
    final String notice = sentenceAudioFallbackMessage(reason, pick);
    final _VideoOsdMessage? landed = _osdNotifier.value;
    if (landed == null || identical(landed, osdBeforeLanding)) {
      _showOsd(notice, severity: ToastSeverity.warning);
      return;
    }
    _showOsd(
      '${landed.message}\n$notice',
      icon: landed.icon,
      prominent: landed.prominent,
      severity: ToastSeverity.warning,
      mineStatus: landed.mineStatus,
    );
  }
}
