import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';

const int _w = 200;
const int _h = 240;
const double _cx = 100;
const double _cy = 120;
const double _halfThick = 12;
const double _halfLength = 80;

/// 概率图上画一条绕 (_cx,_cy) 旋转 [tilt]（正值顺时针）的竖列。
Float32List _tiltedColumn(double tilt, {double halfLength = _halfLength}) {
  final Float32List prob = Float32List(_w * _h);
  final double c = math.cos(tilt), s = math.sin(tilt);
  for (int y = 0; y < _h; y++) {
    for (int x = 0; x < _w; x++) {
      final double dx = x + 0.5 - _cx, dy = y + 0.5 - _cy;
      // 逆旋转回列的局部坐标：u 横穿列、v 沿列。
      final double u = dx * c + dy * s;
      final double v = -dx * s + dy * c;
      if (u.abs() <= _halfThick && v.abs() <= halfLength) {
        prob[y * _w + x] = 0.9;
      }
    }
  }
  return prob;
}

/// 页面点在真实斜列局部坐标系里的横向偏离（0 = 正落在列中线上）。
double _offAxis(MokuroPoint p, double tilt) =>
    (p.dx - _cx) * math.cos(tilt) + (p.dy - _cy) * math.sin(tilt);

List<MangaOcrTextRegion> _overlayRegions(OcrBlock block) {
  final MokuroPayload payload = buildMangaPayloadFromResults(
    <MangaOcrPageFile>[
      MangaOcrPageFile(file: File('unused.png'), relativeUrl: 'p.png'),
    ],
    <OcrPageResult>[
      OcrPageResult(
        pageIndex: 0,
        imageWidth: _w,
        imageHeight: _h,
        blocks: <OcrBlock>[block],
      ),
    ],
  );
  return mangaEffectiveTextRegions(payload.images.single.blocks.single);
}

