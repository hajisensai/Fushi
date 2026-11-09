// BUG-4243（反馈 hbIHtWi2Q7）：OneDrive downloadUrl / Dropbox `/files/download` 回
// `application/octet-stream` 不带 charset，`resp.body` 按 latin1 解码，上传端却是 UTF-8，
// 每轮「下载 → 合并 → 上传」把非 ASCII 再多编一层。这里钉死：下载到的 JSON 按 UTF-8
// 还原，且多轮往返后内容不变；旧解码器写下的对端快照副本作废。
//
// BUG-4244（反馈 UHkG_OhDxQ）：OneDrive JSON 资产（聚合快照）超过 10 MiB 仍走单请求
// `PUT :/content`，被 Graph 400 拒掉。这里钉死大 JSON 走上传会话分片。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/onedrive_upload_session.dart';
import 'package:fushi/src/sync/sync_http.dart';
import 'package:fushi_engine/sync/aggregate_peer_snapshot_cache.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Map<String, String> _octet = <String, String>{
  'content-type': 'application/octet-stream',
};
const Map<String, String> _json = <String, String>{
  'content-type': 'application/json',
};

/// 只存字节的假 OneDrive：`PUT :/content` 存、downloadUrl 以 octet-stream 回放。
class _FakeOneDrive {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final List<String> calls = <String>[];
  final List<String> sessionRanges = <String>[];
  final BytesBuilder _session = BytesBuilder(copy: true);
  String? _sessionName;

  Future<http.Response> handle(http.Request req) async {
    final Uri u = req.url;
    calls.add('${req.method} ${u.host}${u.path}');
    if (u.host == 'dl.example') {
      return http.Response.bytes(
        files[u.path.substring(1)]!,
        200,
        headers: _octet,
      );
    }
    if (u.host == 'up.example') {
      final String range = req.headers['content-range']!;
      sessionRanges.add(range);
      final RegExpMatch m = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(range)!;
      expect(int.parse(m.group(1)!), _session.length);
      _session.add(req.bodyBytes);
      final int total = int.parse(m.group(3)!);
      if (_session.length < total) {
        return http.Response(
          jsonEncode(<String, Object>{
            'nextExpectedRanges': <String>['${_session.length}-'],
          }),
          202,
          headers: _json,
        );
      }
      files[_sessionName!] = _session.takeBytes();
      return http.Response(
        jsonEncode(<String, Object>{'id': 'x'}),
        201,
        headers: _json,
      );
    }
    final RegExpMatch? content = RegExp(
      r'/items/[^/]+:/([^/]+):/content$',
    ).firstMatch(u.path);
    if (req.method == 'PUT' && content != null) {
      files[Uri.decodeComponent(content.group(1)!)] = req.bodyBytes;
      return http.Response('{}', 201, headers: _json);
    }
    final RegExpMatch? session = RegExp(
      r'/items/[^/]+:/([^/]+):/createUploadSession$',
    ).firstMatch(u.path);
    if (req.method == 'POST' && session != null) {
      _sessionName = Uri.decodeComponent(session.group(1)!);
      return http.Response(
        jsonEncode(<String, Object>{'uploadUrl': 'https://up.example/s'}),
        200,
        headers: _json,
      );
    }
    final RegExpMatch? meta = RegExp(
      r'/me/drive/items/([^/:]+)$',
    ).firstMatch(u.path);
    if (req.method == 'GET' && meta != null) {
      return http.Response(
        jsonEncode(<String, Object>{
          '@microsoft.graph.downloadUrl': 'https://dl.example/${meta.group(1)}',
        }),
        200,
        headers: _json,
      );
    }
    fail('unexpected request ${req.method} $u');
  }
}

