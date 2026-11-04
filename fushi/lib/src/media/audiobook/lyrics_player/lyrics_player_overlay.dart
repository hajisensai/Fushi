import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/media/playback_route_marks.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion, fushiMotionDuration;
import 'package:fushi/src/utils/misc/fushi_toast.dart'
    show FushiToast, FushiToastCornerAnchor;

/// 新版宽屏播放中：鼠标指针静止多久后隐藏。
const Duration kLyricsCursorIdleHideDelay = Duration(seconds: 3);

/// 歌词播放覆盖层外壳：盖在阅读器之上，阅读器在下面照常存活、跟随音频、记统计
/// （见 [LyricsPlayerData] 文件头）。本组件只负责：
///  * 按设计系统选外观（[isGlassDesign] → Apple，否则 MD3）；
///  * MD3 下从封面取动态配色（[ColorScheme.fromImageProvider]），整棵子树换上它；
///  * 把歌词 WebView 放进外观给出的矩形——**它在 Stack 里的位置恒定**（第 2 个
///    孩子），宽窄布局切换 / 旋转只改矩形，不重建平台视图；
///  * 外观算出的歌词 HTML 主题变化时回调 [onHtmlThemeChanged]，由页面热更 CSS；
///  * 新版（MD3 / Apple 两套设计系统）宽屏播放中，鼠标指针静止
///    [kLyricsCursorIdleHideDelay] 后隐藏（不论停在哪），一动就回来。只动光标：
///    底栏常驻（用户 2026-11-04「底部控制栏做成常驻不要收起」），歌词矩形恒定。
class ReaderLyricsPlayerOverlay extends StatefulWidget {
  const ReaderLyricsPlayerOverlay({
    super.key,
    required this.lyricsView,
    required this.data,
    required this.callbacks,
    required this.onHtmlThemeChanged,
  });

  /// 歌词 WebView（透明底）。
  final Widget lyricsView;

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 歌词文档主题（颜色 / 对齐 / 透明度阶梯）变化。首帧也会回调一次。
  final ValueChanged<LyricsHtmlTheme> onHtmlThemeChanged;

  @override
  State<ReaderLyricsPlayerOverlay> createState() =>
      _ReaderLyricsPlayerOverlayState();
}

class _ReaderLyricsPlayerOverlayState extends State<ReaderLyricsPlayerOverlay> {
  ColorScheme? _coverScheme;
  ImageProvider? _schemeSource;
  Brightness? _schemeBrightness;
  int _schemeRequest = 0;
  LyricsHtmlTheme? _lastReportedTheme;

  /// 上一帧布局是否新版宽屏（光标空闲隐藏只在这时生效）。build 里随布局更新。
  bool _wide = false;

