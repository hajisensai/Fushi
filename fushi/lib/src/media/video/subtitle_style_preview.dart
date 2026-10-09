import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_image.dart'
    show kClipSubtitleMaxWidthFraction;
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// 预览里的日文示例台词。字幕查词 / 制卡的内容语言是日文，示例用日文才能看出
/// 字体回退链、字重与投影在假名 / 汉字上的真实效果；不随界面语言翻译。
const String _kPreviewSampleLine = '今日はいい天気ですね';

/// 拿不到窗口尺寸（测试 / 首帧未布局）时假定的视频显示区（逻辑像素）。
const Size _kFallbackVideoArea = Size(1280, 720);

/// 字幕样式预览：一块 16:9 的模拟画面，按**当前生效的字幕设置**画一行日文示例
/// 台词（可选再加一行副字幕译文）。
///
/// 样式来源与播放页 `VideoSubtitleOverlay` 的默认外观是同一份：
/// - 偏好 `videoSubtitleStyle` → [VideoSubtitleStyle.decode]；拖动滑条时的未落盘
///   预览态走 [videoSubtitleStyleDraft]（设置页没有播放页可问）。
/// - 字重 / 阴影粗细的「跟随界面缩放」用 [VideoSubtitleStyle.resolveFontWeight] /
///   [VideoSubtitleStyle.resolveShadowThickness]；投影用 [buildSubtitleSoftShadow]；
///   背景底色 [kDefaultSubtitleBackgroundColor]；行高 / 盒内边距 / 圆角用
///   [kVideoSubtitleLineHeight] / [kVideoSubtitleBoxPadding] /
///   [kVideoSubtitleBoxRadius]；字号乘 [subtitleScreenScaleFactor]；主 / 副字幕的
///   锚定边用 [resolveLayerForcedAnchor]。
/// - 字体 = `AppModel.subtitleFontFamily` + 日文内容的回退链（与 overlay 按内容
///   语言解析的同一个 [contentFontFamilies]）。
///
/// **比例忠实**：先在「当前窗口里 16:9 视频会占的那块区域」大小的虚拟画布上按
/// 真实逻辑像素排版，再整体缩进预览框——字幕占画面的比例、离边距离与播放时一致，
/// 而不是把 36px 原样塞进一个两百像素高的小框里。主 / 副两组按换行后的实际高度
/// 依次排布；放不下时画布增高后整体等比缩小，绝不叠字（BUG-3080）。
///
/// 只读、不可聚焦（纯展示，不占键盘 / 手柄的焦点停靠）。
class SubtitleStylePreview extends StatefulWidget {
  const SubtitleStylePreview({
    super.key,
    this.appModel,
    this.uiScale,
    this.height,
    this.showSecondary = true,
  });

  /// 调用方手里已有的 [AppModel]（设置渲染器的 `SettingsContext.appModel`）。
  /// 给了就直接用，不再从 ProviderScope 现取：视频面板 / 设置页的宿主已经把
  /// AppModel 传进 SettingsContext，预览再绕回容器读 `appProvider` 等于多一条
  /// 「宿主必须挂真 ProviderScope 覆盖」的隐式依赖（页面 widget 测试只给
  /// AppModel 不挂覆盖，整页因此 build 抛错）。null = 退回从容器读。
  final AppModel? appModel;

  /// 字幕字重 / 阴影按哪个 UI scale resolve。视频播放面板传
  /// `VideoQuickSettingsHost.uiScale`（视频路由把 FushiAppUiScale 中和成 1.0，
  /// 真字幕按 host 带入的实际 scale 画，预览要与它同源）；null = 全局设置页，
  /// 读 [AppModel.appUiScale]。
  final double? uiScale;

  /// 模拟画面的高度。null = 随可用宽度按 16:9 伸缩（上限 [maxWidth]）。
  final double? height;

  /// 是否再画一行副字幕译文（锚在副字幕层实际会落的那一边）。
  final bool showSecondary;

  /// 不给 [height] 时画面的最大宽度：全宽设置页上不至于撑成一整屏。
  static const double maxWidth = 640;

  @override
  State<SubtitleStylePreview> createState() => _SubtitleStylePreviewState();
}

