/// 查词弹窗「最大宽高」的有效尺寸解析（纯函数，单元可测）。
///
/// 弹窗尺寸只有一个真值——「最大宽高」。三种形态（app 内 / app 外覆盖窗 /
/// 浏览器扩展）默认共享 app 内的 [popupMaxWidth]/[popupMaxHeight]；某个形态被
/// 用户显式「解锁独立尺寸」后，改用该形态自己的宽/高键。这里把这条决策抽成不依赖
/// 任何 Flutter/FFI 的纯函数，供 controller、app_model、Phase C/D 复用与单测。
library;

/// 一对「最大宽 × 最大高」逻辑像素值。
class LookupSize {
  const LookupSize(this.width, this.height);

  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is LookupSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'LookupSize(${width}x$height)';
}

/// 解析某个查词形态（app 外覆盖窗 / 浏览器扩展）的有效最大宽高。
///
/// - [independent] 为 `true`：该形态已解锁独立尺寸，用它自己的
///   [sceneWidth]/[sceneHeight]。
/// - [independent] 为 `false`：跟随 app 内共享值 [sharedWidth]/[sharedHeight]。
///
/// app 内弹窗本身无「跟随/独立」之分，恒等于共享值，直接读 [popupMaxWidth] 即可，
/// 不必经此函数。
LookupSize effectiveLookupSize({
  required bool independent,
  required double sceneWidth,
  required double sceneHeight,
  required double sharedWidth,
  required double sharedHeight,
}) {
  if (independent) {
    return LookupSize(sceneWidth, sceneHeight);
  }
  return LookupSize(sharedWidth, sharedHeight);
}

/// 查词弹窗「最大宽/高」的允许范围（基准逻辑像素）。与设置页两滑杆的 min/max
/// 单一同源——拖拽角落把手与滑杆写同一真值，故 clamp 边界必须一致，否则拖拽能写出
/// 滑杆写不出的越界值。
const double kLookupPopupMinWidth = 250;
const double kLookupPopupMaxWidth = 2000;
const double kLookupPopupMinHeight = 200;
const double kLookupPopupMaxHeight = 1600;

/// 拖拽弹窗右下角把手时，把「当前基准尺寸 + 本次累计位移」折算成新的基准（未缩放）
/// 最大宽高并 clamp 到 [kLookupPopupMinWidth]..[kLookupPopupMaxHeight] 范围。
///
/// 宿主渲染的弹窗盒宽 = `基准宽 × uiScale`（界面缩放，见 base_source_page /
/// dictionary_page_mixin 的盒尺寸 getter）。把手的拖动位移 [deltaWidthPx] /
/// [deltaHeightPx] 落在**已缩放**的盒坐标系里，故折算回基准要除以 [uiScale]：
/// `新基准 = 当前基准 + delta / uiScale`。[uiScale] 非正时按 1 兜底（不除零 /
/// 不反向缩放）。纯函数，方向 + clamp 单元可测，reader / video 两宿主共用。
LookupSize resolveDraggedLookupSize({
  required double currentBaseWidth,
  required double currentBaseHeight,
  required double deltaWidthPx,
  required double deltaHeightPx,
  required double uiScale,
  double minWidth = kLookupPopupMinWidth,
  double maxWidth = kLookupPopupMaxWidth,
  double minHeight = kLookupPopupMinHeight,
  double maxHeight = kLookupPopupMaxHeight,
}) {
  final double scale = uiScale > 0 ? uiScale : 1.0;
  final double width =
      (currentBaseWidth + deltaWidthPx / scale).clamp(minWidth, maxWidth);
  final double height =
      (currentBaseHeight + deltaHeightPx / scale).clamp(minHeight, maxHeight);
  return LookupSize(width, height);
}

/// Phase C（2026-07-13）— 「app 外瞬态覆盖查词窗」被拖角调整尺寸后，native 模态
/// size 循环结束回报**最终窗口物理像素**尺寸，本函数把它倒推回 overlay 场景的
/// 「基准（未缩放）最大宽高」并 clamp。app 内拖拽写 [resolveDraggedLookupSize]（增量
/// 折算），覆盖窗走这里（绝对窗口尺寸折算）——两者都不引入第二套「固定尺寸」概念，
/// 只是把同一「最大宽高」真值换一种输入编辑。
///
/// 正向链（controller 算窗口物理尺寸，见 global_lookup_controller）：
/// `cardW = overlayEffective.width × appUiScale`，再 `× dpr` 传 native 建窗，
/// 故单卡窗口物理宽 ≈ `overlayLogicalW × uiScale × dpr`。倒推即：
/// `overlayLogicalW = 窗口物理宽 / dpr / uiScale`。
///
/// [dpr] / [uiScale] 非正时按 1 兜底（不除零、不反向缩放）。结果先**下取整**到整
/// 逻辑像素（避免一次拖拽因四舍五入把值顶上去 / 多次往返累积漂移），再 clamp 到
/// [kLookupPopupMinWidth]..[kLookupPopupMaxHeight]——与滑杆同一 min/max 单一同源。
/// 纯函数（含 dpr、uiScale、下取整、clamp 边界），直接单测。
LookupSize resolveOverlayResizeFromWindow({
  required double windowPhysicalWidth,
  required double windowPhysicalHeight,
  required double dpr,
  required double uiScale,
  double minWidth = kLookupPopupMinWidth,
  double maxWidth = kLookupPopupMaxWidth,
  double minHeight = kLookupPopupMinHeight,
  double maxHeight = kLookupPopupMaxHeight,
}) {
  final double d = dpr > 0 ? dpr : 1.0;
  final double s = uiScale > 0 ? uiScale : 1.0;
  final double width =
      (windowPhysicalWidth / d / s).floorToDouble().clamp(minWidth, maxWidth);
  final double height = (windowPhysicalHeight / d / s)
      .floorToDouble()
      .clamp(minHeight, maxHeight);
  return LookupSize(width, height);
}
