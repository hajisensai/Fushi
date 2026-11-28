/// 互联 host 的 HTTP 条件请求：内容 ETag 与 `If-None-Match` 匹配的**唯一**实现。
///
/// 能力表（`/api/capabilities`）与三条同步清单（`/api/library/collections` / `tags` /
/// `media-links`）都用它：版本就是正文本身，正文没变回 304 空体，client 复用上次的
/// 结果。client 不解析 ETag，原样回传即可。
library;

import 'package:crypto/crypto.dart' show sha256;

/// [bytes] 的**弱** ETag：`W/"<SHA-256 前 128 位 hex>"`。内容相等 ⇔ ETag 相等。
///
/// 为什么是弱的：`_gzipTextMiddleware` 按 `Accept-Encoding` 把同一份 JSON 发成 gzip
/// 或明文，两种字节不同的表示共用一个验证器。RFC 9110 §8.8.3 要求强 ETag 在字节
/// 不同的表示之间不同；弱 ETag 只声明「语义等价」，正合这里（这些端点不支持 Range
/// / If-Range，用不到强验证器）。`If-None-Match` 本就按弱比较（[ifNoneMatchHits]），
/// 带不带 `W/` 都命中，所以老 client 缓存的强形式 `"…"` 照样命中。
String weakContentEtag(List<int> bytes) =>
    'W/"${sha256.convert(bytes).toString().substring(0, 32)}"';

/// `If-None-Match` 头 [header] 是否命中 [etag]（RFC 9110 §13.1.2 弱比较：逗号分隔
/// 列表、`W/` 前缀忽略、`*` 恒命中）。头缺失 / 为空 → false。
bool ifNoneMatchHits(String? header, String etag) {
  if (header == null || header.isEmpty) return false;
  String opaque(String tag) => tag.startsWith('W/') ? tag.substring(2) : tag;
  final String want = opaque(etag);
  for (final String raw in header.split(',')) {
    final String tag = raw.trim();
    if (tag.isEmpty) continue;
    if (tag == '*' || opaque(tag) == want) return true;
  }
  return false;
}
