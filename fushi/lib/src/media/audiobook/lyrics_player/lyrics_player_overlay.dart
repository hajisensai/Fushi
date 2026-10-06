import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show rethemeFushiWithScheme;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_theme_host.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';

/// 歌词播放覆盖层外壳：盖在阅读器之上，阅读器在下面照常存活、跟随音频、记统计
/// （见 [LyricsPlayerData] 文件头）。本组件只负责：
///  * 按设计系统选外观（[isGlassDesign] → Apple，否则 MD3）；
///  * MD3 下从封面取动态配色（[ColorScheme.fromImageProvider]），整棵子树换上它；
///  * 把歌词 WebView 放进外观给出的矩形——**它在 Stack 里的位置恒定**（第 2 个
///    孩子），宽窄布局切换 / 旋转只改矩形，不重建平台视图；
///  * 外观算出的歌词 HTML 主题变化时回调 [onHtmlThemeChanged]，由页面热更 CSS。
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
    FushiDesktopTitleBar.visibleHeightListenable.removeListener(
      _onTitleBarResize,
    );
    _host?.detach(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReaderLyricsPlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.cover != widget.data.cover) _resolveCoverScheme();
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
  void initState() {
    super.initState();
    FushiDesktopTitleBar.visibleHeightListenable.addListener(_onTitleBarResize);
  }

  void _onTitleBarResize() {
    if (mounted) setState(() {});
  }

  // 标题栏里那截背景的构建材料（由 [build] 每次刷新；标题栏在 Navigator 之外、
  // 拿不到本页的主题与 MediaQuery，构建时原样套回去）。
  late LyricsPlayerDesign _backdropDesign;
  late ThemeData _backdropTheme;
  late MediaQueryData _backdropMediaQuery;
  double _bleed = 0;

  /// 标题栏里画的那份背景：与页面同一个外观、同一主题、同一画布（见
  /// [LyricsPlayerDesign.buildBackground] 的 bleedTop），只是被标题栏裁到最上面
  /// 一截。方法 tear-off 恒等，上报记录按值比较不会每帧重发。
  Widget _buildTitleBarBackdrop(BuildContext context) {
    return MediaQuery(
      data: _backdropMediaQuery,
      child: Theme(
        data: _backdropTheme,
        child: Builder(
          builder: (BuildContext context) => _backdropDesign.buildBackground(
            context,
            widget.data,
            bleedTop: _bleed,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _host?.attach(this, _coverScheme);
    final bool apple = isGlassDesign(context);
    final LyricsPlayerDesign design = apple
        ? const AppleLyricsPlayerDesign()
        : const Md3LyricsPlayerDesign();
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
    // 自绘标题栏占的高度：背景向上延伸这么多，画布顶上那截交给标题栏画。
    final double bleed = FushiDesktopTitleBar.visibleHeight;
    final ThemeData themed = coverScheme == null
        ? base
        : _themeFor(base, coverScheme);
    _backdropDesign = design;
    _backdropTheme = themed;
    _backdropMediaQuery = MediaQuery.of(context);
    _bleed = bleed;
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
              final Size canvas = Size(size.width, size.height + bleed);
              return FushiTitleBarColorScope(
                colors: (background: topEdge, foreground: topEdgeForeground),
                backdrop: bleed <= 0
                    ? null
                    : (
                        canvas: canvas,
                        builder: _buildTitleBarBackdrop,
                        revision: Object.hash(
                          identityHashCode(themed),
                          widget.data.cover,
                          apple,
                        ),
                      ),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    // 背景画布比页面高出标题栏那一截、向上越界（Stack 裁掉）；
                    // 标题栏画同一画布的顶上那截，页面与标题栏之间没有色带。
                    Positioned(
                      left: 0,
                      top: -bleed,
                      width: canvas.width,
                      height: canvas.height,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.callbacks.onTapBackground,
                        child: design.buildBackground(
                          context,
                          widget.data,
                          bleedTop: bleed,
                        ),
                      ),
                    ),
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
