/// `/api/downloads` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// GET    /api/downloads                  {jobs: [...]}
/// POST   /api/downloads                  {magnet, title, mediaKind?, discoveryKind?} → {jobId}
///                                        或 {torrent(base64 .torrent), fileIndexes?, title, …}：
///                                        只下种子里的这几个文件（合集包挑部）
/// POST   /api/downloads/<id>/cancel
/// POST   /api/downloads/<id>/retry
/// DELETE /api/downloads/<id>
/// ```
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart'
    show inspectTorrentMetainfo;
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
        final String torrent = (decoded['torrent'] ?? '').toString().trim();
        final String title = (decoded['title'] ?? '').toString().trim();
        if (magnet.isEmpty == torrent.isEmpty) {
          return shelf.Response(400, body: 'Exactly one of magnet or torrent is required');
        }
        if (title.isEmpty) return shelf.Response(400, body: 'Missing title');
        final Object? rawIndexes = decoded['fileIndexes'];
        if (rawIndexes != null && torrent.isEmpty) {
          // 磁链没有文件清单，选文件只认 `.torrent`。
          return shelf.Response(400, body: 'fileIndexes requires torrent');
        }
        if (rawIndexes != null &&
            (rawIndexes is! List || rawIndexes.isEmpty || rawIndexes.any((Object? i) => i is! int || i < 0))) {
          return shelf.Response(400, body: 'fileIndexes must be a non-empty list of non-negative integers');
        }
        final String mediaKind = (decoded['mediaKind'] ?? 'movie').toString();
        if (mediaKind != 'movie' && mediaKind != 'tv') {
          return shelf.Response(400, body: 'mediaKind must be movie or tv');
        }
        final String discoveryKind = (decoded['discoveryKind'] ?? '').toString().trim();
        if (discoveryKind.isNotEmpty && !kHostDownloadDiscoveryKinds.contains(discoveryKind)) {
          return shelf.Response(
            400,
            body: 'discoveryKind must be one of ${kHostDownloadDiscoveryKinds.join(', ')}',
          );
        }
        final String? discovery = discoveryKind.isEmpty ? null : discoveryKind;
        final String jobId = torrent.isEmpty
            ? await host.addMagnet(
                magnetUri: magnet,
                title: title,
                mediaKind: mediaKind,
                discoveryKind: discovery,
              )
            : await host.addTorrent(
                // 坏 base64 / 坏 bencode 都是 FormatException → 400。
                metainfo: inspectTorrentMetainfo(base64Decode(torrent)),
                fileIndexes: rawIndexes == null ? null : <int>{for (final Object? i in rawIndexes as List) i! as int},
                title: title,
                mediaKind: mediaKind,
                discoveryKind: discovery,
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
