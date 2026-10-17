import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';

/// 「删除已完成剧集成品」从 widget 抽出后的可调用入口：下载页与
/// `fushi_cli source anime-dl rm --delete-files` 共用 [deleteCompletedInterconnectDownloadFiles]。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late InterconnectDownloadManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ic_done_del_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    manager = InterconnectDownloadManager();
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<InterconnectDownloadTask> completed(
    String id,
    InterconnectDownloadOrigin origin,
  ) async {
    await manager.startVideoDownload(
      id: id,
      title: id,
      dest: File('${tmp.path}/$id.mp4'),
      origin: origin,
      run:
          (
            File dest, {
            void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal,
          }) async => dest.writeAsBytesSync(<int>[1, 2, 3]),
    );
    return manager.taskFor(id)!;
  }

  test('判据：只有已完成、知道落点的扩展源视频可连文件删除', () async {
    final InterconnectDownloadTask ext = await completed(
      'ep1',
      InterconnectDownloadOrigin.extension,
    );
    final InterconnectDownloadTask own = await completed(
      'ep2',
      InterconnectDownloadOrigin.ownDevice,
    );
    expect(ext.status, InterconnectDownloadStatus.completed);
    expect(canDeleteCompletedDownloadFiles(ext), isTrue);
    expect(canDeleteCompletedDownloadFiles(own), isFalse);
  });

  test('库里没有行指向成品：先放句柄再删文件，删掉才移出任务记录', () async {
    final InterconnectDownloadTask task = await completed(
      'ep1',
      InterconnectDownloadOrigin.extension,
    );
    final String path = task.destPath!;
    expect(File(path).existsSync(), isTrue);
    final List<String> released = <String>[];
    VideoLibraryDeleteResult? reported;

    final bool done = await deleteCompletedInterconnectDownloadFiles(
      database: db,
      pipeline: null,
      manager: manager,
      task: task,
      report: (VideoLibraryDeleteResult r) => reported = r,
      releaseHandles: (List<String> paths) async => released.addAll(paths),
    );

    expect(done, isTrue);
    expect(released, <String>[path]);
    expect(File(path).existsSync(), isFalse);
    expect(reported, isNotNull);
    expect(reported!.deleted, 0, reason: '没有库行可删');
    expect(reported!.localFiles.failures, isEmpty);
    expect(manager.taskFor('ep1'), isNull);
  });

  test('不满足判据抛 ArgumentError，什么都不删', () async {
    final InterconnectDownloadTask own = await completed(
      'ep2',
      InterconnectDownloadOrigin.ownDevice,
    );
    await expectLater(
      deleteCompletedInterconnectDownloadFiles(
        database: db,
        pipeline: null,
        manager: manager,
        task: own,
        report: (VideoLibraryDeleteResult _) => fail('不应走到删除'),
        releaseHandles: (List<String> _) async => fail('不应放句柄'),
      ),
      throwsArgumentError,
    );
    expect(File('${tmp.path}/ep2.mp4').existsSync(), isTrue);
    expect(manager.taskFor('ep2'), isNotNull);
  });
}
