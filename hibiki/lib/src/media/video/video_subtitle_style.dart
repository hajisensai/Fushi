import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// media_kit 默认底部控制条的**进度条（seek bar）上缘**距视频底边的清空高度（逻辑像素）。
///
/// TODO-171（抄 B站）：字幕避让只需让出**进度条本身那一条**，不是整条底部按钮行。
/// media_kit 底部控制条在同一个 `Stack(bottomCenter)` 里自底向上堆：按钮行
/// （`buttonBarHeight: 56`，播放/快进/时间/全屏图标），进度条（seek bar）骑在按钮行
/// 上沿（桌面用 `Transform.translate(Offset(0, 16))` 把进度条下压、与按钮行顶部重叠）。
/// 真正会遮住字幕的只有进度条那一条，它落在距视频底约一个按钮行高（`buttonBarHeight`）
/// 处。故避让高度取 [_kButtonBarHeight]=56：字幕底缘抬到进度条上方一点点恰骑其顶，
/// 不再多抬整条按钮行 + 离底 margin（旧 `42 + 56 = 98` 把字幕顶过整条按钮行、飞进
/// 画面中上部，用户报「进度条出来把字幕往上顶太高很怪」）。
///
/// 旧值的 `42` 是 media_kit 导出常量 [kDefaultMaterialVideoControlsThemeData] 那套含
/// `bottomButtonBarMargin.bottom: 42` 的整体离底留白——它是控制条离屏幕底边的空白，
/// 不是遮挡字幕的实体，叠进避让只会凭空多抬一个 margin。Hibiki 实际 new 的桌面主题
/// （`MaterialDesktopVideoControlsThemeData`）走构造器默认（`bottomButtonBarMargin`
/// 只有左右、vertical=0），本就没有这 42px，故去掉它也更贴合 Hibiki 真实几何。
///
/// Hibiki 用自绘 `VideoSubtitleOverlay`（非 media_kit 内置字幕视图）。TODO-129 起字幕
/// **动态**避让：控制条出现时把字幕在用户位置之上抬到 `max(用户位置, 本值)`、隐藏时
/// 落回用户位置（由 [VideoSubtitleOverlay] 的 `controlsVisible` 驱动 `AnimatedPadding`，
/// TODO-161 取下限而非加法），不再像 TODO-089 那样把本值恒加进默认
/// [VideoSubtitleStyle.bottomPadding]。本常量是「控制条可见时字幕底缘骑到的进度条上缘
/// 高度」。
const double _kButtonBarHeight = 56;
const double kVideoControlsBottomReserve = _kButtonBarHeight;

/// 控制条可见时**顶部锚字幕**要让出的「顶栏下缘距视频顶边的高度」（逻辑像素）。与
/// [kVideoControlsBottomReserve] 对称：顶部内嵌 chrome（标题栏 + 右上角菜单，替代被删
/// 的 AppBar，BUG-102）占据视频顶部一个按钮行高；此前只有底部锚字幕避让进度条，顶部锚
/// 字幕无避让 → 控制条可见时顶部字幕与标题栏/菜单重叠、把 UI 盖住（BUG-1069）。默认取
/// 一个按钮行高（桌面顶栏贴 y=0、无系统 inset），移动端由页面按真实几何加总覆盖。
const double kVideoControlsTopReserve = _kButtonBarHeight;