class _SubtitleStylePreviewState extends State<SubtitleStylePreview> {
  AppModel? _appModel;
  Listenable? _listenable;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppModel appModel =
        widget.appModel ??
        ProviderScope.containerOf(context, listen: false).read(appProvider);
    if (!identical(appModel, _appModel)) {
      _appModel = appModel;
      // 偏好落盘（PreferencesRepository 通知）、字幕字体换了（AppModel 通知）、
      // 滑条拖动中的预览态，三者任一变化都重画。
      _listenable = Listenable.merge(<Listenable>[
        appModel,
        appModel.prefsRepo,
        videoSubtitleStyleDraft,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = _appModel!;
    return ListenableBuilder(
      listenable: _listenable!,
      builder: (BuildContext context, Widget? _) => _buildFrame(
        context,
        style:
            videoSubtitleStyleDraft.value ??
            VideoSubtitleStyle.decode(appModel.videoSubtitleStyle),
        fontFamily: appModel.subtitleFontFamily,
        uiScale: widget.uiScale ?? appModel.appUiScale,
      ),
    );
  }

  Widget _buildFrame(
    BuildContext context, {
    required VideoSubtitleStyle style,
    required String? fontFamily,
    required double uiScale,
  }) {
    final bool glass = isGlassDesign(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 外框：Apple = 分组卡底色（secondarySystemGroupedBackground），MD3 =
    // surfaceContainerLow。画面本身恒为深色模拟画面，不随主题。
    final Color frameColor = glass
        ? appleColorsOf(context).secondaryGroupedBackground
        : cs.surfaceContainerLow;
    final Widget screen = _buildScreen(
      context,
      style: style,
      fontFamily: fontFamily,
      uiScale: uiScale,
    );
    return Semantics(
      image: true,
      label: t.video_subtitle_preview_label,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: frameColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double? fixedHeight = widget.height;
                final double width = fixedHeight != null
                    ? fixedHeight * 16 / 9
                    : math.min(
                        constraints.maxWidth.isFinite
                            ? constraints.maxWidth
                            : SubtitleStylePreview.maxWidth,
                        SubtitleStylePreview.maxWidth,
                      );
                return Center(
                  child: SizedBox(
                    width: width,
                    height: fixedHeight ?? width * 9 / 16,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: screen,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 模拟画面 + 字幕层：在真实视频显示区大小的虚拟画布上排版后整体缩放。
  Widget _buildScreen(
    BuildContext context, {
    required VideoSubtitleStyle style,
    required String? fontFamily,
    required double uiScale,
  }) {
    final Size window = MediaQuery.sizeOf(context);
    final Size area = _videoAreaIn(window);
    final double fontSize =
        style.fontSize *
        subtitleScreenScaleFactor(window.isEmpty ? area : window);
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 颜色 null（TODO-051 之前的旧数据 =「跟随主题」）的回退与播放页一致：
    // 正文 onSurface、投影 shadow、背景固定半透明黑。
    final Color textColor = style.resolveTextColor(cs.onSurface);
    final Color shadowColor = style.resolveShadowColor(cs.shadow);
    final Color boxColor = style.backgroundOpacity <= 0
        ? Colors.transparent
        : style
              .resolveBackgroundColor(kDefaultSubtitleBackgroundColor)
              .withValues(alpha: style.backgroundOpacity);
    final List<String> fallback = contentFontFamilies(
      languageTag: 'ja',
      platform: defaultTargetPlatform,
    );
    final TextStyle textStyle = TextStyle(
      color: textColor,
      fontSize: fontSize,
      height: kVideoSubtitleLineHeight,
      fontFamily: fontFamily,
      fontFamilyFallback: fallback.isEmpty ? null : fallback,
      fontWeight: videoSubtitleFontWeight(style.resolveFontWeight(uiScale)),
      shadows: buildSubtitleSoftShadow(
        shadowColor,
        style.resolveShadowThickness(uiScale),
      ),
    );

    Widget line(String text) => ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: area.width * kClipSubtitleMaxWidthFraction,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: boxColor,
          borderRadius: BorderRadius.circular(kVideoSubtitleBoxRadius),
        ),
        child: Padding(
          padding: kVideoSubtitleBoxPadding,
          child: Text(text, textAlign: TextAlign.center, style: textStyle),
        ),
      ),
    );

    final SubtitleLayerVAnchor mainAnchor = style.mainAnchor;
    final double mainPadding = _clampDistance(style.bottomPadding);
    // 每边的字幕盒按**离锚定边由近到远**排列；两边各自成一组。
    final List<Widget> topLines = <Widget>[];
    final List<Widget> bottomLines = <Widget>[];
    double topDistance = 0;
    double bottomDistance = 0;
    void place(SubtitleLayerVAnchor anchor, double distance, Widget box) {
      if (anchor == SubtitleLayerVAnchor.top) {
        if (topLines.isEmpty) topDistance = distance;
        topLines.add(box);
      } else {
        if (bottomLines.isEmpty) bottomDistance = distance;
        bottomLines.add(box);
      }
    }

    // 主层先放：同边时它离锚定边最近、副字幕在外侧更靠画面中央（不互相压字）。
    place(mainAnchor, mainPadding, line(_kPreviewSampleLine));
    if (widget.showSecondary) {
      // 副字幕层的锚定边与位置基线：与 overlay 同一套解析（无显式选择时取主层
      // 对侧；位置 null = 跟随主字幕）。
      final SubtitleLayerVAnchor secondaryAnchor =
          resolveLayerForcedAnchor(
            isSecondary: true,
            userAnchor: style.secondaryAnchor,
            mainUserAnchor: mainAnchor,
            ownNonBottom: false,
          ) ??
          SubtitleLayerVAnchor.top;
      place(
        secondaryAnchor,
        _clampDistance(style.secondaryBottomPadding ?? style.bottomPadding),
        line(t.video_subtitle_preview_translation),
      );
    }

    // BUG-3080：两层曾各自用 Positioned 钉在**固定高度**画布的对边（顶层离顶 N、底层
    // 离底 N），彼此不知道对方多高。竖屏手机上画布只有「屏宽 × 9/16」≈ 220 高，
    // 字号一大、主字幕换行，底锚盒向上长过顶锚盒——换出来的字与副字幕画在同一处
    // （串行），而且主字幕第一行跑到副字幕上面（顺序反转）。真播放页的字幕层铺满
    // 整个播放容器（竖屏 ≈ 整屏高），本次默认设置在那里两层相隔几百像素。
    //
    // 修法：两组按实际（换行后）高度在一列里依次排布——顶组、弹性空隙、底组——
    // 画布高度取「16:9 显示区高」与「两组 + 离边距离总高」的较大者。放得下时与旧
    // 版逐像素同位；放不下时画布增高、再由 FittedBox 整体等比缩进预览框，字小一点
    // 但绝不串行，顶组永远在底组之上（与播放页同序）。
    final Widget subtitleCanvas = SizedBox(
      width: area.width,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: area.height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(height: topDistance),
                ...topLines,
              ],
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 底组离锚定边由近到远 = 列里自下而上，故倒序放入。
                ...bottomLines.reversed,
                SizedBox(height: bottomDistance),
              ],
            ),
          ],
        ),
      ),
    );

    final bool eink = isEinkTheme(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _SimulatedScene(eink: eink),
        FittedBox(fit: BoxFit.contain, child: subtitleCanvas),
      ],
    );
  }

  /// 距锚定边的距离夹到 [0, [kVideoSubtitleMaxPadding]]（与滑条 / 持久化同一上限）。
  static double _clampDistance(double padding) =>
      padding.clamp(0, kVideoSubtitleMaxPadding).toDouble();

  /// 当前窗口里一段 16:9 视频（contain）会占的显示区。
  static Size _videoAreaIn(Size window) {
    if (window.isEmpty) return _kFallbackVideoArea;
    final double width = window.width;
    final double height = width * 9 / 16;
    if (height <= window.height) return Size(width, height);
    return Size(window.height * 16 / 9, window.height);
  }
}

/// 模拟画面：深色中性渐变 + 一团柔和的暖光与地平线暗部，像一帧黄昏外景——
/// 足够「像视频」，又不会抢字幕的对比度判断。墨水屏退成纯黑（渐变在墨水屏上
/// 只会变成脏灰噪点）。
class _SimulatedScene extends StatelessWidget {
  const _SimulatedScene({required this.eink});

  final bool eink;

  @override
  Widget build(BuildContext context) {
    if (eink) return const ColoredBox(color: Color(0xFF000000));
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0xFF3A4656),
            Color(0xFF232A35),
            Color(0xFF101318),
          ],
          stops: <double>[0, 0.55, 1],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.55, -0.35),
                  radius: 0.75,
                  colors: <Color>[Color(0x33FFD8A8), Color(0x00FFD8A8)],
                ),
              ),
            ),
          ),
          // 下三分之一压暗：字幕通常落在这里，真实画面的这一带也多是地面 / 暗部。
          Positioned.fill(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                widthFactor: 1,
                heightFactor: 0.36,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x00080A0D), Color(0xCC080A0D)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
