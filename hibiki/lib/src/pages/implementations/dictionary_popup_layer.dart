import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/swipe_dismiss_wrapper.dart';
import 'package:hibiki/utils.dart';

// 占位单例的 canonical 声明已收口到 dictionary_popup_controller.dart（controller
// 内部 seed/复位也用它，必须同一对象）；此处 re-export 维持既有宿主 import 不变。
export 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart'
    show kPopupSearchingPlaceholderResult;

Rect calcPopupPosition({
  required Rect selectionRect,
  required Size screen,
  double padding = 6.0,
  double maxWidth = 360.0,
  // 默认与单一真相源（preferences_repository.defaultPopupMaxHeight=360）对齐；
  // 两个真实调用方都显式传 appModel.popupMaxHeight，此默认仅兜底/测试用。
  double maxHeight = 360.0,
  double bottomReserve = 0.0,
  double topReserve = 0.0,

  /// 竖排（vertical-rl）时把弹窗放在当前列的左/右侧而非上/下，避免压住正在读的列。
  bool verticalWriting = false,

  /// TODO-107：竖排两侧都放不下时回退横排上下避让的最小宽度阈值。两侧可用宽度都
  /// 低于它（极窄屏 / 选区贴边把弹窗压成窄条）时，左右避让已无意义，改走横排上/下
  /// 避让把整宽留给弹窗——避免「为了不压列而把弹窗挤成一根竖条」的更差观感。
  double minPopupWidth = 200.0,

  /// TODO-107：上下避让分支若被压扁到此高度以下视为「装不下」。仅作竖排回退判据的
  /// 下界保护，避免回退横排后弹窗反而被压成一条更矮的横带——两难时不引入更差结果。
  double minPopupHeight = 120.0,
}) {
  final double reserve = bottomReserve.clamp(0, screen.height);
  final double effectiveTop = topReserve.clamp(0, screen.height);
  final double effectiveBottom = screen.height - reserve;
  final double horizontalInset = padding.clamp(0, screen.width / 2);
  final double verticalInset = padding.clamp(0, effectiveBottom / 2);
  final double availableWidth =
      (screen.width - horizontalInset * 2).clamp(0, maxWidth);
  final double availableHeight =
      (effectiveBottom - effectiveTop - verticalInset * 2).clamp(0, maxHeight);
  final double minLeft = horizontalInset;
  final double minTop = effectiveTop + verticalInset;
  final double maxBottom = effectiveBottom - verticalInset;
  final double maxRight = screen.width - horizontalInset;

  // 当 top+bottom 预留合计超过屏高时 minTop 会越过 maxBottom，使后续 clamp 上下界
  // 反转抛错；夹住 minTop 不超过 maxBottom，两分支共用。
  final double safeMinTop = minTop.clamp(0, maxBottom).toDouble();

  const double gap = 4.0;

  // 横排上/下避让：把弹窗整宽放在选区上方或下方，绝不与 selectionRect 垂直重叠
  // （BUG-098）。竖排两侧都放不下时也回退到它（TODO-107），故抽成共用闭包。
  Rect placeAboveBelow() {
    final double width = availableWidth;
    // 高度直接用 availableHeight（已按 maxHeight 与屏幕可用空间双重 clamp）。
    // 旧实现额外乘 0.5 把高度顶死在半屏，使「弹窗最大高度」设置在半屏以上失效；
    // 去掉后高度设置真正说了算，最高可拉到接近整屏（减边距）。
    double height = availableHeight;
    final double maxLeft = screen.width - width - horizontalInset;

    // BUG-098: the popup must never cover the looked-up word. Place it flush
    // against the selection (above or below) and, when neither side fits the
    // full height, pick the side with more room and shrink the popup to that
    // room — so its rect never overlaps [selectionRect]. The old
    // `top.clamp(maxTop)` pulled a too-tall "below" popup back up over the
    // selection.
    final double roomBelow = maxBottom - (selectionRect.bottom + gap);
    final double roomAbove = (selectionRect.top - gap) - safeMinTop;
    final bool below = height <= roomBelow
        ? true
        : (height <= roomAbove ? false : roomBelow >= roomAbove);

    double top;
    if (below) {
      if (height > roomBelow) height = roomBelow.clamp(0, availableHeight);
      top = selectionRect.bottom + gap;
    } else {
      if (height > roomAbove) height = roomAbove.clamp(0, availableHeight);
      top = (selectionRect.top - gap) - height;
    }
    // Final guard: keep the rect on-screen without re-introducing overlap (the
    // upper bound never drops below minTop / the chosen flush edge).
    final double maxTop = (maxBottom - height).clamp(safeMinTop, maxBottom);
    top = top.clamp(safeMinTop, maxTop);

    double left = selectionRect.left;
    left = left.clamp(minLeft, maxLeft);

    return Rect.fromLTWH(left, top, width, height);
  }

  if (verticalWriting) {
    // 竖排 vertical-rl：右→左读，右侧是已读列。优先把弹窗贴当前列右侧（盖已读、
    // 不挡左边还没读的下一列）；右侧放不下才退到左侧。竖直方向锚到选区顶端往下铺，
    // 与列并排——不与 selectionRect 水平重叠即不压当前列。
    double width = availableWidth;
    final double height = availableHeight;
    final double roomRight = maxRight - (selectionRect.right + gap);
    final double roomLeft = (selectionRect.left - gap) - minLeft;

    // TODO-107：两侧都装不下整宽弹窗、且都低于最小宽阈值时，左右避让只会把弹窗压成
    // 一根挡视线的窄竖条——回退横排上/下避让（placeAboveBelow）把整宽让给弹窗，改从
    // 竖直方向避开当前列。仅当横排回退确有可用高度（>=minPopupHeight）才回退，否则
    // 保留原竖排逻辑（极端两难时不引入更差结果）。
    final bool widthFitsAside = width <= roomRight || width <= roomLeft;
    if (!widthFitsAside &&
        roomRight < minPopupWidth &&
        roomLeft < minPopupWidth) {
      final double roomBelow = maxBottom - (selectionRect.bottom + gap);
      final double roomAbove = (selectionRect.top - gap) - safeMinTop;
      final double bestVerticalRoom =
          roomBelow > roomAbove ? roomBelow : roomAbove;
      if (bestVerticalRoom >= minPopupHeight) {
        return placeAboveBelow();
      }
    }

    final bool right = width <= roomRight
        ? true
        : (width <= roomLeft ? false : roomRight >= roomLeft);
    double left;
    if (right) {
      if (width > roomRight) width = roomRight.clamp(0, availableWidth);
      left = selectionRect.right + gap;
    } else {
      if (width > roomLeft) width = roomLeft.clamp(0, availableWidth);
      left = (selectionRect.left - gap) - width;
    }
    final double maxLeftV = (maxRight - width).clamp(minLeft, maxRight);
    left = left.clamp(minLeft, maxLeftV);

    final double maxTopV = (maxBottom - height).clamp(safeMinTop, maxBottom);
    final double top = selectionRect.top.clamp(safeMinTop, maxTopV);
    return Rect.fromLTWH(left, top, width, height);
  }

  return placeAboveBelow();
}

