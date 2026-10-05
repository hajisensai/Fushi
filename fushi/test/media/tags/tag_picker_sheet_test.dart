import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

/// 共享标签选择器 [showTagPicker]：搜索过滤、搜索无果一键新建并选中、多目标三态批量、
/// 含合集时「合集本身 / 合集内全部条目」各写到正确宿主、窄屏 sheet / 宽屏弹层。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<FushiDatabase> openDb() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<bool?> pumpAndOpen(
    WidgetTester tester,
    FushiDatabase db,
    TagTargets targets, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool? result;
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((Ref ref) => _TestAppModel(db)),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showTagPicker(context, targets: targets);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
    return result;
  }

  testWidgets('搜索按标签名过滤；无同名时一键新建并即时挂到单目标上', (WidgetTester tester) async {
    final FushiDatabase db = await openDb();
    await tester.runAsync(() async {
      await db.createTag('推理', 0xFF5C6BC0);
      await db.createTag('百合', 0xFFEC407A);
    });
    await pumpAndOpen(
      tester,
      db,
      const TagTargets(
        media: <MediaRef>[MediaRef(kind: MediaKind.epub, entryKey: 'b1')],
      ),
    );
    expect(find.byType(FushiTagToggleChip), findsNWidgets(2));

    await tester.enterText(
      find.byKey(const ValueKey<String>('tag_picker_search')),
      '推',
    );
    await settle(tester);
    expect(find.byType(FushiTagToggleChip), findsOneWidget);
    expect(
        find.descendant(
          of: find.byType(FushiTagToggleChip),
          matching: find.text('推理'),
        ),
        findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('tag_picker_search')),
      '冒险',
    );
    await settle(tester);
    expect(find.byType(FushiTagToggleChip), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('tag_picker_create')));
    await settle(tester);

    final List<BookTagRow> all =
        (await tester.runAsync(() => db.getAllTags()))!;
    expect(all.map((BookTagRow t) => t.name), contains('冒险'));
    final List<BookTagRow> onBook =
        (await tester.runAsync(() => db.getTagsForBook('b1')))!;
    expect(onBook.map((BookTagRow t) => t.name).toList(), <String>['冒险'],
        reason: '单目标即时落库：新建的标签直接挂上');
    // 已选行出现 input chip。
    expect(find.byType(FushiTagInputChip), findsOneWidget);
  });

  testWidgets('多目标三态：部分已有 → 点一下全加，应用后两本都有', (WidgetTester tester) async {
    final FushiDatabase db = await openDb();
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('想读', 0xFFFFA726);
      await db.addTagToBook('b1', tagId);
    });
    await pumpAndOpen(
      tester,
      db,
      const TagTargets(media: <MediaRef>[
        MediaRef(kind: MediaKind.epub, entryKey: 'b1'),
        MediaRef(kind: MediaKind.srt, entryKey: 's1'),
      ]),
    );
    final Finder chip = find.byKey(ValueKey<String>('tag_picker_chip_$tagId'));
    expect(
        tester.widget<FushiTagToggleChip>(chip).state, TagCheckState.partial);

    await tester.tap(chip);
    await settle(tester);
    expect(tester.widget<FushiTagToggleChip>(chip).state, TagCheckState.all);
    // 多目标不即时落库。
    expect((await tester.runAsync(() => db.getTagsForSrtBook('s1')))!, isEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('tag_picker_apply')));
    await settle(tester);
    expect(
      (await tester.runAsync(() => db.getTagsForSrtBook('s1')))!
          .map((BookTagRow t) => t.id),
      <int>[tagId],
    );
    expect(
      (await tester.runAsync(() => db.getTagsForBook('b1')))!
          .map((BookTagRow t) => t.id),
      <int>[tagId],
    );
  });

  testWidgets('含合集：默认挂在合集本身；切到「全部条目」则逐个挂到成员、合集不变', (WidgetTester tester) async {
    final FushiDatabase db = await openDb();
    late int tagA;
    late int tagB;
    late int cid;
    await tester.runAsync(() async {
      tagA = await db.createTag('异世界', 0xFFAB47BC);
      tagB = await db.createTag('神作', 0xFF42A5F5);
      cid = await db.createMediaCollection('合集');
      await db.addToCollection(cid, MediaKind.epub, 'u1');
      await db.addToCollection(cid, MediaKind.srt, 's9');
    });
    // 一个合集 = 单目标：即时挂到合集本身。
    await pumpAndOpen(tester, db, TagTargets(collectionIds: <int>[cid]));
    expect(find.text(t.tag_picker_scope_collection_hint), findsOneWidget);
    await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagA')));
    await settle(tester);
    expect(
      (await tester.runAsync(() => db.getTagsForCollection(cid)))!
          .map((BookTagRow t) => t.id),
      <int>[tagA],
    );

    // 切到成员模式：两个成员 = 多目标三态，应用后逐个挂上。
    await tester.tap(
      find.byKey(const ValueKey<String>('tag_picker_scope_members')),
    );
    await settle(tester);
    expect(find.text(t.tag_picker_scope_members_hint), findsOneWidget);
    await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagB')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('tag_picker_apply')));
    await settle(tester);

    // epub 成员行 entryKey 是 uid；没有 epub_books 行可换算时沿用原值。
    expect(
      (await tester.runAsync(() => db.getTagsForBook('u1')))!
          .map((BookTagRow t) => t.id),
      <int>[tagB],
    );
    expect(
      (await tester.runAsync(() => db.getTagsForSrtBook('s9')))!
          .map((BookTagRow t) => t.id),
      <int>[tagB],
    );
    expect(
      (await tester.runAsync(() => db.getTagsForCollection(cid)))!
          .map((BookTagRow t) => t.id),
      <int>[tagA],
      reason: '成员模式不动合集自身的标签',
    );
  });

  testWidgets('窄屏走底部 sheet，宽屏走居中弹层', (WidgetTester tester) async {
    final FushiDatabase db = await openDb();
    const TagTargets targets = TagTargets(
      media: <MediaRef>[MediaRef(kind: MediaKind.video, entryKey: 'v1')],
    );
    await pumpAndOpen(tester, db, targets);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(TagPickerPanel), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpAndOpen(tester, db, targets, size: const Size(1600, 900));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(FushiDialogFrame), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// DB 走真实 IO：在 runAsync 里让微任务跑完再泵帧，直到稳定。
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}
