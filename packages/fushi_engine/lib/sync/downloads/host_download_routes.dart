/// `/api/downloads` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// GET    /api/downloads                  {jobs: [...]}
/// POST   /api/downloads                  {magnet, title, mediaKind?} → {jobId}
/// POST   /api/downloads/<id>/cancel
/// POST   /api/downloads/<id>/retry
/// DELETE /api/downloads/<id>
/// ```
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineActionRequired;
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );

Future<shelf.Response> handleHostDownloadRequest(
  HostDownloadHost host,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  final List<String> seg = reqPath
      .substring('/api/downloads'.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  try {
    if (seg.isEmpty) {
      if (method == 'GET') {
        final List<VideoDownloadJobRow> jobs = await host.listJobs();
        return _json(<String, Object?>{
          'jobs': jobs.map(videoDownloadJobToWire).toList(growable: false),
        });
      }
      if (method == 'POST') {
        final Object? decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map) return shelf.Response(400, body: 'JSON object body required');
        final String magnet = (decoded['magnet'] ?? '').toString().trim();
        final String title = (decoded['title'] ?? '').toString().trim();
        if (magnet.isEmpty) return shelf.Response(400, body: 'Missing magnet');
        if (title.isEmpty) return shelf.Response(400, body: 'Missing title');
        final String mediaKind = (decoded['mediaKind'] ?? 'movie').toString();
        if (mediaKind != 'movie' && mediaKind != 'tv') {
          return shelf.Response(400, body: 'mediaKind must be movie or tv');
        }
        final String jobId = await host.addMagnet(
          magnetUri: magnet,
          title: title,
          mediaKind: mediaKind,
        );
        return _json(<String, Object?>{'jobId': jobId});
      }
      return shelf.Response(405);
    }
    final String id = seg.first;
    if (id.contains('..') || id.contains('/')) return shelf.Response(400);
    if (seg.length == 1) {
      if (method != 'DELETE') return shelf.Response(405);
      await host.deleteJob(id);
      return _json(const <String, Object?>{'ok': true});
    }
    if (method != 'POST') return shelf.Response(405);
    switch (seg[1]) {
      case 'cancel':
        await host.cancelJob(id);
        return _json(const <String, Object?>{'ok': true});
      case 'retry':
        await host.retryJob(id);
        return _json(const <String, Object?>{'ok': true});
    }
    return shelf.Response.notFound('Unknown downloads route');
  } on VideoDownloadPipelineActionRequired catch (e) {
    return _json(<String, Object?>{'reason': 'action_required', 'message': '$e'}, status: 409);
  } on ArgumentError catch (e) {
    return shelf.Response(400, body: '${e.message}');
  } on FormatException catch (e) {
    return shelf.Response(400, body: e.message);
  }
}
