part of '../video_fushi_page.dart';

/// 字幕列表里手改单条字幕（反馈 gleDreKAvo / dpAsMkUjKT）。
///
/// 数据流：字幕列表行菜单「编辑字幕」→ [_editCueText] 弹输入框 → 写 Drift 表
/// `video_subtitle_text_overrides`（键 = 视频 + 字幕源 + 起点 + 原文）→
/// [_reloadSubtitleTextOverrides] 读回这一层覆盖交给
/// [VideoPlayerController.setCueTextOverrides]，控制器把命中的 cue 换成改后文本——
/// 画面字幕、字幕列表、查词、制卡读的都是控制器的 cue，一处换处处生效。
///
/// 覆盖随「视频 + 字幕源」切换：[_currentSubtitleSource] 每次写入、以及控制器每次
/// 换上一份新 cue（[VideoPlayerController.onCuesReplaced]）都重读一次，换源 / 换集 /
/// 重载后照样生效；不同源互不影响（ASR 产物每次是新文件 = 新源）。
extension _VideoSubtitleTextEdit on _VideoFushiPageState {
  /// 当前这一集的覆盖层视频键（与远端字幕偏好同一口径，见 [_remotePositionKeyForIndex]）。
  String get _subtitleTextOverrideVideoKey {
    final (String uid, int episode) = _remotePositionKeyForIndex(
      _currentEpisode,
    );
    return subtitleTextOverrideVideoKey(uid, episode);
  }

  /// 当前主字幕源的覆盖层源键。
  String get _subtitleTextOverrideSourceKey =>
      subtitleTextOverrideSourceKey(_currentSubtitleSource);

  /// 按当前「视频 + 字幕源」从库里重读手改字幕并交给控制器。并发调用只认最后一次
  /// （[_subtitleTextOverrideSeq]）：先发后到的旧读取不会盖掉新源的覆盖。
  Future<void> _reloadSubtitleTextOverrides() async {
    final int seq = ++_subtitleTextOverrideSeq;
    final String videoKey = _subtitleTextOverrideVideoKey;
    final String sourceKey = _subtitleTextOverrideSourceKey;
    SubtitleTextOverrides overrides;
    try {
      overrides = SubtitleTextOverrides.fromRows(
        await appModel.database.getVideoSubtitleTextOverrides(
          videoKey: videoKey,
          sourceKey: sourceKey,
        ),
      );
    } catch (e, st) {
      ErrorLogService.instance.log('video.subtitleTextOverrides.load', e, st);
      overrides = SubtitleTextOverrides.empty;
    }
    if (!mounted || seq != _subtitleTextOverrideSeq) return;
    _controller?.setCueTextOverrides(overrides);
  }

  /// 字幕列表行菜单「编辑字幕」：弹输入框改 [cue] 的文本，保存进覆盖层。
  Future<void> _editCueText(AudioCue cue) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    // 打字时视频别往前跑：编辑期间暂停，关掉对话框后按原状态恢复。
    final bool wasPlaying = controller.isPlaying;
    if (wasPlaying) await controller.pause();
    if (!context.mounted) return;
    final String original = cue.sourceText;
    final String? edited = await showFushiTextInputDialog(
      context: context,
      title: t.video_subtitle_list_edit,
      message: cue.uneditedCue == null
          ? null
          : t.video_subtitle_list_edit_original(text: original),
      initialValue: cue.text,
      icon: FushiIcons.edit,
      maxLines: 4,
    );
    if (!mounted) return;
    if (edited != null && edited != cue.text) {
      await _saveCueTextOverride(cue, edited);
    }
    if (wasPlaying && mounted && identical(_controller, controller)) {
      await controller.play();
    }
  }

  /// 字幕列表行菜单「还原原文」：删掉 [cue] 的手改覆盖。
  Future<void> _restoreCueText(AudioCue cue) async {
    if (cue.uneditedCue == null) return;
    await _saveCueTextOverride(cue, cue.sourceText);
  }

  /// 写入（或在 [edited] 等于原文时删除）[cue] 的覆盖，再重读整层交给控制器。
  Future<void> _saveCueTextOverride(AudioCue cue, String edited) async {
    final String videoKey = _subtitleTextOverrideVideoKey;
    final String sourceKey = _subtitleTextOverrideSourceKey;
    final String original = cue.sourceText;
    final bool restore = edited == original;
    try {
      if (restore) {
        await appModel.database.deleteVideoSubtitleTextOverride(
          videoKey: videoKey,
          sourceKey: sourceKey,
          startMs: cue.startMs,
          originalText: original,
        );
      } else {
        await appModel.database.upsertVideoSubtitleTextOverride(
          VideoSubtitleTextOverridesCompanion.insert(
            videoKey: videoKey,
            sourceKey: sourceKey,
            startMs: cue.startMs,
            originalText: original,
            editedText: edited,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e, st) {
      ErrorLogService.instance.log('video.subtitleTextOverrides.save', e, st);
      _showOsd(
        t.video_subtitle_list_edit_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    await _reloadSubtitleTextOverrides();
    if (!mounted) return;
    _showOsd(
      restore
          ? t.video_subtitle_list_edit_restored
          : t.video_subtitle_list_edit_saved,
      icon: restore ? FushiIcons.undo : FushiIcons.edit,
      severity: ToastSeverity.success,
    );
  }
}