/// 控制条可见时字幕要让出的「进度条上缘距视频底边的高度」（逻辑像素），由真实控制条
/// 几何加总而成，并随界面缩放（`uiScale`）放大（BUG-238）。
///
/// 背景（BUG-226/228 的失效区间）：避让用 `max(bottomPadding, reserve)`（取下限，
/// 非加法——加法会把高位字幕顶飞，BUG-226），但旧 reserve 是**常量** 56：
/// - 不随界面缩放（放大界面后控制条变高、reserve 不变 → 盖不住）；
/// - 桌面进度条骑按钮行上沿（约一个按钮行高）56 够用，但**移动端**进度条被抬到
///   `底部留白 + 按钮行 + 间距 + 进度条热区` 之上，上缘 ≈ 140px，远高于默认基线 75，
///   `max(75, 56)=75` 把字幕留在进度条**下面**被遮（用户报「只动了一点点」=实际 0）。
///
/// 故 reserve 必须 = 进度条上缘真实高度（按平台几何加总）×缩放，且 > 默认基线 75 才能
/// 让取下限真正抬升字幕盖过进度条。本函数把这套几何收敛成纯函数（页面与测试同源调用）：
/// - 桌面：进度条骑按钮行上沿 → reserve = 一个按钮行高（[buttonBarHeight]），保持
///   BUG-228「只让出进度条那一条、不抬过整条按钮行」的桌面观感，但现在随缩放变化；
/// - 移动：进度条整体被抬到按钮行上方 → reserve = [bottomChromeBaseline] + 系统底部
///   inset + [buttonBarHeight] + [seekBarButtonGap] + **进度条触摸热区全高**
///   [seekBarContainerHeight] + 字幕呼吸间距 [subtitleBreathingGap]（= 进度条**触摸热区
///   上缘** + 一点点呼吸距离，字幕命中区整体骑在进度条整段可点区上方）。
///
/// BUG-901（字幕点击与进度条点击挨太近 / 误触）——推翻 TODO-568 的取舍：TODO-568 当初为
/// 消「字幕顶飞」把移动 reserve 从触摸热区全高改成**可见轨道高** [seekBarTrackHeight] +
/// 呼吸，让字幕底缘骑在可见进度条上方一点点。但 media_kit `MaterialSeekBar` 把可见轨道放在
/// 触摸热区容器底缘（`Alignment.bottomCenter`），容器上方 ~35×缩放 全是**透明但可点**的
/// seek 命中区。字幕只避让可见轨道 → 字幕命中区（含逐字符兜底扩边）落进那段透明热区里，与
/// 进度条 seek 命中区在同一手势竞技场重叠，手指差几像素就把字幕点误判成 seek、seek 误判成
/// 字幕（用户报「点字幕/点进度条太容易点错」）。
///
/// 修正：移动 reserve 改回用**触摸热区全高** [seekBarContainerHeight]（进度条真正的可点
/// 目标，非只可见轨道）+ 呼吸间距，让字幕命中区整体清出进度条整段 seek 命中区、两者不再
/// 重叠。代价是控制条可见时字幕比可见轨道高出约一个热区高（用户明确要求「让他们远一点」，
/// 这段离底距离正是要的分隔；控制条会自动隐藏、字幕随即落回用户基线）。若真机上此分隔过大，
/// 收窄 `_videoSeekBarContainerHeight`（进度条可点热区）或 [subtitleBreathingGap] 即可，
/// 但不能退回只让可见轨道高——那会重新让两命中区重叠（本 bug 根因）。
///
/// 几何项均来自 `video_hibiki_page.dart` 的同名控制条 getter（已 ×uiScale）；本函数不再
/// 二次乘 uiScale，由调用方传入已缩放值，避免双重缩放。[bottomChromeBaseline] 是不随
/// 缩放的离底基线常量（与页面 `_videoBottomChromeBaseline` 一致），故在此显式加上而非
/// 乘缩放。
double videoSubtitleControlsReserve({
  required bool isDesktop,
  required double buttonBarHeight,
  required double seekBarButtonGap,
  required double seekBarContainerHeight,
  required double subtitleBreathingGap,
  required double bottomChromeBaseline,
  required double bottomSystemInset,
}) {
  if (isDesktop) {
    // 桌面进度条骑按钮行上沿：让出一个（已缩放的）按钮行高即可（BUG-228）。
    return buttonBarHeight;
  }
  // 移动进度条**触摸热区上缘** = 离底基线 + 系统 inset + 按钮行 + 进度条/按钮间距 +
  // 触摸热区全高；再加字幕呼吸间距让字幕命中区整体骑在进度条整段可点区上方，不与 seek
  // 命中区重叠（BUG-901：只让可见轨道高会落进热区上方那段透明可点区、误触）。
  return bottomChromeBaseline +
      bottomSystemInset +
      buttonBarHeight +
      seekBarButtonGap +
      seekBarContainerHeight +
      subtitleBreathingGap;
}

