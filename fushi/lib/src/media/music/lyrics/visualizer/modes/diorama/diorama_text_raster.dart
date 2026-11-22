/// 镜台的歌词栅格（folia `dioramaTextRaster.ts` / `dioramaLineRasterCache.ts`）：
///
/// - 整行图：邻行用，一行一张白字图，按材质颜色染色画成一块平面。
/// - 当前行逐单元图集：每个 CJK 字 / 每个词单独排版画进一张图集（互不相邻，留足模糊边距），
///   位置取自整行排版（`getBoxesForRange`，保留字距与换行）；再出一张同布局的模糊图集作辉光。
///
/// 只在一行第一次需要时栅格化一次，逐帧只改染色 / 透明度 / 变换。超长的行先按画面宽度折行
/// （folia 单行不折，窄屏上会出画；这里保证窄屏也能读）。
///
/// 两种产物：Canvas 后备实现要 `toImageSync` 的 [ui.Image]；Flutter GPU 渲染器要 GPU 纹理，
/// 走异步 `Picture.toImage` 再 `gpu.Texture.fromImage` 零拷贝包一层（`toImageSync` 的图在光栅
/// 线程上懒生成，未必已有纹理，fromImage 会拒绝）。异步期间这一行不画——邻行在雾里提前栅格化，
/// 当前行的逐单元图集也随下一行一起预热，正常播放里看不到这一两帧的空档。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_sequencer.dart';

/// 一个单元在图集里的位置与在整行排版里的位置。
class DioramaPlacedUnit {
  const DioramaPlacedUnit({
    required this.atlasRect,
    required this.atlasCenter,
    required this.layoutCenter,
    required this.height,
  });

  /// 图集里的源矩形（含模糊边距）。
  final Rect atlasRect;

  /// 源矩形里对应单元排版中心的点。
  final Offset atlasCenter;

  /// 单元中心相对整行排版中心的偏移（栅格像素，y 向下）。
  final Offset layoutCenter;

  /// 单元高度（栅格像素）。
  final double height;
}

/// 一行的栅格。
class DioramaLineRaster {
  DioramaLineRaster._({
    required this.fontPx,
    required this.width,
    required this.height,
    required this.lineSize,
    required this.pad,
    required this.units,
    required this.atlasSize,
  });

  /// 一个 em 的栅格像素（对应世界里的 `dioramaLineFontSize`）。
  final double fontPx;

  /// 排版宽高（栅格像素，不含边距）。
  final double width;
  final double height;

  /// 整行白字图的像素尺寸（四周留 [pad]）。
  final Size lineSize;
  final double pad;

  /// 当前行逐单元（与 [DioramaSceneLine.units] 一一对应；排不出的为 null）。
  final List<DioramaPlacedUnit?> units;

  /// 逐单元图集与辉光图集的像素尺寸（两张同尺寸；没有逐单元时为 null）。
  final Size? atlasSize;

  /// Canvas 后备实现用的图（GPU 模式下为 null）。
  ui.Image? lineImage;
  ui.Image? unitAtlas;
  ui.Image? glowAtlas;

  /// GPU 模式的纹理（异步就绪；就绪前为 null）。
  gpu.Texture? lineTexture;
  gpu.Texture? unitTexture;
  gpu.Texture? glowTexture;

  /// GPU 纹理背后的图：纹理零拷贝共享它的存储，图要活得和纹理一样久。
  final List<ui.Image> _gpuImages = <ui.Image>[];

  bool _disposed = false;

