// 自定义图片页底上，MD3 分段分组标题垫毛玻璃胶囊（PR #3840；11-24 改走全应用统一的
// [FushiBackdropFrost]）：图片明暗不可控，
// 直接压在图上的小标题对比度忽高忽低。只在图片背景下垫，纯色 / 形状预设不变；
// 垫了胶囊文字左缘位置也不变。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/fushi_backdrop_frost.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

const String _title = 'Language';

Widget _app() => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
  ),
  home: Scaffold(
    body: FushiPageBackdrop(
      child: ListView(
        children: <Widget>[
          AdaptiveSettingsSection(
            title: _title,
            children: <Widget>[
              AdaptiveSettingsSwitchRow(
                title: 'Row',
                value: false,
                onChanged: (_) {},
              ),
            ],
          ),
        ],
      ),
    ),
  ),
);

Finder _pill() => find.descendant(
  of: find.ancestor(
    of: find.text(_title),
    matching: find.byType(FushiBackdropFrost),
  ),
  matching: find.byType(FushiBackdropFrostPlate),
);

void main() {
  late PageBackdropSettings saved;
  setUp(() => saved = pageBackdropSettings.value);
  tearDown(() => pageBackdropSettings.value = saved);

  testWidgets('图片页底：分组标题垫胶囊，文字左缘不动；纯色页底不垫', (WidgetTester tester) async {
    pageBackdropSettings.value = const PageBackdropSettings(
      preset: PageBackdropPreset.plain,
    );
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(_pill(), findsNothing);
    final double plainLeft = tester.getTopLeft(find.text(_title)).dx;

    pageBackdropSettings.value = const PageBackdropSettings(
      preset: PageBackdropPreset.custom,
      // 不存在的文件：图片层走 errorBuilder 画空，这里只验 imageOf 分支。
      landscapeImagePath: 'missing-wallpaper.png',
    );
    await tester.pump();
    await tester.pump();
    expect(_pill(), findsOneWidget);
    expect(tester.getTopLeft(find.text(_title)).dx, plainLeft);
  });
}