/// 控制条可见时**顶部锚字幕**要让出的「顶栏下缘距视频顶边的高度」（逻辑像素），与
/// [videoSubtitleControlsReserve]（底部）对称。顶部内嵌 chrome（标题栏 + 右上角菜单）位于
/// 视频顶部：桌面贴 y=0、无系统 inset；移动端顶栏抬离状态栏/刘海（`_videoTopBarMargin`）。
/// 顶栏下缘 = 顶部系统 inset + 一个按钮行高；再加字幕呼吸间距让顶部字幕与顶栏留一点分隔。
/// 顶部锚字幕顶缘对本值取下限（`max(用户顶距, 本值)`，见 [VideoSubtitleOverlay._paddingFor]），
/// 控制条可见时整体下移到顶栏下方、不再被标题栏/菜单遮（BUG-1069）；隐藏时落回用户基线。
/// 几何项均已 ×uiScale（由调用方传入已缩放值，本函数不二次缩放）。
double videoSubtitleControlsTopReserve({
  required double buttonBarHeight,
  required double topSystemInset,
  required double subtitleBreathingGap,
}) {
  return topSystemInset + buttonBarHeight + subtitleBreathingGap;
}

/// seek bar 章节刻度层（TODO-432）相对**控制条区域底边**的竖直锚定：返回紧贴轨道的刻度带
/// `bottom`（带底缘离控制条区底边的距离）与 `height`（带高）。纯函数，页面与测试同源。
///
/// 刻度带不取整个 seek bar 容器（会让竖线在桌面凭空高出一截），而是以**轨道中线**为中心、
/// 取 [tickHeight] 的一小段，让竖线只在轨道上下各探出一点点（既盖住轨道又不喧宾夺主）。
///
/// 与 media_kit + [videoSubtitleControlsReserve] 同源的几何（值均已 ×uiScale，本函数不再
/// 二次缩放，[bottomChromeBaseline] 例外为不随缩放的离底常量）：
/// - **桌面**：media_kit 把进度条骑在底部按钮行上沿（`Transform.translate(Offset(0,16))`
///   把进度条下压、与按钮行顶部重叠）。轨道中线大致落在距控制条底边一个按钮行高
///   （[buttonBarHeight]）处。
/// - **移动**：进度条容器底缘 = 离底基线 + 系统 inset + 按钮行 + 进度条/按钮间距
///   （= 页面 `seekBarBottom`），容器高 = [seekBarContainerHeight]，轨道在容器内
///   bottomCenter（贴容器底缘）→ 轨道中线 ≈ `seekBarBottom + seekBarTrackHeight/2`。
({double bottom, double height}) videoSeekBarTrackBand({
  required bool isDesktop,
  required double buttonBarHeight,
  required double seekBarButtonGap,
  required double seekBarContainerHeight,
  required double seekBarTrackHeight,
  required double bottomChromeBaseline,
  required double bottomSystemInset,
  required double tickHeight,
}) {
  final double trackCenter;
  if (isDesktop) {
    // 桌面：轨道骑按钮行上沿，中线 ≈ 一个按钮行高处。
    trackCenter = buttonBarHeight;
  } else {
    // 移动：轨道贴容器底缘（bottomCenter），中线 = seekBarBottom + 轨道半高。
    final double seekBarBottom = bottomChromeBaseline +
        bottomSystemInset +
        buttonBarHeight +
        seekBarButtonGap;
    trackCenter = seekBarBottom + seekBarTrackHeight / 2;
  }
  // 以轨道中线为中心展开 tickHeight：带底缘 = 中线 − 半高。
  return (bottom: trackCenter - tickHeight / 2, height: tickHeight);
}

/// 字幕字号的**屏幕自适应因子**（TODO-1199）。
///
/// 问题：字幕字号此前把用户设置的固定值（[VideoSubtitleStyle.fontSize]）原样喂给
/// overlay，不随屏幕尺寸换算。同一 36px 在小屏手机上占画面很大一块、在大屏平板 / 桌面
/// 上却显得很小——同一字号在不同设备物理观感不一致（用户报「大屏字幕偏小、小屏偏大」）。
///
/// 方案（用户决策「A：自动缩放并且可以调整」）：用户设置的字号仍是**基准**，渲染时乘本
/// 因子，使字幕占屏比例在不同屏幕上观感一致；用户的手动基准值不被改写（自动是叠加的乘数、
/// 可调是保留手动基准），故无需额外开关——自动缩放恒开、基准始终可调。
///
/// 因子按**视口短边**相对参考短边 [referenceShortestSide] 线性缩放，并夹在
/// [minFactor, maxFactor] 内防极端（超小 / 超大屏不会把字幕缩没 / 撑爆）：
/// - 用短边（而非宽 / 高）使横竖屏一致：竖屏短边≈宽、横屏短边≈高，都代表「较小的那一维」，
///   是字幕相对屏幕占比的稳定代理；
/// - 参考短边默认 400（约一台手机的短边逻辑像素），故手机附近因子≈1（基准即所见），平板 /
///   桌面短边更大→因子 > 1 放大，超小屏→因子 < 1 缩小。
///
/// 纯函数（页面与测试同源）：[screenSize] 传 `MediaQuery.sizeOf(context)`（逻辑像素、已
/// 折算 DPI）。短边 <= 0（未布局）时返回 1.0（不缩放）。
double subtitleScreenScaleFactor(
  Size screenSize, {
  double referenceShortestSide = 400.0,
  double minFactor = 0.85,
  double maxFactor = 1.6,
}) {
  final double shortest = screenSize.shortestSide;
  if (shortest <= 0 || referenceShortestSide <= 0) return 1.0;
  final double raw = shortest / referenceShortestSide;
  return raw.clamp(minFactor, maxFactor).toDouble();
}

