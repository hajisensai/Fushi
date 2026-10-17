import 'dart:ui' show Rect, Size;

import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart'
    show MangaCropSuggestions;
import 'package:fushi_anki/fushi_anki_core.dart'
    show MiningImageCrop, MiningMosaicRegion, MiningRequestOverrides;
import 'package:fushi_engine/media/manga/panel_detection.dart' show PanelRect;

/// 漫画制卡卡图裁切的纯函数层：预选建议、一键制卡的裁切决策。
///
/// 坐标一律是**相对原页图**（`bakeOrientation` 之后）的 0..1 归一化矩形——与分镜检测
/// `PanelRect`、制卡覆盖项 `MiningImageCrop` 同一坐标系，页面只负责取数据与落盘。

/// 文本块外扩倍数（按中心等比放大宽高）。一句台词的气泡框通常只占分镜的一小块，
/// 放大到约 3.5 倍大致能带上说话的人物与气泡，又不至于退化成整页。
const double kMangaTextAreaExpansion = 3.5;

/// 把分镜检测结果换成 [Rect]（同一归一化坐标系，不做换算）。
Rect mangaPanelToRect(PanelRect panel) =>
    Rect.fromLTRB(panel.left, panel.top, panel.right, panel.bottom);

/// 这句话所在的分镜：优先取**包含文本矩形中心**的分镜（多个时取面积最小的，嵌套检测
/// 框里最贴身的那格）；没有则取与文本矩形 IoU 最大者；都不沾边返回 null。
Rect? mangaContainingPanel(List<Rect> panels, Rect text) {
  if (panels.isEmpty || text.isEmpty) return null;
  final double cx = text.center.dx;
  final double cy = text.center.dy;
  Rect? containing;
  for (final Rect panel in panels) {
    final bool hit =
        cx >= panel.left &&
        cx <= panel.right &&
        cy >= panel.top &&
        cy <= panel.bottom;
    if (!hit) continue;
    if (containing == null || _area(panel) < _area(containing)) {
      containing = panel;
    }
  }
  if (containing != null) return containing;
  Rect? best;
  double bestIou = 0;
  for (final Rect panel in panels) {
    final double iou = _iou(panel, text);
    if (iou > bestIou) {
      bestIou = iou;
      best = panel;
    }
  }
  return best;
}

/// 文本矩形按中心把宽高各放大 [factor] 倍，再挪进页面（贴边时整体平移而不是截掉，
/// 保住放大后的面积；超过整页的那一维直接取整页）。
Rect expandMangaTextRect(Rect text, {double factor = kMangaTextAreaExpansion}) {
  final double width = (text.width * factor).clamp(0.0, 1.0);
  final double height = (text.height * factor).clamp(0.0, 1.0);
  double left = text.center.dx - width / 2;
  double top = text.center.dy - height / 2;
  left = left.clamp(0.0, 1.0 - width);
  top = top.clamp(0.0, 1.0 - height);
  return Rect.fromLTWH(left, top, width, height);
}

/// 组装对话框的预选建议。[panels] 为空（模型不可用 / 条漫 / 检测失败）时没有分镜一级；
/// [textRect] 为 null（拿不到 OCR 位置）时也没有外扩框——对话框退回整页。
MangaCropSuggestions computeMangaCropSuggestions({
  required int pageIndex,
  required Size pageSize,
  List<Rect> panels = const <Rect>[],
  Rect? textRect,
}) {
  final Rect? text = textRect == null || textRect.isEmpty ? null : textRect;
  return MangaCropSuggestions(
    pageIndex: pageIndex,
    pageSize: pageSize,
    panels: List<Rect>.unmodifiable(panels),
    containingPanel: text == null ? null : mangaContainingPanel(panels, text),
    textRect: text,
    textAreaRect: text == null ? null : expandMangaTextRect(text),
  );
}

/// 本次制卡怎么出卡图。
enum MangaCardImageKind {
  /// 整页原图（现有行为）。
  wholePage,

  /// 不要卡图。
  omit,

  /// 按 [MangaCardImagePlan.crop] 裁（用户在对话框里框的）。
  crop,