  /// 某一层的 GPU 纹理（没就绪 / 没有这层时为 null）。
  gpu.Texture? gpuTexture(bool glow, bool units) =>
      glow ? glowTexture : (units ? unitTexture : lineTexture);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    lineImage?.dispose();
    unitAtlas?.dispose();
    glowAtlas?.dispose();
    lineTexture = null;
    unitTexture = null;
    glowTexture = null;
    for (final ui.Image i in _gpuImages) {
      i.dispose();
    }
    _gpuImages.clear();
  }

  /// 异步把 [pic] 变成 GPU 纹理交给 [assign]；栅格先被丢弃了就直接释放。
  void _realizeGpu(
    ui.Picture pic,
    int w,
    int h,
    void Function(gpu.Texture texture) assign,
  ) {
    pic.toImage(w, h).then((ui.Image img) {
      pic.dispose();
      if (_disposed) {
        img.dispose();
        return;
      }
      _gpuImages.add(img);
      assign(gpu.Texture.fromImage(gpu.gpuContext, img));
    });
  }

  static const double _maxImageSide = 4000;

  static TextStyle _style(double fontPx) => TextStyle(
    fontSize: fontPx,
    fontWeight: FontWeight.w700,
    height: 1.15,
    color: const Color(0xFFFFFFFF),
  );

  static TextPainter _layout(String text, double fontPx, double maxWidthPx) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: _style(fontPx)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      textWidthBasis: TextWidthBasis.longestLine,
    );
    tp.layout(maxWidth: maxWidthPx);
    return tp;
  }

  /// 栅格化一行。[wrapEm] = 折行宽度（em）；[withUnits] = 同时出逐单元图集（当前行用）；
  /// [forGpu] = 产出 GPU 纹理（异步）而不是 Canvas 用的同步图。
  static DioramaLineRaster build(
    DioramaSceneLine line, {
    required double fontPx,
    required double wrapEm,
    required bool withUnits,
    bool forGpu = false,
  }) {
    double px = fontPx;
    TextPainter tp = _layout(line.layoutText, px, wrapEm * px);
    // 图太大就整体降分辨率（贴图边长上限）。
    final double longest = math.max(tp.width, tp.height) + px * 0.5;
    if (longest > _maxImageSide) {
      tp.dispose();
      px = px * _maxImageSide / longest;
      tp = _layout(line.layoutText, px, wrapEm * px);
    }
    final double pad = (px * 0.25).ceilToDouble();
    final double w = tp.width;
    final double h = tp.height;

    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas c = Canvas(rec);
    tp.paint(c, Offset(pad, pad));
    final ui.Picture linePic = rec.endRecording();
    final int lineW = math.max(1, (w + pad * 2).ceil());
    final int lineH = math.max(1, (h + pad * 2).ceil());

    final List<DioramaPlacedUnit?> placed = <DioramaPlacedUnit?>[];
    ui.Picture? unitPic;
    ui.Picture? glowPic;
    int aw = 0;
    int ah = 0;
    if (withUnits && line.units.isNotEmpty) {
      final double sigma = px * 0.14;
      final double gpad = (sigma * 3 + px * 0.06).ceilToDouble();
      final ui.PictureRecorder arec = ui.PictureRecorder();
      final Canvas ac = Canvas(arec);
      // 货架式装箱：一排最宽 2048，单元之间隔开两倍模糊边距，辉光不会串到邻字。
      const double shelfMax = 2048;
      double cursorX = 0;
      double cursorY = 0;
      double shelfH = 0;
      double atlasW = 1;
      for (final DioramaUnit u in line.units) {
        final List<TextBox> boxes = tp.getBoxesForSelection(
          TextSelection(baseOffset: u.charStart, extentOffset: u.charEnd),
        );
        if (boxes.isEmpty) {
          placed.add(null);
          continue;
        }
        Rect box = boxes.first.toRect();
        for (final TextBox b in boxes.skip(1)) {
          box = box.expandToInclude(b.toRect());
        }
        final TextPainter up = _layout(u.text, px, double.infinity);
        final double cellW = up.width + gpad * 2;
        final double cellH = up.height + gpad * 2;
        if (cursorX > 0 && cursorX + cellW > shelfMax) {
          cursorX = 0;
          cursorY += shelfH;
          shelfH = 0;
        }
        up.paint(ac, Offset(cursorX + gpad, cursorY + gpad));
        final Rect rect = Rect.fromLTWH(cursorX, cursorY, cellW, cellH);
        placed.add(
          DioramaPlacedUnit(
            atlasRect: rect,
            atlasCenter: rect.center,
            layoutCenter: Offset(box.center.dx - w / 2, box.center.dy - h / 2),
            height: box.height,
          ),
        );
        up.dispose();
        cursorX += cellW;
        shelfH = math.max(shelfH, cellH);
        atlasW = math.max(atlasW, cursorX);
      }
      final ui.Picture apic = arec.endRecording();
      aw = math.max(1, atlasW.ceil());
      ah = math.max(1, (cursorY + shelfH).ceil());
      final ui.PictureRecorder grec = ui.PictureRecorder();
      final Canvas gc = Canvas(grec);
      gc.saveLayer(
        Rect.fromLTWH(0, 0, aw.toDouble(), ah.toDouble()),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      gc.drawPicture(apic);
      gc.restore();
      unitPic = apic;
      glowPic = grec.endRecording();
    }
    tp.dispose();
    final DioramaLineRaster r = DioramaLineRaster._(
      fontPx: px,
      width: w,
      height: h,
      lineSize: Size(lineW.toDouble(), lineH.toDouble()),
      pad: pad,
      units: placed,
      atlasSize: unitPic == null ? null : Size(aw.toDouble(), ah.toDouble()),
    );
    if (forGpu) {
      r._realizeGpu(linePic, lineW, lineH, (gpu.Texture t) {
        r.lineTexture = t;
      });
      if (unitPic != null && glowPic != null) {
        r._realizeGpu(unitPic, aw, ah, (gpu.Texture t) {
          r.unitTexture = t;
        });
        r._realizeGpu(glowPic, aw, ah, (gpu.Texture t) {
          r.glowTexture = t;
        });
      }
    } else {
      r.lineImage = linePic.toImageSync(lineW, lineH);
      linePic.dispose();
      if (unitPic != null && glowPic != null) {
        r.unitAtlas = unitPic.toImageSync(aw, ah);
        r.glowAtlas = glowPic.toImageSync(aw, ah);
        unitPic.dispose();
        glowPic.dispose();
      }
    }
    return r;
  }
}

/// 生成点精灵：对比层是近乎不透明的软边圆（folia 片元 `1 - smoothstep(0.14, 0.48, r)`），
/// 辉光层是宽而软的光晕（`pow(1 - 2r, 1.7)`）。
ui.Image buildDioramaSprite({required bool glow, int size = 64}) {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas c = Canvas(rec);
  final double r = size / 2;
  const int n = 12;
  final List<Color> colors = <Color>[];
  final List<double> stops = <double>[];
  for (int i = 0; i <= n; i++) {
    final double t = i / n; // 0..1 → 半径 0..0.5（点坐标）
    final double pr = t * 0.5;
    double a;
    if (glow) {
      a = math.pow((1 - pr * 2).clamp(0.0, 1.0), 1.7).toDouble();
    } else {
      final double s = ((pr - 0.14) / (0.48 - 0.14)).clamp(0.0, 1.0);
      a = 1 - s * s * (3 - 2 * s);
    }
    colors.add(Color.from(alpha: a, red: 1, green: 1, blue: 1));
    stops.add(t);
  }
  c.drawCircle(
    Offset(r, r),
    r,
    Paint()..shader = ui.Gradient.radial(Offset(r, r), r, colors, stops),
  );
  final ui.Picture pic = rec.endRecording();
  final ui.Image img = pic.toImageSync(size, size);
  pic.dispose();
  return img;
}