/// 字幕背景盒的**默认底色**（TODO-1059 方案A）：固定半透明黑，而非跟随
/// `ColorScheme.surface`。
///
/// 根因：字幕盒底色此前默认取当前主题 `surface`（[VideoSubtitleStyle.backgroundColor]
/// 为 null 时由页面喂进 `cs.surface`）。浅色主题 `surface` 近白 → 字幕背景变成一块浅色
/// 板，与白色字幕正文对比极低、观感违和（用户报「浅色主题下变浅色背景很违和」）。字幕
/// 背景的语义是「在任意画面上给正文垫一层稳定的暗底提升可读性」，本就该像 ASS/播放器
/// 惯例那样固定暗色、不跟随 App 主题（与固定白字 + 黑描边同源，TODO-051）。
///
/// 只在 `backgroundColor == null`（用户从未显式选过背景色）时生效：显式选过颜色的旧
/// 用户数据（非 null）仍逐字尊重，不被本默认覆盖（Never break userspace）。透明度仍由
/// [VideoSubtitleStyle.backgroundOpacity] 独立控制（0 = 完全无背景）。`0xFF000000`
/// 纯黑，实际可见透明度由 opacity 决定。
const Color kDefaultSubtitleBackgroundColor = Color(0xFF000000);

/// Video subtitle appearance persisted as app preferences.
///
/// The default is a high-contrast caption look: fixed white text with a thick
/// black outline/shadow so it stays readable on any video regardless of the
/// active app theme (TODO-051). Weight and shadow thickness stay nullable so the
/// default thickness can follow the global UI size, while explicit user choices
/// remain fixed. [textColor]/[shadowColor] left null means "follow the theme"
/// (legacy data persisted before TODO-051), resolved via [resolveTextColor] /
/// [resolveShadowColor]. [backgroundColor] left null means "use the fixed
/// [kDefaultSubtitleBackgroundColor] translucent black" (TODO-1059 方案A), NOT
/// the theme surface — so a light theme no longer washes the subtitle box pale.
@immutable
class VideoSubtitleStyle {
  const VideoSubtitleStyle({
    required this.fontSize,
    required this.textColor,
    required this.fontWeight,
    required this.shadowColor,
    required this.shadowThickness,
    required this.backgroundColor,
    required this.backgroundOpacity,
    required this.bottomPadding,
    this.secondaryBottomPadding,
  });

  static const int defaultFontWeight = 700;

  /// 默认阴影/投影**半径**（模糊强度），抄 Niratan（mac 原生日语沉浸 app）字幕默认的
  /// `shadowRadius = 3`（其设置滑杆范围 0..10）。BUG-323 时代这里是 5px「硬描边粗细」；
  /// 现按用户要求改回 Niratan 的柔和投影观感——渲染改为单层高斯 drop shadow（见
  /// [buildSubtitleSoftShadow] 与 [VideoSubtitleOverlay._buildSubtitleChar]），3 就是那层
  /// 软阴影的模糊半径。仍跟随 UI scale（[resolveShadowThickness]）。
  static const double defaultShadowThickness = 3;

  /// v1 持久化时代硬编码的默认阴影粗细（3px）。仅供 [decode] 把 v1 存的该值迁移成 null
  /// （跟随 UI scale）用。用独立字面量与当前 [defaultShadowThickness] 解耦：即便两者当前
  /// 同为 3，语义不同（此值是历史迁移锚点），后续改默认也不破坏旧数据迁移。
  static const double _v1LegacyShadowThickness = 3;

