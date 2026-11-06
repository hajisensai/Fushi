/// 整份表示的 SHA-256 摘要（RFC 9530 `Repr-Digest`），互联包下载的整体校验契约。
///
/// host 的导出包端点每份字节算一次摘要随响应发出（200 与 206 都带：它描述的是**整份**
/// 表示，不是本次 Range 片段）；client 续传把各段拼完后据它校验「拼出来的就是 host
/// 那份字节」，不一致就丢弃重下，而不是把坏包交给导入（Sn4fYseBt4）。
///
/// 只用 `sha-256` 一种算法；老 host 不发该头时 client 只做长度校验，零兼容破坏。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// 响应头名（host 与 client 共用的唯一字面量）。
const String kReprDigestHeader = 'Repr-Digest';

/// 把 32 字节 SHA-256 编成 `Repr-Digest` 头值：`sha-256=:<base64>:`
/// （RFC 9530 §3 的 structured-field Dictionary，值是 byte sequence）。
String formatReprDigestSha256(List<int> digestBytes) =>
    'sha-256=:${base64.encode(digestBytes)}:';

/// 从 `Repr-Digest` 头值里取出 `sha-256` 的原始字节；头缺失 / 无 sha-256 成员 /
/// 格式不对一律 null（调用方据此跳过摘要校验，不当错误）。
List<int>? parseReprDigestSha256(String? header) {
  if (header == null) return null;
  for (final String member in header.split(',')) {
    final String m = member.trim();
    final int eq = m.indexOf('=');
    if (eq <= 0) continue;
    if (m.substring(0, eq).trim().toLowerCase() != 'sha-256') continue;
    final String v = m.substring(eq + 1).trim();
    if (v.length < 2 || !v.startsWith(':') || !v.endsWith(':')) return null;
    try {
      final List<int> bytes = base64.decode(v.substring(1, v.length - 1));
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// 在当前 isolate 里流式计算 [path] 的 SHA-256（不整份读入内存）。
Future<List<int>> sha256OfFileBytes(String path) async {
  final Digest digest = await sha256.bind(File(path).openRead()).first;
  return digest.bytes;
}

/// 在**后台 isolate** 里算 [file] 的 `Repr-Digest` 头值：几 GB 的文件同步哈希要
/// 十几秒，不能占调用方（host 服务 / UI）所在的 isolate。
Future<String> computeReprDigestSha256(File file) async {
  final String path = file.path;
  final List<int> bytes = await Isolate.run(() => sha256OfFileBytes(path));
  return formatReprDigestSha256(bytes);
}
