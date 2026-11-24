part of '../video_fushi_page.dart';

/// 推挤式侧栏（字幕列表 / 聊天回放栏）里按全局坐标命中的字符：句文本 + 字位 + 起查入口。
/// 查词浮层的 dismiss barrier / 悬停换词 / Shift 查词都经它反查，两种侧栏同一口径
/// （BUG-874 / BUG-879 / BUG-910）。
typedef _SideListHit = ({
  String text,
  int graphemeIndex,
  void Function({bool fromHover}) lookup,
});

/// YouTube 直播回放的聊天回放栏（拍板台 zTedU_pOQF，方案 b）：横屏是画面右侧的推挤式
/// 侧栏（与字幕列表同一套、互斥），竖屏学习版式里是下半屏的「聊天回放」页签。入口是
/// 控制条的「聊天」按钮（[VideoControlItem.liveChat]），只在当前视频有聊天回放时出现。
///
/// 数据源与分页在引擎（`youtube_live_chat_replay.dart`），本页只做接线：换源时探测有没有
/// 聊天回放（[_loadLiveChatForCurrentVideo]），开 / 关侧栏，点词查词。
extension _VideoLiveChat on _VideoFushiPageState {
  /// 当前视频有没有聊天回放（控制条按钮 / 竖屏页签据此出现）。
  bool get _hasLiveChat => _liveChat != null;

  /// 视频就绪（首开 / 换集 / 换源）后调：当前是 YouTube 流就探测聊天回放。同一个视频、
  /// 同一个播放器复用已有会话；换了视频先撤掉旧的（按钮立刻消失），探测到再换上新的。
  Future<void> _loadLiveChatForCurrentVideo() async {
    final int seq = ++_liveChatProbeSeq;
    final VideoPlayerController? controller = _controller;
    final String? watchUrl = _currentYoutubeWatchUrl;
    final String? videoId = watchUrl == null
        ? null
        : youtubeVideoIdOrNull(watchUrl);
    final VideoLiveChatReplay? current = _liveChat;
    if (current != null &&
        videoId != null &&
        current.videoId == videoId &&
        identical(_liveChatController, controller)) {
      return;
    }
    final bool wasOpen = _liveChatVisible.value;
    _replaceLiveChat(null, controller: null);
    if (videoId == null || controller == null) return;
    final String? entry = await fetchYoutubeChatReplayEntry(videoId);
    if (!mounted || seq != _liveChatProbeSeq || entry == null) return;
    if (!identical(_controller, controller)) return;
    _replaceLiveChat(
      VideoLiveChatReplay(
        videoId: videoId,
        entryContinuation: entry,
        position: controller.positionMsListenable,
      ),
      controller: controller,
    );
    if (videoLiveChatOpensOnLoad(
      wasOpen: wasOpen,
      autoOpen: appModel.videoLiveChatAutoOpen,
    )) {
      _openLiveChat();
    }
  }