  /// High-contrast caption defaults (TODO-051): 36px bold WHITE text with a soft
  /// translucent-BLACK drop shadow, no box. Fixed white/black instead of theme
  /// colors so subtitles stay legible on any video and don't wash out on
  /// low-contrast themes. [fontWeight]/[shadowThickness] stay null to follow the
  /// global UI scale ([defaultFontWeight] / [defaultShadowThickness] at 1.0).
  ///
  /// [shadowColor] 默认取 `0xE6000000`（黑 @ 0.9 alpha），抄 Niratan 字幕投影
  /// `Color.black.opacity(0.9)`：配合 [defaultShadowThickness]=3 的模糊半径与
  /// [buildSubtitleSoftShadow] 的向下 1px 偏移，得到「字后一层柔和黑影」的观感（不再是
  /// BUG-323 的锐利硬描边）。旧用户显式存的 `0xFF000000` 仍逐字尊重、不被本默认覆盖。
  ///
  /// [bottomPadding] is the user's subtitle position only (default 75). It no
  /// longer bakes in the controls-bar clearance: TODO-129 made the self-drawn
  /// [VideoSubtitleOverlay] dodge the bar *dynamically* — when the controls show
  /// it lifts the subtitle to `max(this position, [kVideoControlsBottomReserve])`
  /// (the progress-bar upper edge) and drops back when they hide (driven by
  /// `controlsVisible`, lower-bound not addition — TODO-161). So the default
  /// stays at the natural 75 and is only nudged just above the progress bar
  /// while it is on screen, instead of being permanently raised (TODO-089) or
  /// lifted over the whole button row (TODO-171). Users who manually pick a
  /// position keep their value verbatim (no "is-manual" branch — it's the same
  /// field; the dynamic dodge takes the lower bound on top of it).
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 36,
    textColor: Color(0xFFFFFFFF),
    fontWeight: null,
    // 黑 @ 0.9 alpha（抄 Niratan `.black.opacity(0.9)`）：柔和投影而非纯黑硬边。
    shadowColor: Color(0xE6000000),
    shadowThickness: null,
    backgroundColor: null,
    backgroundOpacity: 0,
    // 用户位置基线（不含控制条避让）：避让在控制条可见时由 overlay 动态叠加（TODO-129）。
    bottomPadding: 75,
  );

  final double fontSize;
  final Color? textColor;
  final int? fontWeight;
  final Color? shadowColor;
  final double? shadowThickness;
  final Color? backgroundColor;
  final double backgroundOpacity;
  final double bottomPadding;

  /// 副字幕层的**独立**位置基线（距其锚点边的距离；纯 SRT 副字幕强制置顶时即顶距）。
  ///
  /// null = 跟随 [bottomPadding]（历史行为、旧数据零迁移）：此前主副两层共用同一个
  /// [bottomPadding] 字段——主字幕拿它当底距、副字幕（强制置顶）拿它当顶距，调一个
  /// 必然把另一个也拽走，用户没法把主字幕压低同时把副字幕抬高。分成两条基线后，
  /// [VideoSubtitleOverlay] 按层取值（见 `_layerBaseline`），两层各自独立。
  ///
  /// 只有用户真正拖过「副字幕垂直位置」才写具体值；没拖过恒为 null、逐字沿用主字幕
  /// 位置（Never break userspace：老用户外观像素级不变）。
  final double? secondaryBottomPadding;

  VideoSubtitleStyle copyWith({
    double? fontSize,
    Color? textColor,
    int? fontWeight,
    Color? shadowColor,
    double? shadowThickness,
    Color? backgroundColor,
    double? backgroundOpacity,
    double? bottomPadding,
    // null = 不改（保持当前值，含「仍跟随主字幕」的 null 态）。设置面板拖动副字幕位置
    // 时才传具体值；无「改回跟随」的入口，故不需要 backgroundColor 那样的 reset 标志。
    double? secondaryBottomPadding,
    // [backgroundColor] 与 null 语义冲突：`null` 既是「不改」又是「显式清空跟随默认黑」。
    // 用显式 [resetBackgroundColor] 标志区分——true 时把 [backgroundColor] 强制清成 null
    // （回到 [kDefaultSubtitleBackgroundColor] 固定默认），供设置面板「默认（黑）」选项用。
    bool resetBackgroundColor = false,
  }) {
    return VideoSubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      fontWeight: fontWeight ?? this.fontWeight,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowThickness: shadowThickness ?? this.shadowThickness,
      backgroundColor: resetBackgroundColor
          ? null
          : (backgroundColor ?? this.backgroundColor),
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      bottomPadding: bottomPadding ?? this.bottomPadding,
      secondaryBottomPadding:
          secondaryBottomPadding ?? this.secondaryBottomPadding,
    );
  }

  Color resolveTextColor(Color themeColor) => textColor ?? themeColor;
  Color resolveShadowColor(Color themeColor) => shadowColor ?? themeColor;
  Color resolveBackgroundColor(Color themeColor) =>
      backgroundColor ?? themeColor;

  int resolveFontWeight(double uiScale) {
    if (fontWeight != null) return fontWeight!;
    final double scale = _normalizeUiScale(uiScale);
    final int rounded = (defaultFontWeight * scale / 100).round() * 100;
    if (rounded < 100) return 100;
    if (rounded > 900) return 900;
    return rounded;
  }

  double resolveShadowThickness(double uiScale) {
    if (shadowThickness != null) return shadowThickness!;
    return (defaultShadowThickness * _normalizeUiScale(uiScale))
        .clamp(0, 12)
        .toDouble();
  }

  static String encode(VideoSubtitleStyle s) => jsonEncode(<String, dynamic>{
        '_v': 2,
        'fontSize': s.fontSize,
        'textColor': s.textColor?.toARGB32(),
        'fontWeight': s.fontWeight,
        'shadowColor': s.shadowColor?.toARGB32(),
        'shadowThickness': s.shadowThickness,
        'backgroundColor': s.backgroundColor?.toARGB32(),
        'backgroundOpacity': s.backgroundOpacity,
        'bottomPadding': s.bottomPadding,
        // null（从未单独调过副字幕位置）也照写：decode 侧 null → 继续跟随主字幕。
        'secondaryBottomPadding': s.secondaryBottomPadding,
      });

  static VideoSubtitleStyle decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      final int version = d['_v'] is num ? (d['_v'] as num).round() : 1;
      double num2d(Object? v, double fallback) =>
          v is num ? v.toDouble() : fallback;
      int? colorArgb(Object? v) => v is num ? v.toInt() : null;
      int normalizeWeight(Object? v) {
        final int raw = v is num ? v.round() : defaultFontWeight;
        final int rounded = (raw / 100).round() * 100;
        if (rounded < 100) return 100;
        if (rounded > 900) return 900;
        return rounded;
      }

      int? readFontWeight(Object? v) {
        if (v is! num) return null;
        final int normalized = normalizeWeight(v);
        return version < 2 && normalized == defaultFontWeight
            ? null
            : normalized;
      }

      double? readShadowThickness(Object? v) {
        if (v is! num) return null;
        final double normalized = v.toDouble().clamp(0, 12).toDouble();
        // v1 数据存的是当时硬编码的默认阴影粗细（3px）= 「跟随 UI scale」，迁移成 null。
        // 用 v1 时代的字面值对照，而非当前 [defaultShadowThickness]（TODO-051 已改为
        // 5），否则改默认会把老用户的 3px 误当显式值钉死、不再跟随缩放。
        return version < 2 && normalized == _v1LegacyShadowThickness
            ? null
            : normalized;
      }

      // Colors round-trip verbatim: a stored ARGB int is honoured as an explicit
      // choice, a missing/null value stays null = "follow the theme" (legacy
      // data persisted before TODO-051, when defaults were theme-following).
      // White (0xFFFFFFFF) is the new default text color (TODO-051) and must
      // persist as an explicit value — no longer folded back to null.
      final int? argb = colorArgb(d['textColor']);
      final int? shadowArgb = colorArgb(d['shadowColor']);
      final int? backgroundArgb = colorArgb(d['backgroundColor']);
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], defaults.fontSize).clamp(10, 72),
        textColor: argb == null ? null : Color(argb),
        fontWeight: readFontWeight(d['fontWeight']),
        shadowColor: shadowArgb == null ? null : Color(shadowArgb),
        shadowThickness: readShadowThickness(d['shadowThickness']),
        backgroundColor: backgroundArgb == null ? null : Color(backgroundArgb),
        backgroundOpacity: num2d(
          d['backgroundOpacity'],
          defaults.backgroundOpacity,
        ).clamp(0.0, 1.0),
        bottomPadding:
            num2d(d['bottomPadding'], defaults.bottomPadding).clamp(0, 400),
        // 缺字段（旧数据）/ 非数字 → null = 副字幕继续跟随主字幕位置（旧外观不变）。
        secondaryBottomPadding: d['secondaryBottomPadding'] is num
            ? (d['secondaryBottomPadding'] as num)
                .toDouble()
                .clamp(0, 400)
                .toDouble()
            : null,
      );
    } catch (_) {
      return defaults;
    }
  }

  static double _normalizeUiScale(double uiScale) {
    return HibikiAppUiScale.normalize(uiScale);
  }
}

