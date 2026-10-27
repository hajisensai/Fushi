part of '../video_fushi_page.dart';

/// 网页档没有站点视频时，顶部返回条的高度（站点页面让在它下面，返回钮不压在 WebView 上——
/// 收输入的 WebView2 子窗口会先于 Flutter 吃掉落在它矩形里的点击）。
const double _kVideoWebPageBarHeight = 52;

/// 网页档（站点视频，[VideoPlayerController.isWebBackend]）能服务的控制条按钮：逐帧 /
/// 截图 / 识别画面文字 / 片段导出 / 弹幕都要 libmpv 或本地媒体文件，一律不画；音轨只在站点上报了音轨时画
/// （[hasSiteAudioTracks]，目前只有 Netflix）；章节按钮交给通用门控（站点给了片头片尾标记才
/// 有章节）。纯函数，控制条门控 `_shouldRenderControlItem` 与测试同源调用。
@visibleForTesting
bool videoWebBackendSupportsControlItem(
  VideoControlItem item, {
  bool hasSiteAudioTracks = false,
}) {
  switch (item) {
    case VideoControlItem.frameBackward:
    case VideoControlItem.frameForward:
    case VideoControlItem.screenshot:
    case VideoControlItem.ocrFrame:
    case VideoControlItem.clipExport:
    case VideoControlItem.danmaku:
      return false;
    case VideoControlItem.audioTrack:
      return hasSiteAudioTracks;
    default:
      return true;
  }
}

