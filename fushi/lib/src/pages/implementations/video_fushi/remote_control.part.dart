part of '../video_fushi_page.dart';

extension _VideoRemoteControl on _VideoFushiPageState {
  /// 手机的句子列表（与字幕面板同一套代表行）；只有轨 / 调轴变了才重建。
  List<VideoRemoteCue> _videoRemoteRows(VideoPlayerController controller) =>
      _videoRemoteCueCache.read(
        primary: controller.cues,
        secondary: controller.secondaryCues,
        primaryDelayMs: controller.delayMs,
        secondaryDelayMs: controller.effectiveSecondaryDelayMs,
        key: '$_currentSubtitleSource|$_currentSecondarySubtitleSource',
      );

  void _unregisterVideoRemote() {
    final VideoRemotePlaybackBinding? binding = _videoRemoteBinding;
    if (binding != null) appModel.videoRemoteHost.unregister(binding);
    _videoRemoteBinding = null;
  }

  /// 遥控会话身份：作品 / 集 / 视频路径 / 制卡来源任一变了就是新会话。网页档的视频
  /// 路径恒空、站内换片不一定换书（站点入口还没落书时 bookUid 不动），身份另加站点
  /// 视频 key（[_webVideoKey]）。
  String _videoRemoteIdentity(VideoPlayerController controller) =>
      '$_activeBookUid|$_currentEpisode|$_currentVideoPath|'
      '${controller.miningSource}|'
      '${controller.isWebBackend ? _webVideoKey : ''}';

