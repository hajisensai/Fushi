/// tags 稳健档跨端同步（LWW-element-set）DB 层测试：mergeRemoteBookTags /
/// mergeRemoteVideoTags 的 add-wins / remove-wins / 防复活 / 幂等。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

Future<void> _seedBook(HibikiDatabase db, String bookKey) =>
    db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/tmp/$bookKey.epub',
      extractDir: '/tmp/$bookKey',
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: 0,
    ));

Future<Set<String>> _bookTagNames(HibikiDatabase db, String bookKey) async =>
    (await db.getTagsForBook(bookKey)).map((BookTagRow t) => t.name).toSet();

void main() {
  late HibikiDatabase db;
  setUp(() => db = _memDb());
  tearDown(() => db.close());

  group('mergeRemoteBookTags LWW-element-set', () {
    test('远端有标签、本地无 → 合并后本地出现该标签（pull additive）', () async {
      await _seedBook(db, 'BookA');
      await db.mergeRemoteBookTags('BookA',
          remoteAddedAt: <String, int>{'听力': 10, 'N2': 10});
      expect(await _bookTagNames(db, 'BookA'), <String>{'听力', 'N2'});
    });

    test('本地已移除标签(墓碑 t=20) → 远端旧 add(t=10) 不复活（remove-wins）', () async {
      await _seedBook(db, 'BookA');
      // 本地先有 听力 然后移除（写墓碑）。
      final int tagId = await db.getOrCreateTagByName('听力');
      await db.addTagToBook('BookA', tagId);
      await db.removeTagFromBook('BookA', tagId); // 墓碑 removedAt=now(>10)
      // 远端快照仍带旧的 听力(addedAt=10) → 不得复活。
      await db.mergeRemoteBookTags('BookA',
          remoteAddedAt: <String, int>{'听力': 10});
      expect(await _bookTagNames(db, 'BookA'), isEmpty,
          reason: '本地移除晚于远端旧 add，remove-wins，不复活');
    });

    test('远端墓碑(t=40) 压过本地 add(t=30) → 本地标签被移除（delete 传播）', () async {
      await _seedBook(db, 'BookA');
      final int tagId = await db.getOrCreateTagByName('听力');
      await db.addTagToBook('BookA', tagId); // 本地 add，addedAt≈now
      final int localAdd =
          (await db.bookTagAddedAtByName('BookA'))['听力']!;
      await db.mergeRemoteBookTags('BookA',
          remoteAddedAt: const <String, int>{},
          remoteTombstones: <String, int>{'听力': localAdd + 1000});
      expect(await _bookTagNames(db, 'BookA'), isEmpty,
          reason: '远端移除戳晚于本地 add，remove-wins，删除传播');
      // 墓碑保留（防后续第三端旧 add 复活）。
      expect((await db.tagTombstonesByName('BookA', 'epub')).containsKey('听力'),
          isTrue);
    });

    test('重加(add t 更新) 压过旧墓碑 → 标签恢复', () async {
      await _seedBook(db, 'BookA');
      final int tagId = await db.getOrCreateTagByName('听力');
      await db.addTagToBook('BookA', tagId);
      await db.removeTagFromBook('BookA', tagId);
      // 远端更晚的 add 戳 → add-wins 恢复。
      final int laterAdd =
          DateTime.now().millisecondsSinceEpoch + 1000000;
      await db.mergeRemoteBookTags('BookA',
          remoteAddedAt: <String, int>{'听力': laterAdd});
      expect(await _bookTagNames(db, 'BookA'), <String>{'听力'});
      expect((await db.tagTombstonesByName('BookA', 'epub')).containsKey('听力'),
          isFalse,
          reason: 'present 名清墓碑');
    });

    test('幂等：同一远端快照合并两次结果一致', () async {
      await _seedBook(db, 'BookA');
      final Map<String, int> snap = <String, int>{'听力': 10, 'N2': 20};
      await db.mergeRemoteBookTags('BookA', remoteAddedAt: snap);
      await db.mergeRemoteBookTags('BookA', remoteAddedAt: snap);
      expect(await _bookTagNames(db, 'BookA'), <String>{'听力', 'N2'});
    });
  });

  group('mergeRemoteVideoTags', () {
    test('视频标签 pull + remove-wins 防复活', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/v1',
        title: 'V1',
        videoPath: '/tmp/v1.mp4',
      ));
      await db.mergeRemoteVideoTags('video/v1',
          remoteAddedAt: <String, int>{'アニメ': 10});
      expect(
          (await db.getTagsForVideoBook('video/v1'))
              .map((BookTagRow t) => t.name)
              .toSet(),
          <String>{'アニメ'});
      // 本地移除后远端旧 add 不复活。
      final int tagId = await db.getOrCreateTagByName('アニメ');
      await db.removeTagFromVideoBook('video/v1', tagId);
      await db.mergeRemoteVideoTags('video/v1',
          remoteAddedAt: <String, int>{'アニメ': 10});
      expect(await db.getTagsForVideoBook('video/v1'), isEmpty);
    });
  });
}