/// TODO-872：app 外悬浮字幕条（FloatingLyricService 系统悬浮窗）查词弹窗的位置。
/// 被查字的屏幕矩形 [glyphRect]（逻辑像素，与全屏弹窗窗口同坐标系）作为锚点，弹窗
/// 贴在该字上方或下方、绝不盖住被查字——复用 [calcPopupPosition] 久经考验的横排上/下
/// 避让 + clamp 逻辑（单行字幕无竖排，故 verticalWriting 恒 false），避免重复实现一套
/// 几何。返回的矩形 left/top/width/height 直接喂给 Positioned。纯函数。
Rect computeFloatingLyricPopupRect({
  required Rect glyphRect,
  required Size screen,
  required double maxWidth,
  required double maxHeight,
  double gap = 6.0,
}) {
  return calcPopupPosition(
    selectionRect: glyphRect,
    screen: screen,
    padding: gap,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
  );
}

/// TODO-108：底部固定（dock）模式下的弹窗矩形——忽略选区位置，把弹窗放成屏幕底部
/// 一条全宽面板。[screen] 是可用区域大小；[inset] 是左右及离屏底的内边距；[dockedHeight]
/// 是面板目标高度（会按可用高度 clamp）；[bottomReserve]/[topReserve] 与跟随模式同义
/// （底栏/状态栏等预留），保证 dock 面板不被这些区域遮住。纯函数，reader 与 video 两个
/// 收口点共用同一实现，保证两表面 dock 行为一致。
Rect dockedPopupRect({
  required Size screen,
  double inset = 6.0,
  double dockedHeight = 360.0,
  double bottomReserve = 0.0,
  double topReserve = 0.0,
}) {
  final double reserve = bottomReserve.clamp(0, screen.height);
  final double effectiveTop = topReserve.clamp(0, screen.height);
  final double effectiveBottom = screen.height - reserve;
  final double horizontalInset = inset.clamp(0, screen.width / 2);
  final double verticalInset =
      inset.clamp(0, (effectiveBottom).clamp(0, screen.height) / 2);
  final double width =
      (screen.width - horizontalInset * 2).clamp(0, screen.width);
  final double maxAvail = (effectiveBottom - effectiveTop - verticalInset * 2)
      .clamp(0, screen.height);
  final double height = dockedHeight.clamp(0, maxAvail);
  final double top = (effectiveBottom - verticalInset - height)
      .clamp(effectiveTop + verticalInset, effectiveBottom)
      .toDouble();
  return Rect.fromLTWH(horizontalInset, top, width, height);
}

/// 查词弹窗位置分流的单一收口：[bottomDocked] 时忽略选区返回屏幕底部全宽 dock 面板
/// （[dockedPopupRect]），否则跟随选区（[calcPopupPosition]）。
///
/// 收口自 base_source_page._calculatePopupPosition（reader/有声书/独立查词页家族）
/// 与 dictionary_page_mixin._calcMixinPopupPosition（video/首页/texthooker 家族）两份
/// 语义同构的包装器。两者差异仅在传参：base 传实例 getter 的 padding/reserve/
/// verticalWriting（子类可 override），mixin 全用默认 0。故此处把它们全参数化，
/// 默认值（padding=6.0/reserve=0/verticalWriting=false）与底层默认一致，两家族各自
/// 传自己的值即行为不变。
Rect resolvePopupRect({
  required Rect selectionRect,
  required Size screen,
  required bool bottomDocked,
  required double maxWidth,
  required double maxHeight,
  double padding = 6.0,
  double bottomReserve = 0.0,
  double topReserve = 0.0,
  bool verticalWriting = false,
}) {
  if (bottomDocked) {
    return dockedPopupRect(
      screen: screen,
      inset: padding,
      dockedHeight: maxHeight,
      bottomReserve: bottomReserve,
      topReserve: topReserve,
    );
  }
  return calcPopupPosition(
    selectionRect: selectionRect,
    screen: screen,
    padding: padding,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    bottomReserve: bottomReserve,
    topReserve: topReserve,
    verticalWriting: verticalWriting,
  );
}

/// Phase B 拖拽尺寸（2026-07-15）— 把贴词算出的 [anchored] rect 的**原点钉回**
/// [topLeft]（拖拽起始时那张卡的左上角），只保留其尺寸并夹住不越出屏幕（右下不出界）。
///
/// 根因：[calcPopupPosition] 在词靠右缘（横排）或词在右侧（竖排）时，弹窗左缘由
/// 「词位置 − 宽度」推出（右缘锚在词），故宽度一变大 left 就左移。用户拖**右下**把手时
/// 期望「左上不动、右下生长」（标准 resize），左移就成了「从右下拖却从左上动」的 bug。
/// 拖拽期间及被拖的这张卡后续渲染都用本函数把原点冻结在拖拽起点——消除该特殊情况，且
/// 松手不回跳（尺寸落偏好后同一选区仍读冻结原点，直到换词/关窗）。
///
/// [inset] = 屏幕边距（popupPadding）。尺寸取 [anchored] 的（已按当前 max/预览 + 屏幕
/// clamp），再从冻结原点二次夹住确保右/下不出屏。
Rect anchorPopupTopLeft({
  required Rect anchored,
  required Offset topLeft,
  required Size screen,
  required double inset,
}) {
  final double maxLeft = (screen.width - inset).clamp(0.0, screen.width);
  final double maxTop = (screen.height - inset).clamp(0.0, screen.height);
  final double left = topLeft.dx.clamp(inset.clamp(0.0, maxLeft), maxLeft);
  final double top = topLeft.dy.clamp(inset.clamp(0.0, maxTop), maxTop);
  final double width = anchored.width
      .clamp(0.0, (screen.width - inset - left).clamp(0.0, screen.width));
  final double height = anchored.height
      .clamp(0.0, (screen.height - inset - top).clamp(0.0, screen.height));
  return Rect.fromLTWH(left, top, width, height);
}

/// 把一个弹窗层 [child] 按 [pos] 摆放；隐藏层（[visible]=false，即 BUG-094 常驻热槽 /
/// TODO-058 挂起冷层）停到屏幕右外侧 `(screen.width + 8, 0)` 继续预热。
///
/// BUG-135：隐藏热槽的 Android `InAppWebView` 是原生平台视图，即使被 [Visibility] 的
/// `Opacity(0)+IgnorePointer` 包住也照样截获触摸、盖住正文/控件点击；停到屏外（仍保持
/// 真实尺寸冷加载，宿主 Stack 须用 `Clip.none` 不裁）才放掉触摸。[Visibility] 的
/// `maintainState/Animation/Size` 让 WebView 在树里活着、查词时翻可见。
/// base_source_page._buildPopupLayer 与 dictionary_page_mixin.buildNestedPopupLayer
/// 此前各写一份此 parking + Visibility 几何（BUG-135 的 `parked ? width+8` 改一处忘另
/// 一处即漂移），收口于此；两宿主各自的 [DictionaryPopupLayer] 回调差异留在各自方法。
Widget parkedPopupLayer({
  Key? key,
  required Rect pos,
  required bool visible,
  required Size screen,
  required Widget child,
}) {
  return Positioned(
    key: key,
    left: visible ? pos.left : screen.width + 8,
    top: visible ? pos.top : 0,
    width: pos.width,
    height: pos.height,
    child: Visibility(
      visible: visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      // TODO-890 姊妹项：入场淡入。四表面共用此收口，一处补齐全部。
      child: _PopupEntranceFade(visible: visible, child: child),
    ),
  );
}

