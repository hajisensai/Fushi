/// 媒体库全景的图集：封面缩略图（带发光细边框，辉光预烘焙在格子留边里）与词的字形
/// （细体 / 粗体字心 / 粗体描边三种）拼成少数几张大图，供一次 `drawRawAtlas` 实例化绘制。
///
/// 辉光是**有选择的**：只在封面外沿的留边里，封面本体照原图画、不叠任何光，白封面也不会过曝；
/// 亮度全程固定（调制色只用来整体变暗），远近 / 阶段都不改它。
///
/// 飞到眼前的那张封面与翻开的书用 [renderPanoramaHiResCover] 出的同一张高清图（同一个
/// [paintPanoramaFramedCover]），边框比例与图集格子一致，交接那一帧看不出换了物体。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/panorama/panorama_library.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 辉光留边 = 封面短边 × 本比例（图集格子与高清图共用）。
const double kPanoramaFramePadRatio = 0.16;

/// 发光细边框宽 = 封面短边 × 本比例。
const double kPanoramaBorderRatio = 0.018;

/// 作品种类的边框色相（0..1）。
double panoramaKindHue(PanoramaWorkKind kind) => switch (kind) {
  PanoramaWorkKind.book => 0.09,
  PanoramaWorkKind.manga => 0.95,
  PanoramaWorkKind.video => 0.55,
  PanoramaWorkKind.game => 0.76,
  PanoramaWorkKind.music => 0.40,
};

/// 作品的边框色相（种类色相 + 按下标的轻微抖动，同类作品不完全同色）。
double panoramaWorkHue(PanoramaWork work, int index) {
  final double jitter = ((index * 0.6180339887) % 1.0 - 0.5) * 0.06;
  return (panoramaKindHue(work.kind) + jitter) % 1.0;
}

Color panoramaAccent(double hue) =>
    HSVColor.fromAHSV(1, (hue * 360) % 360, 0.55, 1).toColor();

/// 一套字体（每个词固定分到一套；细体 / 粗体取同族的 w300 / w800）。
class PanoramaFontSet {
  const PanoramaFontSet(this.family, {this.fallback = const <String>[]});

  final String? family;
  final List<String> fallback;
}

/// 画一张带发光细边框的封面：[cover] 是封面本体矩形（不含辉光留边），图按原比例铺满它
/// （卡片宽高比 = 原图比例，所以不裁剪）。[image] 为 null 时画占位（色块 + 标题）。
void paintPanoramaFramedCover(
  Canvas canvas,
  Rect cover,
  ui.Image? image,
  Color accent, {
  String? title,
}) {
  final double short = math.min(cover.width, cover.height);
  final double pad = short * kPanoramaFramePadRatio;
  final double border = math.max(1, short * kPanoramaBorderRatio);
  final double radius = short * 0.035;
  final RRect rrect = RRect.fromRectAndRadius(cover, Radius.circular(radius));
  // 1. 辉光：只有边框外沿那一圈，模糊半径落在留边内；封面本体随后不透明地盖在上面。
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = border * 3
      ..color = accent.withValues(alpha: 0.9)
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, pad * 0.42),
  );
  // 2. 封面本体。
  canvas.save();
  canvas.clipRRect(rrect);
  if (image != null) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      cover,
      Paint()..filterQuality = FilterQuality.medium,
    );
  } else {
    canvas.drawRect(
      cover,
      Paint()
        ..shader = ui.Gradient.linear(cover.topLeft, cover.bottomRight, <Color>[
          Color.lerp(accent, Colors.black, 0.55)!,
          Color.lerp(accent, Colors.black, 0.82)!,
        ]),
    );
    if (title != null && title.isNotEmpty) {
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: title,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.9),
            fontSize: short * 0.13,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 5,
        ellipsis: '…',
      )..layout(maxWidth: cover.width * 0.84);
      tp.paint(
        canvas,
        Offset(cover.left + cover.width * 0.08, cover.top + cover.height * 0.1),
      );
      tp.dispose();
    }
  }
  canvas.restore();
  // 3. 发光细边框本身。
  canvas.drawRRect(
    rrect,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = border
      ..color = Color.lerp(accent, Colors.white, 0.45)!,
  );
}

