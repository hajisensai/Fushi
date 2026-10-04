import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi_engine/media/discovery/discovery_format.dart'
    show formatDiscoveryBytes;

// 下载进度的统一表现（互联下载的封面进度 / 角标共用）。
//
// - [FushiDownloadProgressRing]：一枚带百分比的进度环。MD3 确定态是
//   Expressive 波浪环（[FushiWavyCircularProgress]），不定态是 Expressive
//   变形加载指示（[FushiExpressiveLoadingIndicator]）；Apple 确定态是 iOS
//   细圆环（[FushiAppleProgressRing]，不用波浪），不定态是菊花；墨水屏是
//   静止的 Material 原环（不定态钉成 0，不做持续局部刷新）。环中心是百分比，
//   等宽数字（tabular figures）；紧凑尺寸只显示数字、不带 `%`。
// - [FushiDownloadCoverOverlay]：铺满封面的下载态——半透明压暗 + 居中进度环 +
//   百分比；总大小未知时环下给已下载字节；到 100% 淡出。
//
// 系统「减少动态效果」时波浪 / 变形指示由 fushi_expressive_progress 自己收成
// 静止形态，这里的淡出也跟着取消过渡。

/// 环外框小于这个尺寸时是紧凑档：中心只写数字、不带 `%`。
const double kFushiDownloadRingCompactSize = 40;

/// 0..1 → 整数百分比（向下取整：没真到 100% 不显示 100）。
int fushiDownloadPercent(double value) => (value.clamp(0.0, 1.0) * 100).floor();

/// 由「比例 / 已收字节 / 总字节」得出确定进度；都不够时为 null（不定态）。
double? fushiDownloadEffectiveValue({
  double? value,
  int? receivedBytes,
  int? totalBytes,
}) {
  if (value != null) return value.clamp(0.0, 1.0);
  final int? received = receivedBytes;
  final int? total = totalBytes;
  if (received != null && total != null && total > 0) {
    return (received / total).clamp(0.0, 1.0);
  }
  return null;
}

/// 读屏用的进度值：确定态读百分比，不定态有字节就读字节。
String? fushiDownloadSemanticsValue(double? value, int? receivedBytes) {
  if (value != null) return '${fushiDownloadPercent(value)}%';
  if (receivedBytes != null) return formatDiscoveryBytes(receivedBytes);
  return null;
}

/// 带中心百分比的下载进度环（见文件头）。颜色由调用方按底色给：压在封面
/// 暗底上与压在普通表面上需要的前景完全不同，这里不猜底色。
class FushiDownloadProgressRing extends StatelessWidget {
  const FushiDownloadProgressRing({
    super.key,
    required this.value,
    required this.color,
    required this.trackColor,
    required this.labelColor,
    this.size = 44,
    this.showLabel = true,
    this.semanticsLabel,
    this.semanticsValue,
  });

  /// 0..1；null = 不定态（还没有可用的进度回报）。
  final double? value;

  /// 已填段 / 指示颜色。
  final Color color;

  /// 未填轨道颜色。
  final Color trackColor;

  /// 中心百分比文字颜色。
  final Color labelColor;

  /// 环外框边长。
  final double size;

  /// 是否在环中心写百分比。
  final bool showLabel;

  final String? semanticsLabel;

  /// 覆盖默认读屏值（默认读百分比）。
  final String? semanticsValue;

  bool get _compact => size < kFushiDownloadRingCompactSize;

