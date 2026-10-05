import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';

/// BUG-2969：合集详情页成员的右键 / 长按菜单曾是详情页自绘的「打开 / 移出」两项，
/// 与书架书卡的菜单（标签 / 标记读完 / 删除 / 重命名…）不是一回事——合集内选不了
/// 标签，右键也跟外面不一样。现在调用方注入 [MediaCollectionGridDetailPage.onShowMemberMenu]，
/// 书架把**同一个**卡片菜单构建传进来，只多一条「移出合集」。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<({FushiDatabase db, MediaCollectionRow col})> seed() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int cid = await db.createMediaCollection('C');
    for (final String k in <String>['k1', 'k2', 'k3']) {
      await db.addToCollection(cid, MediaKind.epub, k);
    }
    return (db: db, col: (await db.getMediaCollectionById(cid))!);
  }

  Widget? cardBuilder(String mediaType, String entryKey,
          {VoidCallback? onRemoveFromCollection}) =>
      Container(
        key: ValueKey<String>('member-$entryKey'),
        color: Colors.blue,
      );

  testWidgets('注入共享菜单后，长按 / 右键成员走调用方菜单，不再弹精简菜单', (WidgetTester tester) async {
    final ({FushiDatabase db, MediaCollectionRow col}) s = await seed();
    final List<String> menus = <String>[];
    VoidCallback? remove;
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: MediaCollectionGridDetailPage(
          database: s.db,
          collection: s.col,
          memberCardBuilder: cardBuilder,
          onOpenMember: (_, __) {},
          onChanged: () {},
          onShowMemberMenu: (
            String mediaType,
            String entryKey, {
            required VoidCallback onRemoveFromCollection,
          }) async {
            menus.add('$mediaType|$entryKey');
            remove = onRemoveFromCollection;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 触摸长按原地松手。
    final Offset center =
        tester.getCenter(find.byKey(const ValueKey<String>('member-k2')));
    final TestGesture press = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await press.up();
    await tester.pumpAndSettle();
    expect(menus, <String>['epub|k2'], reason: '长按必须交给共享菜单');
    expect(find.text(t.collection_open), findsNothing,
        reason: '不得再弹详情页自绘的「打开 / 移出」精简菜单');

    // 桌面右键同一入口。
    final TestGesture right = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('member-k3'))),
      buttons: 2,
      kind: PointerDeviceKind.mouse,
    );
    await right.up();
    await tester.pumpAndSettle();
    expect(menus.last, 'epub|k3', reason: '右键与长按同一个菜单');

    // 共享菜单里的「移出合集」仍是详情页的真实移出流程。
    remove!();
    await tester.pumpAndSettle();
    final List<MediaCollectionItemRow> after =
        await s.db.getCollectionItems(s.col.id);
    expect(after.map((MediaCollectionItemRow r) => r.entryKey),
        <String>['k1', 'k2']);
  });

  group('书架：合集内外同一个卡片菜单（源码守卫）', () {
    final String main = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_history/books.part.dart',
    ).readAsStringSync();

    test('合集详情页注入共享成员菜单', () {
      expect(
          main.contains('onShowMemberMenu: _showCollectionMemberMenu'), isTrue);
    });

    test('成员菜单分派到与书架卡相同的菜单函数', () {
      final String body = methodBody(
        main,
        'Future<void> _showCollectionMemberMenu(',
      );
      for (final String call in <String>[
        '_showEpubItemMenu(',
        '_showSrtBookDialog(',
        '_showRemoteBookDialog(',
        '_showRemoteSrtDialog(',
      ]) {
        expect(body.contains(call), isTrue, reason: '成员菜单必须复用 $call');
      }
    });

    test('书架书卡长按 / 右键走同一个菜单函数', () {
      final String epubCard = methodBody(main, 'Widget _buildEpubBookCard(');
      expect(epubCard.contains('_showEpubItemMenu('), isTrue);
      final String srtCard = methodBody(books, 'Widget _buildSrtCard(');
      expect(srtCard.contains('_showSrtBookDialog('), isTrue);
    });

    test('卡片菜单含「标签」项（合集内也能选标签）', () {
      final String actions =
          methodBody(main, 'List<DialogAction> _epubExtraActions(');
      expect(actions.contains('label: t.tag_label'), isTrue);
    });
  });
}
