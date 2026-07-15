import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HardwareKeyboard;

import 'package:hibiki/src/media/video/subtitle_pos_mapping.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 命中字幕某字符的结果：整条字幕、被点 grapheme 下标、该字符的全局屏幕矩形。
/// 与 [VideoSubtitleOverlay.onCharTap] 的回调三元组同构。
typedef SubtitleCharHit = ({String sentence, int graphemeIndex, Rect charRect});

/// 给上层（查词浮层的 dismiss barrier）按全局坐标反查「点到的是哪个字幕字符」用的
/// 句柄。[VideoSubtitleOverlay] 在 build 时把自己的命中实现绑进来；上层持有同一个
/// 句柄对象、调 [hitTest]。常驻句柄、最近一次 build 的 overlay 覆盖绑定（全屏复用
/// 同一字幕 overlay 组件，故全屏路由会重新绑定其命中实现）。
///
/// 存在动机：查词浮层打开时，根 Overlay 的全屏 dismiss barrier 盖在字幕之上、会吞掉
/// 点击 → 点同句第二个词只会关栈+恢复播放，查不了第二个词。让 barrier 先用本句柄反查
/// 是否点到了字幕字符，是则切换查词（保持暂停），否则才 dismiss。
class VideoSubtitleHitTester {
  SubtitleCharHit? Function(Offset globalPos)? _impl;

  void bindHitTest(SubtitleCharHit? Function(Offset globalPos) impl) =>
      _impl = impl;

  SubtitleCharHit? hitTest(Offset globalPos) => _impl?.call(globalPos);
}

