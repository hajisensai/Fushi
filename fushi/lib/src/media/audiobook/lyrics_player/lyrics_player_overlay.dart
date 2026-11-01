import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion, fushiMotionDuration;

/// 新版宽屏底栏：播放中无指针 / 按键活动多久后自动隐藏。
const Duration kLyricsChromeIdleHideDelay = Duration(seconds: 3);

/// 浮动件（跳转回退胶囊）占的带子高度：胶囊命中区 48dp + 上下各 4dp 留白。
const double kLyricsNavigationAccessoryBand = 56;

/// 有浮动件时歌词 WebView 的矩形：外观给的歌词矩形 [lyricsRect] 从底边让出
/// [kLyricsNavigationAccessoryBand]（矩形太矮时至少留 1dp 高，不出负高度）。
Rect lyricsViewRectFor(Rect lyricsRect, {required bool hasAccessory}) {
  if (!hasAccessory) return lyricsRect;
  final double bottom = math.max(
    lyricsRect.top + 1,
    lyricsRect.bottom - kLyricsNavigationAccessoryBand,
  );
  return Rect.fromLTRB(
    lyricsRect.left,
    lyricsRect.top,
    lyricsRect.right,
    bottom,
  );
}

/// 浮动件所在的带子：歌词矩形最底下那一截，紧贴外观底栏 / 控件面板的上沿。
Rect navigationAccessoryRectFor(Rect lyricsRect) {
  final Rect lyrics = lyricsViewRectFor(lyricsRect, hasAccessory: true);
  return Rect.fromLTRB(
    lyricsRect.left,
    lyrics.bottom,
    lyricsRect.right,
    math.max(lyrics.bottom, lyricsRect.bottom),
  );
}

/// 歌词播放覆盖层外壳：盖在阅读器之上，阅读器在下面照常存活、跟随音频、记统计
/// （见 [LyricsPlayerData] 文件头）。本组件只负责：
///  * 按设计系统选外观（[isGlassDesign] → Apple，否则 MD3）；
///  * MD3 下从封面取动态配色（[ColorScheme.fromImageProvider]），整棵子树换上它；
///  * 把歌词 WebView 放进外观给出的矩形——**它在 Stack 里的位置恒定**（第 2 个
///    孩子），宽窄布局切换 / 旋转只改矩形，不重建平台视图；
///  * 外观算出的歌词 HTML 主题变化时回调 [onHtmlThemeChanged]，由页面热更 CSS；
///  * MD3 新版宽屏底栏的空闲自动隐藏：播放中 [kLyricsChromeIdleHideDelay] 内没有
///    底栏相关活动 → 底栏淡出，淡完再一次性把歌词矩形伸到底。**隐藏后只有指针进入
///    歌词区下方的底边带子（或按 Tab）才唤出**：正文上的移动 / 点击 / 查词不唤出——
///    唤出会把歌词矩形缩回去、竖排正文重排，鼠标下的字会挪位，查词就点不准了。
///    显示期间任何点击 / 拖动（含菜单、弹层）、按键或在底栏区域悬停都续上计时；
///    暂停 / 切布局立即复位；
///  * 同一条件下鼠标指针空闲 [kLyricsChromeIdleHideDelay] 后隐藏（不论停在哪），
///    一动就回来。与底栏分开计：光标显隐不改歌词矩形，正文上一动就该看得见。
class ReaderLyricsPlayerOverlay extends StatefulWidget {
  const ReaderLyricsPlayerOverlay({
    super.key,
    required this.lyricsView,
    required this.data,
    required this.callbacks,
    required this.onHtmlThemeChanged,
    this.navigationAccessory,
  });

  /// 歌词 WebView（透明底）。
  final Widget lyricsView;

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 歌词文档主题（颜色 / 对齐 / 透明度阶梯）变化。首帧也会回调一次。
  final ValueChanged<LyricsHtmlTheme> onHtmlThemeChanged;

  /// 歌词区底边、紧贴底栏（控件面板）上方的浮动件（阅读器的「跳转回退」胶囊）。
  /// null 不画。
  ///
  /// 反馈 0AwuVqrNFn：旧实现把它盖在歌词区顶部，压住正文行。现在它有自己的一条
  /// 带子（[kLyricsNavigationAccessoryBand]）：有浮动件时歌词 WebView 的矩形从底边
  /// 让出这条带子，胶囊坐在带子里，**不与任何歌词行重叠**——与用户怎么调边距无关
  /// （默认边距下也成立），因为让位发生在外观给出的歌词矩形上，而不是靠歌词文档的
  /// 内边距碰运气。
  final Widget? navigationAccessory;

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

