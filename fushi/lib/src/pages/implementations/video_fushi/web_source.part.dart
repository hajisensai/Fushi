part of '../video_fushi_page.dart';

/// 网页档（站点视频，[VideoPlayerController.isWebBackend]）能服务的控制条按钮：逐帧 /
/// 片段导出 / 弹幕都要 libmpv 或本地媒体文件，一律不画；截图与识别画面文字只在站点画面能
/// 截帧时画（[canCaptureFrame]：页面 canvas 截 `<video>` 当前帧，YouTube 等可以、Netflix DRM
/// 不行——截图与暂停 OCR 同一条截帧链路，BUG-5417）；音轨只在站点上报了音轨时画
/// （[hasSiteAudioTracks]，目前只有 Netflix）；章节按钮交给通用门控（站点给了片头片尾标记才
/// 有章节）。纯函数，控制条门控 `_shouldRenderControlItem` 与测试同源调用。
@visibleForTesting
bool videoWebBackendSupportsControlItem(
  VideoControlItem item, {
  bool hasSiteAudioTracks = false,
  bool canCaptureFrame = false,
}) {
  switch (item) {
    case VideoControlItem.frameBackward:
    case VideoControlItem.frameForward:
    case VideoControlItem.clipExport:
    case VideoControlItem.danmaku:
      return false;
    case VideoControlItem.audioTrack:
      return hasSiteAudioTracks;
    // 截图 / 识别画面文字：站点画面能在页面里截帧（非 DRM，YouTube 等）才画。
    case VideoControlItem.screenshot:
    case VideoControlItem.ocrFrame:
      return canCaptureFrame;
    default:
      return true;
  }
}

