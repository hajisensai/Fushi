part of '../video_fushi_page.dart';

/// 网页档没有站点视频时，顶部返回条的高度（站点页面让在它下面，返回钮不压在 WebView 上——
/// 收输入的 WebView2 子窗口会先于 Flutter 吃掉落在它矩形里的点击）。
const double _kVideoWebPageBarHeight = 52;

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
    // 站点入口没有库里的书，内置网页播放器页读不到它：只有底层合成档能开站点入口。
    if (widget.webSite != null) {
      _rebuild(() {
        _failed = true;
        _failReason = t.video_load_failed_generic;
      });
      return;
    }
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
      onPageLookup: _onWebPageLookup,
      hoverLookupModifier: () => ReaderFushiSource.instance.hoverLookupModifier,
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
      _webBoundEpisodeUrl = widget.webSite == null
          ? webVideoEpisodeUrl(row.videoPath)
          : null;
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
    session.nav.addListener(_syncWebAddress);
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
    // 站点入口还没有书：进度 / 观看统计等播起某一集落库后再接（[_bindWebEpisode]）。
    if (_webBoundEpisodeUrl == null) {
      controller.rebindWebBook(null);
    } else {
      _ensureWatchTracker(controller, row.title);
    }
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
    if (state.ad != _webAdShowing) _rebuild(() => _webAdShowing = state.ad);
    // 广告的位置 / 时长 / 16 倍速 / 静音不是正片的：不进播放器状态（也就不会写进度）。
    if (state.ad) return;
    _webPlatform?.applySnapshot(
      state,
      volume: state.volume,
      muted: state.muted,
      buffering: state.buffering,
    );
    final bool videoChanged = state.videoKey != _webVideoKey;
    if (videoChanged) {
      // 站内换了视频：新视频的播放头不能写进上一集的进度，先断开，播放器档再按地址重绑。
      _controller?.rebindWebBook(null);
      _webVideoKey = state.videoKey;
      _webActiveTrackKey = null;
      _webPendingTrackKey = null;
      _reselectWebTrack();
    }
    if (!listEquals(state.siteTracks, _webSiteTracks) ||
        state.siteTrackCurrent != _webSiteTrackCurrent) {
      _rebuild(() {
        _webSiteTracks = state.siteTracks;
        _webSiteTrackCurrent = state.siteTrackCurrent;
      });
    }
    _maybeRequestDefaultSiteTrack();
    // 站点自己的全屏钮（网页档里点的）= 「我要看了」：换成播放器档 + 窗口全屏。
    if (state.fullscreen && state.hasVideo && !_webPlayerModeFor(state)) {
      _webForcePlayerKey = state.videoKey;
      _webBrowseVideoKey = null;
      unawaited(session.exitPageFullscreen());
      if (!_webWindowFullscreen) unawaited(_toggleWebWindowFullscreen());
    }
    final bool playerMode = _webPlayerModeFor(state);
    session.syncInput(playerMode: playerMode, videoChanged: videoChanged);
    if (playerMode) unawaited(_bindWebEpisode(state));
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

  /// 播放器档里正在播的这一集 = 本页的书：同一集只把进度写回接上；换了集（站点入口里点了
  /// 某一集 / 站内下一集）就把这一集落成书（[ensureWebVideoEpisodeBook]，已有则复用）、
  /// 本页身份原子地换过去——进度、观看统计、收藏、制卡队列、字幕 cue 的 bookKey 都跟着走
  /// （与原盘选片 `_bindDiscPlaylist` 同一套换身份）。
  Future<void> _bindWebEpisode(WebVideoPlaybackState state) async {
    final VideoPlayerController? controller = _controller;
    final WebVideoSession? session = _webSession;
    final String? url = webVideoEpisodeUrl(state.href);
    if (controller == null || session == null || url == null) return;
    if (url == _webBoundEpisodeUrl) {
      controller.rebindWebBook(_activeBookUid);
      unawaited(_refreshWebEpisodeBook(state, url));
      return;
    }
    if (url == _webBindingEpisodeUrl) return;
    _webBindingEpisodeUrl = url;
    final String siteTitle =
        widget.webSite?.title ?? webVideoSiteDefaultTitle(url);
    VideoBookRow? row;
    try {
      row = await ensureWebVideoEpisodeBook(
        widget.repo,
        episodeUrl: url,
        title: state.videoTitle.isNotEmpty
            ? state.videoTitle
            : webVideoEpisodeTitle(
                pageTitle: state.title,
                episodeUrl: url,
                siteTitle: siteTitle,
              ),
      );
    } catch (e, st) {
      ErrorLogService.instance.log('VideoFushi.webEpisode', e, st);
    }
    if (_webBindingEpisodeUrl == url) _webBindingEpisodeUrl = null;
    final WebVideoPlaybackState? latest = session.lastState;
    if (!mounted ||
        row == null ||
        !identical(_controller, controller) ||
        !identical(_webSession, session) ||
        latest == null ||
        webVideoEpisodeUrl(latest.href) != url) {
      return;
    }
    final VideoBookRow bound = row;
    _rebuild(() {
      _webEpisodeBookUid = bound.bookUid;
      _webBoundEpisodeUrl = url;
      _bookRow = bound;
      _title = bound.title;
      _delayMs = bound.delayMs;
      _secondaryDelayMs = bound.secondaryDelayMs;
      _favoritedVideoSentences.clear();
      _webTracks.clear();
      _webActiveTrackKey = null;
    });
    session.bookUid = bound.bookUid;
    controller.setDelayMs(_delayMs);
    controller.setSecondaryDelayMs(_secondaryDelayMs);
    controller.setCues(const <AudioCue>[]);
    controller.rebindWebBook(bound.bookUid);
    // 已采到的轨带着旧 bookKey：让 glue 按新身份整轨重投。
    unawaited(session.replayCues());
    _ensureWatchTracker(controller, bound.title);
    unawaited(_refreshFavoritedCueCache());
    unawaited(_refreshStagedMineCount());
  }

  /// 已绑定的这一集还是占位书名 / 没封面，而页面已经给出真名 / 封面：补上（每集最多跑一次
  /// 成功的补全；站点 SPA 里真名往往晚于播放几百毫秒才出来，所以按快照重试）。
  Future<void> _refreshWebEpisodeBook(
    WebVideoPlaybackState state,
    String url,
  ) async {
    final VideoBookRow? row = _bookRow;
    if (row == null ||
        _webEpisodeMetaDoneUrl == url ||
        _webEpisodeMetaBusy ||
        isWebVideoSiteBookUid(row.bookUid)) {
      return;
    }
    final bool needsTitle = webVideoEpisodeTitleIsPlaceholder(
      row.title,
      row.videoPath,
    );
    final bool needsCover = row.coverPath == null || row.coverPath!.isEmpty;
    if (!needsTitle && !needsCover) {
      _webEpisodeMetaDoneUrl = url;
      return;
    }
    if (needsTitle && state.videoTitle.isEmpty && !needsCover) return;
    _webEpisodeMetaBusy = true;
    try {
      final VideoBookRow updated = await refreshWebVideoEpisodeBook(
        widget.repo,
        row,
        videoTitle: state.videoTitle,
        pageImage: state.imageUrl,
      );
      if (!mounted || _bookRow?.bookUid != updated.bookUid) return;
      if (!identical(updated, row)) {
        _rebuild(() {
          _bookRow = updated;
          _title = updated.title;
        });
      }
      final bool titleDone = !webVideoEpisodeTitleIsPlaceholder(
        updated.title,
        updated.videoPath,
      );
      final bool coverDone =
          updated.coverPath != null && updated.coverPath!.isNotEmpty;
      if (titleDone && coverDone) _webEpisodeMetaDoneUrl = url;
    } catch (e, st) {
      ErrorLogService.instance.log('VideoFushi.webEpisodeMeta', e, st);
      _webEpisodeMetaDoneUrl = url;
    } finally {
      _webEpisodeMetaBusy = false;
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
    final String? pending = _webPendingTrackKey;
    if (pending != null && (_webTracks[pending]?.cues.isNotEmpty ?? false)) {
      _webPendingTrackKey = null;
      _webActiveTrackKey = pending;
    }
    final String? next = _webSubtitlesOff
        ? null
        : chooseWebVideoTrackKey(
            tracks: _webTracks.values,
            videoKey: _webVideoKey,
            preferredLanguage: _webPreferredSubtitleLanguage,
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

  /// 默认字幕语言：这本书自己的语言，没有就走与自动下字幕同一条偏好链（字幕工作台默认语言
  /// > 默认内容语言）。stream 书的 language 多半是空的，只看它就会落到「第一条轨」= 随机语言。
  String? get _webPreferredSubtitleLanguage => resolveSubtitleDownloadLanguage(
    explicitSubtitlePreference: appModel.jimakuDefaultLanguage,
    videoContentLanguage: _bookRow?.language,
    globalDefaultContentLanguage: appModel.defaultContentLanguage,
  );

  /// 让站点播放器切到 [track]：它随即下载那条字幕文件，bridge 截下整轨后由
  /// [_reselectWebTrack] 选中（[_webPendingTrackKey]）。
  void _requestWebSiteTrack(WebVideoSiteTrack track) {
    final WebVideoSession? session = _webSession;
    if (session == null) return;
    _webSubtitlesOff = false;
    _webPendingTrackKey = '$_webVideoKey|${track.lang}';
    unawaited(
      session.evaluate(
        'window.__fushiWebVideo.selectNetflixTrack(${jsonEncode(track.id)})',
      ),
    );
    _rebuild(() {});
  }

  /// 站点字幕关着、这一集一条整轨都还没采到：按首选字幕语言替用户开一条（每集一次；用户
  /// 在面板里关掉字幕后不再自作主张）。没有首选语言的轨就开第一条。
  void _maybeRequestDefaultSiteTrack() {
    if (_webSubtitlesOff ||
        _webSiteTracks.isEmpty ||
        _webSiteTrackCurrent.isNotEmpty ||
        _webSiteTrackAutoVideoKey == _webVideoKey ||
        _currentWebTracks().any((WebVideoTrack t) => !t.isLive)) {
      return;
    }
    _webSiteTrackAutoVideoKey = _webVideoKey;
    final String pref = (_webPreferredSubtitleLanguage ?? '').toLowerCase();
    WebVideoSiteTrack pick = _webSiteTracks.first;
    if (pref.isNotEmpty) {
      for (final WebVideoSiteTrack track in _webSiteTracks) {
        final String lang = track.lang.toLowerCase();
        if (lang == pref || lang.startsWith('$pref-')) {
          pick = track;
          break;
        }
      }
    }
    _requestWebSiteTrack(pick);
  }

  /// 站点播放器里还没采到整轨的字幕轨（面板里列在已采到的轨后面，点选加载）。
  List<WebVideoSiteTrack> _unloadedWebSiteTracks() {
    final Set<String> loaded = <String>{
      for (final WebVideoTrack track in _currentWebTracks()) track.key,
    };
    return <WebVideoSiteTrack>[
      for (final WebVideoSiteTrack track in _webSiteTracks)
        if (!loaded.contains('$_webVideoKey|${track.lang}')) track,
    ];
  }

  /// 当前视频可选的站点字幕轨（有 cue 的才列）。
  List<WebVideoTrack> _currentWebTracks() => <WebVideoTrack>[
    for (final WebVideoTrack track in _webTracks.values)
      if (track.videoKey == _webVideoKey && track.cues.isNotEmpty) track,
  ];

  void _selectWebTrack(String? key) {
    _webSubtitlesOff = key == null;
    _webPendingTrackKey = null;
    _webActiveTrackKey = key;
    _reselectWebTrack();
    _rebuild(() {});
  }

  /// 设置面板「字幕」分类顶部的轨列表（网页档）：关闭 + 站点每条轨。导入文件 / 自动获取 /
  /// 转录 / 对轴这些行都要本地媒体，网页档不列。
  Widget _buildWebSubtitleTrackRows(BuildContext context) {
    final Color? selectedFg = videoPanelSelectedForeground(context);
    final List<WebVideoTrack> tracks = _currentWebTracks();
    final List<WebVideoSiteTrack> siteTracks = _unloadedWebSiteTracks();
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
        if (tracks.isEmpty && siteTracks.isEmpty)
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
        for (final WebVideoSiteTrack track in siteTracks)
          FushiListTileControl(
            key: ValueKey<String>('video-web-site-subtitle-${track.id}'),
            leading: const FushiIcon(Icons.closed_caption_outlined),
            title: Text(track.name.isEmpty ? track.lang : track.name),
            subtitle: Text(
              _webPendingTrackKey == '$_webVideoKey|${track.lang}'
                  ? t.web_video_track_loading
                  : t.web_video_track_site,
            ),
            onTap: () => _requestWebSiteTrack(track),
          ),
      ],
    );
  }

  /// 网页档里按住 Shift 悬停在站点文字上：顶层查词窗口在光标处弹出（它是独立的置顶窗口，
  /// 不受收输入的 WebView2 子窗口挡点击）。站点页面不是字幕：不暂停、不锚 cue。
  void _onWebPageLookup(WebVideoLookupRequest request) {
    if (!mounted || _webPlayerMode) return;
    final String term = subtitleLookupTerm(
      request.sentence,
      request.graphemeIndex,
    );
    if (term.isEmpty) return;
    unawaited(
      GlobalLookupController.instance.lookupText(
        term,
        sentence: request.sentence,
        autoRead: false,
      ),
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
    // 网页档里 Esc 归站点自己（关站内弹窗 / 菜单），不当成「退一级」。
    if (action == ShortcutAction.globalBack && !_webPlayerMode) return;
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
        if (hasVideo && _webAdShowing)
          Positioned.fill(
            child: ColoredBox(
              key: const ValueKey<String>('video-web-ad-cover'),
              color: Colors.black,
              child: Center(
                child: Text(
                  t.web_video_ad_skipping,
                  style: _videoControlTitleStyle(),
                ),
              ),
            ),
          ),
        if (hasVideo)
          Positioned.fill(child: video)
        else ...<Widget>[
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: _kVideoWebPageBarHeight,
            child: _buildWebPageBar(),
          ),
          // 网页档也要看得到短提示（登录导入等）：播放器档的 OSD 层挂在控制条里，这里补一层。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            top: _kVideoWebPageBarHeight,
            child: _buildOsdOverlay(),
          ),
        ],
      ],
    );
  }

  /// 网页档（登录 / 选人 / 详情 / 选集）上方的浏览器工具条：后退（一级一级往外退，与
  /// 返回键同一条 [_handleBackOrExit]）/ 前进 / 刷新（加载中是停止）/ 地址栏（网址或搜索词）
  /// / 页面里有视频时的「在播放器里看」/ 关闭本页。
  Widget _buildWebPageBar() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final WebVideoSession? session = _webSession;
    if (session == null) return const SizedBox.shrink();
    return ColoredBox(
      color: cs.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: ValueListenableBuilder<WebVideoNavState>(
          valueListenable: session.nav,
          builder: (BuildContext _, WebVideoNavState nav, Widget? __) => Row(
            children: <Widget>[
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-nav-back'),
                tooltip: t.back,
                icon: const FushiIcon(FushiIcons.back),
                onPressed: () => unawaited(_handleBackOrExit()),
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-nav-forward'),
                tooltip: t.web_video_nav_forward,
                icon: const Icon(Icons.arrow_forward),
                onPressed: nav.canGoForward
                    ? () => unawaited(session.goForward())
                    : null,
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-nav-reload'),
                tooltip: nav.loading ? t.web_video_nav_close : t.refresh,
                icon: Icon(nav.loading ? Icons.close : Icons.refresh),
                onPressed: () => unawaited(session.reloadOrStop()),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>('video-web-address'),
                  controller: _webAddressController,
                  focusNode: _webAddressFocus,
                  hintText: t.web_video_address_hint,
                  leading: FushiIcon(
                    nav.url.startsWith('https://')
                        ? Icons.lock_outline
                        : Icons.public,
                  ),
                  onChanged: (String _) {},
                  onSubmitted: _submitWebAddress,
                ),
              ),
              const SizedBox(width: 4),
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-login-import'),
                tooltip: t.web_video_login_import,
                icon: Icon(_webLoginImport == null ? Icons.login : Icons.sync),
                onPressed: _beginWebLoginImport,
              ),
              const SizedBox(width: 4),
              if (_webPageHasVideo) ...<Widget>[
                FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('video-web-player-open'),
                  onPressed: () => _setWebPlayerMode(true),
                  icon: const Icon(Icons.play_circle_outline),
                  label: Text(t.web_video_player_open),
                ),
                const SizedBox(width: 4),
              ],
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-nav-close'),
                tooltip: t.web_video_nav_close,
                icon: const Icon(Icons.close),
                onPressed: () {
                  _webClosing = true;
                  unawaited(_handleBackOrExit());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「从浏览器导入登录」：与漫画源登录同一条扩展通道（[BrowserCookieImportGate]）——登记
  /// 当前站点、在系统浏览器里打开它，Fushi 浏览器扩展在该站页面加载完 / 每分钟心跳时把它的
  /// cookie 送来，写进视频的 WebView2 环境（[importWebVideoBrowserCookies]）后刷新本页。
  /// 登记保持到本页关闭：用户可能还没在浏览器里登录，登完再加载一次就会再送。
  void _beginWebLoginImport() {
    final WebVideoSession? session = _webSession;
    if (session == null) return;
    final String current = session.nav.value.url;
    final Uri? page = Uri.tryParse(
      current.isNotEmpty ? current : session.pageUrl,
    );
    if (page == null || page.host.isEmpty) return;
    final String host = BrowserCookieImportGate.normalizeHost(page.host);
    if (_webLoginImport?.request.host != host) {
      _endWebLoginImport();
      final BrowserCookieImportRequestHandle handle =
          BrowserCookieImportGate.begin(host);
      // 句柄 end() 关闭 deliveries，订阅随之结束，不必另存。
      handle.deliveries.listen(
        (BrowserCookieDelivery delivery) =>
            unawaited(_applyWebLoginImport(host, delivery)),
      );
      _rebuild(() => _webLoginImport = handle);
    }
    _showOsd(
      t.web_video_login_import_waiting,
      icon: Icons.login,
      prominent: true,
      severity: ToastSeverity.info,
    );
    unawaited(
      launchUrl(
        Uri(scheme: 'https', host: page.host, path: '/'),
        mode: LaunchMode.externalApplication,
      ).catchError((Object _) => false),
    );
  }

  Future<void> _applyWebLoginImport(
    String host,
    BrowserCookieDelivery delivery,
  ) async {
    final List<BrowserSiteCookie> cookies = browserSiteCookiesForSite(
      delivery.cookies,
      host,
    );
    if (cookies.isEmpty) return;
    final String signature =
        (cookies
                .map(
                  (BrowserSiteCookie c) => '${c.domain}|${c.name}=${c.value}',
                )
                .toList()
              ..sort())
            .join(';');
    if (signature == _webLoginImportSignature) return;
    _webLoginImportSignature = signature;
    final int written = await importWebVideoBrowserCookies(cookies);
    final WebVideoSession? session = _webSession;
    if (!mounted || session == null || written == 0) return;
    _showOsd(
      t.web_video_login_import_received(count: written),
      icon: Icons.login,
      severity: ToastSeverity.success,
    );
    await session.reload();
  }

  void _endWebLoginImport() {
    _webLoginImport?.end();
    _webLoginImport = null;
    _webLoginImportSignature = null;
  }

  /// 地址栏没在编辑时跟着当前页面地址（[WebVideoSession.nav] 的监听者）。
  void _syncWebAddress() {
    final WebVideoSession? session = _webSession;
    if (session == null || _webAddressFocus.hasFocus) return;
    final String url = session.nav.value.url;
    if (_webAddressController.text != url) _webAddressController.text = url;
  }

  void _submitWebAddress(String input) {
    final String? target = webVideoAddressBarTarget(input);
    final WebVideoSession? session = _webSession;
    if (target == null || session == null) return;
    _webAddressFocus.unfocus();
    unawaited(session.loadUrl(target));
  }

  /// 返回键在网页档里的一级：播放器档先退回网页；网页有站内历史就后退一页。都没有（或
  /// 点了工具条「关闭」）返回 false，调用方关掉本页。同步判定：能否后退读工具条缓存的
  /// [WebVideoNavState.canGoBack]（退出路径不 await，BUG-2119）。
  bool _webBackStep() {
    final WebVideoSession? session = _webSession;
    if (session == null || _webClosing) return false;
    if (_webPlayerMode) {
      _setWebPlayerMode(false);
      return true;
    }
    if (!session.nav.value.canGoBack) return false;
    unawaited(session.goBack());
    return true;
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
    final String href = state != null && state.href.isNotEmpty
        ? state.href
        : row.videoPath;
    final String sentence = fieldSentence.isEmpty
        ? cue.text.trim()
        : fieldSentence;
    // YouTube 与浏览器扩展同一条路（[FushiRemoteMiningService.mineImmersion] 的 YouTube 分支）：
    // 按视频 id + 字幕时间窗从真实视频流裁画面与音频，点下就在后台制卡——不进队列、不回放，
    // 也就没有「回放时没全屏 / 外放声音 / 字幕换了语言」这些问题。
    final String? youtubeId = youtubeVideoIdOrNull(href);
    if (youtubeId != null) {
      _trackBackgroundMine(
        _mineWebYoutubeCue(
          ImmersionMinePayload(
            fields: fields,
            sentence: sentence,
            cueSentence: cue.text,
            documentTitle: row.title,
            youtubeVideoId: youtubeId,
            clipStartMs: cue.startMs,
            clipEndMs: cue.endMs,
          ),
        ),
      );
      _showOsd(t.web_video_mine_background, icon: Icons.playlist_add_check);
      return const MinePopupResult.queued();
    }
    await _webMineQueue.enqueue(
      bookUid: _activeBookUid,
      videoKey: _webVideoKey,
      href: href,
      cueStartMs: cue.startMs,
      cueEndMs: cue.endMs,
      sentence: sentence,
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
    // 卡还没真落地：弹窗画「已加入」✓、不回查 Anki（TODO-448）。空回执会被弹窗当成失败
    // （「导出卡片失败」），用户再点一次就重复入队。
    return const MinePopupResult.queued();
  }

  /// YouTube 后台制卡的结局只剩 OSD 能告诉用户（弹窗早已画了「已加入」）；失败抛出，由
  /// [_trackBackgroundMine] 报错并记日志。
  Future<void> _mineWebYoutubeCue(ImmersionMinePayload payload) async {
    final RemoteMineResult res = await appModel
        .createRemoteMiningService()
        .mineImmersion(payload);
    switch (res.result) {
      case 'success':
        _showOsd(
          t.card_exported(deck: res.deckName ?? ''),
          severity: ToastSeverity.success,
        );
      case 'duplicate':
        _showOsd(t.card_duplicate, severity: ToastSeverity.warning);
      default:
        throw StateError(res.message ?? res.detail ?? res.result);
    }
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
    _endWebLoginImport();
    _webSession?.dispose();
    _webAddressController.dispose();
    _webAddressFocus.dispose();
    if (_webUnderlayHeld) {
      _webUnderlayHeld = false;
      unawaited(releaseUnderlayComposition());
    }
  }
}