  /// 换上（或撤掉）聊天回放。撤掉时一并收起侧栏 / 把竖屏页签切回字幕；旧会话等这一帧
  /// 的面板卸载完再释放（面板在卸载时还要从它身上摘监听）。
  void _replaceLiveChat(
    VideoLiveChatReplay? next, {
    required VideoPlayerController? controller,
  }) {
    final VideoLiveChatReplay? old = _liveChat;
    if (old == null && next == null) return;
    _rebuild(() {
      _liveChat = next;
      _liveChatController = controller;
      _liveChatLookupHighlight = null;
    });
    if (next == null) {
      if (_liveChatVisible.value) _liveChatVisible.value = false;
      if (_portraitTab.value == VideoPortraitTab.chat) {
        _portraitTab.value = VideoPortraitTab.subtitles;
      }
    }
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// 控制条「聊天」按钮：开 / 关聊天回放栏。
  void _toggleLiveChat() {
    if (_liveChatVisible.value) {
      _closeLiveChat();
    } else {
      _openLiveChat();
    }
  }

  /// 打开聊天回放栏：竖屏学习版式切到聊天页签；横屏开推挤式侧栏，与字幕列表 / 选集轨道 /
  /// 浮层面板互斥（同一时刻右栏只占其一）。
  void _openLiveChat() {
    if (_liveChat == null) return;
    if (_routeToPortraitPane(VideoPortraitTab.chat)) return;
    _clearRailHover();
    _hideVideoControlEditOverlay(revealControls: false);
    if (_subtitleListVisible.value) _subtitleListVisible.value = false;
    if (_episodeListVisible.value) _closeEpisodeList();
    _liveChatVisible.value = true;
    if (_videoSidePanel.value != null) _hideVideoSidePanel();
    // 与字幕列表同理：聊天栏不领焦点，键盘 / 手柄照常控制画面。
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  /// 关闭聊天回放栏（头部 × / 控制条按钮两条路径的单一出口）。
  void _closeLiveChat() {
    if (!_liveChatVisible.value) return;
    _liveChatVisible.value = false;
    _pokeControlsVisible();
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  /// 点聊天消息里的字查词：查词 / 制卡与字幕列表同一条链路（[_lookupAt]）。制卡音频锚在
  /// 消息发出那一刻正在播的字幕句（聊天是对那一刻的反应）；那一刻没有字幕时回落到播放头
  /// 所在句，与字幕查词的兜底一致。
  void _handleLiveChatLookup(
    YoutubeChatMessage message,
    int graphemeIndex,
    Rect charRect, {
    bool fromHover = false,
  }) {
    if (!_immersiveAllowsLookup) return;
    final VideoPlayerController? controller = _controller;
    if (controller == null || message.text.trim().isEmpty) return;
    _lookupOpenedByHover = fromHover;
    if (!fromHover) _cancelHoverLeaveResume();
    final AudioCue? anchor = resolveMiningCueForPosition(
      cues: controller.miningCues,
      positionMs: message.offsetMs,
      delayMs: controller.miningDelayMs,
    );
    final int spanStart = subtitleLookupSpan(message.text, graphemeIndex).start;
    unawaited(
      _lookupAt(
        message.text,
        graphemeIndex,
        charRect,
        overrideCue: anchor,
      ).then((int count) {
        if (!mounted) return;
        final ({String messageId, int start, int count})? next =
            count > 0 && spanStart >= 0
            ? (messageId: message.id, start: spanStart, count: count)
            : null;
        if (next != _liveChatLookupHighlight) {
          _rebuild(() => _liveChatLookupHighlight = next);
        }
      }),
    );
  }

  /// 聊天栏某条消息上「正在查的词」：只在查词浮层还开着时亮（同字幕高亮
  /// [_activeSubtitleLookupHighlight]）。
  SubtitleTranscriptHighlightRange? _liveChatHighlightFor(
    YoutubeChatMessage message,
  ) {
    final ({String messageId, int start, int count})? h =
        _liveChatLookupHighlight;
    if (h == null || !_hasVisiblePopup || h.messageId != message.id) {
      return null;
    }
    return (start: h.start, count: h.count);
  }

  /// 推挤式侧栏命中（字幕列表优先，再聊天栏）。两种侧栏互斥，同一时刻至多一个挂着。
  _SideListHit? _sideListHitAt(Offset globalPos, {bool exactOnly = false}) {
    final SubtitleListHit? listHit = _subtitleListHitTester.hitTest(
      globalPos,
      exactOnly: exactOnly,
    );
    if (listHit != null) {
      return (
        text: listHit.cue.text,
        graphemeIndex: listHit.graphemeIndex,
        lookup: ({bool fromHover = false}) => _handleSubtitleListLookup(
          listHit.cue,
          listHit.graphemeIndex,
          listHit.anchorRect,
          fromHover: fromHover,
        ),
      );
    }
    final LiveChatHit? chatHit = _liveChatHitTester.hitTest(
      globalPos,
      exactOnly: exactOnly,
    );
    if (chatHit != null) {
      return (
        text: chatHit.message.text,
        graphemeIndex: chatHit.graphemeIndex,
        lookup: ({bool fromHover = false}) => _handleLiveChatLookup(
          chatHit.message,
          chatHit.graphemeIndex,
          chatHit.anchorRect,
          fromHover: fromHover,
        ),
      );
    }
    return null;
  }

  /// 聊天栏面板本体：横屏侧栏与竖屏页签共用（[onClose] 为 null 时不出关闭钮）。
  Widget _buildLiveChatPanel(
    VideoLiveChatReplay chat, {
    required double width,
    required EdgeInsets safeInsets,
    required ColorScheme colorScheme,
    VoidCallback? onClose,
    Key? key,
  }) {
    return VideoLiveChatPanel(
      key: key,
      chat: chat,
      onLookup: _handleLiveChatLookup,
      colorScheme: colorScheme,
      width: width,
      safeAreaInsets: safeInsets,
      showAuthor: _liveChatShowAuthorPref,
      onClose: onClose,
      hitTester: _liveChatHitTester,
      lookupHighlightOf: _liveChatHighlightFor,
      fontSize: (context.fushiType.bodyMedium.fontSize ?? 14) * _videoUiScale,
      fontFamily: appModel.subtitleFontFamily,
    );
  }

  /// 横屏：画面格 + 右侧聊天栏列（与 [_subtitleJumpSidePanel] 同一套推挤几何与光标处理，
  /// 宽度按屏宽自适应）。没有聊天回放时列宽恒 0、[content] 原样铺满。
  Widget _liveChatSidePanel(
    VideoPlayerController controller,
    bool visible,
    Widget content,
  ) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double panelWidth = (screenWidth * 0.28).clamp(240.0, 420.0);
    final EdgeInsets systemPadding = obstructedSafeInsets(
      MediaQuery.paddingOf(context),
      sensorHousingEdge.value,
    );
    final EdgeInsets panelSafeInsets = EdgeInsets.only(
      top: systemPadding.top,
      right: systemPadding.right,
      bottom: systemPadding.bottom,
    );
    final VideoLiveChatReplay? chat = _liveChat;
    return VideoPushAsideRow(
      open: visible && chat != null,
      width: panelWidth + panelSafeInsets.right,
      content: content,
      gapColor: VideoSubtitleJumpPanel.columnSurfaceColor(
        context,
        colorScheme: cs,
      ),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      builder: (BuildContext _) {
        // 收起动画中途会话被撤掉（换到没有聊天回放的视频）：列里只剩底色。
        final VideoLiveChatReplay? live = _liveChat;
        if (live == null) return const SizedBox.shrink();
        return _withSidePanelOpaqueCursor(
          _withSubtitleListCursorReveal(
            _buildLiveChatPanel(
              live,
              key: const ValueKey<String>('video-live-chat-panel'),
              width: panelWidth,
              safeInsets: panelSafeInsets,
              colorScheme: cs,
              onClose: _closeLiveChat,
            ),
          ),
        );
      },
    );
  }

  /// 竖屏学习版式的「聊天回放」页签（有聊天回放才出现）。
  VideoPortraitTabSpec _portraitLiveChatTab(VideoLiveChatReplay chat) {
    return VideoPortraitTabSpec(
      tab: VideoPortraitTab.chat,
      icon: FushiIcons.forum,
      label: t.video_live_chat_title,
      builder: (BuildContext context, EdgeInsets insets) => LayoutBuilder(
        builder: (BuildContext _, BoxConstraints box) => _buildLiveChatPanel(
          chat,
          key: const ValueKey<String>('video-portrait-live-chat-panel'),
          width: box.maxWidth,
          safeInsets: EdgeInsets.only(bottom: insets.bottom),
          colorScheme: _videoChromeColorScheme(context),
        ),
      ),
    );
  }

  /// 偏好仓库通知：「聊天栏显示用户名」变了就重建（设置面板里切换即时生效）。
  void _onLiveChatPrefsChanged() {
    if (!mounted) return;
    final bool value = appModel.videoLiveChatShowAuthor;
    if (value == _liveChatShowAuthorPref) return;
    _rebuild(() => _liveChatShowAuthorPref = value);
  }
}
