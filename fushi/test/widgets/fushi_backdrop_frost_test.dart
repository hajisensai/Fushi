// 自定义背景图上的文字统一垫毛玻璃底（2026-11-24 用户：「自定义了背景，文字后面
// 没有描边或者毛玻璃，导致看不清」，拍板统一处理、毛玻璃底）。
//
// 咬住三件事：① 只在图片背景下画，纯色 / 形状预设不画；② 只画不占位，切换预设
// 文字位置与尺寸一像素不动；③ 公共组件（分区标题、空状态）与页头底板都接上了。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/fushi_backdrop_frost.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:material_ui/material_ui.dart';

const PageBackdropSettings _plain = PageBackdropSettings(
  preset: PageBackdropPreset.plain,
);

// 不存在的文件：图片层走 errorBuilder 画空，这里只验 imageOf 分支。
const PageBackdropSettings _image = PageBackdropSettings(
  preset: PageBackdropPreset.custom,
  landscapeImagePath: 'missing-wallpaper.png',
);

Widget _app(Widget body) => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
  ),
  home: Scaffold(body: FushiPageBackdrop(child: body)),
);

Future<void> _usePreset(WidgetTester tester, PageBackdropSettings s) async {
  pageBackdropSettings.value = s;
  await tester.pump();
  await tester.pump();
}

void main() {
  late PageBackdropSettings saved;
  setUp(() => saved = pageBackdropSettings.value);
  tearDown(() => pageBackdropSettings.value = saved);

  testWidgets('分区标题：图片背景下标题与行尾各垫一枚毛玻璃，版面不动', (WidgetTester tester) async {
    await _usePreset(tester, _plain);
    await tester.pumpWidget(
      _app(
        ListView(
          children: <Widget>[
            FushiSectionTitle(
              'Recently added',
              trailing: TextButton(onPressed: () {}, child: const Text('All')),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(FushiBackdropFrostPlate), findsNothing);
    final Rect plainTitle = tester.getRect(find.text('Recently added'));
    final Rect plainAll = tester.getRect(find.text('All'));

    await _usePreset(tester, _image);
    expect(find.byType(FushiBackdropFrostPlate), findsNWidgets(2));
    expect(tester.getRect(find.text('Recently added')), plainTitle);
    expect(tester.getRect(find.text('All')), plainAll);
    // 底板外扩包住文字（胶囊比文字大一圈）。
    final Rect plate = tester.getRect(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('Recently added'),
              matching: find.byType(FushiBackdropFrost),
            ),
            matching: find.byType(FushiBackdropFrostPlate),
          )
          .first,
    );
    expect(plate.left, lessThan(plainTitle.left));
    expect(plate.right, greaterThan(plainTitle.right));

    await _usePreset(tester, _plain);
    expect(find.byType(FushiBackdropFrostPlate), findsNothing);
  });

  testWidgets('空状态：图片背景下说明文字垫毛玻璃', (WidgetTester tester) async {
    await _usePreset(tester, _image);
    await tester.pumpWidget(
      _app(
        const FushiPlaceholderMessage(
          icon: Icons.inbox_outlined,
          message: 'Nothing here',
          detail: 'Import something first',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.text('Nothing here'),
        matching: find.byType(FushiBackdropFrost),
      ),
      findsOneWidget,
    );
    expect(find.byType(FushiBackdropFrostPlate), findsOneWidget);
  });

  testWidgets('书架书名：图片背景下垫毛玻璃，footer 内书名位置不动', (WidgetTester tester) async {
    Widget footer() => const Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 140,
        height: ShelfCardFooter.height,
        child: ShelfCardFooter(title: 'A fairly long book title'),
      ),
    );
    await _usePreset(tester, _plain);
    await tester.pumpWidget(_app(footer()));
    await tester.pump();
    expect(find.byType(FushiBackdropFrostPlate), findsNothing);
    final Rect plainTitle = tester.getRect(
      find.text('A fairly long book title'),
    );

    await _usePreset(tester, _image);
    expect(find.byType(FushiBackdropFrostPlate), findsOneWidget);
    expect(tester.getRect(find.text('A fairly long book title')), plainTitle);
    final Rect plate = tester.getRect(find.byType(FushiBackdropFrostPlate));
    expect(plate.left, lessThan(plainTitle.left));
    expect(plate.right, greaterThan(plainTitle.right));
    expect(plate.top, lessThan(plainTitle.top));
  });

  testWidgets('页头底板：图片背景下未滚动也常驻毛玻璃，纯色背景不画', (WidgetTester tester) async {
    Widget panel() => const SizedBox(
      height: 120,
      child: FushiMastheadPanel(height: 120, progress: 0),
    );
    await _usePreset(tester, _plain);
    await tester.pumpWidget(_app(panel()));
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);

    await _usePreset(tester, _image);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });
}
