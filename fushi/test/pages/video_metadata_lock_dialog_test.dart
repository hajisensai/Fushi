import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_lock_dialog.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';

/// v99 字段锁的 UI 入口：勾选写穿 `video_metadata_works.locked_fields`。
void main() {
  late FushiDatabase db;
  late int workId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final int collectionId = await db.into(db.mediaCollections).insert(
          MediaCollectionsCompanion.insert(name: '某番', createdAt: 1),
        );
    workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: '某番',
        updatedAt: 1,
      ),
    );
  });

  tearDown(() => db.close());

  Future<bool?> pumpAndOpen(WidgetTester tester) async {
    bool? saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              saved = await editVideoMetadataLockedFields(
                context: context,
                database: db,
                workId: workId,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return saved;
  }

  Finder lockTile(String field) =>
      find.byKey(ValueKey<String>('video-work-lock-$field'));

  testWidgets('勾选后保存写穿 locked_fields', (WidgetTester tester) async {
    await pumpAndOpen(tester);
    expect(lockTile('title'), findsOneWidget);
    expect(lockTile('backdrop'), findsOneWidget);

    await tester.ensureVisible(lockTile('title'));
    await tester.tap(lockTile('title'));
    await tester.pump();
    await tester.ensureVisible(lockTile('cover'));
    await tester.tap(lockTile('cover'));
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect((await db.getVideoMetadataWorkById(workId))!.lockedFields,
        'title,cover');
  });

  testWidgets('取消不写库', (WidgetTester tester) async {
    await db.setVideoMetadataWorkLockedFields(workId, 'overview');
    await pumpAndOpen(tester);
    await tester.ensureVisible(lockTile('title'));
    await tester.tap(lockTile('title'));
    await tester.pump();
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();

    expect(
      (await db.getVideoMetadataWorkById(workId))!.lockedFields,
      'overview',
      reason: '取消必须一列不动',
    );
  });

  testWidgets('已存的锁回显，全部取消后保存落回 NULL', (WidgetTester tester) async {
    await db.setVideoMetadataWorkLockedFields(workId, 'overview,rating');
    await pumpAndOpen(tester);

    expect(
      tester.widget<AdaptiveSettingsSwitchRow>(lockTile('overview')).value,
      isTrue,
    );
    expect(tester.widget<AdaptiveSettingsSwitchRow>(lockTile('rating')).value,
        isTrue);
    expect(tester.widget<AdaptiveSettingsSwitchRow>(lockTile('title')).value,
        isFalse);

    await tester.ensureVisible(lockTile('overview'));
    await tester.tap(lockTile('overview'));
    await tester.pump();
    await tester.ensureVisible(lockTile('rating'));
    await tester.tap(lockTile('rating'));
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(
      (await db.getVideoMetadataWorkById(workId))!.lockedFields,
      isNull,
      reason: '空集合落回 NULL，不是空串',
    );
  });
}
