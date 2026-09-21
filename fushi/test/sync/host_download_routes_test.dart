import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/downloads/host_download_routes.dart';
import 'package:shelf/shelf.dart' as shelf;

/// `/api/downloads` POST 的 `discoveryKind` 字段（设计 §3.3：app 当 host 收发现页
/// 四个非视频域）：合法值透传给 host；非法值路由层直接 400，不进 host。
class _RecordingHost implements HostDownloadHost {
  final List<Map<String, Object?>> added = <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> capability() async =>
      const <String, Object?>{'supported': true, 'backend': 'embedded'};

  @override
  Future<List<VideoDownloadJobRow>> listJobs() async =>
      const <VideoDownloadJobRow>[];

  @override
  Future<String> addMagnet({
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
  }) async {
    added.add(<String, Object?>{
      'magnet': magnetUri,
      'title': title,
      'mediaKind': mediaKind,
      'discoveryKind': discoveryKind,
    });
    return 'job-${added.length}';
  }

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<void> retryJob(String jobId) async {}

  @override
  Future<void> deleteJob(String jobId) async {}
}

Future<shelf.Response> _post(
  HostDownloadHost host,
  Map<String, Object?> body,
) =>
    handleHostDownloadRequest(
      host,
      shelf.Request(
        'POST',
        Uri.parse('http://h/api/downloads'),
        body: jsonEncode(body),
        headers: const <String, String>{'Content-Type': 'application/json'},
      ),
      'POST',
      '/api/downloads',
    );

void main() {
  test('discoveryKind 缺省 → null 透传（视频）；合法域透传', () async {
    final _RecordingHost host = _RecordingHost();
    expect(
      (await _post(
              host, <String, Object?>{'magnet': 'magnet:?x', 'title': 'a'}))
          .statusCode,
      200,
    );
    expect(
      (await _post(host, <String, Object?>{
        'magnet': 'magnet:?x',
        'title': 'b',
        'discoveryKind': 'manga',
      }))
          .statusCode,
      200,
    );
    expect(host.added.map((Map<String, Object?> m) => m['discoveryKind']),
        <Object?>[null, 'manga']);
  });

  test('discoveryKind 非法 → 400，不进 host', () async {
    final _RecordingHost host = _RecordingHost();
    final shelf.Response r = await _post(host, <String, Object?>{
      'magnet': 'magnet:?x',
      'title': 'c',
      'discoveryKind': 'video',
    });
    expect(r.statusCode, 400);
    expect(host.added, isEmpty);
  });

  test('host 不收该域（ArgumentError）→ 400', () async {
    final _RecordingHost host = _RejectingHost();
    final shelf.Response r = await _post(host, <String, Object?>{
      'magnet': 'magnet:?x',
      'title': 'c',
      'discoveryKind': 'game',
    });
    expect(r.statusCode, 400);
    expect(await r.readAsString(), contains('only downloads video'));
  });
}

class _RejectingHost extends _RecordingHost {
  @override
  Future<String> addMagnet({
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
  }) async {
    if (discoveryKind != null) {
      throw ArgumentError('this host only downloads video');
    }
    return super.addMagnet(magnetUri: magnetUri, title: title);
  }
}
