// 反馈 toPvLQcpex：SFTP 同步后端按偏移读资产区间（云端旧名漫画包判型、云盘视频
// 流播共用），与来源库 SFTP 流播同一份实现 openSftpFileRange。用假 SftpClient：
//  (1) 区间 / 截到文件尾 / 起点越界（SyncAssetRangeNotSatisfiable 带总长）；
//  (2) 远端句柄只在订阅后打开、读完或取消即关；只要总长（订阅即取消）也不泄漏句柄；
//  (3) SftpSyncBackend.openAssetRange 经 op 锁取连接，越界结论原样穿过错误翻译层
//      （不被包成 SyncBackendError、不断开连接）。

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sftp_range_read.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';

class _FakeSftpFile implements SftpFile {
  _FakeSftpFile(this._data, this._client);

  final Uint8List _data;
  final _FakeSftpClient _client;

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
  }) async* {
    final int end = length == null ? _data.length : offset + length;
    for (int i = offset; i < end; i += chunkSize) {
      final int stop = i + chunkSize > end ? end : i + chunkSize;
      _client.bytesRead += stop - i;
      yield Uint8List.sublistView(_data, i, stop);
    }
  }

  @override
  Future<void> close() async {
    _client.openHandles -= 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSftpClient implements SftpClient {
  _FakeSftpClient(this.files);

  final Map<String, Uint8List> files;
  int openHandles = 0;
  int opens = 0;
  int bytesRead = 0;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(size: files[path]!.length);

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    opens += 1;
    openHandles += 1;
    return _FakeSftpFile(files[path]!, this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Uint8List> _collect(SyncAssetRange range) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in range.bytes) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  final Uint8List file = Uint8List.fromList(
    List<int>.generate(200 * 1024, (int i) => (i * 13 + 5) & 0xff),
  );
  const String path = 'fushi-data/Book/Book.epub';

  test('reads a closed range at an offset and closes the handle', () async {
    final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
      path: file,
    });
    final SyncAssetRange range = await openSftpFileRange(
      sftp,
      path,
      start: 1000,
      end: 1999,
    );
    expect(
      (range.start, range.end, range.totalBytes),
      (1000, 1999, file.length),
    );
    expect(await _collect(range), Uint8List.sublistView(file, 1000, 2000));
    expect(sftp.bytesRead, 1000, reason: '只读所求区间');
    expect(sftp.openHandles, 0);
  });

  test('an open end / past-EOF end is clamped to the file tail', () async {
    final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
      path: file,
    });
    final int tail = file.length - 16 * 1024;
    final SyncAssetRange open = await openSftpFileRange(
      sftp,
      path,
      start: tail,
    );
    expect(open.end, file.length - 1);
    expect(await _collect(open), Uint8List.sublistView(file, tail));

    final SyncAssetRange past = await openSftpFileRange(
      sftp,
      path,
      start: tail,
      end: file.length + 100,
    );
    expect(past.end, file.length - 1);
    await _collect(past);
  });

  test('a start past EOF is SyncAssetRangeNotSatisfiable with the size', () {
    final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
      path: file,
    });
    expect(
      openSftpFileRange(sftp, path, start: file.length),
      throwsA(
        isA<SyncAssetRangeNotSatisfiable>().having(
          (SyncAssetRangeNotSatisfiable e) => e.totalBytes,
          'totalBytes',
          file.length,
        ),
      ),
    );
  });

  test(
    'no handle is opened until the bytes are read; cancelling closes it',
    () async {
      final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
        path: file,
      });
      final SyncAssetRange headOnly = await openSftpFileRange(
        sftp,
        path,
        start: 0,
        end: 0,
      );
      await headOnly.bytes.listen(null).cancel();
      // async* 体在订阅后总会跑起来（取消只在 yield 处生效），所以这里可能开过一次
      // 句柄；要守的是它随取消关掉、不泄漏。
      expect(sftp.openHandles, 0, reason: '只要总长（HEAD）不泄漏远端句柄');
      final int opensAfterHead = sftp.opens;

      final SyncAssetRange whole = await openSftpFileRange(
        sftp,
        path,
        start: 0,
      );
      final Completer<void> first = Completer<void>();
      final StreamSubscription<List<int>> sub = whole.bytes.listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await sub.cancel();
      expect(sftp.opens, opensAfterHead + 1);
      expect(sftp.openHandles, 0, reason: '取消订阅即关句柄');
      expect(sftp.bytesRead, lessThan(file.length));
    },
  );

  group('SftpSyncBackend.openAssetRange', () {
    test('reads through the backend connection', () async {
      final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
        path: file,
      });
      final SftpSyncBackend backend = SftpSyncBackend.withConnection(
        () async => sftp,
      );
      final SyncAssetRange range = await backend.openAssetRange(
        path,
        start: 10,
        end: 19,
      );
      expect(await _collect(range), Uint8List.sublistView(file, 10, 20));
    });

    test('a past-EOF start passes through the error translation unchanged', () {
      final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
        path: file,
      });
      final SftpSyncBackend backend = SftpSyncBackend.withConnection(
        () async => sftp,
      );
      expect(
        backend.openAssetRange(path, start: file.length + 1),
        throwsA(isA<SyncAssetRangeNotSatisfiable>()),
      );
    });

    test(
      'the plain range view reads the same bytes (no obfuscation header)',
      () async {
        final _FakeSftpClient sftp = _FakeSftpClient(<String, Uint8List>{
          path: file,
        });
        final SyncAssetRangeReader? plain = plainAssetRangeReaderOf(
          SftpSyncBackend.withConnection(() async => sftp),
        );
        expect(plain, isNotNull);
        final SyncAssetRange range = await plain!.openAssetRange(
          path,
          start: 100,
          end: 199,
        );
        expect(await _collect(range), Uint8List.sublistView(file, 100, 200));
      },
    );
  });
}