/// 字幕正文的**柔和投影**（抄 Niratan / mac）：把 [thickness]（阴影半径）渲染成**单层**
/// 高斯 drop shadow，挂在正文 fill [Text] 的 `style.shadows` 上（见
/// [VideoSubtitleOverlay._buildSubtitleChar]）。[thickness] <= 0 返回空列表（无投影）。
///
/// 对应 Niratan `SubtitleOverlayView` 的 `.shadow(color: .black.opacity(0.9),
/// radius: shadowRadius, y: 1)`：单个阴影、模糊半径 = [thickness]、向下偏移 1px、
/// 颜色由 [color] 决定（默认 `0xE6000000` = 黑 @ 0.9）。观感是「字后面一团柔和黑影」。
///
/// 为什么用**单层**而非 BUG-222/BUG-323 的 8 层 `Shadow`：那套残留黑字的根因是**8 份**
/// 模糊 glyph 拷贝（`blurRadius=thickness` > 偏移 `thickness/2`）大面积重叠外溢成能看清
/// 字形的第二个黑字。单层 drop shadow（偏移仅 (0,1)、只一份拷贝）不产生这种重叠，是所有
/// 主流播放器（含 Niratan 本身）字幕投影的常规做法——按用户决策换回这套柔和观感（放弃
/// BUG-323 的硬描边）。[color] 是用户/主题阴影色，thickness=模糊强度，0=无投影。
List<Shadow> buildSubtitleSoftShadow(Color color, double thickness) {
  if (thickness <= 0) return const <Shadow>[];
  return <Shadow>[
    Shadow(color: color, blurRadius: thickness, offset: const Offset(0, 1)),
  ];
}