/// 按全局坐标在一组字符屏幕矩形里反查命中的字符下标（纯函数，可测）。
///
/// TODO-916 症状④：字幕字符之间有 [Wrap] 间隙 + 描边层不计入命中盒，落在字缝/描边
/// 外缘的点用「精确 [Rect.contains]」会全 miss、查不到词。两段判据消除 miss：
/// 1. 先精确包含：命中第一个 `contains(point)` 的字符（旧行为，零容差时等价）。
/// 2. 未命中则取**距点击点最近**的字符，且仅当该点落在该字符的兜底容差区内才采纳。
///
/// 容差**方向感知**（BUG-825）：字缝在**水平**方向（同一行字符间的 [Wrap] 间隙），
/// 描边只是四周薄薄一圈。故容差用椭圆而非各向同性圆——
/// - 水平半轴 [minTolerance]/半字宽取大：跨字缝兜底（TODO-916/971，36px 字半字宽≈18px）；
/// - 垂直半轴 [edgeTolerance] 只放描边级几像素：字身外上下只需覆盖描边外缘。
///
/// 旧实现用各向同性容差 `clamp(半字宽, 10px, ∞)`，把**水平**半字宽（≈18px）原样用到
/// **垂直向下**，会向下溢出盖住紧贴字幕下方的视频进度条（seek bar）——用户 tap 进度条
/// 顶部一条带时被顶层字幕识别器赢走竞技场，暂停视频 + 弹查词、seek 被吞（BUG-825）。
/// 垂直方向本就不该放半字宽的裙边。
///
/// [Rect.zero]（无 RenderBox 的字符）跳过。无任何有效矩形或全部超容差时返回 -1。
@visibleForTesting
int resolveSubtitleCharHit(
  List<Rect> charRects,
  Offset point, {
  // TODO-971：手指比 6px 宽，旧 6.0 下手机字幕点词常落在字缝/描边外缘 miss。
  // 放宽到 10.0，字缝/描边一字之内更易兜底命中（仍夹半字宽，不跨到隔壁字）。
  double minTolerance = 10.0,
  // BUG-825：垂直兜底半轴。字身外上下只需覆盖描边外缘（默认软阴影半径 3px + 手指余量），
  // 远小于水平半字宽——避免向下溢出到紧贴字幕下方的进度条轨道。
  double edgeTolerance = 6.0,
}) {
  // 第一段：精确包含。
  for (int i = 0; i < charRects.length; i++) {
    final Rect r = charRects[i];
    if (r == Rect.zero) continue;
    if (r.contains(point)) return i;
  }
  // 第二段：最近字符兜底（在该字符的方向感知椭圆容差区内）。
  int bestIndex = -1;
  double bestDistance = double.infinity;
  for (int i = 0; i < charRects.length; i++) {
    final Rect r = charRects[i];
    if (r == Rect.zero) continue;
    final double dx = (point.dx.clamp(r.left, r.right)) - point.dx;
    final double dy = (point.dy.clamp(r.top, r.bottom)) - point.dy;
    // 用欧氏距离在多个候选里选**最近**的（水平相邻字符的取舍与旧行为一致）。
    final double distance = (dx * dx + dy * dy);
    if (distance >= bestDistance) continue;
    // 椭圆判据：水平半轴放宽跨字缝、垂直半轴收紧只覆盖描边（BUG-825）。
    final double toleranceX =
        (r.width / 2).clamp(minTolerance, double.infinity).toDouble();
    final double nx = dx / toleranceX;
    final double ny = dy / edgeTolerance;
    if (nx * nx + ny * ny <= 1.0) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

/// libass 把 ASS `\blur` 值换算成高斯半径时乘的常数 `2 / sqrt(ln 256)`（≈0.8493）。见
/// libass `ass_render.c`：`blur_radius_scale = 2 / sqrt(log(256))`，最终下发给高斯的半径 =
/// `\blur 值 × (显示/PlayRes 缩放) × blur_radius_scale`。**ASS 的 `\blur` 数值不是直接的高斯
/// sigma**——少了这个因子就比 mpv/libass 明显偏糊（约 1/0.8493 ≈ 1.18×）。
final double kLibassBlurRadiusScale = 2 / math.sqrt(math.log(256));

/// 把 ASS `\blur` 值 [blurValue] 换算成 Flutter 高斯模糊 sigma（逻辑像素），对齐 libass/mpv：
/// `sigma = blurValue × [assFontScale]（显示区高 / PlayResY）× [kLibassBlurRadiusScale]`，
/// 再夹到 [0, 24]（防 PlayResY 异常时糊爆）。纯函数，overlay 渲染与单测共享真相源。
///
/// 此前 overlay 漏乘 [kLibassBlurRadiusScale]，把 `\blur` 值当 sigma 直接 × 缩放，导致比
/// mpv 明显偏糊（用户报「一条清晰一条发虚」的发虚那条来自字幕自带 `\blur4`，且比 mpv 更糊）。
@visibleForTesting
double assBlurValueToSigma(double blurValue, double assFontScale) {
  final double sigma = blurValue * assFontScale * kLibassBlurRadiusScale;
  return sigma < 0 ? 0 : (sigma > 24 ? 24 : sigma);
}

/// 视频底部当前句字幕 overlay；监听 [VideoPlayerController.currentCue]。
///
/// 字幕逐字符可点击：点击第 [int] 个 grapheme 时回调
/// `(sentence, graphemeIndex, charRect)`，调用方据此从该位置起取词查词（最长匹配
/// 交给 HoshiDicts），并用 [charRect]（被点字符的全局屏幕矩形）把查词浮层定位到
/// 字符附近。非字符区域不拦截指针，让底层 media_kit 控制（点击显隐控制条）正常工作。
///
/// [blurEnabled] 为听力沉浸模式：字幕默认打码（[ImageFiltered] 高斯模糊），桌面悬停
/// （[MouseRegion]）或移动端点击右上角「显形」热区后变清晰，再次移开/点击恢复。
/// 默认关闭，关闭时与历史外观完全一致。
class VideoSubtitleOverlay extends StatefulWidget {
  const VideoSubtitleOverlay({
    required this.controller,
    this.onCharTap,
    this.onCharHover,
    this.hoverAutoLookupEnabled = false,
    this.onHoverChanged,
    this.hitTester,
    this.isCueFavorited,
    this.blurEnabled = false,
    this.subtitleHidden = false,
    this.fontSize = 36,
    this.textColor,
    this.fontWeight = VideoSubtitleStyle.defaultFontWeight,
    this.shadowColor,
    this.shadowThickness = VideoSubtitleStyle.defaultShadowThickness,
    this.backgroundColor,
    this.backgroundOpacity = 0,
    this.bottomPadding = 75,
    this.controlsVisible,
    this.controlsBottomReserve = kVideoControlsBottomReserve,
    this.fontFamily,
    this.respectAssStyle = false,
    super.key,
  });

  final VideoPlayerController controller;

  /// 点击字幕第 [graphemeIndex] 个字符时回调，[sentence] 为整条字幕文本，
  /// [charRect] 为被点字符在全局坐标系下的矩形（弹窗定位用）。
  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharTap;

  /// 桌面 Shift-鼠标悬停查词（TODO-756a，与阅读器 `onShiftHover` 同语义）。按住 Shift 时鼠标
  /// 在字幕字符上移动即回调 `(sentence, graphemeIndex, charRect)`——与 [onCharTap] **同一条
  /// 查词链路**（页面侧都走 `_handleSubtitleLookupTap` → `_lookupAt`），故点击查词与 Shift-悬停
  /// 查词行为一致、零重写。命中节流（8px 阈值 + 同一字符不重复触发）由本组件内部承载，避免每帧
  /// hover 都查词。非 Shift 悬停 / 模糊态 / 空句不触发（与点击不查词一致）。null（移动端 / 测试 /
  /// 无控制条场景）= 不挂 Shift-悬停通道，外观与历史一致。
  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharHover;

  /// TODO-756b：是否“鼠标悬停即自动查词”。true 时 [_handleShiftHover] 不再要求按住
  /// Shift，纯悬停划过字幕字符即经 [onCharHover] 查词；false 时退回 756a 的
  /// Shift+悬停门控。由页面侧从 `ReaderHibikiSource.instance.hoverAutoLookup` 传入。
  /// 移动端无 OS hover，本标志为何值都不产生 hover 事件、自然不触发。
  final bool hoverAutoLookupEnabled;

  /// 鼠标进 / 出**字幕盒本身**（非整片视频区）时回调（BUG-283）。桌面用：字幕盒覆盖在
  /// media_kit 控制条之上，鼠标停字幕上读字 / 查词时，media_kit 控制条 2s 自动隐藏会让
  /// 画面光标被 `hideMouseOnControlsRemoval` 隐藏（用户报「鼠标放字幕上消失」）。页面据
  /// 本回调在 hover 字幕时唤回光标 + 续命控制条。null（测试 / 有声书 / 无控制条）= 不挂。
  final void Function(bool hovering)? onHoverChanged;

  /// 可选的字符命中句柄：build 时把按全局坐标反查字符的实现绑进来，供查词浮层的
  /// dismiss barrier「点同句换词保持暂停」用（见 [VideoSubtitleHitTester]）。
  final VideoSubtitleHitTester? hitTester;

  /// 当前字幕句是否已收藏（TODO-301 / BUG-264）。非 null 时，当前句已收藏会在字幕盒
  /// 起始处显示一枚实心星标记（与字幕列表行的收藏标记同语义）。null（测试 / 有声书等
  /// 无收藏数据源场景）= 不显示标记，外观与历史像素级一致。
  final bool Function(AudioCue cue)? isCueFavorited;

  /// 听力沉浸：字幕默认模糊，悬停/点击显形。
  final bool blurEnabled;

  /// 遮蔽模式「隐藏」（TODO-840 Part B）：为 true 时主字幕整条不渲染（即时返回空盒），
  /// 与 [blurEnabled] 正交且优先级更高（两者来自互斥的 [VideoSubtitleObscureMode]，
  /// 页面侧映射保证不会同时为 true，但即便同时为 true 也以隐藏为准）。默认 false =
  /// 不隐藏，外观与历史一致。隐藏只针对底部主字幕 overlay，不影响查词 / 字幕列表 /
  /// cue 同步等其它文本通道。
  final bool subtitleHidden;

  /// 字幕字号（外观设置）。
  final double fontSize;

  /// 字幕文字颜色（外观设置）。
  final Color? textColor;

  /// 字幕字重（CSS numeric weight 100..900；asbplayer 默认 700）。
  final int fontWeight;

  /// 字幕阴影颜色。
  final Color? shadowColor;

  /// 字幕阴影粗细；asbplayer 默认 3px。
  final double shadowThickness;

  /// 字幕背景颜色。
  final Color? backgroundColor;

  /// 字幕背景不透明度 0..1（外观设置；历史值 0.54 = Colors.black54）。
  final double backgroundOpacity;

  /// 字幕距底部的**用户位置**（外观设置）。控制条避让不含在此值里——TODO-129 起由
  /// [controlsVisible] 在控制条可见时对 [controlsBottomReserve] 取下限（max），此处只是
  /// 用户手选的基线位置。
  final double bottomPadding;

  /// media_kit 控制条当前是否可见（TODO-129/161）。非 null 时驱动字幕动态避让：可见时
  /// 字幕底部 padding 取 `max([bottomPadding], [controlsBottomReserve])`（字幕底缘骑到
  /// 控制条顶、躲开进度条），隐藏时落回 [bottomPadding] 基线（[AnimatedPadding] 平滑过渡）。
  /// 取下限而非加法：基线 < 控制条高时不会被顶飞、手选高位也不被改写。null（默认、测试、
  /// 有声书等无控制条场景）= 不避让，字幕恒贴 [bottomPadding] 基线（旧行为）。
  final ValueListenable<bool>? controlsVisible;

  /// 控制条可见时字幕底缘对其取下限的避让高度 = 底部控制条**进度条上缘**距视频底边的
  /// 高度。仅在 [controlsVisible] 非 null 时生效；基线 ≥ 本值则避让不抬（取基线）。
  ///
  /// 默认 [kVideoControlsBottomReserve]=56（桌面进度条骑按钮行上沿那一条，约一个按钮行
  /// 高，TODO-171/BUG-228；也是测试 / 无控制条场景的兜底）。视频页**显式传入**按平台真实
  /// 控制条几何加总 + 随界面缩放的值（`videoSubtitleControlsReserve`，BUG-238）：移动端
  /// 进度条被抬到按钮行上方，上缘 ≈140×缩放 > 默认基线 75，故取下限 `max(75,140)` 才真正
  /// 抬升盖过进度条；否则常量 56 < 75 → `max(75,56)=75` 把字幕留在进度条下面被遮。
  final double controlsBottomReserve;

  /// 字幕字体。传 null 时走平台默认；视频页传 app-wide reader custom font。
  final String? fontFamily;

  /// 是否尊重 .ass 字幕自带样式（TODO-1105）。为 true 时，字体名 / 主色 / 字号 / 描边色 /
  /// 描边宽 / 阴影色 / 阴影深度优先取 markup 里 ASS 解析出的值（行内 {...} 覆盖 > [V4+ Styles]
  /// cue 默认），缺失才回退用户统一样式（[fontFamily] / [textColor] / [fontSize] /
  /// [shadowColor] / [shadowThickness]）。为 false 时（默认）全部走 widget.* 统一样式，与历史
  /// 外观像素级一致（仅行内 \i \b \u \s \c \fs 这些旧就支持的 span 样式照旧生效——那是本开关
  /// 出现前既有行为、不受影响）。
  final bool respectAssStyle;

  /// 听力沉浸「模糊态」的高斯模糊 sigma（逻辑像素）。以前是硬编码 8——一个只对默认字号
  /// 36 勉强够用的绝对值（8/36≈0.22×字宽），用户把字幕字号调大后同样的 8px 相对字形就
  /// 太浅、字还读得清（用户报「模糊度不够」）。字幕遮蔽的本意是**让人读不出**（只在悬停/
  /// 点击时显形），故模糊强度必须随字号同构缩放而非固定绝对像素：sigma = fontSize×0.45，
  /// 并取下限 12 保证小字号也真正糊掉。默认 36 → 16.2（约旧值两倍），60 → 27。纯函数、
  /// 无副作用，供守卫测试直接钉不变式。
  @visibleForTesting
  static double obscureBlurSigma(double fontSize) {
    const double ratio = 0.45;
    const double minSigma = 12;
    final double scaled = fontSize * ratio;
    return scaled < minSigma ? minSigma : scaled;
  }

  @override
  State<VideoSubtitleOverlay> createState() => _VideoSubtitleOverlayState();
}

/// 字幕文字的 CJK 日文字体回退链（TODO-088）。
///
/// 字幕逐字符渲染成独立 [Text]，每个 [Text] 单独做字体选择。当主字体（用户在
/// TODO-049 设的 app 自定义字体，或某平台默认字体）不含某个字形时，缺失这条统一
/// 回退链就会让每个字符各自落到「引擎默认 fallback」——相邻字符可能挑到不同字体，
/// 单字（典型如假名「の」）字形与周围突兀不一致。
///
/// 这里给出覆盖五个出包平台主流系统日文字体的有序列表。Flutter 引擎按顺序解析、
/// 自动跳过当前平台不存在的字体名，故无需平台分支：
/// - Windows：`Yu Gothic` / `Yu Gothic UI` / `Meiryo` / `MS Gothic`
/// - macOS / iOS：`Hiragino Sans` / `Hiragino Kaku Gothic ProN`
/// - Android / Linux：`Noto Sans CJK JP` / `Noto Sans JP`
const List<String> _kSubtitleCjkFallback = <String>[
  'Yu Gothic',
  'Yu Gothic UI',
  'Hiragino Sans',
  'Hiragino Kaku Gothic ProN',
  'Noto Sans CJK JP',
  'Noto Sans JP',
  'Meiryo',
  'MS Gothic',
];

class _VideoSubtitleOverlayState extends State<VideoSubtitleOverlay>
    with SingleTickerProviderStateMixin {
  bool _revealed = false;

  /// `\fad`/`\fade` 淡入淡出逐帧刷新驱动（TODO-1373）：活动集里有带 fade 的 cue（且开
  /// respectAssStyle）时启动，每帧 setState 重读 [VideoPlayerController.effectivePositionMs]
  /// 重算各 cue 不透明度；否则停掉，避免无谓逐帧重建。读真实播放位置，故暂停 / 变速 / seek
  /// 天然同步、无需额外门控。
  Ticker? _fadeTicker;

  /// TODO-1312：当前帧渲染的所有字幕字符登记表（每帧 build 重建）。主字幕活动集（重叠
  /// cue 多个字幕盒）+ 副字幕活动集的**每个字符**各登记一条，携带所属整条 cue 文本、在该
  /// cue 内的 grapheme 下标、字符 context（求全局矩形）、及该字符所在层是否模糊。命中反查
  /// （[_hitEntryIndexAt] / [_charHitTest]）扫全表，故点主字幕 / 副字幕 / 重叠某条都能查到
  /// 正确的整句 + grapheme。旧的一维 `_charContexts`（单 cue、下标==grapheme）升级为二维。
  final List<_SubtitleCharEntry> _charEntries = <_SubtitleCharEntry>[];

  /// TODO-1372/BUG-698：跨帧的组内槽位表——「层前缀|分组键」→ 槽位列表（**锚点侧在前**：
  /// 底部锚组 slot0 是贴底那格，顶部/中部锚组 slot0 是贴锚那格）。
  ///
  /// 不变量（libass「Collisions: Normal」碰撞语义的槽位版）：**已在屏的 cue 在其可见期内
  /// 槽位不变**，活动集增减不移动任何在屏字幕：
  /// - 新进 cue 先补最靠锚点的空槽，没有才追加到远端（不挤动已有 cue）；
  /// - cue 离场后，若远端仍有在屏 cue，其槽保留为**隐形占位**（保高度撑住别人的槽位）；
  ///   远端空槽（不撑任何人）立即裁掉；
  /// - 组内全部离场 → 状态清除（[build] 按当前活动集清扫），下一条回到锚点侧基线。
  ///
  /// 旧实现按活动集顺序直接塞 Column：重叠窗口内 cue 进出时贴锚格归属随集合翻转——底部组
  /// 新 cue 抢贴底格把在屏 cue 顶上去、顶部组前一条离场后一条补位上跳，正是「两个字幕同时
  /// 存在就时不时跳一下」的机制。
  final Map<String, List<_GroupSlot>> _groupSlots =
      <String, List<_GroupSlot>>{};

  /// 最近一次 build 的字幕显示区高度（本 widget 的 LayoutBuilder 记录），供
  /// [_styleForGrapheme] 把 ASS 绝对字号 / 阴影深度按 显示区高 / PlayResY 缩放
  /// （TODO-1246）。在 LayoutBuilder builder 里赋值，早于 box 内各字符 Builder 回调
  /// 求值（同帧生效）。null=尚未布局，缩放退回 1.0。
  double? _lastLayoutHeight;

  /// 最近一次 build 的字幕显示区宽度（与 [_lastLayoutHeight] 同处记录），供
  /// [_scaledMarginX] 把 ASS `MarginL`/`MarginR` 按 显示区宽 / PlayResX 缩放成水平边距。
  double? _lastLayoutWidth;

  /// 最近一次 build 的 fit:contain **视频内容矩形**高/宽（BUG-820，与 \pos 定位的
  /// [mapPosFractionToContainer] 同一几何）。ASS 字号/描边/阴影/边距的缩放基准优先用
  /// 它（mpv/libass 锚定视频帧显示尺寸）；null（首帧未解出分辨率）回退容器宽高。
  double? _lastVideoContentHeight;
  double? _lastVideoContentWidth;

  /// TODO-916 症状④-A（down-snap）：onTapDown 时刻 [_hitEntryIndexAt] 命中的**登记表下标**
  /// （非 grapheme——二维登记后同一 grapheme 下标可能属不同 cue，故锁扁平 entry 下标），
  /// onTapUp 用它经 [_charHitByEntryIndex] 查词，使命中锁定按下时刻（字幕盒尚未被控制条避让
  /// 动画推移），而非 up 时刻的实时反查。-1 表示按下未命中字符。
  int _pendingTapEntry = -1;

  /// Shift-悬停查词的移动节流阈值（像素，TODO-756a）。与阅读器 `webview.part.dart` 的
  /// `dx*dx+dy*dy < 64`（8px）同构：鼠标移动距离平方未超 64 时不重新命中查词。
  static const double _kShiftHoverThresholdPx = 8;

  /// Shift-悬停查词节流状态（TODO-756a，与阅读器 8px 阈值同构）：上次触发查词的全局 hover
  /// 位置与命中的**登记表下标**。鼠标移动未超 [_kShiftHoverThresholdPx]、或仍落在同一字符上
  /// 时不重复查词（避免每帧 hover 都查），命中新字符或越过阈值才再次触发。`松开 Shift` /
  /// 离开字幕在 [_handleShiftHover] 里复位为 [Offset.zero] / -1，使下次按 Shift 重新进入即触发。
  Offset _lastShiftHoverPos = Offset.zero;
  int _lastShiftHoverEntry = -1;

  /// TODO-1312：按全局坐标在**全部**已渲染字幕字符（主字幕活动集含重叠 cue + 副字幕
  /// 活动集）里反查命中的登记表下标；模糊层字符按 [Rect.zero] 跳过（不参与命中，与点击
  /// 行为一致：模糊时不查词）。无命中返回 -1。是 [_charHitTest] / 竞技场门控 / 悬停查词
  /// 的共享命中内核。
  int _hitEntryIndexAt(Offset globalPos) {
    if (_charEntries.isEmpty) return -1;
    final List<Rect> rects = <Rect>[
      for (final _SubtitleCharEntry e in _charEntries)
        e.blurred ? Rect.zero : _globalRectOf(e.context),
    ];
    return resolveSubtitleCharHit(rects, globalPos);
  }

  /// 按全局坐标反查命中的字幕字符，返回其**所属整条 cue 文本** + 该 cue 内 grapheme 下标
  /// + 字符全局矩形。模糊 / 空 / 无命中返回 null。供 [VideoSubtitleHitTester] 绑定，
  /// 二维登记后点主字幕 / 副字幕 / 重叠某条都能查到正确的整句（TODO-1312）。
  SubtitleCharHit? _charHitTest(Offset globalPos) {
    final int i = _hitEntryIndexAt(globalPos);
    if (i < 0) return null;
    final _SubtitleCharEntry e = _charEntries[i];
    return (
      sentence: e.sentence,
      graphemeIndex: e.graphemeIndex,
      charRect: _globalRectOf(e.context),
    );
  }

  /// 按已知**登记表下标**取命中三元组（TODO-916 症状④-A 的 down-snap 用）：down 时刻已
  /// 经 [_hitEntryIndexAt] 确定命中的 entry 下标，up 时刻直接用该下标重算当前字符矩形即可，
  /// **不再**用 up 时刻的点重新反查——这样即便 down 唤起控制条致字幕盒在 down→up 间被避让
  /// 动画上移，命中仍锁定按下瞄准的那个字符。下标越界 / 模糊字符返回 null。
  SubtitleCharHit? _charHitByEntryIndex(int entryIndex) {
    if (entryIndex < 0 || entryIndex >= _charEntries.length) return null;
    final _SubtitleCharEntry e = _charEntries[entryIndex];
    if (e.blurred) return null;
    final Rect r = _globalRectOf(e.context);
    return (
      sentence: e.sentence,
      graphemeIndex: e.graphemeIndex,
      charRect: r,
    );
  }

  /// 桌面 Shift-鼠标悬停查词（TODO-756a）。仅在 [VideoSubtitleOverlay.onCharHover] 注册时由
  /// [MouseRegion.onHover] 调；语义与阅读器 `onShiftHover`（`webview.part.dart`）一致：
  /// 按住 Shift 在字幕字符上移动即对命中字符走查词。移动端无 OS hover、自然不触发。
  ///
  /// 节流（与阅读器 8px 阈值同构，避免每帧 hover 都查词）：
  /// - 未按 Shift：复位节流锚（[Offset.zero] / -1），下次按 Shift 进入即触发，并直接返回；
  /// - 按住 Shift 但移动距离平方 < [_kShiftHoverThresholdPx]² 且仍落在同一字符上：跳过（不重复查词）；
  /// - 越过阈值或命中新字符：刷新锚并经 [VideoSubtitleOverlay.onCharHover] 触发查词（页面侧
  ///   与点击查词同链路 `_handleSubtitleLookupTap` → `_lookupAt`）。
  ///
  /// 命中复用 [_charHitTest]（模糊态 / 空句返回 null → 不查词，与点击一致）。[PointerHoverEvent]
  /// 的 `position` 已是全局坐标，与 [_charHitTest] 的全局命中契约一致。
  void _handleShiftHover(PointerHoverEvent event) {
    final void Function(String, int, Rect)? onCharHover = widget.onCharHover;
    if (onCharHover == null) return;
    // TODO-756b：开了“悬停即查词”则纯悬停即触发，无需 Shift；否则退回 756a 的
    // Shift 门控。两路都共用同一节流锚与命中链路（onCharHover），仅门控判据不同。
    if (!widget.hoverAutoLookupEnabled &&
        !HardwareKeyboard.instance.isShiftPressed) {
      // 未开“悬停即查词”且未按 Shift：复位节流锚，使下次按 Shift 重新进入即触发
      // （不被旧锚误判为同位置）。
      _lastShiftHoverPos = Offset.zero;
      _lastShiftHoverEntry = -1;
      return;
    }
    final int entryIndex = _hitEntryIndexAt(event.position);
    if (entryIndex < 0) return;
    final _SubtitleCharEntry e = _charEntries[entryIndex];
    // 同一字符（同一登记表下标）+ 未越过移动阈值 → 不重复触发（节流）。命中新字符立即放行
    // （即使移动很小，也应换词查词，与阅读器逐字符 hover 一致）。
    final double dx = event.position.dx - _lastShiftHoverPos.dx;
    final double dy = event.position.dy - _lastShiftHoverPos.dy;
    final bool sameEntry = entryIndex == _lastShiftHoverEntry;
    if (sameEntry &&
        dx * dx + dy * dy < _kShiftHoverThresholdPx * _kShiftHoverThresholdPx) {
      return;
    }
    _lastShiftHoverPos = event.position;
    _lastShiftHoverEntry = entryIndex;
    onCharHover(e.sentence, e.graphemeIndex, _globalRectOf(e.context));
  }

  @override
  void initState() {
    super.initState();
    _fadeTicker = createTicker((_) {
      // 每帧强制重建：build 里按最新播放位置重算各 cue 的 fade 不透明度（值来自
      // controller，不在此保存，故空 setState 足矣）。
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    // 停并释放 ticker：SingleTickerProviderStateMixin.dispose 会断言 ticker 不再 active，
    // 故必须在 super.dispose 之前 dispose 掉它（dispose 内部会取消在途 tick）。
    _fadeTicker?.dispose();
    super.dispose();
  }

  /// 按当前活动集是否需要淡变动画幂等启停 [_fadeTicker]。build 期间调用安全：start 只是
  /// 排下一帧回调、stop 立即止。
  void _syncFadeTicker(bool needed) {
    final Ticker? ticker = _fadeTicker;
    if (ticker == null) return;
    if (needed && !ticker.isActive) {
      ticker.start();
    } else if (!needed && ticker.isActive) {
      ticker.stop();
    }
  }

  @override
  void didUpdateWidget(VideoSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关闭模糊时重置显形态，避免下次开启残留。
    if (!widget.blurEnabled && _revealed) _revealed = false;
  }

  void _setRevealed(bool v) {
    if (_revealed == v) return;
    setState(() => _revealed = v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, _) {
        // 每帧重置字符登记表并（重新）绑定命中句柄——空句也要绑定，使浮层打开但当前无字幕
        // 时 hitTest 返回 null（barrier 走 dismiss）。TODO-1312：登记表二维（主 + 副字幕）。
        _charEntries.clear();
        widget.hitTester?.bindHitTest(_charHitTest);

        // 主字幕活动集（重叠 cue 全渲染，TODO-1312）。遮蔽模式「隐藏」时主层不渲染
        // （TODO-840 Part B）——只影响底部主字幕，不影响副字幕 / 查词 / 字幕列表。
        final List<AudioCue> mainCues = widget.subtitleHidden
            ? const <AudioCue>[]
            : widget.controller.activeCues;
        // 副字幕活动集（TODO-1312：并入 Flutter overlay 多层渲染、可查词）。
        final List<AudioCue> secondaryCues =
            widget.controller.secondaryActiveCues;

        // TODO-1372/BUG-698：清扫「组内已无任何在屏 cue」的槽位状态——整组离场即重置，
        // 下一条从锚点侧基线重新开始；同一活动集重复 build 幂等。放在空集早退之前，
        // 保证 gap 帧也把状态清干净。
        final Set<AudioCue> allActive = HashSet<AudioCue>.identity()
          ..addAll(mainCues)
          ..addAll(secondaryCues);
        _groupSlots.removeWhere((String key, List<_GroupSlot> slots) =>
            !slots.any((_GroupSlot s) => allActive.contains(s.cue)));

        // 逐帧 ticker：活动集里有随播放位置变化的 ASS 动画（\fad 淡变 TODO-1373 / \move 运动
        // / \t 缩放动画 TODO-1374）且开 respectAssStyle 时启动，让各 cue 每帧按最新位置重算；
        // 否则停掉（省重建）。静态 \frz 旋转 / 静态 \fscx\fscy 缩放不需 ticker（不随时间变）。
        _syncFadeTicker(widget.respectAssStyle &&
            allActive.any((AudioCue c) {
              final SubtitleMarkup? m = c.markup;
              return m?.fade != null ||
                  m?.move != null ||
                  (m?.scale?.isAnimated ?? false);
            }));

        if (mainCues.isEmpty && secondaryCues.isEmpty) {
          return const SizedBox.shrink();
        }

        // 副字幕层放画面顶部（翻译参考，不夺主字幕位置）；主字幕层按 markup 锚点 / pos。
        // 二者几何不重叠。单层时直接返回该层（无 Stack 包裹），保持历史单字幕盒几何。
        final List<Widget> layers = <Widget>[
          if (secondaryCues.isNotEmpty)
            _buildSubtitleLayer(context, secondaryCues, isSecondary: true),
          if (mainCues.isNotEmpty)
            _buildSubtitleLayer(context, mainCues, isSecondary: false),
        ];
        if (layers.length == 1) return layers.single;
        return Stack(
          children: <Widget>[
            for (final Widget layer in layers) Positioned.fill(child: layer),
          ],
        );
      },
    );
  }

  /// TODO-1312 / TODO-1341：渲染一「层」字幕（主字幕或副字幕）。
  ///
  /// 主字幕层可能同时有多条时间重叠、但**锚点各异**的 cue（如 OP/ED 的顶部 \an8 歌词与
  /// 底部 \an2 对白同时在屏）。旧实现把整层所有活动 cue 塞进**一个** [Column]、再用单一
  /// 「代表」cue（currentCue）的 pos/anchor 定位——两条锚点不同的字幕于是被裹挟到同一处，
  /// 且代表 cue 随播放位置在两条间翻转时整列在顶 / 底来回跳（TODO-1341 根因）。
  ///
  /// 修复：按各自 markup 的 \pos / \an 锚点**分组**——同锚点的 cue 竖排堆叠进一个字幕盒，
  /// 不同锚点的 cue 各自独立定位（[Stack] 叠放），两条字幕**各就各位**、不再来回跳。每条
  /// cue 仍用**自己的** markup 逐字符描边 / 上色（双轨样式独立，各遵自带样式，TODO-1246）。
  ///
  /// [isSecondary]：副字幕层——强制置顶（画面顶部）、不吃自带 pos/anchor、不模糊、不显
  /// 收藏角标（副字幕=纯翻译参考），全部 cue 归一到一个顶部盒；但仍逐字符可查词（登记进
  /// 同一 [_charEntries]）。单组 / 单 cue 时结构退化为单字幕盒，与历史几何等价。
  Widget _buildSubtitleLayer(
    BuildContext context,
    List<AudioCue> cues, {
    required bool isSecondary,
  }) {
    // 听力沉浸模糊只主层、只播放中生效（暂停 / 查词时清晰，BUG-199；副字幕不模糊）。
    final bool blurred = !isSecondary &&
        widget.blurEnabled &&
        !_revealed &&
        widget.controller.isPlaying;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size container = constraints.biggest;
        // TODO-1246：记录显示区高度，供 _styleForGrapheme 缩放 ASS 绝对字号 / 阴影。
        // 本 builder 早于层内字符 Builder 回调求值，故同帧写入即可被读到。
        _lastLayoutHeight = container.height;
        _lastLayoutWidth = container.width;
        // BUG-820：字号/描边/边距的缩放基准是 fit:contain 后**视频内容矩形**（与 \pos
        // 定位的 [mapPosFractionToContainer] 同一几何），不是容器——窗口比≠视频比
        // （letterbox/pillarbox）时容器高大于视频显示高，按容器缩放整体偏大、与 mpv
        // 不齐。首帧未解出（分辨率未知）为 null，_assFontScale 回退容器（历史行为）。
        final int? videoW = widget.controller.videoWidth;
        final int? videoH = widget.controller.videoHeight;
        final Size? videoContent = (videoW != null && videoH != null)
            ? fitVideoContentSize(videoW, videoH, container)
            : null;
        _lastVideoContentHeight = videoContent?.height;
        _lastVideoContentWidth = videoContent?.width;

        // 按 \pos / \an / MarginV 分组：主、副字幕都按各自位置分组（TODO-1341 后续）——同位置
        // 的 cue 归一堆叠、不同位置各自成组独立定位。副字幕不再被无条件塞进一个顶部盒：带显式
        // 位置（\pos 或 \an，即 ASS 副字幕）的组遵自带位置；纯 SRT 副字幕（anchor / pos 皆空）
        // 无位置信息才在 [_positionCueGroup] 里回退置顶（翻译参考，避让主字幕底部）。
        final List<(String, List<AudioCue>)> groups =
            _groupMainCuesByPosition(cues);

        final List<(String, Widget)> positioned = <(String, Widget)>[
          for (final (String key, List<AudioCue> group) in groups)
            (
              '${isSecondary ? 's' : 'm'}|$key',
              _clipGroup(
                group,
                videoW,
                videoH,
                _positionCueGroup(
                  context,
                  // 槽位状态键带主/副层前缀：两层各自分组，同形键不得跨层串槽位状态
                  // （TODO-1372）。
                  '${isSecondary ? 's' : 'm'}|$key',
                  group,
                  isSecondary: isSecondary,
                  blurred: blurred,
                  container: container,
                ),
              )
            ),
        ];

        // 单组：直接返回该定位盒（历史单字幕盒几何像素级不变）。多组：Stack 叠放，各组用
        // Positioned.fill 填满同一层边界、按各自锚点定位互不重叠（TODO-1341）。
        // Positioned 按**分组键**挂 key：分组顺序=活跃集发现顺序（cue 文件序号），歌词/
        // 招牌与对白的序号在文件里交错时，每次换句两组在本列表里对调；无 key 时 Flutter
        // 按 Stack 位置复用 element——底部组的 [AnimatedPadding] 被喂成顶部组的 padding
        // 目标（b:75→0 / t:0→15），把两组的 padding 差值**动画播出来**＝每句对白入场从
        // 底边滑升一次（用户报「字幕跳」，与 BUG-800 同类病但高一层：组间 element 复用）。
        if (positioned.length == 1) return positioned.single.$2;
        return Stack(
          children: <Widget>[
            for (final (String key, Widget w) in positioned)
              Positioned.fill(key: ValueKey<String>(key), child: w),
          ],
        );
      },
    );
  }

  /// ASS `\clip`/`\iclip` 真裁剪：组内所有 cue 共享同一裁剪（多层卡拉 OK 每层各自成组
  /// =单 cue 组，天然满足）时，把组的定位盒包进 [ClipPath]。路径坐标是归一化分数
  /// （PlayRes 空间），映射基准=fit:contain 视频内容矩形（与 \pos / 字号缩放同一几何，
  /// BUG-820）；组盒填满层边界（局部坐标==overlay 坐标），故绝对路径直接可用。多 cue
  /// 组裁剪不一致（罕见）不裁（画全部近似，与历史一致）。respectAssStyle 关不裁。
  Widget _clipGroup(
      List<AudioCue> group, int? videoW, int? videoH, Widget child) {
    if (!widget.respectAssStyle) return child;
    final SubtitleClip? clip = group.first.markup?.clip;
    if (clip == null) return child;
    for (final AudioCue cue in group.skip(1)) {
      if (!identical(cue.markup?.clip, clip)) return child;
    }
    return ClipPath(
      clipper: _AssClipClipper(clip: clip, videoW: videoW, videoH: videoH),
      child: child,
    );
  }

  /// TODO-1341：把主字幕活动集按「有效定位」（\pos 分数 + 锚点，或纯锚点）分组，保留发现
  /// 顺序。同组的 cue 共享一个位置、竖排堆叠；不同组各自独立定位，从而顶部歌词与底部对白
  /// 不再被裹挟到同一处。返回每组的 (分组键, cue 列表)（组内顺序即活动集顺序；分组键给
  /// [_syncGroupSlots] 作跨帧槽位状态的身份，TODO-1372）。
  List<(String, List<AudioCue>)> _groupMainCuesByPosition(List<AudioCue> cues) {
    final Map<String, List<AudioCue>> byKey = <String, List<AudioCue>>{};
    final List<(String, List<AudioCue>)> order = <(String, List<AudioCue>)>[];
    for (final AudioCue cue in cues) {
      final String key = _positionKey(cue.markup);
      final List<AudioCue>? existing = byKey[key];
      if (existing != null) {
        existing.add(cue);
      } else {
        final List<AudioCue> group = <AudioCue>[cue];
        byKey[key] = group;
        order.add((key, group));
      }
    }
    // 组内按 MarginV 升序稳定排序：折进同一基线桶的底部双语（JP MarginV=4 + CH MarginV=30）
    // 竖排堆叠时，MarginV 小的贴锚点（底部锚组 slot0 在底）、大的在上，复现 libass「MarginV
    // 越大离底越远」的相对次序，不再依赖字幕文件里 JP/CH 的书写先后（本 BUG 的次序保证）。
    // 稳定排序对同 MarginV（多行歌词 / 纯 SRT null）零改动，且只预排序 cue 顺序、不移动
    // [_syncGroupSlots] 里按 identity 稳定的在屏槽位（BUG-698 不变量保持）。
    double mvOf(AudioCue c) {
      final double? mv = c.markup?.cueStyle?.marginV;
      return (mv == null || mv <= 0) ? 0 : mv;
    }

    for (final (String, List<AudioCue>) entry in order) {
      final List<AudioCue> group = entry.$2;
      if (group.length < 2) continue;
      // 稳定排序（List.sort 非稳定）：以原始下标做 tie-break，保证同 MarginV 保持发现次序。
      final List<AudioCue> byIndex = List<AudioCue>.of(group);
      group.sort((AudioCue a, AudioCue b) {
        final int c = mvOf(a).compareTo(mvOf(b));
        return c != 0 ? c : byIndex.indexOf(a).compareTo(byIndex.indexOf(b));
      });
    }
    return order;
  }

  /// 一条 cue 的「有效定位」分组键（TODO-1341）：有 \pos 时按分数（+ 锚点），否则按锚点
  /// （竖直 + 水平对齐）+ MarginV。同键的 cue 同位置堆叠，不同键各自独立定位。
  ///
  /// TODO-1372/BUG-698 语义归一：渲染路径把「anchor 缺省」当底部居中（[_alignFor] /
  /// [_paddingFor] / forceTop 判据全同构），把「MarginV<=0」当无 MarginV（[_scaledMarginV]
  /// 都回退历史基线）。归一进键后，渲染完全相同的 cue 必然同组堆叠，而不是分成两组叠印
  /// 在同一位置互相压字。
  ///
  /// BUG-（双语底部对白 MarginV 塌陷重叠）：底部锚点的最终基线是
  /// `max(bottomPadding, scaledMarginV)`（[_paddingFor]，单调抬升不越用户基线）。故**两条
  /// 底部 cue 的 MarginV 都 <= 用户 bottomPadding 时会被 max 夹到同一基线**——若仍按原始
  /// MarginV 拆成两组，两组各自定位却落在同一 y、互相压字（如典型双语 Dial_JP MarginV=4 +
  /// Dial_CH MarginV=30，both < 默认 75）。修复：底部锚点先按**渲染后基线是否真的不同**归键
  /// ——MarginV 缩放后 <= bottomPadding（会被 max 夹回基线）的一律折进基线桶（key mv=-1），
  /// 使它们同组、竖排堆叠（libass 的碰撞下推同效果），不再叠印。真正超出基线（标题
  /// MarginV=400 等）才保留各自 authored 高度（TODO-1341 行为不变）。顶部/中部锚点无 max
  /// 夹逻辑（[_paddingFor] 直接用 scaledMarginV），保持按原始 MarginV 分键。
  String _positionKey(SubtitleMarkup? markup) {
    final SubtitlePos? pf = markup?.posFraction;
    final SubtitleAnchor? a = markup?.anchor;
    final int av = (a?.vertical ?? SubtitleVAlign.bottom).index;
    final int ah = (a?.horizontal ?? SubtitleHAlign.center).index;
    // ASS Layer 纳入键（libass 语义：碰撞/竖排堆叠**只发生在同层事件之间**，不同层各按
    // 自带位置叠画）。多层卡拉 OK（同句歌词拆光晕层+主文字层+点缀层，Layer 3/4/5）分属
    // 不同组、同锚点同位叠出一行特效，不再被裹挟进一个 Column 竖排成「三个字幕」。
    // Layer 0（srt/vtt/无 Layer 列）不加后缀，既有分组键与槽位状态字面不变。
    final int layer = markup?.layer ?? 0;
    final String lk = layer != 0 ? ':L$layer' : '';
    if (pf != null) {
      return 'p:${pf.xFraction.toStringAsFixed(4)},'
          '${pf.yFraction.toStringAsFixed(4)}:$av:$ah$lk';
    }
    // \move（TODO-1374）：自带绝对位置（起点）→ 各自成组走绝对定位，不与锚点 cue 同组。
    final SubtitleMove? move = widget.respectAssStyle ? markup?.move : null;
    if (move != null) {
      return 'mv:${move.x1Fraction.toStringAsFixed(4)},'
          '${move.y1Fraction.toStringAsFixed(4)}:$av:$ah$lk';
    }
    // MarginV（同锚点内不同竖直边距）纳入键：消除旧「同锚点不同 MarginV 被裹挟进一个
    // Column 挤在一起」的降级（OP/ED 标题与多行歌词那样各在其 authored 高度）。
    // MarginV 仅 ASS 非空（srt/vtt 的 cueStyle 为 null），故 srt/vtt 分组行为像素级不变。
    final double? mvRaw = markup?.cueStyle?.marginV;
    final SubtitleVAlign vertical = a?.vertical ?? SubtitleVAlign.bottom;
    final int mv;
    if (mvRaw == null || mvRaw <= 0) {
      mv = -1;
    } else if (vertical == SubtitleVAlign.bottom) {
      // 底部锚点折叠判据用**原始 MarginV**（PlayRes 像素、显示无关），不用缩放值：缩放值
      // `_scaledMarginV` 随显示区高变化，大屏（显示区高 >> PlayResY）时第二语言对白的
      // MarginV 缩放后会超出固定的 bottomPadding（如 CH MarginV=30 在 2160 高显示区 → 90 >
      // 75），被错判成「独立位置」而脱离基线桶——它与仍折在基线的第一语言各自定位却落在
      // 相邻高度，大字号盒相交、重现 BUG-709 的双语底部塌陷重叠（仅大屏触发）。原始值判据
      // 在任何显示尺寸都一致：MarginV <= 用户基线的底部对白恒折进基线桶竖排堆叠（libass
      // 碰撞下推同效果），只有真正的高位标题（大 MarginV，如 400）才独立占 authored 高度
      // （TODO-1341 不回归）。以原始值入键（而非缩放 round），组身份也不随显示尺寸漂移，
      // 跨帧槽位状态（[_syncGroupSlots]）不因窗口缩放churn。
      mv = mvRaw <= widget.bottomPadding ? -1 : mvRaw.round();
    } else {
      mv = mvRaw.round();
    }
    // MarginL/MarginR（水平边距，原始 PlayResX 像素——显示无关，组身份不随窗口缩放漂移）
    // 纳入键：行级横移对白（如 MarginL=900 挪到说话人一侧）与常规居中对白水平盒不同，
    // 不得同组共用一个代表 padding。无边距（null/<=0）归一成 -1（srt/vtt 恒 -1，分组
    // 行为像素级不变）。
    final double mlRaw = markup?.cueStyle?.marginL ?? 0;
    final double mrRaw = markup?.cueStyle?.marginR ?? 0;
    final int ml = mlRaw > 0 ? mlRaw.round() : -1;
    final int mr = mrRaw > 0 ? mrRaw.round() : -1;
    return 'a:$av:$ah:$mv:$ml:$mr$lk';
  }

  /// TODO-1372/BUG-698：把一组的当前活动 cue 对齐进跨帧槽位表（不变量见 [_groupSlots]），
  /// 返回本帧渲染用的槽位列表（锚点侧在前）。同一活动集重复调用幂等（布局重跑安全）。
  List<_GroupSlot> _syncGroupSlots(String slotKey, List<AudioCue> cues) {
    final List<_GroupSlot> slots =
        _groupSlots.putIfAbsent(slotKey, () => <_GroupSlot>[]);
    // ① 存活标记：槽主仍在活动集 → 在屏；否则离场（远端有人时渲染成隐形占位）。
    final Set<AudioCue> pending = HashSet<AudioCue>.identity()..addAll(cues);
    for (final _GroupSlot slot in slots) {
      slot.alive = pending.remove(slot.cue);
    }
    // ② 新进 cue（按活动集顺序）：先补最靠锚点的空槽，没有才追加远端——都不挤动在屏 cue。
    for (final AudioCue cue in cues) {
      if (!pending.contains(cue)) continue;
      final int free = slots.indexWhere((_GroupSlot s) => !s.alive);
      if (free >= 0) {
        slots[free]
          ..cue = cue
          ..alive = true;
      } else {
        slots.add(_GroupSlot(cue));
      }
    }
    // ③ 远端的空槽不撑任何人，立即裁掉（在屏 cue 位置不受影响）。
    while (slots.isNotEmpty && !slots.last.alive) {
      slots.removeLast();
    }
    return slots;
  }

  /// TODO-1341：把一个位置分组（同锚点的 cue 列表）渲染成**定位好**的字幕盒——按跨帧稳定
  /// 槽位竖排堆叠成 [Column]（TODO-1372，不变量见 [_groupSlots]）、套查词点击 / 模糊 / 悬停
  /// 交互（[_wrapInteractive]），再按该组代表 markup 的 \pos / 锚点定位。无显式位置的副字幕
  /// 组强制顶部。返回填满层边界（[Align] / [Stack]）、可作 [Stack] 直接子的定位盒。
  /// [slotKey] 是带层前缀的分组键，作 [_groupSlots] 里槽位状态的身份。
  Widget _positionCueGroup(
    BuildContext context,
    String slotKey,
    List<AudioCue> cues, {
    required bool isSecondary,
    required bool blurred,
    required Size container,
  }) {
    // 定位代表 markup（分组键已把 \pos / \an / MarginV 语义归一，组内任取一条定位等价，
    // 代表随活动集增减翻转不改变几何）。副字幕若带**显式**位置
    // （\pos 或 \an，即 ASS 副字幕）遵其自带位置（各遵自带位置，消除「副字幕总被拽到顶部」的
    // 降级）；纯 SRT 副字幕（anchor / pos 皆空、无位置信息）才回退强制置顶（翻译参考，避让主
    // 字幕底部，与历史一致）。
    final SubtitleMarkup? ownMarkup = cues.first.markup;
    // 副字幕默认置顶（翻译参考，避让主字幕底部对白）；但若它自带**非底部**位置——\pos，或
    // \an 顶部 / 中部（作者本就把它放在别处，如顶部歌词 / 招牌 / 中部注释）——则遵其自带位置，
    // 不再硬拽到顶（消除「副字幕总被降级到顶部」）。自带底部 / 无位置的副字幕（纯 SRT、\an2
    // 对白）仍置顶，避免与主字幕底部对白撞在同一处（asbplayer 式双语上下分栏）。
    final SubtitlePos? ownPos = ownMarkup?.posFraction;
    final SubtitleAnchor? ownAnchor = ownMarkup?.anchor;
    final bool ownNonBottom = ownPos != null ||
        ownMarkup?.move != null || // \move 自带绝对位置，不被强制置顶（TODO-1374）
        (ownAnchor != null && ownAnchor.vertical != SubtitleVAlign.bottom);
    final bool forceTop = isSecondary && !ownNonBottom;
    final SubtitleMarkup? posMarkup = forceTop ? null : ownMarkup;
    // 本组生效的竖直锚：决定堆叠增长方向（槽位远端在哪一侧）。
    final SubtitleVAlign effectiveV = forceTop
        ? SubtitleVAlign.top
        : (ownAnchor?.vertical ?? SubtitleVAlign.bottom);

    // TODO-1372/BUG-698：组内跨帧稳定槽位（锚点侧在前，不变量见 [_groupSlots]）。Column
    // 自顶向下渲染：底部锚组反转（slot0 贴底、新 cue 往上长），顶部/中部锚组顺序（slot0
    // 贴顶、新 cue 往下长；中部锚组增长对称外扩，重叠罕见，接受半高偏移）。
    final List<_GroupSlot> slots = _syncGroupSlots(slotKey, cues);
    final Iterable<_GroupSlot> topToBottom =
        effectiveV == SubtitleVAlign.bottom ? slots.reversed : slots;
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // 每个槽位按 **cue 身份**挂 key：组内 cue 数量变化（相邻/重叠对白进出场）时，
        // Flutter 按身份而非 Column 位置复用 element。没有 key 时，底部锚组的 reversed
        // 顺序让新 cue 追加在 Column 头部，在屏 cue 的 element 被按位置复用成**另一条**
        // cue（文本+\fad 不透明度瞬跳 1→0）——双语字幕闪烁的直接根因。槽位数据层的跨帧
        // 稳定（TODO-1372/BUG-698）必须传导到 element 层才有效。
        for (final _GroupSlot slot in topToBottom)
          KeyedSubtree(
            key: ObjectKey(slot.cue),
            child: slot.alive
                ? _buildCueBox(context, slot.cue,
                    isSecondary: isSecondary, blurred: blurred)
                // 离场 cue 的隐形占位：保持原盒尺寸撑住远端在屏字幕的槽位（不登记查词
                // 命中、不响应指针、无收藏角标）。libass「事件在屏期间位置不变」语义的
                // 槽位版。
                : IgnorePointer(
                    child: Opacity(
                      opacity: 0,
                      child: _buildCueBox(context, slot.cue,
                          isSecondary: isSecondary,
                          blurred: blurred,
                          registerHits: false),
                    ),
                  ),
          ),
      ],
    );

    content = _wrapInteractive(context, content,
        isSecondary: isSecondary, blurred: blurred);

    final Offset? posScreen = _posScreen(posMarkup, container, cue: cues.first);
    if (posScreen != null) {
      // \pos 绝对定位：把字幕盒的 \an 锚点精确落到映射坐标（\pos 覆盖 MarginV）。
      final SubtitleAnchor anchor = posMarkup!.anchor ??
          const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center);
      return Stack(
        children: <Widget>[
          Positioned(
            left: posScreen.dx,
            top: posScreen.dy,
            child: FractionalTranslation(
              translation: Offset(
                -_hFrac(anchor.horizontal),
                -_vFrac(anchor.vertical),
              ),
              child: content,
            ),
          ),
        ],
      );
    }
    // 无 \pos：纯 SRT 副字幕强制顶部锚点；否则按 markup 锚点（null → 历史底居中）。
    final SubtitleAnchor? anchor = forceTop
        ? const SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center)
        : posMarkup?.anchor;
    // ASS MarginV（同锚点内竖直边距）缩放到显示尺寸，作为该组距锚点边的偏移，使作者用
    // MarginV 放在不同高度的同锚点 cue（标题 + 多行歌词）各就其位（TODO-1341 后续）。
    final double? scaledMarginV = forceTop ? null : _scaledMarginV(posMarkup);
    // ASS MarginL/MarginR（水平边距）缩放到显示尺寸：横移对白（说话人一侧）/ an7 左上
    // 招牌的左缘偏移各就其位。强制置顶的纯 SRT 副字幕（posMarkup null）恒无边距。
    final double? scaledMarginL =
        _scaledMarginX(posMarkup, posMarkup?.cueStyle?.marginL);
    final double? scaledMarginR =
        _scaledMarginX(posMarkup, posMarkup?.cueStyle?.marginR);
    return Align(
      alignment: _alignFor(anchor),
      child: _anchoredPadded(
          anchor, content, scaledMarginV, scaledMarginL, scaledMarginR),
    );
  }

  /// TODO-1312 / TODO-1341：给一「组」字幕盒套查词点击（[_SubtitleCharTapRecognizer]）、
  /// 听力沉浸模糊（仅主层）、桌面 hover（显形 / 光标唤回 / Shift-悬停查词）。定位在
  /// [_positionCueGroup] 里做，本方法只负责交互层包裹（原 _buildSubtitleLayer 中段抽出）。
  ///
  /// 字符点击查词：一片 translucent [RawGestureDetector]，其识别器只在按下点命中某字符时才
  /// 收指针进竞技场（BUG-553 门控）。命中反查扫全 [_charEntries]（含各组各层）。translucent
  /// 保证 hover 透传、media_kit 控制条唤起不被吞（BUG-198）。
  Widget _wrapInteractive(
    BuildContext context,
    Widget content, {
    required bool isSecondary,
    required bool blurred,
  }) {
    if (widget.onCharTap != null) {
      content = RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          _SubtitleCharTapRecognizer:
              GestureRecognizerFactoryWithHandlers<_SubtitleCharTapRecognizer>(
            () => _SubtitleCharTapRecognizer(
              hitTestChar: (Offset globalPosition) =>
                  _hitEntryIndexAt(globalPosition) >= 0,
            ),
            (_SubtitleCharTapRecognizer instance) {
              instance
                ..onTapDown = (TapDownDetails details) {
                  _pendingTapEntry = _hitEntryIndexAt(details.globalPosition);
                }
                ..onTapUp = (TapUpDetails details) {
                  final SubtitleCharHit? hit =
                      _charHitByEntryIndex(_pendingTapEntry);
                  _pendingTapEntry = -1;
                  if (hit != null) {
                    widget.onCharTap!(
                        hit.sentence, hit.graphemeIndex, hit.charRect);
                  }
                }
                ..onTapCancel = () {
                  _pendingTapEntry = -1;
                };
            },
          ),
        },
        child: content,
      );
    }

    if (blurred) {
      // 模糊态（仅主层）：盖一层高斯模糊 + 拦字符点击（避免误触查词）+ 显形热区。
      // 模糊强度随字号缩放（见 [VideoSubtitleOverlay.obscureBlurSigma]），字号越大糊得越狠，
      // 保证任何字号下都真读不出（旧的固定 8px 对大字号太浅，用户报「模糊度不够」）。
      final double sigma =
          VideoSubtitleOverlay.obscureBlurSigma(widget.fontSize);
      content = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: content,
          ),
          Positioned.fill(
            child: GestureDetector(
              key: const Key('video-subtitle-reveal'),
              behavior: HitTestBehavior.translucent,
              onTap: () => _setRevealed(true),
            ),
          ),
        ],
      );
    }

    // 桌面悬停：①听力沉浸显形/复原（主层 blurEnabled）②向页面回报 hover（唤回光标 + 续命
    // 控制条，BUG-283/284）③Shift-鼠标悬停查词（TODO-756a）。三者合一个 opaque:false 的
    // MouseRegion（不阻断 hover 下探 media_kit，BUG-198）。仅确需 hover 时挂（外观零变化）。
    final bool needHover = (!isSecondary && widget.blurEnabled) ||
        widget.onHoverChanged != null ||
        widget.onCharHover != null;
    if (!needHover) return content;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        if (!isSecondary && widget.blurEnabled) _setRevealed(true);
        widget.onHoverChanged?.call(true);
      },
      onHover: _handleShiftHover,
      onExit: (_) {
        if (!isSecondary && widget.blurEnabled) _setRevealed(false);
        widget.onHoverChanged?.call(false);
        _lastShiftHoverPos = Offset.zero;
        _lastShiftHoverEntry = -1;
      },
      child: content,
    );
  }

  /// TODO-1312：渲染一条 cue 的字幕盒（背景盒 + 逐字符描边文本 + 主层收藏角标）。逐字符
  /// 登记进 [_charEntries]（携带整条 cue 文本、该 cue 内 grapheme 下标、字符 context、模糊
  /// 态），供全局坐标反查命中。空文本 cue 返回零尺寸盒（不占位）。
  /// [registerHits] 为 false（隐形占位，TODO-1372）时跳过字符登记与收藏角标——离场 cue
  /// 只保几何、不可交互。
  Widget _buildCueBox(
    BuildContext context,
    AudioCue cue, {
    required bool isSecondary,
    required bool blurred,
    bool registerHits = true,
  }) {
    final String text = cue.text;
    if (text.isEmpty) return const SizedBox.shrink();
    final SubtitleMarkup? markup = cue.markup;
    final List<String> chars = text.characters.toList(growable: false);

    final Color backgroundColor = widget.backgroundOpacity <= 0
        ? Colors.transparent
        : (widget.backgroundColor ?? kDefaultSubtitleBackgroundColor)
            .withValues(alpha: widget.backgroundOpacity);

    // 单个 grapheme 的渲染 + 查词登记（所属 cue 文本 + 该 cue 内 grapheme 下标 + context
    // + 模糊态，供全局坐标反查）。字符本身不各自包 opaque GestureDetector（会吞 hover /
    // 光标，BUG-198）；tap 命中由上层 translucent RawGestureDetector + 本登记表反查承载
    // （BUG-553 竞技场门控）。隐形占位（TODO-1372，registerHits 为 false）不登记：离场
    // cue 不可点、不可查词。
    Widget charWidget(int i) {
      return Builder(
        builder: (BuildContext charContext) {
          if (registerHits) {
            _charEntries.add(_SubtitleCharEntry(
              sentence: text,
              graphemeIndex: i,
              context: charContext,
              blurred: blurred,
            ));
          }
          return _buildSubtitleChar(chars[i], i, markup);
        },
      );
    }

    // \N 硬换行（markup.lineBreakGraphemes）：按作者排好的断点切成多行，复现 libass
    // 布局（plainText 里断点处是空格、查词/制卡不变，仅渲染分行；断点空格本身不渲染
    // ——libass 的 \N 同样被消费不显示）。无 \N（含 srt/vtt）恒单行 Wrap，几何像素级不变。
    final List<int> breakList = markup?.lineBreakGraphemes ?? const <int>[];
    final Set<int> breakSet =
        breakList.isEmpty ? const <int>{} : breakList.toSet();
    final List<List<Widget>> rows = <List<Widget>>[<Widget>[]];
    for (int i = 0; i < chars.length; i++) {
      if (breakSet.contains(i)) {
        rows.add(<Widget>[]);
        continue;
      }
      rows.last.add(charWidget(i));
    }
    final Widget textContent = rows.length == 1
        ? Wrap(alignment: WrapAlignment.center, children: rows.single)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              for (final List<Widget> row in rows)
                Wrap(alignment: WrapAlignment.center, children: row),
            ],
          );

    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: textContent,
      ),
    );

    // 当前句已收藏：字幕盒左上角外侧叠一枚实心星角标（TODO-301 / BUG-264）。仅主层
    // （副字幕=翻译参考，不制卡/不收藏）。[isCueFavorited] 为 null（测试 / 无数据源）不叠；
    // 隐形占位（registerHits=false）不叠（离场 cue 无角标语义）。
    if (!isSecondary && registerHits) {
      final bool favorited = widget.isCueFavorited?.call(cue) ?? false;
      if (favorited) {
        final Color starColor =
            widget.textColor ?? Theme.of(context).colorScheme.tertiary;
        box = Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            box,
            Positioned(
              left: -6,
              top: -10,
              child: Icon(
                Icons.star,
                size: widget.fontSize * 0.6,
                color: starColor,
                shadows: buildSubtitleShadows(
                  widget.shadowColor ?? Theme.of(context).colorScheme.shadow,
                  widget.shadowThickness,
                ),
              ),
            ),
          ],
        );
      }
    }
    // 缓存屏障（BUG-797 掉帧型闪烁）：\fad/\t/\move 动画期 [_fadeTicker] 每帧 setState、
    // 播放位置更新也随 controller 通知整树重绘——没有屏障时，上方 Opacity/Transform 每
    // tick 都把盒内**每字一个**的 ImageFiltered 高斯 saveLayer（双语长句 ~35 个/帧）
    // 重录重栅格化一遍，掉帧表现为字幕闪/卡。RepaintBoundary 让盒内容成为独立缓存层：
    // 动画只重合成缓存纹理。放在动画包装层之下、盒（含背景/收藏角标）之上；不改布局/
    // 命中几何（[_charEntries] 是 build 期登记，与 paint 无关）。
    box = RepaintBoundary(child: box);

    // \frz 旋转 / \fscx\fscy 缩放（+ \t 缩放动画）：绕字幕盒中心变换（TODO-1374）。招牌类
    // 字幕（\pos + \frz/缩放）据此复现 mpv/libass 摆位。Transform 不改布局尺寸（组内堆叠 /
    // 命中登记按未变换盒几何），旋转招牌本就不查词，可接受命中矩形不随旋转。
    box = _applyAssTransform(box, cue, markup);

    // \fad/\fade 行级淡入淡出（TODO-1373）：整条 cue（含背景 / 收藏角标）按不透明度淡变。
    // 仅 respectAssStyle 开且本 cue 带 fade 时包裹；Opacity 不改布局 / 命中几何，逐字查词
    // 照常。隐形占位（registerHits=false）已在外层 Opacity(0)，此处叠乘不影响其为 0。
    final SubtitleFade? fade = widget.respectAssStyle ? markup?.fade : null;
    if (fade == null) return box;
    return Opacity(opacity: _fadeOpacityFor(fade, cue), child: box);
  }

  /// `\frz` 旋转 + `\fscx`/`\fscy`（含 `\t` 动画）缩放：把字幕盒绕中心做仿射变换
  /// （TODO-1374）。仅 respectAssStyle 开且本 cue 带旋转 / 缩放时包裹；否则原样返回（零多余
  /// 层，历史几何不变）。缩放动画按 cue 内已播放时长逐帧插值（由 [_syncFadeTicker] 驱动）。
  Widget _applyAssTransform(Widget box, AudioCue cue, SubtitleMarkup? markup) {
    if (!widget.respectAssStyle || markup == null) return box;
    final double? rot = markup.rotationDeg;
    final SubtitleScale? sc = markup.scale;
    if (rot == null && sc == null) return box;
    double sx = 1.0;
    double sy = 1.0;
    if (sc != null) {
      final int? posMs = widget.controller.effectivePositionMs;
      final int elapsed = (posMs ?? cue.startMs) - cue.startMs;
      final (double a, double b) = sc.scaleAt(elapsed, cue.endMs - cue.startMs);
      sx = a;
      sy = b;
    }
    final Matrix4 m = Matrix4.identity();
    // ASS \frz 逆时针为正；Flutter rotateZ 顺时针为正，故取负。
    if (rot != null) m.rotateZ(-rot * math.pi / 180.0);
    if (sc != null) m.scale(sx, sy, 1.0);
    return Transform(alignment: Alignment.center, transform: m, child: box);
  }

  /// 本条 cue 的 `\fad`/`\fade` 不透明度（0..1）。无位置信息（未 load）时恒 1（不淡）。
  /// elapsed = 音画延迟校正后的等效位置 − cue 起点；duration = cue 时长。
  double _fadeOpacityFor(SubtitleFade fade, AudioCue cue) {
    final int? pos = widget.controller.effectivePositionMs;
    if (pos == null) return 1.0;
    return fade.opacityAt(pos - cue.startMs, cue.endMs - cue.startMs);
  }

  /// 渲染单个字幕字符。两条外观路径：
  ///
  /// **① 默认统一外观**（`!respectAssStyle` 或非 .ass 字幕 markup==null）：单层 fill [Text]
  /// + Niratan 式**柔和投影**（[buildSubtitleSoftShadow]，黑@0.9、模糊半径=shadowThickness、
  /// 向下 1px）。这是用户开箱看到的「默认阴影」——按用户决策抄 mac 的 Niratan，放弃 BUG-323
  /// 的锐利硬描边。单层软投影（仅一份拷贝、偏移 (0,1)）不会重现 BUG-222/323 的 8 层模糊
  /// glyph 拷贝外溢残影。
  ///
  /// **② 尊重 .ass 自带样式**（[VideoSubtitleOverlay.respectAssStyle] 开且 cue 带 markup）：
  /// 底层 stroke [Text]（[buildSubtitleStrokePaint] 沿字形轮廓描一圈 .ass 的 \bord/\3c 硬
  /// 描边）+ 上层 fill [Text]，并保留 .ass 的 \shad 硬投影（[_styleForGrapheme] 的
  /// `shadows`）。忠实还原 .ass 文件明示的描边/阴影语义（TODO-1105/1246），不被默认软投影
  /// 覆盖。描边宽<=0 时降级为单层 fill。
  ///
  /// \blur/\be 辉光（TODO-1373，仅 respect 时）对齐 libass `ass_bitmap.c` 语义：
  /// **\bord>0 时只糊「描边（含 \shad 阴影）」层，字面 fill 保持锐利**（mpv 观感=清晰
  /// 字面+柔光晕）；\bord==0 才糊整个字形（字面边缘发虚）。此前无条件把合成字形
  /// （描边+填充+阴影）整体 [ImageFiltered]，带描边的 `{\blur5}` 对白被糊成一团不可读。
  /// 命中矩形不因层数变化（ImageFiltered / Stack 不改布局），逐字查词照常。
  Widget _buildSubtitleChar(String char, int i, SubtitleMarkup? markup) {
    final TextStyle fillStyle = _styleForGrapheme(i, markup);
    final bool respect = widget.respectAssStyle && markup != null;
    final double sigma = _blurSigmaFor(i, markup);
    final Widget glyph;
    if (!respect) {
      // 默认统一外观：Niratan 柔和投影。fillStyle 在非 respect 下 shadows==null，直接挂软
      // 投影；thickness<=0（用户关阴影）时 soft 为空，渲染纯 fill（无投影、零多余层）。
      final List<Shadow> soft = buildSubtitleSoftShadow(
        widget.shadowColor ?? Theme.of(context).colorScheme.shadow,
        widget.shadowThickness,
      );
      glyph = Text(
        char,
        style: soft.isEmpty ? fillStyle : fillStyle.copyWith(shadows: soft),
      );
    } else {
      // 尊重 .ass：\bord/\3c 真描边 + \shad ASS 硬投影（TODO-1105/1246），保持原样。
      final (Color strokeColor, double strokeWidth) = _resolveStroke(i, markup);
      final Paint? strokePaint =
          buildSubtitleStrokePaint(strokeColor, strokeWidth);
      if (strokePaint == null) {
        // .ass 无描边（\bord 0）：单层 fill（自带 ASS 阴影，若有）。
        glyph = Text(char, style: fillStyle);
      } else {
        // 描边层：复制 fill 的所有几何属性，但用 foreground 画笔取代 color（Flutter 断言
        // foreground 与 color 不可共存，故显式重建而非 copyWith——copyWith 无法把 color 清空）。
        final TextStyle strokeStyle = fillStyle.copyWith(
          color: null,
          foreground: strokePaint,
          // 描边层不画下划线/删除线，避免与 fill 层重叠加粗装饰线（fill 层已画）。
          decoration: TextDecoration.none,
        );
        // 阴影只保留在描边层（最底）→ 正确 z 序（阴影 < 描边 < 填充）；填充层清空阴影防重叠。
        final bool hasShadows =
            fillStyle.shadows != null && fillStyle.shadows!.isNotEmpty;
        final TextStyle fillTopStyle = hasShadows
            ? fillStyle.copyWith(shadows: const <Shadow>[])
            : fillStyle;
        // \bord>0 + \blur：只糊描边层（阴影挂在描边层上，随之同糊——libass 的阴影本就是
        // 模糊后描边位图的平移拷贝）；fill 层留在 ImageFiltered 外保持锐利。
        Widget strokeLayer = Text(char, style: strokeStyle);
        if (sigma > 0) {
          strokeLayer = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: strokeLayer,
          );
        }
        // 底层 stroke 先画（在下），上层 fill 后画（在上）盖住描边内缘，露出外缘成轮廓。
        return Stack(
          children: <Widget>[
            strokeLayer,
            Text(char, style: fillTopStyle),
          ],
        );
      }
    }
    // 无描边（\bord 0 的 respect 分支；非 respect 分支 sigma 恒 0）：糊整个字形——libass
    // 在没有描边位图时对字形位图本身做高斯，字面边缘发虚是原作者点名要的效果。
    if (sigma <= 0) return glyph;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: glyph,
    );
  }

  /// 覆盖第 [i] 个 grapheme 的 `\blur`/`\be` 换算成 Flutter 高斯模糊 sigma（逻辑像素）。
  /// respectAssStyle 关 / 无 blur 返回 0。真换算（含 libass `2/sqrt(ln256)` 因子 + 夹范围）
  /// 委托纯函数 [assBlurValueToSigma]（可单测），本方法只负责取 span 的 `\blur` 值 + 缩放。
  double _blurSigmaFor(int i, SubtitleMarkup? markup) {
    if (!widget.respectAssStyle || markup == null) return 0;
    final double? blur = _spanAt(i, markup)?.blur;
    if (blur == null || blur <= 0) return 0;
    return assBlurValueToSigma(blur, _assFontScale(markup));
  }

  /// 解析第 [i] 个 grapheme 的**描边色 + 描边宽**（[_buildSubtitleChar] 的 ASS 尊重分支用）。
  ///
  /// respectAssStyle 关：恒返回用户统一 (shadowColor, shadowThickness)——与历史像素级一致。
  /// respectAssStyle 开：描边色取 span.\3c ?? cueStyle.OutlineColour ?? 统一色；描边宽取
  /// span.\bord ?? cueStyle.Outline ?? 统一宽（TODO-1105，行内覆盖 cue 默认覆盖统一样式），
  /// 且 ASS 描边宽按 显示区高/PlayResY 与字号同源缩放（TODO-1246，见下）。
  (Color, double) _resolveStroke(int i, SubtitleMarkup? markup) {
    final Color baseColor =
        widget.shadowColor ?? Theme.of(context).colorScheme.shadow;
    final double baseWidth = widget.shadowThickness;
    if (!widget.respectAssStyle || markup == null) {
      return (baseColor, baseWidth);
    }
    final SubtitleSpan? span = _spanAt(i, markup);
    final SubtitleCueStyle? cue = markup.cueStyle;
    final int? outlineArgb = span?.outlineColorArgb ?? cue?.outlineColorArgb;
    // ASS `Outline`/`\bord` 描边宽是相对 PlayResY 的**绝对像素**（`ScaledBorderAndShadow: yes`
    // 时随画面缩放，anime .ass 普遍如此），必须与字号（BUG-604 已按 显示区高/PlayResY 缩放）
    // **同源缩放**到显示尺寸；否则在小于 PlayResY 的显示区里，描边相对**已缩放**的字号偏粗——
    // 大制作字幕（PlayResY=1080、Outline=2.5）设计的细描边被渲染成一圈过重的黑边，「尊重自带
    // 样式」名不副实（用户报开关无明显区别；TODO-1246）。回退到用户统一描边宽（[baseWidth]，
    // 已是逻辑像素）时不缩放。缩放结果夹到 [0.5, 24] 防 PlayResY 缺失/异常时描边消失或撑爆
    // （与 _resolveAssShadows 阴影深度夹同量级）。
    final double? outlineWidthAss = span?.outlineWidthPx ?? cue?.outlineWidthPx;
    final double outlineWidth = outlineWidthAss != null
        ? (outlineWidthAss * _assFontScale(markup)).clamp(0.5, 24.0).toDouble()
        : baseWidth;
    return (
      outlineArgb != null ? Color(outlineArgb) : baseColor,
      outlineWidth,
    );
  }

  /// 覆盖第 [i] 个 grapheme 的行内 span（半开区间命中）；无则 null。
  SubtitleSpan? _spanAt(int i, SubtitleMarkup? markup) {
    if (markup == null) return null;
    for (final SubtitleSpan s in markup.spans) {
      if (i >= s.startGrapheme && i < s.endGrapheme) return s;
    }
    return null;
  }

  /// 合并外观默认与覆盖第 [i] 个 grapheme 的 span 样式（**填充层**）。默认统一外观下柔和
  /// 投影由 [_buildSubtitleChar] 挂到本样式上；尊重 .ass 时描边由其底层 stroke [Text] 单独
  /// 承载、.ass \shad 硬投影由本方法的 `shadows` 提供（BUG-323 / TODO-569 / TODO-1105）。
  ///
  /// respectAssStyle 关：只应用行内 `\i \b \u \s \c \fs` 这些历史就支持的 span 样式，字体 /
  /// 字号 / 颜色的基线恒为用户统一样式，与历史像素级一致。
  /// respectAssStyle 开：字体名 / 主色 / 字号 / 粗斜下删线优先取 .ass 值（行内 span >
  /// [SubtitleCueStyle] cue 默认 > 用户统一样式，TODO-1105）。字体缺字时仍挂
  /// [_kSubtitleCjkFallback] 兜底。
  TextStyle _styleForGrapheme(int i, SubtitleMarkup? markup) {
    final bool respect = widget.respectAssStyle && markup != null;
    final SubtitleCueStyle? cue = respect ? markup.cueStyle : null;
    final SubtitleSpan? span = _spanAt(i, markup);

    // 基线字体 / 颜色 / 字号：respect 时先叠 cueStyle（V4+ Styles）默认，否则恒用户统一样式。
    final String? baseFontFamily =
        (respect ? cue?.fontName : null) ?? widget.fontFamily;
    final Color baseColor = (respect && cue?.primaryColorArgb != null)
        ? Color(cue!.primaryColorArgb!)
        : (widget.textColor ?? Theme.of(context).colorScheme.onSurface);
    // ASS 绝对字号（PlayRes 像素）按 显示区高 / PlayResY 缩放到播放尺寸（TODO-1246）；
    // cueStyle 无字号时回退用户统一样式（已含 subtitleScreenScaleFactor）。
    final double assFontScale = respect ? _assFontScale(markup) : 1.0;
    final double? cueFontPx = respect ? cue?.fontSizePx : null;
    final double baseFontSize = cueFontPx != null
        ? _scaleAssFontSize(cueFontPx * assFontScale)
        : widget.fontSize;
    // 字重：cueStyle 存在即以 ASS 为准——`Bold=0`（fansub 对白的常态）必须渲染
    // **常规字重**，不得回退用户统一字重（视频页默认 700）。否则所有 ASS 字幕被
    // 合成假粗体（Fontname 多半未安装 → 回退字体再被 fake-bold），笔画变粗变宽、
    // 细描边被吞，观感与 mpv（同缺字体但按 Bold=0 常规渲染）差异巨大——用户报
    // 「字号/描边没尊重 ASS」的真凶。无 cueStyle（非 ASS / 样式失配）才用统一字重。
    final FontWeight baseWeight = (respect && cue != null)
        ? ((cue.bold ?? false) ? FontWeight.bold : FontWeight.normal)
        : _fontWeight(widget.fontWeight);

    final TextStyle base = TextStyle(
      color: baseColor,
      fontSize: baseFontSize,
      height: 1.3,
      fontFamily: baseFontFamily,
      // 统一的 CJK 日文回退链：主字体（自定义或平台默认）缺某字形（如假名「の」缺字）
      // 时，引擎按本列表顺序找到第一个存在的系统日文字体，而非各字符独立走引擎默认
      // fallback（不同字符可能落到不同字体、字形割裂）。引擎自动忽略当前平台不存在的
      // 项，故一条列表覆盖全平台、无需平台分支（TODO-088）。
      fontFamilyFallback: _kSubtitleCjkFallback,
      fontWeight: baseWeight,
      // cueStyle 的斜体 / 下划线 / 删除线（respect 时）作为基线，行内 span 可再覆盖。
      fontStyle: (respect && (cue?.italic ?? false)) ? FontStyle.italic : null,
      decoration: (respect) ? _cueDecoration(cue) : null,
      // ASS 阴影（Shadow 深度 + BackColour；行内 span 覆盖 cueStyle 默认）映射成向右下
      // 的硬投影（TODO-1246）。respect 关或无阴影时为 null，与历史像素级一致。
      shadows: respect ? _resolveAssShadows(span, cue, assFontScale) : null,
    );
    if (span == null) return base;

    final List<TextDecoration> decos = <TextDecoration>[];
    if (span.underline) decos.add(TextDecoration.underline);
    if (span.strike) decos.add(TextDecoration.lineThrough);
    // 行内 \fn 字体（respect 时）：优先于 base 的 cue 字体 / 统一字体。
    final String? spanFontFamily = (respect ? span.fontName : null);
    // \1a/\alpha 主填充透明度（respect 时）：施于最终生效的填充色（行内 \c 优先，否则
    // 基线色）。多层卡拉 OK 光晕层 `\1a&HFF&` 抹透明填充、只留模糊描边成辉光；描边层
    // 由 [_buildSubtitleChar] 单独构建，不受本透明度影响（ASS \1a 仅主填充语义）。
    final double? fillOp = respect ? span.fillOpacity : null;
    Color? spanColor = span.colorArgb != null ? Color(span.colorArgb!) : null;
    if (fillOp != null) {
      spanColor = (spanColor ?? baseColor).withValues(alpha: fillOp);
    }
    return base.copyWith(
      fontFamily: spanFontFamily,
      fontStyle: span.italic ? FontStyle.italic : null,
      fontWeight: span.bold ? FontWeight.bold : null,
      color: spanColor,
      // 行内字号（respect 时）同按 ASS 缩放；respect 关时保持历史裸像素（旧 span 行为）。
      fontSize: span.fontSizePx != null
          ? (respect
              ? _scaleAssFontSize(span.fontSizePx! * assFontScale)
              : span.fontSizePx!)
          : base.fontSize,
      decoration: decos.isEmpty ? null : TextDecoration.combine(decos),
    );
  }

  /// [SubtitleCueStyle] 的下划线 / 删除线合成 [TextDecoration]（respect 基线用）；都无则 null。
  static TextDecoration? _cueDecoration(SubtitleCueStyle? cue) {
    if (cue == null) return null;
    final List<TextDecoration> decos = <TextDecoration>[];
    if (cue.underline ?? false) decos.add(TextDecoration.underline);
    if (cue.strikeOut ?? false) decos.add(TextDecoration.lineThrough);
    return decos.isEmpty ? null : TextDecoration.combine(decos);
  }

  static FontWeight _fontWeight(int value) {
    final int index = ((value.clamp(100, 900) ~/ 100).clamp(1, 9)) - 1;
    return FontWeight.values[index];
  }

  /// ASS 字号 / 阴影深度是相对 [SubtitleMarkup.playResY] 的绝对像素（TODO-1246）；本因子把
  /// 它们缩放到 fit:contain 的**视频内容矩形**高（[_lastVideoContentHeight]，BUG-820——
  /// mpv/libass 锚定视频帧显示尺寸；窗口比≠视频比时容器高偏大）；首帧未解出分辨率时
  /// 回退容器高（[_lastLayoutHeight]，历史行为）。缺 playResY / 未布局时返回 1.0。
  double _assFontScale(SubtitleMarkup? markup) {
    final double? playResY = markup?.playResY;
    final double? displayH = _lastVideoContentHeight ?? _lastLayoutHeight;
    if (playResY == null ||
        playResY <= 0 ||
        displayH == null ||
        displayH <= 0) {
      return 1.0;
    }
    return displayH / playResY;
  }

  /// 缩放后的 ASS 字号夹到合理范围：下限 8px、上限 = 显示区高的 40%（防 PlayResY 缺失 /
  /// 异常时字号撑爆整屏；PlayResY 正确时常规字号远低于该上限、不受影响）。
  double _scaleAssFontSize(double px) {
    final double maxPx = (_lastLayoutHeight ?? 720) * 0.4;
    return px.clamp(8.0, maxPx > 8.0 ? maxPx : 8.0).toDouble();
  }

  /// ASS `MarginV`（竖直边距，PlayRes 像素）按 显示区高 / PlayResY 缩放到显示尺寸（与字号 /
  /// 阴影同源，TODO-1246），供 [_paddingFor] 把同锚点不同 MarginV 的 cue（标题 + 多行歌词）
  /// 各放到 authored 高度。无 MarginV / 无法缩放（<=0 / 缺 PlayResY）返回 null（回退历史
  /// bottomPadding 基线）。夹到 [0, 显示区高]，防 PlayResY 异常时偏移撑爆。MarginV 仅 ASS
  /// 非空（srt/vtt cueStyle 为 null），故 srt/vtt 恒 null、几何像素级不变。
  double? _scaledMarginV(SubtitleMarkup? markup) {
    final double? mv = markup?.cueStyle?.marginV;
    if (mv == null || mv <= 0) return null;
    final double h = _lastLayoutHeight ?? 720;
    return (mv * _assFontScale(markup)).clamp(0.0, h).toDouble();
  }

  /// ASS `MarginL`/`MarginR`（水平边距，PlayResX 像素）按 显示区宽 / PlayResX 缩放到显示
  /// 尺寸（与 [_scaledMarginV] 之于 PlayResY 同构）。缺 PlayResX 时回退 [_assFontScale]
  /// （等比视频两者相等）。无边距（null / <=0）返回 null。夹到 [0, 显示区宽] 防异常撑爆。
  double? _scaledMarginX(SubtitleMarkup? markup, double? margin) {
    if (margin == null || margin <= 0) return null;
    final double? playResX = markup?.playResX;
    // BUG-820：与 [_assFontScale] 同源——基准优先视频内容矩形宽，回退容器宽。
    final double? w = _lastVideoContentWidth ?? _lastLayoutWidth;
    final double scale =
        (playResX != null && playResX > 0 && w != null && w > 0)
            ? w / playResX
            : _assFontScale(markup);
    return (margin * scale).clamp(0.0, w ?? 1280).toDouble();
  }

  /// 把 ASS 阴影（Shadow 深度 + BackColour 阴影色，行内 span 覆盖 cueStyle 默认）解析成
  /// 向右下偏移的硬投影 [Shadow]（TODO-1246）。深度按 [scale] 与字号同步缩放。深度<=0 /
  /// 无阴影返回 null（不加 shadows，历史像素级一致）。阴影色缺失时按 ASS 默认取黑，而非
  /// 描边色（描边由 [_resolveStroke] 单独承载）。
  List<Shadow>? _resolveAssShadows(
      SubtitleSpan? span, SubtitleCueStyle? cue, double scale) {
    final double? depth = span?.shadowDepthPx ?? cue?.shadowDepthPx;
    if (depth == null || depth <= 0) return null;
    final int? colorArgb = span?.shadowColorArgb ?? cue?.shadowColorArgb;
    final Color color =
        colorArgb != null ? Color(colorArgb) : const Color(0xFF000000);
    final double off = (depth * scale).clamp(0.5, 24.0).toDouble();
    return <Shadow>[Shadow(color: color, offset: Offset(off, off))];
  }

  /// \pos 映射到容器局部坐标；无 \pos 或视频未解码返回 null（走 anchor 对齐）。
  Offset? _posScreen(SubtitleMarkup? markup, Size container, {AudioCue? cue}) {
    SubtitlePos? pf = markup?.posFraction;
    // \move(...)：无静态 \pos 时按 cue 内时间在起止点间线性插值（TODO-1374）。ticker 已在
    // build 里对带 move 的活动 cue 启动，故每帧重算。
    final SubtitleMove? move = widget.respectAssStyle ? markup?.move : null;
    if (pf == null && move != null && cue != null) {
      final int? posMs = widget.controller.effectivePositionMs;
      final int elapsed = (posMs ?? cue.startMs) - cue.startMs;
      pf = move.posAt(elapsed, cue.endMs - cue.startMs);
    }
    if (pf == null) return null;
    final int? w = widget.controller.videoWidth;
    final int? h = widget.controller.videoHeight;
    if (w == null || h == null) return null;
    return mapPosFractionToContainer(pf, w, h, container);
  }

  static double _hFrac(SubtitleHAlign h) => switch (h) {
        SubtitleHAlign.left => 0,
        SubtitleHAlign.center => 0.5,
        SubtitleHAlign.right => 1,
      };

  static double _vFrac(SubtitleVAlign v) => switch (v) {
        SubtitleVAlign.top => 0,
        SubtitleVAlign.middle => 0.5,
        SubtitleVAlign.bottom => 1,
      };

  /// anchor → Align 对齐（无 \pos 时用）。null=历史底居中。
  Alignment _alignFor(SubtitleAnchor? a) {
    if (a == null) return Alignment.bottomCenter;
    final double x = switch (a.horizontal) {
      SubtitleHAlign.left => -1,
      SubtitleHAlign.center => 0,
      SubtitleHAlign.right => 1,
    };
    final double y = switch (a.vertical) {
      SubtitleVAlign.top => -1,
      SubtitleVAlign.middle => 0,
      SubtitleVAlign.bottom => 1,
    };
    return Alignment(x, y);
  }

  /// 顶部锚点用顶部 padding、中部不加、底部按 [controlsVisible] 取避让下限。
  ///
  /// 底部锚点避让是「字幕底缘 ≥ 控制条顶缘」的约束，故控制条可见时底部 padding 取
  /// `max(bottomPadding, controlsBottomReserve)`——而**不是** `bottomPadding + reserve`
  /// 的加法叠加。加法会把高位字幕凭空多抬一个基线、顶出可视底带（TODO-161 用户报「桌面
  /// hover 字幕消失」，BUG-226）；取下限只把字幕抬到 reserve（=进度条上缘）恰骑控制条顶，
  /// 避开进度条又不飞。reserve 是按平台真实控制条几何加总 + 随界面缩放的值（视频页传入
  /// `videoSubtitleControlsReserve`，BUG-238），移动端 ≈140×缩放 > 默认基线 75，故默认字幕
  /// 在控制条可见时真正被抬升盖过被抬高的移动进度条。用户手选高位（> reserve）时 max 取其
  /// 值、不被避让改写；手选低位（< reserve）时控制条可见仍抬到 reserve 躲进度条、隐藏落回
  /// 原值。避让只对底部锚点生效——控制条在底部，顶部 / 中部字幕不会被进度条遮挡。
  EdgeInsets _paddingFor(SubtitleAnchor? a, bool controlsVisible,
      double? scaledMarginV, double? scaledMarginL, double? scaledMarginR) {
    final SubtitleVAlign v = a?.vertical ?? SubtitleVAlign.bottom;
    // 底部锚点基线：用户 bottomPadding 与 ASS 缩放 MarginV 取**较大值**（单调抬升——绝不低于
    // 用户基线，保 TODO-129/161/238 控制条避让不回归；作者用大 MarginV 要求更高时才抬）。
    final double bottomBase = scaledMarginV == null
        ? widget.bottomPadding
        : math.max(widget.bottomPadding, scaledMarginV);
    // ASS MarginL/MarginR 水平边距：Align 内侧 padding 恰是 ASS 排版盒语义——居中对齐时
    // 盒宽 = 文本 + L + R、Align 居中该盒 → 文本中心右移 (L-R)/2；左/右对齐时文本起点 /
    // 终点分别落在 L / 宽-R。无边距恒 0（srt/vtt 像素级不变）。
    final double left = scaledMarginL ?? 0;
    final double right = scaledMarginR ?? 0;
    return switch (v) {
      SubtitleVAlign.bottom => EdgeInsets.only(
          left: left,
          right: right,
          bottom: controlsVisible
              ? math.max(bottomBase, widget.controlsBottomReserve)
              : bottomBase,
        ),
      // 顶部锚点：有 ASS MarginV 时用缩放 MarginV 作顶部偏移（标题 / 多行歌词各就其位），
      // 否则回退用户基线 bottomPadding（历史行为，像素级不变）。
      SubtitleVAlign.top => EdgeInsets.only(
          left: left,
          right: right,
          top: scaledMarginV ?? widget.bottomPadding,
        ),
      SubtitleVAlign.middle => EdgeInsets.only(left: left, right: right),
    };
  }

  /// 给字幕盒套底部 padding。无 [VideoSubtitleOverlay.controlsVisible]（测试 / 有声书 /
  /// 无控制条场景）走静态 [Padding]，与历史像素级一致（controlsVisible=false → 贴
  /// bottomPadding 基线）。有控制条可见性时改 [ValueListenableBuilder] 监听 +
  /// [AnimatedPadding]：控制条出现 → 底部 padding 取 `max(bottomPadding, reserve)`（字幕
  /// 底缘骑到控制条顶、躲开进度条）、隐藏 → 落回 bottomPadding 基线（TODO-129/161，几何
  /// 见 [_paddingFor]）。取下限而非加法，故基线 < 控制条高时不会把字幕顶飞、手选高位也
  /// 不被改写（同一字段无特例分支）。
  Widget _anchoredPadded(SubtitleAnchor? anchor, Widget child,
      double? scaledMarginV, double? scaledMarginL, double? scaledMarginR) {
    final ValueListenable<bool>? visible = widget.controlsVisible;
    if (visible == null) {
      return Padding(
          padding: _paddingFor(
              anchor, false, scaledMarginV, scaledMarginL, scaledMarginR),
          child: child);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (BuildContext _, bool controlsVisible, Widget? padded) {
        return AnimatedPadding(
          // 与 media_kit 控制条淡入淡出同量级（~200ms），字幕上顶/落回跟随控制条显隐。
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: _paddingFor(anchor, controlsVisible, scaledMarginV,
              scaledMarginL, scaledMarginR),
          child: padded,
        );
      },
      child: child,
    );
  }

  /// 把 [charContext] 对应字符的局部布局矩形转成全局屏幕矩形（弹窗定位用）。
  /// 无 RenderBox 时退化成 [Rect.zero]，调用方有 fallback。
  static Rect _globalRectOf(BuildContext charContext) {
    final RenderObject? ro = charContext.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return Rect.zero;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    return topLeft & ro.size;
  }
}

