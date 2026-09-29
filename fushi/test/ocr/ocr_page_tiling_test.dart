import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/ocr_page_tiling.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// BUG-2767：行级 OCR 的切片规划与跨片合并。
///
/// 拼接用例的坐标与文字取自 macOS 27 上 `RecognizeDocumentsRequest` 对真实
/// 日漫页的逐片输出（非手捏），合并结果对照的是同页 Google Lens 的读法。
OcrRect ltrb(double left, double top, double right, double bottom) =>
    OcrRect(left: left, top: top, right: right, bottom: bottom);

OcrTextLine line(String text, OcrRect rect, [int? tile]) =>
    OcrTextLine(text: text, rect: rect, tile: tile);

List<List<double>> edges(List<OcrRect> tiles) => <List<double>>[
      for (final OcrRect t in tiles) <double>[t.left, t.top, t.right, t.bottom],
    ];

void main() {
  group('planOcrPageTiles', () {
    test('普通漫画单页只按行切三片，相邻片带重叠', () {
      expect(edges(planOcrPageTiles(1370, 2000)), <List<double>>[
        <double>[0, 0, 1370, 734],
        <double>[0, 600, 1370, 1400],
        <double>[0, 1266, 1370, 2000],
      ]);
    });

    test('一片装得下的小图返回空：表示整页识别，不是没东西可认', () {
      expect(planOcrPageTiles(700, 760), isEmpty);
      expect(planOcrPageTiles(0, 2000), isEmpty);
    });

    test('跨页大图才会被竖着切', () {
      final List<OcrRect> tiles = planOcrPageTiles(2740, 2000);
      expect(tiles, hasLength(6));
      expect(tiles.map((OcrRect t) => t.left).toSet(), hasLength(2));
    });

    test('条漫长图按上限封顶，片覆盖整页且首尾贴边', () {
      final List<OcrRect> tiles = planOcrPageTiles(800, 30000);
      expect(tiles, hasLength(kOcrMaxTiles));
      expect(tiles.first.top, 0);
      expect(tiles.last.bottom, 30000);
      for (int i = 1; i < tiles.length; i++) {
        expect(tiles[i].top, lessThan(tiles[i - 1].bottom),
            reason: '第 $i 片与上一片之间必须有重叠');
      }
    });

    test('重叠至少容得下一个字（下限像素）', () {
      final List<OcrRect> tiles =
          planOcrPageTiles(400, 1600, targetTileHeight: 300);
      for (int i = 1; i < tiles.length; i++) {
        expect(tiles[i - 1].bottom - tiles[i].top,
            greaterThanOrEqualTo(2 * kOcrTileMinOverlap - 1));
      }
    });
  });

  group('mergeTiledOcrLines', () {
    test('没切片的结果原样返回（平台忽略切片请求时的恒等退路）', () {
      final List<OcrTextLine> lines = <OcrTextLine>[
        line('あ', ltrb(0, 0, 10, 10)),
        line('あ', ltrb(0, 0, 10, 10)),
      ];
      expect(mergeTiledOcrLines(lines, const <OcrRect>[]), same(lines));
      expect(
          mergeTiledOcrLines(lines, planOcrPageTiles(1370, 2000)), same(lines));
    });

    test('跨切线的竖列：两截按文字重叠精确拼回（真实输出 c2 p4）', () {
      final List<OcrRect> tiles = <OcrRect>[
        ltrb(0, 0, 1115, 587),
        ltrb(0, 480, 1115, 1120),
        ltrb(0, 1013, 1115, 1600),
      ];
      final List<OcrTextLine> merged = mergeTiledOcrLines(<OcrTextLine>[
        line('ということは貴女', ltrb(353.7, 273.5, 383.7, 537.1), 0),
        line('繰り返しているという', ltrb(213.8, 273.5, 245.8, 583.0), 0),
        line('というの！？', ltrb(211.8, 480.0, 243.8, 646.0), 1),
      ], tiles);
      expect(merged.map((OcrTextLine l) => l.text), <String>[
        'ということは貴女',
        '繰り返しているというの！？',
      ]);
      final OcrRect column = merged.last.rect;
      expect(column.top, 273.5);
      expect(column.bottom, 646.0);
      // 相邻而不相关的列（左右隔开）不许被拼进来。
      expect(column.left, closeTo(211.8, 0.01));
      expect(column.right, closeTo(245.8, 0.01));
    });

    test('切边上的半个字被读错也能对齐，三片接成一列（真实输出 c1 p1）', () {
      final List<OcrRect> tiles = <OcrRect>[
        ltrb(0, 0, 1403, 751),
        ltrb(0, 614, 1403, 1434),
        ltrb(0, 1297, 1403, 2048),
      ];
      final List<OcrTextLine> merged = mergeTiledOcrLines(<OcrTextLine>[
        // 切边 751 上的「サ」只剩半个，Vision 读成了「：」。
        line('★ユニバー：', ltrb(69.3, 584.1, 104.0, 749.0), 0),
        line('ユニバーサル・スタジオ・ジャパンにて『ワンピース・プレミ', ltrb(69.3, 614.0, 106.0, 1432.0),
            1),
        line('ス・プレミア・サマーツ』7月30日（木）開幕！！', ltrb(63.2, 1297.0, 110.1, 1932.0), 2),
      ], tiles);
      expect(merged.single.text,
          '★ユニバーサル・スタジオ・ジャパンにて『ワンピース・プレミア・サマーツ』7月30日（木）開幕！！');
      expect(merged.single.rect.top, 584.1);
      expect(merged.single.rect.bottom, 1932.0);
    });

    test('重叠区里完整读了两遍的行只留一条', () {
      final List<OcrRect> tiles = <OcrRect>[
        ltrb(0, 0, 1000, 700),
        ltrb(0, 560, 1000, 1400),
      ];
      final List<OcrTextLine> merged = mergeTiledOcrLines(<OcrTextLine>[
        line('だよな', ltrb(300, 580, 330, 670), 0),
        line('だよな', ltrb(301, 581, 331, 669), 1),
        line('大丈夫', ltrb(340, 590, 370, 680), 1),
      ], tiles);
      expect(merged.map((OcrTextLine l) => l.text), <String>['だよな', '大丈夫']);
    });

    test('截断的半截让位给另一片里的完整版', () {
      final List<OcrRect> tiles = <OcrRect>[
        ltrb(0, 0, 1000, 700),
        ltrb(0, 560, 1000, 1400),
      ];
      final List<OcrTextLine> merged = mergeTiledOcrLines(<OcrTextLine>[
        // 上片：列从 600 开始，被 700 的切边截断，只读到两个字。
        line('何が', ltrb(500, 600, 530, 698), 0),
        // 下片：整列都在片内，读全了。
        line('何があった', ltrb(500, 600, 530, 760), 1),
      ], tiles);
      expect(merged.single.text, '何があった');
    });

    test('对不上文字时按重叠区中线各取一半，不重复也不丢字', () {
      expect(
        stitchOcrLineText(
          'あいうえお',
          'かきくけこ',
          firstStart: 0,
          firstEnd: 100,
          secondStart: 60,
          secondEnd: 160,
        ),
        // 中线 80：前一截留前 4 个字，后一截丢前 1 个字。
        'あいうえきくけこ',
      );
    });

    test('单字重叠与字距估计吻合时采用', () {
      // 两截只重叠 25px ≈ 一个字：末字「ん」与首字「ん」就是同一个字。
      expect(
        stitchOcrLineText(
          'たくさん',
          'んですか',
          firstStart: 0,
          firstEnd: 100,
          secondStart: 75,
          secondEnd: 175,
        ),
        'たくさんですか',
      );
    });

    test('单字巧合相等但字距估计重叠 3 字：不采用，走中线', () {
      // 重叠 60px ≈ 3 个字，文字却只有末字「お」与首字「お」相等——那是巧合，
      // 照它拼会凭空多出重叠区里的两个字。
      expect(
        stitchOcrLineText(
          'あいうえお',
          'おかきくけ',
          firstStart: 0,
          firstEnd: 100,
          secondStart: 40,
          secondEnd: 140,
        ),
        // 中线 70：前一截留前 4 个字（3.5 四舍五入），后一截丢前 2 个字。
        'あいうえきくけ',
      );
    });
  });
}
