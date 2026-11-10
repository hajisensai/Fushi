import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_routes.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

/// 通用 host 任务协议（设计 §3.4）的路由 + 管理器契约：
/// create → upload → start → poll → result → delete，以及重启后 running→error。
class _EchoRunner implements HostJobRunner {
  _EchoRunner({this.fail = false});
  final bool fail;
  final List<Map<String, Object?>> seenParams = <Map<String, Object?>>[];

  @override
  String get kind => 'echo';

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'ready': true,
  };

  @override
  void validateParams(Map<String, Object?> params) {
    if (params['suffix'] == null) {
      throw const FormatException('suffix required');
    }
  }

  @override
  String contentTypeFor(String outputName) => 'text/plain; charset=utf-8';

  @override
  Future<HostJobOutcome> run(HostJobContext ctx) async {
    seenParams.add(ctx.params);
    if (fail) throw StateError('boom');
    ctx.onProgress(0.5, 'half');
    final String text = await ctx.input('in.txt').readAsString();
    await ctx.output('out.txt').writeAsString('$text${ctx.params['suffix']}');
    return const HostJobOutcome(
      outputs: <String, String>{'out.txt': 'out.txt'},
      primaryOutput: 'out.txt',
      message: 'echoed',
    );
  }
}

Future<shelf.Response> _call(
  HostJobManager jobs,
  String method,
  String path, {
  Object? body,
  List<int>? bytes,
}) {
  final shelf.Request request = shelf.Request(
    method,
    Uri.parse('http://h$path'),
    body: bytes ?? (body == null ? null : jsonEncode(body)),
    headers: body == null
        ? null
        : const <String, String>{'Content-Type': 'application/json'},
  );
  return handleHostJobRequest(jobs, request, method, path);
}

