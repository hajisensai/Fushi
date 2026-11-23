/// 全屏歌词动画的背景层（folia `src/components/visualizer/backgrounds/registry.tsx`）：背景与样式
/// 独立组合，宿主按样式的背景请求在样式下面画选中的背景。
///
/// 加背景 = 在 [lyricVisualizerBackgrounds] 里加一项（id 落库，冻结）。背景参数与样式参数存在同一张
/// 表里（偏好 `music_visualizer_tunings`），键是 [lyricVisualizerBackgroundTuningKey]。
library;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/backgrounds.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 样式要什么背景。
enum LyricVisualizerBackgroundKind {
  /// 用户在设置里选的共享背景（默认）。
  selected,

  /// 不要共享背景：样式自己画全部背景，宿主只铺一层 `palette.background` 纯色底。
  none,

  /// 指定某个背景（[LyricVisualizerBackgroundRequest.id]）。
  specific,

  /// 什么都不画（下面歌词页的背景透出来）。
  transparent,
}

/// 样式的背景请求（`LyricVisualizerEntry.background` 按参数算出来）。
@immutable
class LyricVisualizerBackgroundRequest {
  const LyricVisualizerBackgroundRequest._(this.kind)
    : id = null,
      tuningOverrides = const <String, Object>{};

  const LyricVisualizerBackgroundRequest._full(
    this.kind,
    this.id,
    this.tuningOverrides,
  );

  /// 指定某个背景；[id] 不认识时回落用户选的。
  const LyricVisualizerBackgroundRequest.specific(
    String this.id, {
    this.tuningOverrides = const <String, Object>{},
  }) : kind = LyricVisualizerBackgroundKind.specific;

  static const LyricVisualizerBackgroundRequest selected =
      LyricVisualizerBackgroundRequest._(
        LyricVisualizerBackgroundKind.selected,
      );
  static const LyricVisualizerBackgroundRequest none =
      LyricVisualizerBackgroundRequest._(LyricVisualizerBackgroundKind.none);
  static const LyricVisualizerBackgroundRequest transparent =
      LyricVisualizerBackgroundRequest._(
        LyricVisualizerBackgroundKind.transparent,
      );

  final LyricVisualizerBackgroundKind kind;
  final String? id;

  /// 叠在用户背景参数上的覆盖（folia 样式的 `background` 配置，如浮名把「通用」背景的几何图形关掉：
  /// `{'disableGeometricBackground': true}`）。只对画出来的那个背景声明过的参数生效，其余键忽略；
  /// 不落库，用户存的值不变。
  final Map<String, Object> tuningOverrides;

  /// 同一请求，再叠上 [overrides]（后写的赢）。
  LyricVisualizerBackgroundRequest withTuning(Map<String, Object> overrides) =>
      overrides.isEmpty
      ? this
      : LyricVisualizerBackgroundRequest._full(kind, id, <String, Object>{
          ...tuningOverrides,
          ...overrides,
        });

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerBackgroundRequest &&
      other.kind == kind &&
      other.id == id &&
      mapEquals(other.tuningOverrides, tuningOverrides);

  @override
  int get hashCode => Object.hash(
    kind,
    id,
    Object.hashAllUnordered(
      tuningOverrides.entries.map(
        (MapEntry<String, Object> e) => Object.hash(e.key, e.value),
      ),
    ),
  );
}

/// 一个背景的注册项。
@immutable
class LyricVisualizerBackgroundEntry {
  const LyricVisualizerBackgroundEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
    this.tunings = const <LyricVisualizerTuningSpec>[],
    this.drawsNothing = false,
  });

  /// 落库值（冻结）。
  final String id;
  final String Function() label;
  final IconData icon;

  /// 画背景（填满约束、不吃点击）。[context] 是当前样式的输入（时钟 / 配色 / 音频 / 封面），
  /// [tuning] 是这个背景自己的参数。
  final Widget Function(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
  )
  builder;
  final List<LyricVisualizerTuningSpec> tunings;

  /// true = 本身不画东西（[lyricVisualizerFluidBackgroundId]：歌词页的流体背景本来就铺在宿主下面）。
  final bool drawsNothing;
}