/// ASS `\clip`/`\iclip` 的 [CustomClipper]：把 [SubtitleClip] 的归一化分数路径映射到
/// fit:contain 视频内容矩形（居中 + 黑边偏移，与 `\pos` 定位同一几何），构建 [Path]。
/// `\iclip` 用全区减路径（挖孔）。视频分辨率未知回退整容器为映射基准（历史近似）。
class _AssClipClipper extends CustomClipper<Path> {
  _AssClipClipper({required this.clip, this.videoW, this.videoH});

  final SubtitleClip clip;
  final int? videoW;
  final int? videoH;

  @override
  Path getClip(Size size) {
    final Size content = (videoW != null && videoH != null)
        ? (fitVideoContentSize(videoW!, videoH!, size) ?? size)
        : size;
    final double ox = (size.width - content.width) / 2;
    final double oy = (size.height - content.height) / 2;
    double mx(double fx) => ox + fx * content.width;
    double my(double fy) => oy + fy * content.height;
    final Path p = Path();
    for (final SubtitleClipSegment seg in clip.segments) {
      switch (seg.op) {
        case SubtitleClipOp.move:
          p.moveTo(mx(seg.x1), my(seg.y1));
        case SubtitleClipOp.line:
          p.lineTo(mx(seg.x1), my(seg.y1));
        case SubtitleClipOp.cubic:
          p.cubicTo(mx(seg.x1), my(seg.y1), mx(seg.x2), my(seg.y2), mx(seg.x3),
              my(seg.y3));
      }
    }
    p.close();
    if (!clip.inverse) return p;
    return Path.combine(
        PathOperation.difference, Path()..addRect(Offset.zero & size), p);
  }