  /// 底栏已淡出（[Md3ModernLyricsPlayerDesign.wideChromeHidden]）。
  bool _chromeHidden = false;

  /// 歌词矩形已伸到底（[Md3ModernLyricsPlayerDesign.wideLyricsExpanded]）。
  bool _lyricsExpanded = false;

  /// 空闲计时器：每次活动重排（取消 + 新建，比逐帧轮询便宜）。
  Timer? _idleTimer;
  Timer? _expandTimer;

  /// 上一帧布局的判据（本地坐标）：是否宽屏、底栏区域顶边（= 正常歌词矩形底边）、
  /// 唤出带子顶边（= 伸到底的歌词矩形底边）。build 里随布局更新。
  bool _wide = false;
  double _chromeZoneTop = double.infinity;
  double _revealZoneTop = double.infinity;

  /// 最近一次悬停的纵坐标（本地）：鼠标停在底栏上不动时不隐藏。
  double? _hoverY;

  /// 鼠标指针已隐藏（空闲）。
  bool _cursorHidden = false;
  Timer? _cursorTimer;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAutoHide());
  }

  /// 条件（播放态 / 布局 / 宽窄）变化：底栏与光标一起复位重排。
  void _syncAutoHide() {
    _syncIdle();
    _syncCursor();
  }

  /// 光标复位并按当前条件重排（或撤掉）空闲隐藏计时。
  void _syncCursor() {
    if (!mounted) return;
    _cursorTimer?.cancel();
    _cursorTimer = null;
    if (_cursorHidden) setState(() => _cursorHidden = false);
    if (!_autoHideEnabled) return;
    _cursorTimer = Timer(kLyricsChromeIdleHideDelay, () {
      _cursorTimer = null;
      if (!mounted || !_autoHideEnabled) return;
      setState(() => _cursorHidden = true);
    });
  }

  /// 只有 MD3 新版布局播放中才自动隐藏（Apple / 经典 / 暂停一律常显）。宽窄由外观
  /// 自己判断：窄屏忽略这两个标志。
  bool get _autoHideEnabled =>
      mounted &&
      widget.data.isPlaying &&
      widget.data.controlsStyle == LyricsControlsStyle.modern &&
      _wide &&
      !isGlassDesign(context);

  /// 全局坐标 → 本覆盖层的纵坐标；还没布局时 null。
  double? _localY(Offset global) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.globalToLocal(global).dy;
  }

  void _onGlobalPointer(PointerEvent event) {
    if (!mounted) return;
    final bool hover = event is PointerHoverEvent;
    final bool press = event is PointerDownEvent || event is PointerMoveEvent;
    if (!hover && !press) return;
    _syncCursor();
    final double? y = _localY(event.position);
    if (hover) _hoverY = y;
    if (_chromeHidden) {
      // 隐藏中只认底边带子：正文上的移动 / 点击（查词）不唤出、不改歌词矩形。
      if (y != null && y >= _revealZoneTop) _syncIdle();
      return;
    }
    // 显示中：点击 / 拖动（含菜单与弹层里的）或在底栏区域悬停都续上计时；
    // 只在正文上悬停不续，否则边读边动鼠标底栏永远不走。
    if (press || (y != null && y >= _chromeZoneTop)) _syncIdle();
  }

  bool _onKey(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    // 隐藏中只有 Tab（焦点要进底栏）唤出；其余快捷键不动底栏、不重排正文。
    if (!_chromeHidden || event.logicalKey == LogicalKeyboardKey.tab) {
      _syncIdle();
    }
    return false;
  }

  /// 复位底栏并按当前条件重排（或撤掉）空闲计时器。
  void _syncIdle() {
    if (!mounted) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    _expandTimer?.cancel();
    _expandTimer = null;
    if (_chromeHidden || _lyricsExpanded) {
      setState(() {
        _chromeHidden = false;
        _lyricsExpanded = false;
      });
    }
    if (_autoHideEnabled) {
      _idleTimer = Timer(kLyricsChromeIdleHideDelay, _onIdleTimer);
    }
  }

  void _onIdleTimer() {
    _idleTimer = null;
    if (!mounted || !_autoHideEnabled) return;
    final double? hoverY = _hoverY;
    if (hoverY != null && hoverY >= _chromeZoneTop) {
      // 鼠标停在底栏上：不在它底下把底栏收走。
      _idleTimer = Timer(kLyricsChromeIdleHideDelay, _onIdleTimer);
      return;
    }
    final Duration fade = fushiMotionDuration(context, FushiMotion.medium);
    setState(() {
      _chromeHidden = true;
      // 无动效（墨水屏 / 减弱动态效果）时直接一步到位。
      if (fade == Duration.zero) _lyricsExpanded = true;
    });
    if (fade == Duration.zero) return;
    _expandTimer = Timer(fade, () {
      _expandTimer = null;
      if (!mounted || !_chromeHidden) return;
      setState(() => _lyricsExpanded = true);
    });
  }

  /// 页面外的歌词主题宿主（路由 builder 包的那层）：登记后整页弹出层（菜单 /
  /// 侧栏 / 对话框 / 查词浮层）一起换成歌词模式配色。
  LyricsThemeHostState? _host;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idleTimer?.cancel();
    _expandTimer?.cancel();
    _cursorTimer?.cancel();
    _host?.detach(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReaderLyricsPlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.cover != widget.data.cover) _resolveCoverScheme();
    if (oldWidget.data.isPlaying != widget.data.isPlaying ||
        oldWidget.data.controlsStyle != widget.data.controlsStyle) {
      // 播放态变化本身算一次活动：刚按下播放不该立刻吞掉底栏。
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncAutoHide());
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

  /// 记下这次布局的宽窄与两条判据线（只读几何，不触发重建）。宽窄变了重排计时。
  void _updateAutoHideZones(
    BuildContext context,
    LyricsPlayerDesign design,
    Size size,
    EdgeInsets padding,
  ) {
    final bool wide =
        design is Md3ModernLyricsPlayerDesign && lyricsPlayerIsWide(size);
    if (wide) {
      _chromeZoneTop = Md3ModernLyricsPlayerDesign(
        compactExpanded: widget.data.compactControlsExpanded,
      ).lyricsRect(context, size, padding).bottom;
      _revealZoneTop = Md3ModernLyricsPlayerDesign(
        compactExpanded: widget.data.compactControlsExpanded,
        wideLyricsExpanded: true,
      ).lyricsRect(context, size, padding).bottom;
    } else {
      _chromeZoneTop = double.infinity;
      _revealZoneTop = double.infinity;
    }
    if (wide != _wide) {
      _wide = wide;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncAutoHide());
    }
  }

  Widget _buildWithMirror(
    BuildContext context, {
    required bool apple,
    required double mirror,
  }) {
    // MD3 按偏好选新版 / 经典布局；Apple 不读这项偏好（设置面板在 Apple 下隐藏）。
    final LyricsPlayerDesign design = apple
        ? AppleLyricsPlayerDesign(mirrorProgress: mirror)
        : widget.data.controlsStyle == LyricsControlsStyle.classic
        ? Md3LyricsPlayerDesign(mirrorProgress: mirror)
        : Md3ModernLyricsPlayerDesign(
            compactExpanded: widget.data.compactControlsExpanded,
            wideChromeHidden: _chromeHidden,
            wideLyricsExpanded: _lyricsExpanded,
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
              _updateAutoHideZones(context, design, size, padding);
              return FushiTitleBarColorScope(
                colors: (background: topEdge, foreground: topEdgeForeground),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.callbacks.onTapBackground,
                        child: design.buildBackground(context, widget.data),
                      ),
                    ),
                    Positioned.fromRect(
                      rect: lyricsViewRectFor(
                        rect,
                        hasAccessory: widget.navigationAccessory != null,
                      ),
                      child: widget.lyricsView,
                    ),
                    if (widget.navigationAccessory != null)
                      Positioned.fromRect(
                        rect: navigationAccessoryRectFor(rect),
                        child: Center(child: widget.navigationAccessory),
                      ),
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
              );
            },
          );
        },
      ),
    );
  }
}