/// 出厂默认背景：歌词页的流体背景（样式 / 动效 / 饱和度在 设置 › 音乐 › 歌词页背景）。它由歌词页
/// 画在宿主下面，这里只占位、不重复画一份。
const String lyricVisualizerFluidBackgroundId = 'fluid';

/// 纯色（`palette.background`）。
const String lyricVisualizerSolidBackgroundId = 'solid';

/// 背景参数在 `music_visualizer_tunings` 里的键（与样式 prefValue 不会撞：带前缀）。
String lyricVisualizerBackgroundTuningKey(String backgroundId) =>
    'background:$backgroundId';

/// 全部背景（顺序即设置里的顺序）：歌词页背景、纯色，再接 folia 移植的背景（`backgrounds/`）。
final List<LyricVisualizerBackgroundEntry> lyricVisualizerBackgrounds =
    <LyricVisualizerBackgroundEntry>[
      LyricVisualizerBackgroundEntry(
        id: lyricVisualizerFluidBackgroundId,
        label: () => t.music_visualizer_background_fluid,
        icon: FushiIcons.lyrics,
        drawsNothing: true,
        builder: (LyricVisualizerContext c, LyricVisualizerTuning _) =>
            const SizedBox.expand(),
      ),
      LyricVisualizerBackgroundEntry(
        id: lyricVisualizerSolidBackgroundId,
        label: () => t.music_visualizer_background_solid,
        icon: FushiIcons.formatShapes,
        builder: (LyricVisualizerContext c, LyricVisualizerTuning _) =>
            ColoredBox(color: c.palette.background),
      ),
      ...lyricVisualizerPortedBackgrounds,
    ];

/// 按 id 取背景；不认识的回落默认（流体）。
LyricVisualizerBackgroundEntry lyricVisualizerBackgroundOf(String? id) {
  for (final LyricVisualizerBackgroundEntry e in lyricVisualizerBackgrounds) {
    if (e.id == id) return e;
  }
  return lyricVisualizerBackgrounds.first;
}

/// 解析一个样式的背景请求：返回要画的背景（null = 什么都不画）。[selectedId] 是用户选的共享背景；
/// [noneFallback] 是请求 `none` 时铺的纯色底。
LyricVisualizerBackgroundEntry? resolveLyricVisualizerBackground(
  LyricVisualizerBackgroundRequest request,
  String? selectedId,
) {
  switch (request.kind) {
    case LyricVisualizerBackgroundKind.selected:
      return lyricVisualizerBackgroundOf(selectedId);
    case LyricVisualizerBackgroundKind.specific:
      for (final LyricVisualizerBackgroundEntry e
          in lyricVisualizerBackgrounds) {
        if (e.id == request.id) return e;
      }
      return lyricVisualizerBackgroundOf(selectedId);
    case LyricVisualizerBackgroundKind.none:
      return lyricVisualizerBackgroundOf(lyricVisualizerSolidBackgroundId);
    case LyricVisualizerBackgroundKind.transparent:
      return null;
  }
}

/// 背景 [background] 这一帧生效的参数：用户存的值（[stored]）叠上样式请求里的覆盖
/// （[LyricVisualizerBackgroundRequest.tuningOverrides]），再按背景声明规整。
LyricVisualizerTuning lyricVisualizerBackgroundTuning(
  LyricVisualizerBackgroundEntry background,
  Map<String, Object?> stored,
  LyricVisualizerBackgroundRequest request,
) => LyricVisualizerTuning(
  background.tunings,
  request.tuningOverrides.isEmpty
      ? stored
      : <String, Object?>{...stored, ...request.tuningOverrides},
);
