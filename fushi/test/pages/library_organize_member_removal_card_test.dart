// 整理记录页的「移出成员」确认卡（用户 2026-11-24 拍板：动用户合集要用户显式同意，
// 可以永远拒绝）：卡上写清合集名、要移出的成员标题与原因码的本地化说明；三个按钮
// 「永远不 / 这次不 / 移出」；移出后提示条带「撤销」，撤销把成员放回原位、卡片回来。
// MD3 与 Apple 两套设计系统各跑一遍；按钮一律焦点驱动（Enter）。
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/library_organize_history_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() => db.close());

  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  Future<String> book(String title) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: '/m/$title',
        extractDir: '/m/$title',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    return (await db.resolveEpubBookUid(title))!;
  }

  Future<({int collection, List<String> uids})> seed() async {
    final List<String> uids = <String>[
      await book('第1话'),
      await book('映像特典'),
      await book('第2话'),
    ];
    final int col = await db.createMediaCollection(
      '我的番',
      origin: CollectionOrigin.user,
    );
    for (final String u in uids) {
      await db.addToCollectionRaw(col, 'epub', u, userIntent: false);
    }
    await recordMemberRemovalProposals(
      db,
      trigger: 'disc_import',
      proposals: <MemberRemovalProposal>[
        MemberRemovalProposal(
          collectionId: col,
          members: <CollectionMemberKey>[
            (mediaType: 'epub', entryKey: uids[1]),
          ],
          reasonCode: kMemberRemovalReasonDiscExtra,
        ),
      ],
    );
    return (collection: col, uids: uids);
  }

  Future<List<String>> order(int id) async => <String>[
    for (final MediaCollectionItemRow i in await db.getCollectionItems(id))
      i.entryKey,
  ];

  Future<void> pumpPage(WidgetTester tester, {required bool apple}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(apple: apple),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: LibraryOrganizeHistoryPage(db: db, prefs: prefs),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 聚焦 [label] 所在的焦点节点后按 Enter。
  Future<void> pressLabel(WidgetTester tester, Finder label) async {
    await tester.ensureVisible(label.first);
    Focus.of(tester.element(label.first)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  /// 焦点驱动按下 [target] 里的按钮：聚焦它的文字所在的焦点节点后按 Enter。
  Future<void> pressByFocus(WidgetTester tester, Finder target) => pressLabel(
    tester,
    find.descendant(of: target, matching: find.byType(Text)),
  );

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds：卡片写清合集、成员与原因；移出后可撤销回原位', (WidgetTester tester) async {
      final ({int collection, List<String> uids}) s = await seed();
      final int id = (await loadLibraryOrganizeProposals(db)).single.id;
      await pumpPage(tester, apple: apple);

      expect(
        find.text(
          t.library_organize_proposal_remove_members(name: '我的番', n: 1),
        ),
        findsOneWidget,
      );
      expect(
        find.text(t.library_organize_proposal_quoted(name: '映像特典')),
        findsOneWidget,
      );
      expect(
        find.text(t.library_organize_proposal_reason_disc_extra),
        findsOneWidget,
      );
      expect(find.text(t.library_organize_proposal_never), findsOneWidget);
      expect(find.text(t.library_organize_proposal_defer), findsOneWidget);

      await pressByFocus(
        tester,
        find.byKey(ValueKey<String>('library_organize_proposal_accept_$id')),
      );
      expect(await order(s.collection), <String>[s.uids[0], s.uids[2]]);
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$id')),
        findsNothing,
      );
      expect(find.text(t.library_organize_proposal_applied), findsOneWidget);

      // 提示条上的「撤销」（两套设计系统的按钮实现不同，按文字找焦点节点）。
      await pressLabel(tester, find.text(t.library_organize_undo));
      expect(await order(s.collection), s.uids, reason: '放回原位');
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$id')),
        findsOneWidget,
        reason: '建议回到待确认',
      );
    });

    testWidgets('$ds：「这次不」不执行、卡片消失；「永远不」钉住成员', (WidgetTester tester) async {
      final ({int collection, List<String> uids}) s = await seed();
      final int id = (await loadLibraryOrganizeProposals(db)).single.id;
      await pumpPage(tester, apple: apple);

      await pressByFocus(
        tester,
        find.byKey(ValueKey<String>('library_organize_proposal_defer_$id')),
      );
      expect(await order(s.collection), s.uids);
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$id')),
        findsNothing,
      );

      // 取消暂缓（同 CLI organize-unaccept）后点「永远不」。
      await undoLibraryOrganizeProposal(db, id);
      // 换一棵树再进页面，重新加载建议。
      await tester.pumpWidget(const SizedBox());
      await pumpPage(tester, apple: apple);
      await pressByFocus(
        tester,
        find.byKey(ValueKey<String>('library_organize_proposal_decline_$id')),
      );
      final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
        s.collection,
      );
      expect(
        <String, bool>{
          for (final MediaCollectionItemRow r in rows)
            r.entryKey: r.pinnedByUser,
        },
        <String, bool>{s.uids[0]: false, s.uids[1]: true, s.uids[2]: false},
      );
      expect(
        find.byKey(ValueKey<String>('library_organize_proposal_$id')),
        findsNothing,
      );
    });
  }
}
