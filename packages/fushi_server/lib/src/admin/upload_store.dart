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
    // `..` 一次就够：原先写成 `s == '..' || s == '.' && false`，而 `&&` 优先级
    // 高于 `||`，那个 `.` 分支恒 false —— 是死代码，却长得像一道检查。真正兜住
    // 逃逸的是这里的 `..` 拒绝 + 下面的 normalize + isWithin；`.` 段由 normalize
    // 折叠掉，没有单独拒绝的必要（拒绝反而会打断发 `./foo` 的客户端）。
    final List<String> segments = cleaned.split('/');
    if (cleaned.isEmpty || cleaned.startsWith('/') || segments.contains('..')) {
      throw const UploadRejected(400, 'bad path');
    }
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
    // 声明长度只用来**尽早**拒绝，不能当成配额的唯一判据：
    //   · declaredLength <= 0（没有 Content-Length 的分块上传）会整个跳过检查；
    //   · 声明值本来就是客户端说了算的，写多少字节与它无关。
    // 所以下面在写入循环里按真实字节数再判一次。
    final int baseline = await used();
    if (declaredLength > 0 && baseline + declaredLength > quotaBytes) {
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
    bool overQuota = false;
    try {
      await for (final List<int> chunk in body) {
        if (baseline + written + chunk.length > quotaBytes) {
          overQuota = true;
          break;
        }
        sink.add(chunk);
        written += chunk.length;
      }
    } finally {
      await sink.close();
    }
    if (overQuota) {
      // 把这次已追加的字节退回去，别让一次被拒的上传把 .part 撑到超额。
      if (written > 0) {
        final RandomAccessFile raf = await part.open(mode: FileMode.append);
        try {
          await raf.truncate(have);
        } finally {
          await raf.close();
        }
      }
      throw const UploadRejected(413, 'upload quota exceeded');
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
