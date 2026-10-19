import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/privacy/media_privacy_dialog.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 私密对话框显示的是**有效**状态：作品自己没标、但在私密合集里时，排行榜 /
/// Bangumi 照样当它私密。只读作品自己那一行会把它显示成「关」，用户以为它会被
/// 上传——这里钉死：开关显示开且禁用，并写明是哪个合集。MD3 与 Apple 两套都验。
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String> book(String key) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/x/$key.epub',
        extractDir: '/x/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
      ),
    );
    return (await db.getEpubBook(key))!.uid;
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool apple,
    required String bookKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: apple,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: MediaPrivacyDialog(
              db: db,
              kind: TagHostKind.epub,
              entryKey: bookKey,
              title: bookKey,
            ),
          ),
        ),
      ),
    );
    // 读库是真异步（drift），放到真时钟里跑完再重建。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  FushiSwitchListTile switchTile(WidgetTester tester) =>
      tester.widget<FushiSwitchListTile>(
        find.byKey(const ValueKey<String>('media-privacy-switch')),
      );

  final Finder inheritedNote = find.byKey(
    const ValueKey<String>('media-privacy-inherited-note'),
  );

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets('$system：在私密合集里（按 uid 入合集）→ 开关显示开、禁用、写明合集', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final String uid = await book('B');
        final int c = await db.createMediaCollection('秘密合集');
        await db.addToCollection(c, MediaKind.epub, uid);
        await db.setMediaPrivate(
          TagHostKind.collection,
          collectionTagEntryKey(c),
          true,
        );
      });
      await pumpDialog(tester, apple: apple, bookKey: 'B');

      final FushiSwitchListTile tile = switchTile(tester);
      expect(tile.value, isTrue, reason: '实际私密，不能显示成关');
      expect(tile.onChanged, isNull, reason: '作品开关拨不掉合集的私密');
      expect(inheritedNote, findsOneWidget);
      expect(
        find.text(t.media_privacy_inherited_note(collections: '秘密合集')),
        findsOneWidget,
      );
    });

    testWidgets('$system：不在私密合集里 → 开关显示作品自己的状态、可拨、无说明', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final String uid = await book('Open');
        final int c = await db.createMediaCollection('公开合集');
        await db.addToCollection(c, MediaKind.epub, uid);
      });
      await pumpDialog(tester, apple: apple, bookKey: 'Open');

      final FushiSwitchListTile tile = switchTile(tester);
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNotNull);
      expect(inheritedNote, findsNothing);
    });
  }
}
