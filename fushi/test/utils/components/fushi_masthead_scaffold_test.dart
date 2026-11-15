import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart'
    show FushiMastheadPanel;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 二级页共享的页头大字外壳：正文让位与页头同一次布局定下（首帧不跳）、滚动中
/// 页名收缩不改让位、`titleInBody` 页头的页名按给定偏移淡入。
void main() {
  Future<void> pumpHost(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData(useMaterial3: true), home: home),
    );
  }

  testWidgets('首帧正文的顶部让位就等于页头下沿，之后不再变', (WidgetTester tester) async {
    final List<double> insets = <double>[];
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpHost(
      tester,
      FushiMastheadScaffold(
        title: 'Statistics',
        actions: <Widget>[
          FushiIconButtonControl(
            tooltip: 'Refresh',
            onPressed: () {},
            icon: const FushiIcon(FushiIcons.refresh),
          ),
        ],
        body: Builder(
          builder: (BuildContext context) {
            insets.add(MediaQuery.paddingOf(context).top);
            return ListView.builder(
              controller: controller,
              itemExtent: 80,
              itemCount: 60,
              itemBuilder: (BuildContext context, int i) => Text('row $i'),
            );
          },
        ),
      ),
    );
    // 只过了一帧：正文已经按页头实高让位，不是先只让状态栏、下一帧再下移。
    final double headerBottom = tester
        .getRect(find.byType(FushiMastheadHeader))
        .bottom;
    expect(insets, isNotEmpty);
    expect(insets.first, moreOrLessEquals(headerBottom));
    expect(headerBottom, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 600));
    controller.jumpTo(200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // 页名收缩（页头变矮）但正文让位不跟着变：内容不跳。
    expect(
      tester.getRect(find.byType(FushiMastheadHeader)).bottom,
      lessThan(headerBottom),
    );
    expect(insets.toSet(), <double>{insets.first});
    // 滚到页头下面后垫底板。
    final FushiMastheadPanel panel = tester.widget(
      find.byType(FushiMastheadPanel),
    );
    expect(panel.progress, greaterThan(0));
  });

  testWidgets('titleInBody：页名在主滚动越过 titleRevealOffset 后才淡入', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    final ValueNotifier<double> reveal = ValueNotifier<double>(300);
    addTearDown(controller.dispose);
    addTearDown(reveal.dispose);
    await pumpHost(
      tester,
      Scaffold(
        body: FushiMastheadFrame(
          title: 'Work title',
          titleInBody: true,
          titleRevealOffset: reveal,
          body: ListView.builder(
            controller: controller,
            itemExtent: 80,
            itemCount: 60,
            itemBuilder: (BuildContext context, int i) => Text('row $i'),
          ),
        ),
      ),
    );
    double titleOpacity() => tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.text('Work title'),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    // 裸图标页头一行高。
    expect(
      tester.getSize(find.byType(FushiMastheadHeader)).height,
      kFushiMastheadBareRowExtent,
    );
    expect(titleOpacity(), 0);
    controller.jumpTo(200);
    await tester.pump();
    expect(titleOpacity(), 0);
    controller.jumpTo(400);
    await tester.pump();
    expect(titleOpacity(), 1);
  });
}