Future<Map<String, dynamic>> _json(shelf.Response r) async =>
    Map<String, dynamic>.from(jsonDecode(await r.readAsString()) as Map);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('host_jobs_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('create → upload → start → poll → result → delete 全链路', () async {
    final _EchoRunner runner = _EchoRunner();
    final HostJobManager jobs = HostJobManager(
      jobRoot: root,
      runners: <HostJobRunner>[runner],
    );

    final shelf.Response created = await _call(
      jobs,
      'POST',
      '/api/jobs',
      body: <String, Object?>{
        'kind': 'echo',
        'params': <String, Object?>{'suffix': '!'},
      },
    );
    expect(created.statusCode, 200);
    final String id = (await _json(created))['jobId'] as String;
    expect(id.length, 24);

    final shelf.Response up = await _call(
      jobs,
      'PUT',
      '/api/jobs/$id/input/in.txt',
      bytes: utf8.encode('hi'),
    );
    expect(up.statusCode, 200);
    expect((await _json(up))['state'], 'uploading');

    final shelf.Response started = await _call(
      jobs,
      'POST',
      '/api/jobs/$id/start',
    );
    expect(started.statusCode, 200);

    // 轮询直到终态（runner 是同步完成的，几轮内必到）。
    Map<String, dynamic> status = <String, dynamic>{};
    for (int i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      status = await _json(await _call(jobs, 'GET', '/api/jobs/$id'));
      if (status['state'] == 'done') break;
    }
    expect(status['state'], 'done');
    // 终态可见 ≠ 已落盘：DELETE 自己会等这笔落盘，这里显式等一次把契约钉住。
    await jobs.whenIdle();
    expect(status['progress'], 1);
    expect(status['message'], 'echoed');
    expect(status['outputs'], <String>['out.txt']);
    expect(status['primaryOutput'], 'out.txt');
    expect(runner.seenParams.single['suffix'], '!');

    final shelf.Response result = await _call(
      jobs,
      'GET',
      '/api/jobs/$id/result',
    );
    expect(result.statusCode, 200);
    expect(result.headers['Content-Type'], startsWith('text/plain'));
    expect(await result.readAsString(), 'hi!');
    final shelf.Response named = await _call(
      jobs,
      'GET',
      '/api/jobs/$id/result/out.txt',
    );
    expect(await named.readAsString(), 'hi!');

    // 磁盘上有记录（重启可续的依据）。
    expect(File(p.join(root.path, id, 'job.json')).existsSync(), isTrue);

    final shelf.Response deleted = await _call(jobs, 'DELETE', '/api/jobs/$id');
    expect(deleted.statusCode, 200);
    expect(Directory(p.join(root.path, id)).existsSync(), isFalse);
    expect((await _call(jobs, 'GET', '/api/jobs/$id')).statusCode, 404);
  });

  test('参数校验 400、未知 kind 400、未完成取 result 409、上传已密封 409', () async {
    final HostJobManager jobs = HostJobManager(
      jobRoot: root,
      runners: <HostJobRunner>[_EchoRunner()],
    );
    expect(
      (await _call(
        jobs,
        'POST',
        '/api/jobs',
        body: <String, Object?>{'kind': 'echo', 'params': <String, Object?>{}},
      )).statusCode,
      400,
    );
    expect(
      (await _call(
        jobs,
        'POST',
        '/api/jobs',
        body: <String, Object?>{
          'kind': 'nope',
          'params': <String, Object?>{'suffix': 1},
        },
      )).statusCode,
      400,
    );
    final String id =
        (await _json(
              await _call(
                jobs,
                'POST',
                '/api/jobs',
                body: <String, Object?>{
                  'kind': 'echo',
                  'params': <String, Object?>{'suffix': '?'},
                },
              ),
            ))['jobId']
            as String;
    final shelf.Response early = await _call(
      jobs,
      'GET',
      '/api/jobs/$id/result',
    );
    expect(early.statusCode, 409);
    expect((await _json(early))['reason'], 'not_done');
    await _call(
      jobs,
      'PUT',
      '/api/jobs/$id/input/in.txt',
      bytes: utf8.encode('x'),
    );
    await _call(jobs, 'POST', '/api/jobs/$id/start');
    for (int i = 0; i < 400 && jobs.get(id).state != HostJobState.done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    // 终态落盘还在飞时 tearDown 删作业根目录会让 rename 抛 PathNotFound。
    await jobs.whenIdle();
    final shelf.Response late = await _call(
      jobs,
      'PUT',
      '/api/jobs/$id/input/more.txt',
      bytes: utf8.encode('y'),
    );
    expect(late.statusCode, 409);
  });

  test('runner 抛异常 → error 态带 error 文本；重启后 running 降级为 error', () async {
    final HostJobManager jobs = HostJobManager(
      jobRoot: root,
      runners: <HostJobRunner>[_EchoRunner(fail: true)],
    );
    final String id =
        (await _json(
              await _call(
                jobs,
                'POST',
                '/api/jobs',
                body: <String, Object?>{
                  'kind': 'echo',
                  'params': <String, Object?>{'suffix': '!'},
                },
              ),
            ))['jobId']
            as String;
    await _call(
      jobs,
      'PUT',
      '/api/jobs/$id/input/in.txt',
      bytes: utf8.encode('x'),
    );
    await _call(jobs, 'POST', '/api/jobs/$id/start');
    Map<String, dynamic> status = <String, dynamic>{};
    for (int i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      status = await _json(await _call(jobs, 'GET', '/api/jobs/$id'));
      if (status['state'] == 'error') break;
    }
    expect(status['state'], 'error');
    await jobs.whenIdle();
    expect(status['error'], contains('boom'));

    // 伪造一条「进程死在 running」的记录，再起一个管理器读回来。
    final HostJobRecord ghost = HostJobRecord(
      id: 'ghostghostghostghostghos',
      kind: 'echo',
      params: <String, Object?>{'suffix': '!'},
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      state: HostJobState.running,
    );
    final File f = File(p.join(root.path, ghost.id, 'job.json'));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(ghost.encode());
    final HostJobManager restarted = HostJobManager(
      jobRoot: root,
      runners: <HostJobRunner>[_EchoRunner()],
    );
    await restarted.load();
    expect(restarted.get(ghost.id).state, HostJobState.error);
    expect(restarted.get(ghost.id).error, contains('restarted'));
  });

  test('输入名只留文件名段（路径穿越/分隔符被剥掉）', () {
    expect(HostJobManager.safeName('../../etc/passwd'), 'passwd');
    expect(HostJobManager.safeName(r'C:\x\y.srt'), 'y.srt');
    expect(HostJobManager.safeName('..'), 'input');
    expect(HostJobManager.safeName('a b(1).mp3'), 'a b(1).mp3');
  });

  test('capability 汇总 kinds 与每种 kind 的就绪信息', () async {
    final HostJobManager jobs = HostJobManager(
      jobRoot: root,
      runners: <HostJobRunner>[_EchoRunner()],
    );
    final Map<String, Object?> cap = await jobs.capability();
    expect(cap['kinds'], <String>['echo']);
    expect((cap['echo'] as Map)['ready'], isTrue);
  });

  // BUG-4278：TTL 不能只在进程首次触达时扫一次，被遗弃的 pending/uploading 也要回收。
  group('ttl housekeeping', () {
    late DateTime clock;

    setUp(() {
      clock = DateTime(2026, 11, 10, 12);
    });

    HostJobManager manager(List<HostJobRunner> runners) => HostJobManager(
      jobRoot: root,
      runners: runners,
      now: () => clock,
      jobTtl: const Duration(hours: 24),
    );

    Future<String> createJob(
      HostJobManager jobs, {
      String kind = 'echo',
    }) async {
      final shelf.Response r = await _call(
        jobs,
        'POST',
        '/api/jobs',
        body: <String, Object?>{
          'kind': kind,
          'params': <String, Object?>{'suffix': '!'},
        },
      );
      expect(r.statusCode, 200);
      return (await _json(r))['jobId'] as String;
    }

    Future<List<String>> listedIds(HostJobManager jobs) async {
      final shelf.Response r = await _call(jobs, 'GET', '/api/jobs');
      expect(r.statusCode, 200);
      return <String>[
        for (final Object? j in (await _json(r))['jobs'] as List)
          (j as Map)['id'] as String,
      ];
    }

    test('运行期建的终态任务过 TTL 后在下一次触达时被清掉', () async {
      final HostJobManager jobs = manager(<HostJobRunner>[_EchoRunner()]);
      expect(await listedIds(jobs), isEmpty);
      final String id = await createJob(jobs);
      await _call(
        jobs,
        'PUT',
        '/api/jobs/$id/input/in.txt',
        bytes: utf8.encode('hi'),
      );
      await _call(jobs, 'POST', '/api/jobs/$id/start');
      Map<String, dynamic> status = <String, dynamic>{};
      for (int i = 0; i < 400; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        status = await _json(await _call(jobs, 'GET', '/api/jobs/$id'));
        if (status['state'] == 'done') break;
      }
      expect(status['state'], 'done');
      await jobs.whenIdle();

      clock = clock.add(const Duration(hours: 25));
      expect(await listedIds(jobs), isNot(contains(id)));
      expect(jobs.dirFor(id).existsSync(), isFalse);
    });

    test('只上传了输入、从没 start 的遗弃任务过 TTL 后被回收', () async {
      final HostJobManager jobs = manager(<HostJobRunner>[_EchoRunner()]);
      final String id = await createJob(jobs);
      await _call(
        jobs,
        'PUT',
        '/api/jobs/$id/input/in.txt',
        bytes: utf8.encode('hi'),
      );
      clock = clock.add(const Duration(hours: 25));
      expect(await listedIds(jobs), isNot(contains(id)));
      expect(jobs.dirFor(id).existsSync(), isFalse);
    });

    test('running 任务不按 TTL 清', () async {
      final _GateRunner gate = _GateRunner();
      final HostJobManager jobs = manager(<HostJobRunner>[gate]);
      final String id = await createJob(jobs, kind: 'gate');
      await _call(jobs, 'POST', '/api/jobs/$id/start');
      await gate.entered.future;
      clock = clock.add(const Duration(hours: 25));
      expect(await listedIds(jobs), contains(id));
      expect(jobs.get(id).state, HostJobState.running);
      gate.release.complete();
      // 等任务走到终态、终态落盘完成，再让 tearDown 删作业根目录。
      for (int i = 0; i < 400 && !jobs.get(id).isTerminal; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(jobs.get(id).state, HostJobState.done);
      await jobs.whenIdle();
    });

    test('清理按 pruneInterval 节流', () async {
      final HostJobManager jobs = manager(<HostJobRunner>[_EchoRunner()]);
      expect(await listedIds(jobs), isEmpty);
      final String id = await createJob(jobs);
      final DateTime createdAt = clock;

      clock = createdAt.add(
        const Duration(hours: 24) - const Duration(minutes: 1),
      );
      expect(await listedIds(jobs), contains(id), reason: '还没过期');

      clock = clock.add(const Duration(minutes: 2));
      expect(await listedIds(jobs), contains(id), reason: '已过期，但距上次清理不足 10 分钟');

      clock = clock.add(const Duration(minutes: 10));
      expect(await listedIds(jobs), isNot(contains(id)));
    });

    test('并发的首批请求都等读盘完成', () async {
      final HostJobRecord rec = HostJobRecord(
        id: 'persistedpersistedpersis',
        kind: 'echo',
        params: <String, Object?>{'suffix': '!'},
        createdAt: clock,
        updatedAt: clock,
      );
      final File f = File(p.join(root.path, rec.id, 'job.json'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(rec.encode());

      final HostJobManager jobs = manager(<HostJobRunner>[_EchoRunner()]);
      final List<List<String>> both = await Future.wait(<Future<List<String>>>[
        listedIds(jobs),
        listedIds(jobs),
      ]);
      expect(both[0], contains(rec.id));
      expect(both[1], contains(rec.id));
    });
  });
}

/// 进 run 后挂住，直到测试放行；用来把任务钉在 running。
class _GateRunner implements HostJobRunner {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  String get kind => 'gate';

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{};

  @override
  void validateParams(Map<String, Object?> params) {}

  @override
  String contentTypeFor(String outputName) => 'application/octet-stream';

  @override
  Future<HostJobOutcome> run(HostJobContext ctx) async {
    entered.complete();
    await release.future;
    return const HostJobOutcome(outputs: <String, String>{});
  }
}