/// TODO-890 姊妹项：查词弹窗**入场淡入**收口。app 外覆盖窗靠注入 CSS
/// `transition:opacity 200ms ease-out` + 双 gate 翻 `opacity 0→1` 做平滑淡入；app 内
/// 各表面（阅读器 / 视频 / 首页 / 安卓独立窗）此前经 [parkedPopupLayer] 的 [Visibility]
/// **硬切**出现，观感生硬且冷路径显得慢。此包装器把「隐藏→可见」补成
/// [_kSlideDuration] / easeOut 淡入，与 app 外及本层既有的 swipe 滑出淡出（同一常量 /
/// 曲线）三处统一。
///
/// 关键：[ImplicitlyAnimatedWidget] 首帧取目标值不补间，故不能只写
/// `AnimatedOpacity(opacity: visible ? 1 : 0)`——首次挂载即 `visible:true` 的
/// 视频 / 首页 / 独立窗会跳过淡入。这里用「首帧强制 0 + post-frame 翻 1」保证每次进入
/// 可见态都淡入（含首帧即可见），镜像 app 外「shell 默认 opacity:0，reveal gate 齐才翻 1」。
class _PopupEntranceFade extends StatefulWidget {
  const _PopupEntranceFade({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_PopupEntranceFade> createState() => _PopupEntranceFadeState();
}

class _PopupEntranceFadeState extends State<_PopupEntranceFade> {
  /// 入场淡入是否已触发（[AnimatedOpacity] 目标翻 1）。隐藏态复位，下次可见重新淡入。
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _scheduleReveal();
  }

  @override
  void didUpdateWidget(_PopupEntranceFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _revealed = false; // 重新进入可见态：复位以再次淡入。
      _scheduleReveal();
    } else if (!widget.visible && oldWidget.visible) {
      _revealed = false; // 隐藏即复位，避免下次瞬间满不透明。
    }
  }

  /// 下一帧把 [_revealed] 翻 true，使 [AnimatedOpacity] 从首帧的 0 补间到 1
  /// （同帧内 0→1 会被隐式动画当作初值直接取 1、不补间）。
  void _scheduleReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.visible && !_revealed) {
        setState(() => _revealed = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      // 墨水屏模式：淡入归零为瞬时显示——慢刷新屏上 0→1 补间是一段灰阶残影，
      // 且弹窗「先出壳后出内容」的观感在 e-ink 上尤其糟。
      opacity: widget.visible && _revealed ? 1.0 : 0.0,
      duration: isEinkTheme(context) ? Duration.zero : _kSlideDuration,
      curve: Curves.easeOut,
      child: widget.child,
    );
  }
}

/// Maps a word rect reported in the popup WebView's own coordinate space
/// ([localRect] — CSS px == the WebView's logical px, origin at the WebView's
/// top-left) to absolute screen coordinates, using the WebView's *live*
/// rendered geometry via [webViewKey].
///
/// BUG-129: a nested lookup must place the child popup against the word the user
/// actually selected inside the parent popup. The parent popup's `Positioned`
/// rect is NOT the WebView's origin — the WebView sits below the popup header
/// (the index-0 audio/favorite controls, ~48px tall) and inside the popup
/// surface border, and may be scaled by ancestor transforms (appUiScale).
/// Reconstructing the rect as `localRect.shift(positioned.topLeft)` ignores all
/// of that, placing the child popup ~header-height above the real word so it
/// covers the very word being looked up. Asking the rendered WebView's
/// [RenderBox] where its corners map (`localToGlobal`) walks the real transform
/// chain, accounting for the header offset, border inset, and any scale in one
/// shot. Falls back to [fallback] only when the render box is unavailable
/// (should not happen at selection time — the parent popup is on-screen).
Rect popupWordScreenRect({
  required GlobalKey webViewKey,
  required Rect localRect,
  required Rect fallback,
}) {
  final RenderObject? obj = webViewKey.currentContext?.findRenderObject();
  if (obj is RenderBox && obj.attached && obj.hasSize) {
    final Offset topLeft = obj.localToGlobal(localRect.topLeft);
    final Offset bottomRight = obj.localToGlobal(localRect.bottomRight);
    return Rect.fromPoints(topLeft, bottomRight);
  }
  return fallback;
}

// [kPopupSearchingPlaceholderResult]（BUG-080 搜索期预挂载共享空结果）现声明于
// dictionary_popup_controller.dart，经文件头 export 在此可用（_buildBody 的
// `result ?? kPopupSearchingPlaceholderResult` 兜底与热槽 seed 是同一单例）。

class DictionaryPopupLayer extends StatelessWidget {
  const DictionaryPopupLayer({
    required this.result,
    required this.webViewKey,
    required this.onDismiss,
    required this.onTextSelected,
    required this.onLinkClick,
    required this.onMineEntry,
    required this.onDuplicateCheck,
    this.onOverwriteTargetNoteId,
    this.onMinedCardAction,
    this.onOpenInAnki,
    this.onUpdateEntry,
    this.onFavoriteEntry,
    this.onFavoriteCheck,
    this.onAppendSentence,
    this.onSetSentenceContext,
    this.onClearSentenceDraft,
    this.onSentenceContextPreview,
    this.onOpenSentenceContextModal,
    this.isSearching = false,
    this.keepWebViewWarm = false,
    this.hasChildPopup = false,
    this.onTapOutside,
    this.onScrolledToBottom,
    this.onRendered,
    this.onRenderError,
    this.inputSpec = const DictionaryPopupInputSpec(),
    this.onHostInputToken,
    this.headerWidget,
    this.overlayWidget,
    this.isDark = false,
    this.overrideFillColor,
    this.showBorder = true,
    this.swipeDismissible = true,
    this.enableSwipeToClose = true,
    this.onClose,
    this.onBack,
    this.transparentDocumentBackground = false,
    this.showResizeGrip = false,
    this.onResizeStart,
    this.onResizeUpdate,
    this.onResizeEnd,
    this.onResizeCancel,
    super.key,
  });

  final DictionarySearchResult? result;
  final bool isSearching;

  /// When true, the popup's [DictionaryPopupWebView] is mounted (and stays
  /// mounted) even with no results and not searching — so the WebView cold-loads
  /// popup.html + JS + CSS ONCE while idle/hidden and is then reused warm for
  /// every later lookup. Used by the persistent warm slot in
  /// [BaseSourcePageState] (BUG-092) to kill the per-lookup white flash on the
  /// reader/video/audiobook surfaces.
  final bool keepWebViewWarm;

