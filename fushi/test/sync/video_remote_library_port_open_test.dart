import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi/src/sync/video_remote_library_port.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:material_ui/material_ui.dart';

/// 点播的电脑侧打开流程：一切「这次打不开」的判断都必须排在
/// [ExternalMediaNavigation.closeActive] 之前——打不开就不能先把电脑上正在放的
/// 视频关掉。
void main() {
  late FushiDatabase db;
  late Directory tmp;
  late int closeCalls;
  late bool readonly;
  late VideoRemoteLibrary library;
  final Object owner = Object();

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('fushi_remote_open_');
    closeCalls = 0;
    readonly = false;
    ExternalMediaNavigation.instance.register(owner, () async {
      closeCalls++;
      return true;
    }, videoUid: () => 'video/playing');
    library = createVideoRemoteLibrary(
      database: () => db,
      navigatorKey: GlobalKey<NavigatorState>(),
      stopAudiobook: () async {},
      isMigrationReadonly: () => readonly,
    );
  });

  tearDown(() async {
    ExternalMediaNavigation.instance.unregister(owner);
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> addVideo(String uid, String path) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(uid),
      videoPath: Value<String>(path),
    ),
  );

  Future<VideoRemoteException> openFailure(String uid) async {
    try {
      await library.open(uid);
    } on VideoRemoteException catch (error) {
      return error;
    }
    fail('open($uid) should have failed');
  }

  // navigatorKey 没挂 Navigator：判据若排到取 navigator 之后，会先回 host_busy。
  test('视频文件已缺失：回 video_missing，不关正在放的视频', () async {
    await addVideo('video/gone', '${tmp.path}/gone.mkv');

    final VideoRemoteException error = await openFailure('video/gone');

    expect(error.status, 404);
    expect(error.code, 'video_missing');
    expect(closeCalls, 0);
  });

  test('库里没有这一行：回 video_missing，不关正在放的视频', () async {
    final VideoRemoteException error = await openFailure('video/unknown');

    expect(error.code, 'video_missing');
    expect(closeCalls, 0);
  });

  test('迁移只读期间：先于一切查库回 host_busy，不关正在放的视频', () async {
    // 用库里没有的 uid：只读判据排在最前时回 host_busy，排在查库之后会回
    // video_missing——两种顺序在这里可区分。
    readonly = true;

    final VideoRemoteException error = await openFailure('video/unknown');

    expect(error.status, 409);
    expect(error.code, 'host_busy');
    expect(closeCalls, 0);
  });
}
