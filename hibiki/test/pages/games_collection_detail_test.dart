import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/utils.dart';

/// 游戏进合集：通用合集网格详情页（[MediaCollectionGridDetailPage]）加载 'game'
/// 成员的 widget 测试。
///
/// 钉住三条：
/// 1. game 成员经 [buildGameCollectionMemberCard] 用游戏卡视觉（[GalgamePosterCard]）
///    渲染，标题上屏；
/// 2. 库里找不到的 game 孤儿引用返回 null → 详情页跳过、不崩；
/// 3. 非 game mediaType 交回 null（书/SRT 由书架页自己的 builder 渲染，本 builder
///    不越界），混合合集里书成员在游戏侧详情不渲染也不误当游戏。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  GalgameEntry entry(String id, String name) => GalgameEntry(
        id: id,
        name: name,
        exePath: 'Z:\\missing\\$id.exe',
        workdir: r'Z:\missing',
        addedAt: DateTime(2026),
      );

  test('buildGameCollectionMemberCard：查找/越界/孤儿三态', () {
    final List<GalgameEntry> games = <GalgameEntry>[entry('g1', 'ATRI')];
    expect(
      buildGameCollectionMemberCard(
        games: games,
        mediaType: 'game',
        entryKey: 'g1',
      ),
      isA<Widget>(),
    );
    // 孤儿引用（游戏已从库移除）→ null，详情页跳过。
    expect(
      buildGameCollectionMemberCard(
        games: games,
        mediaType: 'game',
        entryKey: 'gone',
      ),
      isNull,
    );
    // 非 game mediaType → null（不把 epub 行误当游戏渲染）。
    expect(
      buildGameCollectionMemberCard(
        games: games,
        mediaType: 'epub',
        entryKey: 'g1',
      ),
      isNull,
    );
  });

  testWidgets('合集详情页渲染 game 成员卡；孤儿与书成员被跳过', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int c = await db.createMediaCollection('ネコぱら全集');
    await db.addToCollection(c, MediaKind.game, 'g1');
    await db.addToCollection(c, MediaKind.game, 'gone'); // 孤儿：库里无此游戏。
    await db.addToCollection(c, MediaKind.epub, 'book-1'); // 混合合集：书成员。
    final MediaCollectionRow collection = (await db.getMediaCollectionById(c))!;

    final List<GalgameEntry> games = <GalgameEntry>[entry('g1', 'ATRI')];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionGridDetailPage(
            database: db,
            collection: collection,
            memberCardBuilder: (
              String mediaType,
              String entryKey, {
              VoidCallback? onRemoveFromCollection,
            }) =>
                buildGameCollectionMemberCard(
              games: games,
              mediaType: mediaType,
              entryKey: entryKey,
            ),
            onChanged: () {},
          ),
        ),
      ),
    );
    // initState 里 getCollectionItems 异步返回后再重建。
    await tester.pumpAndSettle();

    // 在库的 game 成员用游戏卡视觉渲染、标题上屏。
    expect(find.byType(GalgamePosterCard), findsOneWidget);
    expect(find.text('ATRI'), findsOneWidget);
    // 孤儿 game 引用与 epub 成员都被跳过：不渲染、不崩、不出现幽灵卡。
    expect(find.text('gone'), findsNothing);
    expect(find.text('book-1'), findsNothing);
  });
}
