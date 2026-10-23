import 'dart:async';
import 'dart:math' as math;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart'
    show lyricsPlayerIsWide;
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/pages/implementations/video_remote/video_remote_control_card.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_favorites_view.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_transcript_view.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiConnectedButtonGroup;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 遥控器页面上的全部操作（纯回调；页面负责网络与确认对话框）。
@immutable
class VideoRemoteCallbacks {
  const VideoRemoteCallbacks({
    required this.onBack,
    required this.onControl,
    required this.onLookup,
    required this.onFavoritesScopeChanged,
    required this.onOpenFavorite,
    required this.onRemoveFavorites,
    required this.onRefresh,
    this.onSeek,
    this.onLineTap,
    this.onReplayLine,
    this.onToggleFavoriteLine,
    this.onMineLine,
    this.onLookupFavorite,
    this.onCustomizeControls,
    this.onPickVideo,
    this.onCloseVideo,
  });

  /// 返回（退出遥控）。
  final VoidCallback onBack;

  /// 控制按钮。`followCurrent` 由脚手架自己处理（回到当前句），不会转发。
  final ValueChanged<VideoRemoteControlItem> onControl;

  /// 字幕里点字查词：行下标 + 字下标（grapheme）+ 被点词的全局锚点矩形。
  final VideoRemoteLookupCallback onLookup;

  final ValueChanged<VideoRemoteFavoritesScope> onFavoritesScopeChanged;
  final ValueChanged<VideoRemoteFavoriteEntry> onOpenFavorite;
  final ValueChanged<Set<String>> onRemoveFavorites;

  /// ⋯ 菜单里的「刷新」。
  final VoidCallback onRefresh;

  /// 拖动进度条跳转；null = 进度只显示。
  final ValueChanged<Duration>? onSeek;

  /// 点字幕行内文字以外的地方（通常 = 跳到这句）。
  final ValueChanged<int>? onLineTap;

  /// 长按字幕行面板里的动作；null 的动作不显示。
  final ValueChanged<int>? onReplayLine;
  final ValueChanged<int>? onToggleFavoriteLine;
  final ValueChanged<int>? onMineLine;

  /// 收藏卡里点字查词（带被点词的全局锚点矩形）；null = 收藏句子不逐字可点。
  final VideoRemoteFavoriteLookupCallback? onLookupFavorite;

  /// ⋯ 菜单里的「自定义按钮」（通常 `showVideoRemoteControlEditor`）；null =
  /// 不显示该项。
  final VoidCallback? onCustomizeControls;

  /// 顶栏「点播」：从电脑视频库里选片让电脑播放；null = 电脑不支持（旧版），
  /// 不显示该按钮。
  final VoidCallback? onPickVideo;

  /// 顶栏「关闭视频」：让电脑关掉正在放的视频；null = 电脑没开视频或不支持，
  /// 不显示该按钮。
  final VoidCallback? onCloseVideo;
}

