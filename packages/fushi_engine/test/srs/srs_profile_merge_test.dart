// 续做迁移带过来的半截并入（G9-5，srs_profile_merge.dart）：主库改指新 uid 在内核收尾之前、媒体先拷后删、失败留着
// 标记可以重跑；新代不再发起协议 3 式的 uid 并入。
//
// 内核那一半（`profile_merge_commit` 把旧集合并进新集合）在 Rust 侧经 C ABI 测
// （native/fushi_fsrs/src/store/gen4/prepare_tests.rs `a_half_done_merge_*`）；这里只测 Dart 的顺序与主库 / 媒体。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_profile_data.dart'
    show SrsProfileMergeFinish;
import 'package:fushi_engine/srs/srs_profile_merge.dart';
import 'package:test/test.dart';

const String _kNewUid = '0193a1b2-0000-7000-8000-00000000cafe';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase db;
  late int profileId;
  late String oldUid;
  late Directory media;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int now = DateTime.now().millisecondsSinceEpoch;
    profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    oldUid = await db.profileUidOf(profileId);
    media = Directory.systemTemp.createTempSync('fushi_srs_merge_media_');
    addTearDown(() => media.deleteSync(recursive: true));
    Directory('${media.path}/$oldUid').createSync();
    File('${media.path}/$oldUid/a.png').writeAsStringSync('old-a');
    File('${media.path}/$oldUid/b.png').writeAsStringSync('old-b');
    Directory('${media.path}/$_kNewUid').createSync();
    File('${media.path}/$_kNewUid/b.png').writeAsStringSync('new-b');
  });

  const SrsProfileMergeFinish folded = (folded: true, outcome: 'joined');

  test('主库还指着旧 uid：先拷媒体、改主库，再发收尾；收尾之后删旧媒体目录', () async {
    final List<String> seen = <String>[];
    final SrsProfileMergeFinish r = await srsResumeProfileMerge(
      db,
      profileId: profileId,
      oldUid: oldUid,
      newUid: _kNewUid,
      mediaRoot: media,
      commit: () async {
        // 收尾发出时：主库已经是新 uid、媒体已经在新 uid 下、旧目录还在（收尾失败还能重跑）。
        seen.add(await db.profileUidOf(profileId));
        expect(File('${media.path}/$_kNewUid/a.png').existsSync(), isTrue);
        expect(Directory('${media.path}/$oldUid').existsSync(), isTrue);
        return folded;
      },
    );
    expect(r, folded);
    expect(seen, <String>[_kNewUid]);
    expect(await db.profileUidOf(profileId), _kNewUid);
    expect(
      File('${media.path}/$_kNewUid/b.png').readAsStringSync(),
      'new-b',
      reason: '内容寻址：同名不覆盖',
    );
    expect(Directory('${media.path}/$oldUid').existsSync(), isFalse);
  });

  test('收尾失败：主库留在新 uid、旧媒体目录留着；同样的参数重跑只做收尾', () async {
    await expectLater(
      srsResumeProfileMerge(
        db,
        profileId: profileId,
        oldUid: oldUid,
        newUid: _kNewUid,
        mediaRoot: media,
        commit: () async => throw StateError('kernel said no'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await db.profileUidOf(profileId), _kNewUid);
    expect(Directory('${media.path}/$oldUid').existsSync(), isTrue);

    int commits = 0;
    final SrsProfileMergeFinish r = await srsResumeProfileMerge(
      db,
      profileId: profileId,
      oldUid: oldUid,
      newUid: _kNewUid,
      mediaRoot: media,
      commit: () async {
        commits++;
        return (folded: false, outcome: null);
      },
    );
    expect(r.folded, isFalse);
    expect(commits, 1);
    expect(await db.profileUidOf(profileId), _kNewUid);
    expect(Directory('${media.path}/$oldUid').existsSync(), isFalse);
  });

  test('主库既不是旧 uid 也不是新 uid：报错，不发收尾、不动主库', () async {
    bool committed = false;
    await expectLater(
      srsResumeProfileMerge(
        db,
        profileId: profileId,
        oldUid: '0193a1b2-0000-7000-8000-00000000d00d',
        newUid: _kNewUid,
        commit: () async {
          committed = true;
          return folded;
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(committed, isFalse);
    expect(await db.profileUidOf(profileId), oldUid);
  });

  test('新 uid 已是本机另一个 profile：报错，不发收尾、不动主库与媒体', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int other = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Other', createdAt: now, updatedAt: now),
    );
    await db.adoptProfileUid(other, _kNewUid);
    bool committed = false;
    await expectLater(
      srsResumeProfileMerge(
        db,
        profileId: profileId,
        oldUid: oldUid,
        newUid: _kNewUid,
        mediaRoot: media,
        commit: () async {
          committed = true;
          return folded;
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(committed, isFalse);
    expect(await db.profileUidOf(profileId), oldUid);
    expect(File('${media.path}/$_kNewUid/a.png').existsSync(), isFalse);
  });
}
