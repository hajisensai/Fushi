/// `/api/jobs` 的 shelf 路由（鉴权由 FushiSyncServer 的 middleware 统一做，
/// 这里不豁免任何端点）。
///
/// ```
/// GET    /api/jobs                        列表
/// POST   /api/jobs                        {kind, params} → {jobId, state}
/// GET    /api/jobs/<id>                   轮询
/// PUT    /api/jobs/<id>/input/<name>      上传输入（body=bytes）
/// POST   /api/jobs/<id>/start
/// GET    /api/jobs/<id>/result[/<name>]   产物
/// DELETE /api/jobs/<id>                   取消 + 清理
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/host_jobs/host_job.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );

Future<shelf.Response> handleHostJobRequest(
  HostJobManager jobs,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  await jobs.load();
  final List<String> seg = reqPath
      .substring('/api/jobs'.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  try {
    if (seg.isEmpty) {
      if (method == 'GET') {
        return _json(<String, Object?>{
          'jobs': jobs.list().map((HostJobRecord r) => r.toWireJson()).toList(),
        });
      }
      if (method == 'POST') {
        final Object? decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map) return shelf.Response(400, body: 'JSON object body required');
        final String? kind = decoded['kind']?.toString();
        if (kind == null || kind.isEmpty) return shelf.Response(400, body: 'Missing kind');
        final Object? rawParams = decoded['params'];
        final Map<String, Object?> params = rawParams is Map
            ? Map<String, Object?>.from(rawParams)
            : <String, Object?>{};
        final HostJobRecord rec = await jobs.create(kind, params);
        return _json(<String, Object?>{'jobId': rec.id, ...rec.toWireJson()});
      }
      return shelf.Response(405);
    }
    final String id = seg.first;
    if (id.contains('..') || id.contains('/')) return shelf.Response(400);
    if (seg.length == 1) {
      if (method == 'GET') return _json(jobs.get(id).toWireJson());
      if (method == 'DELETE') {
        await jobs.delete(id);
        return _json(const <String, Object?>{'ok': true});
      }
      return shelf.Response(405);
    }
    final String action = seg[1];
    if (action == 'input' && seg.length == 3) {
      if (method != 'PUT') return shelf.Response(405);
      await jobs.putInput(id, seg[2], request.read());
      return _json(jobs.get(id).toWireJson());
    }
    if (action == 'start' && seg.length == 2) {
      if (method != 'POST') return shelf.Response(405);
      await jobs.start(id);
      return _json(jobs.get(id).toWireJson());
    }
    if (action == 'result') {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      final HostJobRecord rec = jobs.get(id);
      if (rec.state != HostJobState.done) {
        return _json(<String, Object?>{'reason': 'not_done', 'state': rec.state.name}, status: 409);
      }
      final String? name = seg.length >= 3 ? seg[2] : null;
      final File? file = jobs.result(id, name);
      if (file == null || !await file.exists()) return shelf.Response.notFound('No such output');
      final int length = await file.length();
      return shelf.Response.ok(
        method == 'HEAD' ? null : file.openRead(),
        headers: <String, String>{
          'Content-Type': jobs.contentTypeFor(id, name ?? rec.primaryOutput ?? ''),
          'Content-Length': '$length',
        },
      );
    }
    return shelf.Response.notFound('Unknown jobs route');
  } on HostJobNotFound {
    return shelf.Response.notFound('No such job');
  } on HostJobConflict catch (e) {
    return _json(<String, Object?>{'reason': e.reason}, status: 409);
  } on FormatException catch (e) {
    return shelf.Response(400, body: e.message);
  }
}
