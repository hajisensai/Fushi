/// `/api/downloads` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// GET    /api/downloads                  {jobs: [...]}
/// POST   /api/downloads                  {magnet | torrent, title, mediaKind?, discoveryKind?,
///                                         files?, year?, metadataProvider?, externalId?,
///                                         subtitlePolicy?} → {jobId}（字段见 HostDownloadAddRequest）
/// GET    /api/downloads/<id>/subtitles   {subtitles: [...]}
/// POST   /api/downloads/<id>/cancel
/// POST   /api/downloads/<id>/retry
/// DELETE /api/downloads/<id>[?deleteFiles=true|false]
/// ```
///
/// `deleteFiles` 缺省 = 旧客户端，host 按各自的历史缺省处理（BUG-3437）。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadPipelineActionRequired;
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/interconnect_module.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart'
    show readBoundedBodyString;
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
        final Object? decoded = jsonDecode(
          await readBoundedBodyString(request),
        );
        if (decoded is! Map) {
          return shelf.Response(400, body: 'JSON object body required');
        }
        final String jobId = await host.add(
          HostDownloadAddRequest.fromJson(decoded),
        );
        return _json(<String, Object?>{'jobId': jobId});
      }
      return shelf.Response(405);
    }
    final String id = seg.first;
    if (id.contains('..') || id.contains('/')) return shelf.Response(400);
    if (seg.length == 1) {
      if (method != 'DELETE') return shelf.Response(405);
      final String? rawDeleteFiles = request.url.queryParameters['deleteFiles'];
      final bool? deleteFiles = switch (rawDeleteFiles) {
        null => null,
        'true' || '1' => true,
        'false' || '0' => false,
        _ => throw const FormatException('deleteFiles must be true or false'),
      };
      await host.deleteJob(id, deleteFiles: deleteFiles);
      return _json(const <String, Object?>{'ok': true});
    }
    if (seg.length == 2 && seg[1] == 'subtitles') {
      if (method != 'GET') return shelf.Response(405);
      final List<VideoDownloadJobSubtitleRow>? rows = await host
          .listJobSubtitles(id);
      if (rows == null) return shelf.Response.notFound('Unknown job');
      return _json(<String, Object?>{
        'subtitles': rows
            .map(videoDownloadJobSubtitleToWire)
            .toList(growable: false),
      });
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
    return _json(<String, Object?>{
      'reason': 'action_required',
      'message': '$e',
    }, status: 409);
  } on ArgumentError catch (e) {
    return shelf.Response(400, body: '${e.message}');
  } on FormatException catch (e) {
    return shelf.Response(400, body: e.message);
  }
}

/// 代下载（设计 §3.3）的互联模块（`/api/downloads*` + 能力位 `downloads`）。[host] 为 null = host
/// 不提供：端点 404、能力位无 `downloads`。
class HostDownloadsInterconnectModule extends InterconnectHostModule {
  HostDownloadsInterconnectModule(this.host);

  final HostDownloadHost? host;

  @override
  String get name => 'downloads';

  @override
  List<InterconnectCapability> get capabilities => <InterconnectCapability>[
    InterconnectCapability('downloads', capability),
  ];

  /// 能力值；null = 本 host 此刻不提供（键不出现）。
  Future<Object?> capability() async {
    final Map<String, Object?>? downloads = await host?.capability();
    if (downloads == null) return null;
    // `deleteFilesParam`：本路由的 DELETE 认 `?deleteFiles=`（BUG-3437）；老 host 没有这个键，
    // client 据此决定能不能让用户选「同时删除已下载文件」。
    return <String, Object?>{
      ...downloads,
      kHostDownloadDeleteFilesParamCapability: true,
    };
  }

  @override
  List<InterconnectRoute> get routes => <InterconnectRoute>[
    InterconnectRoute(
      const InterconnectPath.subtree('/api/downloads'),
      trust: InterconnectTrust.credential,
      handler: handle,
    ),
  ];

  Future<shelf.Response> handle(InterconnectRequest request) async {
    final HostDownloadHost? h = host;
    if (h == null) return shelf.Response.notFound('Host downloads off');
    return handleHostDownloadRequest(
      h,
      request.raw,
      request.method.toUpperCase(),
      request.path,
    );
  }
}