/// 封面本体尺寸 → 含辉光留边的整张尺寸。
Size panoramaFramedSize(Size cover) {
  final double pad =
      math.min(cover.width, cover.height) * kPanoramaFramePadRatio;
  return Size(cover.width + pad * 2, cover.height + pad * 2);
}

/// 图集 + Rust 建图输入。
class PanoramaAtlas {
  PanoramaAtlas._({
    required this.pages,
    required this.scene,
    required this.aspects,
    required this.hues,
  });

  /// 图集页（下标 = `cellPages` 的值）。
  final List<ui.Image> pages;
  final FfcPanoScene scene;

  /// 每部作品的封面宽高比（高清图按它出）。
  final List<double> aspects;

  /// 每部作品的边框色相。
  final List<double> hues;

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final ui.Image p in pages) {
      p.dispose();
    }
  }
}

/// 图集规格：随平台降档控制显存。
class PanoramaAtlasSpec {
  const PanoramaAtlasSpec({
    required this.pageSize,
    required this.thumbPx,
    required this.emPx,
    required this.maxGlyphs,
    this.maxThumbPx = 0,
    this.coverBudgetPx = 0,
  });

  /// 桌面：4096 页、封面面积 112²～384² 像素（按作品数分 1.25 页预算）、字身 28 像素。
  static const PanoramaAtlasSpec desktop = PanoramaAtlasSpec(
    pageSize: 4096,
    thumbPx: 112,
    maxThumbPx: 384,
    coverBudgetPx: 4096 * 4096 * 1.25,
    emPx: 28,
    maxGlyphs: 6000,
  );

  /// 移动端：2048 页、封面约 88²～256²（1.25 页预算）、字身 22。
  static const PanoramaAtlasSpec mobile = PanoramaAtlasSpec(
    pageSize: 2048,
    thumbPx: 88,
    maxThumbPx: 256,
    coverBudgetPx: 2048 * 2048 * 1.25,
    emPx: 22,
    maxGlyphs: 4000,
  );

  static PanoramaAtlasSpec get current =>
      Platform.isAndroid || Platform.isIOS ? mobile : desktop;

  final int pageSize;

  /// 封面面积边长的下限（作品很多时）。
  final double thumbPx;

  /// 封面面积边长的上限；≤ [thumbPx] 时固定用 [thumbPx]。
  final double maxThumbPx;

  /// 全部封面合计的像素面积预算（决定作品少时能给每张多清晰）。
  final double coverBudgetPx;
  final double emPx;

  /// [works] 部作品时每张封面的面积边长：拉近到球心时封面占屏几百像素，固定 112² 会糊；
  /// 作品少就按预算给大图，作品多再往 [thumbPx] 收，图集总面积有上限。
  double thumbPxFor(int works) {
    if (maxThumbPx <= thumbPx || coverBudgetPx <= 0) return thumbPx;
    final double fit = math.sqrt(coverBudgetPx / math.max(1, works));
    return fit.clamp(thumbPx, maxThumbPx).floorToDouble();
  }

  /// （字体, 字）唯一字形数上限；超出时先合并字体套数，仍超就丢掉引入新字的词。
  final int maxGlyphs;
}

