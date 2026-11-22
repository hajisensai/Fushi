import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/privacy/media_lock_auth.dart';
import 'package:fushi/src/media/privacy/media_privacy_dialog.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 作品「隐私」对话框（拍板台 qiqSbvdxrk：原「私密」「NSFW」两行 + 新「上锁」合成
/// 一个入口）。分级显示的是**有效**状态：作品自己没标、但在私密 / 上锁合集或私密
/// 来源库里时照样生效，低于继承下限的选项禁用并写明来源。MD3 与 Apple 两套都验。
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

/// 系统验证恒不可用（测试机没有原生通道）。
final class _NoDeviceAuth implements DeviceOwnerAuth {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<DeviceOwnerAuthResult> authenticate(String reason) async =>
      DeviceOwnerAuthResult.unavailable;
}

void main() {
  late FushiDatabase db;
  late _FailingPrivacyReads interceptor;
  late MediaLockAuth savedAuth;

  setUp(() {
    interceptor = _FailingPrivacyReads()..fail = false;
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interceptor),
    );
    savedAuth = MediaLockAuth.instance;
  });
  tearDown(() async {
    MediaLockAuth.instance = savedAuth;
    await db.close();
  });

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

  Future<void> settle(WidgetTester tester) async {
    // 读写库是真异步（drift），放到真时钟里跑完再重建。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool apple,
    required String entryKey,
    TagHostKind kind = TagHostKind.epub,
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
              // 每部作品一个新 State（同位置换作品时不复用上一部的读数）。
              key: ValueKey<String>(entryKey),
              db: db,
              kind: kind,
              entryKey: entryKey,
              title: entryKey,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// 分段控件当前的选中项与各段是否可点（MD3 胶囊 / Apple 分段两种实现）。
  ({Set<MediaPrivacyLevel> selected, Map<MediaPrivacyLevel, bool> enabled})
  levels(WidgetTester tester) {
    final Finder scope = find.byKey(
      const ValueKey<String>('media-privacy-level'),
    );
    final Finder pill = find.descendant(
      of: scope,
      matching: find.byType(FushiPillSegmentedButton<MediaPrivacyLevel>),
    );
    final List<ButtonSegment<MediaPrivacyLevel>> segments;
    final Set<MediaPrivacyLevel> selected;
    if (pill.evaluate().isNotEmpty) {
      final FushiPillSegmentedButton<MediaPrivacyLevel> w = tester.widget(pill);
      segments = w.segments;
      selected = w.selected;
    } else {
      final FushiSegmentedButton<MediaPrivacyLevel> w = tester.widget(
        find.descendant(
          of: scope,
          matching: find.byType(FushiSegmentedButton<MediaPrivacyLevel>),
        ),
      );
      segments = w.segments;
      selected = w.selected;
    }
    return (
      selected: selected,
      enabled: <MediaPrivacyLevel, bool>{
        for (final ButtonSegment<MediaPrivacyLevel> s in segments)
          s.value: s.enabled,
      },
    );
  }

  // Apple 分段按纯文本重建段标签（label 上的 key 不保留），按文案找。
  Finder segment(MediaPrivacyLevel level) => find.descendant(
    of: find.byKey(const ValueKey<String>('media-privacy-level')),
    matching: find.text(switch (level) {
      MediaPrivacyLevel.public => t.media_privacy_level_public,
      MediaPrivacyLevel.private => t.media_privacy_level_private,
      MediaPrivacyLevel.locked => t.media_privacy_level_locked,
    }),
  );

  FushiSwitchListTile nsfwTile(WidgetTester tester) =>
      tester.widget<FushiSwitchListTile>(
        find.byKey(const ValueKey<String>('media-nsfw-switch')),
      );

  final Finder inheritedNote = find.byKey(
    const ValueKey<String>('media-privacy-inherited-note'),
  );

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets('$system：在私密合集里（按 uid 入合集）→ 显示私密、公开禁用、写明合集', (
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
      await pumpDialog(tester, apple: apple, entryKey: 'B');

      final state = levels(tester);
      expect(state.selected, <MediaPrivacyLevel>{MediaPrivacyLevel.private});
      expect(state.enabled[MediaPrivacyLevel.public], isFalse);
      expect(state.enabled[MediaPrivacyLevel.locked], isTrue);
      expect(inheritedNote, findsOneWidget);
      expect(
        find.text(t.media_privacy_inherited_note(collections: '秘密合集')),
        findsOneWidget,
      );
    });

    testWidgets('$system：在上锁合集里 → 显示上锁、其余禁用、写明合集', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final String uid = await book('L');
        final int c = await db.createMediaCollection('锁柜');
        await db.addToCollection(c, MediaKind.epub, uid);
        await db.setMediaLocked(
          TagHostKind.collection,
          collectionTagEntryKey(c),
          true,
        );
      });
      await pumpDialog(tester, apple: apple, entryKey: 'L');

      final state = levels(tester);
      expect(state.selected, <MediaPrivacyLevel>{MediaPrivacyLevel.locked});
      expect(state.enabled[MediaPrivacyLevel.public], isFalse);
      expect(state.enabled[MediaPrivacyLevel.private], isFalse);
      expect(
        find.text(t.media_lock_inherited_note(collections: '锁柜')),
        findsOneWidget,
      );
    });

    testWidgets('$system：不在私密合集里 → 显示公开、各级可选、无说明；改私密落库', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final String uid = await book('Open');
        final int c = await db.createMediaCollection('公开合集');
        await db.addToCollection(c, MediaKind.epub, uid);
      });
      await pumpDialog(tester, apple: apple, entryKey: 'Open');

      final state = levels(tester);
      expect(state.selected, <MediaPrivacyLevel>{MediaPrivacyLevel.public});
      expect(state.enabled.values, everyElement(isTrue));
      expect(inheritedNote, findsNothing);
      expect(nsfwTile(tester).onChanged, isNotNull);

      await tester.tap(segment(MediaPrivacyLevel.private));
      await settle(tester);
      expect(
        await tester.runAsync(
          () => db.isMediaPrivate(TagHostKind.epub, 'Open'),
        ),
        isTrue,
      );
      expect(levels(tester).selected, <MediaPrivacyLevel>{
        MediaPrivacyLevel.private,
      });
    });

    testWidgets('$system：已有口令时选「上锁」只写上锁标记，不动私密标记', (WidgetTester tester) async {
      final MediaLockPasscode passcode = MediaLockPasscode(
        store: MemoryMediaLockSecretStore(),
        iterations: 2,
      );
      await tester.runAsync(() async {
        await book('K');
        await passcode.set('1234');
      });
      MediaLockAuth.instance = MediaLockAuth(
        passcode: passcode,
        device: _NoDeviceAuth(),
      );
      await pumpDialog(tester, apple: apple, entryKey: 'K');

      await tester.tap(segment(MediaPrivacyLevel.locked));
      await settle(tester);
      expect(
        await tester.runAsync(() => db.isMediaLocked(TagHostKind.epub, 'K')),
        isTrue,
      );
      expect(
        await tester.runAsync(() => db.isMediaPrivate(TagHostKind.epub, 'K')),
        isFalse,
      );
      expect(levels(tester).selected, <MediaPrivacyLevel>{
        MediaPrivacyLevel.locked,
      });
    });

    testWidgets('$system：字幕书只有「公开 / 上锁」两级', (WidgetTester tester) async {
      await pumpDialog(
        tester,
        apple: apple,
        entryKey: 'srt-1',
        kind: TagHostKind.srt,
      );
      expect(levels(tester).enabled.keys, <MediaPrivacyLevel>[
        MediaPrivacyLevel.public,
        MediaPrivacyLevel.locked,
      ]);
    });

    testWidgets('$system：所在来源库开了隐私（v140）→ 显示私密、公开禁用、写明来源库', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await book('Src');
        final int source = await db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: '私人文件夹',
            mediaKind: 'book',
            rootPath: '/books/private',
            createdAt: 0,
          ),
        );
        await (db.update(db.epubBooks)..where((t) => t.bookKey.equals('Src')))
            .write(EpubBooksCompanion(sourceId: Value<int?>(source)));
        await db.updateMediaSourcePrivate(source, true);
      });
      await pumpDialog(tester, apple: apple, entryKey: 'Src');

      final state = levels(tester);
      expect(state.selected, <MediaPrivacyLevel>{MediaPrivacyLevel.private});
      expect(state.enabled[MediaPrivacyLevel.public], isFalse);
      expect(
        find.text(t.media_privacy_inherited_source_note(source: '私人文件夹')),
        findsOneWidget,
      );
    });

    testWidgets('$system：NSFW 开关写通用表；在 NSFW 合集里时显示开且禁用', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final String uid = await book('N');
        await book('M');
        final int c = await db.createMediaCollection('成人合集');
        await db.addToCollection(c, MediaKind.epub, uid);
        await db.setMediaNsfw(
          TagHostKind.collection,
          collectionTagEntryKey(c),
          true,
        );
      });
      await pumpDialog(tester, apple: apple, entryKey: 'N');
      expect(nsfwTile(tester).value, isTrue);
      expect(nsfwTile(tester).onChanged, isNull);

      await pumpDialog(tester, apple: apple, entryKey: 'M');
      expect(nsfwTile(tester).value, isFalse);
      nsfwTile(tester).onChanged!(true);
      await settle(tester);
      expect(
        await tester.runAsync(() => db.isMediaNsfw(TagHostKind.epub, 'M')),
        isTrue,
      );
      expect(nsfwTile(tester).value, isTrue);
    });
  }

  for (final bool apple in <bool>[false, true]) {
    final String system = apple ? 'Apple' : 'MD3';

    testWidgets('$system：首次读库失败 → 控件保持禁用、明示读不到；重试成功后显示真实状态', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await book('P');
        await db.setMediaPrivate(TagHostKind.epub, 'P', true);
      });
      interceptor.fail = true;
      await pumpDialog(tester, apple: apple, entryKey: 'P');

      final Finder error = find.byKey(
        const ValueKey<String>('media-privacy-load-error'),
      );
      expect(error, findsOneWidget);
      // fail-closed：读不到时不能给出「公开、可改」的控件。
      final state = levels(tester);
      expect(state.selected, isEmpty);
      expect(state.enabled.values, everyElement(isFalse));
      expect(nsfwTile(tester).onChanged, isNull);
      expect(find.text(t.retry), findsOneWidget);

      interceptor.fail = false;
      await tester.tap(find.text(t.retry));
      await settle(tester);

      expect(error, findsNothing);
      expect(find.text(t.retry), findsNothing);
      expect(levels(tester).selected, <MediaPrivacyLevel>{
        MediaPrivacyLevel.private,
      });
    });
  }
}
