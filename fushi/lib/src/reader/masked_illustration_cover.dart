/// 未揭开插图的遮罩视觉：阅读器插图册（[ReaderGalleryPage]）与书架端插图库
/// （`IllustrationsViewerPage`）共用一份，避免同一个「盖住了」在两个表面长得不一样。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 缩略图遮罩的模糊半径占卡片短边的比例。
///
/// BUG-2559：两个插图表面此前都写死 `sigma: 16`，但卡片不一样大——书架端插图库
/// 是最宽 200 的方卡，阅读器插图册是最宽 160 的 0.72 竖卡。同一个**绝对**模糊
/// 半径施在小 20% 的卡上就是更糊一档，于是同一本书的同一张插图在两处看着不是
/// 一个遮罩。按短边取比例后，遮蔽力度与卡片尺寸无关，两处（以及将来任何尺寸的
/// 缩略图）自然一致。
///
/// 0.08 = 现有书架端的观感（200 短边 → sigma 16）：取它做基准是为了让这次统一
/// 不改动任何人已经习惯的强度，只把另一侧对齐过来。
const double kMaskedIllustrationSigmaFraction = 0.08;

/// 未揭开插图的遮罩视觉：普通屏「模糊图 + 蒙层 + 图标」，墨水屏「实心遮板 + 图标」。
///
/// 模糊半径默认按实际卡片短边算（[kMaskedIllustrationSigmaFraction]）。全屏查看
/// 器这类「尺寸随窗口跑、且另配了更重的蒙层」的表面可以用 [sigma] 钉死绝对值。
///
/// 墨水屏不走模糊有两个理由，都不是审美偏好：慢刷新面板渲染不出干净的高斯过渡，
/// 留下的是一片残影；而灰阶下「一张糊图」在观感上就等于「这张图本身不高清」，
/// 遮罩的意图一点都传达不到，用户只会以为画廊坏了。实心遮板一眼可辨是盖住的。
Widget maskedIllustrationCover(
  BuildContext context,
  Widget img, {
  double? sigma,
  Color scrim = const Color(0x33000000),
  required double iconSize,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  if (isEinkTheme(context)) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: scheme.surface),
        Center(
          child: Icon(
            Icons.visibility_off_outlined,
            color: scheme.onSurface,
            size: iconSize,
          ),
        ),
      ],
    );
  }
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double effectiveSigma = sigma ?? _sigmaForBox(constraints.biggest);
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: effectiveSigma,
                sigmaY: effectiveSigma,
              ),
              child: img,
            ),
          ),
          ColoredBox(color: scrim),
          Center(
            child: Icon(
              Icons.visibility_off_outlined,
              color: Colors.white70,
              size: iconSize,
            ),
          ),
        ],
      );
    },
  );
}

/// 按 [box] 短边算模糊半径。约束不定（无界高的网格卡不会出现，但 sliver 量测
/// 期可能问到无界）时退回历史绝对值，绝不因为量不到尺寸就交出一张清晰的图。
double _sigmaForBox(Size box) {
  final double shortest = box.shortestSide;
  if (!shortest.isFinite || shortest <= 0) return 16;
  return shortest * kMaskedIllustrationSigmaFraction;
}
