// 详情页的两处重复 / 割裂（反馈 g7NgcM5F1b，所有 MediaDetailLayout 详情页共用）：
//  * 顶栏标题与 hero 大标题同屏重复：顶栏标题初始隐藏，正文滚过阈值后淡入；
//  * hero 底部一条带阴影的硬边：模糊封面的晕边没被裁剪，晕到 hero 之外压在下方内容上。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:material_ui/material_ui.dart';

const String _title = '君が一等星に光るまで 01';

// 1x1 透明 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

double _titleOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.byKey(const ValueKey<String>('fushi_page_header_title_fade')),
    )
    .opacity;

void main() {
  testWidgets('顶栏标题初始隐藏，滚过阈值后淡入，滚回去再隐藏', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiPageScaffold(
          title: _title,
          revealTitleAfterScroll: kMediaDetailTitleRevealOffset,
          body: ListView(
            children: <Widget>[
              for (int i = 0; i < 40; i++)
                SizedBox(height: 80, child: Text('row $i')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_titleOpacity(tester), 0, reason: 'hero 里已有大标题，顶栏标题不该同屏出现');

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(_titleOpacity(tester), 1);

    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(_titleOpacity(tester), 0);
  });

  testWidgets('不传 revealTitleAfterScroll：标题恒显示（其它页面行为不变）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiPageScaffold(
          title: _title,
          body: ListView(children: const <Widget>[SizedBox(height: 2000)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_page_header_title_fade')),
      findsNothing,
    );
    expect(find.text(_title), findsOneWidget);
  });

  testWidgets('模糊封面背景被裁在 hero 框内（晕边不压到下方内容）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: MediaDetailBackdrop(image: MemoryImage(_png)),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byType(ImageFiltered),
        matching: find.byType(ClipRect),
      ),
      findsOneWidget,
      reason: 'ImageFiltered 默认不裁剪，模糊晕边会画到 hero 底边之外形成「阴影硬边」',
    );
  });
  // BUG-3355（反馈 kVwc9NMu2x「漫画点开顶上有莫名的毛玻璃」）：AnimatedSwitcher 的
  // 默认布局给子项松约束，Image 不铺满、按宽高比缩成居中的一条竖图——两栏详情页
  // 顶部只剩窗口中间一块模糊竖条。两种背景（模糊封面 / 原样 fanart）都必须铺满。
  for (final double sigma in <double>[28, 0]) {
    testWidgets('背景图铺满整块（blurSigma=$sigma）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 700,
              height: 400,
              child: MediaDetailBackdrop(
                image: MemoryImage(_png),
                blurSigma: sigma,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getSize(find.byType(Image)), const Size(700, 400));
    });
  }
}