/// 字幕**真描边**画笔（BUG-323 / TODO-569）：把宽度 [thickness] 渲染成沿字形轮廓的单层
/// 描边，由底层 stroke [Text] 用本画笔描出、上层 fill [Text] 填正文（见
/// [VideoSubtitleOverlay._buildSubtitleChar] 的 ASS 尊重分支）。[thickness] <= 0 返回 null。
///
/// 适用范围（TODO-1105 后收窄）：现仅供**「尊重 .ass 自带样式」路径**画 .ass 的 `\bord`/
/// `Outline` 硬描边——那是 .ass 文件明示的描边语义，必须用沿轮廓的真描边忠实还原。**默认
/// 统一外观**已按用户决策改回 Niratan 的柔和投影（[buildSubtitleSoftShadow]），不再走本
/// 描边。保留真描边而非旧的 8 层模糊 `Shadow` 伪描边，是因为后者在大 thickness / 缩放下
/// 会外溢成「残留黑字」（BUG-323 根因，见 [buildSubtitleShadows] 文档）；真描边单层、无
/// 模糊、无偏移拷贝，任何 thickness 只是描边变粗变细，绝不产生第二个错位黑字。
///
/// [color] 是描边色（.ass \3c / OutlineColour），[thickness] = 描边宽（.ass \bord），
/// 0 = 无描边。`strokeJoin/Cap.round` 让转角圆滑，贴合 ASS/asbplayer outline 观感。
Paint? buildSubtitleStrokePaint(Color color, double thickness) {
  if (thickness <= 0) return null;
  return Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = thickness
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = color
    ..isAntiAlias = true;
}

