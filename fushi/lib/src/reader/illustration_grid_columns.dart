import 'dart:math' as math;

/// 插图网格（阅读器插图册 [ReaderGalleryPage] 与书架端插图库
/// `IllustrationsViewerPage`）共用的列数规则：卡片目标宽随网格宽度走，而不是
/// 钉死一个 160 / 200 的上限——那样在 1920 宽的桌面窗口里插图仍只有手机大小，
/// 右边整片空着。
///
/// 目标宽 = 网格宽的 1/5，夹在 [kIllustrationCardMinTargetExtent] ~
/// [kIllustrationCardMaxTargetExtent]；列数取「不让卡片超过目标宽」的最少列
/// （向上取整）。手机（网格宽 ≲ 1000）落在下限，列数与原先一致；桌面窗口越宽
/// 卡片越大，直到 360 封顶后再靠加列吸收余宽。
///
/// 阅读器插图册的滚动定位模型（`_GalleryLayout`）与真实网格必须用同一份列数，
/// 所以这里只吃纯数字、不碰 BuildContext，两边各自算出来结果一定相同。
int illustrationGridColumnsForWidth(
  double gridWidth, {
  required double spacing,
}) {
  final double target = (gridWidth / 5).clamp(
    kIllustrationCardMinTargetExtent,
    kIllustrationCardMaxTargetExtent,
  );
  return math.max(1, (gridWidth / (target + spacing)).ceil());
}

/// 卡片目标宽下限：与原先书架端插图库的 `maxCrossAxisExtent: 200` 同值，窄屏
/// 列数不变。
const double kIllustrationCardMinTargetExtent = 200;

/// 卡片目标宽上限：再宽的窗口也不让单张缩略图超过它（缩略图本就是进全屏前的
/// 预览，铺满半个屏幕没有意义）。
const double kIllustrationCardMaxTargetExtent = 360;
