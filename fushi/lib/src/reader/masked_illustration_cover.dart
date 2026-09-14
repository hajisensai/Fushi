/// 未揭开插图的遮罩视觉：阅读器插图册（[ReaderGalleryPage]）与书架端插图库
/// （`IllustrationsViewerPage`）共用一份，避免同一个「盖住了」在两个表面长得不一样。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 未揭开插图的遮罩视觉：普通屏「模糊图 + 蒙层 + 图标」，墨水屏「实心遮板 + 图标」。
///
/// 墨水屏不走模糊有两个理由，都不是审美偏好：慢刷新面板渲染不出干净的高斯过渡，
/// 留下的是一片残影；而灰阶下「一张糊图」在观感上就等于「这张图本身不高清」，
/// 遮罩的意图一点都传达不到，用户只会以为画廊坏了。实心遮板一眼可辨是盖住的。
Widget maskedIllustrationCover(
  BuildContext context,
  Widget img, {
  double sigma = 16,
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
  return Stack(
    fit: StackFit.expand,
    children: <Widget>[
      ClipRect(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
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
}
