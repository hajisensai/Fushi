import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「同一作品」视频合集卡的本地海报与视频库合集卡同一顺序：合集自有封面 →
/// （刮削作品海报）→ 成员本地封面借用。从媒体服务器加入的剧没有合集自有封面时，
/// 各集共用落盘的作品海报，卡片借它而不是画占位图。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late int collectionId;
  late MediaLinkEndpoint endpoint;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('media_link_cover_');
    collectionId = await db.createMediaCollection('Show A');
    endpoint = (
      kind: MediaLinkKind.videoCollection,
      key: collectionTagEntryKey(collectionId),
    );
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<String> touch(String name) async {
    final File f = File('${tmp.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(<int>[1, 2, 3]);
    return f.path;
  }

  Future<void> addMember(String uid, {String? coverPath}) async {
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: 'Show A $uid',
        videoPath: 'media-server://$uid/Show A $uid',
        coverPath: Value<String?>(coverPath),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, uid);
  }

  test('没有合集自有封面 → 借成员的本地封面（媒体服务器加入的剧）', () async {
    final String workPoster = await touch('media_server_work.jpg');
    await addMember('ep1', coverPath: workPoster);
    await addMember('ep2', coverPath: workPoster);

    final MediaLinkEntry entry = await resolveMediaLinkEntry(db, endpoint);

    expect(entry.coverPath, workPoster);
    expect(entry.hasRemoteMembers, isFalse);
  });

  test('合集自有封面优先于成员封面', () async {
    final String own = await touch('collection_own.jpg');
    final String member = await touch('member.jpg');
    await addMember('ep1', coverPath: member);
    await db.updateMediaCollectionCoverPath(collectionId, own);

    final MediaLinkEntry entry = await resolveMediaLinkEntry(db, endpoint);

    expect(entry.coverPath, own);
  });

  test('成员封面文件不在了 → 跳过它取下一个；都不在为 null', () async {
    final String live = await touch('ep2.jpg');
    await addMember('ep1', coverPath: '${tmp.path}/gone.jpg');
    await addMember('ep2', coverPath: live);
    expect((await resolveMediaLinkEntry(db, endpoint)).coverPath, live);

    await File(live).delete();
    expect((await resolveMediaLinkEntry(db, endpoint)).coverPath, isNull);
  });

  test('远端成员只进 remoteMemberKeys，不影响本地封面借用', () async {
    final String member = await touch('local.jpg');
    await db.addToCollection(collectionId, MediaKind.video, 'remote-1');
    await addMember('ep1', coverPath: member);

    final MediaLinkEntry entry = await resolveMediaLinkEntry(db, endpoint);

    expect(entry.coverPath, member);
    expect(entry.remoteMemberKeys, <String>['remote-1']);
  });
}