  @override
  bool shouldReclip(covariant _AssClipClipper oldClipper) =>
      !identical(oldClipper.clip, clip) ||
      oldClipper.videoW != videoW ||
      oldClipper.videoH != videoH;
}

/// TODO-1312：一个已渲染字幕字符的登记项（[_VideoSubtitleOverlayState._charEntries]
/// 一条）。二维登记（主字幕活动集含重叠 cue + 副字幕活动集，每字符一条）后，按全局坐标
/// 反查命中能回到「哪条 cue + 该 cue 内第几个 grapheme」，故点主 / 副 / 重叠某条都查得对。
class _SubtitleCharEntry {
  _SubtitleCharEntry({
    required this.sentence,
    required this.graphemeIndex,
    required this.context,
    required this.blurred,
  });

  /// 该字符所属的整条 cue 文本（查词 / 制卡取整句用）。
  final String sentence;

  /// 该字符在其所属 cue 内的 grapheme 下标（从该位置起最长匹配取词）。
  final int graphemeIndex;

  /// 字符 widget 的 [BuildContext]（求其全局屏幕矩形做命中 / 弹窗定位）。
  final BuildContext context;

  /// 该字符所在层是否模糊（听力沉浸主层模糊时为 true）——模糊字符不参与命中反查
  /// （与点击不查词一致），命中扫描时按 [Rect.zero] 跳过。
  final bool blurred;
}