  /// 一键制卡默认裁到这句话所在分镜：页面去跑分镜检测，失败 / 无命中退回整页。
  autoPanel,
}

/// [resolveMangaCardImagePlan] 的结论。
class MangaCardImagePlan {
  const MangaCardImagePlan(
    this.kind, {
    this.crop,
    this.mosaic = const <MiningMosaicRegion>[],
    this.diagnostic,
  });

  final MangaCardImageKind kind;

  /// 只在 [MangaCardImageKind.crop] 时非 null。
  final Rect? crop;

  /// 打码区域（相对未裁切原页图）；只在 [MangaCardImageKind.crop] 时可能非空。非空时
  /// 宿主必须打码成功才能出卡图——失败就不要卡图，绝不退回整页原图。
  final List<MiningMosaicRegion> mosaic;

  /// 退回整页的原因（只为留诊断，不给用户看）。
  final String? diagnostic;
}

/// 决定本次漫画制卡的卡图方案。纯函数：页面在制卡入口**同步**读齐参数再调它。
///
/// * `omitImage` → 不要卡图。
/// * 有 crop：`isWholePage` = 用户明确不裁（压过默认设置）；页码与本次制卡页
///   [miningPageIndex] 不一致 → 退整页并留诊断（绝不裁错页）；否则按 crop 裁。
/// * 有打码（`mosaic`，与 crop 同属对话框里的那一页）：整页也要走裁切通道（裁 0..1）
///   才能把码打上；页码对不上时**不要卡图**——打码位置是那一页的，退回整页就把用户
///   想遮住的东西原样送进了卡片。没有 crop 却有打码（不该出现的组合）同样不要卡图。
/// * 没有 crop：[cropToPanelByDefault] 开、非条漫、知道是哪一页 → 交给页面裁到所在
///   分镜（模型是否可用由页面在执行时判定，不可用即整页）；否则整页。
///   没有模型时**绝不**按文本外扩去裁：自动裁错比不裁更糟。
MangaCardImagePlan resolveMangaCardImagePlan({
  required MiningRequestOverrides? overrides,
  required int? miningPageIndex,
  required bool cropToPanelByDefault,
  required bool webtoon,
}) {
  if (overrides?.omitImage ?? false) {
    return const MangaCardImagePlan(MangaCardImageKind.omit);
  }
  final MiningImageCrop? crop = overrides?.crop;
  final List<MiningMosaicRegion> mosaic =
      overrides?.mosaic ?? const <MiningMosaicRegion>[];
  if (crop == null && mosaic.isNotEmpty) {
    return const MangaCardImagePlan(
      MangaCardImageKind.omit,
      diagnostic: 'mosaic without crop page',
    );
  }
  if (crop != null) {
    if (crop.isWholePage && mosaic.isEmpty) {
      return const MangaCardImagePlan(MangaCardImageKind.wholePage);
    }
    if (miningPageIndex == null || crop.pageIndex != miningPageIndex) {
      return MangaCardImagePlan(
        mosaic.isEmpty ? MangaCardImageKind.wholePage : MangaCardImageKind.omit,
        diagnostic:
            'crop page ${crop.pageIndex} != mining page $miningPageIndex',
      );
    }
    return MangaCardImagePlan(
      MangaCardImageKind.crop,
      crop: Rect.fromLTRB(crop.left, crop.top, crop.right, crop.bottom),
      mosaic: mosaic,
    );
  }
  if (cropToPanelByDefault && !webtoon && miningPageIndex != null) {
    return const MangaCardImagePlan(MangaCardImageKind.autoPanel);
  }
  return const MangaCardImagePlan(MangaCardImageKind.wholePage);
}

double _area(Rect r) => r.width * r.height;

double _iou(Rect a, Rect b) {
  final Rect overlap = a.intersect(b);
  if (overlap.width <= 0 || overlap.height <= 0) return 0;
  final double intersection = _area(overlap);
  final double union = _area(a) + _area(b) - intersection;
  return union <= 0 ? 0 : intersection / union;
}
