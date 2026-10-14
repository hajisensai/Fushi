part of '../video_fushi_page.dart';

/// Reuses the subtitle panel's representative-row rules outside its widget.
/// Only subtitle/track changes rebuild rows; position ticks read the cache.
class _VideoRemoteCueCache {
  List<AudioCue>? _primary;
  List<AudioCue>? _secondary;
  String? _key;
  int _primaryLength = -1;
  int _secondaryLength = -1;
  List<VideoRemoteCue> _rows = <VideoRemoteCue>[];

  List<VideoRemoteCue> read(
    VideoPlayerController controller,
    String? primarySource,
    String? secondarySource,
  ) {
    final String key =
        '$primarySource|$secondarySource|${controller.delayMs}|'
        '${controller.effectiveSecondaryDelayMs}';
    if (identical(_primary, controller.cues) &&
        identical(_secondary, controller.secondaryCues) &&
        _primaryLength == controller.cues.length &&
        _secondaryLength == controller.secondaryCues.length &&
        _key == key) {
      return _rows;
    }
    _primary = controller.cues;
    _secondary = controller.secondaryCues;
    _primaryLength = controller.cues.length;
    _secondaryLength = controller.secondaryCues.length;
    _key = key;
    _rows =
        <VideoRemoteCue>[
          ..._trackRows(controller.cues, 'primary', controller.delayMs),
          ..._trackRows(
            controller.secondaryCues,
            'secondary',
            controller.effectiveSecondaryDelayMs,
          ),
        ]..sort((VideoRemoteCue a, VideoRemoteCue b) {
          final int time = (a.startMs + a.delayMs).compareTo(
            b.startMs + b.delayMs,
          );
          return time != 0 ? time : a.id.compareTo(b.id);
        });
    return _rows;
  }

  List<VideoRemoteCue> _trackRows(
    List<AudioCue> cues,
    String track,
    int delay,
  ) {
    return <VideoRemoteCue>[
      for (final ({int rawIndex, String text, int startMs, int endMs}) row
          in subtitleTranscriptRowSpans(cues))
        VideoRemoteCue(
          id: '$track:${row.rawIndex}',
          text: row.text,
          startMs: row.startMs,
          endMs: row.endMs,
          delayMs: delay,
          track: track,
        ),
    ];
  }
}

extension _VideoRemoteControl on _VideoFushiPageState {
  void _unregisterVideoRemote() {
    final VideoRemotePlaybackBinding? binding = _videoRemoteBinding;
    if (binding != null) appModel.videoRemoteHost.unregister(binding);
    _videoRemoteBinding = null;
  }

