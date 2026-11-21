/// 续传 / 复用的**版本身份**：只认强验证器（强 ETag 或 Last-Modified）。
///
/// HBK-AUDIT-033 / BUG-5117：之前媒体服务器整片下载与在线源直链下载把「总长相同」
/// 也算作可比对的身份——服务器从不给 ETag / Last-Modified 时照样带 `Range` 续传
/// （没有验证器可放进 `If-Range`，服务器无从拒绝），206 只回同样的总长就被认作同一
/// 份字节；文件被**等长替换**后旧前缀 + 新后缀拼成坏片。总长只能**否定**（不同 →
/// 肯定换了），不能**证明**同一版本。
///
/// 规则（RFC 9110 §13.1.5 If-Range、§8.8.1 强弱验证器）：
/// - 强验证器 = 非 `W/` 前缀的 ETag，或 Last-Modified。弱 ETag 不能放进 `If-Range`，
///   也不能用来证明逐字节相同。
/// - 续传前必须有强验证器；没有就不续，从 0 重下。
/// - 续传响应（206）必须**回显** `If-Range` 用的那个验证器且相等；没回显（兼容层
///   无视 If-Range 又不带验证器）= 缺证据，作废这条响应从 0 重下。两边都有的其它
///   字段（另一个验证器、总长）任一不同也作废。
library;

import 'dart:io';

import 'package:meta/meta.dart';

import 'package:fushi_engine/utils/misc/resumable_downloader.dart';

@immutable
class ResumeValidator {
  const ResumeValidator({this.etag, this.lastModified, this.totalBytes});

  final String? etag;
  final String? lastModified;
  final int? totalBytes;

  /// `W/"…"`：弱 ETag（语义等价、不保证逐字节相同）。
  static bool isWeakEtag(String value) => value.startsWith('W/');

  /// 可放进 `If-Range`、可证明逐字节相同的 ETag；弱 / 空 ETag 为 null。
  String? get strongEtag {
    final String? e = etag;
    if (e == null || e.isEmpty || isWeakEtag(e)) return null;
    return e;
  }

  String? get _lastModified {
    final String? lm = lastModified;
    return lm == null || lm.isEmpty ? null : lm;
  }

  /// 有没有能证明「同一版本」的强验证器。只有总长 / 只有弱 ETag 都不算。
  bool get hasStrongValidator => strongEtag != null || _lastModified != null;

  /// 续传请求用的 `If-Range` 来源：强 ETag 优先，其次 Last-Modified；没有强验证器
  /// 时为 null（调用方此时不该续传）。
  ResumableDownloadState? get ifRangeState => hasStrongValidator
      ? ResumableDownloadState(etag: strongEtag, lastModified: _lastModified)
      : null;

  /// 续传响应（206）是否**证明**仍是记下的那个版本：`If-Range` 用的验证器必须原样
  /// 回显且相等；两边都有的其它字段任一不同即不是。缺证据一律 false。
  bool provesSameRepresentation(ResumableDownloadResponse response) {
    final String? etagNow = _nonEmpty(response.header(HttpHeaders.etagHeader));
    final String? modifiedNow = _nonEmpty(
      response.header(HttpHeaders.lastModifiedHeader),
    );
    final int? totalNow = contentRangeTotal(
      response.header(HttpHeaders.contentRangeHeader),
    );
    return _sameAs(
      ResumeValidator(
        etag: etagNow,
        lastModified: modifiedNow,
        totalBytes: totalNow,
      ),
    );
  }

  /// 两份记录（如完整分量侧车里的 vs 现探的）是否同一版本：任一共有字段不同即
  /// 不是；必须有一个强验证器两边都有且相等才算是。
  bool sameRepresentationAs(ResumeValidator other) => _sameAs(other);

  bool _sameAs(ResumeValidator now) {
    final String? etagThen = _nonEmpty(etag);
    final String? etagNow = _nonEmpty(now.etag);
    if (etagThen != null && etagNow != null && etagThen != etagNow) {
      return false;
    }
    final String? lmThen = _lastModified;
    final String? lmNow = now._lastModified;
    if (lmThen != null && lmNow != null && lmThen != lmNow) return false;
    final int? totalThen = totalBytes;
    final int? totalNow = now.totalBytes;
    if (totalThen != null && totalNow != null && totalThen != totalNow) {
      return false;
    }
    // 证明只能来自强验证器：强 ETag 两边都在且相等（强比较），或 Last-Modified
    // 两边都在且相等。只有总长 / 弱 ETag 相等不构成证据。
    final String? strongThen = strongEtag;
    if (strongThen != null) return now.strongEtag == strongThen;
    if (lmThen != null) return lmNow == lmThen;
    return false;
  }

  /// `Content-Range: bytes a-b/total` 的总长；`*` / 缺失 / 畸形为 null。
  static int? contentRangeTotal(String? value) {
    if (value == null) return null;
    final RegExpMatch? match = RegExp(
      r'^bytes\s+\d+-\d+/(\d+)$',
    ).firstMatch(value.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}
