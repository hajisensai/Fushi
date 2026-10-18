part of '../video_fushi_page.dart';

/// 网页档没有站点视频时，顶部返回条的高度（站点页面让在它下面，返回钮不压在 WebView 上——
/// 收输入的 WebView2 子窗口会先于 Flutter 吃掉落在它矩形里的点击）。
const double _kVideoWebPageBarHeight = 56;

/// 网页档（站点视频，[VideoPlayerController.isWebBackend]）能服务的控制条按钮：逐帧 /
/// 截图 / 片段导出 / 音轨 / 章节 / 弹幕都要 libmpv 或本地媒体文件，一律不画。纯函数，
/// 控制条门控 `_shouldRenderControlItem` 与测试同源调用。
@visibleForTesting
bool videoWebBackendSupportsControlItem(VideoControlItem item) {
  switch (item) {
    case VideoControlItem.frameBackward:
    case VideoControlItem.frameForward:
    case VideoControlItem.screenshot:
    case VideoControlItem.clipExport:
    case VideoControlItem.audioTrack:
    case VideoControlItem.previousChapter:
    case VideoControlItem.nextChapter:
    case VideoControlItem.chapterList:
    case VideoControlItem.danmaku:
      return false;
    default:
      return true;
  }
}

/// 网页档设置面板的分组：着色器 / mpv / 弹幕都作用在 libmpv 或本地文件上，去掉。
@visibleForTesting
List<settings_dest.VideoGroup> videoWebBackendSettingsGroups(
  List<settings_dest.VideoGroup> groups,
) => <settings_dest.VideoGroup>[
  for (final settings_dest.VideoGroup g in groups)
    if (g != settings_dest.VideoGroup.shaders &&
        g != settings_dest.VideoGroup.mpv &&
        g != settings_dest.VideoGroup.danmaku)
      g,
];