  /// TODO-869：本层弹窗是否有子（后代）弹窗。透传给 [DictionaryPopupWebView] 注入
  /// `window.__hasChildPopup`，让 popup.js 点卡片本体留白时据此关后代层（有子层才发
  /// tapOutside，叶子层不发，保持 TODO-859）。宿主按 `index < entries.length - 1` 派生。
  final bool hasChildPopup;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey;
  final VoidCallback onDismiss;
  final void Function(String text, Rect localRect) onTextSelected;
  final void Function(String query, Rect localRect) onLinkClick;
  final Future<MinePopupResult> Function(Map<String, String> fields)
      onMineEntry;

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId] + 新字段）。null 时弹窗不进
  /// 「最新可改」第三态，点 ✓ 仍走旧的查重/再制流程（向后兼容）。
  final Future<MinePopupResult> Function(
      int noteId, Map<String, String> fields)? onUpdateEntry;
  final Future<bool> Function(String expression, String reading)
      onDuplicateCheck;

  /// TODO-614：覆写范围=「全部」时按内容反查可覆写的已存在 note id（多张取最近），
  /// 透传给 [DictionaryPopupWebView] 让更早的卡也能进「✓↩ 最新可改」态。null 时弹窗
  /// 维持旧两态行为（默认 latest / AnkiDroid 降级）。
  final Future<int?> Function(String expression, String reading)?
      onOverwriteTargetNoteId;

  /// TODO-1007/1008：点 ✓（卡已存在）弹操作选择（覆写/新增重复卡/查看·在 Anki 中打开），
  /// 命中多张让用户选。透传给 [DictionaryPopupWebView]。null 时回退旧两态行为。
  final Future<MinePopupResult> Function(Map<String, String> fields)?
      onMinedCardAction;

  /// TODO-1360：已制卡的词旁「在 Anki 中打开卡片」按钮回调，透传给
  /// [DictionaryPopupWebView]。宿主据 expression/reading 反查并直接在 Anki 中打开命中卡。
  final Future<void> Function(String expression, String reading)? onOpenInAnki;
  final Future<bool> Function(Map<String, String> fields)? onFavoriteEntry;
  final Future<bool> Function(String expression, String reading)?
      onFavoriteCheck;

  /// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：弹窗「+句」追加当前句到宿主草稿，
  /// 返回累积句数。null 时弹窗不渲染「+句」按钮（纯查词页 / 视频 E 未接入前向后兼容）。
  final Future<int> Function()? onAppendSentence;

  /// TODO-393：「上 N 句 / 下 N 句」上下文选择回调，透传给 webview。
  final Future<int> Function(int prevCount, int nextCount)?
      onSetSentenceContext;

  /// TODO-382「+句」可撤销：弹窗点「清空已加句子」清空宿主草稿，返回清空后句数（恒 0）。
  /// 与 [onAppendSentence] 同生命周期：支持草稿的表面非空，纯查词页 null（不渲染清空入口）。
  final Future<int> Function()? onClearSentenceDraft;

  /// Niratan「制卡前调整·选择句子上下文」：弹窗拉取当前草稿真实上下文句 + 词偏移做
  /// 预览的回调，透传给 webview。null 时弹窗不渲染「调整上下文」按钮（与 [onSetSentenceContext]
  /// 同生命周期，仅支持草稿的表面非空）。
  final Future<Map<String, Object?>> Function()? onSentenceContextPreview;

  /// BUG-763/766：弹窗点某词条「调整上下文」→ 宿主弹 app 原生顶层对话框。透传给 webview。
  final Future<void> Function(int entryIndex, String matched)?
      onOpenSentenceContextModal;
  final VoidCallback? onTapOutside;
  final VoidCallback? onScrolledToBottom;
  final VoidCallback? onRendered;

  /// TODO-058 fail-safe：弹窗 WebView 主框架加载失败时触发，宿主据此立即翻可见
  /// 挂起的冷层（加载失败也显示，不卡死）。
  final VoidCallback? onRenderError;

  /// 弹窗内要交回宿主的输入集合（键盘 token + 鼠标按钮），见 [DictionaryPopupInputSpec]。
  final DictionaryPopupInputSpec inputSpec;

  /// [inputSpec] 命中时弹窗回传的 token。
  final ValueChanged<String>? onHostInputToken;
  final Widget? headerWidget;
  final Widget? overlayWidget;
  final bool isDark;
  final Color? overrideFillColor;
  final bool showBorder;
  final bool swipeDismissible;

  /// TODO-407②：平台级"滑动关闭"开关。与 [swipeDismissible] 取并（两者皆真才挂
  /// [SwipeDismissWrapper]）：调用方用 [swipeDismissible] 表达"此层是否允许滑关"
  /// （如 popup_dictionary_page 基础层 false），用 [enableSwipeToClose] 表达"当前
  /// 平台/偏好是否允许滑关"（Windows/Linux 默认 false）。
  final bool enableSwipeToClose;

  /// TODO-407①：顶层右端"X 关闭"按钮的回调。非空时弹窗顶栏渲染一个始终可关的 X
  /// （任何平台、即便滑关被禁用也能关）。点 X 走各表面既有的关闭汇聚点。
  final VoidCallback? onClose;

  /// TODO-485：嵌套层左端"返回"按钮的回调。非空时弹窗顶栏渲染一个不依赖滑动
  /// 的返回入口，语义是关闭当前子层并回到父层。
  final VoidCallback? onBack;

  /// TODO-1065：转发给 [DictionaryPopupWebView] —— 本层属「app 外 / 悬浮字幕」独立
  /// 查词窗（popup_main 宿主）时 true，令弹窗 `<html>` 透明消除整窗泛白（默认 false =
  /// in-app 行为，见 DictionaryPopupWebView.transparentDocumentBackground）。
  final bool transparentDocumentBackground;

  /// 弹窗尺寸拖拽（2026-07-13 设计 Phase B）：为真时在弹窗右下角叠一个可拖拽把手，
  /// 拖动 = 可视化地改「最大宽/高」偏好（`popupMaxWidth/Height`，与设置页两滑杆同一
  /// 真值）。仅 app 内 reader / video 两宿主开启（默认 false，app 外覆盖窗 / 嵌套返回层
  /// 不受影响）。三个回调都非空时才真正渲染并接线把手。
  final bool showResizeGrip;

  /// 拖拽开始：宿主据此把当前基准尺寸存入预览态（[onResizeUpdate] 累积于其上）。
  final VoidCallback? onResizeStart;

  /// 拖拽进行：[deltaPx] 是本次指针增量位移（弹窗盒坐标系，已缩放逻辑像素）。宿主
  /// 经 `resolveDraggedLookupSize` 折算回基准并实时预览。
  final void Function(Offset deltaPx)? onResizeUpdate;

  /// 拖拽结束：宿主把预览尺寸一次性落偏好（`setPopupMaxWidth/Height`）。
  final VoidCallback? onResizeEnd;

  /// 拖拽被竞技场中途取消（不走 [onResizeEnd]）：宿主借此丢弃预览态、还原到已落库
  /// 尺寸，避免弹窗悬停在预览尺寸；偏好从不会因取消被写坏。
  final VoidCallback? onResizeCancel;

  /// 拖拽把手的测试锚点（widget 测试用 `find.byKey` 定位后模拟 pan）。
  static const Key resizeGripKey =
      ValueKey<String>('dictionary-popup-resize-grip');

  /// TODO-406/407：滑动关闭是否生效——平台/偏好开关（[enableSwipeToClose]）与调用方
  /// 层级开关（[swipeDismissible]）同时为真才挂 [SwipeDismissWrapper]。
  bool get _swipeActive => swipeDismissible && enableSwipeToClose;

  static const BoxConstraints _topActionConstraints =
      BoxConstraints.tightFor(width: 36, height: 36);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fillColor = overrideFillColor ?? colorScheme.surface;

    final Widget? topBar = _buildTopBar(context);
    final Widget body = _buildContent(context, fillColor);

    final Widget surfaceChild;
    if (topBar != null) {
      // TODO-406：可拖/可滑区收敛到顶栏（header + X）。WebView 正文 body 不在
      // [SwipeDismissWrapper] 的 Listener 子树内——正文里左键框选的指针位移序列
      // 不再冒泡进滑动判定，彻底消除"框选误触滑动关闭"。
      final Widget topRegion = _swipeActive
          ? SwipeDismissWrapper(
              sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
              onDismiss: onDismiss,
              child: topBar,
            )
          : topBar;
      // TODO-1187：分隔线从 header widget 内的无条件底边框移到这里，只在「有 header
      // 星标/音频行」且「有可渲染词条」时才画。无结果（「未找到搜索结果」占位）/ 搜索中
      // 不画，消除悬在收藏行与占位卡之间的多余横线。app 外覆盖窗 / 嵌套返回层无
      // [headerWidget]（topBar 只有关闭/返回按钮）—— 从来没有这条线，此处也不画，不受影响。
      final bool showHeaderDivider =
          headerWidget != null && _hasRenderableResults;
      surfaceChild = Column(
        children: <Widget>[
          topRegion,
          if (showHeaderDivider)
            Divider(
              height: 0.5,
              thickness: 0.5,
              color: Theme.of(context).dividerColor,
            ),
          Expanded(child: body),
        ],
      );
    } else {
      // 无顶栏的层（如 app 外查词页 popup_dictionary_page 的嵌套返回层）保留旧的
      // 整窗滑动语义，不改其既有横滑返回行为；其余表面顶层恒有顶栏走上面分支。
      surfaceChild = body;
    }

    final Widget surface = HibikiPopupSurface(
      color: fillColor,
      showBorder: showBorder,
      clipBehavior: showBorder ? Clip.antiAlias : Clip.none,
      child: surfaceChild,
    );

    // TODO-805：弹窗的「关闭命中区」必须等于弹窗的可视矩形。宿主把弹窗摆在
    // [parkedPopupLayer] 的 `Positioned` 矩形里，全屏 dismiss barrier 是这块矩形的
    // **补集**（点矩形外 → barrier → 关一层）。但 [HibikiPopupSurface] 是 `Material`，
    // 圆角 `Clip.antiAlias` 让 `RenderPhysicalShape.hitTest` 按圆角形状裁剪命中：圆角
    // 弧外的角落（仍在 `Positioned` 矩形内、视觉上仍是弹窗）命中假 → 漏到下面的
    // barrier → 关窗；透明 WebView 正文外的余白、顶栏空白同理。用户因此感到「点击
    // 消失的位置和弹窗外边有差异」。包一层 `HitTestBehavior.opaque` 的吸收层，使整个
    // `Positioned` 矩形（含圆角余白）一律命中真值、停在弹窗层不再下穿 barrier；空
    // `onTap` 在竞技场必输给任何子识别器，按钮 / WebView / 顶栏滑动判定一律不受影响。
    //
    // TODO-880：手机滑关回归 + 桌面开关不生效都在这一层修。TODO-406 把可滑区砍到 40px
    // 顶栏后，那条裸 [SwipeDismissWrapper] 的 `Listener` 与本 opaque 吸收层 + header
    // 按钮在窄带里同处竞技场，横拖被判成 tap / 被按钮吞 → 手机滑关失效；桌面 716
    // barrier 横拖只在弹窗矩形**外**生效，用户在弹窗本体上拖永远到不了它 → 开关「开了
    // 也没用」。在 **同一个** opaque GestureDetector 上追加 `onHorizontalDrag*`：tap 与
    // 横拖共享一个识别器，Flutter 竞技场天然把单击走 `onTap`、横拖走 drag，互斥不互吞，
    // 可滑区自然恢复到整窗（含顶栏 + 正文外余白），与 805 前体验一致。受
    // [enableSwipeToClose] 门控（关时只 onTap 如旧）；阈值/灵敏度与顶栏 wrapper、716
    // barrier 同源（[swipeDismissThreshold] + [dismissSwipeSensitivity]）。双向水平
    // （左右皆可，对齐手机 `_dragX.abs()`）。顶栏原 wrapper 保留（冗余但无害）。
    //
    // 仅有顶栏的层让本吸收层兼管「弹窗本体横拖关」（[bodySwipe]=true）；无顶栏的层
    // （popup_dictionary_page 嵌套返回层）仍交给下方整窗 [SwipeDismissWrapper]（保留其
    // 横滑动画反馈），本层只 onTap 吸收命中，避免两条路径同时触发 [onDismiss] 双关。
    final bool bodySwipe = _swipeActive && topBar != null;
    final Widget content = _BodySwipeDismissDetector(
      enableSwipeToClose: bodySwipe,
      onDismiss: onDismiss,
      child: surface,
    );

    final Widget shell = (topBar != null || !_swipeActive)
        ? content
        : SwipeDismissWrapper(
            sensitivity: ReaderHibikiSource.instance.dismissSwipeSensitivity,
            onDismiss: onDismiss,
            child: content,
          );

    return _maybeWrapResizeGrip(shell);
  }

  /// 尺寸拖拽（Phase B）：仅当 [showResizeGrip] 且已接线 [onResizeUpdate] 时，在弹窗
  /// 盒右下角叠一个拖拽把手。把手是 [Stack] 的**同级顶层**（不在 [SwipeDismissWrapper]
  /// / [_BodySwipeDismissDetector] 子树内），其 `HitTestBehavior.opaque` 在右下角吸收
  /// 命中，pan 识别器在竞技场天然赢过下面的滑关/关窗判定，故绝不破坏既有滑动关闭 /
  /// barrier / 嵌套弹窗几何（Never break userspace）。外层 [Stack] 填满宿主给的
  /// `Positioned` 盒，把手钉在 `right:0,bottom:0`（右下），向右增宽、向下增高——弹窗可能
  /// 锚在词上方，几何 recompute 由 `resolvePopupRect` 处理，无需在此关心锚点方向。
  Widget _maybeWrapResizeGrip(Widget shell) {
    if (!showResizeGrip || onResizeUpdate == null) return shell;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(child: shell),
        Positioned(
          right: 0,
          bottom: 0,
          child: _PopupResizeGrip(
            key: resizeGripKey,
            onStart: onResizeStart,
            onUpdate: onResizeUpdate!,
            onEnd: onResizeEnd,
            onCancel: onResizeCancel,
          ),
        ),
      ],
    );
  }

  /// 顶栏 = 可选的 [headerWidget]（reader 音频控制 / video 句子收藏星标）叠加
  /// 左端返回按钮（[onBack]）/ 右端关闭按钮（[onClose]）。三者都空时返回 null。
  ///
  /// BUG-822：旧实现用 [Stack] 把三组按钮各自 [Align] 叠在同一水平带上——左端 A−/A+、
  /// 全宽居中的 [headerWidget]（音频控制最多 4 颗按钮 ≈ 144px）、右端关闭。这是「重叠即
  /// 设计」：三层互不预留空间，弹窗宽度收窄到 [kLookupPopupMinWidth]（250）或 UI 缩放放大
  /// 时，居中的音频行向两侧张开压到 A−/A+ 与关闭按钮上，视觉上按钮相互重叠。
  ///
  /// 改成一条 [Row] 顺序排布：左簇（返回/A−/A+）→ 弹性居中的 header → 右簇（关闭）。左右
  /// 簇定宽钉在两端，中段用 [Expanded] 吃掉剩余宽度并让 header 在其中 [Center] 居中——header
  /// 被夹在两簇之间的有界宽度里，Row 顺序排布天然不重叠（消除特殊情况）。header 自身在窄宽
  /// 下的收缩由内容侧负责（reader 音频行用 `FittedBox(scaleDown)` 等比缩小，见
  /// `buildPopupAudioControls`），本层只给它有界宽度、不再全宽居中压到两侧。[Center] 给
  /// header 的是 loose 约束（0..剩余宽），故 header 即便是贪婪/无限宽（`double.infinity`）也
  /// 被夹到剩余宽，绝不抛无界宽异常；同时保住 [ReaderChromeScaler] 需要的有界宽（UI 缩放
  /// 不失效）。header 缺省（app 外覆盖窗）时中段退化成 [Spacer]，行为与旧的「只有 A−/A+ +
  /// 关闭」一致。
  Widget? _buildTopBar(BuildContext context) {
    if (headerWidget == null && onClose == null && onBack == null) {
      return null;
    }

    final String backTooltip =
        MaterialLocalizations.of(context).backButtonTooltip;

    // 左簇：返回（可选）+ A−/A+ 字号按钮（TODO-1353）。定宽，钉在行首。
    final Widget leftCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (onBack != null)
          HibikiIconButton(
            icon: Icons.arrow_back,
            size: 20,
            tooltip: backTooltip,
            constraints: _topActionConstraints,
            padding: EdgeInsets.zero,
            onTap: onBack,
          ),
        _buildZoomFontButton(context, zoomIn: false),
        _buildZoomFontButton(context, zoomIn: true),
      ],
    );

    // 右簇：关闭按钮（可选）。定宽，钉在行尾。缺省时用 0 宽占位保持 Row 结构一致。
    final Widget rightCluster = onClose != null
        ? HibikiIconButton(
            icon: Icons.close,
            size: 20,
            tooltip: t.dialog_close,
            constraints: _topActionConstraints,
            padding: EdgeInsets.zero,
            onTap: onClose,
          )
        : const SizedBox.shrink();

    // 中段：header 在左右簇之间的剩余（有界）宽度里居中，永不压到两侧按钮。收缩交给
    // 内容侧（reader 音频行内部 FittedBox），本层只负责「夹在中间、给有界宽」。
    final Widget middle = headerWidget == null
        ? const Spacer()
        : Expanded(child: Center(child: headerWidget!));

    final Widget bar = Row(
      children: <Widget>[leftCluster, middle, rightCluster],
    );

    // 无 header 的层（app 外覆盖窗/嵌套返回层）保持旧的 40 高度；有 header 时高度由
    // header 自身（[ReaderChromeScaler] 跟随 UI 缩放）决定。
    return headerWidget == null ? SizedBox(height: 40, child: bar) : bar;
  }

  /// TODO-1353 复诉：弹窗顶栏可见的 A−/A+ 手动字号按钮。点按经
  /// [DictionaryPopupWebViewState.zoomFontStep] 走与 Ctrl+滚轮完全同一条 JS 步进路径
  /// （同 [8,72] 夹紧、就地改 zoom 即时生效不闪烁、popupZoomFont 回调持久化到
  /// dictionaryFontSize），三端一致；WebView 未挂载（无结果占位/搜索中）时安全 no-op。
  ///
  /// BUG-1033：这里原本在 [HibikiIconButton] 外面**又**套了一层 [Tooltip]，而
  /// [HibikiIconButton] 自己已经为纯图标形态包了一层。两层嵌套下，更靠近 child 的内层
  /// 先命中 hover，外层那句「Ctrl+滚轮也可缩放」从来没机会显示——桌面用户看到的一直是
  /// 只有标签的单行气泡，TODO-1353 想给的提示等于没给。现在收成一层：把完整 message 直接
  /// 交给 [HibikiIconButton.tooltip]，由那唯一一层负责显示（并带
  /// [kIconButtonTooltipHoverDelay] 悬停延迟，避免子弹窗落到光标下就自动冒泡盖住父层正文）。
  Widget _buildZoomFontButton(BuildContext context, {required bool zoomIn}) {
    final String label =
        zoomIn ? t.popup_font_size_increase : t.popup_font_size_decrease;
    // 桌面才提 Ctrl+滚轮：移动端没有滚轮，多这行只会让气泡更长。
    final String message = isDesktopPlatform
        ? '$label\n${t.dictionary_font_size_zoom_hint}'
        : label;
    return HibikiIconButton(
      icon: zoomIn ? Icons.text_increase : Icons.text_decrease,
      size: 20,
      tooltip: message,
      constraints: _topActionConstraints,
      padding: EdgeInsets.zero,
      onTap: () => webViewKey.currentState?.zoomFontStep(zoomIn: zoomIn),
    );
  }

  /// TODO-1187：本层是否有可渲染词条（词条或汉字结果）。header 与 body 之间的分隔线
  /// 只在此为真时才画（无结果/搜索中不画，消除悬空多余横线）；[_buildBody] 也据此决定
  /// 是挂 WebView 还是「未找到搜索结果」占位。单一真相源，避免两处判据漂移。
  bool get _hasRenderableResults =>
      result != null &&
      (result!.entries.isNotEmpty || result!.kanjiResults.isNotEmpty);

  Widget _buildBody(BuildContext context, Color fillColor) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    final bool hasRenderableResults = _hasRenderableResults;
    final bool isSeedWarmSlot = keepWebViewWarm &&
        result != null &&
        result!.searchTerm.isEmpty &&
        !hasRenderableResults;

    // BUG-080: mount the WebView as soon as the lookup starts (while still
    // searching, before results arrive) so popup.html + JS + CSS cold-load in
    // PARALLEL with the synchronous FFI lookup instead of serially after it.
    // The WebView is transparent (settings) and popup.css body background
    // defaults to `transparent` until results push theme vars, so the empty
    // preload simply shows the themed popup surface behind the spinner — no
    // flash. Real results are pushed via the WebView's didUpdateWidget when
    // they arrive. A finished search with no results falls through to the
    // placeholder below (no WebView kept).
    //
    // A persistent hidden warm slot still mounts the WebView while seeded with
    // the shared empty result. Once a real empty lookup completes, it must fall
    // through to the Flutter placeholder instead of showing the warm WebView's
    // blank shell.
    if (hasRenderableResults || isSearching || isSeedWarmSlot) {
      return Stack(
        children: [
          DictionaryPopupWebView(
            key: webViewKey,
            transparentDocumentBackground: transparentDocumentBackground,
            result: result ?? kPopupSearchingPlaceholderResult,
            hasChildPopup: hasChildPopup,
            onTapOutside: onTapOutside,
            onTextSelected: onTextSelected,
            onLinkClick: onLinkClick,
            onMineEntry: onMineEntry,
            onUpdateEntry: onUpdateEntry,
            onDuplicateCheck: onDuplicateCheck,
            onOverwriteTargetNoteId: onOverwriteTargetNoteId,
            onMinedCardAction: onMinedCardAction,
            onOpenInAnki: onOpenInAnki,
            onFavoriteEntry: onFavoriteEntry,
            onFavoriteCheck: onFavoriteCheck,
            onAppendSentence: onAppendSentence,
            onSetSentenceContext: onSetSentenceContext,
            onOpenSentenceContextModal: onOpenSentenceContextModal,
            onClearSentenceDraft: onClearSentenceDraft,
            onSentenceContextPreview: onSentenceContextPreview,
            onScrolledToBottom: onScrolledToBottom,
            onRendered: onRendered,
            onRenderError: onRenderError,
            inputSpec: inputSpec,
            onHostInputToken: onHostInputToken,
          ),
          // 搜索期且还没有词条时，用一层不透明主题色盖板（带进度条）盖住 WebView。
          // 视频（mixin reuseWarmSlot）会在结果就绪前就把热槽设为可见，此刻 WebView
          // 是空载——Windows 的 inappwebview fork 不完全尊重 transparentBackground，
          // 会露出白底（用户报「白屏等一会才出字」）。盖板把这段空白替换成与弹窗同色的
          // 加载态，待词条到达即撤掉露出已渲染内容。书内查词结果就绪后才可见
          // （那时 hasRenderableResults=true 不触发）、分页 load-more 有词条也不触发，故只对
          // 视频这条「可见+搜索中+无词条」路径生效，四个表面共用同一组件、观感一致。
          if (isSearching && !hasRenderableResults)
            Positioned.fill(
              child: ColoredBox(
                color: fillColor,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      backgroundColor: Colors.transparent,
                      color: Theme.of(context).colorScheme.primary,
                      minHeight: 2.75,
                    ),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: HibikiPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
          iconSize: 20,
          messageStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color fillColor) {
    Widget body = _buildBody(context, fillColor);
    if (overlayWidget != null) {
      body = Stack(
        children: [
          body,
          Positioned.fill(child: overlayWidget!),
        ],
      );
    }
    // header 不再在此处包 Column——顶栏（header + X）由 [build] 经 [_buildTopBar]
    // 渲染并与 body 拆成上下两块，使 swipe 只裹顶栏、body 脱离滑动判定（TODO-406）。
    return body;
  }
}

/// TODO-880：弹窗本体（含顶栏）的「opaque 命中吸收 + 水平滑动关闭」收口层。
///
/// 永远是 `HitTestBehavior.opaque` 的吸收层（TODO-805：整个 `Positioned` 矩形命中真
/// 值、不下穿 barrier，按钮/WebView 不受影响）。
///
/// BUG-1242：这里不能再注册 Flutter `HorizontalDragGestureRecognizer`。Windows
/// `CustomPlatformView` 的触摸通过 raw pointer 注入 WebView2；父层横拖识别器一旦把稍带
/// 横向抖动的纵向滚动赢进 gesture arena，平台视图会收到 cancel，表现就是查词结果滑好几次
/// 才偶尔响应。改用不参与竞技场的 raw [Listener] 旁路观察触摸轨迹：只有明确横向主导后
/// 才更新退场动画，纵向轨迹永不取消 WebView 的原生滚动。
///
/// 当 [enableSwipeToClose] 为真时，明确横向触摸拖动
/// 期间 [Transform.translate] 实时跟手（[_dragX]）+ 随位移淡出；松手时按累计 dx 是否过
/// [swipeDismissThreshold]（灵敏度取 [dismissSwipeSensitivity]，与顶栏 wrapper / 716
/// barrier 同源）分流——
///   * 过阈值：用 [AnimationController] 从当前 [_dragX] 朝拖动方向补间滑出屏外
///     （位移 = 卡片宽 + [_kSlideOutMargin]）+ 淡出，[_kSlideDuration] / easeOut，
///     **动画完成回调里**才调 [onDismiss]（关一层）——宿主在弹窗已滑出不可见之后才移除，
///     用户看到顺滑滑走而非瞬时消失。
///   * 未过阈值：补间弹回原位（spring-back）。
/// 双向水平（[_dragX].abs()，对齐手机）。鼠标拖选不参与本体滑关（顶栏仍有专用
/// [SwipeDismissWrapper]），避免正文框选触发退场。
///
/// TODO-890 复用复位：reader 复用同一槽位（[Visibility] 保留、换新 child）时，
/// [didUpdateWidget] 监测 child 身份变化并复位 [AnimationController] / [_dragX]，
/// 否则复用后的弹窗卡在「已滑出 opacity 0」不可见（镜像 [SwipeDismissWrapper] 的
/// `_dismissing` + `didUpdateWidget` 复位契约）。
class _BodySwipeDismissDetector extends StatefulWidget {
  const _BodySwipeDismissDetector({
    required this.enableSwipeToClose,
    required this.onDismiss,
    required this.child,
  });

  final bool enableSwipeToClose;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_BodySwipeDismissDetector> createState() =>
      _BodySwipeDismissDetectorState();
}

/// TODO-890：滑出/弹回补间时长与曲线（plan 决策点：200ms easeOut，出场与弹回同曲线）。
const Duration _kSlideDuration = Duration(milliseconds: 200);

/// TODO-890：滑出目标位移 = 卡片宽 + 该边距，保证弹窗矩形完全移出可视区（plan 决策点：
/// 用卡片宽而非整屏宽，避免大屏上动画过慢）。
const double _kSlideOutMargin = 24.0;

class _BodySwipeDismissDetectorState extends State<_BodySwipeDismissDetector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 当前水平位移（px）。跟手期由拖动累计；松手补间期由 [_controller] 在
  /// [_dragStartX]→[_dragTargetX] 间插值驱动。
  double _dragX = 0;

  /// 跟手期的卡片宽度（[LayoutBuilder] 提供），决定滑出目标位移与淡出归一分母。
  double _layerWidth = 0;

  /// 补间起止位移（松手时定）。
  double _dragStartX = 0;
  double _dragTargetX = 0;

  /// 过阈值滑出补间是否在进行——完成时调 [onDismiss]（弹回补间不调）。
  bool _dismissing = false;

  /// 当前仍按下的可触摸指针。出现第二根指针后，本轮手势永久失效，直到所有指针
  /// 都抬起；不能在其中一根抬起后把剩余指针重新解释成一次新的单指横滑。
  final Set<int> _activePointers = <int>{};
  int? _trackedPointer;
  Offset? _pointerStart;

  /// null=尚未判轴，true=横拖关闭候选，false=纵向/斜向滚动（交还 WebView）。
  bool? _pointerIsHorizontal;

  double get _threshold => swipeDismissThreshold(
        ReaderHibikiSource.instance.dismissSwipeSensitivity,
      );

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _kSlideDuration)
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 墨水屏模式：滑出/弹回补间归零（Duration.zero 的 forward 立即 complete，
    // onDismiss 时序不变，只是不再画补间帧）。跟随主题切换双向生效。
    _controller.duration =
        isEinkTheme(context) ? Duration.zero : _kSlideDuration;
  }

  @override
  void didUpdateWidget(_BodySwipeDismissDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 复用同一槽位换新 child：复位退场态，否则复用后的弹窗卡在「已滑出 opacity 0」。
    if (_dismissing && !identical(oldWidget.child, widget.child)) {
      _controller.stop();
      _dismissing = false;
      _dragX = 0;
      _dragStartX = 0;
      _dragTargetX = 0;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTick() {
    final double next =
        _dragStartX + (_dragTargetX - _dragStartX) * _controller.value;
    if (next != _dragX && mounted) {
      setState(() => _dragX = next);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _dismissing) {
      // 弹窗已滑出屏外、不可见——此刻才真正关一层（避免 dismiss 与动画竞争）。
      widget.onDismiss();
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enableSwipeToClose ||
        (event.kind != PointerDeviceKind.touch &&
            event.kind != PointerDeviceKind.stylus &&
            event.kind != PointerDeviceKind.invertedStylus)) {
      return;
    }
    _activePointers.add(event.pointer);
    if (_trackedPointer != null || _activePointers.length != 1) {
      // BUG-1242：第二根指针必须立即取消第一根的 dismiss tracking。旧实现直接
      // return，第一根之后的 move/up 仍可越过阈值关闭弹窗。
      _clearTrackedPointer();
      _springBack();
      return;
    }
    _trackedPointer = event.pointer;
    _pointerStart = event.position;
    _pointerIsHorizontal = null;
    _controller.stop();
    _dismissing = false;
    setState(() => _dragX = 0);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _trackedPointer || _pointerStart == null) return;
    final Offset delta = event.position - _pointerStart!;
    if (_pointerIsHorizontal == null) {
      if (delta.distanceSquared < 64) return;
      // 强横向意图才滑关。其余轨迹固定判为正文滚动，后续即使偏回横向也不反抢。
      _pointerIsHorizontal = delta.dx.abs() > delta.dy.abs() * 1.5;
    }
    if (_pointerIsHorizontal != true) return;
    setState(() => _dragX = delta.dx);
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _trackedPointer) return;
    final bool shouldFinish = _pointerIsHorizontal == true;
    _clearTrackedPointer();
    if (shouldFinish) {
      _finishHorizontalDrag();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _trackedPointer) return;
    final bool shouldSpringBack = _pointerIsHorizontal == true;
    _clearTrackedPointer();
    if (shouldSpringBack) {
      _springBack();
    }
  }

  void _clearTrackedPointer() {
    _trackedPointer = null;
    _pointerStart = null;
    _pointerIsHorizontal = null;
  }

  void _finishHorizontalDrag() {
    final double accumulated = _dragX;
    // 双向水平：左右皆可，对齐手机 `_dragX.abs()`。
    if (accumulated.abs() > _threshold) {
      // 过阈值：朝拖动方向补间滑出屏外（卡片宽 + 边距），完成回调里再 onDismiss。
      final double width = _layerWidth > 0 ? _layerWidth : accumulated.abs();
      _dragStartX = accumulated;
      _dragTargetX =
          (accumulated.isNegative ? -1.0 : 1.0) * (width + _kSlideOutMargin);
      _dismissing = true;
      _controller
        ..reset()
        ..animateTo(1.0, curve: Curves.easeOut);
    } else {
      _springBack();
    }
  }

  void _springBack() {
    _dragStartX = _dragX;
    _dragTargetX = 0;
    _dismissing = false;
    _controller
      ..reset()
      ..animateTo(1.0, curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.enableSwipeToClose
          ? LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (constraints.maxWidth.isFinite) {
                  _layerWidth = constraints.maxWidth;
                }
                final double width = _layerWidth > 0 ? _layerWidth : 1.0;
                // 跟手淡出：位移越大越淡，最低 0.3（与 SwipeDismissWrapper 同手感）；
                // 滑出补间末段（_dragTargetX = width + margin）自然趋近 0。
                final double opacity = _dismissing
                    ? (1 - (_dragX.abs() / (width + _kSlideOutMargin)))
                        .clamp(0.0, 1.0)
                    : (1 - (_dragX.abs() / width) * 0.7).clamp(0.3, 1.0);
                return Transform.translate(
                  offset: Offset(_dragX, 0),
                  child: Opacity(
                    opacity: opacity,
                    child: widget.child,
                  ),
                );
              },
            )
          : widget.child,
    );
  }
}

