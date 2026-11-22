// HBK-AUDIT-223：[SyncAssetStore.getBytesAsset] 的 256 MiB 上限契约
// （[kSyncBytesAssetMaxBytes]）在每个云后端上都成立：远端声明的大小已超限就一个
// 字节都不收、抛 [SyncAssetTooLarge]（不被映射成「不存在」的 null）。逐块计数本身
// 由共用的 [readSyncAssetBytesCapped] 钉在
// `packages/fushi_engine/test/sync/sync_asset_bytes_cap_test.dart`。WebDAV / Google
// Drive / 互联早就边收边计数，这里补上此前整份读进内存的 OneDrive / Dropbox / SFTP。
// FTP 只能下载到临时文件，没有可注入的客户端，走的是同一个计数器（见
// ftp_sync_backend._downloadBytes）。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_http.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 声明 [kSyncBytesAssetMaxBytes] + 1 字节、实际只有一小块的响应体，记下是否被订阅。
class _OversizedBody {
  bool listened = false;

  http.StreamedResponse response() => http.StreamedResponse(
    Stream<List<int>>.multi((MultiStreamController<List<int>> c) {
      listened = true;
      c.add(Uint8List(8));
      c.close();
    }),
    200,
    contentLength: kSyncBytesAssetMaxBytes + 1,
    headers: <String, String>{'content-type': 'application/octet-stream'},
  );
}

class _FakeSftpFile implements SftpFile {
  _FakeSftpFile(this._data, this._declaredSize, this._client);

  final Uint8List _data;
  final int _declaredSize;
  final _FakeSftpClient _client;

  @override
  Future<SftpFileAttrs> stat() async => SftpFileAttrs(size: _declaredSize);

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
  }) async* {
    final int end = length == null || length > _data.length
        ? _data.length
        : length;
    _client.bytesRead += end - offset;
    yield Uint8List.sublistView(_data, offset, end);
  }

  @override
  Future<void> close() async {
    _client.openHandles -= 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSftpClient implements SftpClient {
  _FakeSftpClient(this.data, this.declaredSize);

  final Uint8List data;
  final int declaredSize;
  int openHandles = 0;
  int bytesRead = 0;

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    openHandles += 1;
    return _FakeSftpFile(data, declaredSize, this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() {
    debugSetSyncHttpClient(null);
    OneDriveSyncBackend.instance.debugSetAccessToken(null);
    DropboxSyncBackend.instance.debugSetAccessToken(null);
  });

  test('OneDrive：downloadUrl 声明超过上限就不收，抛 SyncAssetTooLarge', () async {
    final _OversizedBody body = _OversizedBody();
    debugSetSyncHttpClient(
      MockClient.streaming((http.BaseRequest req, _) async {
        if (req.url.host == 'dl.example') return body.response();
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode(<String, Object>{
                '@microsoft.graph.downloadUrl': 'https://dl.example/big',
              }),
            ),
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final OneDriveSyncBackend backend = OneDriveSyncBackend.instance
      ..debugSetAccessToken('t');
    await expectLater(
      backend.getBytesAsset('big'),
      throwsA(isA<SyncAssetTooLarge>()),
    );
    expect(body.listened, isFalse);
  });

  test('Dropbox：/files/download 声明超过上限就不收，抛 SyncAssetTooLarge', () async {
    final _OversizedBody body = _OversizedBody();
    debugSetSyncHttpClient(
      MockClient.streaming((http.BaseRequest req, _) async {
        expect(req.url.path, '/2/files/download');
        expect(req.headers['Dropbox-API-Arg'], '{"path":"/fushi/big.bin"}');
        return body.response();
      }),
    );
    final DropboxSyncBackend backend = DropboxSyncBackend.instance
      ..debugSetAccessToken('t');
    await expectLater(
      backend.getBytesAsset('/fushi/big.bin'),
      throwsA(isA<SyncAssetTooLarge>()),
    );
    expect(body.listened, isFalse);
  });

  group('SFTP', () {
    test('上限之内整份读回，句柄关掉', () async {
      final Uint8List data = Uint8List.fromList(<int>[1, 2, 3]);
      final _FakeSftpClient sftp = _FakeSftpClient(data, data.length);
      final SftpSyncBackend backend = SftpSyncBackend.withConnection(
        () async => sftp,
      );
      expect(await backend.getBytesAsset('a.bin'), data);
      expect(sftp.openHandles, 0);
    });

    test('stat 大小超过上限：一个字节都不读，抛 SyncAssetTooLarge 而不是 null', () async {
      final _FakeSftpClient sftp = _FakeSftpClient(
        Uint8List(8),
        kSyncBytesAssetMaxBytes + 1,
      );
      final SftpSyncBackend backend = SftpSyncBackend.withConnection(
        () async => sftp,
      );
      await expectLater(
        backend.getBytesAsset('big.bin'),
        throwsA(isA<SyncAssetTooLarge>()),
      );
      expect(sftp.bytesRead, 0);
      expect(sftp.openHandles, 0);
    });
  });
}