  void _registerVideoRemote(VideoPlayerController controller) {
    _unregisterVideoRemote();
    final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
      identity: () =>
          '$_activeBookUid|$_currentEpisode|$_currentVideoPath|'
          '${controller.miningSource}',
      title: () => _videoMiningDocumentTitle() ?? '',
      bookUid: () => _activeBookUid,
      sectionIndex: () => _favoriteSectionIndex ?? 0,
      cues: () => _videoRemoteCueCache.read(
        controller,
        _currentSubtitleSource,
        _currentSecondarySubtitleSource,
      ),
      state: () => <String, Object?>{
        'positionMs': controller.positionMs ?? 0,
        'durationMs': controller.durationMs ?? 0,
        'playing': controller.isPlaying,
        'speed': controller.speed,
        'controlRevision': controller.remoteControlRevision,
        'primaryTrack': controller.activeSubtitleTrackId,
        'secondaryTrack': controller.secondaryCues.isNotEmpty
            ? 'secondary'
            : null,
        'primaryDelayMs': controller.delayMs,
        'secondaryDelayMs': controller.effectiveSecondaryDelayMs,
      },
      command: (String action, Map<String, dynamic> body) async {
        switch (action) {
          case 'play':
            await controller.play();
          case 'pause':
            await controller.pause();
          case 'seek':
          case 'seekCue':
            final int position = (body['positionMs'] as num).toInt();
            await controller.seekMs(
              position.clamp(0, controller.durationMs ?? position),
            );
            if (action == 'seekCue') await controller.play();
          default:
            throw const VideoRemoteException(400, 'invalid_action');
        }
      },
      mine: _mineRemoteVideoCue,
      // 手机试听放的是电脑会写进卡片的那段（与 [_mineRemoteVideoCue] 同一个
      // [_remoteVideoMiningWindow]，含首尾留白与调轴），不是按 cue 边界放（BUG-3350）。
      previewAudio: (VideoRemoteCue anchor, int startMs, int endMs) async {
        final ({int clipStartMs, int clipEndMs}) window =
            _remoteVideoMiningWindow(controller, anchor, startMs, endMs);
        if (window.clipEndMs <= window.clipStartMs) return false;
        await controller.playRangeMs(window.clipStartMs, window.clipEndMs);
        return true;
      },
      stopAudio: controller.stopPlayRange,
      openFavorite: _openRemoteVideoFavorite,
      addListener: controller.addListener,
      removeListener: controller.removeListener,
      favoritesChanged: _refreshFavoritedCueCache,
    );
    _videoRemoteBinding = binding;
    appModel.videoRemoteHost.register(binding);
  }

  /// 遥控制卡 / 试听共用的音频与画面窗：字幕时基区间 `[startMs, endMs]`（[anchor] 所在
  /// 那条字幕流）按本页规则加首尾留白，再按 [anchor] 的调轴换到播放器轴。试听与写卡
  /// 只算这一处（BUG-2196 ②）。
  ({int clipStartMs, int clipEndMs}) _remoteVideoMiningWindow(
    VideoPlayerController controller,
    VideoRemoteCue anchor,
    int startMs,
    int endMs,
  ) {
    final AudioPlaybackRange padded = padSentenceRange(
      AudioPlaybackRange(audioFileIndex: 0, startMs: startMs, endMs: endMs),
      cues: anchor.track == 'secondary'
          ? controller.secondaryCues
          : controller.cues,
      headPadMs: appModel.miningAudioHeadPadMs,
      tailPadMs: appModel.miningAudioTailPadMs,
    );
    return (
      clipStartMs: miningClipTimeMs(padded.startMs, anchor.delayMs),
      clipEndMs: miningClipTimeMs(padded.endMs, anchor.delayMs),
    );
  }

  /// 遥控制卡：手机经 `lookupContext` 调好的上下文由宿主冻结成 [selection]
  /// （与本页 [_resolveVideoMiningRange] 同一套草稿合成），这里只按本页规则加
  /// 首尾留白、换到播放器轴再出卡。
  Future<Map<String, Object?>> _mineRemoteVideoCue(
    VideoRemoteCue cue,
    Map<String, dynamic> request,
    VideoRemoteMineSelection selection,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !mounted) {
      throw const VideoRemoteException(409, 'no_video');
    }
    if (controller.isBlurayNavigationSession &&
        (!controller.discMiningAvailable || _discLearningBlocked)) {
      throw const VideoRemoteException(409, 'video_extraction_unavailable');
    }
    final Object? rawFields = request['rawFields'];
    if (rawFields is! Map) {
      throw const VideoRemoteException(400, 'invalid_fields');
    }
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<dynamic, dynamic> entry in rawFields.entries)
        entry.key.toString(): entry.value.toString(),
    };
    if ((fields['expression'] ?? '').trim().isEmpty) {
      throw const VideoRemoteException(400, 'invalid_fields');
    }
    final Object? requestSentence = request['sentence'];
    if (requestSentence != null && requestSentence is! String) {
      throw const VideoRemoteException(400, 'invalid_fields');
    }
    // 手机经 rawFields 原样带来的「高级制卡」覆盖项（遥控页只给句子分区，通常为空；
    // 卡组由落卡层按同一个键读）。与本机制卡同在首个 await 之前读。
    final MiningRequestOverrides? overrides = MiningRequestOverrides.readFrom(
      fields,
    );
    final ({int clipStartMs, int clipEndMs}) window = _remoteVideoMiningWindow(
      controller,
      cue,
      selection.startMs,
      selection.endMs,
    );
    final VideoMiningRange range = applyVideoMiningOverrides((
      clipStartMs: window.clipStartMs,
      clipEndMs: window.clipEndMs,
      // 与本页制卡同：封面锚在合并区间**未 pad** 的起点。
      stillFrameAtMs: miningClipTimeMs(selection.startMs, cue.delayMs),
      sentence: '',
      cueSentence: null,
    ), overrides);
    // 手机调过上下文（加句 / 改字）时以合成文本为准；否则沿用手机带来的句子。
    final String sentence = selection.adjusted
        ? selection.sentence
        : requestSentence as String? ?? selection.sentence;
    final VideoMiningHistorySnapshot history =
        VideoMiningHistorySnapshot.capture(
          fields: fields,
          sentence: sentence,
          documentTitle: _title ?? _activeBookUid,
          bookKey: _activeBookUid,
          sectionIndex: _favoriteSectionIndex,
          cueStartMs: cue.startMs,
          cueEndMs: cue.endMs,
          dateKey: statTodayKey(),
        );
    final FushiDatabase historyDb = appModel.database;
    final String dictionaryMedia = _remoteDictionaryMediaJson(
      fields['dictionaryMedia'] ?? '',
    );
    String? error;
    // 宿主校验完查词上下文后同步调到这里：从那一刻到 [_mineVideoCard] 冻结播放器输入
    // 之间不得有任何 await，否则这段时间里换集（手机 openFavorite / 电脑本地换集）
    // 会让卡片用旧集字幕的时间去裁新集的音频和画面。
    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      stillFrameAtMs: range.stillFrameAtMs,
      sentence: sentence,
      cueSentence: selection.cueSentence,
      overrides: overrides,
      silent: true,
      forceForeground: true,
      forceSubtitleStart: true,
      localOnly: true,
      onFailure: (String code) => error = code,
      // 手机弹框里的词典是本机这几部（手机端查的就是本机词典）：外字等词典媒体落进
      // 本机 Anki 媒体缓存，与本机弹框制卡同一步骤（手机那边没有这些字节）。
      writeFieldsMedia: () => writeDictionaryMediaCache(dictionaryMedia),
    );
    if (result.ankiConnect) {
      await _recordMinedSentenceForVideo(history, result.noteId, db: historyDb);
    }
    return <String, Object?>{
      ...result.toJson(),
      'success': result.ankiConnect,
      if (error != null) 'error': error,
    };
  }

  /// 手机送来的词典媒体清单（`[{dictionary, path}]`）只留路径落在词典资源根内的
  /// 条目：缓存文件名取自路径扩展名，越级路径不许进写盘那一步。
  static String _remoteDictionaryMediaJson(String raw) {
    if (raw.isEmpty || raw == '[]') return raw;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return '[]';
    }
    if (decoded is! List) return '[]';
    return jsonEncode(<Map<String, String>>[
      for (final Object? item in decoded)
        if (item is Map &&
            item['dictionary'] is String &&
            item['path'] is String &&
            safeDictionaryMediaPath(item['path'] as String) != null)
          <String, String>{
            'dictionary': item['dictionary'] as String,
            'path': safeDictionaryMediaPath(item['path'] as String)!,
          },
    ]);
  }

  Future<void> _openRemoteVideoFavorite(FavoriteSentence favorite) async {
    final String? uid = favorite.bookKey;
    if (uid == null || uid.isEmpty) {
      throw const VideoRemoteException(404, 'favorite_source_unavailable');
    }
    if (uid == _activeBookUid &&
        _isRemote &&
        (favorite.sectionIndex ?? 0) != (_favoriteSectionIndex ?? 0)) {
      final int episode = favorite.sectionIndex ?? 0;
      if (episode < 0 || episode >= _episodes.length) {
        throw const VideoRemoteException(404, 'favorite_source_unavailable');
      }
      await _controller?.pause();
      if (!mounted) throw const VideoRemoteException(409, 'no_video');
      await _loadRemoteEpisode(
        episode,
        startIntent: EpisodeStartIntent.explicitCue,
        initialPositionMsOverride: favorite.normCharOffset,
      );
      if (_controller == null || _failed) {
        throw const VideoRemoteException(404, 'favorite_source_unavailable');
      }
      await _openRemoteVideoFavorite(favorite);
      return;
    }
    if (uid == _activeBookUid &&
        (favorite.sectionIndex ?? 0) == (_favoriteSectionIndex ?? 0)) {
      final VideoPlayerController? controller = _controller;
      if (controller == null) {
        throw const VideoRemoteException(409, 'no_video');
      }
      final List<VideoRemoteCue> rows = _videoRemoteCueCache.read(
        controller,
        _currentSubtitleSource,
        _currentSecondarySubtitleSource,
      );
      final List<VideoRemoteCue> candidates = rows
          .where(
            (VideoRemoteCue item) =>
                (favorite.normCharOffset == null ||
                    item.startMs == favorite.normCharOffset) &&
                item.text.trim() == favorite.text.trim(),
          )
          .toList();
      if (candidates.isEmpty && favorite.normCharOffset != null) {
        candidates.addAll(
          rows.where(
            (VideoRemoteCue item) => item.startMs == favorite.normCharOffset,
          ),
        );
      }
      if (candidates.length > 1) {
        throw const VideoRemoteException(409, 'favorite_subtitle_ambiguous');
      }
      final VideoRemoteCue? cue = candidates.firstOrNull;
      if (cue == null) {
        throw const VideoRemoteException(404, 'favorite_subtitle_missing');
      }
      await controller.seekMs(miningClipTimeMs(cue.startMs, cue.delayMs));
      await controller.play();
      return;
    }
    final VideoBookRow? row = await widget.repo.getByBookUid(uid);
    if (row == null) {
      throw const VideoRemoteException(404, 'favorite_source_unavailable');
    }
    if (await isLocalVideoResourceMissing(row.videoPath)) {
      throw const VideoRemoteException(404, 'favorite_source_unavailable');
    }
    final Map<String, int> collections = await appModel.database
        .getPrimaryCollectionIdByEntry();
    if (!context.mounted) throw const VideoRemoteException(409, 'no_video');
    final PageRoute<void>? oldFullscreenRoute = _videoFullscreenRoute;
    final NavigatorState navigator = Navigator.of(context);
    final NavigatorState rootNavigator = Navigator.of(
      context,
      rootNavigator: true,
    );
    final Route<Object?>? currentRoute = ModalRoute.of(context);
    final EpisodeSwitchPlan plan = resolveEpisodeSwitchPlan(
      fullscreenRouteActive: oldFullscreenRoute?.isActive ?? false,
      ownsHandedOverNativeFullscreen: _ownsHandedOverNativeFullscreen,
      hasCurrentRoute: currentRoute != null,
    );
    await _controller?.pause();
    if (!context.mounted) throw const VideoRemoteException(409, 'no_video');
    final Route<void> route = adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoFushiPage.neutralized(
        bookUid: uid,
        repo: widget.repo,
        playlistCollectionId: collections[MediaKind.video.compositeKey(uid)],
        initialRemoteFavorite: favorite,
        initialEpisodeIndex: favorite.sectionIndex,
        initialSubtitleListVisible: false,
        initialFullscreen: plan.handOverNativeFullscreen,
      ),
    );
    _unregisterVideoRemote();
    if (plan.mode == EpisodeSwitchMode.replace) {
      unawaited(navigator.pushReplacement<void, void>(route));
      return;
    }
    _ownsHandedOverNativeFullscreen = false;
    _didInitialFullscreen = true;
    unawaited(navigator.push<void>(route));
    if (oldFullscreenRoute != null && oldFullscreenRoute.isActive) {
      rootNavigator.removeRoute<void>(oldFullscreenRoute);
    }
    navigator.removeRoute<Object?>(currentRoute!);
  }
}