void main() {
  const Map<String, Object?> payload = <String, Object?>{
    'readingStats': <Object?>[
      <String, Object?>{'title': '本好きの下剋上 第一部', 'dateKey': '2026-11-09'},
    ],
    'favoriteSentences': <Object?>['「ありがとう」と言った。🎉 Ünïcödé'],
  };

  tearDown(() {
    debugSetSyncHttpClient(null);
    OneDriveSyncBackend.instance.debugSetAccessToken(null);
    DropboxSyncBackend.instance.debugSetAccessToken(null);
  });

  test('OneDrive：octet-stream 下载的 JSON 按 UTF-8 还原，多轮往返不再多编一层', () async {
    final _FakeOneDrive drive = _FakeOneDrive();
    debugSetSyncHttpClient(MockClient(drive.handle));
    final OneDriveSyncBackend backend = OneDriveSyncBackend.instance
      ..debugSetAccessToken('t');

    await backend.putJsonAsset('ns', 'agg.json', payload);
    Object? current = payload;
    for (int round = 0; round < 3; round++) {
      current = await backend.getJsonAsset('agg.json');
      expect(current, payload, reason: 'round $round');
      await backend.putJsonAsset('ns', 'agg.json', current);
    }
    expect(utf8.decode(drive.files['agg.json']!), jsonEncode(payload));
  });

  test('Dropbox：/files/download 的 octet-stream JSON 按 UTF-8 还原', () async {
    final Uint8List stored = utf8.encode(jsonEncode(payload));
    debugSetSyncHttpClient(
      MockClient((http.Request req) async {
        expect(req.url.path, '/2/files/download');
        return http.Response.bytes(stored, 200, headers: _octet);
      }),
    );
    final DropboxSyncBackend backend = DropboxSyncBackend.instance
      ..debugSetAccessToken('t');

    expect(await backend.getJsonAsset('/fushi/agg.json'), payload);
  });

  test('OneDrive：超过 10 MiB 的 JSON 资产走上传会话分片，不发单请求 PUT', () async {
    final _FakeOneDrive drive = _FakeOneDrive();
    debugSetSyncHttpClient(MockClient(drive.handle));
    final OneDriveSyncBackend backend = OneDriveSyncBackend.instance
      ..debugSetAccessToken('t');
    final Map<String, Object?> big = <String, Object?>{
      'blob': '字' * (kOneDriveSimpleUploadMaxBytes ~/ 3 + 1024),
    };
    final Uint8List expected = utf8.encode(jsonEncode(big));
    expect(expected.length, greaterThan(kOneDriveSimpleUploadMaxBytes));

    await backend.putJsonAsset('ns', 'big.json', big);

    expect(drive.calls.where((String c) => c.endsWith(':/content')), isEmpty);
    expect(
      drive.calls.where((String c) => c.endsWith(':/createUploadSession')),
      hasLength(1),
    );
    expect(drive.sessionRanges, <String>[
      'bytes 0-${kOneDriveUploadChunkBytes - 1}/${expected.length}',
      'bytes $kOneDriveUploadChunkBytes-${expected.length - 1}/${expected.length}',
    ]);
    expect(drive.files['big.json'], expected);
  });

  test('OneDrive：小 JSON 资产仍走单请求 PUT :/content', () async {
    final _FakeOneDrive drive = _FakeOneDrive();
    debugSetSyncHttpClient(MockClient(drive.handle));
    final OneDriveSyncBackend backend = OneDriveSyncBackend.instance
      ..debugSetAccessToken('t');

    await backend.putJsonAsset('ns', 'small.json', payload);

    expect(drive.calls, <String>[
      'PUT graph.microsoft.com/v1.0/me/drive/items/ns:/small.json:/content',
    ]);
  });

  test('修复前（无 format 代号）写下的对端快照副本不再命中', () async {
    final Directory root = await Directory.systemTemp.createTemp('peer_cache');
    addTearDown(() => root.delete(recursive: true));
    final DirectoryAggregatePeerSnapshotCache cache =
        DirectoryAggregatePeerSnapshotCache(() async => root);
    const AssetEntry entry = AssetEntry(
      id: 'id1',
      name: 'peer.json',
      isFolder: false,
      revision: 'r1',
    );
    final File legacy = File('${root.path}/ch/peer.json.json');
    await legacy.parent.create(recursive: true);
    await legacy.writeAsString(
      jsonEncode(<String, Object?>{
        'id': 'id1',
        'revision': 'r1',
        'snapshot': <String, Object?>{'title': 'æ\u009c¬'},
      }),
    );
    expect(await cache.read('ch', entry), isNull);

    await cache.write('ch', entry, payload);
    expect(await cache.read('ch', entry), payload);
  });
}
