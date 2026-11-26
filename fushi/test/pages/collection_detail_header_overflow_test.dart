import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 用户 2026-11-25（Cupertino 合集页录屏）：页头动作是 `FushiIconButtonControl`，
/// 收纳判据收不进「⋯」，窄屏只能横滑、右侧删除等按钮被藏到屏外。页头动作必须是
/// [FushiIconButton]，放不下按优先级收进「⋯」，外露的每颗都完整落在屏内。
void main() {
  testWidgets('Cupertino 手机宽：合集页头动作可收纳、不溢出屏外', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int collectionId = await db.createMediaCollection('BanG Dream! 合集');
    for (int i = 0; i < 3; i++) {
      await db.addToCollection(collectionId, MediaKind.epub, 'book-$i');
    }
    final MediaCollectionRow collection = (await db.getMediaCollectionById(
      collectionId,
    ))!;

    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.brown),
            textTheme: Typography.material2021().black,
            glass: FushiGlassMaterial.minimal,
            glassDesign: true,
          ).copyWith(platform: TargetPlatform.iOS),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => MediaCollectionGridDetailPage(
          database: db,
          collection: collection,
          memberCardBuilder:
              (
                String mediaType,
                String entryKey, {
                VoidCallback? onRemoveFromCollection,
              }) => const ColoredBox(color: Color(0xFFE8EAF0)),
          onChanged: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final MediaPosterDetailChrome chrome = tester.widget(
      find.byType(MediaPosterDetailChrome),
    );
    expect(chrome.actions, isNotEmpty);
    expect(
      chrome.actions.every((Widget action) => action is FushiIconButton),
      isTrue,
      reason: '页头动作必须是 FushiIconButton，才能放不下时收进「⋯」',
    );

    const double screenWidth = 390;
    for (final String key in <String>[
      'collection_detail_rename',
      'collection_detail_header_save_order',
      'collection_detail_delete',
    ]) {
      final Finder button = find.byKey(ValueKey<String>(key));
      if (button.evaluate().isEmpty) continue; // 收进了「⋯」
      final Rect rect = tester.getRect(button);
      expect(
        rect.right,
        lessThanOrEqualTo(screenWidth),
        reason: '$key 外露时必须整颗在屏内，不能靠横滑才看得到',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