  /// 本地 / 远端 / 网页档三种片源共用这一个绑定：按片源分流的只有字幕轨、在线字幕下载
  /// 与制卡（网页档没有本地媒体，字幕按「站点视频 → 轨」管，见 [_VideoWebSource]），其余
  /// 都走 controller 与页面原有入口。
  void _registerVideoRemote(VideoPlayerController controller) {
    final bool web = controller.isWebBackend;
    final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
      identity: () => _videoRemoteIdentity(controller),
      title: () => _videoMiningDocumentTitle() ?? '',
      bookUid: () => _activeBookUid,
      sectionIndex: () => _favoriteSectionIndex ?? 0,
      cues: () => _videoRemoteRows(controller),
      state: () => <String, Object?>{
        'positionMs': controller.positionMs ?? 0,
        'durationMs': controller.durationMs ?? 0,
        'playing': controller.isPlaying,
        'speed': controller.speed,
        'controlRevision': controller.remoteControlRevision,
        'primaryTrack': web
            ? _webActiveTrackKey
            : controller.activeSubtitleTrackId,
        'secondaryTrack': controller.secondaryCues.isNotEmpty
            ? 'secondary'
            : null,
        'primaryDelayMs': controller.delayMs,
        'secondaryDelayMs': controller.effectiveSecondaryDelayMs,
        // 音量 / 选集的显示值（手机音量条、选集按钮可用与否）。
        'volume': _volumeDisplay.value.round(),
        'episodeIndex': _currentEpisode,
        'episodeCount': _episodes.length,
        // 选词光标在哪（手机触控板据此切换手势）。
        'caret': _remoteCaretSurface,
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
            final int target = position.clamp(
              0,
              controller.durationMs ?? position,
            );
            _recordVideoJumpDeparture(target);
            await controller.seekMs(target);
            if (action == 'seekCue') await controller.play();
          default:
            throw const VideoRemoteException(400, 'invalid_action');
        }
      },
      mine: web ? _mineRemoteWebCue : _mineRemoteVideoCue,
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
      // 音量不经 controller 通知（见 [_volumeDisplay]），电脑上调音量也要推给手机。
      addListener: (VoidCallback listener) {
        controller.addListener(listener);
        _volumeDisplay.addListener(listener);
      },
      removeListener: (VoidCallback listener) {
        controller.removeListener(listener);
        _volumeDisplay.removeListener(listener);
      },
      favoritesChanged: _refreshFavoritedCueCache,
      // 以下三组与桌面控制通道（[_playbackRemote]）/ 剧集列表同一批执行体。
      setVolume: (int volume) => _applyUserVideoVolume(volume.toDouble()),
      episodes: _remoteEpisodes,
      switchEpisode: _switchRemoteControlledEpisode,
      subtitleTracks: web ? _remoteWebSubtitleOptions : _remoteSubtitleOptions,
      selectSubtitleTrack: web
          ? _selectRemoteWebSubtitleOption
          : _selectRemoteSubtitleOption,
      // 在线搜字幕：与字幕工作台「本集」同一组默认值与检索请求，下载后走同一个
      // [_applyDownloadedSubtitles]（网页档登记成站点视频的一条轨）。
      searchSubtitles: _searchRemoteOnlineSubtitles,
      downloadSubtitle: (String id) => web
          ? _downloadRemoteWebOnlineSubtitle(controller, id)
          : _downloadRemoteOnlineSubtitle(controller, id),
      // 手机触控板驱动的是本页的字幕选词光标（与键盘 / 手柄同一套），查词卡弹在
      // 电脑屏幕上。
      caret: (String step) => _runRemoteCaretStep(controller, step),
      // 手机选集的封面与本页剧集面板同一份图源。
      episodeCover: _remoteEpisodeCover,
      // 手机「关闭视频」：与点播换片同一条媒体切换队列、同一个退出流程（落进度）。
      close: _closeForRemote,
    );
    // 先登记新的再撤旧的：先撤会让宿主回落到压在下面的播放器（浏览页等），手机闪一下。
    final VideoRemotePlaybackBinding? previous = _videoRemoteBinding;
    _videoRemoteBinding = binding;
    appModel.videoRemoteHost.register(binding);
    if (previous != null) appModel.videoRemoteHost.unregister(previous);
  }

  /// 手机选集列表：与剧集轨道同一份 [_episodes]（单视频为空）。
  List<VideoRemoteEpisode> _remoteEpisodes() => <VideoRemoteEpisode>[
    for (int i = 0; i < _episodes.length; i++)
      VideoRemoteEpisode(
        index: i,
        title: _episodes[i].displayTitle ?? _episodes[i].title,
        current: i == _currentEpisode,
        hasCover: _remoteEpisodeHasCover(_episodes[i]),
      ),
  ];

  /// 这一集有没有可给手机预览的封面（与剧集面板同一份图源）。
  bool _remoteEpisodeHasCover(_PlaylistEpisodeRef episode) =>
      (episode.coverPath?.isNotEmpty ?? false) ||
      ((episode.coverUrl?.isNotEmpty ?? false) && _episodeCoverFetcher != null);

  /// 手机选集的封面字节：本地集读 `coverPath`，远端集经剧集面板同一个取图器拉
  /// `coverUrl`；都没有返回 null（电脑回 `cover_missing`，手机画占位）。远端取图
  /// 失败记诊断日志并回 `502 cover_unavailable`（与「没有封面」分开），手机同样画
  /// 占位、下次进入视野再问。
  Future<Uint8List?> _remoteEpisodeCover(int index) async {
    if (index < 0 || index >= _episodes.length) return null;
    final _PlaylistEpisodeRef episode = _episodes[index];
    final String? path = episode.coverPath;
    if (path != null && path.isNotEmpty) {
      final File file = File(path);
      if (await file.exists()) return file.readAsBytes();
    }
    final String? url = episode.coverUrl;
    final RemoteCoverFetcher? fetcher = _episodeCoverFetcher;
    if (url == null || url.isEmpty || fetcher == null) return null;
    try {
      return await fetcher.fetchRemoteCover(url);
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'VideoFushiPage.remoteEpisodeCover',
        error,
      );
      throw const VideoRemoteException(502, 'cover_unavailable');
    }
  }

  /// 手机「关闭视频」：只关被遥控的这一页。别的媒体页压在它上面（当前登记的不是
  /// 本页）或本页退出被拦下（落进度失败、压着对话框）都回 `host_busy`，不硬拆。
  Future<void> _closeForRemote() =>
      ExternalMediaNavigation.instance.navigate(() async {
        if (!mounted || !ExternalMediaNavigation.instance.isActive(this)) {
          throw const VideoRemoteException(409, 'host_busy');
        }
        if (!await ExternalMediaNavigation.instance.closeActive()) {
          throw const VideoRemoteException(409, 'host_busy');
        }
      });

  /// 手机选集：与剧集列表点选同一入口（[_switchEpisode]，listSelect）。不等它
  /// 完成——本地换集是 pushReplacement 到新页，其 Future 要等新页退出才 settle，
  /// 等它会把遥控宿主的串行队列一直卡住；新集的会话经新页登记推给手机。
  Future<void> _switchRemoteControlledEpisode(int index) async {
    if (!mounted) throw const VideoRemoteException(409, 'no_video');
    unawaited(
      _switchEpisode(index, intent: EpisodeStartIntent.listSelect).catchError((
        Object error,
        StackTrace stack,
      ) {
        ErrorLogService.instance.log(
          'VideoFushiPage.remoteSwitchEpisode',
          error,
          stack,
        );
      }),
    );
  }

  /// 手机字幕轨列表：与桌面控制通道 `video subs` 同一份轨表（本机视频首次会枚举
  /// 内封轨，与打开设置面板「字幕」分类同一条枚举）。轨的 source 可能是本机文件
  /// 路径，只把它的摘要交给手机。
  Future<List<VideoRemoteSubtitleOption>> _remoteSubtitleOptions() async {
    final VideoRemoteSubtitleState state;
    try {
      state = await _playbackRemote.subtitleState();
    } on VideoRemoteFailure catch (failure) {
      throw _remoteSubtitleException(failure);
    }
    return <VideoRemoteSubtitleOption>[
      for (final VideoRemoteSubtitleTrack track in state.tracks)
        VideoRemoteSubtitleOption(
          id: videoRemoteSubtitleOptionId(track.source),
          label: track.label,
          kind: track.kind.name,
          selected: track.primary,
          selectable: track.selectable,
        ),
    ];
  }

  /// 手机选主字幕（null = 关闭）：与字幕面板主字幕行 / 「关闭」行同一入口。
  Future<void> _selectRemoteSubtitleOption(String? id) async {
    try {
      if (id == null) {
        await _playbackRemote.subtitleOff(secondary: false);
        return;
      }
      final VideoRemoteSubtitleState state = await _playbackRemote
          .subtitleState();
      final VideoRemoteSubtitleTrack? track = state.tracks.firstWhereOrNull(
        (VideoRemoteSubtitleTrack t) =>
            videoRemoteSubtitleOptionId(t.source) == id,
      );
      if (track == null) {
        throw const VideoRemoteException(404, 'subtitle_track_missing');
      }
      if (!track.selectable) {
        throw const VideoRemoteException(409, 'subtitle_track_unavailable');
      }
      if (track.primary) return;
      await _playbackRemote.selectSubtitle(track.source, secondary: false);
    } on VideoRemoteFailure catch (failure) {
      throw _remoteSubtitleException(failure);
    }
  }

  /// 选词光标所在的表面，按遥控协议的取值（`none` / `video` / `popup`）。
  String get _remoteCaretSurface => switch (_videoCaret.surface) {
    CaretSurface.video => 'video',
    CaretSurface.popup => 'popup',
    CaretSurface.none || CaretSurface.reader || CaretSurface.lyrics => 'none',
  };

  /// 手机触控板的一步（`videoRemoteCaretActions`）→ 字幕选词光标动作。与手柄
  /// 同一个执行体（[_enterSubtitleCaret] / [_runVideoCaretAction]）：主面上左右
  /// 按阅读顺序逐字挪、确认即查词（查词卡弹出后光标转进卡里），卡里确认按下
  /// 光标所在的按钮（＋ = 制卡），后退逐层关卡、最后退出光标并恢复它暂停的播放。
  /// 光标没开时只认 `enter`，其余步是空操作（手机据回报的 `none` 退回空闲手势）。
  Future<String> _runRemoteCaretStep(
    VideoPlayerController controller,
    String step,
  ) async {
    if (!mounted) throw const VideoRemoteException(409, 'no_video');
    if (step == 'enter') {
      if (!_videoCaretActive) _enterSubtitleCaret(controller);
      return _remoteCaretSurface;
    }
    if (!_videoCaretActive) return _remoteCaretSurface;
    await _runVideoCaretAction(switch (step) {
      'left' => CaretAction.stepBackward,
      'right' => CaretAction.stepForward,
      'up' => CaretAction.moveUp,
      'down' => CaretAction.moveDown,
      'activate' => CaretAction.activate,
      'longPress' => CaretAction.longPress,
      _ => CaretAction.dismissOrExit,
    });
    return _remoteCaretSurface;
  }

  /// 手机「在线搜索字幕」：默认值取本页的番名 / 身份种子 / 集号 / 季号（与
  /// [_openSubtitleWorkbench] 同源）。算不出番名时回空结果，手机自己填词再搜。
  Future<VideoRemoteOnlineSubtitleSearch> _searchRemoteOnlineSubtitles(
    String? query,
    int? episode,
  ) async {
    final String series = _jimakuQuery() ?? '';
    final SubtitleSearchSeed seed = series.isEmpty
        ? const SubtitleSearchSeed()
        : await _buildJimakuSeed(series);
    if (!mounted) throw const VideoRemoteException(409, 'no_video');
    return _remoteOnlineSubtitles.search(
      RemoteOnlineSubtitleContext(
        seriesQuery: series,
        seed: seed,
        episode: _jimakuEpisodeNumber(),
        season: _jimakuSeasonNumber(),
        videoPath: _isRemote ? null : _currentVideoPath,
      ),
      query: query,
      episode: episode,
    );
  }

  /// 手机选中一条在线字幕：电脑下载落盘（本机视频按内嵌轨对齐），返回「应用」
  /// 一步，由遥控宿主核过会话后在命令队列里执行，与字幕工作台下载完成同一入口
  /// 登记并应用。
  ///
  /// 下载期间手机可能已经换集（新集可能就在本页换 controller，也可能
  /// pushReplacement 到新页、本页还没 dispose）：应用前核对本页仍登记着发起时
  /// 那份绑定、controller 与会话身份都没变，否则回 409 `session_changed`，
  /// 绝不把上一集的字幕套到新集 / 已释放的 controller 上。
  Future<VideoRemoteSubtitleApply> _downloadRemoteOnlineSubtitle(
    VideoPlayerController controller,
    String id,
  ) async {
    final VideoRemotePlaybackBinding? binding = _videoRemoteBinding;
    final String identity = _videoRemoteIdentity(controller);
    final String path = await _remoteOnlineSubtitles.download(
      id,
      videoPath: _isRemote ? null : _currentVideoPath,
    );
    return () async {
      if (!mounted) throw const VideoRemoteException(409, 'no_video');
      if (binding == null ||
          !identical(_videoRemoteBinding, binding) ||
          !identical(_controller, controller) ||
          _videoRemoteIdentity(controller) != identity) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      await _applyDownloadedSubtitles(controller, <String>[path]);
    };
  }

  /// 网页档的手机字幕轨列表：与设置面板网页档轨列表同一份（[_buildWebSubtitleTrackRows]）——
  /// 已采到整轨的站点轨 / 下载的字幕，再加站点里还没采到的轨（选中后由站点下载、bridge
  /// 截下）。图片字幕只能让站点自己画（不可查词），照样可选。
  Future<List<VideoRemoteSubtitleOption>> _remoteWebSubtitleOptions() async =>
      <VideoRemoteSubtitleOption>[
        for (final WebVideoTrack track in _currentWebTracks())
          VideoRemoteSubtitleOption(
            id: videoRemoteSubtitleOptionId('web:${track.key}'),
            label: _webTrackLabel(track),
            kind: track.siteTrackId.isEmpty && !track.isLive
                ? 'external'
                : 'embedded',
            selected: track.key == _webActiveTrackKey,
            selectable: true,
          ),
        for (final WebVideoSiteTrack track in _unloadedWebSiteTracks())
          VideoRemoteSubtitleOption(
            id: videoRemoteSubtitleOptionId('site:${track.id}'),
            label: track.name.isEmpty ? track.lang : track.name,
            kind: track.imageBased ? 'graphic' : 'embedded',
            selected: track.imageBased && track.id == _webSiteTrackCurrent,
            selectable: true,
          ),
      ];

  /// 网页档手机选主字幕（null = 关闭）：与设置面板网页档轨行同一入口
  /// （[_selectWebTrack] / [_requestWebSiteTrack]）。
  Future<void> _selectRemoteWebSubtitleOption(String? id) async {
    if (!mounted || !_webMode) {
      throw const VideoRemoteException(409, 'no_video');
    }
    if (id == null) {
      _selectWebTrack(null);
      return;
    }
    for (final WebVideoTrack track in _currentWebTracks()) {
      if (videoRemoteSubtitleOptionId('web:${track.key}') == id) {
        _selectWebTrack(track.key);
        return;
      }
    }
    for (final WebVideoSiteTrack track in _unloadedWebSiteTracks()) {
      if (videoRemoteSubtitleOptionId('site:${track.id}') == id) {
        _requestWebSiteTrack(track, byUser: true);
        return;
      }
    }
    throw const VideoRemoteException(404, 'subtitle_track_missing');
  }

  /// 网页档的在线字幕：落盘后解析成 cue，作为当前站点视频的一条轨登记进 [_webTracks]
  /// 并选中。网页档的字幕都按「站点视频 → 轨」管（[_reselectWebTrack] 每次轨集变化按轨
  /// 重灌 controller），直接 setCues 会被下一次站点轨回报覆盖；登记成轨后设置面板网页档
  /// 轨列表同样列出它、可切回。
  Future<VideoRemoteSubtitleApply> _downloadRemoteWebOnlineSubtitle(
    VideoPlayerController controller,
    String id,
  ) async {
    final VideoRemotePlaybackBinding? binding = _videoRemoteBinding;
    final String identity = _videoRemoteIdentity(controller);
    final String path = await _remoteOnlineSubtitles.download(id);
    final List<AudioCue> cues = await loadVideoRemoteSubtitleFile(
      path,
      _activeBookUid,
    );
    return () async {
      if (!mounted) throw const VideoRemoteException(409, 'no_video');
      if (binding == null ||
          !identical(_videoRemoteBinding, binding) ||
          !identical(_controller, controller) ||
          _videoRemoteIdentity(controller) != identity) {
        throw const VideoRemoteException(409, 'session_changed');
      }
      if (cues.isEmpty) {
        throw const VideoRemoteException(409, 'subtitle_track_unavailable');
      }
      final String name = p.basename(path);
      final String key = '$_webVideoKey|download:$name';
      // 网页轨的显示名取 lang（[_webTrackLabel]）：下载档用文件名。
      _webTracks[key] = WebVideoTrack(
        key: key,
        videoKey: _webVideoKey,
        lang: name,
        cues: cues,
      );
      _selectWebTrack(key);
    };
  }

  /// 网页档的遥控制卡：与本页网页档制卡（[_onWebMineEntry]）同两条路——YouTube 按视频
  /// id + 字幕时间窗从真实视频流裁音频与画面、当场出卡；其它站点没有可截的本地媒体，
  /// 冻结字段与时间窗进网页制卡队列，之后切到可捕获档逐句重放落卡（手机收到「已收下」）。
  Future<Map<String, Object?>> _mineRemoteWebCue(
    VideoRemoteCue cue,
    Map<String, dynamic> request,
    VideoRemoteMineSelection selection,
  ) async {
    final VideoBookRow? row = _bookRow;
    if (!mounted || !_webMode || row == null) {
      throw const VideoRemoteException(409, 'no_video');
    }
    final VideoRemoteMineRequest parsed = parseVideoRemoteMineRequest(request);
    final String sentence = videoRemoteMineSentence(selection, parsed.sentence);
    final WebVideoPlaybackState? state = _webSession?.lastState;
    final String href = state != null && state.href.isNotEmpty
        ? state.href
        : row.videoPath;
    final String? youtubeId = youtubeVideoIdOrNull(href);
    if (youtubeId != null) {
      // 与手机试听同一个窗（含首尾留白与调轴，BUG-3350）：服务端 YouTube 裁剪不再加留白。
      final VideoPlayerController? controller = _controller;
      if (controller == null) throw const VideoRemoteException(409, 'no_video');
      final ({int clipStartMs, int clipEndMs}) window =
          _remoteVideoMiningWindow(
            controller,
            cue,
            selection.startMs,
            selection.endMs,
          );
      final RemoteMineResult res = await appModel
          .createRemoteMiningService()
          .mineImmersion(
            ImmersionMinePayload(
              fields: parsed.fields,
              sentence: sentence,
              cueSentence: selection.cueSentence,
              documentTitle: row.title,
              youtubeVideoId: youtubeId,
              clipStartMs: window.clipStartMs,
              clipEndMs: window.clipEndMs,
            ),
          );
      return <String, Object?>{
        'success': res.result == 'success',
        if (res.result == 'duplicate') 'duplicate': true,
        if (res.result != 'success' && res.result != 'duplicate')
          'error': 'mining_failed',
      };
    }
    await _webMineQueue.enqueue(
      bookUid: _activeBookUid,
      videoKey: _webVideoKey,
      href: href,
      cueStartMs: selection.startMs,
      cueEndMs: selection.endMs,
      sentence: sentence,
      cueSentence: selection.cueSentence,
      fields: parsed.fields,
    );
    await _refreshStagedMineCount();
    if (mounted) {
      _showOsd(
        t.web_video_mine_queued(count: _stagedMineCount.value),
        icon: FushiIcons.checklist,
      );
    }
    return <String, Object?>{
      ...const MinePopupResult.queued().toJson(),
      'success': true,
    };
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
    final ({int startMs, int endMs}) padded = videoRemotePaddedMiningRange(
      startMs: startMs,
      endMs: endMs,
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
    // 手机经 rawFields 原样带来的「高级制卡」覆盖项（遥控页只给句子分区，通常为空；
    // 卡组由落卡层按同一个键读）。与本机制卡同在首个 await 之前读。
    final VideoRemoteMineRequest parsed = parseVideoRemoteMineRequest(request);
    final Map<String, String> fields = parsed.fields;
    final MiningRequestOverrides? overrides = parsed.overrides;
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
    final String sentence = videoRemoteMineSentence(selection, parsed.sentence);
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
    // 已在 [parseVideoRemoteMineRequest] 里清洗（只留词典资源根内的路径）。
    final String dictionaryMedia = fields['dictionaryMedia'] ?? '';
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
      final VideoRemoteCue cue = matchVideoRemoteFavoriteCue(
        _videoRemoteRows(controller),
        favorite,
      );
      final int favoriteMs = miningClipTimeMs(cue.startMs, cue.delayMs);
      _recordVideoJumpDeparture(favoriteMs);
      await controller.seekMs(favoriteMs);
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

/// 桌面控制通道的字幕失败 → 遥控协议错误码（手机按码本地化）。
VideoRemoteException _remoteSubtitleException(VideoRemoteFailure failure) =>
    switch (failure.code) {
      'no_video' => const VideoRemoteException(409, 'no_video'),
      'busy' => const VideoRemoteException(409, 'subtitle_busy'),
      'not_found' => const VideoRemoteException(404, 'subtitle_track_missing'),
      _ => const VideoRemoteException(409, 'subtitle_track_unavailable'),
    };