/// 手机字幕遥控器的整页脚手架（纯展示）。
///
/// 布局按 [lyricsPlayerIsWide]（宽 ≥600 且横向）切换：
///  * 竖屏：浮动顶栏（返回 / 作品名·集数 / [字幕|收藏] / ⋯ 自定义按钮·刷新，
///    `adaptiveOverflow` 宽度不够才收进 ⋯）+ 中间列表 + 底部浮动控制卡；
///  * 横屏 / 平板：左栏信息 + 控制卡，右栏顶栏 + [字幕|收藏] 列表。
/// 背景是封面取色的 mesh（Apple 设计系统用平底）。
///
/// 列表区是三页横排的 [PageView]：「字幕」「收藏·当前视频」「收藏·全部视频」，
/// 左右滑动切换（竖横屏都有）。滑动与按钮双向同步：页签按钮 / 收藏范围按钮切了，
/// 页面跟着滑过去（M3E spatial 弹簧，动效关闭时瞬切）；滑停在某页，页签与范围
/// 跟着变（范围变化走 [VideoRemoteCallbacks.onFavoritesScopeChanged]，页签变化走
/// [onTabChanged]）。[pageSwipeEnabled] 为 false（查词弹框开着）时不响应横滑。
///
/// 状态归属：
///  * 当前页签由本组件持有（初值 [initialTab]，变化回调 [onTabChanged]）；
///  * 字幕列表与收藏列表的滚动位置、搜索词、多选挂在本组件持有的 GlobalKey 上，
///    竖横屏切换时子树整体搬家，状态不丢；
///  * 跟随状态在 [transcriptController]（不传则本组件自建一个）。
/// 只要调用方在旋转时不换掉本组件（同一个 State），以上状态都保留。
class VideoRemoteScaffold extends StatefulWidget {
  const VideoRemoteScaffold({
    super.key,
    required this.nowPlaying,
    required this.lines,
    required this.activeIndex,
    required this.favorites,
    required this.favoritesScope,
    required this.controlLayout,
    required this.callbacks,
    this.clock,
    this.notice,
    this.favoritesLoading = false,
    this.initialTab = VideoRemoteTab.transcript,
    this.onTabChanged,
    this.transcriptController,
    this.isControlEnabled,
    this.transcriptReplayKey,
    this.lineTextStyle,
    this.animateBackdrop = false,
    this.lookupHighlight,
    this.pageSwipeEnabled = true,
  });

  final VideoRemoteNowPlaying nowPlaying;
  final List<VideoRemoteTranscriptLine> lines;
  final int activeIndex;
  final List<VideoRemoteFavoriteEntry> favorites;
  final VideoRemoteFavoritesScope favoritesScope;
  final VideoRemoteControlLayout controlLayout;
  final VideoRemoteCallbacks callbacks;

  /// 进度读口；null = 不显示进度条。
  final FushiPlaybackClock? clock;

  /// 内联状态卡（等待 / 出错 / 断线）；null = 不显示。
  final VideoRemoteNotice? notice;

  final bool favoritesLoading;
  final VideoRemoteTab initialTab;
  final ValueChanged<VideoRemoteTab>? onTabChanged;
  final VideoRemoteTranscriptController? transcriptController;
  final bool Function(VideoRemoteControlItem item)? isControlEnabled;

  /// 变化时字幕列表重开错峰进场（换视频 / 换字幕版本）。
  final Object? transcriptReplayKey;

  /// 字幕正文基准样式；null = 主题 titleLarge。
  final TextStyle? lineTextStyle;

  /// 背景 mesh 是否流动。默认静止：遥控页常亮、长时间开着，背景逐帧重画是
  /// 白白耗电发热（spec「没有动态背景」）。
  final bool animateBackdrop;

  /// 当前查词弹框正在查的词：画在它所属的字幕行 / 收藏卡上；null = 不高亮。
  final VideoRemoteLookupHighlight? lookupHighlight;

  /// 列表区能否左右滑动切页。查词弹框开着时调用方传 false，避免和弹框的横滑
  /// 关闭、逐字点击抢手势。
  final bool pageSwipeEnabled;

  @override
  State<VideoRemoteScaffold> createState() => _VideoRemoteScaffoldState();
}

class _VideoRemoteScaffoldState extends State<VideoRemoteScaffold> {
  final GlobalKey _transcriptKey = GlobalKey(
    debugLabel: 'video-remote-transcript',
  );
  final GlobalKey _favoritesCurrentKey = GlobalKey(
    debugLabel: 'video-remote-favorites-current',
  );
  final GlobalKey _favoritesAllKey = GlobalKey(
    debugLabel: 'video-remote-favorites-all',
  );

  /// 三页横排的 PageView 整体挂这个 key：竖横屏切换时整棵（含保活的离屏页）
  /// 搬家，各页滚动位置 / 搜索词不丢。
  final GlobalKey _pagesKey = GlobalKey(debugLabel: 'video-remote-pages');
  late VideoRemoteTab _tab = widget.initialTab;
  late final PageController _pages = PageController(
    initialPage: videoRemotePageIndex(_tab, widget.favoritesScope),
  );
  VideoRemoteTranscriptController? _ownController;
  VideoRemoteNotice? _lastNotice;

