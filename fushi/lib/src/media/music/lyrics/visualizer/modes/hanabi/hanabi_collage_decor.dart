/// 一个场景单元（段落）的环境层与拼贴层装配（folia `scene.ts` 里 ambient / unitCollage / 每镜头 collage 的那部分）。
///
/// 层序（folia `scene.ts` 头注释）：stage（镜头内运镜）里
///   ambient.back → unitCollage.back → spin/world（每个镜头：fireworks → ornaments(back) → collage(back) →
///   字底色块 → 字 → ornaments(front) → collage(front)）→ ambient.front → unitCollage.front。
/// 场景只需在这些位置调 [HanabiUnitDecor] 的对应方法。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_ambient.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_collage_plan.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_timeline.dart';

/// 装配拼贴需要的一个镜头的事实。
class HanabiDecorShot {
  const HanabiDecorShot({
    required this.id,
    required this.profile,
    required this.isBridge,
    required this.timing,
    required this.palette,
    required this.line,
    required this.textBounds,
    required this.mains,
    required this.launches,
  });
  final String id;
  final HanabiProfile profile;
  final bool isBridge;
  final ShotTiming timing;
  final HanabiPalette palette;
  final HanabiLine? line;

  /// 字组静止时的包围盒（镜头容器坐标）；没有字时 null（按文字区算）。
  final LayoutRect? textBounds;

  /// 主烟花（文字入场那一发；间奏为全部连发）。
  final List<BurstEvent> mains;
  final List<LaunchEvent> launches;
}

/// 拼贴的字样：曲名在前，再是 HANABI / 花火（folia runtime `motifs()`）。
List<String> hanabiCollageMotifs(String? title) {
  final String? t = title?.trim();
  return <String>[if (t != null && t.isNotEmpty) t, 'HANABI', '花火'];
}

/// 一个场景单元的环境层 + 拼贴层。
class HanabiUnitDecor {
  HanabiUnitDecor({
    required String unitSeed,
    required this.size,
    required List<HanabiDecorShot> shots,
    required double Function(double time) rise,
    required double startTime,
    required double endTime,
    required double ambientDensity,
    required double collageAmount,
    required List<String> motifs,
    CollageOpening? opening,
    String? fallbackFont,
  }) {
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final HanabiDecorShot? lead = shots.isEmpty ? null : shots.first;
    if (lead != null && ambientDensity > 0) {
      double rate = 0;
      for (final HanabiDecorShot s in shots) {
        rate += hanabiDistantRateOf(s.profile.mood);
      }
      ambient = HanabiAmbient(
        seed: '$unitSeed:ambient',
        size: size,
        density: math.min(2, ambientDensity),
        palette: lead.palette,
        startTime: startTime,
        endTime: endTime,
        distantRate: rate / math.max(shots.length, 1),
      );
    }
    final double amount = math.min(2, collageAmount);
    if (amount <= 0) {
      plans = <CollagePlan>[for (final _ in shots) CollagePlan.empty];
      return;
    }
    final HanabiCollageCache c = HanabiCollageCache(fallbackFont: fallbackFont);
    cache = c;
    if (lead != null) {
      unitCollage = HanabiUnitCollage(
        size: size,
        seed: unitSeed,
        cache: c,
        paper: lead.palette.paper,
        amount: amount,
        startTime: startTime,
      );
    }
    CollageRecipe? previous;
    final List<CollagePlan> out = <CollagePlan>[];
    for (int index = 0; index < shots.length; index++) {
      final HanabiDecorShot shot = shots[index];
      final HanabiRegion region = shot.profile.region;
      final ShotTiming timing = shot.timing;
      final LayoutRect? tb = shot.textBounds;
      final CollageRect bounds = tb != null
          ? CollageRect(tb.x, tb.y, tb.width, tb.height)
          : CollageRect(
              -region.w * w / 2,
              -region.h * h / 2,
              region.w * w,
              region.h * h,
            );
      final CollagePlan plan = planShotCollage(
        CollagePlanInput(
          seed: '$unitSeed:${shot.id}',
          family: shot.profile.family,
          mood: shot.profile.mood,
          isBridge: shot.isBridge,
          block: shot.profile.text.block,
          shotNumber: index,
          bounds: bounds,
          screen: CollageRect(-region.cx * w, -region.cy * h, w, h),
          screenAt: (double time) => CollageRect(
            -region.cx * w,
            -(region.cy * h + timing.worldY + rise(time)),
            w,
            h,
          ),
          unit: unit,
          palette: shot.palette,
          enterAt: timing.enterAt,
          exitAt: timing.exitAt,
          exitDuration: timing.exitDuration,
          start: timing.start,
          end: timing.end,
          keyword: pickCollageKeyword(shot.line),
          motifs: motifs,
          bursts: <CollageBurst>[
            for (final BurstEvent e in shot.mains)
              CollageBurst(
                x: e.x,
                y: e.y,
                at: e.at,
                main: true,
                radius: e.spec.radius * unit * e.scale,
              ),
          ],
          launches: <CollageLaunch>[
            for (final LaunchEvent l in shot.launches)
              CollageLaunch(
                fromX: l.fromX,
                fromY: l.fromY,
                toX: l.toX,
                toY: l.toY,
                at: l.at,
                duration: l.duration,
              ),
          ],
          amount: amount,
          previous: previous,
          opening: index == 0 ? opening : null,
        ),
      );
      previous = plan.recipe;
      out.add(plan);
    }
    plans = out;
  }

  final Size size;
  HanabiAmbient? ambient;
  HanabiUnitCollage? unitCollage;
  HanabiCollageCache? cache;

  /// 每个镜头的拼贴计划（与传入的 shots 同序）。
  late final List<CollagePlan> plans;

  /// 第 [shot] 个镜头的拼贴最晚可见到哪一刻（+0.05，folia `collageEnd + 0.05`）；没有件时 -∞。
  double shotLifeEnd(int shot) =>
      shot < plans.length ? plans[shot].end + 0.05 : double.negativeInfinity;

  /// 环境层（后）+ 网点底纹：在镜头内运镜之后、spin / 上升之前调，屏幕坐标。
  void paintBack(
    ui.Canvas canvas,
    HanabiSprites sprites,
    double time,
    double rise,
  ) {
    ambient?.paintBack(canvas, sprites, time, rise);
    unitCollage?.paintBack(canvas, time, rise);
  }

  /// 环境层（前）+ 左缘竖胶片：所有镜头画完之后调，屏幕坐标。
  void paintFront(
    ui.Canvas canvas,
    HanabiSprites sprites,
    double time,
    double rise,
  ) {
    ambient?.paintFront(canvas, sprites, time, rise);
    unitCollage?.paintFront(canvas, time, rise);
  }

  /// 镜头的后层拼贴：在后层装饰件之后、字底色块之前调，镜头容器坐标。
  void paintShotBack(ui.Canvas canvas, int shot, double time) {
    final HanabiCollageCache? c = cache;
    if (c == null || shot >= plans.length) return;
    paintCollageItems(canvas, c, plans[shot], CollageLayer.back, time);
  }

  /// 镜头的前层拼贴：在前层装饰件之后调，镜头容器坐标。
  void paintShotFront(ui.Canvas canvas, int shot, double time) {
    final HanabiCollageCache? c = cache;
    if (c == null || shot >= plans.length) return;
    paintCollageItems(canvas, c, plans[shot], CollageLayer.front, time);
  }

  void dispose() {
    cache?.dispose();
    cache = null;
  }
}
