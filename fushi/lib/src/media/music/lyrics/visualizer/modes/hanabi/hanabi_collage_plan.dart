/// PV 拼贴的编排（移植 folia `hanabi/collage/collagePlan.ts`，纯数据，不碰画布）：每个镜头按族、情绪与种子
/// 挑一种「拼贴配方」，算出每个拼贴件的位置、颜色与出入场时刻。
///
/// 日系动漫 PV 的手帐感：斜跨画面的装饰带（电影胶片、剪刀剪出的剪切线、蕾丝花边，都不带字）、重复的空心字、
/// 带白边的贴纸、胶带、格子纸片、小窗口、编号标签，加上烟花开花时蹦出来的图标贴纸与升空时跟着尾迹的小图标。
/// 间奏镜头放一条胶片与一路往上飘的贴纸气球。坐标都在镜头容器里（与文字的本地坐标一致）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_program.dart';

enum CollageRecipe {
  scrapbook,
  strips,
  echo,
  window,
  stickerbomb,
  quiet,
  bridge,
  opening,
}

enum StickerShape { heart, star, sparkle, flower, cloud, ribbon, cat, bubble }

enum TapePattern { stripe, dot, check }

enum PatchPattern { grid, dots, gingham, plain }

/// 装饰带：电影胶片（齿孔 + 一格格粉彩画面）、剪切线（剪刀剪过去留下虚线）、蕾丝花边（波浪边 + 孔眼）。
enum StripStyle { film, cut, lace }

enum CollageLayer { back, front }

/// 拼贴件（folia `CollageItem` 的联合类型）。
sealed class CollageItem {
  const CollageItem();

  /// 这一件最后可见的时刻。
  double get end;
}

/// 带出场 / 退场时刻的件（folia `Timed`）。
sealed class CollageTimed extends CollageItem {
  CollageTimed({
    required this.at,
    required this.exitAt,
    required this.exitDuration,
  });

  /// 出场开始的时刻。
  double at;
  double exitAt;
  double exitDuration;

  @override
  double get end => exitAt + exitDuration;
}

