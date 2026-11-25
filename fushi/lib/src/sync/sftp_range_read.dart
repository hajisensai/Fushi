import 'package:dartssh2/dartssh2.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';

/// 按偏移读 SFTP 文件 [path] 的 `[start, end]` 闭区间（[end] 为 null 或越过文件尾时
/// 截到文件尾）。同步后端（[SyncAssetRangeReader]）与来源库流播共用这一份实现。
///
/// 先 `stat` 拿总长；[start] 越过文件尾抛 [SyncAssetRangeNotSatisfiable]。远端句柄在
/// 字节流**真正开始读**时才打开、读完或取消订阅时关闭：只要总长的调用方（中继对 HEAD
/// 是「订阅后立刻取消」）不会留下一个没人关的句柄，所以调用方不再需要时**必须**
/// 取消订阅。
Future<SyncAssetRange> openSftpFileRange(
  SftpClient sftp,
  String path, {
  required int start,
  int? end,
}) async {
  if (start < 0 || (end != null && end < start)) {
    throw ArgumentError('invalid range [$start, $end]');
  }
  final int? size = (await sftp.stat(path)).size;
  if (size == null) {
    throw StateError('SFTP server did not report a size for $path');
  }
  if (start >= size) throw SyncAssetRangeNotSatisfiable(size);
  final int last = (end == null || end >= size) ? size - 1 : end;

  Stream<List<int>> bytes() async* {
    final SftpFile handle = await sftp.open(path, mode: SftpFileOpenMode.read);
    try {
      yield* handle.read(offset: start, length: last - start + 1);
    } finally {
      await handle.close();
    }
  }

  return SyncAssetRange(
    start: start,
    end: last,
    totalBytes: size,
    bytes: bytes(),
  );
}
