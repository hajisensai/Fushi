import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_library_tasks.dart';
import 'package:fushi/src/ops/ctl_online_support.dart';
import 'package:fushi/src/ops/ctl_video_player_support.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

/// longRunning 操作的状态读数（spec §6.1）：真实描述 + 真实目录装配，状态路由换成
/// 内存替身（同 METHOD + pattern）。每种状态来源验「进行中 → 非终态」「完成 →
/// succeeded」「失败 → 终态且未成功」，以及 taskIdOf 能从真实结果形状里取到 id
/// （能用真实序列化函数的都用真实的：视频任务、有声书任务、小说下载任务）。

class _FakeApp implements AppModel {
  @override
  bool moduleEnabled(ModuleId module) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('状态测试不应访问 AppModel.${invocation.memberName}');
}

class _FakeRef implements WidgetRef {
  final _FakeApp app = _FakeApp();

  @override
  T read<T>(ProviderListenable<T> provider) => app as T;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('状态测试不应访问 ref.${invocation.memberName}');
}

typedef _Handler = Future<Object?> Function(CtlCall call);

class _World {
  final VideoRemoteJobRegistry videoJobs = VideoRemoteJobRegistry();
  final LibraryCtlTaskRegistry libraryTasks = LibraryCtlTaskRegistry();
  final Map<String, Map<String, Object?>> downloads =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> transcribeJobs =
      <String, Map<String, Object?>>{};
  final Map<String, CtlOnlineTask> onlineTasks = <String, CtlOnlineTask>{};
  final List<Map<String, Object?>> mangaJobs = <Map<String, Object?>>[];

  static Never _missing(String what) => throw CtlFailure.notFound(what);

  Map<String, _Handler> handlers() => <String, _Handler>{
    'GET /api/admin/video/jobs/:id': (CtlCall c) async =>
        ctlVideoJobJson(videoJobs[c.params['id']!] ?? _missing('job')),
    'GET /api/admin/downloads/:id': (CtlCall c) async =>
        downloads[c.params['id']] ?? _missing('download'),
    'GET /api/admin/library/audiobook/tasks/:id': (CtlCall c) async =>
        (libraryTasks.byId(c.params['id']!) ?? _missing('task')).toJson(),
    'GET /api/admin/library/audiobook/jobs/:id': (CtlCall c) async =>
        transcribeJobs[c.params['id']] ?? _missing('job'),
    'GET /api/admin/online/tasks/:id': (CtlCall c) async =>
        (onlineTasks[c.params['id']] ?? _missing('task')).toJson(),
    'GET /api/admin/online/manga-downloads': (CtlCall c) async =>
        <String, Object?>{
          'jobs': <Map<String, Object?>>[
            for (final Map<String, Object?> j in mangaJobs)
              if (c.optString('book') == null ||
                  j['bookKey'] == c.optString('book'))
                j,
          ],
        },
  };
}

