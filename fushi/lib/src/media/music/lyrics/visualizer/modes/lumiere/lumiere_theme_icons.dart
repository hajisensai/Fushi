/// 绘光的主题图标落点（移植 folia `lumiere/lineart/themeIcons.ts` 的 `placeThemeIcons`）：主题图标
/// （`LyricVisualizerTheme.lyricsIcons` 映射到的语义图标字形）按种子散落在构图空处，避开文字区、画面
/// 边缘和彼此。坐标一律高度单位（x 在 0..aspect，y 在 0..1）。
///
/// folia 把 Lucide 图标折线当线稿逐笔描出；本 app 不带 Lucide 折线，画的是字形整枚淡入（见
/// `LumiereScene._paintThemeIcons`）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_profile.dart';

/// 摆好的一枚图标（folia `PlacedIcon`）。
@immutable
class LumierePlacedIcon {
  const LumierePlacedIcon({
    required this.icon,
    required this.cx,
    required this.cy,
    required this.size,
    required this.rotation,
  });

  final IconData icon;
  final double cx;
  final double cy;

  /// 边长（高度单位）。
  final double size;

  /// 转角（弧度）。
  final double rotation;
}

/// folia `ICON_SIZE` / `TEXT_PAD` / `EDGE` / `ATTEMPTS`。
const double kLumiereIconSizeMin = 0.085;
const double kLumiereIconSizeMax = 0.13;
const double kLumiereIconTextPad = 0.05;
const double kLumiereIconEdge = 0.05;
const int kLumiereIconAttempts = 48;

bool _overlaps(double cx, double cy, double half, TextRegion r, double pad) =>
    (cx - r.cx).abs() < half + r.w / 2 + pad &&
    (cy - r.cy).abs() < half + r.h / 2 + pad;

/// 按种子给图标找落点：在画面内（留边）随机取位置，拒绝与文字区（外扩 [kLumiereIconTextPad]）或已放下
/// 的图标重叠的候选；找不到空处的图标不放。[avoid] 是高度单位的文字区。默认放 2–3 枚。
List<LumierePlacedIcon> placeLumiereThemeIcons({
  required List<IconData> icons,
  required double aspect,
  required TextRegion avoid,
  required LumiereRng random,
  int offset = 0,
  int? count,
}) {
  if (icons.isEmpty) return const <LumierePlacedIcon>[];
  final int n = count ?? 2 + (random() < 0.5 ? 1 : 0);
  final List<LumierePlacedIcon> placed = <LumierePlacedIcon>[];
  for (int i = 0; i < n; i++) {
    final IconData icon = icons[(offset + i) % icons.length];
    final double size =
        kLumiereIconSizeMin +
        random() * (kLumiereIconSizeMax - kLumiereIconSizeMin);
    final double rotation = (random() - 0.5) * 0.3;
    // 转动后的外接半径（留一点余量）。
    final double half = size * 0.72;
    for (int attempt = 0; attempt < kLumiereIconAttempts; attempt++) {
      final double cx =
          kLumiereIconEdge +
          half +
          random() * math.max(0, aspect - 2 * (kLumiereIconEdge + half));
      final double cy =
          kLumiereIconEdge +
          half +
          random() * math.max(0, 1 - 2 * (kLumiereIconEdge + half));
      if (_overlaps(cx, cy, half, avoid, kLumiereIconTextPad)) continue;
      if (placed.any(
        (LumierePlacedIcon o) =>
            math.sqrt(math.pow(o.cx - cx, 2) + math.pow(o.cy - cy, 2)) <
            (o.size + size) * 0.9,
      )) {
        continue;
      }
      placed.add(
        LumierePlacedIcon(
          icon: icon,
          cx: cx,
          cy: cy,
          size: size,
          rotation: rotation,
        ),
      );
      break;
    }
  }
  return placed;
}