/// 待采整轨的确定失败判据（纯函数，见 `_webPendingLiveCueCount`）：站点当前轨已是所请求的那条，
/// 且 live 轨（DOM 采样）在请求之后长出了新 cue。
@visibleForTesting
bool webVideoPendingTrackCaptureFailed({
  required String requestedSiteTrackId,
  required String siteTrackCurrent,
  required int liveCueCountAtRequest,
  required int liveCueCountNow,
}) =>
    requestedSiteTrackId.isNotEmpty &&
    requestedSiteTrackId == siteTrackCurrent &&
    liveCueCountNow > liveCueCountAtRequest;

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
      // 站点画面从透明像素处透出来：本页的路由层页底（底色 + 角落形状）必须让开，
      // 否则网页被整个盖住、看着像「加载不出来」。
      // （initState 里同步调起本方法，路由只能在 await 之后取。）
      final Route<Object?>? route = context.mounted
          ? ModalRoute.of(context)
          : null;
      if (route != null) {
        _webTransparentRoute = route;
        setFushiPageRouteTransparent(route, true);
      }
      await _initWebSource(row);
      return;
    }
    if (!context.mounted) return;
    // 站点入口没有库里的书，内置网页播放器页读不到它：只有底层合成档能在本页播站点
    // 入口。拿不到底层合成（引擎没带合成器补丁的构建、或用户选了非窗口档）时改用
    // app 内浏览器打开这个站点，而不是一张「无法加载该视频」的死页（2026-10-20
    // 用户截图「视频站点这个打不开」：本地调试引擎不支持底层合成）。
    final WebVideoSite? site = widget.webSite;
    if (site != null) {
      unawaited(
        Navigator.of(
          context,
        ).pushReplacement(fushiWebBrowserRoute(context, site.url)),
      );
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
    _immersiveControlLayoutJson.value =
        appModel.videoImmersiveControlLayoutJson;
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
      onSeekDone: (WebVideoSeekDone done) => _webPlatform?.applySeekDone(done),
      onCommandFailed: (String command, String _) =>
          _webPlatform?.applyCommandFailed(command),
      onTrackFailed: _onWebTrackFailed,
      onNetflixMetadata: _onWebNetflixMetadata,
    )..qualityTargetHeight = appModel.youtubeQualityTargetHeight;
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
      _webLoginImport ??= _createWebLoginImport();
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
    // 章节来自站点（Netflix 片头片尾标记，[setWebChapters]）：按钮随有无章节出现 / 消失。
    _attachControllerChapterListener(controller);
    _adoptHandedOverFullscreenForWeb();
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    _seedWarmPopup();
    unawaited(_refreshFavoritedCueCache());
    unawaited(_refreshStagedMineCount());
    if (Platform.isWindows) _startWebMineIdle();
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
      _webFailedTrackKeys.clear();
      // 上一集选的图片字幕轨不跟到新视频（新文档的 glue 也已按宿主开关藏起站点字幕）。
      _setWebSiteImageTrackShown(false);
      _reselectWebTrack();
    }
    if (!listEquals(state.siteTracks, _webSiteTracks) ||
        state.siteTrackCurrent != _webSiteTrackCurrent) {
      _rebuild(() {
        _webSiteTracks = state.siteTracks;
        _webSiteTrackCurrent = state.siteTrackCurrent;
      });
    }
    _checkWebPendingTrackCapture();
    _maybeRequestDefaultSiteTrack();
    _syncWebAudioTracks(state);
    _syncWebNetflixMetadata(state);
    _notifyWebBlocker(state);
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
      final String metaTitle = _webEpisodeMetaTitle(state.href);
      row = await ensureWebVideoEpisodeBook(
        widget.repo,
        episodeUrl: url,
        title: metaTitle.isNotEmpty
            ? metaTitle
            : state.videoTitle.isNotEmpty
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
    // 站点 metadata（Netflix：「作品 · S1E2 集名」+ 剧照）优于页面 DOM / og（播放器档里 DOM
    // 标题常被藏、播放页没有 og:image）。
    final String metaTitle = _webEpisodeMetaTitle(state.href);
    final String metaCover = _webEpisodeMetaCover(state.href);
    final String videoTitle = metaTitle.isNotEmpty
        ? metaTitle
        : state.videoTitle;
    final String pageImage = metaCover.isNotEmpty ? metaCover : state.imageUrl;
    if (needsTitle && videoTitle.isEmpty && !needsCover) return;
    _webEpisodeMetaBusy = true;
    try {
      final VideoBookRow updated = await refreshWebVideoEpisodeBook(
        widget.repo,
        row,
        videoTitle: videoTitle,
        pageImage: pageImage,
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

  String _webEpisodeMetaTitle(String href) {
    final String? watchId = _webNetflixWatchId(href);
    final NetflixTitleMetadata? meta = watchId == null
        ? null
        : _webNetflixMeta[watchId];
    return meta == null ? '' : meta.displayTitleFor(watchId!);
  }

  String _webEpisodeMetaCover(String href) {
    final String? watchId = _webNetflixWatchId(href);
    final NetflixTitleMetadata? meta = watchId == null
        ? null
        : _webNetflixMeta[watchId];
    return meta == null ? '' : meta.coverFor(watchId!);
  }

  /// 这份快照该不该是播放器档：没视频一定不是；站点弹层打断播放时不是；用户对**这一集**点过
  /// 「回到网页」/「在播放器里看」以用户为准（换一集即失效——在网页里点了另一集，就自动进播放器）；否则看地址是不是
  /// 播放页（[webVideoIsWatchPage]：Netflix 浏览页的预告片不算）。
  bool _webPlayerModeFor(WebVideoPlaybackState state) {
    if (!state.hasVideo) return false;
    // 站点弹层打断了播放（「还在看吗？」/ 播放错误）：播放器档藏着站点页面、WebView 也不收输入，
    // 用户既看不到也点不到——让位给网页档。弹层没了（快照 blk 回空）自动回到播放器档。
    if (state.isBlocked) return false;
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
          icon: FushiIcons.webAsset,
          label: t.web_video_page_show,
          onSelected: run,
        ),
        child: FushiTooltip(
          message: t.web_video_page_show,
          child: KeyedSubtree(
            key: const ValueKey<String>('video-web-page-show'),
            child: _chromeIconButton(
              icon: FushiIcons.webAsset,
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
    if (track.cues.isNotEmpty) _webFailedTrackKeys.remove(track.key);
    _reselectWebTrack();
    // live 轨长了：待采整轨的失败判据可能成立了。
    if (track.isLive) _checkWebPendingTrackCapture();
  }

  /// bridge 回报某条整轨抓取失败：在途的那条落成失败（面板显示失败、可点选重试）。
  void _onWebTrackFailed(String key) {
    if (!mounted) return;
    _rebuild(() {
      _webFailedTrackKeys.add(key);
      if (_webPendingTrackKey == key) _webPendingTrackKey = null;
    });
  }

  int _webLiveCueCount() =>
      _webTracks['$_webVideoKey|$kWebVideoLiveTrackLang']?.cues.length ?? 0;

  /// 待采整轨的确定失败判据（[webVideoPendingTrackCaptureFailed]）。
  void _checkWebPendingTrackCapture() {
    final String? pending = _webPendingTrackKey;
    if (pending == null) return;
    final int tilde = pending.indexOf('~');
    final String requestedId = tilde >= 0 ? pending.substring(tilde + 1) : '';
    if (!webVideoPendingTrackCaptureFailed(
      requestedSiteTrackId: requestedId,
      siteTrackCurrent: _webSiteTrackCurrent,
      liveCueCountAtRequest: _webPendingLiveCueCount,
      liveCueCountNow: _webLiveCueCount(),
    )) {
      return;
    }
    ErrorLogService.instance.log(
      'VideoFushi.web',
      'site subtitle shown but full track not captured: $pending',
    );
    _onWebTrackFailed(pending);
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
  void _requestWebSiteTrack(WebVideoSiteTrack track, {bool byUser = false}) {
    final WebVideoSession? session = _webSession;
    if (session == null) return;
    if (byUser) _webSubtitleUserChosen = true;
    _webSubtitlesOff = false;
    unawaited(
      session.evaluate(
        'window.__fushiWebVideo.selectNetflixTrack(${jsonEncode(track.id)})',
      ),
    );
    if (track.imageBased) {
      // 图片字幕截不到文字：不进 Fushi 叠层，让站点自己画（不可查词）。
      _webPendingTrackKey = null;
      _webActiveTrackKey = null;
      _setWebSiteImageTrackShown(true);
      _reselectWebTrack();
      _rebuild(() {});
      return;
    }
    _setWebSiteImageTrackShown(false);
    final String key = track.storeKey(_webVideoKey);
    _webFailedTrackKeys.remove(key);
    _webPendingLiveCueCount = _webLiveCueCount();
    if (_webTracks[key]?.cues.isNotEmpty ?? false) {
      // 早已采到（Netflix 选回之前看过的轨不会重新下载）：直接选中。
      _webPendingTrackKey = null;
      _webActiveTrackKey = key;
    } else {
      _webPendingTrackKey = key;
    }
    _reselectWebTrack();
    _rebuild(() {});
  }

  void _setWebSiteImageTrackShown(bool shown) {
    if (_webSiteImageTrackShown == shown) return;
    _webSiteImageTrackShown = shown;
    unawaited(_webSession?.setNativeSubtitlesHidden(!shown));
  }

  /// 每集首次（P1-5）：按首选字幕语言替用户选一条站点字幕轨——即使站点已默认开着别的语言
  /// （Netflix 按账号习惯默认开英文）。用户在面板里亲手选过 / 关掉字幕后不再干预。没有首选
  /// 语言的轨时：站点字幕关着、也没采到任何整轨，就开第一条文字轨（否则无字可查）。
  void _maybeRequestDefaultSiteTrack() {
    if (_webSubtitlesOff ||
        _webSubtitleUserChosen ||
        _webSiteTracks.isEmpty ||
        _webSiteTrackAutoVideoKey == _webVideoKey) {
      return;
    }
    _webSiteTrackAutoVideoKey = _webVideoKey;
    final WebVideoSiteTrack? preferred = pickWebVideoSiteTrackForLanguage(
      _webSiteTracks,
      _webPreferredSubtitleLanguage,
    );
    if (preferred != null) {
      if (preferred.id != _webSiteTrackCurrent ||
          _webActiveTrackKey != preferred.storeKey(_webVideoKey)) {
        _requestWebSiteTrack(preferred);
      }
      return;
    }
    if (_webSiteTrackCurrent.isNotEmpty ||
        _currentWebTracks().any((WebVideoTrack t) => !t.isLive)) {
      return;
    }
    final WebVideoSiteTrack? firstText = _webSiteTracks
        .where((WebVideoSiteTrack t) => !t.imageBased)
        .firstOrNull;
    if (firstText != null) _requestWebSiteTrack(firstText);
  }

  /// 站点音轨（P1-4）：音轨清单由 [WebVideoPlatformPlayer] 变成 media_kit 的音轨，原生的音轨菜单 /
  /// 侧栏「音频」照常工作；这里同步选中态，并在每集首次按内容语言偏好替用户选一次（P1-5）。
  void _syncWebAudioTracks(WebVideoPlaybackState state) {
    final String current = state.siteAudioTrackCurrent;
    if (current.isNotEmpty && current != _currentAudioTrackId) {
      _rebuild(() => _currentAudioTrackId = current);
    }
    if (_webAudioUserChosen ||
        state.siteAudioTracks.isEmpty ||
        _webAudioAutoVideoKey == state.videoKey) {
      return;
    }
    _webAudioAutoVideoKey = state.videoKey;
    final WebVideoSiteTrack? preferred = pickWebVideoSiteTrackForLanguage(
      state.siteAudioTracks,
      _bookRow?.language ?? appModel.defaultContentLanguage,
    );
    final VideoPlayerController? controller = _controller;
    if (preferred == null || preferred.id == current || controller == null) {
      return;
    }
    final AudioTrack? track = controller.audioTracks
        .where((AudioTrack t) => t.id == preferred.id)
        .firstOrNull;
    if (track != null) unawaited(controller.selectAudioTrack(track));
  }

  /// 站点弹层打断播放（[WebVideoPlaybackState.blocker]）：[_webPlayerModeFor] 已让位给网页档，这里
  /// 告诉用户为什么画面没了（同一次打断只说一次）。
  void _notifyWebBlocker(WebVideoPlaybackState state) {
    if (!state.isBlocked || !state.hasVideo) {
      if (!state.isBlocked) _webBlockerNotified = '';
      return;
    }
    final String token = '${state.videoKey}#${state.blocker}';
    if (_webBlockerNotified == token) return;
    _webBlockerNotified = token;
    ErrorLogService.instance.log(
      'VideoFushi.web',
      'playback blocked by site: ${state.blocker} (${state.href})',
    );
    final String code = state.blockerErrorCode;
    _showOsd(
      state.blocker == 'interrupt'
          ? t.web_video_blocked_interrupt
          : code.isEmpty
          ? t.web_video_blocked_error_generic
          : t.web_video_blocked_error(code: code),
      icon: FushiIcons.webAsset,
      prominent: true,
      severity: state.blocker == 'interrupt'
          ? ToastSeverity.info
          : ToastSeverity.warning,
    );
  }

  // ── Netflix 剧集 / 章节（P2-2）───────────────────────────────────────────

  /// Netflix 播放页的播放 id（`/watch/<id>`）；不是 Netflix 播放页为 null。
  String? _webNetflixWatchId(String href) {
    final String? url = webVideoEpisodeUrl(href);
    if (url == null || !url.startsWith('https://www.netflix.com/watch/')) {
      return null;
    }
    return url.substring('https://www.netflix.com/watch/'.length);
  }

  /// 正在看的这一集有 metadata 就用（剧集面板 / 章节），没有就向站点要一次（每个 id 一次；失败
  /// 只记日志，面板没有剧集）。
  void _syncWebNetflixMetadata(WebVideoPlaybackState state) {
    final String? watchId = _webNetflixWatchId(state.href);
    if (watchId == null) return;
    final NetflixTitleMetadata? meta = _webNetflixMeta[watchId];
    if (meta != null) {
      _applyWebNetflixMetadata(meta, watchId, state.durationMs);
      return;
    }
    if (!state.hasVideo || !_webNetflixMetaRequested.add(watchId)) return;
    _webNetflixMetaInFlight.add(watchId);
    unawaited(
      _webSession?.evaluate(
        'window.__fushiWebVideo.fetchNetflixMetadata(${jsonEncode(watchId)})',
      ),
    );
  }

  void _onWebNetflixMetadata(String movieId, String? text, String error) {
    // 回执来自页面（不可信）：只认本页确实发出过、还没回的那个 id，且原文里真有这一集
    // ——否则页面可以随手投一份伪造的剧集 / 剧照 / 片头标记给任意 id。
    if (!_webNetflixMetaInFlight.remove(movieId)) return;
    if (!mounted || text == null) return;
    final NetflixTitleMetadata? meta = parseNetflixMetadata(text);
    if (meta != null && !meta.describes(movieId)) {
      ErrorLogService.instance.log(
        'VideoFushi.web',
        'netflix metadata $movieId: response does not contain that episode',
      );
      return;
    }
    if (meta == null) {
      ErrorLogService.instance.log(
        'VideoFushi.web',
        'netflix metadata $movieId: unrecognised shape',
      );
      return;
    }
    _webNetflixMeta[movieId] = meta;
    for (final NetflixEpisode e in meta.episodes) {
      _webNetflixMeta[e.id] = meta;
      _webNetflixMetaRequested.add(e.id);
    }
    final WebVideoPlaybackState? state = _webSession?.lastState;
    final String? watchId = state == null
        ? null
        : _webNetflixWatchId(state.href);
    if (watchId != null && _webNetflixMeta[watchId] == meta) {
      _applyWebNetflixMetadata(meta, watchId, state!.durationMs);
    }
  }

  /// metadata → 剧集面板（[_episodes]，换集走 [_switchWebEpisode]）+ 章节（片头片尾标记）。
  void _applyWebNetflixMetadata(
    NetflixTitleMetadata meta,
    String watchId,
    int? durationMs,
  ) {
    final List<String> urls = <String>[
      for (final NetflixEpisode e in meta.episodes) e.watchUrl,
    ];
    final int index = meta.indexOfEpisode(watchId);
    if (!listEquals(urls, _webEpisodeUrls) || index != _currentEpisode) {
      _rebuild(() {
        _webEpisodeUrls = urls;
        _episodes = <_PlaylistEpisodeRef>[
          for (final NetflixEpisode e in meta.episodes)
            _PlaylistEpisodeRef(
              title: meta.displayTitleFor(e.id),
              displayTitle: e.title.isEmpty ? null : e.title,
              // 剧集面板按标题解析季 / 集号（collectionGroupKeyForFilename）：给它标准形状。
              path:
                  'S${e.seasonSeq.toString().padLeft(2, '0')}'
                  'E${e.seq.toString().padLeft(2, '0')}',
              coverUrl: e.stillUrl.isEmpty ? null : e.stillUrl,
              coverCacheKey: e.stillUrl.isEmpty ? null : 'netflix:${e.id}',
            ),
        ];
        _currentEpisode = index < 0 ? 0 : index;
      });
    }
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.isWebBackend) return;
    controller.setWebChapters(
      netflixChaptersFromMarkers(
        meta.markersFor(watchId),
        NetflixChapterLabels(
          recap: t.web_video_chapter_recap,
          intro: t.web_video_chapter_intro,
          main: t.web_video_chapter_main,
          credits: t.web_video_chapter_credits,
        ),
        durationMs: durationMs,
      ),
    );
  }

  /// 剧集面板 / 上下一集 / 自动连播选了第 [index] 集：同一个 WebView 导航过去（站点播放页），
  /// 之后的落书 / 进度 / 字幕由 [_onWebState] 按新地址接上。
  void _switchWebEpisode(int index) {
    final WebVideoSession? session = _webSession;
    if (session == null || index < 0 || index >= _webEpisodeUrls.length) {
      return;
    }
    _webBrowseVideoKey = null;
    unawaited(session.loadUrl(_webEpisodeUrls[index]));
  }

  /// 站点播放器里还没采到整轨的字幕轨（面板里列在已采到的轨后面，点选加载）。
  List<WebVideoSiteTrack> _unloadedWebSiteTracks() {
    final Set<String> loaded = <String>{
      for (final WebVideoTrack track in _currentWebTracks()) track.key,
    };
    return <WebVideoSiteTrack>[
      for (final WebVideoSiteTrack track in _webSiteTracks)
        if (!loaded.contains(track.storeKey(_webVideoKey))) track,
    ];
  }

  /// 已采到的整轨在面板里的名字：站点显示名（「English [CC]」）优先，live 轨用固定文案。
  String _webTrackLabel(WebVideoTrack track) {
    if (track.isLive) return t.web_video_track_live;
    if (track.siteTrackId.isNotEmpty) {
      for (final WebVideoSiteTrack site in _webSiteTracks) {
        if (site.id == track.siteTrackId && site.name.isNotEmpty) {
          return site.name;
        }
      }
    }
    return track.lang;
  }

  String _webSiteTrackStatus(WebVideoSiteTrack track) {
    if (track.imageBased) return t.web_video_track_image;
    final String key = track.storeKey(_webVideoKey);
    if (_webFailedTrackKeys.contains(key)) return t.web_video_track_failed;
    if (_webPendingTrackKey == key) return t.web_video_track_loading;
    return t.web_video_track_site;
  }

  /// 当前视频可选的站点字幕轨（有 cue 的才列）。
  List<WebVideoTrack> _currentWebTracks() => <WebVideoTrack>[
    for (final WebVideoTrack track in _webTracks.values)
      if (track.videoKey == _webVideoKey && track.cues.isNotEmpty) track,
  ];

  void _selectWebTrack(String? key) {
    _webSubtitleUserChosen = true;
    _webSubtitlesOff = key == null;
    _webPendingTrackKey = null;
    _setWebSiteImageTrackShown(false);
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
          leading: const FushiIcon(FushiIcons.subtitlesOff),
          title: Text(t.video_subtitle_off),
          selected: _webActiveTrackKey == null,
          selectedColor: selectedFg,
          onTap: () => _selectWebTrack(null),
        ),
        if (tracks.isEmpty && siteTracks.isEmpty)
          FushiListTileControl(
            dense: true,
            leading: const FushiIcon(FushiIcons.subtitles),
            title: Text(t.web_video_no_tracks),
            enabled: false,
          ),
        for (final WebVideoTrack track in tracks)
          FushiListTileControl(
            key: ValueKey<String>('video-web-subtitle-${track.key}'),
            leading: const FushiIcon(FushiIcons.subtitles),
            title: Text(_webTrackLabel(track)),
            selected: track.key == _webActiveTrackKey,
            selectedColor: selectedFg,
            onTap: () => _selectWebTrack(track.key),
          ),
        for (final WebVideoSiteTrack track in siteTracks)
          FushiListTileControl(
            key: ValueKey<String>('video-web-site-subtitle-${track.id}'),
            leading: const FushiIcon(FushiIcons.subtitles),
            title: Text(track.name.isEmpty ? track.lang : track.name),
            subtitle: Text(_webSiteTrackStatus(track)),
            selected: track.imageBased && track.id == _webSiteTrackCurrent,
            selectedColor: selectedFg,
            onTap: () => _requestWebSiteTrack(track, byUser: true),
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
  ///
  /// 进 / 退是异步的 runner 调用：切换在途时再来的请求（双击 + 快捷键、站点全屏钮连发）直接
  /// 丢弃，否则两次翻转交错会让 [_webWindowFullscreen] 与窗口真实状态反相（标志说「窗口」、窗口
  /// 却还全屏，之后每一次切换都反着来）。
  Future<void> _toggleWebWindowFullscreen() async {
    if (_webWindowFullscreenTransitioning) return;
    _webWindowFullscreenTransitioning = true;
    final bool enter = !_webWindowFullscreen;
    _rebuild(() => _webWindowFullscreen = enter);
    try {
      if (enter) {
        await _enterVideoNativeFullscreen();
      } else {
        await _exitVideoNativeFullscreen();
      }
    } finally {
      _webWindowFullscreenTransitioning = false;
    }
    if (mounted) {
      _focusOwnership.reclaimAfterFrame(FocusReclaimCause.chromeToggled);
    }
  }

  /// 从全屏页换集而来的网页档新页（[VideoFushiPage.initialFullscreen]）：本地分支等就绪后压
  /// media_kit 全屏路由，但站点画面是 WebView2 子窗口、跟不进新路由（会被路由盖成黑屏）。网页档
  /// 的全屏就是窗口全屏——把认领来的原生全屏原样收作 [_webWindowFullscreen]，不再压路由，按钮、
  /// Esc 与退页都按网页档的全屏收口。
  void _adoptHandedOverFullscreenForWeb() {
    _didInitialFullscreen = true;
    if (!_ownsHandedOverNativeFullscreen) return;
    _ownsHandedOverNativeFullscreen = false;
    _rebuild(() => _webWindowFullscreen = true);
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
          // 「从浏览器导入登录」的等待状态条（可取消），贴在网页工具条下面。
          if (_webLoginImport case final WebVideoLoginImport import)
            Positioned(
              left: 0,
              right: 0,
              top: _kVideoWebPageBarHeight,
              child: WebVideoLoginImportStatusBar(controller: import),
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
                icon: const FushiIcon(FushiIcons.forward),
                onPressed: nav.canGoForward
                    ? () => unawaited(session.goForward())
                    : null,
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-nav-reload'),
                tooltip: nav.loading ? t.web_video_nav_close : t.refresh,
                icon: FushiIcon(
                  nav.loading ? FushiIcons.close : FushiIcons.refresh,
                ),
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
                        ? FushiIcons.lock
                        : FushiIcons.globe,
                  ),
                  onChanged: (String _) {},
                  onSubmitted: _submitWebAddress,
                ),
              ),
              const SizedBox(width: 4),
              if (_webLoginImport
                  case final WebVideoLoginImport import) ...<Widget>[
                WebVideoLoginImportButton(controller: import),
                const SizedBox(width: 4),
              ],
              if (_webPageHasVideo) ...<Widget>[
                FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('video-web-player-open'),
                  onPressed: () => _setWebPlayerMode(true),
                  icon: const FushiIcon(FushiIcons.playCircle),
                  label: Text(t.web_video_player_open),
                ),
                const SizedBox(width: 4),
              ],
              FushiIconButtonControl(
                key: const ValueKey<String>('video-web-nav-close'),
                tooltip: t.web_video_nav_close,
                icon: const FushiIcon(FushiIcons.close),
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

  /// 「从浏览器导入登录」：与漫画源登录、app 内浏览器同一份 [BrowserLoginImport]——登记
  /// 当前站点、在系统浏览器里打开它，Fushi 浏览器扩展把该站 cookie 送来，写进视频的
  /// WebView2 环境（[importWebVideoBrowserCookies]）后刷新本页，登记随即结束（之后扩展
  /// 再送一律被拒，不会每次打开该站都灌一批、刷一次页）。等待时网页工具条下有可取消的
  /// 状态条。按钮 / 状态条 / 站点选择都在 [WebVideoLoginImport]，这里只接线。
  WebVideoLoginImport _createWebLoginImport() => WebVideoLoginImport(
    urls: () {
      final WebVideoSession? session = _webSession;
      if (session == null) return null;
      return (currentUrl: session.nav.value.url, pageUrl: session.pageUrl);
    },
    write: importWebVideoBrowserCookies,
    onImported: _onWebLoginImported,
    onFailed: () => _showOsd(
      t.login_import_write_failed,
      icon: FushiIcons.login,
      severity: ToastSeverity.error,
    ),
  );

  void _onWebLoginImported(int written) {
    final WebVideoSession? session = _webSession;
    if (!mounted || session == null) return;
    _showOsd(
      t.web_video_login_import_received(count: written),
      icon: FushiIcons.login,
      severity: ToastSeverity.success,
    );
    unawaited(session.reload());
  }

  void _endWebLoginImport() {
    _webLoginImport?.dispose();
    _webLoginImport = null;
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
      _showOsd(t.web_video_mine_background, icon: FushiIcons.checklist);
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
        icon: FushiIcons.checklist,
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
  /// 逐句重放落卡（[WebVideoFushiPage.autoRunMineQueue]）。[idle] = 空闲自动制卡的交接：
  /// 那边静音跑、有输入即让位，跑完换回本页（[WebVideoFushiPage.returnHostingAfterMining]）。
  Future<void> _runWebMineQueue({bool idle = false}) async {
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
          returnHostingAfterMining: idle ? WebVideoHosting.windowed : null,
        ),
      ),
    );
  }

  /// 空闲判定：用户在播放器档里暂停了、队列非空、整机 2 分钟没输入 → 交接到内置档。
  void _startWebMineIdle() {
    _webMineIdle?.dispose();
    final WebMineIdleScheduler scheduler = WebMineIdleScheduler(
      canStart: () =>
          mounted &&
          _webMode &&
          _webPlayerMode &&
          !WebMineIdleScheduler.silentCaptureUnavailable &&
          _stagedMineCount.value > 0 &&
          !(_webSession?.lastState?.isPlaying ?? true),
      onIdle: () => unawaited(_runWebMineQueue(idle: true)),
      // 交接后本页即被替换；让位由内置档那一页负责。
      onUserActive: () {},
    );
    _webMineIdle = scheduler;
    scheduler.start();
  }

  /// dispose：退窗口全屏（runner 拥有的全屏态不随路由消失）、拆会话、归还底层合成。
  void _disposeWebSource() {
    _webMineIdle?.dispose();
    _webMineIdle = null;
    _detachControllerChapterListener();
    if (_webWindowFullscreen && Platform.isWindows) {
      _webWindowFullscreen = false;
      unawaited(WindowCaptionChannel.setFullscreen(false));
    }
    _endWebLoginImport();
    _webSession?.dispose();
    _webAddressController.dispose();
    _webAddressFocus.dispose();
    final Route<Object?>? transparentRoute = _webTransparentRoute;
    if (transparentRoute != null) {
      _webTransparentRoute = null;
      setFushiPageRouteTransparent(transparentRoute, false);
    }
    if (_webUnderlayHeld) {
      _webUnderlayHeld = false;
      unawaited(releaseUnderlayComposition());
    }
  }
}
