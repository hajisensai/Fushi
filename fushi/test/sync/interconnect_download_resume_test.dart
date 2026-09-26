import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show remoteVideoDownloadFileName;
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/interconnect_video_resume_store.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// BUG-2714：手机从电脑拉视频（互联下载）——切屏被杀后任务整张消失、`.part` 成孤儿；
/// 进度只在库页封面角上有一个圆环，下载中心看不到；同名视频共用同一个 `.part`。
///
/// 这里钉的是管理器 / 续传清单 / 下载中心映射 / 落点命名四层契约。传输层
/// （Range + If-Range + 中止保 part）的真 host 用例在
/// `interconnect_video_download_resume_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocale(AppLocale.en);

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fushi-ic-resume');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  File dest(String name) => File('${dir.path}/$name');

  InterconnectVideoResumeRecord recordFor(File file, {String id = 'v1'}) =>
      InterconnectVideoResumeRecord(
        videoId: id,
        title: 'Title $id',
        sourceId: 'interconnect',
        destPath: file.path,
      );

  /// 一个会写 part、报字节、听中止信号的假传输原语：每次调用从 part 已有长度
  /// 接着写，每写一块报一次字节；[blockAt] 字节处停下等 [release]。
  InterconnectVideoDownloadRunner fakeTransfer({
    required int total,
    int chunk = 10,
    int? blockAt,
    Completer<void>? release,
    List<int>? startOffsets,
  }) {
    return (
      File target, {
      void Function(double progress)? onProgress,
      void Function(int received, int? total)? onBytes,
      Future<void>? cancelSignal,
    }) async {
      final File part = File('${target.path}.part');
      int received = await part.exists() ? await part.length() : 0;
      startOffsets?.add(received);
      bool cancelled = false;
      unawaited(cancelSignal?.then((_) => cancelled = true));
      onBytes?.call(received, total);
      while (received < total) {
        if (blockAt != null && received >= blockAt && release != null) {
          await Future.any(<Future<void>>[
            release.future,
            if (cancelSignal != null) cancelSignal,
          ]);
        }
        if (cancelled) throw const RemoteDownloadCancelled();
        final int n = (total - received).clamp(0, chunk);
        await part.writeAsBytes(List<int>.filled(n, 7), mode: FileMode.append);
        received += n;
        onBytes?.call(received, total);
        await Future<void>.delayed(Duration.zero);
      }
      await part.rename(target.path);
    };
  }

  group('暂停 / 继续', () {
    test('暂停保留 part、任务停在 paused；继续从已下字节接上并完成', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final File file = dest('a.mp4');
      final Completer<void> release = Completer<void>();
      final List<int> offsets = <int>[];
      final InterconnectVideoDownloadRunner run = fakeTransfer(
        total: 100,
        blockAt: 40,
        release: release,
        startOffsets: offsets,
      );
      int completions = 0;

      final Future<InterconnectDownloadTask> first = manager.startVideoDownload(
        id: 'v1',
        title: 'Title v1',
        dest: file,
        run: run,
        onComplete: (File _) async => completions++,
        resumeRecord: recordFor(file),
      );
      // 等传输停在 40 字节处。
      while ((manager.taskFor('v1')?.receivedBytes ?? 0) < 40) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(manager.canPause('v1'), isTrue);
      manager.pause('v1');
      await expectLater(first, throwsA(isA<RemoteDownloadCancelled>()));

      final InterconnectDownloadTask paused = manager.taskFor('v1')!;
      expect(paused.status, InterconnectDownloadStatus.paused);
      expect(paused.receivedBytes, 40);
      expect(paused.totalBytes, 100);
      expect(paused.progress, closeTo(0.4, 1e-9));
      expect(await File('${file.path}.part').length(), 40);
      await manager.flushResumeManifests();
      final InterconnectVideoResumeRecord? manifest =
          await InterconnectVideoResumeStore.read(file.path);
      expect(manifest?.paused, isTrue, reason: '暂停必须落进清单，重启后不自动续');
      expect(manifest?.totalBytes, 100);

      release.complete();
      await manager.resume('v1');
      expect(offsets, <int>[0, 40], reason: '继续必须从 part 已有长度接着下，不是从 0');
      expect(
          manager.taskFor('v1')!.status, InterconnectDownloadStatus.completed);
      expect(completions, 1);
      await manager.flushResumeManifests();
      expect(await file.length(), 100);
      expect(await InterconnectVideoResumeStore.read(file.path), isNull,
          reason: '完成后清单删掉，不再被扫描出来');
    });

    test('书任务不可暂停（传输原语不认中止信号）', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final Future<void> running = manager.startBookDownload(
        downloadId: 'b1',
        title: 'Book',
        dest: dest('b.epub'),
        run: (File target, {void Function(double progress)? onProgress}) =>
            gate.future,
      );
      final String id = InterconnectDownloadManager.bookTaskId('b1');
      expect(manager.isRunning(id), isTrue);
      expect(manager.canPause(id), isFalse);
      manager.pause(id);
      expect(manager.isRunning(id), isTrue);
      gate.complete();
      await running;
    });

    test('失败后可在下载中心重试（同一份原语），暂停中的任务不被结束态淘汰', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      int calls = 0;
      await expectLater(
        manager.startVideoDownload(
          id: 'v1',
          title: 'Title v1',
          dest: dest('f.mp4'),
          run: (
            File target, {
            void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal,
          }) async {
            calls++;
            if (calls == 1) throw const SocketException('peer offline');
          },
        ),
        throwsA(isA<SocketException>()),
      );
      expect(manager.taskFor('v1')!.status, InterconnectDownloadStatus.failed);
      expect(manager.canRestart('v1'), isTrue);
      await manager.resume('v1');
      expect(calls, 2);
      expect(
          manager.taskFor('v1')!.status, InterconnectDownloadStatus.completed);
      expect(manager.canRestart('v1'), isFalse);
    });
  });

  group('续传清单', () {
    test('被杀前写下的清单能扫出来；part 丢了 / 成品已在的孤儿清单被清掉', () async {
      final File live = dest('live.mp4');
      await File('${live.path}.part').writeAsBytes(<int>[1, 2, 3]);
      await InterconnectVideoResumeStore.write(recordFor(live, id: 'live'));

      final File noPart = dest('nopart.mp4');
      await InterconnectVideoResumeStore.write(recordFor(noPart, id: 'np'));

      final File done = dest('done.mp4');
      await File('${done.path}.part').writeAsBytes(<int>[1]);
      await done.writeAsBytes(<int>[1, 2]);
      await InterconnectVideoResumeStore.write(recordFor(done, id: 'done'));

      await File('${dir.path}/junk.mp4.resume.json').writeAsString('{oops');

      final List<InterconnectVideoResumeRecord> records =
          await InterconnectVideoResumeStore.scan(dir);
      expect(records.map((InterconnectVideoResumeRecord r) => r.videoId),
          <String>['live']);
      expect(InterconnectVideoResumeStore.manifestFor(noPart.path).existsSync(),
          isFalse);
      expect(InterconnectVideoResumeStore.manifestFor(done.path).existsSync(),
          isFalse);
      expect(File('${dir.path}/junk.mp4.resume.json').existsSync(), isFalse);
    });

    test('进程被杀（run 永不返回）时清单已在盘上、且不是暂停态', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final File file = dest('k.mp4');
      final Completer<void> never = Completer<void>();
      unawaited(manager
          .startVideoDownload(
            id: 'v1',
            title: 'Title v1',
            dest: file,
            run: (
              File target, {
              void Function(double progress)? onProgress,
              void Function(int received, int? total)? onBytes,
              Future<void>? cancelSignal,
            }) async {
              await File('${target.path}.part').writeAsBytes(<int>[1]);
              await never.future;
            },
            resumeRecord: recordFor(file),
          )
          .catchError((Object _) => manager.taskFor('v1')!));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await manager.flushResumeManifests();
      final List<InterconnectVideoResumeRecord> records =
          await InterconnectVideoResumeStore.scan(dir);
      expect(records, hasLength(1));
      expect(records.single.paused, isFalse, reason: '非暂停的中断任务下次要自动续');
      expect(records.single.sourceId, 'interconnect');
    });

    test('以暂停态登记（重启后接回用户暂停过的任务）→ 继续即续传', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final File file = dest('p.mp4');
      await File('${file.path}.part').writeAsBytes(List<int>.filled(30, 1));
      final List<int> offsets = <int>[];
      manager.registerPausedVideoDownload(
        id: 'v1',
        title: 'Title v1',
        dest: file,
        run: fakeTransfer(total: 60, startOffsets: offsets),
        resumeRecord: recordFor(file).copyWith(paused: true),
        receivedBytes: 30,
        totalBytes: 60,
      );
      final InterconnectDownloadTask task = manager.taskFor('v1')!;
      expect(task.status, InterconnectDownloadStatus.paused);
      expect(task.progress, closeTo(0.5, 1e-9));
      await manager.resume('v1');
      expect(offsets, <int>[30]);
      expect(await file.length(), 60);
    });
  });

  group('下载中心条目', () {
    test('下载中给「已收 / 总 (百分比)」，暂停给继续与删除，完成只给移出', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final File file = dest('c.mp4');
      final Completer<void> release = Completer<void>();
      final Future<void> running = manager
          .startVideoDownload(
            id: 'v1',
            title: 'Title v1',
            dest: file,
            run: fakeTransfer(
              total: 2 * 1024 * 1024,
              chunk: 512 * 1024,
              blockAt: 1024 * 1024,
              release: release,
            ),
            resumeRecord: recordFor(file),
          )
          .then((_) {}, onError: (Object _) {});
      while ((manager.taskFor('v1')?.receivedBytes ?? 0) < 1024 * 1024) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      DownloadTaskEntry entry =
          interconnectDownloadTaskEntry(manager, manager.taskFor('v1')!);
      expect(entry.status, DownloadTaskStatus.active);
      expect(entry.kind, DownloadTaskKind.video);
      expect(entry.actions.pause, isNotNull);
      expect(entry.actions.resume, isNull);
      expect(interconnectDownloadStatusLabel(manager.taskFor('v1')!),
          '${t.download_task_status_downloading} · 1.0 MiB / 2.0 MiB (50%)');

      await entry.actions.pause!();
      await running;
      entry = interconnectDownloadTaskEntry(manager, manager.taskFor('v1')!);
      expect(entry.status, DownloadTaskStatus.paused);
      expect(entry.actions.resume, isNotNull);
      expect(entry.actions.delete, isNotNull);
      expect(entry.actions.deletesFiles, isTrue);
      expect(entry.actions.pause, isNull);

      release.complete();
      await entry.actions.resume!();
      entry = interconnectDownloadTaskEntry(manager, manager.taskFor('v1')!);
      expect(entry.status, DownloadTaskStatus.completed);
      expect(entry.actions.clear, isNotNull);
      expect(entry.actions.delete, isNull);
    });

    test('删除暂停任务并勾选删文件：part 与清单一起删', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final File file = dest('d.mp4');
      await File('${file.path}.part').writeAsBytes(<int>[1, 2]);
      await InterconnectVideoResumeStore.write(
          recordFor(file).copyWith(paused: true));
      manager.registerPausedVideoDownload(
        id: 'v1',
        title: 'Title v1',
        dest: file,
        run: fakeTransfer(total: 10),
        resumeRecord: recordFor(file).copyWith(paused: true),
      );
      final DownloadTaskEntry entry =
          interconnectDownloadTaskEntry(manager, manager.taskFor('v1')!);
      await entry.actions.delete!(deleteFiles: true);
      expect(manager.taskFor('v1'), isNull);
      expect(File('${file.path}.part').existsSync(), isFalse);
      expect(InterconnectVideoResumeStore.manifestFor(file.path).existsSync(),
          isFalse);
    });
  });

  group('落点命名', () {
    RemoteVideoInfo info(String id, String title) =>
        RemoteVideoInfo(id: id, title: title);

    test('同名不同 id 的两条视频落点不同（不再共用一个 .part）', () {
      final String a = remoteVideoDownloadFileName(info('show-a/ep1', '第1話'));
      final String b = remoteVideoDownloadFileName(info('show-b/ep1', '第1話'));
      expect(a, isNot(b));
      expect(a, startsWith('第1話.'));
      expect(a, endsWith('.mp4'));
    });

    test('同一 id 落点稳定（续传依赖它），标题里的非法字符被替换', () {
      final RemoteVideoInfo v = info('x', 'a:b?.mp4');
      expect(remoteVideoDownloadFileName(v), remoteVideoDownloadFileName(v));
      expect(remoteVideoDownloadFileName(v), isNot(contains(':')));
      expect(remoteVideoDownloadFileName(v), isNot(contains('.mp4.')));
    });
  });

  group('Android 保活', () {
    test('有任务在跑就挂前台服务，全部结束后撤掉', () async {
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final InterconnectDownloadManager manager =
          InterconnectDownloadManager(keepAlive: keepAlive);
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final Future<void> running = manager.startVideoDownload(
        id: 'v1',
        title: 'Title v1',
        dest: dest('k.mp4'),
        run: (
          File target, {
          void Function(double progress)? onProgress,
          void Function(int received, int? total)? onBytes,
          Future<void>? cancelSignal,
        }) async {
          onBytes?.call(25, 100);
          await gate.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(keepAlive.updates, isNotEmpty);
      expect(keepAlive.updates.last.title, 'Title v1');
      expect(keepAlive.updates.last.percent, 25);
      expect(keepAlive.stops, 0);
      gate.complete();
      await running;
      expect(keepAlive.stops, 1);
    });

    test('整批串行下载：成员之间不撤前台服务，整批结束才撤', () async {
      // 成员之间若撤了服务，app 已在后台时 Android 12+ 不允许再拉起，后续成员
      // 全程没有保活。
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final InterconnectDownloadManager manager =
          InterconnectDownloadManager(keepAlive: keepAlive);
      addTearDown(manager.dispose);
      final List<int> stopsBeforeMember = <int>[];
      Future<void> Function() member(String id) => () async {
            stopsBeforeMember.add(keepAlive.stops);
            await manager.startVideoDownload(
              id: id,
              title: 'Title $id',
              dest: dest('$id.mp4'),
              run: (
                File target, {
                void Function(double progress)? onProgress,
                void Function(int received, int? total)? onBytes,
                Future<void>? cancelSignal,
              }) async {
                onBytes?.call(50, 100);
              },
            );
          };
      await manager.startBatch(
        id: 'batch',
        title: 'Batch',
        starters: <Future<void> Function()>[
          member('b1'),
          member('b2'),
          member('b3'),
        ],
      );
      expect(stopsBeforeMember, <int>[0, 0, 0],
          reason: '任何一个成员起跑前都不该已经撤过服务');
      expect(keepAlive.stops, 1, reason: '整批结束后撤一次');
    });
  });
}

class _RecordingKeepAlive implements DownloadKeepAlive {
  final List<({String title, String text, int? percent})> updates =
      <({String title, String text, int? percent})>[];
  int stops = 0;

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    updates.add((title: title, text: text, percent: percent));
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}
