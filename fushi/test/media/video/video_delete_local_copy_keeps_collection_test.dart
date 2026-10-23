// 反馈 _sZllpFQWm / BUG-3666：删掉一集「从配对设备下载到本机的副本」。
//
// 落地是媒体库删除链（删行 + 删下载下来的文件），但合集成员行必须留着：成员行的
// entryKey 就是对端 id，留着它这一集退回远端集（可再流播 / 再下载）；按默认把它
// 从合集里摘掉，这一集会从详情页整个消失，合集只剩它时还会被连带自删。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory dir;
  late int collectionId;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    dir = Directory.systemTemp.createTempSync('fushi_local_copy');
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<File> insertDownloadedCopy(String uid) async {
    final File file = File('${dir.path}/$uid.mkv')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(uid),
        videoPath: Value<String>(file.path),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, uid);
    return file;
  }

  test('removeFromCollections: false 删行 + 删文件，但成员行留着、这一集退回远端集', () async {
    final File copy = await insertDownloadedCopy('e1');
    await insertDownloadedCopy('e2');

    final VideoLibraryDeleteResult result = await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: <String>['e1'],
      decision: const DeleteDecision(
        scope: DeleteScope.keepLocalOnly,
        deleteLocalFiles: true,
      ),
      removeFromCollections: false,
      compactDatabase: false,
    );

    expect(result.deleted, 1);
    expect(await repo.getByBookUid('e1'), isNull);
    expect(copy.existsSync(), isFalse, reason: '下载下来的文件一并删掉');
    expect(
      (await repo.getCollectionItems(
        collectionId,
      )).map((MediaCollectionItemRow item) => item.entryKey).toList(),
      <String>['e1', 'e2'],
      reason: '成员行留着，顺序不变',
    );
    final List<CollectionEpisodeSlot> slots = await loadCollectionEpisodeSlots(
      repository: repo,
      collectionId: collectionId,
      loadRemoteVideos: () async => <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'e1', title: 'e1'),
      ],
    );
    expect(
      slots.map((CollectionEpisodeSlot s) => (s.entryKey, s.isRemote)).toList(),
      <(String, bool)>[('e1', true), ('e2', false)],
      reason: '删掉本机副本后这一集回到对端那份',
    );
  });

  test('默认（普通删除）仍把它从合集里摘掉，合集清空时随之自删', () async {
    await insertDownloadedCopy('only');

    await deleteVideoBooksWithDecision(
      repo: repo,
      database: db,
      pipeline: null,
      bookUids: <String>['only'],
      decision: const DeleteDecision(scope: DeleteScope.keepLocalOnly),
      compactDatabase: false,
    );

    expect(await db.getMediaCollectionById(collectionId), isNull);
  });
}