/// [_VideoSubtitleOverlayState._groupSlots] 的一格（TODO-1372/BUG-698）：槽主 cue + 是否
/// 仍在活动集。离场（[alive] 为 false）且远端仍有在屏 cue 时，本格以隐形占位渲染（保高度
/// 撑住槽位不塌）。
class _GroupSlot {
  _GroupSlot(this.cue);

  /// 槽主（可能已离场——那时本格作隐形占位保持高度）。新 cue 补空槽时顶替。
  AudioCue cue;

  /// 槽主是否仍在活动集。false = 隐形占位。
  bool alive = true;
}

/// 字幕盒的**按字符矩形门控** tap 识别器（BUG-553）。语义同普通 [TapGestureRecognizer]，
/// 但只有当**按下点**命中某字幕字符（含 [resolveSubtitleCharHit] 字缝 / 描边容差，由
/// [hitTestChar] 判定）时才通过 [isPointerAllowed] 收下该指针、加入手势竞技场竞逐 tap；
/// 按下点落在字幕盒内字符间空白（超容差）时不收指针、不进竞技场，让盖在其下的 media_kit
/// 控制条 `onTap` 独占竞技场胜出（点字幕区空白照常唤出 / 隐藏控制条）。
///
/// 取代旧的「整片 translucent [GestureDetector] 无条件收下所有 tap」：那样字幕盒在 Stack
/// 上层、任何落在盒内的 tap 都赢竞技场并 reject 掉 media_kit 的 onTap，移动端（无 hover
/// 兜底）表现为「有字幕在屏时点画面唤不出控制条」。门控只作用于竞技场，不改变 translucent
/// 的命中 / hover hit-test 语义（media_kit 仍在命中路径里，桌面 hover 行为原样保留、BUG-198）。
class _SubtitleCharTapRecognizer extends TapGestureRecognizer {
  _SubtitleCharTapRecognizer({required this.hitTestChar});

  /// 按**全局**坐标判定按下点是否命中某字幕字符（与点击查词同一判据）。
  final bool Function(Offset globalPosition) hitTestChar;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    // 按下点未命中字符 → 不收指针 → 不进竞技场 → media_kit 控制条 onTap 独占胜出。
    if (!hitTestChar(event.position)) return false;
    return super.isPointerAllowed(event);
  }
}
