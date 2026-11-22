import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_edit_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_manual_edit.dart';

/// BUG-5082：「编辑资料」对话框——刮削全失败（没有作品行）时也能手填并落库上锁。
void main() {
  late FushiDatabase db;
  const String bookUid = 'movie-1';

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>(bookUid),
        title: Value<String>('冷门剧场版'),
        videoPath: Value<String>('D:/Anime/冷门剧场版.mkv'),
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> pumpAndOpen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                await editVideoWorkManualMetadata(
                  context: context,
                  database: db,
                  target: await videoWorkManualTargetForBook(db, bookUid),
                  fallbackTitle: '冷门剧场版',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder input(VideoMetadataLockableField field) => find.descendant(
    of: find.byKey(ValueKey<String>('video-work-edit-${field.name}')),
    matching: find.byType(EditableText),
  );

  testWidgets('没有作品行：填简介 / 年份后保存，建行并上锁', (WidgetTester tester) async {
    await pumpAndOpen(tester);
    expect(
      tester
          .widget<EditableText>(input(VideoMetadataLockableField.title))
          .controller
          .text,
      '冷门剧场版',
      reason: '标题初值取视频名',
    );

    await tester.enterText(input(VideoMetadataLockableField.overview), '手填简介');
    await tester.enterText(input(VideoMetadataLockableField.year), '19x99');
    await tester.enterText(input(VideoMetadataLockableField.genres), '机战，科幻');
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('video-work-edit-save')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-work-edit-save')),
    );
    await tester.pumpAndSettle();

    final VideoMetadataWorkRow row = (await db.getVideoMetadataWorkByBook(
      bookUid,
    ))!;
    expect(row.overview, '手填简介');
    expect(row.year, 1999, reason: '年份框只收数字');
    expect(row.title, '冷门剧场版');
    expect(parseLockedFields(row.lockedFields), <VideoMetadataLockableField>{
      VideoMetadataLockableField.overview,
      VideoMetadataLockableField.year,
      VideoMetadataLockableField.genres,
    });
    final List<VideoMetadataTermRow> terms = await db
        .getVideoMetadataTermsForWork(row.id);
    expect(terms.map((VideoMetadataTermRow e) => e.name), <String>['机战', '科幻']);
  });

  test('合集详情页的「编辑资料」不要求已有作品行（刮削全失败也可点）', () {
    final String page = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();
    final int start = page.indexOf('_CollectionManageAction.editMetadata,');
    expect(start, isNot(-1));
    final String entry = page.substring(start, page.indexOf('),', start));
    expect(entry.contains('enabled:'), isFalse);
  });
}
