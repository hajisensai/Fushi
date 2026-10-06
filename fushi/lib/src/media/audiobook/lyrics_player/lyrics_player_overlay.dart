import 'package:flutter/material.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_md3.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveCoverScheme();
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

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final LyricsPlayerDesign design = apple
        ? const AppleLyricsPlayerDesign()
        : const Md3LyricsPlayerDesign();
    final ThemeData base = Theme.of(context);
    final ColorScheme? coverScheme = apple ? null : _coverScheme;
    // 顶边底色：桌面自绘标题栏在 Navigator 外，只认页面上报的颜色。覆盖层上报这
    // 一色、并把背景最上面一条渐变带压成这一色，标题栏与播放页之间就没有接缝。
    //  * MD3：动态取色后的 surface（背景的渐变团是叠在 surface 上的）；
    //  * Apple：封面深色方案里的 surfaceContainerHigh（带封面色相的深灰，与模糊
    //    封面 + 黑色压暗后的顶部同一观感）；无封面时退回 iOS 深色分组底。
    final ColorScheme scheme = coverScheme ?? base.colorScheme;
    final Color topEdge = apple
        ? (_coverScheme?.surfaceContainerHigh ?? const Color(0xFF1C1C1E))
        : scheme.surface;
    final Color topEdgeForeground = apple ? Colors.white : scheme.onSurface;
    return FushiTitleBarColorScope(
      colors: (background: topEdge, foreground: topEdgeForeground),
      child: Theme(
        // 结构恒定：Theme 包装层无论设计系统都在，只换数据。
        data: coverScheme == null
            ? base
            : base.copyWith(colorScheme: coverScheme),
        child: Builder(
          builder: (BuildContext context) {
            _reportHtmlTheme(design.htmlTheme(context, widget.data));
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Size size = constraints.biggest;
                final EdgeInsets padding = MediaQuery.paddingOf(context);
                final Rect rect = design.lyricsRect(size, padding);
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.callbacks.onTapBackground,
                        child: design.buildBackground(context, widget.data),
                      ),
                    ),
                    // 顶边接缝带：从标题栏同色（实色）渐变到透明，盖在背景之上、
                    // 歌词与控件之下，不吃指针。
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: kLyricsTopSeamBand,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              // 最上 6px 保持实色：第一行像素与标题栏严格同色，
                              // 之后再渐隐（easeOut 形状由中间一档近似）。
                              stops: const <double>[0, 0.14, 0.55, 1],
                              colors: <Color>[
                                topEdge,
                                topEdge,
                                topEdge.withValues(alpha: 0.45),
                                topEdge.withValues(alpha: 0),
                              ],
                            ),
                          ),
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
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// 顶边接缝渐变带高度（逻辑像素）：标题栏同色实色 → 透明。
const double kLyricsTopSeamBand = 44;
