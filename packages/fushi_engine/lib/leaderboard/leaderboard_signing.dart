// 请求签名串（与 services/leaderboard/src/auth.js `signingString` 逐字节一致）：
//   `${METHOD}\n${pathWithQuery}\n${time}\n${hex(sha256(body))}`

import 'package:crypto/crypto.dart' as crypto;

/// 待签名串。[pathWithQuery] 必须与服务端看到的 `URL.pathname + URL.search` 相同
/// （含前导 `/`，有查询时含 `?`）；[body] 是实际发出的请求体字节（GET 为空）。
String leaderboardSigningString(
  String method,
  String pathWithQuery,
  int timeMs,
  List<int> body,
) {
  final String bodyHash = crypto.sha256.convert(body).toString();
  return '${method.toUpperCase()}\n$pathWithQuery\n$timeMs\n$bodyHash';
}
