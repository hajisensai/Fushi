import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  Future<Map<String, Object?>> capability() async => <String, Object?>{'ready': true};

  @override
  void validateParams(Map<String, Object?> params) {
    if (params['suffix'] == null) throw const FormatException('suffix required');
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
    headers: body == null ? null : const <String, String>{'Content-Type': 'application/json'},
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
    final HostJobManager jobs = HostJobManager(jobRoot: root, runners: <HostJobRunner>[runner]);

    final shelf.Response created = await _call(jobs, 'POST', '/api/jobs',
        body: <String, Object?>{'kind': 'echo', 'params': <String, Object?>{'suffix': '!'}});
    expect(created.statusCode, 200);
    final String id = (await _json(created))['jobId'] as String;
    expect(id.length, 24);

    final shelf.Response up = await _call(jobs, 'PUT', '/api/jobs/$id/input/in.txt',
        bytes: utf8.encode('hi'));
    expect(up.statusCode, 200);
    expect((await _json(up))['state'], 'uploading');

    final shelf.Response started = await _call(jobs, 'POST', '/api/jobs/$id/start');
    expect(started.statusCode, 200);

    // 轮询直到终态（runner 是同步完成的，几轮内必到）。
    Map<String, dynamic> status = <String, dynamic>{};
    for (int i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      status = await _json(await _call(jobs, 'GET', '/api/jobs/$id'));
      if (status['state'] == 'done') break;
    }
    expect(status['state'], 'done');
    expect(status['progress'], 1);
    expect(status['message'], 'echoed');
    expect(status['outputs'], <String>['out.txt']);
    expect(status['primaryOutput'], 'out.txt');
    expect(runner.seenParams.single['suffix'], '!');

    final shelf.Response result = await _call(jobs, 'GET', '/api/jobs/$id/result');
    expect(result.statusCode, 200);
    expect(result.headers['Content-Type'], startsWith('text/plain'));
    expect(await result.readAsString(), 'hi!');
    final shelf.Response named = await _call(jobs, 'GET', '/api/jobs/$id/result/out.txt');
    expect(await named.readAsString(), 'hi!');

    // 磁盘上有记录（重启可续的依据）。
    expect(File(p.join(root.path, id, 'job.json')).existsSync(), isTrue);

    final shelf.Response deleted = await _call(jobs, 'DELETE', '/api/jobs/$id');
    expect(deleted.statusCode, 200);
    expect(Directory(p.join(root.path, id)).existsSync(), isFalse);
    expect((await _call(jobs, 'GET', '/api/jobs/$id')).statusCode, 404);
  });

  test('参数校验 400、未知 kind 400、未完成取 result 409、上传已密封 409', () async {
    final HostJobManager jobs =
        HostJobManager(jobRoot: root, runners: <HostJobRunner>[_EchoRunner()]);
    expect(
        (await _call(jobs, 'POST', '/api/jobs',
                body: <String, Object?>{'kind': 'echo', 'params': <String, Object?>{}}))
            .statusCode,
        400);
    expect(
        (await _call(jobs, 'POST', '/api/jobs',
                body: <String, Object?>{'kind': 'nope', 'params': <String, Object?>{'suffix': 1}}))
            .statusCode,
        400);
    final String id = (await _json(await _call(jobs, 'POST', '/api/jobs',
        body: <String, Object?>{'kind': 'echo', 'params': <String, Object?>{'suffix': '?'}})))['jobId'] as String;
    final shelf.Response early = await _call(jobs, 'GET', '/api/jobs/$id/result');
    expect(early.statusCode, 409);
    expect((await _json(early))['reason'], 'not_done');
    await _call(jobs, 'PUT', '/api/jobs/$id/input/in.txt', bytes: utf8.encode('x'));
    await _call(jobs, 'POST', '/api/jobs/$id/start');
    for (int i = 0; i < 400 && jobs.get(id).state != HostJobState.done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final shelf.Response late =
        await _call(jobs, 'PUT', '/api/jobs/$id/input/more.txt', bytes: utf8.encode('y'));
    expect(late.statusCode, 409);
  });

  test('runner 抛异常 → error 态带 error 文本；重启后 running 降级为 error', () async {
    final HostJobManager jobs =
        HostJobManager(jobRoot: root, runners: <HostJobRunner>[_EchoRunner(fail: true)]);
    final String id = (await _json(await _call(jobs, 'POST', '/api/jobs',
        body: <String, Object?>{'kind': 'echo', 'params': <String, Object?>{'suffix': '!'}})))['jobId'] as String;
    await _call(jobs, 'PUT', '/api/jobs/$id/input/in.txt', bytes: utf8.encode('x'));
    await _call(jobs, 'POST', '/api/jobs/$id/start');
    Map<String, dynamic> status = <String, dynamic>{};
    for (int i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      status = await _json(await _call(jobs, 'GET', '/api/jobs/$id'));
      if (status['state'] == 'error') break;
    }
    expect(status['state'], 'error');
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
    final HostJobManager restarted =
        HostJobManager(jobRoot: root, runners: <HostJobRunner>[_EchoRunner()]);
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
    final HostJobManager jobs =
        HostJobManager(jobRoot: root, runners: <HostJobRunner>[_EchoRunner()]);
    final Map<String, Object?> cap = await jobs.capability();
    expect(cap['kinds'], <String>['echo']);
    expect((cap['echo'] as Map)['ready'], isTrue);
  });
}