  ImageProvider? _schemeSource;
  Brightness? _schemeBrightness;
  int _schemeRequest = 0;
  ColorScheme? _coverScheme;
  ThemeData? _themedBase;
  ColorScheme? _themedScheme;
  ThemeData? _themed;

  VideoRemoteTranscriptController get _controller =>
      widget.transcriptController ??
      (_ownController ??= VideoRemoteTranscriptController());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveCoverScheme();
  }

  @override
  void didUpdateWidget(covariant VideoRemoteScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nowPlaying.cover != widget.nowPlaying.cover) {
      _resolveCoverScheme();
    }
    // 收藏范围按钮（或调用方）换了范围：停在收藏页时滑到对应那一页。
    if (oldWidget.favoritesScope != widget.favoritesScope &&
        _tab == VideoRemoteTab.favorites) {
      _goToPage(videoRemotePageIndex(_tab, widget.favoritesScope));
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _ownController?.dispose();
    super.dispose();
  }

  /// 封面取色（MD3）：异步取到前先用应用主题。与歌词模式同一做法。
  void _resolveCoverScheme() {
    if (isGlassDesign(context)) return;
    final ImageProvider? cover = widget.nowPlaying.cover;
    final Brightness brightness = Theme.of(context).brightness;
    if (cover == _schemeSource && brightness == _schemeBrightness) return;
    _schemeSource = cover;
    _schemeBrightness = brightness;
    final int request = ++_schemeRequest;
    if (cover == null) {
      if (_coverScheme != null) setState(() => _coverScheme = null);
      return;
    }
    ColorScheme.fromImageProvider(provider: cover, brightness: brightness)
        .then((ColorScheme scheme) {
          if (!mounted || request != _schemeRequest) return;
          setState(() => _coverScheme = scheme);
        })
        .catchError((Object _) {
          // 封面解码失败：保留应用主题配色，不是错误。
        });
  }

  ThemeData _themeFor(ThemeData base) {
    final ColorScheme? scheme = _coverScheme;
    if (scheme == null || isGlassDesign(context)) return base;
    final ThemeData? cached = _themed;
    if (cached != null &&
        identical(base, _themedBase) &&
        identical(scheme, _themedScheme)) {
      return cached;
    }
    _themedBase = base;
    _themedScheme = scheme;
    return _themed = rethemeFushiWithScheme(base, scheme);
  }

  void _setTab(VideoRemoteTab tab) {
    if (tab == _tab) return;
    fushiSelectionHaptic(context);
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
    _goToPage(videoRemotePageIndex(tab, widget.favoritesScope));
  }

  /// 按钮侧切页：滑到第 [page] 页（M3E spatial 弹簧；动效关闭时瞬切）。
  void _goToPage(int page) {
    if (!_pages.hasClients || _pages.positions.length != 1) return;
    final double? current = _pages.page;
    if (current != null && (current - page).abs() < 0.001) return;
    final FushiSpringSpec spring = context.fushiMotion.spatialDefault;
    if (!spring.enabled || spring.duration == Duration.zero) {
      _pages.jumpToPage(page);
      return;
    }
    unawaited(
      _pages.animateToPage(
        page,
        duration: spring.duration,
        curve: spring.curve,
      ),
    );
  }

  /// 滑动侧切页：滑停后把页签与收藏范围同步成这一页（按钮驱动的动画停下时
  /// 两者本就一致，这里是 no-op）。
  bool _onPagesScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification is! ScrollEndNotification ||
        notification.metrics is! PageMetrics) {
      return false;
    }
    final double? page = (notification.metrics as PageMetrics).page;
    if (page == null) return false;
    final int index = page.round().clamp(0, 2);
    final VideoRemoteTab tab = index == 0
        ? VideoRemoteTab.transcript
        : VideoRemoteTab.favorites;
    if (tab == VideoRemoteTab.favorites) {
      final VideoRemoteFavoritesScope scope = index == 2
          ? VideoRemoteFavoritesScope.allVideos
          : VideoRemoteFavoritesScope.currentVideo;
      if (scope != widget.favoritesScope) {
        widget.callbacks.onFavoritesScopeChanged(scope);
      }
    }
    if (tab != _tab) {
      fushiSelectionHaptic(context);
      setState(() => _tab = tab);
      widget.onTabChanged?.call(tab);
    }
    return false;
  }

  void _onControl(VideoRemoteControlItem item) {
    // 遥控器按键：每按一下都轻震确认（眼睛多半在电脑屏幕上）。
    fushiRemoteActionHaptic(context);
    if (item == VideoRemoteControlItem.followCurrent) {
      _setTab(VideoRemoteTab.transcript);
      _controller.returnToCurrent();
      return;
    }
    widget.callbacks.onControl(item);
  }

  // -------------------------------------------------------------------------
  // 组件
  // -------------------------------------------------------------------------

  Widget _topBar({required bool withTitle}) {
    final VideoRemoteCallbacks callbacks = widget.callbacks;
    final VoidCallback? customize = callbacks.onCustomizeControls;
    final VoidCallback? pickVideo = callbacks.onPickVideo;
    final VoidCallback? closeVideo = callbacks.onCloseVideo;
    final List<FushiToolbarItem> pickGroup = <FushiToolbarItem>[
      if (pickVideo != null)
        FushiToolbarItem(
          key: const ValueKey<String>('video-remote-pick-video'),
          icon: FushiIcons.video,
          label: t.video_remote_library_title,
          onPressed: pickVideo,
        ),
      if (closeVideo != null)
        FushiToolbarItem(
          key: const ValueKey<String>('video-remote-close-video'),
          icon: FushiIcons.stop,
          label: t.video_remote_close_video,
          onPressed: closeVideo,
        ),
    ];
    return FushiFloatingTopBar(
      key: const ValueKey<String>('video-remote-top-bar'),
      leading: <FushiToolbarItem>[
        FushiToolbarItem(
          key: const ValueKey<String>('video-remote-back'),
          icon: FushiIcons.back,
          label: t.back,
          onPressed: callbacks.onBack,
        ),
      ],
      title: withTitle
          ? (widget.nowPlaying.titleWithEpisode.isEmpty
                ? t.video_remote_title
                : widget.nowPlaying.titleWithEpisode)
          : '',
      subtitle: withTitle ? (widget.nowPlaying.hostName ?? '') : '',
      // 竖屏有标题胶囊（保底 160 宽），手机宽度放不下两个页签键，会被收进
      // ⋯——页签改由顶栏下方的连接式按钮组承担（[_tabSwitch]）；横屏顶栏没有
      // 标题，页签就在顶栏里。
      actions: withTitle
          ? <List<FushiToolbarItem>>[if (pickGroup.isNotEmpty) pickGroup]
          : <List<FushiToolbarItem>>[
              if (pickGroup.isNotEmpty) pickGroup,
              <FushiToolbarItem>[
                FushiToolbarItem(
                  key: const ValueKey<String>('video-remote-tab-transcript'),
                  icon: FushiIcons.subtitles,
                  label: t.video_remote_subtitles,
                  selected: _tab == VideoRemoteTab.transcript,
                  onPressed: () => _setTab(VideoRemoteTab.transcript),
                ),
                FushiToolbarItem(
                  key: const ValueKey<String>('video-remote-tab-favorites'),
                  icon: FushiIcons.star,
                  label: t.video_remote_favorites,
                  selected: _tab == VideoRemoteTab.favorites,
                  onPressed: () => _setTab(VideoRemoteTab.favorites),
                ),
              ],
            ],
      overflow: <FushiToolbarItem>[
        if (customize != null)
          FushiToolbarItem(
            key: const ValueKey<String>('video-remote-customize'),
            icon: FushiIcons.dashboardCustomize,
            label: t.video_remote_control_customize,
            onPressed: customize,
          ),
        FushiToolbarItem(
          key: const ValueKey<String>('video-remote-refresh'),
          icon: FushiIcons.refresh,
          label: t.refresh,
          onPressed: callbacks.onRefresh,
        ),
      ],
    );
  }

  /// 竖屏页签：[字幕|收藏] 连接式按钮组（选中段弹成胶囊）。
  Widget _tabSwitch() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: FushiConnectedButtonGroup<VideoRemoteTab>(
      key: const ValueKey<String>('video-remote-tab-switch'),
      expandedInsets: EdgeInsets.zero,
      selected: <VideoRemoteTab>{_tab},
      onSelectionChanged: (Set<VideoRemoteTab> next) {
        if (next.isNotEmpty) _setTab(next.first);
      },
      segments: <ButtonSegment<VideoRemoteTab>>[
        ButtonSegment<VideoRemoteTab>(
          value: VideoRemoteTab.transcript,
          icon: const FushiIcon(FushiIcons.subtitles),
          label: Text(t.video_remote_subtitles),
        ),
        ButtonSegment<VideoRemoteTab>(
          value: VideoRemoteTab.favorites,
          icon: const FushiIcon(FushiIcons.star),
          label: Text(t.video_remote_favorites),
        ),
      ],
    ),
  );

  Widget _transcript() => VideoRemoteTranscriptView(
    key: _transcriptKey,
    lines: widget.lines,
    activeIndex: widget.activeIndex,
    controller: _controller,
    onLookup: widget.callbacks.onLookup,
    onLineTap: widget.callbacks.onLineTap,
    onReplayLine: widget.callbacks.onReplayLine,
    onToggleFavoriteLine: widget.callbacks.onToggleFavoriteLine,
    onMineLine: widget.callbacks.onMineLine,
    textStyle: widget.lineTextStyle,
    entranceReplayKey: widget.transcriptReplayKey,
    lookupHighlight: widget.lookupHighlight,
  );

  /// 收藏的一页（当前视频 / 全部视频各一页）。调用方一次只取当前范围那一批：
  /// 另一页在滑过去、范围回调取回新一批之前显示加载中，不拿别的范围的条目冒充。
  Widget _favorites(VideoRemoteFavoritesScope scope) {
    final bool active = scope == widget.favoritesScope;
    return VideoRemoteFavoritesView(
      key: scope == VideoRemoteFavoritesScope.allVideos
          ? _favoritesAllKey
          : _favoritesCurrentKey,
      entries: active ? widget.favorites : const <VideoRemoteFavoriteEntry>[],
      scope: scope,
      onOpen: widget.callbacks.onOpenFavorite,
      onRemove: widget.callbacks.onRemoveFavorites,
      onLookup: widget.callbacks.onLookupFavorite,
      loading: !active || widget.favoritesLoading,
      lookupHighlight: widget.lookupHighlight,
    );
  }

  /// 翻页的实时位置（0 = 字幕，1 = 收藏·当前视频，2 = 收藏·全部视频）；还没
  /// 挂上时按当前页签与范围推算。
  double get _pagePosition {
    if (_pages.hasClients && _pages.positions.length == 1) {
      final double? page = _pages.page;
      if (page != null) return page;
    }
    return videoRemotePageIndex(_tab, widget.favoritesScope).toDouble();
  }

  /// 收藏范围选择器：固定在翻页之上，不随页滑动（用户 2026-10-13：滑的是
  /// 选择器下面的内容，不是选择器本身）。从字幕页滑向收藏时跟着手指展开、
  /// 淡入；两个收藏页之间滑动时只有选中段跟着手指切换。
  Widget _scopeSelector() {
    return ListenableBuilder(
      listenable: _pages,
      builder: (BuildContext context, Widget? _) {
        final double page = _pagePosition;
        final double reveal = page.clamp(0.0, 1.0);
        final VideoRemoteFavoritesScope shown = page >= 1.5
            ? VideoRemoteFavoritesScope.allVideos
            : VideoRemoteFavoritesScope.currentVideo;
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: reveal,
            child: Opacity(
              opacity: reveal,
              child: IgnorePointer(
                ignoring: reveal < 1,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: FushiConnectedButtonGroup<VideoRemoteFavoritesScope>(
                    key: const ValueKey<String>('video-remote-favorites-scope'),
                    expandedInsets: EdgeInsets.zero,
                    selected: <VideoRemoteFavoritesScope>{shown},
                    onSelectionChanged: (Set<VideoRemoteFavoritesScope> next) {
                      if (next.isEmpty || next.first == widget.favoritesScope) {
                        return;
                      }
                      fushiSelectionHaptic(context);
                      widget.callbacks.onFavoritesScopeChanged(next.first);
                    },
                    segments: <ButtonSegment<VideoRemoteFavoritesScope>>[
                      ButtonSegment<VideoRemoteFavoritesScope>(
                        value: VideoRemoteFavoritesScope.currentVideo,
                        label: Text(t.video_remote_favorites_scope_current),
                      ),
                      ButtonSegment<VideoRemoteFavoritesScope>(
                        value: VideoRemoteFavoritesScope.allVideos,
                        label: Text(t.video_remote_all),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 三页横排（字幕 / 收藏·当前视频 / 收藏·全部视频），都保活：离屏页不画、
  /// 不吃指针，但滚动位置与搜索词都在。收藏范围选择器固定在翻页之上
  /// （[_scopeSelector]），只有它下面的内容随页滑动。
  Widget _tabBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _scopeSelector(),
        Expanded(child: _pagesView()),
      ],
    );
  }

  Widget _pagesView() {
    return NotificationListener<ScrollNotification>(
      onNotification: _onPagesScroll,
      child: PageView(
        key: _pagesKey,
        controller: _pages,
        physics: widget.pageSwipeEnabled
            ? const PageScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        children: <Widget>[
          _VideoRemoteKeepAlive(
            key: const ValueKey<String>('video-remote-page-transcript'),
            child: _transcript(),
          ),
          _VideoRemoteKeepAlive(
            key: const ValueKey<String>('video-remote-page-favorites-current'),
            child: _favorites(VideoRemoteFavoritesScope.currentVideo),
          ),
          _VideoRemoteKeepAlive(
            key: const ValueKey<String>('video-remote-page-favorites-all'),
            child: _favorites(VideoRemoteFavoritesScope.allVideos),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard() {
    final VideoRemoteNotice? notice = widget.notice ?? _lastNotice;
    if (widget.notice != null) _lastNotice = widget.notice;
    return FushiChromeReveal(
      visible: widget.notice != null,
      from: AxisDirection.up,
      child: notice == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FushiInlineNotice(
                key: const ValueKey<String>('video-remote-notice'),
                message: notice.message,
                severity: switch (notice.kind) {
                  VideoRemoteNoticeKind.waiting => FushiNoticeSeverity.info,
                  VideoRemoteNoticeKind.error => FushiNoticeSeverity.error,
                  VideoRemoteNoticeKind.disconnected =>
                    FushiNoticeSeverity.warning,
                },
                icon: switch (notice.kind) {
                  VideoRemoteNoticeKind.waiting => FushiIcons.pending,
                  VideoRemoteNoticeKind.error => FushiIcons.error,
                  VideoRemoteNoticeKind.disconnected => FushiIcons.cloudOff,
                },
                actions: <Widget>[
                  if (notice.actionLabel != null && notice.onAction != null)
                    FushiTextButton(
                      onPressed: notice.onAction,
                      child: Text(notice.actionLabel!),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _controlCard(VideoRemoteControlCardVariant variant) =>
      ListenableBuilder(
        listenable: _controller,
        builder: (BuildContext context, Widget? _) => VideoRemoteControlCard(
          key: const ValueKey<String>('video-remote-control-card'),
          variant: variant,
          layout: widget.controlLayout,
          nowPlaying: widget.nowPlaying,
          clock: widget.clock,
          onSeek: widget.callbacks.onSeek,
          following: _controller.following,
          isEnabled: widget.isControlEnabled,
          onControl: _onControl,
        ),
      );

  // -------------------------------------------------------------------------
  // 布局
  // -------------------------------------------------------------------------

  Widget _portrait(EdgeInsets safe) {
    return Padding(
      padding: EdgeInsets.only(
        top: safe.top + 8,
        bottom: safe.bottom + 12,
        left: safe.left,
        right: safe.right,
      ),
      child: Column(
        key: const ValueKey<String>('video-remote-portrait'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _topBar(withTitle: true),
            ),
          ),
          FushiStaggeredEntrance(index: 1, child: _tabSwitch()),
          _noticeCard(),
          Expanded(child: FushiStaggeredEntrance(index: 1, child: _tabBody())),
          FushiStaggeredEntrance(
            index: 3,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: _controlCard(VideoRemoteControlCardVariant.floating),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wide(Size size, EdgeInsets safe) {
    final double hPad = (size.width * 0.03).clamp(16.0, 40.0);
    final double content = math.max(1, size.width - safe.horizontal - 2 * hPad);
    final double panel = (content * 0.36).clamp(
      math.min(300.0, content * 0.5),
      math.min(440.0, content * 0.5),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        safe.left + hPad,
        safe.top + 16,
        safe.right + hPad,
        safe.bottom + 16,
      ),
      child: Row(
        key: const ValueKey<String>('video-remote-wide'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: panel,
            child: FushiStaggeredEntrance(
              index: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: _controlCard(VideoRemoteControlCardVariant.panel),
              ),
            ),
          ),
          SizedBox(width: (content * 0.03).clamp(16.0, 40.0)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiStaggeredEntrance(
                  index: 1,
                  child: _topBar(withTitle: false),
                ),
                _noticeCard(),
                Expanded(
                  child: FushiStaggeredEntrance(index: 2, child: _tabBody()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData themed = _themeFor(Theme.of(context));
    return Theme(
      data: themed,
      child: Builder(
        builder: (BuildContext context) {
          final bool glass = isGlassDesign(context);
          return Material(
            type: MaterialType.transparency,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Size size = constraints.biggest;
                final EdgeInsets safe = MediaQuery.paddingOf(context);
                final bool wide = lyricsPlayerIsWide(size);
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (glass)
                      ColoredBox(color: Theme.of(context).colorScheme.surface)
                    else
                      FushiMeshBackdrop(animate: widget.animateBackdrop),
                    FushiEntranceScope(
                      child: wide ? _wide(size, safe) : _portrait(safe),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// 列表区第几页：0 = 字幕，1 = 收藏·当前视频，2 = 收藏·全部视频（纯函数，测试用）。
int videoRemotePageIndex(VideoRemoteTab tab, VideoRemoteFavoritesScope scope) =>
    switch (tab) {
      VideoRemoteTab.transcript => 0,
      VideoRemoteTab.favorites =>
        scope == VideoRemoteFavoritesScope.allVideos ? 2 : 1,
    };

/// PageView 的一页保活（离屏也不销毁，滚动位置 / 搜索词 / 多选都在）。
class _VideoRemoteKeepAlive extends StatefulWidget {
  const _VideoRemoteKeepAlive({super.key, required this.child});

  final Widget child;

  @override
  State<_VideoRemoteKeepAlive> createState() => _VideoRemoteKeepAliveState();
}

class _VideoRemoteKeepAliveState extends State<_VideoRemoteKeepAlive>
    with AutomaticKeepAliveClientMixin<_VideoRemoteKeepAlive> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