/// 网页站点后端（底层合成）的页面侧：Netflix / YouTube 页这类流媒体书在原生播放器页里
/// 播放——站点画面由垫在 Flutter 下面的 WebView2 子窗口（硬件 PlayReady，Netflix 4K）
/// 自己画，从透明像素处透出来；控制条、字幕叠层、查词、收藏、快捷键全是本页原有的那套，
/// 播放动作经 [WebVideoPlatformPlayer] 变成页面 JS。
///
/// 字段（[_webSession] 等）留在主壳——extension 不能带字段。
extension _VideoWebSource on _VideoFushiPageState {
  /// 网页站流媒体书的入口（[_initVideo] 分流到这里）：宿主档按用户偏好（没选过且引擎能做
  /// 底层合成 = 4K 窗口档）。窗口档拿到底层合成就在本页播；否则交给内置网页播放器页
  /// （它自己的 DOM 字幕层 / 超分 / 制卡重放）。
  Future<void> _openWebSource(VideoBookRow row) async {
    final Object? pref = appModel.prefsRepo.getPref(kWebVideoHostingPrefKey);
    final WebVideoHosting hosting =
        pref == null && await underlayCompositionSupported()
        ? WebVideoHosting.windowed
        : webVideoHostingFromPref(pref);
    if (!mounted) return;
    if (hosting == WebVideoHosting.windowed &&
        await acquireUnderlayComposition()) {
      if (!mounted) {
        // dispose 已在 await 期间跑过（那时还没持有），这份由这里归还。
        unawaited(releaseUnderlayComposition());
        return;
      }
      _webUnderlayHeld = true;
      await _initWebSource(row);
      return;
    }
    if (!context.mounted) return;
    // media_kit controller 尚未 load，pushReplacement 代价只是本页一次空 build。
    unawaited(
      Navigator.of(context).pushReplacement(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => WebVideoFushiPage.neutralized(
            bookUid: _activeBookUid,
            repo: widget.repo,
            hosting: hosting,
          ),
        ),
      ),
    );
  }

  /// 建会话（脚本 / 4K 环境 / 登录 cookie）→ 网页播放器后端 → [VideoPlayerController.loadWeb]，
  /// 再按本地分支同一批页面状态收尾（调轴 / 倍速 / 字幕样式 / 控件布局 / 进度 / 观看统计 /
  /// 收藏 / 查词浮层预热）。跳过的是只对 libmpv 或本地文件成立的那些：缩略图预览、内嵌字幕
  /// 预热、字体抽取、音轨恢复、弹幕。会话准备好之前是普通加载态；之后视频区最底层就是站点
  /// 页面（登录页在有视频之前就要能用）。
  Future<void> _initWebSource(VideoBookRow row) async {
    _setLoadingPhase(_VideoLoadPhase.connecting);
    _delayMs = row.delayMs;
    _secondaryDelayMs = row.secondaryDelayMs;
    _playbackSpeed = _readPersistedSpeed();
    _playbackVolume = _readPersistedVolume();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _controlLayoutNotifier.value = appModel.videoControlLayout;
    _customActionBindingsNotifier.value = appModel.videoCustomActionBindings;
    _videoFitMode = appModel.videoFitMode;
    final WebVideoSession session = WebVideoSession(
      bookUid: _activeBookUid,
      pageUrl: row.videoPath,
      onTrack: _onWebTrack,
      onState: _onWebState,
      onKeyToken: _onWebKeyToken,
    );
    final VideoPlayerController controller = VideoPlayerController();
    final WebVideoPlatformPlayer platform = WebVideoPlatformPlayer(
      evaluate: session.evaluate,
    );
    // loadWeb 起 Player 之后，后端随 controller.dispose 一起释放；之前失败要自己放。
    bool handedToPlayer = false;
    try {
      await session.prepare(shortcuts: appModel.shortcutRegistry);
      if (!mounted) {
        session.dispose();
        controller.dispose();
        unawaited(platform.dispose());
        return;
      }
      _pendingController = controller;
      handedToPlayer = true;
      await controller.loadWeb(
        platform: platform,
        bookUid: _activeBookUid,
        pageUrl: row.videoPath,
        initialSpeed: _playbackSpeed,
        initialVolume: _playbackVolume,
      );
    } catch (e, st) {
      // WebView2 Runtime 缺失 / 用户数据目录被占 / 资产缺失：落进带返回键的失败态。
      ErrorLogService.instance.log('VideoFushi.web', e, st);
      session.dispose();
      controller.dispose();
      if (!handedToPlayer) unawaited(platform.dispose());
      _pendingController = null;
      if (mounted) {
        _rebuild(() {
          _failed = true;
          _failReason = t.video_load_failed_generic;
        });
      }
      return;
    }
    if (!mounted) {
      session.dispose();
      return;
    }
    controller.setDelayMs(_delayMs);
    controller.setSecondaryDelayMs(_secondaryDelayMs);
    controller.onPositionWrite = _persistWebPosition;
    _titleNotifier.value = row.title;
    _rebuild(() {
      _webSession = session;
      _webPlatform = platform;
      _controller = controller;
      _pendingController = null;
      _title = row.title;
      _failed = false;
      _failReason = null;
      _currentVideoPath = null;
      // 页级加载态到此为止：视频区从这一帧起就是站点页面（登录 / 选人），有了 <video>
      // 再挂播放器控件。
      _videoReadyToShow = true;
    });
    _syncVolumeDisplay(controller.volume);
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    _seedWarmPopup();
    unawaited(_refreshFavoritedCueCache());
    unawaited(_refreshStagedMineCount());
    _ensureWatchTracker(controller, row.title);
  }

  /// 进度写库：与本地书同一条 [_persistPosition]（lastPositionMs + 远端进度镜像 + 片长），
  /// 但播放头不足 [kWebVideoMinPersistPositionMs] 不算「看过」（站点自己从片头起播 /
  /// 片头广告，不能把已有进度抹成 0）。
  Future<void> _persistWebPosition(String uid, int posMs) async {
    if (posMs < kWebVideoMinPersistPositionMs) return;
    await _persistPosition(uid, posMs);
  }

  /// 页面快照 → 播放器状态；换集 / 有无视频的切换驱动选轨、输入归属与布局。
  void _onWebState(WebVideoPlaybackState state) {
    final WebVideoSession? session = _webSession;
    if (!mounted || session == null) return;
    _webPlatform?.applySnapshot(
      state,
      volume: state.volume,
      muted: state.muted,
      buffering: state.buffering,
    );
    final bool videoChanged = state.videoKey != _webVideoKey;
    if (videoChanged) {
      _webVideoKey = state.videoKey;
      _webActiveTrackKey = null;
      _reselectWebTrack();
    }
    // 站点自己的全屏钮（网页档里点的）= 「我要看了」：换成播放器档 + 窗口全屏。
    if (state.fullscreen && state.hasVideo && !_webPlayerModeFor(state)) {
      _webForcePlayerKey = state.videoKey;
      _webBrowseVideoKey = null;
      unawaited(session.exitPageFullscreen());
      if (!_webWindowFullscreen) unawaited(_toggleWebWindowFullscreen());
    }
    final bool playerMode = _webPlayerModeFor(state);
    session.syncInput(playerMode: playerMode, videoChanged: videoChanged);
    final VideoPlayerController? controller = _controller;
    if (controller != null) _syncVolumeDisplay(controller.volume);
    // 标题后缀站点实际解码的分辨率：4K 档画质够不够一眼可见。
    final String base = _bookRow?.title ?? _title ?? '';
    final String title = state.hasVideo && state.videoHeight > 0
        ? '$base · ${state.videoHeight}p'
        : base;
    if (_titleNotifier.value != title) _titleNotifier.value = title;
    if (playerMode != _webPlayerMode || state.hasVideo != _webPageHasVideo) {
      _rebuild(() {
        _webPlayerMode = playerMode;
        _webPageHasVideo = state.hasVideo;
      });
      // 进了播放器档：WebView 不再收输入，键盘焦点收回播放器。
      if (playerMode) {
        _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
      }
    }
  }

  /// 这份快照该不该是播放器档：没视频一定不是；用户对**这一集**点过「回到网页」/「在播放器里
  /// 看」以用户为准（换一集即失效——在网页里点了另一集，就自动进播放器）；否则看地址是不是
  /// 播放页（[webVideoIsWatchPage]：Netflix 浏览页的预告片不算）。
  bool _webPlayerModeFor(WebVideoPlaybackState state) {
    if (!state.hasVideo) return false;
    if (_webBrowseVideoKey == state.videoKey) return false;
    if (_webForcePlayerKey == state.videoKey) return true;
    return webVideoIsWatchPage(state.href);
  }

  /// 「回到网页」/「在播放器里看」：只改这一集的档位，同一个 WebView 原地切（不重载、不断播）。
  void _setWebPlayerMode(bool on) {
    final WebVideoSession? session = _webSession;
    final WebVideoPlaybackState? state = session?.lastState;
    if (session == null || state == null) return;
    if (on) {
      _webForcePlayerKey = state.videoKey;
      _webBrowseVideoKey = null;
    } else {
      _webBrowseVideoKey = state.videoKey;
      _webForcePlayerKey = null;
      // 网页档要在窗口里选集：窗口全屏一起退掉。
      if (_webWindowFullscreen) unawaited(_toggleWebWindowFullscreen());
    }
    _onWebState(state);
  }

  /// 播放器档右上组头部的「回到网页」：与原盘「主菜单」同一个挂法（随控制条显隐、窄屏收进「⋯」）。
  List<VideoBarEntry> _webPageBarEntries({required bool desktop}) {
    void run() => _setWebPlayerMode(false);
    return <VideoBarEntry>[
      VideoBarEntry(
        priority: 87,
        menuAction: VideoBarMenuAction(
          icon: Icons.web,
          label: t.web_video_page_show,
          onSelected: run,
        ),
        child: FushiTooltip(
          message: t.web_video_page_show,
          child: KeyedSubtree(
            key: const ValueKey<String>('video-web-page-show'),
            child: _chromeIconButton(
              icon: Icons.web,
              desktop: desktop,
              onPressed: run,
            ),
          ),
        ),
      ),
    ];
  }

  void _onWebTrack(WebVideoTrack track) {
    if (!mounted) return;
    _webTracks[track.key] = track;
    _reselectWebTrack();
  }

  /// 轨集 / 当前视频变化后重选当前轨并灌进 controller（同轨更新也要灌：live 轨边看边长）。
  /// 选择规则与内置网页播放器同一份 [chooseWebVideoTrackKey]（内容语言偏好 > 整轨 > live）。
  void _reselectWebTrack() {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.isWebBackend) return;
    final String? next = _webSubtitlesOff
        ? null
        : chooseWebVideoTrackKey(
            tracks: _webTracks.values,
            videoKey: _webVideoKey,
            preferredLanguage: _bookRow?.language,
            current: _webActiveTrackKey,
          );
    final bool changed = next != _webActiveTrackKey;
    _webActiveTrackKey = next;
    final WebVideoTrack? track = next == null ? null : _webTracks[next];
    controller.setCues(track?.cues ?? const <AudioCue>[]);
    final int? pos = controller.positionMs;
    if (pos != null) controller.updateCueForPosition(pos);
    if (changed) _rebuild(() {});
  }

  /// 当前视频可选的站点字幕轨（有 cue 的才列）。
  List<WebVideoTrack> _currentWebTracks() => <WebVideoTrack>[
    for (final WebVideoTrack track in _webTracks.values)
      if (track.videoKey == _webVideoKey && track.cues.isNotEmpty) track,
  ];

  void _selectWebTrack(String? key) {
    _webSubtitlesOff = key == null;
    _webActiveTrackKey = key;
    _reselectWebTrack();
    _rebuild(() {});
  }

  /// 设置面板「字幕」分类顶部的轨列表（网页档）：关闭 + 站点每条轨。导入文件 / 自动获取 /
  /// 转录 / 对轴这些行都要本地媒体，网页档不列。
  Widget _buildWebSubtitleTrackRows(BuildContext context) {
    final Color? selectedFg = videoPanelSelectedForeground(context);
    final List<WebVideoTrack> tracks = _currentWebTracks();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiListTileControl(
          key: const ValueKey<String>('video-web-subtitle-off'),
          leading: const FushiIcon(Icons.subtitles_off),
          title: Text(t.video_subtitle_off),
          selected: _webActiveTrackKey == null,
          selectedColor: selectedFg,
          onTap: () => _selectWebTrack(null),
        ),
        if (tracks.isEmpty)
          FushiListTileControl(
            dense: true,
            leading: const FushiIcon(Icons.closed_caption_outlined),
            title: Text(t.web_video_no_tracks),
            enabled: false,
          ),
        for (final WebVideoTrack track in tracks)
          FushiListTileControl(
            key: ValueKey<String>('video-web-subtitle-${track.key}'),
            leading: const FushiIcon(Icons.closed_caption_outlined),
            title: Text(track.isLive ? t.web_video_track_live : track.lang),
            selected: track.key == _webActiveTrackKey,
            selectedColor: selectedFg,
            onTap: () => _selectWebTrack(track.key),
          ),
      ],
    );
  }

  /// WebView2 持焦（登录页里点过）时截获的视频快捷键：走与键盘同一张动作表。
  void _onWebKeyToken(String token) {
    if (!mounted) return;
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: appModel.shortcutRegistry,
      token: token,
      scope: ShortcutScope.video,
    );
    if (action == null) return;
    final VideoPlayerController? controller = _controller;
    if (controller == null) {
      if (action == ShortcutAction.globalBack) _handleVideoEscapeAction();
      return;
    }
    videoActionCallbacks(
      _buildVideoShortcutActions(controller, input: VideoActionInput.keyboard),
    )[action]?.call();
  }

  /// 网页档的全屏：窗口全屏（与本地视频进全屏同一组 runner 调用），不推全屏路由——
  /// WebView2 子窗口挂在本页的平台视图上，不会跟进新路由。
  Future<void> _toggleWebWindowFullscreen() async {
    final bool enter = !_webWindowFullscreen;
    _rebuild(() => _webWindowFullscreen = enter);
    if (enter) {
      await _enterVideoNativeFullscreen();
    } else {
      await _exitVideoNativeFullscreen();
    }
    if (mounted) {
      _focusOwnership.reclaimAfterFrame(FocusReclaimCause.chromeToggled);
    }
  }

  /// 视频槽：站点 WebView 垫在最底层（稳定 key，有无 <video> 两种布局之间不重建）；有视频时
  /// 上面是原生 [Video]（透明底）+ 控制条，没视频时只在顶部留一条返回条、站点页面让在它下面。
  Widget _wrapWebVideoSurface(Widget video) {
    final WebVideoSession? session = _webSession;
    if (session == null) return video;
    final bool hasVideo = _webPlayerMode;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          top: hasVideo ? 0 : _kVideoWebPageBarHeight,
          child: WebVideoSurface(key: _webSurfaceKey, session: session),
        ),
        if (hasVideo)
          Positioned.fill(child: video)
        else
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: _kVideoWebPageBarHeight,
            child: _buildWebPageBar(),
          ),
      ],
    );
  }

  /// 网页档（登录 / 选人 / 详情 / 选集）上方的返回条：返回走与播放器返回钮同一条
  /// [_handleBackOrExit]；页面里有视频时右侧给「在播放器里看」。
  Widget _buildWebPageBar() {
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            FushiIconButtonControl(
              key: const ValueKey<String>('video-web-page-back'),
              tooltip: t.back,
              icon: const FushiIcon(FushiIcons.back),
              onPressed: () => unawaited(_handleBackOrExit()),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<String?>(
                valueListenable: _titleNotifier,
                builder: (BuildContext _, String? title, Widget? __) => Text(
                  title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            if (_webPageHasVideo)
              FilledButton.tonalIcon(
                key: const ValueKey<String>('video-web-player-open'),
                onPressed: () => _setWebPlayerMode(true),
                icon: const Icon(Icons.play_circle_outline),
                label: Text(t.web_video_player_open),
              ),
          ],
        ),
      ),
    );
  }

  /// 网页档制卡（[_onMineEntryImpl] 分流到这里）：**只入队**（schema v90 `web_mine_queue`），
  /// 冻结点击那一刻的 Anki 字段与锚点 cue 时间窗；之后切到可捕获的内置档逐句重放录音 +
  /// 截帧再落卡（[_runWebMineQueue]）。无锚点 cue（还没查过词 / 无字幕轨）时退回纯字段制卡。
  Future<MinePopupResult> _onWebMineEntry(Map<String, String> fields) async {
    final AudioCue? cue = _lastLookupCue ?? _controller?.currentCue;
    final VideoBookRow? row = _bookRow;
    if (cue == null || row == null) return _mineFieldsOnly(fields);
    final WebVideoPlaybackState? state = _webSession?.lastState;
    final String fieldSentence = (fields['sentence'] ?? '').trim();
    await _webMineQueue.enqueue(
      bookUid: _activeBookUid,
      videoKey: _webVideoKey,
      href: state != null && state.href.isNotEmpty ? state.href : row.videoPath,
      cueStartMs: cue.startMs,
      cueEndMs: cue.endMs,
      sentence: fieldSentence.isEmpty ? cue.text.trim() : fieldSentence,
      cueSentence: cue.text,
      fields: fields,
    );
    await _refreshStagedMineCount();
    if (mounted) {
      _showOsd(
        t.web_video_mine_queued(count: _stagedMineCount.value),
        icon: Icons.playlist_add_check,
      );
    }
    // 卡还没真落地：不把弹窗按钮画成 ✓（弹窗侧「未知结局不重画」契约，TODO-448）。
    return const MinePopupResult();
  }

  /// 跑制卡队列：同一本书原地换成内置网页播放器（可捕获的 1080p 档），画面一就绪就自动
  /// 逐句重放落卡（[WebVideoFushiPage.autoRunMineQueue]）。
  Future<void> _runWebMineQueue() async {
    await _controller?.flushPosition();
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => WebVideoFushiPage.neutralized(
          bookUid: _activeBookUid,
          repo: widget.repo,
          hosting: WebVideoHosting.builtin,
          autoRunMineQueue: true,
        ),
      ),
    );
  }

  /// dispose：退窗口全屏（runner 拥有的全屏态不随路由消失）、拆会话、归还底层合成。
  void _disposeWebSource() {
    if (_webWindowFullscreen && Platform.isWindows) {
      _webWindowFullscreen = false;
      unawaited(WindowCaptionChannel.setFullscreen(false));
    }
    _webSession?.dispose();
    if (_webUnderlayHeld) {
      _webUnderlayHeld = false;
      unawaited(releaseUnderlayComposition());
    }
  }
}