/// 网页档（站点视频）里键盘 / 手柄 / 自定义按钮触发的视频动作，哪些站点后端服务不了而诚实
/// no-op：着色器对比、逐帧、小窗都要 libmpv 或本地媒体。截图（页面截帧，截不到时
/// `_saveScreenshot` 给 OSD 说明）与上 / 下一章（站点章节 [VideoPlayerController.setWebChapters]）
/// 站点能服务，不在此列——它们曾被一刀切成 no-op，按键「没反应」（BUG-5417）。纯函数，
/// `_buildVideoShortcutActions` 与测试同源调用。
@visibleForTesting
bool videoWebBackendSupportsShortcutAction(ShortcutAction action) {
  switch (action) {
    case ShortcutAction.videoToggleShaderCompare:
    case ShortcutAction.videoPreviousFrame:
    case ShortcutAction.videoNextFrame:
    case ShortcutAction.videoToggleMiniWindow:
      return false;
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

/// 播放器层这份站点快照该不该挂播放器控件（纯函数，[_VideoWebSource._webPlayerModeFor] 与测试
/// 同源调用）：页面里有视频、站点弹层没打断播放（「还在看吗？」/ 播放错误时要露出站点页面让
/// 用户点）、地址是观看页。播放器层只当播放器，没有「回到网页」这一档
/// （`docs/specs/2026-11-01-one-browser.md`）。
@visibleForTesting
bool webVideoShowsPlayer({
  required bool hasVideo,
  required bool blocked,
  required String href,
}) => hasVideo && !blocked && webVideoIsWatchPage(href);

/// 播放器层该不该因为地址关掉、回到浏览器（纯函数，[_VideoWebSource._onWebNav] 与测试同源
/// 调用）：主框架离开了观看页（Netflix 片尾跳回浏览页、未登录被带去登录页、YouTube 跳出
/// watch）。空地址（还没导航）不算。
@visibleForTesting
bool webVideoLeavesPlayer(String url) =>
    url.isNotEmpty && !webVideoIsWatchPage(url);

/// 网页档设置面板的分组：mpv / 弹幕都作用在 libmpv 或本地文件上，去掉。「画质增强」页签
/// 保留——着色器同样不生效，但整页消失会被当成「画质增强按钮没了」（拍板 kp-No6loQi），
/// 改由面板在网页档把这一页画成说明态（为什么不生效 + 切到内置网页播放器档的入口，
/// [VideoQuickSettingsSheet.webBackend]）。
@visibleForTesting
List<settings_dest.VideoGroup> videoWebBackendSettingsGroups(
  List<settings_dest.VideoGroup> groups,
) => <settings_dest.VideoGroup>[
  for (final settings_dest.VideoGroup g in groups)
    if (g != settings_dest.VideoGroup.mpv &&
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
  /// 网页站流媒体书的入口（[_initVideo] 分流到这里）：播放方式按 [resolveWebVideoHosting]
  /// （手动选择 > 按站点实测 > DRM 且能高于 1080p 的预判 > Fushi 播放）。站点原生播放拿到底层
  /// 合成就在本页播；否则交给内置网页播放器页（它自己的 DOM 字幕层 / 超分 / 制卡重放）。
  Future<void> _openWebSource(VideoBookRow row) async {
    final bool underlay = await underlayCompositionSupported();
    if (!context.mounted) return;
    final WebVideoHosting hosting = resolveWebVideoHostingFromPrefs(
      appModel.prefsRepo.getPref,
      siteKey: webVideoSiteKey(Uri.parse(row.videoPath)),
      underlaySupported: underlay,
      displayHeightPx: webVideoDisplayHeightPx(context),
    );
    if (hosting == WebVideoHosting.windowed &&
        await acquireUnderlayComposition()) {
      if (!mounted) {
        // dispose 已在 await 期间跑过（那时还没持有），这份由这里归还。
        unawaited(releaseUnderlayComposition());
        return;
      }
      _webUnderlayHeld = true;
      // 站点画面从透明像素处透出来：本页的路由层页底（底色 + 背景装饰）必须让开，
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
      // 浏览器交接过来的：那个标签页就在下面、还停在这个地址，回去即可；再压一个浏览器就是
      // 第二个浏览器。
      if (widget.webBackToBrowser) {
        Navigator.of(context).pop();
      } else {
        unawaited(
          Navigator.of(
            context,
          ).pushReplacement(fushiWebBrowserRoute(context, site.url)),
        );
      }
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
    // 浏览器共享的站点设置（广告拦截 / 网页深色 / 网站设置）：与 app 内浏览器同一个服务、同一份
    // 偏好，见 `web_video_browser_settings.dart`。与浏览器标签页同法：建 WebView 前先等缓存
    // 引擎进内存（本地反序列化，不等网络），否则首页子资源请求与 documentStart 取的
    // cosmetic 都落在空引擎上；联网刷新过期列表留在后台。
    final WebAdblockService adblock = ref.read(webAdblockServiceProvider);
    await warmWebVideoAdblock(adblock, logTag: 'VideoFushi.web.adblockLoad');
    if (!mounted) return;
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
      adblock: adblock,
      browserPrefs: appModel.prefsRepo,
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
    session.mainFrameUrl.addListener(_onWebNav);
    _rebuild(() {
      _webSession = session;
      _webPlatform = platform;
      _controller = controller;
      _pendingController = null;
      _title = row.title;
      _failed = false;
      _failureHealsOnOpen = false;
      _failReason = null;
      _failTorrentVideo = null;
      _currentVideoPath = null;
      // 页级加载态到此为止：视频区从这一帧起就是站点页面（登录 / 选人），有了 <video>
      // 再挂播放器控件。
      _videoReadyToShow = true;
    });
    _syncVolumeDisplay(controller.volume);
    // 手机遥控：与本地片源同一个绑定（[_registerVideoRemote]），字幕轨 / 在线字幕 / 制卡
    // 按网页档分流。
    _registerVideoRemote(controller);
    // 章节来自站点（Netflix 片头片尾标记，[setWebChapters]）：按钮随有无章节出现 / 消失。
    _attachControllerChapterListener(controller);
    _adoptHandedOverFullscreenForWeb();
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    _seedWarmPopup();
    unawaited(_refreshFavoritedCueCache());
    unawaited(_refreshStagedMineCount());
    if (Platform.isWindows) _startWebMineIdle();
    final WebMineReturnState? restore = widget.webReturnState;
    if (restore != null) {
      // 制卡重放换回来的：用户重放前的选择就是「亲手选过的」，不让每集首次的语言偏好盖掉。
      _webSubtitleUserChosen = true;
      _webAudioUserChosen = true;
      _webPendingRestore = WebMineRestoreTracker(restore, now: DateTime.now());
    }
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
    final bool videoChanged = state.videoKey != _webTrackSel.videoKey;
    if (videoChanged) {
      final bool generatedWasActive =
          _webTrackSel.activeKey != null &&
          _webTrackSel.activeKey ==
              webVideoGeneratedTrackKey(_webTrackSel.videoKey);
      // 站内换了视频：新视频的播放头不能写进上一集的进度，先断开，播放器档再按地址重绑。
      _controller?.rebindWebBook(null);
      _webTrackSel.beginVideo(state.videoKey);
      _webFailedTrackKeys.clear();
      // 上一集选的图片字幕轨不跟到新视频（新文档的 glue 也已按宿主开关藏起站点字幕）。
      _setWebSiteImageTrackShown(false);
      _reselectWebTrack();
      // 仍是已落书的这一集（站点只是换了视频 key）：生成字幕按新 key 重挂，原来选着就接着选。
      if (webVideoEpisodeUrl(state.href) == _webBoundEpisodeUrl) {
        _installWebGeneratedTrack(select: generatedWasActive);
      }
    }
    if (!listEquals(state.siteTracks, _webSiteTracks) ||
        state.siteTrackCurrent != _webSiteTrackCurrent) {
      _rebuild(() {
        _webSiteTracks = state.siteTracks;
        _webSiteTrackCurrent = state.siteTrackCurrent;
      });
    }
    _checkWebPendingTrackCapture();
    _applyWebPendingRestore(state);
    _maybeRequestDefaultSiteTrack();
    _syncWebAudioTracks(state);
    _syncWebNetflixMetadata(state);
    _notifyWebBlocker(state);
    _observeWebHosting(state);
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
    if (playerMode != _webPlayerMode) {
      _rebuild(() => _webPlayerMode = playerMode);
      // 进了播放器档：WebView 不再收输入，键盘焦点收回播放器。
      if (playerMode) {
        _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
      }
    }
  }

  /// 本页一定是站点原生播放：逐拍喂实测探针，结论按站点记下（下次默认播放方式据此定）。
  void _observeWebHosting(WebVideoPlaybackState state) {
    final WebVideoHostingVerdict? verdict = _webHostingProbe.observe(state);
    final Uri? uri = Uri.tryParse(state.href);
    if (verdict == null || uri == null || uri.host.isEmpty) return;
    unawaited(
      recordWebVideoHostingVerdict(
        getPref: appModel.prefsRepo.getPref,
        setPref: appModel.prefsRepo.setPref,
        siteKey: webVideoSiteKey(uri),
        verdict: verdict,
      ),
    );
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
      unawaited(_restoreWebGeneratedSubtitle());
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
      _webTrackSel.clearTracks();
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
    // 站点剧集 metadata 先于这一集落书到了：这一集现在才有书，收进它的剧合集。
    final String? boundWatchId = _webNetflixWatchId(url);
    final NetflixTitleMetadata? boundMeta = boundWatchId == null
        ? null
        : _webNetflixMeta[boundWatchId];
    if (boundMeta != null) unawaited(_linkWebSeries(boundMeta));
    unawaited(_restoreWebGeneratedSubtitle());
  }

  /// 把库里这部剧已落书的各集收进它的 playlist 合集（GBDddvjDsj / BUG-4024：继续观看 /
  /// 视频库按剧归组、续播带系列上下文）。metadata 到达（顺带收编本修复前散着的集）与新一集
  /// 落书两处触发，幂等。
  Future<void> _linkWebSeries(NetflixTitleMetadata meta) async {
    try {
      await linkWebVideoSeriesEpisodes(appModel.database, meta);
    } catch (e, st) {
      ErrorLogService.instance.log('VideoFushi.webSeries', e, st);
    }
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

  /// 这份快照该不该挂播放器控件（[webVideoShowsPlayer]）。站点弹层打断时播放器控件让开、露出
  /// 站点页面让用户点；弹层没了（快照 blk 回空）自动回到播放器。
  bool _webPlayerModeFor(WebVideoPlaybackState state) => webVideoShowsPlayer(
    hasVideo: state.hasVideo,
    blocked: state.isBlocked,
    href: state.href,
  );

  void _onWebTrack(WebVideoTrack track) {
    if (!mounted) return;
    _webTrackSel.tracks[track.key] = track;
    if (track.cues.isNotEmpty) _webFailedTrackKeys.remove(track.key);
    _reselectWebTrack(updatedKey: track.key);
    // live 轨长了：待采整轨的失败判据可能成立了。
    if (track.isLive) _checkWebPendingTrackCapture();
  }

  /// bridge 回报某条整轨抓取失败：在途的那条落成失败（面板显示失败、可点选重试）。
  void _onWebTrackFailed(String key) {
    if (!mounted) return;
    _rebuild(() {
      _webFailedTrackKeys.add(key);
      if (_webTrackSel.pendingKey == key) _webTrackSel.pendingKey = null;
    });
  }

  int _webLiveCueCount() =>
      _webTrackSel
          .tracks['${_webTrackSel.videoKey}|$kWebVideoLiveTrackLang']
          ?.cues
          .length ??
      0;

  /// 待采整轨的确定失败判据（[webVideoPendingTrackCaptureFailed]）。
  void _checkWebPendingTrackCapture() {
    final String? pending = _webTrackSel.pendingKey;
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
  /// 选择与重灌判据和内置网页播放器同一份 [WebVideoTrackSelection.reselect]。
  void _reselectWebTrack({String? updatedKey}) {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.isWebBackend) return;
    final WebVideoTrackReselect r = _webTrackSel.reselect(
      updatedKey: updatedKey,
      preferredLanguage: _webPreferredSubtitleLanguage,
    );
    if (!r.reload) return;
    controller.setCues(r.cues);
    final int? pos = controller.positionMs;
    if (pos != null) controller.updateCueForPosition(pos);
    if (r.changed) _rebuild(() {});
  }

  /// 默认字幕语言（与内置网页播放器同一条偏好链，[webVideoPreferredSubtitleLanguage]）。
  String? get _webPreferredSubtitleLanguage =>
      webVideoPreferredSubtitleLanguage(
        subtitleWorkbenchLanguage: appModel.jimakuDefaultLanguage,
        bookLanguage: _bookRow?.language,
        defaultContentLanguage: appModel.defaultContentLanguage,
      );

  /// 加载 [track] 的整轨：站点播放器轨（Netflix）让播放器切过去，它随即下载那条字幕文件、bridge
  /// 截下整轨；按需加载的占位轨（YouTube 等，[WebVideoSiteTrack.isLazy]）让站点桥去取。整轨到了由
  /// [_reselectWebTrack] 选中并钉住（[_webTrackSel.pendingKey]）。
  void _requestWebSiteTrack(WebVideoSiteTrack track, {bool byUser = false}) {
    final WebVideoSession? session = _webSession;
    if (session == null) return;
    if (byUser) _webSubtitleUserChosen = true;
    _webTrackSel.subtitlesOff = false;
    if (track.isLazy) {
      _requestWebLazyTrack(session, track);
      return;
    }
    unawaited(
      session.evaluate(
        'window.__fushiWebVideo.selectNetflixTrack(${jsonEncode(track.id)})',
      ),
    );
    if (track.imageBased) {
      // 图片字幕截不到文字：不进 Fushi 叠层，让站点自己画（不可查词）。
      _webTrackSel.pendingKey = null;
      _webTrackSel.pinnedKey = null;
      _webTrackSel.activeKey = null;
      _setWebSiteImageTrackShown(true);
      _reselectWebTrack();
      _rebuild(() {});
      return;
    }
    _setWebSiteImageTrackShown(false);
    _markWebTrackRequested(track.storeKey(_webTrackSel.videoKey));
  }

  /// 记下显式请求的整轨：早已采到就直接钉住，否则等它到（[_webTrackSel.pendingKey]）。
  void _markWebTrackRequested(String key) {
    _webFailedTrackKeys.remove(key);
    _webPendingLiveCueCount = _webLiveCueCount();
    if (_webTrackSel.tracks[key]?.cues.isNotEmpty ?? false) {
      // 早已采到（Netflix 选回之前看过的轨不会重新下载）：直接选中。
      _webTrackSel.pendingKey = null;
      _webTrackSel.pinnedKey = key;
    } else {
      _webTrackSel.pendingKey = key;
    }
    _reselectWebTrack();
    _rebuild(() {});
  }

  /// 按需加载的占位轨：让站点桥取整轨（glue `requestLazyTrack` → providers
  /// `fushiRequestLazyTrack`）。整轨照常经 `{type:'track'}` 到；取不到时桥发失败回执
  /// （`{type:'trackFailed'}` → [_onWebTrackFailed]）。页面答「已不是占位」而 Dart 这边也没有
  /// 这条整轨（换了视频 / 清单过期），同样是确定的失败。
  void _requestWebLazyTrack(WebVideoSession session, WebVideoSiteTrack track) {
    _setWebSiteImageTrackShown(false);
    final String key = track.storeKey(_webTrackSel.videoKey);
    _markWebTrackRequested(key);
    if (_webTrackSel.pendingKey != key) return; // 早已采到
    unawaited(
      session
          .evaluate(
            'window.__fushiWebVideo.requestLazyTrack(${jsonEncode(key)})',
          )
          .then((Object? result) {
            if (!mounted || result == 'requested') return;
            if (_webTrackSel.pendingKey == key &&
                !(_webTrackSel.tracks[key]?.cues.isNotEmpty ?? false)) {
              ErrorLogService.instance.log(
                'VideoFushi.web',
                'lazy subtitle track not requestable ($result): $key',
              );
              _onWebTrackFailed(key);
            }
          }),
    );
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
    if (_webTrackSel.subtitlesOff ||
        _webSubtitleUserChosen ||
        _webSiteTracks.isEmpty ||
        _webSiteTrackAutoVideoKey == _webTrackSel.videoKey ||
        // 这一集生成的字幕已选上（重进时读回的登记）：不再替用户换成站点轨。
        _webTrackSel.pinnedKey ==
            webVideoGeneratedTrackKey(_webTrackSel.videoKey)) {
      return;
    }
    _webSiteTrackAutoVideoKey = _webTrackSel.videoKey;
    final WebVideoSiteTrack? preferred = pickWebVideoSiteTrackForLanguage(
      _webSiteTracks,
      _webPreferredSubtitleLanguage,
    );
    if (preferred != null) {
      if (preferred.id != _webSiteTrackCurrent ||
          _webTrackSel.activeKey != preferred.storeKey(_webTrackSel.videoKey)) {
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

  /// 正在看的这一集有 metadata 就用（剧集面板 / 章节），没有就向站点要（每个 id 在途只一次；
  /// 失败记日志，换了视频文档再要，见 [_webNetflixMetaFailedAt]）。
  void _syncWebNetflixMetadata(WebVideoPlaybackState state) {
    final String? watchId = _webNetflixWatchId(state.href);
    if (watchId == null) return;
    final NetflixTitleMetadata? meta = _webNetflixMeta[watchId];
    if (meta != null) {
      _applyWebNetflixMetadata(meta, watchId, state.durationMs);
      return;
    }
    if (!state.hasVideo || _webNetflixMetaInFlight.contains(watchId)) return;
    final String? failedAt = _webNetflixMetaFailedAt[watchId];
    if (failedAt != null) {
      if (failedAt == state.videoKey) return;
      _webNetflixMetaFailedAt.remove(watchId);
    } else if (!_webNetflixMetaRequested.add(watchId)) {
      return;
    }
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
    if (!mounted) return;
    void failed() => _webNetflixMetaFailedAt[movieId] =
        _webSession?.lastState?.videoKey ?? '';
    if (text == null) {
      failed();
      return;
    }
    final NetflixTitleMetadata? meta = parseNetflixMetadata(text);
    if (meta != null && !meta.describes(movieId)) {
      ErrorLogService.instance.log(
        'VideoFushi.web',
        'netflix metadata $movieId: response does not contain that episode',
      );
      failed();
      return;
    }
    if (meta == null) {
      ErrorLogService.instance.log(
        'VideoFushi.web',
        'netflix metadata $movieId: unrecognised shape',
      );
      failed();
      return;
    }
    _webNetflixMeta[movieId] = meta;
    for (final NetflixEpisode e in meta.episodes) {
      _webNetflixMeta[e.id] = meta;
      _webNetflixMetaRequested.add(e.id);
    }
    unawaited(_linkWebSeries(meta));
    final WebVideoPlaybackState? state = _webSession?.lastState;
    final String? watchId = state == null
        ? null
        : _webNetflixWatchId(state.href);
    if (watchId != null && _webNetflixMeta[watchId] == meta) {
      _applyWebNetflixMetadata(meta, watchId, state!.durationMs);
      // 封面 / 真名补全原本只在下一份快照触发：暂停时 metadata 到了也立刻补（BUG-3801）。
      if (_webPlayerMode) unawaited(_bindWebEpisode(state));
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
    unawaited(session.loadUrl(_webEpisodeUrls[index]));
  }

  /// 站点播放器里还没采到整轨的字幕轨（面板里列在已采到的轨后面，点选加载）。
  List<WebVideoSiteTrack> _unloadedWebSiteTracks() {
    final Set<String> loaded = <String>{
      for (final WebVideoTrack track in _currentWebTracks()) track.key,
    };
    return <WebVideoSiteTrack>[
      for (final WebVideoSiteTrack track in _webSiteTracks)
        if (!loaded.contains(track.storeKey(_webTrackSel.videoKey))) track,
    ];
  }

  /// 已采到的整轨在面板里的名字：站点显示名（「English [CC]」）优先，live 轨用固定文案。
  String _webTrackLabel(WebVideoTrack track) {
    if (track.isLive) return t.web_video_track_live;
    if (track.lang == kWebVideoGeneratedTrackLang) {
      return t.web_video_track_generated;
    }
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
    final String key = track.storeKey(_webTrackSel.videoKey);
    if (_webFailedTrackKeys.contains(key)) return t.web_video_track_failed;
    if (_webTrackSel.pendingKey == key) return t.web_video_track_loading;
    return t.web_video_track_site;
  }

  /// 当前视频可选的站点字幕轨（有 cue 的才列）。
  List<WebVideoTrack> _currentWebTracks() => _webTrackSel.currentTracks;

  void _selectWebTrack(String? key) {
    _webSubtitleUserChosen = true;
    _webTrackSel.choose(key);
    _setWebSiteImageTrackShown(false);
    _reselectWebTrack();
    _rebuild(() {});
  }

  /// 设置面板「字幕」分类顶部的轨列表（网页档）：字幕工作台（生成字幕、对照表、跳转、拆分）
  /// + 关闭 + 每条轨（站点轨、下载 / 拆分出的本机轨、这一集生成的字幕）。导入文件 / 自动获取 /
  /// 转录 / 对轴这些行都要本地媒体，网页档不列。
  Widget _buildWebSubtitleTrackRows(BuildContext context) {
    final Color? selectedFg = videoPanelSelectedForeground(context);
    final List<WebVideoTrack> tracks = _currentWebTracks();
    final List<WebVideoSiteTrack> siteTracks = _unloadedWebSiteTracks();
    final VideoPlayerController? controller = _controller;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 字幕工作台：与本机 / 远端字幕菜单同一个入口（生成字幕是工作台里的一项工具，
        // 内嵌生成面板先从页面取媒体地址拉整集音频，见 [_webSubtitleStudioPanel]）。
        if (controller != null &&
            _subtitleStudioAvailable(controller)) ...<Widget>[
          FushiListTileControl(
            key: const ValueKey<String>('video-web-subtitle-studio'),
            leading: const FushiIcon(FushiIcons.transcribe),
            title: Text(t.video_subtitle_studio_title),
            subtitle: Text(t.video_subtitle_studio_entry_hint),
            onTap: () => unawaited(_openSubtitleStudio(controller)),
          ),
          const FushiDividerControl(height: 1),
        ],
        FushiListTileControl(
          key: const ValueKey<String>('video-web-subtitle-off'),
          leading: const FushiIcon(FushiIcons.subtitlesOff),
          title: Text(t.video_subtitle_off),
          selected: _webTrackSel.activeKey == null,
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
            selected: track.key == _webTrackSel.activeKey,
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

  /// 把本机字幕文件 [path]（手机下载的在线字幕、工作台拆分出的日语字幕）作为一条轨并进
  /// 当前视频的站点轨并选中。网页轨的显示名取 lang（[_webTrackLabel]）：本机档用文件名。
  void _selectWebLocalSubtitleTrack(String path, List<AudioCue> cues) {
    final String name = p.basename(path);
    final String key = '${_webTrackSel.videoKey}|download:$name';
    _webTrackSel.tracks[key] = WebVideoTrack(
      key: key,
      videoKey: _webTrackSel.videoKey,
      lang: name,
      cues: cues,
    );
    _selectWebTrack(key);
  }

  // ── 字幕生成（完整管线）────────────────────────────────────────────────────
  //
  // 网页档没有本机媒体：从页面取媒体地址（web_video_subtitle_media.dart：YouTube 现取
  // audio-only 流；其它站点用 <video> 直链或页面为这个视频请求过的 HLS / DASH 清单，带页面
  // 同一身份的 UA / Referer / Cookie），把整集音频拉成本机副本（与在线流同一个
  // [appVideoStreamSubtitleAudioStager]），再走 [AppVideoSubtitleService.resolveStream]。
  // 产物登记在这一集的书上（`video_books.subtitleSource`），作为一条可选轨并进站点轨。

  /// 网页档这一集能不能跑字幕生成管线（[webVideoSubtitlePipelineAvailable]）。EME 加密流
  /// （Netflix）客观拉不出音频，入口不出现；媒体地址拿不拿得到开拉时问页面。
  bool get _canRunWebSubtitlePipeline => webVideoSubtitlePipelineAvailable(
    webMode: _webMode,
    playerMode: _webPlayerMode,
    episodeBound: _webSubtitleEpisodeUrl != null,
    encrypted: _webSession?.lastState?.encrypted ?? false,
    asrSupported: isAsrSupported,
  );

  /// 已落成书的这一集的规范地址；站点入口还没播起任何一集时为 null。
  String? get _webSubtitleEpisodeUrl {
    final String? url = _webBoundEpisodeUrl;
    if (!_webMode || url == null || isWebVideoSiteBookUid(_activeBookUid)) {
      return null;
    }
    return url;
  }

  /// 网页档这一集整集音频副本的身份：键（来源 `web` + 这一集的地址 + 站点音轨，见
  /// [videoStreamSubtitleAudioKey]）、标题（副本 / 导出字幕的文件名用）与这一集的书。
  ({String key, String title, String bookUid})? _webWholeAudioIdentity() {
    final String? url = _webSubtitleEpisodeUrl;
    if (url == null) return null;
    final String audioTrack =
        _webSession?.lastState?.siteAudioTrackCurrent ?? '';
    return (
      key: videoStreamSubtitleAudioKey(
        sourceId: 'web',
        videoId: url,
        episode: 0,
        audioTrack: audioTrack.isEmpty ? '-' : audioTrack,
      ),
      title: _bookRow?.title ?? _title ?? url,
      bookUid: _activeBookUid,
    );
  }

  /// 页面媒体地址的 Referer / YouTube 视频 id 用的观看页地址：快照里对过主机的地址，没有就用
  /// 这一集的规范地址。
  String _webSubtitlePageUrl(WebVideoSession session) {
    final String href = session.lastState?.href ?? '';
    return href.isNotEmpty ? href : (_webBoundEpisodeUrl ?? session.pageUrl);
  }

  /// 拿不到媒体的原因（给用户看）。
  String _webSubtitleMediaBlockMessage(WebVideoSubtitleMediaBlock reason) =>
      switch (reason) {
        WebVideoSubtitleMediaBlock.noVideo =>
          t.web_video_subtitle_media_no_video,
        WebVideoSubtitleMediaBlock.encrypted =>
          t.web_video_subtitle_media_encrypted,
        WebVideoSubtitleMediaBlock.noMediaAddress =>
          t.web_video_subtitle_media_no_address,
      };

  /// 开拉前现取输入（[prepareWebVideoSubtitleAudio]）；拿不到媒体时以说明原因的
  /// [VideoStreamSubtitleAudioUnavailable] 结束（进度对话框 / 内嵌面板照常显示原因）。
  Future<VideoStreamSubtitleAudioInput> _prepareWebWholeAudio(
    WebVideoSession session,
  ) async {
    try {
      return await prepareWebVideoSubtitleAudio(
        probe: () => session.evaluate('window.__fushiWebVideo.mediaSource()'),
        pageUrl: _webSubtitlePageUrl(session),
        cookieHeader: session.cookieHeaderFor,
      );
    } on WebVideoSubtitleMediaBlocked catch (e) {
      throw VideoStreamSubtitleAudioUnavailable(
        _webSubtitleMediaBlockMessage(e.reason),
      );
    }
  }

  /// AI 校对参考画面的视频地址（[webVideoSubtitleFrameInput]）；YouTube / 拿不到媒体为 null。
  Future<({String url, Map<String, String> headers})?> _webSubtitleFrameInput(
    WebVideoSession session,
  ) => webVideoSubtitleFrameInput(
    probe: () => session.evaluate('window.__fushiWebVideo.mediaSource()'),
    pageUrl: _webSubtitlePageUrl(session),
    cookieHeader: session.cookieHeaderFor,
  );

  /// 开拉这一集的整集音频（同一集已在拉就接上那一次）；不在可生成的这一集时 null。
  VideoStreamSubtitleAudioStaging? _startWebWholeAudio() {
    final VideoPlayerController? controller = _controller;
    final WebVideoSession? session = _webSession;
    final ({String key, String title, String bookUid})? id =
        _webWholeAudioIdentity();
    if (controller == null || session == null || id == null) return null;
    return appVideoStreamSubtitleAudioStager.start(
      key: id.key,
      title: id.title,
      durationMs: controller.durationMs ?? 0,
      prepare: () => _prepareWebWholeAudio(session),
    );
  }

  /// 这一集的管线目标：[audio] 是整集音频副本，产物落 app 字幕目录、登记成这一集的书的
  /// 字幕（页面关了也生效，重进时读回，见 [_restoreWebGeneratedSubtitle]），参考画面从页面
  /// 给的视频地址抽。副本已被清掉时 null。
  Future<AppVideoSubtitleTarget?> _webSubtitleTarget(File audio) async {
    final WebVideoSession? session = _webSession;
    final ({String key, String title, String bookUid})? id =
        _webWholeAudioIdentity();
    if (session == null || id == null) return null;
    final ({String url, Map<String, String> headers})? frame =
        await _webSubtitleFrameInput(session);
    final VideoBookRepository repo = widget.repo;
    final String bookUid = id.bookUid;
    final String? language = _bookRow?.language;
    try {
      return await appVideoSubtitleService(appModel).resolveStream(
        audioPath: audio.path,
        title: id.title,
        key: id.key,
        exportDir: videoStreamSubtitleExportDirUnder(
          await AppPaths.videoSubtitlesDirectory(),
        ),
        contentLanguage: language == null || language.isEmpty ? null : language,
        remember: (String subtitlePath) =>
            repo.updateSubtitleSource(bookUid, subtitlePath),
        frameSource: frame == null
            ? null
            : videoStreamSubtitleFrameSource(
                headers: frame.headers,
                input: () async => frame.url,
              ),
      );
    } on AppVideoSubtitleTargetNotFound {
      return null;
    }
  }

  /// 「生成字幕」（工作台里那一行按钮）：先把整集音频拉到本机（进度对话框，可取消），再打开
  /// 与本机视频同一个管线面板；任务结束后把产物作为一条轨选中。
  Future<void> _openWebSubtitlePipeline(
    VideoPlayerController controller,
  ) async {
    final ({String key, String title, String bookUid})? id =
        _webWholeAudioIdentity();
    if (id == null) return;
    bool isCurrent() =>
        mounted &&
        identical(_controller, controller) &&
        _webWholeAudioIdentity()?.key == id.key;
    final File? audio = await _stageWholeAudioWithDialog(
      key: id.key,
      title: id.title,
      start: _startWebWholeAudio,
      logTag: 'video.webSubtitleAudio',
    );
    if (audio == null || !isCurrent()) return;
    final AppVideoSubtitleTarget? target = await _webSubtitleTarget(audio);
    if (target == null || !isCurrent() || !context.mounted) return;
    await showVideoSubtitleGenerateSheet(
      context: context,
      service: appVideoSubtitleService(appModel),
      target: target,
      prefs: PrefsRepoVideoSubtitleGeneratePrefs(appModel.prefsRepo),
      openAiSettings: pushAiSettingsPage,
      onJobStarted: (AppVideoSubtitleJob job) => unawaited(
        _applyWebPipelineSubtitleWhenDone(
          controller,
          job,
          audio.path,
          id.bookUid,
        ),
      ),
      // 播放器里正显示的站点字幕交给 AI 校对当参考（按副本路径对上这一集）。
      pinnedEvidence: _playerSubtitleEvidence(controller, audio.path),
    );
  }

  /// 工作台内嵌的网页档生成面板：先拉整集音频（[VideoStreamSubtitleAudioPanel]，有进度、可
  /// 取消、拿不到媒体时说明原因；已拉好 / 正在拉时直接接上），拉好后原地换成本机管线面板。
  /// 换了集 / 播放器重建之后不再开拉、不再出面板。
  WidgetBuilder? _webSubtitleStudioPanel(VideoPlayerController controller) {
    final ({String key, String title, String bookUid})? id =
        _webWholeAudioIdentity();
    if (id == null) return null;
    bool isCurrent() =>
        mounted &&
        identical(_controller, controller) &&
        _webWholeAudioIdentity()?.key == id.key;
    final AppVideoSubtitleService service = appVideoSubtitleService(appModel);
    return (BuildContext context) => VideoStreamSubtitleAudioPanel(
      existing: () => appVideoStreamSubtitleAudioStager.existing(
        key: id.key,
        title: id.title,
      ),
      inflight: () => appVideoStreamSubtitleAudioStager.inflight(id.key),
      start: () => isCurrent() ? _startWebWholeAudio() : null,
      onFailed: (Object error, StackTrace stack) =>
          ErrorLogService.instance.log('video.webSubtitleAudio', error, stack),
      ready: (File audio) async {
        if (!isCurrent()) return null;
        final AppVideoSubtitleTarget? target = await _webSubtitleTarget(audio);
        if (target == null || !isCurrent()) return null;
        final Map<String, List<SubtitleEvidenceTrack>> pinnedEvidence =
            _playerSubtitleEvidence(controller, audio.path);
        return (BuildContext context) => VideoSubtitleGenerateSheet(
          embedded: true,
          service: service,
          target: target,
          prefs: PrefsRepoVideoSubtitleGeneratePrefs(appModel.prefsRepo),
          openAiSettings: pushAiSettingsPage,
          onJobStarted: (AppVideoSubtitleJob job) => unawaited(
            _applyWebPipelineSubtitleWhenDone(
              controller,
              job,
              audio.path,
              id.bookUid,
            ),
          ),
          pinnedEvidence: pinnedEvidence,
        );
      },
    );
  }

  /// 管线结束后：页面还停在同一个播放器、同一集（[bookUid]）就把产物作为生成字幕轨装上并
  /// 选中（产物已由落点登记到书上，页面关了 / 换了集也照样在重进时读回）；跳过了就说明原因。
  Future<void> _applyWebPipelineSubtitleWhenDone(
    VideoPlayerController controller,
    AppVideoSubtitleJob job,
    String audioPath,
    String bookUid,
  ) async {
    await job.done;
    bool isCurrent() =>
        mounted &&
        identical(_controller, controller) &&
        _activeBookUid == bookUid;
    if (!isCurrent() || job.status != AppVideoSubtitleJobStatus.succeeded) {
      return;
    }
    final VideoSubtitleEpisodeResult? result = job.result?.episodes
        .firstWhereOrNull(
          (VideoSubtitleEpisodeResult r) => p.equals(r.videoPath, audioPath),
        );
    if (result == null) return;
    final String? output = result.outputPath;
    if (!result.exported || output == null) {
      _showOsd(
        videoSubtitleEpisodeStatusLabel(result, language: job.options.language),
        severity: ToastSeverity.warning,
      );
      return;
    }
    final List<AudioCue> cues = await _loadExternalSubtitleCues(
      output,
      bookUid,
    );
    if (!isCurrent()) return;
    if (cues.isEmpty) {
      _showOsd(
        t.video_subtitle_load_failed(label: p.basename(output)),
        severity: ToastSeverity.error,
      );
      return;
    }
    _webGeneratedSubtitle = (bookUid: bookUid, path: output, cues: cues);
    _webGeneratedCheckedBookUid = bookUid;
    _webSubtitleUserChosen = true;
    _installWebGeneratedTrack(select: true);
    _showOsd(t.video_subtitle_switched(label: t.web_video_track_generated));
  }

  /// 重进 / 换到某一集时读回这一集的书登记的生成字幕（`subtitleSource`，由管线落点写）：
  /// 文件还在就作为生成字幕轨装上；用户这次会话里还没亲手选过轨时直接选中。每集只读一次。
  Future<void> _restoreWebGeneratedSubtitle() async {
    final String bookUid = _activeBookUid;
    if (_webSubtitleEpisodeUrl == null ||
        _webGeneratedCheckedBookUid == bookUid) {
      return;
    }
    _webGeneratedCheckedBookUid = bookUid;
    final VideoBookRow? row = await appModel.database.getVideoBookByBookUid(
      bookUid,
    );
    final String? source = row?.subtitleSource;
    if (source == null ||
        !isExternalSubtitleFilePathForMenu(source) ||
        !await File(source).exists()) {
      return;
    }
    final List<AudioCue> cues = await _loadExternalSubtitleCues(
      source,
      bookUid,
    );
    if (!mounted || _activeBookUid != bookUid || cues.isEmpty) return;
    _webGeneratedSubtitle = (bookUid: bookUid, path: source, cues: cues);
    _installWebGeneratedTrack(
      select: !_webSubtitleUserChosen && !_webTrackSel.subtitlesOff,
    );
  }

  /// 把这一集的生成字幕（[_webGeneratedSubtitle]）挂到当前视频 key 下（不是这一集的、还没有
  /// 视频 key 时不挂）；[select] 时钉住它（撤掉还在途的站点轨请求，免得后到的站点轨抢走）。
  void _installWebGeneratedTrack({required bool select}) {
    final ({String bookUid, String path, List<AudioCue> cues})? generated =
        _webGeneratedSubtitle;
    if (generated == null ||
        generated.bookUid != _activeBookUid ||
        _webTrackSel.videoKey.isEmpty) {
      return;
    }
    final String key = webVideoGeneratedTrackKey(_webTrackSel.videoKey);
    _webTrackSel.tracks[key] = WebVideoTrack(
      key: key,
      videoKey: _webTrackSel.videoKey,
      lang: kWebVideoGeneratedTrackLang,
      cues: generated.cues,
      languageCode: webVideoGeneratedSubtitleLanguage(generated.path),
    );
    if (select) {
      _webTrackSel.subtitlesOff = false;
      _webTrackSel.pendingKey = null;
      _setWebSiteImageTrackShown(false);
      _webTrackSel.pinnedKey = key;
    }
    _reselectWebTrack();
    _rebuild(() {});
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
      _buildVideoShortcutActions(controller),
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
    _initialFullscreen.settle();
    if (!_ownsHandedOverNativeFullscreen) return;
    _ownsHandedOverNativeFullscreen = false;
    _rebuild(() => _webWindowFullscreen = true);
  }

  /// 视频槽：站点 WebView 垫在最底层（稳定 key，有无 <video> 两种布局之间不重建）；有视频时
  /// 上面是原生 [Video]（透明底）+ 控制条，没视频 / 站点弹层打断时只在顶部留一条细返回条
  /// （[_buildWebReturnBar]，淡入淡出）、站点页面让在它下面。
  Widget _wrapWebVideoSurface(Widget video) {
    final WebVideoSession? session = _webSession;
    if (session == null) return video;
    final bool hasVideo = _webPlayerMode;
    // 网页档没有站点视频时顶部返回条的总高度（含顶部让位，见 [webVideoReturnBarExtent]）：
    // 站点页面让在它下面，返回钮不压在 WebView 上——收输入的 WebView2 子窗口会先于
    // Flutter 吃掉落在它矩形里的点击。
    final double barExtent = webVideoReturnBarExtent(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          top: hasVideo ? 0 : barExtent,
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
        if (hasVideo) Positioned.fill(child: video),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: barExtent,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: hasVideo
                ? const SizedBox.shrink(
                    key: ValueKey<String>('video-web-return-bar-hidden'),
                  )
                : _buildWebReturnBar(),
          ),
        ),
        // 露出站点页面时也要看得到短提示：播放器档的 OSD 层挂在控制条里，这里补一层。
        if (!hasVideo)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            top: barExtent,
            child: _buildOsdOverlay(),
          ),
      ],
    );
  }

  /// 播放器层露出站点页面时的细返回条（[WebVideoReturnBar]）：返回（关掉本层，与返回键同一条
  /// [_handleBackOrExit]）、标题、「在浏览器中打开」（[_exitWebToBrowser]）。
  Widget _buildWebReturnBar() {
    final WebVideoSession? session = _webSession;
    return WebVideoReturnBar(
      title: _titleNotifier,
      onBack: () => unawaited(_handleBackOrExit()),
      onOpenInBrowser: session == null
          ? null
          : () => _exitWebToBrowser(
              session.mainFrameUrl.value.isNotEmpty
                  ? session.mainFrameUrl.value
                  : session.pageUrl,
            ),
    );
  }

  /// 主框架地址变了（[WebVideoSession.mainFrameUrl] 的监听者）：离开观看页就回浏览器
  /// （[webVideoLeavesPlayer]）。
  void _onWebNav() {
    final WebVideoSession? session = _webSession;
    if (session == null) return;
    final String url = session.mainFrameUrl.value;
    if (webVideoLeavesPlayer(url)) _exitWebToBrowser(url);
  }

  /// 关掉播放器层、在浏览器里打开 [url]：浏览器交接过来的（[VideoFushiPage.webBackToBrowser]）
  /// 把地址交回那个标签页（[WebVideoBrowserReturn]）再关页；从视频库打开的没有浏览器可回，
  /// 先落进度再把本页换成一个浏览器页。只跑一次。
  ///
  /// 这条路径是**被动**的（站点自己跳页：Netflix 片尾回 /browse、会话过期跳登录页），触发时本页
  /// 上面可能压着对话框 / 弹出菜单：先按身份把压在本页路由上面的路由弹掉（[popRoutesAbove]），
  /// 之后的 pop / pushReplacement 作用的才是本页——否则关掉的是对话框、视频页留在下面继续占着
  /// 底层合成。本页路由已不在栈里时什么都不做、也不登记回程地址（不给下一次交接留过期地址）。
  void _exitWebToBrowser(String url) {
    final Uri? target = Uri.tryParse(url);
    final ModalRoute<dynamic>? ownRoute = mounted
        ? ModalRoute.of(context)
        : null;
    if (ownRoute == null ||
        !ownRoute.isActive ||
        _webExitingToBrowser ||
        target == null ||
        (target.scheme != 'http' && target.scheme != 'https')) {
      return;
    }
    while (_dismissTopForegroundLayer()) {}
    if (!popRoutesAbove(Navigator.of(context), ownRoute)) return;
    _webExitingToBrowser = true;
    if (widget.webBackToBrowser) {
      WebVideoBrowserReturn.offer(target);
      _exitVideoPage();
      return;
    }
    unawaited(_replaceWebWithBrowser(ownRoute, target));
  }

  Future<void> _replaceWebWithBrowser(
    ModalRoute<dynamic> ownRoute,
    Uri target,
  ) async {
    await _controller?.flushPosition();
    if (!context.mounted) return;
    final NavigatorState nav = Navigator.of(context);
    // 落进度期间又弹出来的层同样先收掉；本页已被别的路径关掉就不再换。
    if (!popRoutesAbove(nav, ownRoute)) return;
    unawaited(
      nav.pushReplacement(fushiWebBrowserRoute(context, target.toString())),
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
    final String href = state != null && state.href.isNotEmpty
        ? state.href
        : row.videoPath;
    final String sentence = fieldSentence.isEmpty
        ? cue.text.trim()
        : fieldSentence;
    // 入队要的身份在点下这一刻冻结：YouTube 直裁失败退回入队时已过了几秒，用户可能换了集。
    final String bookUid = _activeBookUid;
    final String videoKey = _webTrackSel.videoKey;
    Future<void> enqueue() async {
      await _webMineQueue.enqueue(
        bookUid: bookUid,
        videoKey: videoKey,
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
    }

    // YouTube 与浏览器扩展同一条路（[mineWebVideoCueDirectOrQueue]）：按视频 id + 字幕时间窗从
    // 真实视频流裁画面与音频，点下就在后台制卡——不回放，也就没有「回放时没全屏 / 外放声音 /
    // 字幕换了语言」这些问题；裁不出来才退回队列。
    final String? youtubeId = webVideoDirectMineVideoId(href);
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
          enqueue,
        ),
      );
      _showOsd(t.web_video_mine_background, icon: FushiIcons.checklist);
      return const MinePopupResult.queued();
    }
    await enqueue();
    // 卡还没真落地：弹窗画「已加入」✓、不回查 Anki（TODO-448）。空回执会被弹窗当成失败
    // （「导出卡片失败」），用户再点一次就重复入队。
    return const MinePopupResult.queued();
  }

  /// YouTube 后台制卡的结局只剩 OSD 能告诉用户（弹窗早已画了「已加入」）。直裁拿不到媒体退回
  /// 制卡队列（[enqueue] 自己报「已入队」）；与取媒体无关的失败（Anki 未配置 / 落卡失败等）
  /// 或连入队也失败则抛出，由 [_trackBackgroundMine] 报错并记日志。
  Future<void> _mineWebYoutubeCue(
    ImmersionMinePayload payload,
    Future<void> Function() enqueue,
  ) async {
    // 统计用发起时冻结的库与归属：直裁要等流解析 + 裁剪，落卡时可能已经换集 / 离页。
    final FushiDatabase mineDb = appModel.database;
    final ({String bookKey, String title}) statIdentity = _studyStatsIdentity;
    final RemoteMineResult? res = await mineWebVideoCueDirectOrQueue(
      mineDirect: () =>
          appModel.createRemoteMiningService().mineImmersion(payload),
      enqueue: enqueue,
      onFallback: (String reason) => ErrorLogService.instance.log(
        'VideoFushi.web',
        'YouTube direct mine failed, queued for replay: $reason',
      ),
    );
    if (res == null) return;
    switch (res.result) {
      case 'success':
        // 新制成功计入视频统计：与本页其它制卡（[_recordVideoMineStat]）、内置网页
        // 播放器页的直裁、队列重放落卡同一笔账——改走直裁不该让 YouTube 的卡不再计数。
        unawaited(_recordVideoMineStat(mineDb, statIdentity));
        _showMineOsd(
          t.card_exported(deck: res.deckName ?? ''),
          MineToastStatus.added,
        );
      case 'duplicate':
        _showMineOsd(t.card_duplicate, MineToastStatus.duplicate);
      default:
        throw StateError(res.message ?? res.detail ?? res.result);
    }
  }

  /// 顶栏「切换到 Fushi 播放」（本页一定是站点原生播放；站点入口没有库里的书、Fushi 播放读不到，
  /// 小窗 / 沉浸锁下也不画）。与跳转记录胶囊同一套外观，挂在右上组最前面。
  Widget? _webHostingTopBarButton({required bool desktop}) {
    if (!_webMode ||
        widget.webSite != null ||
        _inMiniWindow ||
        _immersiveLocked.value) {
      return null;
    }
    return Padding(
      key: const ValueKey<String>('video_web_hosting_top_bar'),
      padding: EdgeInsetsDirectional.only(end: 8 * _videoUiScale),
      child: VideoGlassSurface(
        enabled: _appleChrome,
        child: FushiTooltip(
          message: t.web_video_hosting_switch_to_builtin,
          child: Semantics(
            button: true,
            label: t.web_video_hosting_switch_to_builtin,
            child: _chromeIconButton(
              icon: FushiIcons.video,
              desktop: desktop,
              onPressed: () => unawaited(_switchWebToBuiltinHosting()),
            ),
          ),
        ),
      ),
    );
  }

  /// 「画质增强」说明态里的「切换到内置网页播放器」：记住宿主档偏好（与内置网页播放器页的
  /// 宿主档菜单同一个键），同一本书原地换成内置网页播放器页（它有自己的超分，见
  /// `web_video_shaders.dart`），集 / 轨 / 位置一并带过去。站点入口（[VideoFushiPage.webSite]）
  /// 没有库里的书、内置档读不到，不给这个入口。
  Future<void> _switchWebToBuiltinHosting() async {
    final WebVideoPlaybackState? state = _webSession?.lastState;
    final VideoBookRow? row = _bookRow;
    if (row != null) {
      await appModel.prefsRepo.setPref(
        kWebVideoHostingManualBySitePrefKey,
        recordManualWebVideoHosting(
          appModel.prefsRepo.getPref(kWebVideoHostingManualBySitePrefKey),
          webVideoSiteKey(Uri.parse(row.videoPath)),
          WebVideoHosting.builtin,
        ),
      );
    }
    await _controller?.flushPosition();
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => WebVideoFushiPage.neutralized(
          bookUid: _activeBookUid,
          repo: widget.repo,
          hosting: WebVideoHosting.builtin,
          mineReturnState: state == null ? null : WebMineReturnState.of(state),
          returnToBrowser: widget.webBackToBrowser,
        ),
      ),
    );
  }

  /// 跑制卡队列：同一本书原地换成内置网页播放器（可捕获的 1080p 档），画面一就绪就自动
  /// 逐句重放落卡（[WebVideoFushiPage.autoRunMineQueue]）。[idle] = 空闲自动制卡的交接：
  /// 那边静音跑、有输入即让位，跑完换回本页（[WebVideoFushiPage.returnHostingAfterMining]）。
  Future<void> _runWebMineQueue({bool idle = false}) async {
    final WebVideoPlaybackState? state = _webSession?.lastState;
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
          // 手动 / 空闲都回到本页（重放前的集 / 轨 / 位置一并带过去、再带回来）。
          returnHostingAfterMining: WebVideoHosting.windowed,
          idleAutoMining: idle,
          mineReturnState: state == null ? null : WebMineReturnState.of(state),
          returnToBrowser: widget.webBackToBrowser,
        ),
      ),
    );
  }

  /// 每拍站点状态到来时把 [_webPendingRestore] 对齐一次；每项动作最多首发 + 一次补发
  /// （[WebMineRestoreTracker]）。
  void _applyWebPendingRestore(WebVideoPlaybackState state) {
    final WebMineRestoreTracker? tracker = _webPendingRestore;
    if (tracker == null) return;
    final WebVideoSession? session = _webSession;
    if (session == null) return;
    final WebMineRestorePlan? plan = tracker.step(state, DateTime.now());
    if (plan == null) {
      _webPendingRestore = null;
      return;
    }
    final String? href = plan.navigateHref;
    if (href != null) {
      unawaited(session.loadUrl(href));
      return;
    }
    final String? text = plan.selectTextTrack;
    if (text != null) {
      if (text.isEmpty) {
        _selectWebTrack(null);
        unawaited(
          session.evaluate("window.__fushiWebVideo.selectNetflixTrack('')"),
        );
      } else {
        final WebVideoSiteTrack? track = state.siteTracks
            .where((WebVideoSiteTrack t) => t.id == text)
            .firstOrNull;
        if (track != null) _requestWebSiteTrack(track, byUser: true);
      }
    }
    final String? audio = plan.selectAudioTrack;
    final VideoPlayerController? controller = _controller;
    if (audio != null && controller != null) {
      final AudioTrack? track = controller.audioTracks
          .where((AudioTrack t) => t.id == audio)
          .firstOrNull;
      if (track != null) unawaited(controller.selectAudioTrack(track));
    }
    final int? seek = plan.seekMs;
    if (seek != null && controller != null) unawaited(controller.seekMs(seek));
    switch (plan.setPlaying) {
      case true:
        if (controller != null) unawaited(controller.play());
      case false:
        if (controller != null) unawaited(controller.pause());
      case null:
        break;
    }
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
    _webSession?.mainFrameUrl.removeListener(_onWebNav);
    _webSession?.dispose();
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