/// 读一张封面并按面积统一缩到 [areaPx]² 左右；读不到返回 null。
Future<({ui.Image image, double aspect})?> _decodeThumb(
  String? path,
  double areaPx,
) async {
  if (path == null || path.isEmpty) return null;
  try {
    final File f = File(path);
    if (!await f.exists()) return null;
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromFilePath(
      path,
    );
    final ui.ImageDescriptor desc = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    if (desc.width <= 0 || desc.height <= 0) {
      desc.dispose();
      return null;
    }
    final double aspect = desc.width / desc.height;
    final int w = math.max(1, (areaPx * math.sqrt(aspect)).round());
    final int h = math.max(1, (areaPx / math.sqrt(aspect)).round());
    final ui.Codec codec = await desc.instantiateCodec(
      targetWidth: math.min(w, desc.width),
      targetHeight: math.min(h, desc.height),
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    desc.dispose();
    return (image: frame.image, aspect: aspect);
  } catch (e, s) {
    // 坏图 / 读不了：记日志（带路径，便于定位是哪张封面），再当没封面画占位。
    ErrorLogService.instance.log('PanoramaAtlas.decodeCover($path)', e, s);
    return null;
  }
}

/// 每个格子要画的内容。
sealed class _CellJob {
  _CellJob(this.w, this.h);

  final double w;
  final double h;
  int page = 0;
  double x = 0;
  double y = 0;

  void paint(Canvas canvas);
}

final class _CoverJob extends _CellJob {
  _CoverJob(super.w, super.h, this.cover, this.image, this.accent, this.title);

  final Size cover;
  final ui.Image? image;
  final Color accent;
  final String title;

  @override
  void paint(Canvas canvas) {
    final double pad = (w - cover.width) / 2;
    paintPanoramaFramedCover(
      canvas,
      Rect.fromLTWH(x + pad, y + pad, cover.width, cover.height),
      image,
      accent,
      title: title,
    );
  }
}

final class _GlyphJob extends _CellJob {
  _GlyphJob(super.w, super.h, this.painter);

  final TextPainter painter;

  @override
  void paint(Canvas canvas) {
    painter.paint(
      canvas,
      Offset(x + (w - painter.width) / 2, y + (h - painter.height) / 2),
    );
  }
}

/// 货架装箱：按高度降序逐行排；放不下就开新页。
void _pack(List<_CellJob> jobs, int pageSize, List<int> pageHeights) {
  final List<_CellJob> order = List<_CellJob>.of(jobs)
    ..sort((_CellJob a, _CellJob b) => b.h.compareTo(a.h));
  int page = 0;
  double x = 0;
  double y = 0;
  double rowH = 0;
  const double gap = 1;
  for (final _CellJob j in order) {
    if (x + j.w > pageSize) {
      x = 0;
      y += rowH + gap;
      rowH = 0;
    }
    if (y + j.h > pageSize) {
      pageHeights.add(pageSize);
      page++;
      x = 0;
      y = 0;
      rowH = 0;
    }
    j
      ..page = page
      ..x = x
      ..y = y;
    x += j.w.ceilToDouble() + gap;
    rowH = math.max(rowH, j.h.ceilToDouble());
  }
  pageHeights.add(math.min(pageSize, (y + rowH + gap).ceil()));
}

/// 词 → 字体套（固定分配：同一个词每次都落在同一套）。
int _fontOf(String word, int sets) {
  int h = 0x811C9DC5;
  for (final int c in word.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return sets <= 1 ? 0 : h % sets;
}

/// 建图集与 Rust 建图输入。[onProgress] 报 0..1。
Future<PanoramaAtlas> buildPanoramaAtlas(
  PanoramaLibrary library, {
  required List<PanoramaFontSet> fonts,
  PanoramaAtlasSpec spec = PanoramaAtlasSpec.desktop,
  void Function(double progress)? onProgress,
  int seed = 1,
}) async {
  final List<PanoramaFontSet> sets = fonts.isEmpty
      ? const <PanoramaFontSet>[PanoramaFontSet(null)]
      : fonts;
  final List<_CellJob> jobs = <_CellJob>[];
  final List<double> aspects = <double>[];
  final List<double> hues = <double>[];
  final List<_CoverJob> coverJobs = <_CoverJob>[];

  // 1. 封面缩略图（并发解码，控制在 6 路）。
  final int n = library.works.length;
  final double thumbPx = spec.thumbPxFor(n);
  final List<({ui.Image image, double aspect})?> thumbs =
      List<({ui.Image image, double aspect})?>.filled(n, null);
  int next = 0;
  int done = 0;
  Future<void> worker() async {
    while (next < n) {
      final int i = next++;
      thumbs[i] = await _decodeThumb(library.works[i].coverPath, thumbPx);
      done++;
      onProgress?.call(0.6 * done / math.max(1, n));
    }
  }

  await Future.wait(<Future<void>>[for (int k = 0; k < 6; k++) worker()]);
  for (int i = 0; i < n; i++) {
    final PanoramaWork w = library.works[i];
    final double aspect = thumbs[i]?.aspect ?? 0.7;
    final Size cover = Size(
      thumbPx * math.sqrt(aspect),
      thumbPx / math.sqrt(aspect),
    );
    final Size framed = panoramaFramedSize(cover);
    final double hue = panoramaWorkHue(w, i);
    aspects.add(aspect);
    hues.add(hue);
    final _CoverJob job = _CoverJob(
      framed.width.ceilToDouble(),
      framed.height.ceilToDouble(),
      cover,
      thumbs[i]?.image,
      panoramaAccent(hue),
      w.title,
    );
    coverJobs.add(job);
    jobs.add(job);
  }

  // 2. 字形：先定每个词的字体套，超出上限时合并套数。
  List<int> fontOfWord(int setCount) => <int>[
    for (final PanoramaWord w in library.words) _fontOf(w.text, setCount),
  ];
  int setCount = sets.length;
  List<int> wordFont = fontOfWord(setCount);
  int uniqueCount(List<int> wf) {
    final Set<int> keys = <int>{};
    for (int i = 0; i < library.words.length; i++) {
      for (final int r in library.words[i].text.runes) {
        keys.add(wf[i] << 21 | r);
      }
    }
    return keys.length;
  }

  while (setCount > 1 && uniqueCount(wordFont) > spec.maxGlyphs) {
    setCount--;
    wordFont = fontOfWord(setCount);
  }

  final Map<int, int> glyphIndex = <int, int>{}; // (font<<21|rune) → 唯一字形下标
  final List<({int font, int rune})> uniques = <({int font, int rune})>[];
  final List<int> keptWords = <int>[];
  for (int i = 0; i < library.words.length; i++) {
    final List<int> runes = <int>[
      for (final int r in library.words[i].text.runes)
        if (r > 0x20) r,
    ];
    if (runes.isEmpty) continue;
    final int newOnes = runes
        .where((int r) => !glyphIndex.containsKey(wordFont[i] << 21 | r))
        .toSet()
        .length;
    if (uniques.length + newOnes > spec.maxGlyphs) continue;
    for (final int r in runes) {
      glyphIndex.putIfAbsent(wordFont[i] << 21 | r, () {
        uniques.add((font: wordFont[i], rune: r));
        return uniques.length - 1;
      });
    }
    keptWords.add(i);
  }

  final double em = spec.emPx;
  final double stroke = em * 0.17;
  final List<double> advances = <double>[];
  final List<_GlyphJob> glyphJobs = <_GlyphJob>[]; // 每唯一字形 3 个：细 / 字心 / 描边
  TextStyle styleFor(PanoramaFontSet s, FontWeight weight) => TextStyle(
    fontFamily: s.family,
    fontFamilyFallback: s.fallback.isEmpty ? null : s.fallback,
    fontSize: em,
    fontWeight: weight,
    // 可变字体只认 wght 轴：同时给，静态字体忽略它。
    fontVariations: <FontVariation>[
      FontVariation.weight(weight.value.toDouble()),
    ],
    height: 1.15,
    color: Colors.white,
  );
  for (int u = 0; u < uniques.length; u++) {
    final PanoramaFontSet s = sets[uniques[u].font];
    final String ch = String.fromCharCode(uniques[u].rune);
    TextPainter make(TextStyle style) => TextPainter(
      text: TextSpan(text: ch, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final TextPainter thin = make(styleFor(s, FontWeight.w300));
    final TextPainter fill = make(styleFor(s, FontWeight.w800));
    final TextPainter outline = make(
      styleFor(s, FontWeight.w800).copyWith(
        color: null,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 2
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white,
      ),
    );
    final double cw = (math.max(thin.width, fill.width) + 4).ceilToDouble();
    final double ch2 = (math.max(thin.height, fill.height) + 2).ceilToDouble();
    advances.add(fill.width / em);
    glyphJobs
      ..add(_GlyphJob(cw, ch2, thin))
      ..add(_GlyphJob(cw, ch2, fill))
      ..add(
        _GlyphJob(
          (cw + stroke * 2).ceilToDouble(),
          (ch2 + stroke * 2).ceilToDouble(),
          outline,
        ),
      );
    if (u % 300 == 299) {
      onProgress?.call(0.6 + 0.25 * u / uniques.length);
      await Future<void>.delayed(Duration.zero);
    }
  }
  jobs.addAll(glyphJobs);

  // 3. 装箱 + 绘制各页。
  final List<int> pageHeights = <int>[];
  _pack(jobs, spec.pageSize, pageHeights);
  final List<ui.Image> pages = <ui.Image>[];
  for (int p = 0; p < pageHeights.length; p++) {
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas canvas = Canvas(rec);
    for (final _CellJob j in jobs) {
      if (j.page == p) j.paint(canvas);
    }
    final ui.Picture pic = rec.endRecording();
    pages.add(await pic.toImage(spec.pageSize, math.max(1, pageHeights[p])));
    pic.dispose();
    onProgress?.call(0.85 + 0.15 * (p + 1) / pageHeights.length);
  }
  for (final ({ui.Image image, double aspect})? t in thumbs) {
    t?.image.dispose();
  }
  for (final _GlyphJob g in glyphJobs) {
    g.painter.dispose();
  }

  // 4. Rust 建图输入。格子顺序：先作品，再字形（每字形 3 格）。
  final int cellCount = coverJobs.length + glyphJobs.length;
  final Float32List rects = Float32List(cellCount * 4);
  final Int32List cellPages = Int32List(cellCount);
  void putCell(int c, _CellJob j) {
    rects
      ..[c * 4] = j.x
      ..[c * 4 + 1] = j.y
      ..[c * 4 + 2] = j.w
      ..[c * 4 + 3] = j.h;
    cellPages[c] = j.page;
  }

  final Float32List workParams = Float32List(n * 3);
  final Int32List workCells = Int32List(n);
  for (int i = 0; i < n; i++) {
    putCell(i, coverJobs[i]);
    workParams
      ..[i * 3] = aspects[i]
      ..[i * 3 + 1] = coverJobs[i].cover.width
      ..[i * 3 + 2] = hues[i];
    workCells[i] = i;
  }
  for (int g = 0; g < glyphJobs.length; g++) {
    putCell(n + g, glyphJobs[g]);
  }
  final List<int> glyphRefs = <int>[];
  final Int32List words = Int32List(keptWords.length * 3);
  for (int k = 0; k < keptWords.length; k++) {
    final int i = keptWords[k];
    final int start = glyphRefs.length;
    for (final int r in library.words[i].text.runes) {
      if (r <= 0x20) continue;
      glyphRefs.add(glyphIndex[wordFont[i] << 21 | r]!);
    }
    words
      ..[k * 3] = library.words[i].work
      ..[k * 3 + 1] = start
      ..[k * 3 + 2] = glyphRefs.length - start;
  }
  final Int32List glyphCells = Int32List(glyphRefs.length * 3);
  final Float32List glyphAdv = Float32List(glyphRefs.length);
  for (int g = 0; g < glyphRefs.length; g++) {
    final int u = glyphRefs[g];
    glyphCells
      ..[g * 3] = n + u * 3
      ..[g * 3 + 1] = n + u * 3 + 1
      ..[g * 3 + 2] = n + u * 3 + 2;
    glyphAdv[g] = advances[u];
  }
  return PanoramaAtlas._(
    pages: pages,
    aspects: aspects,
    hues: hues,
    scene: FfcPanoScene(
      cellRects: rects,
      cellPages: cellPages,
      workParams: workParams,
      workCells: workCells,
      words: words,
      glyphCells: glyphCells,
      glyphAdvances: glyphAdv,
      glyphEmPx: em,
      seed: seed,
    ),
  );
}

/// 一部作品的高清带框封面（含辉光留边），尺寸按 [cover]（封面本体逻辑像素）× [pixelRatio]。
/// 返回图与其中封面本体的位置（相对整张，逻辑像素）。
Future<ui.Image> renderPanoramaHiResCover(
  PanoramaWork work, {
  required Size cover,
  required double hue,
  required double pixelRatio,
}) async {
  final double areaPx = math.sqrt(cover.width * cover.height) * pixelRatio;
  final ({ui.Image image, double aspect})? src = await _decodeThumb(
    work.coverPath,
    areaPx,
  );
  final Size framed = panoramaFramedSize(cover);
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec)..scale(pixelRatio);
  final double pad = (framed.width - cover.width) / 2;
  paintPanoramaFramedCover(
    canvas,
    Rect.fromLTWH(pad, pad, cover.width, cover.height),
    src?.image,
    panoramaAccent(hue),
    title: work.title,
  );
  final ui.Picture pic = rec.endRecording();
  final ui.Image out = await pic.toImage(
    (framed.width * pixelRatio).ceil(),
    (framed.height * pixelRatio).ceil(),
  );
  pic.dispose();
  src?.image.dispose();
  return out;
}
