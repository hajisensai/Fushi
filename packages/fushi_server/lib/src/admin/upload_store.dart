/// WebUI 上传：分块可续（`Content-Range`）、落到库根、配额账本。
///
/// 协议：`PUT /api/admin/upload?library=<id>&path=<相对路径>`，body 为一段字节，
/// `Content-Range: bytes <start>-<end>/<total>`（不带就当整文件一次传）。服务端把
/// 分段追加到 `<file>.part`，收齐 `total` 字节后原子 rename 成目标文件。
/// `GET /api/admin/upload?library=<id>&path=<相对路径>` 返回 `{received}` 供断点续传。
///
/// 配额：`<support>/upload_ledger.json` 记累计上传字节；超过 `upload_quota_bytes`
/// 拒收 413。不是磁盘配额（那由 OS 管），只是防 WebUI 被当网盘用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/config/server_config.dart';
import 'package:path/path.dart' as p;

class UploadRejected implements Exception {
  const UploadRejected(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'UploadRejected($status: $message)';
}

class UploadStore {
  UploadStore({required this.ledgerFile, required this.quotaBytes});

  final File ledgerFile;
  final int quotaBytes;
  int? _used;

  Future<int> used() async {
    if (_used != null) return _used!;
    try {
      final Object? decoded = jsonDecode(await ledgerFile.readAsString());
      _used = decoded is Map ? (decoded['bytes'] as num?)?.toInt() ?? 0 : 0;
    } catch (_) {
      _used = 0;
    }
    return _used!;
  }

  Future<void> _record(int delta) async {
    _used = (await used()) + delta;
    await ledgerFile.parent.create(recursive: true);
    await ledgerFile.writeAsString(jsonEncode(<String, Object?>{'bytes': _used}), flush: true);
  }

  /// 目标文件的绝对路径；[relative] 不得逃出库根。
  static String resolveTarget(LibraryRootConfig library, String relative) {
    final String root = p.normalize(p.absolute(library.path));
    final String cleaned = relative.replaceAll('\\', '/');
    if (cleaned.isEmpty || cleaned.startsWith('/') || cleaned.split('/').any((String s) => s == '..' || s == '.' && false)) {
      throw const UploadRejected(400, 'bad path');
    }
    if (cleaned.split('/').contains('..')) throw const UploadRejected(400, 'bad path');
    final String target = p.normalize(p.join(root, cleaned));
    if (!p.isWithin(root, target)) throw const UploadRejected(400, 'path escapes library root');
    return target;
  }

  Future<int> received(String target) async {
    final File part = File('$target.part');
    if (await part.exists()) return part.length();
    if (await File(target).exists()) return File(target).length();
    return 0;
  }

  /// 写一段；返回 (received, complete)。
  Future<({int received, bool complete})> putChunk({
    required String target,
    required Stream<List<int>> body,
    required int? rangeStart,
    required int? total,
    required int declaredLength,
  }) async {
    if (declaredLength > 0 && (await used()) + declaredLength > quotaBytes) {
      throw const UploadRejected(413, 'upload quota exceeded');
    }
    final File part = File('$target.part');
    await part.parent.create(recursive: true);
    final int have = await part.exists() ? await part.length() : 0;
    final int start = rangeStart ?? 0;
    if (start != have) {
      throw UploadRejected(409, 'expected offset $have, got $start');
    }
    final IOSink sink = part.openWrite(mode: FileMode.append);
    int written = 0;
    try {
      await for (final List<int> chunk in body) {
        sink.add(chunk);
        written += chunk.length;
      }
    } finally {
      await sink.close();
    }
    await _record(written);
    final int now = have + written;
    final bool complete = total == null || now >= total;
    if (complete) {
      final File dest = File(target);
      if (await dest.exists()) await dest.delete();
      await part.rename(target);
    }
    return (received: now, complete: complete);
  }
}

/// `Content-Range: bytes <start>-<end>/<total>` → (start, total)。解析失败返回 null。
({int start, int? total})? parseContentRange(String? header) {
  if (header == null) return null;
  final RegExpMatch? m = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(header.trim());
  if (m == null) return null;
  final int start = int.parse(m.group(1)!);
  final int? total = m.group(3) == '*' ? null : int.parse(m.group(3)!);
  return (start: start, total: total);
}