void main() {
  const double tilt = -20 * math.pi / 180;

  group('检测器主轴角', () {
    test('斜 20° 的竖列：行倾角与块倾角都还原出 -20°', () {
      final List<PpTextLine> lines = ppDetPostprocess(
        _tiltedColumn(tilt),
        _w,
        _h,
      );
      expect(lines, hasLength(1));
      expect(lines.single.vertical, isTrue);
      expect(lines.single.tilt, closeTo(tilt, 1 * math.pi / 180));
      expect(ppBlockTilt(lines), closeTo(tilt, 1 * math.pi / 180));
    });

    test('正立竖列：块倾角恰为 0（保证正常页面输出不变）', () {
      final List<PpTextLine> lines = ppDetPostprocess(_tiltedColumn(0), _w, _h);
      expect(ppBlockTilt(lines), 0);
    });

    test('只斜 2° 的长列（约 8 字）照样转：两端漂移已超行厚 10%', () {
      const double slight = 2 * math.pi / 180;
      final List<PpTextLine> lines = ppDetPostprocess(
        _tiltedColumn(slight, halfLength: 100),
        _w,
        _h,
      );
      expect(ppBlockTilt(lines), closeTo(slight, 0.5 * math.pi / 180));
    });

    test('斜 3° 的短列（3 字）当正立：两端漂移不到行厚 10%', () {
      final List<PpTextLine> lines = ppDetPostprocess(
        _tiltedColumn(3 * math.pi / 180, halfLength: 36),
        _w,
        _h,
      );
      expect(lines.single.elongation, greaterThan(kPpTiltMinElongation));
      expect(ppBlockTilt(lines), 0);
    });

    test('可忽略判据看漂移量不看角度：同样 3°，短列忽略、长列不忽略', () {
      const double three = 3 * math.pi / 180;
      expect(mokuroTiltIsNegligible(3 * 24, 24, three), isTrue);
      expect(mokuroTiltIsNegligible(20 * 24, 24, three), isFalse);
      // 长列只斜 1.5° 也要转（20 字两端偏 0.26 字宽）。
      expect(mokuroTiltIsNegligible(20 * 24, 24, 1.5 * math.pi / 180), isFalse);
    });

    test('近方块的连通域（单字）不参与估角', () {
      const PpTextLine square = PpTextLine(
        rect: OcrRect(left: 0, top: 0, right: 10, bottom: 10),
        score: 1,
        axisAngle: 0.5,
        elongation: 1.2,
        pixelCount: 100,
      );
      expect(ppBlockTilt(const <PpTextLine>[square]), 0);
    });

    test('两轴缩放比不同时主轴角按缩放后的方向重算', () {
      const PpTextLine diagonal = PpTextLine(
        rect: OcrRect(left: 0, top: 0, right: 10, bottom: 10),
        score: 1,
        axisAngle: math.pi / 4,
      );
      // x 拉长 2 倍：45° 的斜线变成 atan(1/2)。
      expect(diagonal.scaled(2, 1).axisAngle, closeTo(math.atan(0.5), 1e-9));
    });
  });

  group('倾斜行四边形', () {
    test('mangaTiltedLineQuad 与 mokuroOrientedRectFromQuad 互逆、外接框不变', () {
      const OcrRect box = OcrRect(left: 50, top: 30, right: 150, bottom: 210);
      final List<List<double>> quad = mangaTiltedLineQuad(box, tilt);
      final MokuroOrientedRect oriented = mokuroOrientedRectFromQuad(quad)!;
      expect(oriented.rotation, closeTo(tilt, 1e-9));
      final MokuroRect bounds = oriented.bounds;
      expect(bounds.left, closeTo(box.left, 1e-6));
      expect(bounds.top, closeTo(box.top, 1e-6));
      expect(bounds.right, closeTo(box.right, 1e-6));
      expect(bounds.bottom, closeTo(box.bottom, 1e-6));
      expect(oriented.height, greaterThan(oriented.width));
    });

    test('倾角 0 / 病态框退回轴对齐四角', () {
      const OcrRect box = OcrRect(left: 0, top: 0, right: 40, bottom: 40);
      final List<List<double>> axis = <List<double>>[
        <double>[0, 0],
        <double>[40, 0],
        <double>[40, 40],
        <double>[0, 40],
      ];
      expect(mangaTiltedLineQuad(box, 0), axis);
      // 正方外接框按 40° 反解，边长非正 → 不硬造旋转矩形。
      expect(mangaTiltedLineQuad(box, 40 * math.pi / 180), axis);
    });

    test('顶点顺序无关：逆时针、从别的角起拟合出同一倾角', () {
      final List<List<double>> quad = mangaTiltedLineQuad(
        const OcrRect(left: 0, top: 0, right: 80, bottom: 200),
        tilt,
      );
      final List<List<double>> reversed = <List<double>>[
        quad[2],
        quad[1],
        quad[0],
        quad[3],
      ];
      expect(
        mokuroOrientedRectFromQuad(reversed)!.rotation,
        closeTo(tilt, 1e-9),
      );
    });

    test('梯形不是矩形 → null，覆盖层退回外接框', () {
      expect(
        mokuroOrientedRectFromQuad(<List<double>>[
          <double>[0, 0],
          <double>[100, 0],
          <double>[70, 50],
          <double>[30, 50],
        ]),
        isNull,
      );
    });

    test('OcrBlock 缓存 JSON 往返保留 lineTilt，正立块不写该字段', () {
      final OcrBlock tilted = OcrBlock(
        box: const OcrRect(left: 0, top: 0, right: 10, bottom: 10),
        vertical: true,
        lines: const <String>['あ'],
        lineBoxes: const <OcrRect>[
          OcrRect(left: 0, top: 0, right: 10, bottom: 10),
        ],
        lineTilt: tilt,
      );
      expect(OcrBlock.fromJson(tilted.toJson()).lineTilt, tilt);
      const OcrBlock upright = OcrBlock(
        box: OcrRect(left: 0, top: 0, right: 10, bottom: 10),
        vertical: true,
        lines: <String>['あ'],
        lineBoxes: <OcrRect>[OcrRect(left: 0, top: 0, right: 10, bottom: 10)],
      );
      expect(upright.toJson().containsKey('lineTilt'), isFalse);
    });
  });

  group('覆盖层逐字格沿斜列排布', () {
    // 检测 → 块倾角 → manga.json 四边形 → 覆盖层字格，整条链路。
    final List<PpTextLine> lines = ppDetPostprocess(
      _tiltedColumn(tilt),
      _w,
      _h,
    );
    const String text = '布多めのにしたけど';

    OcrBlock block(double lineTilt) => OcrBlock(
      box: lines.single.rect,
      vertical: true,
      lines: const <String>[text],
      lineBoxes: <OcrRect>[lines.single.rect],
      lineTilt: lineTilt,
    );

    test('每个字格中心都落在真实斜列里，并带上列的旋转', () {
      final List<MangaOcrTextRegion> regions = _overlayRegions(
        block(ppBlockTilt(lines)),
      );
      expect(regions, hasLength(text.length));
      for (final MangaOcrTextRegion region in regions) {
        expect(
          _offAxis(region.rectangle.center, tilt).abs(),
          lessThan(_halfThick / 2),
        );
        expect(region.rotation, closeTo(tilt, 1 * math.pi / 180));
      }
      // 阅读序自上而下：中心 y 单调递增。
      for (int i = 1; i < regions.length; i++) {
        expect(
          regions[i].rectangle.center.dy,
          greaterThan(regions[i - 1].rectangle.center.dy),
        );
      }
    });

    test('对照：丢掉倾角时首尾字格落在列外（修复前的症状）', () {
      final List<MangaOcrTextRegion> regions = _overlayRegions(block(0));
      expect(
        _offAxis(regions.first.rectangle.center, tilt).abs(),
        greaterThan(_halfThick),
      );
      expect(
        _offAxis(regions.last.rectangle.center, tilt).abs(),
        greaterThan(_halfThick),
      );
    });

    test('HTML 给斜列字格写 rotate 变换，正立块不写', () {
      final MokuroPayload payload = buildMangaPayloadFromResults(
        <MangaOcrPageFile>[
          MangaOcrPageFile(file: File('unused.png'), relativeUrl: 'p.png'),
        ],
        <OcrPageResult>[
          OcrPageResult(
            pageIndex: 0,
            imageWidth: _w,
            imageHeight: _h,
            blocks: <OcrBlock>[block(ppBlockTilt(lines))],
          ),
        ],
      );
      final String tiltedHtml = mangaOcrBoxesHtml(payload.images.single);
      expect(
        RegExp(
          r'transform:rotate\(-(19|20|21)(\.\d+)?deg\)',
        ).allMatches(tiltedHtml).length,
        text.length,
      );
      final MokuroPayload uprightPayload = buildMangaPayloadFromResults(
        <MangaOcrPageFile>[
          MangaOcrPageFile(file: File('unused.png'), relativeUrl: 'p.png'),
        ],
        <OcrPageResult>[
          OcrPageResult(
            pageIndex: 0,
            imageWidth: _w,
            imageHeight: _h,
            blocks: <OcrBlock>[block(0)],
          ),
        ],
      );
      expect(
        mangaOcrBoxesHtml(uprightPayload.images.single),
        isNot(contains('transform:rotate')),
      );
    });
  });
}
