import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_hourly_breakdown.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2622：统计页时段图按 format 分色堆叠。
///
/// 守的核心不是「有几种颜色」，而是**历史数据不得被编造归属**：v67 之前
/// `reading_hourly_logs` 没有 format 列，那些行在写入时身份就丢了，事后没有任何依据
/// 能拆开。把它们算进 EPUB 只是让图好看，代价是给用户看一个假的归属。所以它必须
/// 单独成带、用中性色、并且图例与说明必须显式出现。
void main() {
  const ColorScheme scheme = ColorScheme.light();
  final ThemeData theme = ThemeData(colorScheme: scheme);

  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );

  /// 从渲染树里取出真正喂给画笔的分带数据。断言「画了什么」而不是「传了什么」。
  StatHourlyChartPainter painterOf(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((CustomPaint c) => c.painter)
      .whereType<StatHourlyChartPainter>()
      .single;

  StatHourlyBreakdown breakdownOf(
      List<(String format, int hour, int ms)> rows) {
    final StatHourlyBreakdown b = StatHourlyBreakdown();
    for (final (String format, int hour, int ms) in rows) {
      b.addMs(
        band: StatHourlyFormatBand.ofDbValue(format),
        hour: hour,
        ms: ms,
      );
    }
    return b;
  }

  group('StatHourlyFormatBand.ofDbValue', () {
    test('三个真实写入面各归各带', () {
      expect(StatHourlyFormatBand.ofDbValue(BookFormat.epub.dbValue),
          StatHourlyFormatBand.epub);
      expect(StatHourlyFormatBand.ofDbValue(BookFormat.pdf.dbValue),
          StatHourlyFormatBand.pdf);
      expect(StatHourlyFormatBand.ofDbValue(BookFormat.manga.dbValue),
          StatHourlyFormatBand.manga);
    });

    test('空 format（v67 前的历史行 / 旧端同步差额）归未区分带，不归 EPUB', () {
      expect(StatHourlyFormatBand.ofDbValue(''),
          StatHourlyFormatBand.unattributed);
    });

    test('未知 format 串也归未区分带（不走 parseOrEpub 的宽松回退）', () {
      expect(StatHourlyFormatBand.ofDbValue('srtbook'),
          StatHourlyFormatBand.unattributed);
    });
  });

  group('StatHourlyBreakdown', () {
    test('同 (带, 小时) 的多行累加，不是覆盖', () {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        (BookFormat.epub.dbValue, 9, 1000),
        (BookFormat.epub.dbValue, 9, 2000),
      ]);
      expect(b.valuesOf(StatHourlyFormatBand.epub)[9], 3000);
      expect(b.totalMs, 3000);
    });

    test('越界小时被丢弃，不把图画坏', () {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        (BookFormat.epub.dbValue, 24, 1000),
        (BookFormat.epub.dbValue, -1, 1000),
      ]);
      expect(b.isEmpty, isTrue);
      expect(b.totalMs, 0);
    });

    test('activeBands 只含非零带，按枚举声明序（未区分带排在最后）', () {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        ('', 3, 500),
        (BookFormat.manga.dbValue, 3, 500),
        (BookFormat.epub.dbValue, 3, 500),
      ]);
      expect(b.activeBands, <StatHourlyFormatBand>[
        StatHourlyFormatBand.epub,
        StatHourlyFormatBand.manga,
        StatHourlyFormatBand.unattributed,
      ]);
    });
  });

  group('分色堆叠渲染', () {
    testWidgets('有 format 的数据按类分带渲染，图例列出每一类', (WidgetTester tester) async {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        (BookFormat.epub.dbValue, 9, 600000),
        (BookFormat.pdf.dbValue, 9, 300000),
        (BookFormat.manga.dbValue, 20, 120000),
      ]);
      await tester.pumpWidget(wrap(Builder(
        builder: (BuildContext context) =>
            buildStatHourlyFormatChartSection(context, b),
      )));

      final StatHourlyChartPainter painter = painterOf(tester);
      expect(painter.bands.length, 3);
      expect(painter.bands[0].values[9], 600000);
      expect(painter.bands[0].color, scheme.tertiary);
      expect(painter.bands[1].values[9], 300000);
      expect(painter.bands[1].color, scheme.primary);
      expect(painter.bands[2].values[20], 120000);
      expect(painter.bands[2].color, scheme.secondary);
      // 柱高口径仍是当小时合计，分带没有让总量丢失。
      expect(painter.totalAt(9), 900000);

      expect(find.text(t.stat_hourly_band_epub), findsOneWidget);
      expect(find.text(t.stat_hourly_band_pdf), findsOneWidget);
      expect(find.text(t.stat_hourly_band_manga), findsOneWidget);
      // 全是有身份的数据，不该冒出「未区分历史」这条。
      expect(find.text(t.stat_hourly_band_unattributed), findsNothing);
      expect(find.text(t.stat_hourly_unattributed_note), findsNothing);
    });

    testWidgets('老数据单独成带：不并进 EPUB，图例与说明都标明它分不开', (WidgetTester tester) async {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        (BookFormat.epub.dbValue, 9, 600000),
        ('', 9, 300000),
      ]);
      await tester.pumpWidget(wrap(Builder(
        builder: (BuildContext context) =>
            buildStatHourlyFormatChartSection(context, b),
      )));

      final StatHourlyChartPainter painter = painterOf(tester);
      expect(painter.bands.length, 2);
      // 核心：EPUB 带只拿到自己那 600000，历史那 300000 绝不能被加进来。
      expect(painter.bands[0].values[9], 600000);
      expect(painter.bands[0].color, scheme.tertiary);
      // 未区分带用中性描边色，不是第四个品类色。
      expect(painter.bands[1].values[9], 300000);
      expect(painter.bands[1].color, scheme.outlineVariant);
      expect(painter.bands[1].color, isNot(scheme.tertiary));
      expect(painter.bands[1].color, isNot(scheme.primary));
      expect(painter.bands[1].color, isNot(scheme.secondary));
      expect(painter.totalAt(9), 900000);

      expect(find.text(t.stat_hourly_band_unattributed), findsOneWidget);
      expect(find.text(t.stat_hourly_unattributed_note), findsOneWidget);
    });

    testWidgets('只有老数据时图例仍然出现——中性柱子不能被当成某一类', (WidgetTester tester) async {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        ('', 14, 450000),
      ]);
      await tester.pumpWidget(wrap(Builder(
        builder: (BuildContext context) =>
            buildStatHourlyFormatChartSection(context, b),
      )));

      final StatHourlyChartPainter painter = painterOf(tester);
      expect(painter.bands.length, 1);
      expect(painter.bands.single.color, scheme.outlineVariant);
      expect(find.text(t.stat_hourly_band_unattributed), findsOneWidget);
      expect(find.text(t.stat_hourly_unattributed_note), findsOneWidget);
      expect(find.text(t.stat_hourly_band_epub), findsNothing);
    });

    testWidgets('只有一类真实阅读面时不画只有一项的空图例', (WidgetTester tester) async {
      final StatHourlyBreakdown b = breakdownOf(<(String, int, int)>[
        (BookFormat.epub.dbValue, 8, 60000),
        (BookFormat.epub.dbValue, 9, 120000),
      ]);
      await tester.pumpWidget(wrap(Builder(
        builder: (BuildContext context) =>
            buildStatHourlyFormatChartSection(context, b),
      )));

      final StatHourlyChartPainter painter = painterOf(tester);
      expect(painter.bands.length, 1);
      expect(find.text(t.stat_hourly_band_epub), findsNothing);
      expect(find.text(t.stat_hourly_band_pdf), findsNothing);
      expect(find.text(t.stat_hourly_band_manga), findsNothing);
      expect(find.text(t.stat_hourly_band_unattributed), findsNothing);
      expect(find.text(t.stat_hourly_unattributed_note), findsNothing);
    });

    testWidgets('空数据不炸：无带、无图例、无说明', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(Builder(
        builder: (BuildContext context) =>
            buildStatHourlyFormatChartSection(context, StatHourlyBreakdown()),
      )));

      expect(tester.takeException(), isNull);
      expect(painterOf(tester).bands, isEmpty);
      expect(find.text(t.stat_today_hourly), findsOneWidget);
      expect(find.text(t.stat_hourly_band_epub), findsNothing);
      expect(find.text(t.stat_hourly_unattributed_note), findsNothing);
    });

    testWidgets('视频统计的单色入口仍是一带（观看时长没有阅读面之分）', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(Builder(
        builder: (BuildContext context) => buildStatHourlyChartSection(
          context,
          List<int>.filled(kStatHourlyBuckets, 0)..[5] = 90000,
        ),
      )));

      final StatHourlyChartPainter painter = painterOf(tester);
      expect(painter.bands.length, 1);
      expect(painter.bands.single.color, scheme.tertiary);
      expect(painter.totalAt(5), 90000);
      expect(find.text(t.stat_hourly_band_epub), findsNothing);
      expect(find.text(t.stat_hourly_unattributed_note), findsNothing);
    });
  });

  group('画笔真的堆叠（读回像素）', () {
    // 画布尺寸与画笔内部常量：bottomPadding=20 / leftPadding=32，chartHeight=120。
    const double width = 480;
    const double height = 140;
    const double chartHeight = height - 20;

    /// 第 [hour] 根柱子的水平中心（对齐画笔的 step / barWidth / gap 计算）。
    int barCenterX(int hour) {
      const double step = (width - 32) / kStatHourlyBuckets;
      const double barWidth = step * 0.7;
      const double gap = step * 0.15;
      return (32 + hour * step + gap + barWidth / 2).round();
    }

    Future<ByteData> renderPixels(StatHourlyChartPainter painter) async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(width, height));
      final ui.Image image =
          await recorder.endRecording().toImage(width.toInt(), height.toInt());
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data!;
    }

    Color pixelAt(ByteData data, int x, int y) {
      final int offset = (y * width.toInt() + x) * 4;
      return Color.fromARGB(
        data.getUint8(offset + 3),
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      );
    }

    testWidgets('未区分带画在自己那一截，没有覆盖也没有吞掉真实阅读面那一截', (WidgetTester tester) async {
      // 9 时：EPUB 600000（下 2/3）+ 未区分 300000（上 1/3），全天最高柱 ⇒ 满高。
      final StatHourlyChartPainter painter = StatHourlyChartPainter(
        bands: <StatHourlyBand>[
          StatHourlyBand(
            values: List<int>.filled(kStatHourlyBuckets, 0)..[9] = 600000,
            color: scheme.tertiary,
          ),
          StatHourlyBand(
            values: List<int>.filled(kStatHourlyBuckets, 0)..[9] = 300000,
            color: scheme.outlineVariant,
          ),
        ],
        barRadius: const Radius.circular(4),
        labelColor: scheme.onSurfaceVariant,
        labelStyle: const TextStyle(),
      );
      // dart:ui 的 toImage / toByteData 靠真实事件循环推进，testWidgets 默认的
      // FakeAsync 时钟里它们永远不完成（表现为 10 分钟超时而不是断言失败）。
      final ByteData pixels =
          (await tester.runAsync(() => renderPixels(painter)))!;
      final int x = barCenterX(9);

      // 底部 2/3 是 EPUB 色；顶部 1/3 是未区分的中性色。
      expect(pixelAt(pixels, x, (chartHeight * 0.85).round()), scheme.tertiary);
      expect(pixelAt(pixels, x, (chartHeight * 0.5).round()), scheme.tertiary);
      expect(pixelAt(pixels, x, (chartHeight * 0.15).round()),
          scheme.outlineVariant);
    });
  });
}