/// 字幕描边阴影：把粗细 [thickness] 渲染成**贴合文字四周的对称描边/光晕**，而非
/// 单向下方的投影（BUG-222）。
///
/// 旧实现是一个 `Shadow(offset: Offset(0, thickness))` 纯向下位移的 drop shadow：
/// thickness 越大阴影越往下「掉」，字幕移动/换句时阴影与字身分离，观感像「阴影没跟住、
/// 总有残留」。字幕该有的是 ASS/asbplayer 式的 **outline**——阴影包住字身四周。
///
/// 做法：八个方向（上下左右 + 四对角）各放一个小偏移阴影，偏移半径取 `thickness/2`
/// （对角乘 ~0.707 归一成圆形描边），`blurRadius=thickness` 让描边软化成贴合字身的
/// 光晕。八向对称 → 合成结果围绕文字、无单向「掉落」感。thickness 仍是用户/缩放控制的
/// 描边强度（0 = 无描边），[color] 仍是用户/主题阴影色，语义不变。
///
/// 历史：字幕**正文**字符早先用本函数的 8 向 `Shadow`（BUG-222），后因大 thickness /
/// 缩放下 8 份模糊 glyph 拷贝外溢成「残留黑字」改成硬描边（BUG-323），现按用户决策再
/// 换成 [buildSubtitleSoftShadow] 的单层柔和投影（抄 Niratan）。本函数仍保留给**收藏星
/// 角标**那枚 [Icon] 用——图标尺寸小、四周对称光晕正合适，不在字幕文字残影范围内。
///
/// [thickness] <= 0 返回空列表（无描边，与旧 `shadowThickness<=0` 分支等价）。
List<Shadow> buildSubtitleShadows(Color color, double thickness) {
  if (thickness <= 0) return const <Shadow>[];
  // 描边偏移半径：thickness 的一半，最小 0.5px 保证薄描边也成形。
  final double r = (thickness / 2).clamp(0.5, double.infinity).toDouble();
  final double diag = r * 0.70710678; // 对角归一成圆形描边（cos45°）。
  const List<({double dx, double dy})> dirs = <({double dx, double dy})>[
    (dx: 1, dy: 0),
    (dx: -1, dy: 0),
    (dx: 0, dy: 1),
    (dx: 0, dy: -1),
    (dx: 1, dy: 1),
    (dx: 1, dy: -1),
    (dx: -1, dy: 1),
    (dx: -1, dy: -1),
  ];
  return <Shadow>[
    for (final ({double dx, double dy}) d in dirs)
      Shadow(
        color: color,
        blurRadius: thickness,
        offset: Offset(
          (d.dx.abs() == d.dy.abs() ? diag : r) * d.dx,
          (d.dx.abs() == d.dy.abs() ? diag : r) * d.dy,
        ),
      ),
  ];
}

/// 视频内顶栏（media_kit 控制条 [topButtonBar]）的外边距（BUG-463）。
///
/// 移动端视频永不进 media_kit 全屏路由（BUG-221），而 fork 的 [MaterialVideoControls]
/// 只在**全屏**分支给顶栏 Column 套 `MediaQuery.padding` 顶部内缩、窗口分支恒
/// `EdgeInsets.zero` → 顶栏按钮永远贴 `y=0`，被状态栏 / 刘海盖住、点不到（用户报「顶栏
/// 的按钮会被挡住」）。本纯函数把系统安全区折成顶栏 margin：
/// - `top`：由 [systemBarsVisible] 门控，系统栏真实可见时取 [systemViewPadding].top，
///   隐栏时归零，避免 iOS 横竖屏切换 / 系统栏临时显隐期间残留的 `padding.top`
///   过渡值把顶栏偶发下压。
/// - `left` / `right`：与浮动侧栏 `_mergeRailSafeAreaPadding` 同款逐边取 `max(16, inset)`
///   ——横屏短边刘海下顶栏左 / 右按钮也避开 cutout，又不在无刘海时把默认 16 叠成双重留白。
///
/// 调用方同时传 `MediaQuery.padding` 与 `MediaQuery.viewPadding`：top 与底栏
/// `_videoBottomSystemInset` 一样由系统栏真实可见性决定；左右 cutout 则用更稳定的
/// viewPadding 与 padding 逐边取 max。
EdgeInsets videoTopBarMargin({
  required EdgeInsets systemPadding,
  required EdgeInsets systemViewPadding,
  required bool systemBarsVisible,
}) {
  return EdgeInsets.only(
    left: math.max(16.0, math.max(systemPadding.left, systemViewPadding.left)),
    right:
        math.max(16.0, math.max(systemPadding.right, systemViewPadding.right)),
    top: systemBarsVisible ? systemViewPadding.top : 0.0,
  );
}
