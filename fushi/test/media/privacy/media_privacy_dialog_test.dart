import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
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
/// 读私密表时按开关抛错：模拟首次读库失败，再放行验证重试。
class _FailingPrivacyReads extends QueryInterceptor {
  bool fail = true;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (fail && statement.contains('media_privacy_flags')) {
      throw StateError('disk I/O error');
    }
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  late FushiDatabase db;
  late _FailingPrivacyReads interceptor;

  setUp(() {
    interceptor = _FailingPrivacyReads()..fail = false;
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interceptor),
    );
  });
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

    testWidgets('$system：所在来源库开了隐私（v140）→ 开关显示开、禁用、写明来源库', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await book('Nsfw');
        final int source = await db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: '私人文件夹',
            mediaKind: 'book',
            rootPath: '/books/private',
            createdAt: 0,
          ),
        );
        await (db.update(db.epubBooks)..where((t) => t.bookKey.equals('Nsfw')))
            .write(EpubBooksCompanion(sourceId: Value<int?>(source)));
        await db.updateMediaSourcePrivate(source, true);
      });
      await pumpDialog(tester, apple: apple, bookKey: 'Nsfw');

      final FushiSwitchListTile tile = switchTile(tester);
      expect(tile.value, isTrue, reason: '实际私密，不能显示成关');
      expect(tile.onChanged, isNull, reason: '作品开关拨不掉来源库的私密');
      expect(
        find.text(t.media_privacy_inherited_source_note(source: '私人文件夹')),
        findsOneWidget,
      );
    });
  }

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets('$system：首次读库失败 → 开关保持禁用、明示读不到；重试成功后显示真实状态', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await book('P');
        await db.setMediaPrivate(TagHostKind.epub, 'P', true);
      });
      interceptor.fail = true;
      await pumpDialog(tester, apple: apple, bookKey: 'P');

      final Finder error = find.byKey(
        const ValueKey<String>('media-privacy-load-error'),
      );
      expect(error, findsOneWidget);
      expect(
        find.textContaining(
          t.media_privacy_load_failed(reason: '').trim().split(':').first,
        ),
        findsOneWidget,
      );
      // fail-closed：读不到时不能给出「公开、可改」的开关。
      expect(switchTile(tester).onChanged, isNull);
      expect(find.text(t.retry), findsOneWidget);

      interceptor.fail = false;
      await tester.tap(find.text(t.retry));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();

      expect(error, findsNothing);
      expect(find.text(t.retry), findsNothing);
      final FushiSwitchListTile tile = switchTile(tester);
      expect(tile.value, isTrue);
      expect(tile.onChanged, isNotNull);
    });
  }
}
