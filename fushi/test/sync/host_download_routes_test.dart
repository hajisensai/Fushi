import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadSubtitlePolicy;
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

  final List<HostDownloadAddRequest> requests = <HostDownloadAddRequest>[];

  @override
  Future<String> add(HostDownloadAddRequest request) async {
    requests.add(request);
    added.add(<String, Object?>{
      'magnet': request.magnetUri,
      'title': request.title,
      'mediaKind': request.mediaKind,
      'discoveryKind': request.discoveryKind,
    });
    return 'job-${added.length}';
  }

  @override
  Future<List<VideoDownloadJobSubtitleRow>?> listJobSubtitles(
    String jobId,
  ) async =>
      jobId == 'known' ? const <VideoDownloadJobSubtitleRow>[] : null;

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

  group('POST 扩展字段（.torrent / 文件选择 / 年份 / 作品身份 / 字幕策略）', () {
    test('torrent + files + year + 身份 + 字幕策略原样到达 host', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': base64Encode(_packTorrent()),
        'title': 'Doraemon Movie 10',
        'files': <int>[1],
        'year': 1989,
        'metadataProvider': 'TMDB',
        'externalId': '0042',
        'subtitlePolicy': 'bestEffort',
      });
      expect(r.statusCode, 200, reason: await r.readAsString());
      final HostDownloadAddRequest req = host.requests.single;
      expect(req.magnetUri, isNull);
      expect(req.metainfo!.files.map((f) => f.path),
          <String>['a.mkv', 'b.mkv', 'c.mkv']);
      expect(req.selectedFileIndexes, <int>{1});
      expect(req.year, 1989);
      expect(req.metadataProvider, 'tmdb', reason: 'provider 归一成小写');
      expect(req.externalId, '42', reason: 'id 归一成十进制正整数');
      expect(req.subtitlePolicy, VideoDownloadSubtitlePolicy.bestEffort);
    });

    test('老客户端只发 magnet/title：扩展字段全是 null（旧行为）', () async {
      final _RecordingHost host = _RecordingHost();
      expect(
        (await _post(host, <String, Object?>{'magnet': 'magnet:?x', 'title': 'a'}))
            .statusCode,
        200,
      );
      final HostDownloadAddRequest req = host.requests.single;
      expect(req.metainfo, isNull);
      expect(req.selectedFileIndexes, isNull);
      expect(req.year, isNull);
      expect(req.metadataProvider, isNull);
      expect(req.subtitlePolicy, isNull);
    });

    final Map<String, (Map<String, Object?>, String)> bad =
        <String, (Map<String, Object?>, String)>{
      '缺 magnet 与 torrent': (
        <String, Object?>{'title': 't'},
        'Missing magnet',
      ),
      'magnet 与 torrent 同时给': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'torrent': base64Encode(_packTorrent()),
          'title': 't',
        },
        'not both',
      ),
      'torrent 不是 base64': (
        <String, Object?>{'torrent': '%%%not-base64', 'title': 't'},
        'base64',
      ),
      'torrent 不是 bencode': (
        <String, Object?>{
          'torrent': base64Encode(utf8.encode('hello')),
          'title': 't',
        },
        'torrent metainfo',
      ),
      'files 下标越界': (
        <String, Object?>{
          'torrent': base64Encode(_packTorrent()),
          'title': 't',
          'files': <int>[3],
        },
        'out of range 0..2',
      ),
      'files 下标不是整数': (
        <String, Object?>{
          'torrent': base64Encode(_packTorrent()),
          'title': 't',
          'files': <Object?>['1'],
        },
        'out of range',
      ),
      'files 配磁链': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'files': <int>[0],
        },
        'requires torrent',
      ),
      'files 空列表': (
        <String, Object?>{
          'torrent': base64Encode(_packTorrent()),
          'title': 't',
          'files': <int>[],
        },
        'non-empty',
      ),
      // admin / 互联两个入口共用：WebUI / ctl / app 客户端都只发 movie|tv，
      // 未知值不再静默当 movie。
      'mediaKind 非 movie/tv': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'mediaKind': 'anime',
        },
        'mediaKind must be movie or tv',
      ),
      'year 不像年份': (
        <String, Object?>{'magnet': 'magnet:?x', 'title': 't', 'year': 19},
        'plausible year',
      ),
      '只给 provider': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'metadataProvider': 'tmdb',
        },
        'together',
      ),
      '不认识的 provider': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'metadataProvider': 'bangumi',
          'externalId': '1',
        },
        'metadataProvider must be one of',
      ),
      'externalId 非正整数': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'metadataProvider': 'anidb',
          'externalId': 'abc',
        },
        'positive integer',
      ),
      '非视频任务带身份': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'discoveryKind': 'novel',
          'year': 2000,
        },
        'only apply to video',
      ),
      '字幕策略非法': (
        <String, Object?>{
          'magnet': 'magnet:?x',
          'title': 't',
          'subtitlePolicy': 'always',
        },
        'subtitlePolicy must be one of',
      ),
    };
    bad.forEach((String name, (Map<String, Object?>, String) c) {
      test('$name → 400 带原因，不进 host', () async {
        final _RecordingHost host = _RecordingHost();
        final shelf.Response r = await _post(host, c.$1);
        expect(r.statusCode, 400);
        expect(await r.readAsString(), contains(c.$2));
        expect(host.added, isEmpty);
      });
    });
  });

  // #2015 先上线的字段名 `fileIndexes`：合入统一请求（HostDownloadAddRequest）后
  // 仍原样认，行为与 `files` 一致（合集包里只要其中几部）。
  group('旧字段名 fileIndexes（与 files 同义）', () {
    final String torrent = base64Encode(_packTorrent());

    test('解析种子、把选中的下标原样透传给 host', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': torrent,
        'fileIndexes': <int>[0, 2],
        'title': 'Doraemon Movies',
      });
      expect(r.statusCode, 200, reason: await r.readAsString());
      final HostDownloadAddRequest req = host.requests.single;
      expect(req.selectedFileIndexes, <int>{0, 2});
      expect(req.metainfo!.files.map((f) => f.path),
          <String>['a.mkv', 'b.mkv', 'c.mkv']);
      expect(req.mediaKind, 'movie');
    });

    test('只给种子不给下标 → 整颗种子（null）', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': torrent,
        'title': 'Doraemon Movies',
      });
      expect(r.statusCode, 200);
      expect(host.requests.single.selectedFileIndexes, isNull);
    });

    test('配磁链 / 空列表 / 非整数 / 负数 / 与 files 同给 → 400，不进 host',
        () async {
      final _RecordingHost host = _RecordingHost();
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{
          'magnet': 'magnet:?x',
          'fileIndexes': <int>[0],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <int>[],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <Object>['0'],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <int>[-1],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'files': <int>[0],
          'fileIndexes': <int>[1],
          'title': 't',
        },
      ]) {
        expect((await _post(host, body)).statusCode, 400, reason: '$body');
      }
      expect(host.added, isEmpty);
    });
  });

  // #2015 先上线的字段名 `fileIndexes`：合入统一请求（HostDownloadAddRequest）后
  // 仍原样认，行为与 `files` 一致（合集包里只要其中几部）。
  group('旧字段名 fileIndexes（与 files 同义）', () {
    final String torrent = base64Encode(_packTorrent());

    test('解析种子、把选中的下标原样透传给 host', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': torrent,
        'fileIndexes': <int>[0, 2],
        'title': 'Doraemon Movies',
      });
      expect(r.statusCode, 200, reason: await r.readAsString());
      final HostDownloadAddRequest req = host.requests.single;
      expect(req.selectedFileIndexes, <int>{0, 2});
      expect(req.metainfo!.files.map((f) => f.path),
          <String>['a.mkv', 'b.mkv', 'c.mkv']);
      expect(req.mediaKind, 'movie');
    });

    test('只给种子不给下标 → 整颗种子（null）', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': torrent,
        'title': 'Doraemon Movies',
      });
      expect(r.statusCode, 200);
      expect(host.requests.single.selectedFileIndexes, isNull);
    });

    test('配磁链 / 空列表 / 非整数 / 负数 / 与 files 同给 → 400，不进 host',
        () async {
      final _RecordingHost host = _RecordingHost();
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{
          'magnet': 'magnet:?x',
          'fileIndexes': <int>[0],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <int>[],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <Object>['0'],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <int>[-1],
          'title': 't',
        },
        <String, Object?>{
          'torrent': torrent,
          'files': <int>[0],
          'fileIndexes': <int>[1],
          'title': 't',
        },
      ]) {
        expect((await _post(host, body)).statusCode, 400, reason: '$body');
      }
      expect(host.added, isEmpty);
    });
  });

  test('GET /api/downloads/<id>/subtitles：已知任务列出，未知任务 404', () async {
    final _RecordingHost host = _RecordingHost();
    Future<shelf.Response> get(String id) => handleHostDownloadRequest(
          host,
          shelf.Request('GET', Uri.parse('http://h/api/downloads/$id/subtitles')),
          'GET',
          '/api/downloads/$id/subtitles',
        );
    final shelf.Response known = await get('known');
    expect(known.statusCode, 200);
    expect(jsonDecode(await known.readAsString()),
        <String, Object?>{'subtitles': <Object?>[]});
    expect((await get('ghost')).statusCode, 404);
  });
}

class _RejectingHost extends _RecordingHost {
  @override
  Future<String> add(HostDownloadAddRequest request) async {
    if (request.discoveryKind != null) {
      throw ArgumentError('this host only downloads video');
    }
    return super.add(request);
  }
}

/// 三个文件（下标 0..2）的 v1 多文件 .torrent。
List<int> _packTorrent() => utf8.encode(
      'd4:infod5:filesld6:lengthi1e4:pathl5:a.mkveed6:lengthi1e4:pathl5:'
      'b.mkveed6:lengthi1e4:pathl5:c.mkveee4:name4:pack12:piece lengthi16384e'
      '6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
    );
