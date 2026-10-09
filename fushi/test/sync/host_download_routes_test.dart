import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
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
  Future<String> addTorrent({
    required InspectedTorrentMetainfo metainfo,
    Set<int>? fileIndexes,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
  }) async {
    added.add(<String, Object?>{
      'torrentId': metainfo.torrentId,
      'files': metainfo.files.map((InspectedTorrentFile f) => f.path).toList(),
      'fileIndexes': fileIndexes,
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

  // 合集包里只要其中几部：磁链拿不到文件清单，只能交 `.torrent` + 文件 index。
  group('torrent + fileIndexes', () {
    final String torrent = base64Encode(_moviePackTorrent());

    test('解析种子、把选中的 index 原样透传给 host', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': torrent,
        'fileIndexes': <int>[0, 2],
        'title': 'Doraemon Movies',
      });
      expect(r.statusCode, 200);
      expect(host.added.single['fileIndexes'], <int>{0, 2});
      expect(host.added.single['files'], <String>[
        'Doraemon Movie 01 (1980).mkv',
        'Doraemon Movie 02 (1981).mkv',
        'Doraemon Movie 05 (1984).mkv',
      ]);
      expect(host.added.single['mediaKind'], 'movie');
    });

    test('只给种子不给 index → 整个种子（null）', () async {
      final _RecordingHost host = _RecordingHost();
      final shelf.Response r = await _post(host, <String, Object?>{
        'torrent': torrent,
        'title': 'Doraemon Movies',
      });
      expect(r.statusCode, 200);
      expect(host.added.single.containsKey('fileIndexes'), isTrue);
      expect(host.added.single['fileIndexes'], isNull);
    });

    test('磁链 + 种子同时给、或都不给 → 400，不进 host', () async {
      final _RecordingHost host = _RecordingHost();
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{
          'magnet': 'magnet:?x',
          'torrent': torrent,
          'title': 't'
        },
        <String, Object?>{'title': 't'},
      ]) {
        expect((await _post(host, body)).statusCode, 400);
      }
      expect(host.added, isEmpty);
    });

    test('fileIndexes 只认 .torrent、且必须是非负整数列表 → 否则 400', () async {
      final _RecordingHost host = _RecordingHost();
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{
          'magnet': 'magnet:?x',
          'fileIndexes': <int>[0],
          'title': 't'
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <int>[],
          'title': 't'
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <Object>['0'],
          'title': 't'
        },
        <String, Object?>{
          'torrent': torrent,
          'fileIndexes': <int>[-1],
          'title': 't'
        },
      ]) {
        expect((await _post(host, body)).statusCode, 400, reason: '$body');
      }
      expect(host.added, isEmpty);
    });

    test('坏 base64 / 坏种子 → 400', () async {
      final _RecordingHost host = _RecordingHost();
      for (final String bad in <String>[
        '!!!',
        base64Encode(utf8.encode('not a torrent'))
      ]) {
        expect(
          (await _post(host, <String, Object?>{'torrent': bad, 'title': 't'}))
              .statusCode,
          400,
        );
      }
      expect(host.added, isEmpty);
    });
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

/// 三部剧场版的多文件种子（v1，最小合法 bencode）。
Uint8List _moviePackTorrent() => _bencode(<String, Object?>{
      'info': <String, Object?>{
        'files': <Object?>[
          for (final String name in <String>[
            'Doraemon Movie 01 (1980).mkv',
            'Doraemon Movie 02 (1981).mkv',
            'Doraemon Movie 05 (1984).mkv',
          ])
            <String, Object?>{
              'length': 1024,
              'path': <Object?>[name]
            },
        ],
        'name': 'Pack',
        'piece length': 16384,
        'pieces': Uint8List(20),
      },
    });

Uint8List _bencode(Object? value) {
  final BytesBuilder output = BytesBuilder(copy: false);

  void write(Object? current) {
    if (current is int) {
      output.add(utf8.encode('i${current}e'));
    } else if (current is String) {
      final List<int> bytes = utf8.encode(current);
      output
        ..add(utf8.encode('${bytes.length}:'))
        ..add(bytes);
    } else if (current is Uint8List) {
      output
        ..add(utf8.encode('${current.length}:'))
        ..add(current);
    } else if (current is List<Object?>) {
      output.addByte(0x6c);
      current.forEach(write);
      output.addByte(0x65);
    } else if (current is Map<String, Object?>) {
      output.addByte(0x64);
      for (final String key in current.keys.toList()..sort()) {
        write(key);
        write(current[key]);
      }
      output.addByte(0x65);
    } else {
      throw ArgumentError.value(current, 'value');
    }
  }

  write(value);
  return output.takeBytes();
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
