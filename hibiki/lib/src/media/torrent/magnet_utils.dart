/// 磁力链接解析工具（纯函数，通用下载入口用）。

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// 解析磁力链接的 v1 infoHash（`xt=urn:btih:<hash>`），归一化为 40 位小写
/// 十六进制。支持两种编码：40 位十六进制原样小写；32 位 RFC4648 base32 解码成
/// 20 字节再转十六进制。无法解析（非磁力 / 缺 btih / 长度不对）返回 null。
String? parseMagnetInfoHash(String magnet) {
  final String trimmed = magnet.trim();
  if (!trimmed.toLowerCase().startsWith('magnet:')) return null;
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  // 同名多值 xt 都看一遍，取第一个能解析出 btih 的。
  final List<String> xts = uri.queryParametersAll['xt'] ?? const <String>[];
  for (final String xt in xts) {
    const String prefix = 'urn:btih:';
    if (!xt.toLowerCase().startsWith(prefix)) continue;
    final String raw = xt.substring(prefix.length).trim();
    if (raw.length == 40 && _isHex(raw)) {
      return raw.toLowerCase();
    }
    if (raw.length == 32) {
      final String? hex = _base32ToHex(raw.toUpperCase());
      if (hex != null) return hex;
    }
  }
  return null;
}

/// 解析磁力链接里的显示名 `dn`（做默认标题用）；无则返回 null。
String? parseMagnetDisplayName(String magnet) {
  final Uri? uri = Uri.tryParse(magnet.trim());
  if (uri == null) return null;
  final String? dn = uri.queryParameters['dn'];
  if (dn == null) return null;
  final String name = dn.trim();
  return name.isEmpty ? null : name;
}

bool _isHex(String s) {
  for (final int c in s.codeUnits) {
    final bool ok = (c >= 0x30 && c <= 0x39) || // 0-9
        (c >= 0x41 && c <= 0x46) || // A-F
        (c >= 0x61 && c <= 0x66); // a-f
    if (!ok) return false;
  }
  return true;
}

/// 32 字符 base32 → 20 字节 → 40 位小写十六进制；非法字符返回 null。
String? _base32ToHex(String base32) {
  int buffer = 0;
  int bits = 0;
  final List<int> bytes = <int>[];
  for (final int unit in base32.codeUnits) {
    final int val = _base32Alphabet.indexOf(String.fromCharCode(unit));
    if (val < 0) return null;
    buffer = (buffer << 5) | val;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((buffer >> bits) & 0xff);
    }
  }
  if (bytes.length != 20) return null;
  final StringBuffer hex = StringBuffer();
  for (final int b in bytes) {
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}
