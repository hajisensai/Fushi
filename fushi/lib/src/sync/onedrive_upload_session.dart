import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:fushi/src/sync/sync_backend.dart';

/// OneDrive 单次 `PUT :/content` 的上限：超过就改走可续传的上传会话。
///
/// Graph 官方最佳实践：大于 10 MiB 的文件用 resumable 传输（createUploadSession）。
/// 单请求 `PUT :/content` 本身只支持到 250 MB，而且一次长连接上传几百 MB 时任何一次
/// 断流（移动网络切换、iOS 退后台、服务端重置）都会让整份上传作废——下一轮同步远端
/// 仍没有这个资产，于是又从头导出、从头上传（反馈 xQVvACx8mY：OneDrive 每次同步都把
/// 整本有声书重传一遍，日志里每一次都以 Broken pipe / Connection reset 告终）。
const int kOneDriveSimpleUploadMaxBytes = 10 * 1024 * 1024;

/// 上传会话的分片大小：Graph 要求分片是 320 KiB 的整数倍、单请求 < 60 MiB，
/// 推荐 5–10 MiB。取 32 × 320 KiB = 10 MiB。
const int kOneDriveUploadChunkBytes = 32 * 320 * 1024;

/// 同一偏移上**连续**失败（中间没有任何字节被服务端确认）多少次后放弃本次上传。
/// 只要服务端确认有进展，计数就清零——断续但在推进的网络总能传完。
const int kOneDriveUploadMaxStalledAttempts = 4;

/// 把 [file] 经 Graph 上传会话 [uploadUrl] 分片传完，返回完成时的 driveItem JSON。
///
/// 协议（driveitem-createuploadsession）：
/// - 分片顺序 `PUT {uploadUrl}`，带 `Content-Range: bytes a-b/total`；**不带**
///   `Authorization`（uploadUrl 自带预签名，带上 bearer 反而可能 401）。
/// - 中间分片回 202 + `nextExpectedRanges`；最后一片回 200/201 + driveItem。
/// - 连接中断 / 5xx：`GET {uploadUrl}` 查服务端已收到哪里，从 `nextExpectedRanges`
///   的起点续传（这是会话协议本身的续传语义，不是把同一请求盲目重发）；5xx 按官方
///   建议指数退避。
/// - 404：会话已失效，直接失败（下一轮同步会新开会话）。
///
/// 放弃时尽力 `DELETE {uploadUrl}` 释放服务端暂存。
Future<Map<String, dynamic>> uploadFileToOneDriveSession({
  required http.Client client,
  required Uri uploadUrl,
  required File file,
  SyncTransferProgress? onProgress,
  int chunkBytes = kOneDriveUploadChunkBytes,
  int maxStalledAttempts = kOneDriveUploadMaxStalledAttempts,
  Future<void> Function(Duration delay) sleep = _defaultSleep,
}) async {
  final int total = await file.length();
  final RandomAccessFile raf = await file.open();
  int offset = 0;
  int stalled = 0;
  Object? lastError;
  try {
    while (true) {
      final int end = (offset + chunkBytes < total
          ? offset + chunkBytes
          : total);
      final int length = end - offset;
      _ChunkOutcome outcome;
      try {
        await raf.setPosition(offset);
        final Uint8List bytes = await raf.read(length);
        if (bytes.length != length) {
          throw SyncBackendError(
            'Upload failed reading file: short read at $offset',
          );
        }
        final http.Response resp = await client.put(
          uploadUrl,
          headers: <String, String>{
            'Content-Range': 'bytes $offset-${end - 1}/$total',
          },
          body: bytes,
        );
        outcome = _ChunkOutcome.fromResponse(resp);
      } on SyncBackendError {
        rethrow;
      } catch (e) {
        // 连接层失败（Broken pipe / Connection reset / ClientException）。
        outcome = _ChunkOutcome.transient(e);
      }

      if (outcome.completedItem != null) {
        onProgress?.call(1, total);
        return outcome.completedItem!;
      }
      if (outcome.fatal != null) {
        await _cancelSession(client, uploadUrl);
        throw outcome.fatal!;
      }

      int? next = outcome.nextOffset;
      if (outcome.transientError != null) {
        lastError = outcome.transientError;
        if (outcome.serverError) {
          // 官方：5xx 用指数退避后再续传。
          await sleep(Duration(seconds: 1 << (stalled < 5 ? stalled : 5)));
        }
        // 问服务端实际收到了哪里，从那里续传。
        try {
          next = await _queryNextOffset(client, uploadUrl);
        } on _SessionGone catch (e) {
          throw SyncBackendError('Upload failed: upload session expired ($e)');
        } catch (e) {
          lastError = e;
          next = null;
        }
      }

      if (next != null && next > offset) {
        offset = next;
        stalled = 0;
        onProgress?.call(total > 0 ? offset / total : 0, offset);
        continue;
      }
      if (next != null && next < offset) {
        // 服务端比本地认为的少收了（上一片没落地）：以服务端为准。
        offset = next;
      }
      stalled++;
      if (stalled >= maxStalledAttempts) {
        await _cancelSession(client, uploadUrl);
        throw SyncBackendError('Upload failed: ${lastError ?? 'no progress'}');
      }
    }
  } finally {
    await raf.close();
  }
}

Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