void main() {
  late _World world;
  late OpCatalog catalog;

  setUp(() {
    world = _World();
    final OpContext context = OpContext(ref: _FakeRef());
    final Map<String, _Handler> fakes = world.handlers();
    final List<CtlRoute> routes = <CtlRoute>[
      for (final CtlRoute route in buildDomainOpRoutes(context))
        if (fakes['${route.method} ${route.pattern}'] case final _Handler fake)
          CtlRoute(route.method, route.pattern, fake)
        else
          route,
    ];
    final Set<String> registered = <String>{
      for (final CtlRoute r in routes) '${r.method} ${r.pattern}',
    };
    expect(
      fakes.keys.where((String k) => !registered.contains(k)),
      isEmpty,
      reason: '替身对应的路由必须真实存在',
    );
    catalog = buildAppOpCatalog(context, routes);
  });

  FushiOp op(String id) {
    final FushiOp op = catalog[id]!;
    expect(op.longRunning, isTrue, reason: id);
    expect(op.taskStatus, isNotNull, reason: id);
    return op;
  }

  Future<OpTaskStatus> status(String id, String taskId) =>
      op(id).taskStatus!(taskId);

  group('视频页任务（GET /api/admin/video/jobs/:id）', () {
    for (final String id in <String>[
      'video.player.subtitle.ocr',
      'video.player.subtitle.transcribe',
      'video.player.subtitle.align',
      'video.player.clip',
      'video.subtitle.generate',
    ]) {
      test('$id：running → 非终态；succeeded / failed / cancelled 各自映射', () async {
        final VideoRemoteJob job = world.videoJobs.register(
          VideoRemoteJob(kind: VideoRemoteJobKind.values.first, bookUid: 'v/1'),
        );
        // 执行结果就是 ctlVideoJobJson（顶层 id，不是 taskId / jobId）。
        expect(op(id).taskIdFrom(ctlVideoJobJson(job)), job.id);
        expect((await status(id, job.id)).terminal, isFalse);

        job.succeed(<String, Object?>{'path': '/clips/a b.mp4'});
        final OpTaskStatus ok = await status(id, job.id);
        expect(ok.terminal, isTrue);
        expect(ok.succeeded, isTrue);
        expect(ok.summary, contains('a b.mp4'));

        final VideoRemoteJob bad = world.videoJobs.register(
          VideoRemoteJob(kind: VideoRemoteJobKind.values.first, bookUid: 'v/1'),
        )..fail('asr_failed', 'model missing');
        final OpTaskStatus failed = await status(id, bad.id);
        expect(failed.terminal, isTrue);
        expect(failed.succeeded, isFalse);
        expect(failed.summary, contains('model missing'));

        final VideoRemoteJob cancelled = world.videoJobs.register(
          VideoRemoteJob(kind: VideoRemoteJobKind.values.first, bookUid: 'v/1'),
        )..fail('cancelled', 'cancelled');
        final OpTaskStatus c = await status(id, cancelled.id);
        expect(c.terminal && !c.succeeded, isTrue);
      });
    }
  });

  group('下载中心任务（GET /api/admin/downloads/:id）', () {
    const String id = 'video.discovery.acquire';

    test('入队结果顶层 jobId；active → 非终态，completed → 成功', () async {
      expect(
        op(id).taskIdFrom(<String, Object?>{'jobId': 'job-7', 'title': 'X'}),
        'job-7',
      );
      world.downloads['job-7'] = <String, Object?>{
        'jobId': 'job-7',
        'title': 'Frieren 01',
        'lifecycle': 'active',
        'stage': 'download',
      };
      expect((await status(id, 'job-7')).terminal, isFalse);
      world.downloads['job-7']!['lifecycle'] = 'completed';
      final OpTaskStatus ok = await status(id, 'job-7');
      expect(ok.terminal && ok.succeeded, isTrue);
      expect(ok.summary, contains('Frieren 01'));
    });

    test('failed / needsAttention → 终态未成功并带 lastError', () async {
      world.downloads['job-8'] = <String, Object?>{
        'jobId': 'job-8',
        'title': 'Y',
        'lifecycle': 'needsAttention',
        'lastError': 'no seeders',
      };
      final OpTaskStatus stalled = await status(id, 'job-8');
      expect(stalled.terminal, isTrue);
      expect(stalled.succeeded, isFalse);
      expect(stalled.summary, contains('no seeders'));
      world.downloads['job-8']!['lifecycle'] = 'failed';
      expect((await status(id, 'job-8')).succeeded, isFalse);
    });

    test('直链任务（direct:）：running → 非终态，done → 成功，failed → 失败', () async {
      world.downloads['direct:3'] = <String, Object?>{
        'jobId': 'direct:3',
        'title': 'Z',
        'lifecycle': 'running',
        'stage': 'direct',
      };
      expect((await status(id, 'direct:3')).terminal, isFalse);
      world.downloads['direct:3']!['lifecycle'] = 'done';
      expect((await status(id, 'direct:3')).succeeded, isTrue);
      world.downloads['direct:3']!['lifecycle'] = 'failed';
      final OpTaskStatus failed = await status(id, 'direct:3');
      expect(failed.terminal && !failed.succeeded, isTrue);
    });
  });

  group('有声书附着 / 重匹配（GET /api/admin/library/audiobook/tasks/:id）', () {
    for (final String id in <String>[
      'library.audiobook.attach',
      'library.audiobook.rematch',
    ]) {
      test('$id：真实任务 JSON 取 id；running → done / failed', () async {
        final Completer<Map<String, Object?>> gate =
            Completer<Map<String, Object?>>();
        final LibraryCtlTask task = world.libraryTasks.start(
          kind: 'attach',
          key: 'book:b1',
          run: (LibraryCtlTask t) => gate.future,
          describe: (Object e) => '$e',
        );
        expect(op(id).taskIdFrom(task.toJson()), task.id);
        expect((await status(id, task.id)).terminal, isFalse);
        gate.complete(<String, Object?>{'cues': 12});
        await task.whenDone;
        final OpTaskStatus ok = await status(id, task.id);
        expect(ok.terminal && ok.succeeded, isTrue);

        final LibraryCtlTask bad = world.libraryTasks.start(
          kind: 'rematch',
          key: 'book:b2',
          run: (LibraryCtlTask t) async => throw StateError('no cues'),
          describe: (Object e) => 'boom: $e',
        );
        await bad.whenDone;
        final OpTaskStatus failed = await status(id, bad.id);
        expect(failed.terminal, isTrue);
        expect(failed.succeeded, isFalse);
        expect(failed.summary, contains('boom'));
      });
    }
  });

  group('有声书转录（GET /api/admin/library/audiobook/jobs/:id）', () {
    const String id = 'library.audiobook.transcribe';

    test('queued / running → 非终态；done → 成功；failed → 失败', () async {
      expect(
        op(id).taskIdFrom(<String, Object?>{'id': 'tj1', 'status': 'queued'}),
        'tj1',
      );
      world.transcribeJobs['tj1'] = <String, Object?>{
        'id': 'tj1',
        'title': 'Book',
        'status': 'queued',
      };
      expect((await status(id, 'tj1')).terminal, isFalse);
      world.transcribeJobs['tj1']!['status'] = 'running';
      expect((await status(id, 'tj1')).terminal, isFalse);
      world.transcribeJobs['tj1']!
        ..['status'] = 'done'
        ..['resultKey'] = 'srt:42';
      final OpTaskStatus ok = await status(id, 'tj1');
      expect(ok.terminal && ok.succeeded, isTrue);
      expect(ok.summary, contains('srt:42'));
      world.transcribeJobs['tj1']!
        ..['status'] = 'failed'
        ..['error'] = 'decoder crashed';
      final OpTaskStatus failed = await status(id, 'tj1');
      expect(failed.terminal && !failed.succeeded, isTrue);
      expect(failed.summary, contains('decoder crashed'));
    });
  });

  group('在线源下载（online.source.download）', () {
    const String id = 'online.source.download';

    test('novel：真实任务 JSON → novel:<id>；running / done / failed', () async {
      final CtlOnlineTask task = CtlOnlineTask(
        id: 't1',
        kind: 'novel',
        title: 'Novel',
        total: 10,
        createdAt: 0,
      );
      world.onlineTasks['t1'] = task;
      final String? taskId = op(id).taskIdFrom(task.toJson());
      expect(taskId, 'novel:t1');
      expect((await status(id, taskId!)).terminal, isFalse);
      task
        ..status = 'done'
        ..done = 10;
      final OpTaskStatus ok = await status(id, taskId);
      expect(ok.terminal && ok.succeeded, isTrue);
      expect(ok.summary, contains('10/10'));
      task
        ..status = 'failed'
        ..error = 'site down';
      final OpTaskStatus failed = await status(id, taskId);
      expect(failed.terminal && !failed.succeeded, isTrue);
      expect(failed.summary, contains('site down'));
    });

    test('manga：按这本书最近入队的 queued 个任务汇总，旧任务不算', () async {
      world.mangaJobs.add(<String, Object?>{
        'id': 'old',
        'bookKey': 'm1',
        'status': 'failed',
        'createdAt': 1,
      });
      final String? taskId = op(id).taskIdFrom(<String, Object?>{
        'kind': 'manga',
        'bookKey': 'm1',
        'title': 'Manga',
        'queued': 2,
        'lockedSkipped': 0,
      });
      expect(taskId, 'manga:2:m1');
      for (final String j in <String>['j1', 'j2']) {
        world.mangaJobs.add(<String, Object?>{
          'id': j,
          'bookKey': 'm1',
          'chapter': 'Ch $j',
          'status': 'queued',
          'createdAt': 10,
        });
      }
      expect((await status(id, taskId!)).terminal, isFalse);
      world.mangaJobs[1]['status'] = 'done';
      world.mangaJobs[2]['status'] = 'running';
      expect((await status(id, taskId)).terminal, isFalse);
      world.mangaJobs[2]['status'] = 'done';
      final OpTaskStatus ok = await status(id, taskId);
      expect(ok.terminal && ok.succeeded, isTrue, reason: '旧的失败任务不属于这批');
      world.mangaJobs[2]
        ..['status'] = 'failed'
        ..['error'] = 'HTTP 403';
      final OpTaskStatus failed = await status(id, taskId);
      expect(failed.terminal && !failed.succeeded, isTrue);
      expect(failed.summary, contains('HTTP 403'));
    });

    test('manga 全部被锁跳过（queued=0）/ anime 剧集 → 不追踪', () {
      expect(
        op(id).taskIdFrom(<String, Object?>{
          'kind': 'manga',
          'bookKey': 'm1',
          'queued': 0,
        }),
        isNull,
      );
      expect(
        op(id).taskIdFrom(<String, Object?>{
          'kind': 'anime',
          'queued': 2,
          'taskIds': <String>['e1', 'e2'],
        }),
        isNull,
      );
    });
  });
}
