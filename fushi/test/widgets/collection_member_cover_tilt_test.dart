import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show collectionDetailSortPrefKey, kCollectionDetailManualSortValue;
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4323（反馈 bsbJ4OVa8o）：合集里的书 / 视频卡没有库页那种 3D 倾斜视差。
///
/// 根因：合集详情的成员卡 / 集卡整张包在 `IgnorePointer` 里（手势归外层网格），
/// 卡里 [FushiHoverLift] 自己的 MouseRegion 收不到事件；外层 [FushiHoverLiftHost]
/// 只代收「悬停」一位、不代收指针位置，[FushiTilt] 读到的指针恒为 null，抬升 /
/// 扫光都有、倾斜永远是平的。修复后 [FushiHoverLiftRelay] 连指针位置一起代收。
///
/// 断言两件事：① 每张卡的子树里恰好一个 [FushiTilt]（不双重倾斜）；② 悬停在卡的
/// 右缘时那一层真的转起来（rotateY 的 (0,2) 项 < 0），移出后回到单位矩阵。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Finder tiltTransformUnder(Finder scope) => find
      .descendant(
        of: find.descendant(of: scope, matching: find.byType(FushiTilt)),
        matching: find.byType(Transform),
      )
      .first;

  Matrix4 tiltOf(WidgetTester tester, Finder scope) =>
      tester.widget<Transform>(tiltTransformUnder(scope)).transform;

  Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1, 1));
    await tester.pump();
    await mouse.moveTo(at);
    await tester.pumpAndSettle();
    return mouse;
  }

  void sizeView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
  }

  /// 库页同款成员卡：[FushiHoverLift] 包 [ShelfCoverFrame]（材质由详情页注入）。
  Widget? cardBuilder(
    String mediaType,
    String entryKey, {
    VoidCallback? onRemoveFromCollection,
  }) => KeyedSubtree(
    key: ValueKey<String>('member-$entryKey'),
    child: FushiHoverLift(
      builder: (BuildContext _, bool __) => const SizedBox.expand(
        child: ShelfCoverFrame(child: ColoredBox(color: Colors.blue)),
      ),
    ),
  );

  for (final bool manual in <bool>[false, true]) {
    final String label = manual ? '手动序拖排网格' : '默认网格';
    testWidgets('合集详情书卡悬停右缘：恰好一层倾斜且朝右转（$label）', (WidgetTester tester) async {
      sizeView(tester);
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int cid = await db.createMediaCollection('C');
      await db.addToCollection(cid, MediaKind.epub, 'k1');
      await db.addToCollection(cid, MediaKind.epub, 'k2');
      if (manual) {
        await db.setPref(
          collectionDetailSortPrefKey(cid),
          kCollectionDetailManualSortValue,
        );
      }
      final MediaCollectionRow col = (await db.getMediaCollectionById(cid))!;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: MediaCollectionGridDetailPage(
              database: db,
              collection: col,
              memberCardBuilder: cardBuilder,
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder card = find.byKey(const ValueKey<String>('member-k1'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byType(FushiTilt)),
        findsOneWidget,
        reason: '成员卡子树里应恰好一层 FushiTilt（不双重倾斜）',
      );
      final Rect r = tester.getRect(card);
      final TestGesture mouse = await mouseAt(
        tester,
        Offset(r.right - 4, r.center.dy),
      );
      expect(
        tiltOf(tester, card).entry(0, 2),
        lessThan(-0.05),
        reason: '悬停在卡右缘应朝右倾（被 IgnorePointer 挡住时也要拿到指针位置）',
      );
      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(tiltOf(tester, card).isIdentity(), isTrue);
    });
  }

  testWidgets('视频合集集卡：缩略图恰好一层倾斜，悬停右缘朝右转', (WidgetTester tester) async {
    sizeView(tester);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                height: kCollectionEpisodeCardHeight,
                child: Builder(
                  builder: (BuildContext context) => CollectionEpisodeCard(
                    thumb: collectionEpisodeThumb(context, null),
                    number: '1',
                    title: 'Episode 1',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder card = find.byType(CollectionEpisodeCard);
    expect(
      find.descendant(of: card, matching: find.byType(FushiTilt)),
      findsOneWidget,
    );
    final Rect thumb = tester.getRect(find.byType(ShelfCoverFrame));
    final TestGesture mouse = await mouseAt(
      tester,
      Offset(thumb.right - 2, thumb.center.dy),
    );
    expect(tiltOf(tester, card).entry(0, 2), lessThan(-0.05));
    await mouse.moveTo(const Offset(1199, 899));
    await tester.pumpAndSettle();
    expect(tiltOf(tester, card).isIdentity(), isTrue);
  });

  group('库页卡：每张恰好一层 FushiTilt', () {
    Future<void> pumpCard(WidgetTester tester, Widget frame) async {
      sizeView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 160,
                height: 240,
                child: FushiHoverLift(
                  builder: (BuildContext _, bool __) => frame,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    const Widget cover = ColoredBox(color: Colors.blue);

    testWidgets('单本（无材质）', (WidgetTester tester) async {
      await pumpCard(tester, const ShelfCoverFrame(child: cover));
      expect(find.byType(FushiTilt), findsOneWidget);
    });

    testWidgets('单本（材质）', (WidgetTester tester) async {
      await pumpCard(
        tester,
        const ShelfCoverMaterialScope(
          material: ShelfCoverMaterial.glossyBook,
          child: ShelfCoverFrame(child: cover),
        ),
      );
      expect(find.byType(FushiTilt), findsOneWidget);
    });

    testWidgets('叠层（材质扇形）', (WidgetTester tester) async {
      await pumpCard(
        tester,
        const ShelfCoverMaterialScope(
          material: ShelfCoverMaterial.glossyBook,
          child: ShelfCoverFrame(
            stackedCovers: <Widget>[cover, cover, cover],
            child: cover,
          ),
        ),
      );
      expect(find.byType(FushiTilt), findsOneWidget);
    });

    testWidgets('叠层（无材质）', (WidgetTester tester) async {
      await pumpCard(
        tester,
        const ShelfCoverFrame(stackedBehind: cover, child: cover),
      );
      expect(find.byType(FushiTilt), findsOneWidget);
    });
  });
}