  /// 鼠标指针已隐藏（空闲）。
  bool _cursorHidden = false;
  Timer? _cursorTimer;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCursor());
    _mineToastAnchor = FushiToast.anchorMineToCorner(_lyricsRegionGlobal);
  }

  /// 光标复位并按当前条件重排（或撤掉）空闲隐藏计时。
  void _syncCursor() {
    if (!mounted) return;
    _cursorTimer?.cancel();
    _cursorTimer = null;
    if (_cursorHidden) setState(() => _cursorHidden = false);
    if (!_cursorAutoHideEnabled) return;
    _cursorTimer = Timer(kLyricsCursorIdleHideDelay, () {
      _cursorTimer = null;
      if (!mounted || !_cursorAutoHideEnabled) return;
      setState(() => _cursorHidden = true);
    });
  }

  /// 只有新版布局（MD3 / Apple）宽屏播放中才隐藏空闲光标（经典 / 暂停 / 窄屏一律
  /// 常显）；无障碍导航（读屏）开着时也常显。播放态取「有效播放态」
  /// （[LyricsPlayerData.playbackActive]）：查词时的临时暂停不算暂停。
  bool get _cursorAutoHideEnabled =>
      mounted &&
      widget.data.playbackActive &&
      widget.data.controlsStyle == LyricsControlsStyle.modern &&
      _wide &&
      !MediaQuery.accessibleNavigationOf(context);

  /// 上次依赖变化时的读屏开关：开关切换时重排光标计时（并立即复位光标）。
  bool? _accessibleNavigationWas;

  void _onGlobalPointer(PointerEvent event) {
    if (!mounted) return;
    if (event is PointerHoverEvent ||
        event is PointerDownEvent ||
        event is PointerMoveEvent) {
      _syncCursor();
    }
  }

  /// 页面外的歌词主题宿主（路由 builder 包的那层）：登记后整页弹出层（菜单 /
  /// 侧栏 / 对话框 / 查词浮层）一起换成歌词模式配色。
  LyricsThemeHostState? _host;

  /// 歌词 WebView 的矩形（本组件坐标，即外观给的歌词矩形），每次布局刷新；
  /// 制卡结果卡贴它的底部起始角（见 [FushiToast.anchorMineToCorner]）。
  Rect? _lyricsRect;

  /// 本页当前是否在屏上可见：上面压了不透明路由（歌词模式上再推一个页面）时
  /// Overlay 把本页设为 offstage、[TickerMode] 关掉。此时不能再把制卡结果贴到
  /// 一块看不见的区域角上，[_lyricsRegionGlobal] 返回 null、退回默认大卡。
  /// 半透明弹层（查词浮层 / 对话框）不关 TickerMode，歌词仍在底下可见，照常贴角。
  bool _onstage = true;

  /// 歌词模式期间制卡结果改成角落小卡：正文铺满全屏，底部正中的大卡正好压在
  /// 正文上（群反馈 2026-11-01「字卡提示好大，还挡正文」）。
  late final FushiToastCornerAnchor _mineToastAnchor;

  Rect? _lyricsRegionGlobal() {
    final Rect? rect = _lyricsRect;
    if (!mounted || rect == null || !_onstage) return null;
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(rect.topLeft) & rect.size;
  }

  /// 有声书播放页（歌词模式）开着时，把所在路由（阅读器页）登记成「播放页」：底下的
  /// 浏览页据此让网页别跟着播（BUG-4084）。登记跟着覆盖层走——只在歌词模式挂着，
  /// 退回正文阅读就撤，纯读书不算盖住浏览器的播放页。
  final PlaybackRouteMark _playbackRouteMark = PlaybackRouteMark();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playbackRouteMark.attach(ModalRoute.of(context));
    final bool accessibleNavigation = MediaQuery.accessibleNavigationOf(
      context,
    );
    if (_accessibleNavigationWas != null &&
        accessibleNavigation != _accessibleNavigationWas) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncCursor());
    }
    _accessibleNavigationWas = accessibleNavigation;
    final LyricsThemeHostState? host = LyricsThemeHost.maybeOf(context);
    if (!identical(host, _host)) {
      _host?.detach(this);
      _host = host;
    }
    _resolveCoverScheme();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _cursorTimer?.cancel();
    _mineToastAnchor.release();
    _host?.detach(this);
    _playbackRouteMark.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReaderLyricsPlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.cover != widget.data.cover) _resolveCoverScheme();
    if (oldWidget.data.playbackActive != widget.data.playbackActive ||
        oldWidget.data.controlsStyle != widget.data.controlsStyle) {
      // 播放态变化本身算一次活动：刚按下播放不该立刻藏光标。查词的临时暂停 / 恢复
      // 不改有效播放态，不算活动。
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncCursor());
    }
  }

  /// 封面的「动态取色」（与系统壁纸取色同一算法）。MD3：整棵子树换上这套配色；
  /// Apple：底色就是模糊封面本身，取色只用来定顶边与桌面标题栏接缝的底色（恒深色，
  /// Apple Music 歌词页恒为深底）。异步取色期间先用应用主题，取到后换色。
  void _resolveCoverScheme() {
    final ImageProvider? cover = widget.data.cover;
    final Brightness brightness = isGlassDesign(context)
        ? Brightness.dark
        : Theme.of(context).brightness;
    // ImageProvider 按值比较（FileImage 比路径），每次重建新建的同一封面不重取色。
    if (cover == _schemeSource && brightness == _schemeBrightness) {
      return;
    }
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

  void _reportHtmlTheme(LyricsHtmlTheme theme) {
    if (theme == _lastReportedTheme) return;
    _lastReportedTheme = theme;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_lastReportedTheme, theme)) return;
      widget.onHtmlThemeChanged(theme);
    });
  }

  ThemeData? _themedBase;
  ColorScheme? _themedScheme;
  ThemeData? _themed;

  /// [rethemeFushiWithScheme] 的结果按 (base, scheme) 缓存：覆盖层随播放器每次
  /// 通知都重建，组件主题不必每帧重算。
  ThemeData _themeFor(ThemeData base, ColorScheme scheme) {
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

  @override
  Widget build(BuildContext context) {
    // 建立对 TickerMode 的依赖：被不透明路由盖住 / 揭开时重建并刷新可见性。
    _onstage = TickerMode.valuesOf(context).enabled;
    _host?.attach(this, _coverScheme);
    final bool apple = isGlassDesign(context);
    // 左右互换带换位动画：进度 0↔1 按 M3E 时长补间，外观按进度插值两端几何，
    // 歌词 WebView / 底板 / 面板一起滑到对侧（WebView 仍是同一个孩子，只换矩形）。
    // 墨水屏与系统「减弱动态效果」下 fushiMotionDuration 归零 = 直接跳到终值。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: widget.data.sidesMirrored ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      builder: (BuildContext context, double mirror, Widget? _) =>
          _buildWithMirror(context, apple: apple, mirror: mirror),
    );
  }

  /// 记下这次布局是否新版宽屏（只读几何，不触发重建）。宽窄变了重排光标计时。
  void _updateCursorHideScope(LyricsPlayerDesign design, Size size) {
    final bool wide =
        (design is Md3ModernLyricsPlayerDesign ||
            design is AppleModernLyricsPlayerDesign) &&
        lyricsPlayerIsWide(size);
    if (wide != _wide) {
      _wide = wide;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncCursor());
    }
  }

  Widget _buildWithMirror(
    BuildContext context, {
    required bool apple,
    required double mirror,
  }) {
    // 两套设计系统都按偏好选新版 / 经典布局（`lyrics_controls_style`）。
    final bool classic =
        widget.data.controlsStyle == LyricsControlsStyle.classic;
    final LyricsPlayerDesign design = apple
        ? classic
              ? AppleLyricsPlayerDesign(mirrorProgress: mirror)
              : AppleModernLyricsPlayerDesign(
                  compactExpanded: widget.data.compactControlsExpanded,
                )
        : classic
        ? Md3LyricsPlayerDesign(mirrorProgress: mirror)
        : Md3ModernLyricsPlayerDesign(
            compactExpanded: widget.data.compactControlsExpanded,
          );
    final ThemeData base = Theme.of(context);
    final ColorScheme? coverScheme = apple ? null : _coverScheme;
    // 顶边底色：桌面自绘标题栏在 Navigator 外，只认页面上报的颜色。它只是兜底
    // （背景尚未画出的一帧）；真正铺在标题栏里的是同一张背景的最上面一截。
    //  * MD3：动态取色后的 surface（背景的渐变团是叠在 surface 上的）；
    //  * Apple：封面深色方案里的 surfaceContainerHigh（带封面色相的深灰）；无
    //    封面时退回 iOS 深色分组底。
    // 前景（窗口按钮）：MD3 用 onSurface，Apple 歌词页恒深底用白。
    final ColorScheme scheme = coverScheme ?? base.colorScheme;
    final Color topEdge = apple
        ? (_coverScheme?.surfaceContainerHigh ?? const Color(0xFF1C1C1E))
        : scheme.surface;
    final Color topEdgeForeground = apple ? Colors.white : scheme.onSurface;
    final ThemeData themed = coverScheme == null
        ? base
        : _themeFor(base, coverScheme);
    // 结构恒定：Theme 包装层无论设计系统都在，只换数据。整份主题按封面 scheme
    // 重走工厂（不是只换 colorScheme）：菜单 / 倍速面板 / 提示条这些弹出层的
    // 表面色烤在组件主题里，只换 colorScheme 它们仍是全局色。
    return Theme(
      data: themed,
      child: Builder(
        builder: (BuildContext context) {
          _reportHtmlTheme(design.htmlTheme(context, widget.data));
          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size size = constraints.biggest;
              final EdgeInsets padding = MediaQuery.paddingOf(context);
              final Rect rect = design.lyricsRect(context, size, padding);
              _updateCursorHideScope(design, size);

              // 制卡角落小卡贴的是歌词 WebView 的真实矩形：跳转记录已移进顶栏
              // （[LyricsPlayerData.jumpActions]），WebView 就铺满外观给的歌词矩形。
              _lyricsRect = rect;
              return FushiTitleBarColorScope(
                colors: (background: topEdge, foreground: topEdgeForeground),
                // 覆盖层顶栏常驻（自动隐藏只收底栏），歌词矩形与顶栏都排在
                // padding.top 之下、标题行那一条只有背景：标题行是隐形拖动条，
                // 始终可拖窗口 / 双击最大化，窗口按钮指针进入才淡入（BUG-4102）。
                child: FushiTitleBarDragBandScope(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      // 空白背景：单击照旧（onTapBackground），鼠标按住拖动越过
                      // 拖动阈值才算拖窗口（BUG-4102）。歌词 WebView 在它上面，
                      // 不被覆盖。
                      Positioned.fill(
                        child: FushiWindowDragArea(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.callbacks.onTapBackground,
                            child: design.buildBackground(context, widget.data),
                          ),
                        ),
                      ),
                      // 跳转记录的返回 / 前进图标在各外观的顶栏右侧（
                      // [LyricsPlayerData.jumpActions]），不占歌词矩形。
                      Positioned.fromRect(rect: rect, child: widget.lyricsView),
                      Positioned.fill(
                        child: design.buildChrome(
                          context,
                          widget.data,
                          widget.callbacks,
                          size: size,
                          padding: padding,
                          lyricsRect: rect,
                        ),
                      ),
                      // 空闲隐藏光标：必须盖在最上层——WebView 插件自己的
                      // MouseRegion 会覆盖外层设的光标。半透明命中（不拦事件），
                      // 不隐藏时 defer 给下面的区域。
                      Positioned.fill(
                        child: MouseRegion(
                          key: const ValueKey<String>('lyrics_cursor_hider'),
                          opaque: false,
                          hitTestBehavior: HitTestBehavior.translucent,
                          cursor: _cursorHidden
                              ? SystemMouseCursors.none
                              : MouseCursor.defer,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