/// 尺寸拖拽把手的边长（逻辑像素）。桌面常显、移动端可触摸拖。
const double _kResizeGripSize = 18.0;

/// 查词弹窗右下角的尺寸拖拽把手（Phase B）。渲染成常见的对角抓手纹样，接 pan 手势：
/// 起手 [onStart]（宿主存当前基准尺寸）、拖动 [onUpdate]（增量位移，宿主折算+实时预览）、
/// 松手 [onEnd]（宿主落偏好）。`HitTestBehavior.opaque` 让整块把手区域吸收命中，pan
/// 识别器在竞技场赢过下面的滑关/关窗，绝不误触。桌面附带右下拉伸鼠标指针。
class _PopupResizeGrip extends StatelessWidget {
  const _PopupResizeGrip({
    required this.onUpdate,
    this.onStart,
    this.onEnd,
    this.onCancel,
    super.key,
  });

  final VoidCallback? onStart;
  final void Function(Offset deltaPx) onUpdate;
  final VoidCallback? onEnd;

  /// pan 被手势竞技场中途夺走（不走 [onEnd]）时触发：宿主借此丢弃预览态、还原到
  /// 已落库尺寸，避免弹窗停在预览尺寸的悬挂态（偏好从不会因取消被写坏）。
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final Color color =
        Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: onStart == null ? null : (_) => onStart!(),
        onPanUpdate: (DragUpdateDetails details) => onUpdate(details.delta),
        onPanEnd: onEnd == null ? null : (_) => onEnd!(),
        onPanCancel: onCancel,
        child: CustomPaint(
          size: const Size.square(_kResizeGripSize),
          painter: _ResizeGripPainter(color),
        ),
      ),
    );
  }
}

/// 把手纹样：右下角两道由长到短的对角线（越靠角越长），是跨平台通用的 resize 抓手观感。
class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const double margin = 3.0;
    // 靠角的长线 + 更靠角的短线，形成阶梯状对角抓手。
    canvas.drawLine(
      Offset(size.width - margin, size.height - margin * 5),
      Offset(size.width - margin * 5, size.height - margin),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - margin, size.height - margin * 3),
      Offset(size.width - margin * 3, size.height - margin),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ResizeGripPainter oldDelegate) =>
      oldDelegate.color != color;
}
