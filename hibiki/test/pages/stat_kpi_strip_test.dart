import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_kpi_strip.dart';

/// TODO-1253 / BUG 守卫：顶部 KPI 概览条在手机窄屏下数字必须完整可见。
///
/// 根因：旧实现把 4 张 KPI 卡片无条件塞进单排 Row，手机窄屏每卡内宽只剩 ~40px，
/// `12.3万` / `123小时45分` 这类多字数值被 ellipsis 截成看不清——「手机看不到数字」。
/// 修复：[StatKpiStrip] 按可用宽度自适应列数，窄屏换行成 2 列，让每卡有足够内宽。
void main() {
  // 逼近真实：全部字数走「万」格式、全部时长可能上百小时（最长的数值）。
  const List<StatKpiItem> items = <StatKpiItem>[
    StatKpiItem(icon: Icons.text_fields, value: '128.6万', label: '字数'),
    StatKpiItem(icon: Icons.schedule, value: '432小时17分', label: '时长'),
    StatKpiItem(icon: Icons.menu_book_outlined, value: '128', label: '书数'),
    StatKpiItem(
        icon: Icons.calendar_today_outlined, value: '365', label: '活跃天数'),
  ];

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      );

  // 收集某文本的 RenderParagraph（用于判断是否被截断）。
  RenderParagraph paragraphOf(WidgetTester tester, String text) {
    final Finder f = find.text(text);
    expect(f, findsOneWidget, reason: '数值 "$text" 应在树里');
    return tester.renderObject<RenderParagraph>(f);
  }

  Future<void> pumpAt(WidgetTester tester, Size size, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(child));
    await tester.pump();
  }

  testWidgets(
      'phone width (360): every KPI number is fully visible (not clipped)',
      (WidgetTester tester) async {
    await pumpAt(
        tester, const Size(360, 800), const StatKpiStrip(items: items));

    for (final StatKpiItem it in items) {
      expect(paragraphOf(tester, it.value).didExceedMaxLines, isFalse,
          reason: '手机窄屏下 KPI 数值 "${it.value}" 不应被 ellipsis 截断');
    }
  });

  testWidgets('phone width (360): strip reflows to 2 columns (2 rows)',
      (WidgetTester tester) async {
    await pumpAt(
        tester, const Size(360, 800), const StatKpiStrip(items: items));

    // 4 个数值分布在 2 个不同的纵坐标 -> 换成了 2 排。
    final Set<double> dys = <double>{
      for (final StatKpiItem it in items)
        tester.getTopLeft(find.text(it.value)).dy,
    };
    expect(dys.length, 2, reason: '窄屏应换成 2 排（每排 2 列）');
  });

  testWidgets('wide width (1040): single row, all numbers visible',
      (WidgetTester tester) async {
    await pumpAt(
        tester, const Size(1040, 800), const StatKpiStrip(items: items));

    final Set<double> dys = <double>{
      for (final StatKpiItem it in items)
        tester.getTopLeft(find.text(it.value)).dy,
    };
    expect(dys.length, 1, reason: '宽屏 4 张卡应在同一排');
    for (final StatKpiItem it in items) {
      expect(paragraphOf(tester, it.value).didExceedMaxLines, isFalse);
    }
  });

  testWidgets(
      'REGRESSION baseline: old 4-in-row Row DOES clip numbers at 360px',
      (WidgetTester tester) async {
    // 复刻旧 _buildKpiStrip 的 4×Expanded 单排结构，证明它在手机上截断数字。
    Widget oldTile(StatKpiItem it) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(it.icon, size: 18),
                  const SizedBox(height: 8),
                  Text(it.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(it.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
        );

    await pumpAt(
      tester,
      const Size(360, 800),
      Row(children: <Widget>[
        for (final StatKpiItem it in items) Expanded(child: oldTile(it))
      ]),
    );

    bool anyClipped = false;
    for (final RenderObject ro
        in tester.renderObjectList<RenderObject>(find.byType(RichText))) {
      if (ro is RenderParagraph && ro.didExceedMaxLines) anyClipped = true;
    }
    expect(anyClipped, isTrue, reason: '旧 4-in-row 结构在手机窄屏必然截断某些 KPI 文本（记录根因）');
  });
}
