import 'dart:convert';
import 'dart:typed_data';

/// Decodes a malloc-owned C ABI payload after its bytes have been copied.
///
/// BUG-1522：编码边界在 native 侧，不在这里。`fushi_torrent_ffi.cpp` 的
/// `append_json_escaped` 是**每个字段**的唯一出口，它先 `is_valid_utf8`，
/// 只有当这一个字段不是合法 UTF-8 时才在 Windows 上试
/// `windows_ansi_to_utf8`（libtorrent/WinSock 的 `error_code::message()` 走
/// 当前 locale 的 ANSI code page），仍不合法的字节才落成 `�`。因此
/// C ABI 出参契约是「整包永远是合法 UTF-8 JSON」。
///
/// Dart 侧因此**不做任何编码猜测**。整包按 ANSI 重解码是错的：payload 里只要
/// 混进一个本地化错误串，就会把同一包里本来合法的 UTF-8 种子名、保存路径一起
/// 按 ANSI 解成乱码——CP936 上把 `テスト` 解成汉字垃圾，CP1252 上把 `中文` 解成
/// `ÖÐÎÄ`。编码是逐字段的属性，不是整包的属性，没有任何单一 code page 能同时
/// 解对两半。
///
/// `allowMalformed` 只是**旧随包 DLL**（还没带上 native 侧修复）的降级网：
/// 坏字节就地变成 U+FFFD，损坏范围锁在那一个字段内，绝不牵连同包的合法内容，
/// 也不会让整份 tracker 列表因为一次 `jsonDecode` 失败而消失。
Object? decodeNativeTorrentJsonBytes(Uint8List bytes) {
  final String text = utf8.decode(bytes, allowMalformed: true);
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