  @override
  Widget build(BuildContext context) {
    final double? v = value;
    final Widget ring = _buildRing(context, v);
    final Widget body = v == null || !showLabel
        ? ring
        : Stack(
            alignment: Alignment.center,
            children: <Widget>[
              ring,
              // 环内留出线宽 + 波浪振幅的余量；大字号下由 FittedBox 收小，不撑破环。
              SizedBox.square(
                dimension: size * 0.62,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _compact
                        ? '${fushiDownloadPercent(v)}'
                        : '${fushiDownloadPercent(v)}%',
                    maxLines: 1,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: size * (_compact ? 0.36 : 0.27),
                      fontWeight: FontWeight.w600,
                      height: 1,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
    return Semantics(
      container: true,
      label: semanticsLabel,
      value:
          semanticsValue ?? (v == null ? null : '${fushiDownloadPercent(v)}%'),
      child: ExcludeSemantics(
        child: SizedBox.square(dimension: size, child: body),
      ),
    );
  }

  Widget _buildRing(BuildContext context, double? v) {
    if (isEinkTheme(context)) {
      // 墨水屏：静止原环，不定态钉 0（无限转圈 = 持续局部刷新拖影）。
      return CircularProgressIndicator(
        value: v ?? 0,
        strokeWidth: _compact ? 2.5 : 3,
        color: color,
        backgroundColor: trackColor,
      );
    }
    if (isGlassDesign(context)) {
      if (v == null) {
        return fushiAppleActivityIndicator(context, size: size, color: color);
      }
      // iOS 下载环：细圆环 + 强调色填充，不用波浪。
      return FushiAppleProgressRing(
        value: v,
        size: size,
        strokeWidth: _compact ? 2.5 : 3,
        color: color,
        trackColor: trackColor,
      );
    }
    if (v == null) {
      return FushiExpressiveLoadingIndicator(size: size, color: color);
    }
    return FushiWavyCircularProgress(
      value: v,
      size: size,
      padding: EdgeInsets.zero,
      strokeWidth: _compact ? 3 : 4,
      trackGap: _compact ? 3 : 4,
      color: color,
      trackColor: trackColor,
    );
  }
}

/// 铺满封面的下载态（见文件头）。自身撑满父级（放进 `Positioned.fill`，或
/// 放进松约束的 `Center` 也照样铺满），不拦截点击——点按仍落到卡片本体。
class FushiDownloadCoverOverlay extends StatelessWidget {
  const FushiDownloadCoverOverlay({
    super.key,
    required this.value,
    this.receivedBytes,
    this.totalBytes,
    this.semanticsLabel,
  });

  /// 0..1；null 时按 [receivedBytes] / [totalBytes] 推，仍推不出即不定态。
  final double? value;

  /// 已下载字节（含续传前已有的部分）；总大小未知时显示它。
  final int? receivedBytes;

  /// 总字节；未知为 null。
  final int? totalBytes;

  /// 读屏标签（如「下载中」），值读百分比 / 字节。
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final double? v = fushiDownloadEffectiveValue(
      value: value,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    );
    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);
    final bool reduceMotion =
        eink || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 暗底上的前景：MD3 取 primaryFixedDim（固定色阶 80，明暗主题下都够亮，
    // 让环带上主题色）；Apple 是白色（iOS 封面上的下载环是白环，不上强调色——
    // 单色强调在浅色模式下是黑色，压在暗底上看不见）。
    final Color ringColor = eink
        ? cs.onSurface
        : (glass ? Colors.white : cs.primaryFixedDim);
    final Color trackColor = eink
        ? cs.outlineVariant
        : Colors.white.withValues(alpha: glass ? 0.3 : 0.28);
    final Color labelColor = eink ? cs.onSurface : Colors.white;
    final Color scrim = glass
        ? Colors.black.withValues(alpha: 0.4)
        : cs.scrim.withValues(alpha: 0.48);
    final String? bytesLabel = v == null && receivedBytes != null
        ? formatDiscoveryBytes(receivedBytes!)
        : null;

    return IgnorePointer(
      child: Semantics(
        container: true,
        label: semanticsLabel,
        value: fushiDownloadSemanticsValue(v, receivedBytes),
        child: ExcludeSemantics(
          child: AnimatedOpacity(
            // 下满 100% 即淡出（随后的入库收尾不再压着封面）。
            opacity: v != null && v >= 1 ? 0 : 1,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            child: SizedBox.expand(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  final double side = math.min(
                    box.hasBoundedWidth ? box.maxWidth : 120,
                    box.hasBoundedHeight ? box.maxHeight : 120,
                  );
                  final double ringSize = (side * 0.38).clamp(28.0, 64.0);
                  final bool roomForBytes =
                      bytesLabel != null &&
                      side >= ringSize + 28 &&
                      ringSize >= kFushiDownloadRingCompactSize;
                  Widget content = Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FushiDownloadProgressRing(
                        value: v,
                        size: ringSize,
                        color: ringColor,
                        trackColor: trackColor,
                        labelColor: labelColor,
                      ),
                      if (roomForBytes) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          bytesLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: labelColor,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ],
                    ],
                  );
                  if (eink) {
                    // 墨水屏不压暗（半透明灰在墨水屏上是一片脏网点）：实心
                    // 表面圆盘 + 描边把环托出来。
                    content = Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        shape: roomForBytes
                            ? BoxShape.rectangle
                            : BoxShape.circle,
                        borderRadius: roomForBytes
                            ? BorderRadius.circular(12)
                            : null,
                        border: Border.all(color: cs.outline),
                      ),
                      child: content,
                    );
                    return Center(child: content);
                  }
                  return ColoredBox(
                    color: scrim,
                    child: Center(child: content),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