class StripItem extends CollageTimed {
  StripItem({
    required this.style,
    required this.x,
    required this.y,
    required this.length,
    required this.thickness,
    required this.rotation,
    required this.color,
    required this.speed,
    required this.from,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final StripStyle style;
  final double x;
  double y;
  final double length;
  final double thickness;
  final double rotation;

  /// 主色：胶片的画面格、剪切线的虚线、花边里穿的缎带。
  final int color;

  /// 图案沿带子走的速度（像素 / 秒，带方向）。
  final double speed;

  /// 从哪一端擦出（-1 / 1）。
  final int from;
}

class EchoItem extends CollageTimed {
  EchoItem({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
    required this.text,
    required this.color,
    required this.size,
    required this.vertical,
    required this.speed,
    required this.alpha,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final String text;
  final int color;
  final double size;

  /// false：横排成一行（folia axis 'x'）；true：竖着摞成一列（axis 'y'）。
  final bool vertical;
  final double speed;
  final double alpha;
}

class StickerItem extends CollageTimed {
  StickerItem({
    required this.shape,
    required this.x,
    required this.y,
    required this.size,
    required this.rotation,
    required this.color,
    required this.label,
    required this.layer,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final StickerShape shape;
  final double x;
  final double y;
  final double size;
  final double rotation;
  final int color;

  /// 对话框贴纸里的字。
  final String? label;
  final CollageLayer layer;
}

class TapeItem extends CollageTimed {
  TapeItem({
    required this.x,
    required this.y,
    required this.length,
    required this.width,
    required this.rotation,
    required this.color,
    required this.pattern,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final double x;
  final double y;
  final double length;
  final double width;
  final double rotation;
  final int color;
  final TapePattern pattern;
}

class PatchItem extends CollageTimed {
  PatchItem({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
    required this.color,
    required this.pattern,
    required this.dark,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final int color;
  final PatchPattern pattern;

  /// 深色卡片（字没有色块时用，保证白字看得清）。
  final bool dark;
}

class WindowItem extends CollageTimed {
  WindowItem({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rotation,
    required this.bar,
    required this.title,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final double bar;
  final String title;
}

class LabelItem extends CollageTimed {
  LabelItem({
    required this.x,
    required this.y,
    required this.text,
    required this.color,
    required this.size,
    required this.rotation,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final double x;
  final double y;
  final String text;
  final int color;
  final double size;
  final double rotation;
}

/// 开场标题卡里的曲名大字：弹出后轻轻上下浮动。
class HeadlineItem extends CollageTimed {
  HeadlineItem({
    required this.x,
    required this.y,
    required this.text,
    required this.color,
    required this.size,
    required this.rotation,
    required super.at,
    required super.exitAt,
    required super.exitDuration,
  });
  final double x;
  final double y;
  final String text;
  final int color;
  final double size;
  final double rotation;
}

/// 图标贴纸：开花一瞬蹦出、停一会儿、往上飘着淡出。
class PopItem extends CollageItem {
  const PopItem({
    required this.x,
    required this.y,
    required this.icon,
    required this.color,
    required this.size,
    required this.rotation,
    required this.at,
    required this.duration,
  });
  final double x;
  final double y;
  final String icon;
  final int color;
  final double size;
  final double rotation;
  final double at;
  final double duration;

  @override
  double get end => at + duration;
}

/// 升空的小图标：跟着尾迹的头往上走、一路转着，到顶淡出。
class WhooshItem extends CollageItem {
  const WhooshItem({
    required this.icon,
    required this.fromX,
    required this.fromY,
    required this.toX,
    required this.toY,
    required this.at,
    required this.duration,
    required this.color,
    required this.size,
  });
  final String icon;
  final double fromX;
  final double fromY;
  final double toX;
  final double toY;
  final double at;
  final double duration;
  final int color;
  final double size;

  @override
  double get end => at + duration + 0.55;
}

/// 间奏的贴纸气球：从画面下面一路飘上去。
class FloaterItem extends CollageItem {
  const FloaterItem({
    required this.shape,
    required this.x,
    required this.y,
    required this.rise,
    required this.size,
    required this.color,
    required this.at,
    required this.duration,
    required this.sway,
  });
  final StickerShape shape;
  final double x;
  final double y;
  final double rise;
  final double size;
  final int color;
  final double at;
  final double duration;
  final double sway;

  @override
  double get end => at + duration;
}

class CollageRect {
  const CollageRect(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
}

class CollageBurst {
  const CollageBurst({
    required this.x,
    required this.y,
    required this.at,
    required this.main,
    required this.radius,
  });
  final double x;
  final double y;
  final double at;

  /// 主烟花（文字入场时那一发、间奏的连发）。
  final bool main;
  final double radius;
}

class CollageLaunch {
  const CollageLaunch({
    required this.fromX,
    required this.fromY,
    required this.toX,
    required this.toY,
    required this.at,
    required this.duration,
  });
  final double fromX;
  final double fromY;
  final double toX;
  final double toY;
  final double at;
  final double duration;
}

class CollageOpening {
  const CollageOpening(this.title, this.artist);
  final String title;
  final String? artist;
}

class CollagePlanInput {
  const CollagePlanInput({
    required this.seed,
    required this.family,
    required this.mood,
    required this.isBridge,
    required this.block,
    required this.shotNumber,
    required this.bounds,
    required this.screen,
    this.screenAt,
    required this.unit,
    required this.palette,
    required this.enterAt,
    required this.exitAt,
    required this.exitDuration,
    required this.start,
    required this.end,
    required this.keyword,
    required this.motifs,
    required this.bursts,
    required this.launches,
    required this.amount,
    this.icons = const <String>[],
    required this.previous,
    this.opening,
  });
  final String seed;
  final String family;
  final HanabiMood mood;
  final bool isBridge;
  final BlockStyle block;

  /// 镜头在单元里的序号（编号标签用）。
  final int shotNumber;

  /// 字组静止时的包围盒；间奏为文字区。
  final CollageRect bounds;

  /// 镜头定格时画面在镜头容器里的范围。
  final CollageRect screen;

  /// time 时刻画面在镜头容器里的范围；不给按 [screen]。
  final CollageRect Function(double time)? screenAt;
  final double unit;
  final HanabiPalette palette;
  final double enterAt;
  final double exitAt;
  final double exitDuration;
  final double start;
  final double end;
  final String? keyword;
  final List<String> motifs;
  final List<CollageBurst> bursts;
  final List<CollageLaunch> launches;

  /// tuning.collage（0..2）。
  final double amount;

  /// 开花时蹦出来的图标名；空时用 [kHanabiFallbackIcon]。
  final List<String> icons;
  final CollageRecipe? previous;
  final CollageOpening? opening;
}

class CollagePlan {
  const CollagePlan(this.recipe, this.items);
  final CollageRecipe? recipe;
  final List<CollageItem> items;

  static const CollagePlan empty = CollagePlan(null, <CollageItem>[]);

  /// 所有件里最晚的可见时刻（没有件时 -∞）。
  double get end {
    double out = double.negativeInfinity;
    for (final CollageItem item in items) {
      out = math.max(out, item.end);
    }
    return out;
  }
}

/// 每个族偏好的配方（前面的权重大）。
const Map<String, List<CollageRecipe>> _familyRecipes =
    <String, List<CollageRecipe>>{
      'uchiage': <CollageRecipe>[
        CollageRecipe.strips,
        CollageRecipe.scrapbook,
        CollageRecipe.stickerbomb,
      ],
      'kiku': <CollageRecipe>[
        CollageRecipe.echo,
        CollageRecipe.strips,
        CollageRecipe.window,
      ],
      'botan': <CollageRecipe>[
        CollageRecipe.stickerbomb,
        CollageRecipe.scrapbook,
        CollageRecipe.window,
      ],
      'yanagi': <CollageRecipe>[CollageRecipe.quiet, CollageRecipe.echo],
      'senrin': <CollageRecipe>[
        CollageRecipe.stickerbomb,
        CollageRecipe.strips,
        CollageRecipe.scrapbook,
      ],
      'hoshikuzu': <CollageRecipe>[
        CollageRecipe.window,
        CollageRecipe.quiet,
        CollageRecipe.stickerbomb,
      ],
      'obi': <CollageRecipe>[
        CollageRecipe.strips,
        CollageRecipe.scrapbook,
        CollageRecipe.echo,
      ],
      'senko': <CollageRecipe>[
        CollageRecipe.window,
        CollageRecipe.echo,
        CollageRecipe.strips,
      ],
      'senkohanabi': <CollageRecipe>[
        CollageRecipe.quiet,
        CollageRecipe.scrapbook,
      ],
      'shakudama': <CollageRecipe>[
        CollageRecipe.echo,
        CollageRecipe.strips,
        CollageRecipe.stickerbomb,
      ],
    };

/// 日系可爱 PV 的糖果色。
const List<int> kCollageCandy = <int>[
  0xffb3d1,
  0xb8f2e6,
  0xfff1a8,
  0xd7c4ff,
  0xffc9a8,
  0xa8dcff,
];

/// 标签上的深色字、胶片片基。
const int kCollageInk = 0x2b1f3d;

/// 深色卡片。
const int kCollageDeepCard = 0x1d1838;

/// 没有主题图标时用的图标（folia 是 lucide 的 `Flower`）。
const String kHanabiFallbackIcon = 'Flower';

/// 图标贴纸的描边色：比糖果色深一档，白边上看得清。
const List<int> kCollageIconInks = <int>[
  0xff5fa2,
  0x3fb2ff,
  0xffa31a,
  0x9b6bff,
  0x2ec9a0,
];
const List<String> _bubbleLabels = <String>[
  '♡',
  '!!',
  '♪',
  'LOVE',
  'yay!',
  '(≧▽≦)',
  '☆彡',
];
const List<String> _windowTitles = <String>[
  '♡ hanabi.exe',
  '♪ lyric.txt',
  '✦ night_sky.png',
  '☆ summer.mp3',
  '♡ kirakira.app',
];
const List<StickerShape> _shapes = <StickerShape>[
  StickerShape.heart,
  StickerShape.star,
  StickerShape.sparkle,
  StickerShape.flower,
  StickerShape.cloud,
  StickerShape.ribbon,
  StickerShape.cat,
];
const List<StripStyle> kCollageStripStyles = <StripStyle>[
  StripStyle.film,
  StripStyle.cut,
  StripStyle.lace,
];

/// 各样式带子的粗细（占画面短边）。
double _stripThickness(StripStyle style) => switch (style) {
  StripStyle.film => 0.075,
  StripStyle.cut => 0.045,
  StripStyle.lace => 0.06,
};

T _pick<T>(List<T> list, HanabiRng random) =>
    list[(random() * list.length).floor() % list.length];

/// 调色板颜色的粉彩版：往白里混，保持色相。
int collagePastel(int color, [double amount = 0.45]) =>
    mixRgb(color, 0xffffff, amount);

final RegExp _latin = RegExp(r"^[\p{Script=Latin}\p{N}'’\- ]+$", unicode: true);

/// 一句里最像关键词的词：很短的句子（2–5 个字）整句；否则取最长的词（2–10 个字），拉丁字母转大写。
String? pickCollageKeyword(HanabiLine? line) {
  if (line == null) return null;
  final String text = line.text.trim();
  String shout(String word) =>
      _latin.hasMatch(word) ? word.toUpperCase() : word;
  final int graphemes = line.chars
      .where((String c) => c.trim().isNotEmpty)
      .length;
  if (graphemes >= 2 && graphemes <= 5) return shout(text);
  String? best;
  int bestLength = 0;
  for (final HanabiSegment part in line.segments) {
    if (!part.wordLike) continue;
    final List<String> chars = line.chars.sublist(part.start, part.end);
    int a = 0;
    int b = chars.length;
    while (a < b && chars[a].trim().isEmpty) {
      a++;
    }
    while (b > a && chars[b - 1].trim().isEmpty) {
      b--;
    }
    final int length = b - a;
    if (length < 2 || length > 10) continue;
    if (length > bestLength) {
      best = chars.sublist(a, b).join();
      bestLength = length;
    }
  }
  return best == null ? null : shout(best);
}

/// 挑配方：族偏好里避开上一个镜头的配方；间奏固定 bridge。
CollageRecipe chooseCollageRecipe(
  String family,
  bool isBridge,
  CollageRecipe? previous,
  HanabiRng random,
) {
  if (isBridge) return CollageRecipe.bridge;
  final List<CollageRecipe> preferred =
      _familyRecipes[family] ??
      const <CollageRecipe>[
        CollageRecipe.scrapbook,
        CollageRecipe.strips,
        CollageRecipe.stickerbomb,
      ];
  final List<CollageRecipe> choices = <CollageRecipe>[
    for (final CollageRecipe r in preferred)
      if (r != previous) r,
  ];
  final List<CollageRecipe> list = choices.isNotEmpty ? choices : preferred;
  final double total = list.length * (list.length + 1) / 2;
  double roll = random() * total;
  for (int index = 0; index < list.length; index++) {
    roll -= list.length - index;
    if (roll < 0) return list[index];
  }
  return list.first;
}

/// 数量倍率下的件数：0 时 0，其余至少 min。
int _countOf(double base, double amount, [int min = 1]) =>
    amount <= 0 ? 0 : math.max(min, (base * amount).round());

String _pad2(int n) => n.toString().padLeft(2, '0');

/// 一个镜头的拼贴。确定性：同样的输入（含 seed）永远同样的件。
CollagePlan planShotCollage(CollagePlanInput input) {
  if (input.amount <= 0) return CollagePlan.empty;
  final HanabiRng random = hanabiRng('${input.seed}:collage');
  final CollageRecipe recipe = input.isBridge && input.opening != null
      ? CollageRecipe.opening
      : chooseCollageRecipe(
          input.family,
          input.isBridge,
          input.previous,
          random,
        );
  final CollageRect bounds = input.bounds;
  final CollageRect screen = input.screen;
  final double unit = input.unit;
  final double amount = input.amount;
  final List<CollageItem> items = <CollageItem>[];
  final double exitAt = input.exitAt;
  final double exitDuration = input.exitDuration;
  final List<int> candy = <int>[
    ...kCollageCandy,
    collagePastel(input.palette.accent),
    collagePastel(
      input.palette.sparks.length > 1
          ? input.palette.sparks[1]
          : input.palette.accent,
    ),
  ];
  int candyColor() => _pick(candy, random);

  /// 画面左缘留给胶片与画框朱印的宽度。
  final double railGap = unit * 0.14;
  final double cx = bounds.x + bounds.width / 2;
  final double cy = bounds.y + bounds.height / 2;
  final double sx = screen.x + screen.width / 2;
  double clampX(double x, double pad) =>
      clampD(x, screen.x + railGap * 0.5 + pad, screen.x + screen.width - pad);
  double clampY(double y, double pad) =>
      clampD(y, screen.y + pad, screen.y + screen.height - pad);
  int signed() => random() < 0.5 ? -1 : 1;

  final List<String> motifs = input.motifs.isNotEmpty
      ? input.motifs
      : const <String>['HANABI', '花火'];
  String motif() => _pick(motifs, random);

  StickerItem sticker(
    StickerShape shape,
    double x,
    double y,
    double size,
    double delay, {
    CollageLayer layer = CollageLayer.front,
    String? label,
  }) {
    final double px = clampX(x, size * 0.6);
    final double py = clampY(y, size * 0.6);
    final double rotation = (random() - 0.5) * 0.7;
    return StickerItem(
      shape: shape,
      x: px,
      y: py,
      size: size,
      rotation: rotation,
      color: candyColor(),
      label: label,
      layer: layer,
      at: input.enterAt + delay,
      exitAt: exitAt,
      exitDuration: exitDuration,
    );
  }

  /// 包围盒四角往外的落点（0..3 = 左上、右上、右下、左下）。
  (double, double) corner(int index, double out) {
    final int dx = index == 0 || index == 3 ? -1 : 1;
    final int dy = index < 2 ? -1 : 1;
    return (
      (dx < 0 ? bounds.x : bounds.x + bounds.width) + dx * out,
      (dy < 0 ? bounds.y : bounds.y + bounds.height) + dy * out * 0.6,
    );
  }

  StripItem strip(StripStyle style, int side, double delay) {
    final double thickness = math.max(
      style == StripStyle.cut ? 14 : 18,
      unit * _stripThickness(style),
    );
    final double gap = unit * 0.05 + thickness / 2;
    double y = side < 0 ? bounds.y - gap : bounds.y + bounds.height + gap;
    y = clampY(y, thickness);
    final double rotation = side * (0.06 + random() * 0.1);
    final int color = candyColor();
    final double speed =
        signed() *
        unit *
        (style == StripStyle.film ? 0.12 : 0.05) *
        (0.8 + random() * 0.4);
    final int from = signed();
    return StripItem(
      style: style,
      x: sx,
      y: y,
      length:
          math.sqrt(
            screen.width * screen.width + screen.height * screen.height,
          ) *
          1.25,
      thickness: thickness,
      rotation: rotation,
      color: color,
      speed: speed,
      from: from,
      at: input.enterAt + delay,
      exitAt: exitAt,
      exitDuration: exitDuration,
    );
  }

  EchoItem? echo(bool vertical, int side, double alpha) {
    final String text = input.keyword ?? motif();
    if (text.trim().isEmpty) return null;
    final double size = unit * (vertical ? 0.11 : 0.13);
    if (!vertical) {
      final double y = side < 0
          ? bounds.y - size * 0.75
          : bounds.y + bounds.height + size * 0.75;
      final double py = clampY(y, size * 0.5);
      final double rotation = (random() - 0.5) * 0.08;
      final int color = random() < 0.5 ? input.palette.paper : candyColor();
      return EchoItem(
        vertical: false,
        text: text,
        size: size,
        alpha: alpha,
        x: sx,
        y: py,
        width: screen.width * 1.3,
        height: size * 1.25,
        rotation: rotation,
        color: color,
        speed: side * unit * 0.07,
        at: input.enterAt - 0.15,
        exitAt: exitAt,
        exitDuration: exitDuration,
      );
    }
    final double width =
        size * math.max(1, text.runes.length) * 0.9 + size * 0.4;
    final double free = (screen.width - bounds.width) / 2;
    final double x = side < 0
        ? bounds.x - width * 0.55
        : bounds.x + bounds.width + width * 0.55;
    final int color = random() < 0.5 ? input.palette.paper : candyColor();
    return EchoItem(
      vertical: true,
      text: text,
      size: size,
      alpha: alpha,
      x: clampD(
        free > width * 0.6
            ? x
            : (side < 0 ? double.negativeInfinity : double.infinity),
        screen.x + railGap + width * 0.5,
        screen.x + screen.width - unit * 0.06 - width * 0.5,
      ),
      y: cy,
      width: width,
      height: screen.height * 1.3,
      rotation: 0,
      color: color,
      speed: side * unit * 0.06,
      at: input.enterAt - 0.15,
      exitAt: exitAt,
      exitDuration: exitDuration,
    );
  }

  PatchItem patch(
    double pad,
    double offset,
    PatchPattern pattern,
    double delay,
  ) {
    final bool dark =
        input.block == BlockStyle.none ||
        input.block == BlockStyle.outline ||
        input.block == BlockStyle.marker;
    final double x = cx + offset * signed();
    final double y = cy + offset * signed() * 0.6;
    final double rotation = (random() - 0.5) * 0.09;
    return PatchItem(
      x: x,
      y: y,
      width: bounds.width + pad * 2,
      height: bounds.height + pad * 2,
      rotation: rotation,
      color: dark ? kCollageDeepCard : candyColor(),
      pattern: pattern,
      dark: dark,
      at: input.enterAt + delay,
      exitAt: exitAt,
      exitDuration: exitDuration,
    );
  }

  TapeItem tape(int index, double delay, CollageRect around) {
    final double length = unit * (0.12 + random() * 0.04);
    final double x = index == 0 || index == 3
        ? around.x
        : around.x + around.width;
    final double y = index < 2 ? around.y : around.y + around.height;
    final int diagonal = index == 0 || index == 2 ? -1 : 1;
    final double rotation = diagonal * (0.62 + random() * 0.2);
    final int color = candyColor();
    return TapeItem(
      x: x,
      y: y,
      length: length,
      width: length * 0.3,
      rotation: rotation,
      color: color,
      pattern: _pick(TapePattern.values, random),
      at: input.enterAt + delay,
      exitAt: exitAt,
      exitDuration: exitDuration,
    );
  }

  LabelItem label(double delay) {
    final double size = math.max(12, unit * 0.026);
    final String text = random() < 0.5
        ? 'No.${_pad2(input.shotNumber + 1)}'
        : '#${_pad2(input.shotNumber + 1)} ${_pick(const <String>['♪', '♡', '✦'], random)}';
    final (double ax, double ay) = corner(3, size * 0.4);
    final double x = clampX(ax + size * 2.2, size * 3);
    final double y = clampY(ay + size * 0.9, size);
    final int color = candyColor();
    return LabelItem(
      x: x,
      y: y,
      text: text,
      color: color,
      size: size,
      rotation: (random() - 0.5) * 0.2,
      at: input.enterAt + delay,
      exitAt: exitAt,
      exitDuration: exitDuration,
    );
  }

  double stickerSize() => unit * (0.065 + random() * 0.04);

  switch (recipe) {
    case CollageRecipe.scrapbook:
      final double pad = unit * 0.045;
      final PatchItem card = patch(
        pad,
        unit * 0.012,
        _pick(const <PatchPattern>[
          PatchPattern.grid,
          PatchPattern.dots,
          PatchPattern.gingham,
        ], random),
        -0.12,
      );
      items
        ..add(patch(pad * 0.6, unit * 0.04, PatchPattern.plain, -0.2))
        ..add(card);
      final CollageRect around = CollageRect(
        card.x - card.width / 2,
        card.y - card.height / 2,
        card.width,
        card.height,
      );
      final int first = (random() * 2).floor();
      items
        ..add(tape(first, 0.05, around))
        ..add(tape(first + 2, 0.12, around));
      for (int k = 0; k < _countOf(1.5, amount); k++) {
        final (double x, double y) = corner(
          (first + 1 + k * 2) % 4,
          unit * 0.03,
        );
        final StickerShape shape = _pick(_shapes, random);
        items.add(sticker(shape, x, y, stickerSize(), 0.25 + k * 0.1));
      }
      items.add(label(0.3));
    case CollageRecipe.strips:
      final int side = random() < 0.5 ? -1 : 1;
      final StripStyle first = _pick(kCollageStripStyles, random);
      items.add(strip(first, side, -0.1));
      if (amount >= 0.75) {
        final StripStyle second = _pick(<StripStyle>[
          for (final StripStyle s in kCollageStripStyles)
            if (s != first) s,
        ], random);
        items.add(strip(second, side == -1 ? 1 : -1, 0.05));
      }
      for (int k = 0; k < _countOf(2, amount); k++) {
        final (double x, double y) = corner(
          (k * 2 + (side < 0 ? 1 : 0)) % 4,
          unit * 0.04,
        );
        items.add(
          sticker(
            k.isEven ? StickerShape.sparkle : StickerShape.star,
            x,
            y,
            stickerSize() * 0.85,
            0.2 + k * 0.12,
          ),
        );
      }
    case CollageRecipe.echo:
      final bool vertical = screen.width - bounds.width > unit * 0.5;
      final EchoItem? first = echo(vertical, -1, 0.3);
      final EchoItem? second = echo(vertical, 1, 0.3);
      if (first != null) items.add(first);
      if (second != null && amount >= 0.75) items.add(second);
      final (double x, double y) = corner(1, unit * 0.04);
      final double size = stickerSize() * 1.6;
      items.add(
        sticker(
          StickerShape.bubble,
          x,
          y,
          size,
          0.3,
          label: _pick(_bubbleLabels, random),
        ),
      );
    case CollageRecipe.window:
      final double pad = unit * 0.05;
      final double bar = math.max(16, unit * 0.04);
      final double width = bounds.width + pad * 2;
      final double height = bounds.height + pad * 2 + bar;
      final double rotation = (random() - 0.5) * 0.05;
      items.add(
        WindowItem(
          x: cx,
          y: cy - bar / 2,
          width: width,
          height: height,
          rotation: rotation,
          bar: bar,
          title: _pick(_windowTitles, random),
          at: input.enterAt - 0.18,
          exitAt: exitAt,
          exitDuration: exitDuration,
        ),
      );
      for (int k = 0; k < _countOf(2, amount); k++) {
        final (double x, double y) = corner(k == 0 ? 0 : 2, unit * 0.035);
        final StickerShape shape = _pick(_shapes, random);
        items.add(sticker(shape, x, y, stickerSize(), 0.25 + k * 0.12));
      }
    case CollageRecipe.stickerbomb:
      final int count = _countOf(4, amount, 2);
      for (int k = 0; k < count; k++) {
        final (double x, double y) = corner(
          k % 4,
          unit * (0.03 + 0.03 * (k ~/ 4)),
        );
        final double jitter = unit * 0.03;
        final StickerShape shape = _pick(_shapes, random);
        final double jx = (random() - 0.5) * jitter;
        final double jy = (random() - 0.5) * jitter;
        items.add(
          sticker(shape, x + jx, y + jy, stickerSize(), 0.15 + k * 0.08),
        );
      }
      final (double x, double y) = corner((random() * 4).floor(), unit * 0.09);
      final double size = stickerSize() * 1.5;
      items.add(
        sticker(
          StickerShape.bubble,
          x,
          y,
          size,
          0.4,
          label: _pick(_bubbleLabels, random),
        ),
      );
    case CollageRecipe.quiet:
      final EchoItem? row = echo(false, random() < 0.5 ? -1 : 1, 0.16);
      if (row != null) items.add(row);
      final (double x, double y) = corner((random() * 4).floor(), unit * 0.03);
      items.add(sticker(StickerShape.sparkle, x, y, stickerSize() * 0.7, 0.35));
    case CollageRecipe.opening:
      final CollageOpening opening = input.opening!;
      final double leaveAt = math.max(input.start + 1.2, input.end - 0.7);
      const double leaveDuration = 0.5;
      final int titleLength = opening.title.runes.length;
      final double titleSize = math.min(
        unit * 0.11,
        screen.width * 0.5 / math.max(4, titleLength * 0.62),
      );
      final double width = math.min(
        screen.width * 0.72,
        math.max(unit * 0.6, titleSize * titleLength * 0.7 + unit * 0.2),
      );
      final double bar = math.max(16, unit * 0.045);
      final double height =
          titleSize * 1.9 + bar + (opening.artist != null ? unit * 0.06 : 0);
      final double y = screen.y + screen.height * 0.42;
      final double at = input.start + 0.25;
      items
        ..add(
          WindowItem(
            x: sx,
            y: y,
            width: width,
            height: height,
            rotation: -0.02,
            bar: bar,
            title: '♪ now playing',
            at: at,
            exitAt: leaveAt,
            exitDuration: leaveDuration,
          ),
        )
        ..add(
          HeadlineItem(
            x: sx,
            y: y + bar / 2 - (opening.artist != null ? unit * 0.02 : 0),
            text: opening.title,
            color: candyColor(),
            size: titleSize,
            rotation: -0.03,
            at: at + 0.18,
            exitAt: leaveAt,
            exitDuration: leaveDuration,
          ),
        );
      final String? artist = opening.artist;
      if (artist != null) {
        items.add(
          LabelItem(
            x: sx,
            y: y + height / 2 - unit * 0.045,
            text: artist,
            color: candyColor(),
            size: math.max(12, unit * 0.028),
            rotation: 0.02,
            at: at + 0.4,
            exitAt: leaveAt,
            exitDuration: leaveDuration,
          ),
        );
      }
      final CollageRect card = CollageRect(
        sx - width / 2,
        y - height / 2,
        width,
        height,
      );
      for (int k = 0; k < 4; k++) {
        final double x = k == 0 || k == 3 ? card.x : card.x + card.width;
        final double cornerY = k < 2 ? card.y : card.y + card.height;
        final StickerShape shape = _pick(const <StickerShape>[
          StickerShape.heart,
          StickerShape.star,
          StickerShape.ribbon,
          StickerShape.sparkle,
        ], random);
        final StickerItem base = sticker(shape, x, cornerY, unit * 0.075, 0);
        base
          ..at = at + 0.3 + k * 0.08
          ..exitAt = leaveAt
          ..exitDuration = leaveDuration;
        items.add(base);
      }
      final int floaters = _countOf(5, amount, 2);
      for (int k = 0; k < floaters; k++) {
        final StickerShape shape = _pick(const <StickerShape>[
          StickerShape.heart,
          StickerShape.star,
          StickerShape.sparkle,
        ], random);
        final double x = screen.x + screen.width * (0.1 + random() * 0.8);
        final double rise = screen.height * (1.25 + random() * 0.3);
        final double size = unit * (0.045 + random() * 0.04);
        final int color = candyColor();
        final double fat =
            input.start +
            0.6 +
            (k / floaters) * math.max(0.5, input.end - input.start - 1.5);
        final double duration = 3.4 + random() * 1.4;
        final double sway = unit * (0.02 + random() * 0.03);
        items.add(
          FloaterItem(
            shape: shape,
            x: x,
            y: screen.y + screen.height * 1.08,
            rise: rise,
            size: size,
            color: color,
            at: fat,
            duration: duration,
            sway: sway,
          ),
        );
      }
    case CollageRecipe.bridge:
      final StripItem film = strip(StripStyle.film, 1, 0);
      film
        ..y = screen.y + screen.height * (0.62 + random() * 0.12)
        ..at = input.start + 0.1;
      items.add(film);
      final int floaters = _countOf(7, amount, 3);
      final double span = math.max(0.5, input.end - input.start);
      for (int k = 0; k < floaters; k++) {
        final double at =
            input.start + (k / floaters) * span * 0.8 + random() * 0.3;
        final StickerShape shape = _pick(const <StickerShape>[
          StickerShape.heart,
          StickerShape.star,
          StickerShape.sparkle,
          StickerShape.flower,
        ], random);
        final double x = screen.x + screen.width * (0.08 + random() * 0.84);
        final double rise = screen.height * (1.25 + random() * 0.3);
        final double size = unit * (0.05 + random() * 0.05);
        final int color = candyColor();
        final double duration = 3.2 + random() * 1.6;
        final double sway = unit * (0.02 + random() * 0.03);
        items.add(
          FloaterItem(
            shape: shape,
            x: x,
            y: screen.y + screen.height * 1.08,
            rise: rise,
            size: size,
            color: color,
            at: at,
            duration: duration,
            sway: sway,
          ),
        );
      }
  }

  // 图标贴纸：主烟花开花的一瞬（间奏的连发隔一发一个，最多 5 个）。
  final List<String> icons = input.icons.isNotEmpty
      ? input.icons
      : const <String>[kHanabiFallbackIcon];
  int iconTurn = (random() * icons.length).floor();
  String nextIcon() => icons[iconTurn++ % icons.length];
  final List<CollageBurst> mains = <CollageBurst>[
    for (final CollageBurst b in input.bursts)
      if (b.main) b,
  ];
  final List<CollageBurst> popped = recipe == CollageRecipe.opening
      ? const <CollageBurst>[]
      : input.isBridge
      ? <CollageBurst>[
          for (int i = 0; i < mains.length; i++)
            if (i.isEven) mains[i],
        ].take(5).toList()
      : mains.take(1).toList();
  for (final CollageBurst burst in popped) {
    if (random() > math.min(1, 0.55 + 0.35 * amount)) continue;
    final double size =
        unit * (input.isBridge ? 0.1 : 0.115) * (0.9 + random() * 0.25);
    final CollageRect view = input.screenAt?.call(burst.at + 0.35) ?? screen;
    final double halfWidth = size * 0.6;
    final double left = view.x + railGap * 0.5 + halfWidth;
    final double right = view.x + view.width - halfWidth - size * 0.3;
    final double top = view.y + size * 0.8;
    final double bottom = view.y + view.height * 0.8;
    final bool preferRight = input.isBridge ? burst.x > sx : burst.x >= cx;
    (double, double) beside(int dir) => (
      dir > 0
          ? bounds.x + bounds.width + halfWidth + size * 0.3
          : bounds.x - halfWidth - size * 0.3,
      bounds.y + size * 0.2,
    );
    final List<(double, double)> candidates = input.isBridge
        ? <(double, double)>[
            (
              burst.x + (preferRight ? 1 : -1) * burst.radius * 0.45,
              burst.y - burst.radius * 0.35,
            ),
          ]
        : <(double, double)>[
            beside(preferRight ? 1 : -1),
            beside(preferRight ? -1 : 1),
            (
              cx + (random() - 0.5) * bounds.width * 0.3,
              bounds.y - size * 0.75,
            ),
          ];
    bool fits((double, double) p) =>
        p.$1 >= left && p.$1 <= right && p.$2 >= top && p.$2 <= bottom;
    final (double, double) spot = candidates.firstWhere(
      fits,
      orElse: () => candidates.first,
    );
    final String icon = nextIcon();
    final int color = _pick(kCollageIconInks, random);
    final double rotation = (preferRight ? 1 : -1) * (0.08 + random() * 0.18);
    items.add(
      PopItem(
        icon: icon,
        x: clampD(spot.$1, left, math.max(left, right)),
        y: clampD(spot.$2, top, math.max(top, bottom)),
        color: color,
        size: size,
        rotation: rotation,
        at: burst.at + 0.04,
        duration: 1.3,
      ),
    );
  }

  // 升空的小图标：只跟主烟花的尾迹，最多两条。
  for (final CollageLaunch launch in input.launches.take(2)) {
    if (random() > 0.45 + 0.25 * amount) continue;
    final String icon = nextIcon();
    items.add(
      WhooshItem(
        icon: icon,
        fromX: launch.fromX,
        fromY: launch.fromY,
        toX: launch.toX,
        toY: launch.toY,
        at: launch.at,
        duration: launch.duration,
        color: _pick(kCollageIconInks, random),
        size: math.max(18, unit * 0.055),
      ),
    );
  }

  return CollagePlan(recipe, items);
}