/// `GET {uploadUrl}` → `nextExpectedRanges[0]` 的起点。会话已完成（无剩余区间）时
/// 返回 null 交由下一次 PUT 判定；404 抛 [_SessionGone]。
Future<int?> _queryNextOffset(http.Client client, Uri uploadUrl) async {
  final http.Response resp = await client.get(uploadUrl);
  if (resp.statusCode == 404) throw _SessionGone('HTTP 404');
  if (resp.statusCode >= 400) {
    throw SyncBackendError(
      'Upload session status failed: HTTP ${resp.statusCode}',
    );
  }
  return parseOneDriveNextExpectedOffset(resp.body);
}

/// 解析 Graph uploadSession JSON 的 `nextExpectedRanges` 第一段起点（`"26-"` /
/// `"26-99"` → 26）。没有该字段或格式不对返回 null。
int? parseOneDriveNextExpectedOffset(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  final Object? ranges = json['nextExpectedRanges'];
  if (ranges is! List || ranges.isEmpty) return null;
  final Object? first = ranges.first;
  if (first is! String) return null;
  final int dash = first.indexOf('-');
  return int.tryParse(dash < 0 ? first : first.substring(0, dash));
}

Future<void> _cancelSession(http.Client client, Uri uploadUrl) async {
  try {
    await client.delete(uploadUrl);
  } catch (_) {
    // 尽力而为：会话本身也会到期自动回收；真正的失败已经由调用方抛出。
  }
}

class _SessionGone implements Exception {
  _SessionGone(this.message);
  final String message;
  @override
  String toString() => message;
}

class _ChunkOutcome {
  _ChunkOutcome._({
    this.completedItem,
    this.nextOffset,
    this.transientError,
    this.serverError = false,
    this.fatal,
  });

  factory _ChunkOutcome.transient(Object error, {bool serverError = false}) =>
      _ChunkOutcome._(transientError: error, serverError: serverError);

  factory _ChunkOutcome.fromResponse(http.Response resp) {
    final int code = resp.statusCode;
    if (code == 200 || code == 201) {
      final Object? json = jsonDecode(resp.body);
      return _ChunkOutcome._(
        completedItem: json is Map<String, dynamic>
            ? json
            : <String, dynamic>{},
      );
    }
    if (code == 202) {
      return _ChunkOutcome._(
        nextOffset: parseOneDriveNextExpectedOffset(resp.body),
      );
    }
    if (code == 404) {
      return _ChunkOutcome._(
        fatal: SyncBackendError(
          'Upload failed: upload session expired (HTTP 404)',
        ),
      );
    }
    if (code >= 500) {
      return _ChunkOutcome.transient(
        'HTTP $code ${resp.body}',
        serverError: true,
      );
    }
    if (code == 416) {
      // 区间已被服务端收过（上一片其实落地了只是响应丢了）：查状态续传。
      return _ChunkOutcome.transient('HTTP 416');
    }
    return _ChunkOutcome._(
      fatal: SyncBackendError('Upload failed: HTTP $code ${resp.body}'),
    );
  }

  final Map<String, dynamic>? completedItem;
  final int? nextOffset;
  final Object? transientError;
  final bool serverError;
  final SyncBackendError? fatal;
}
