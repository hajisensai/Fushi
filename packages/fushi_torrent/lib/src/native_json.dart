import 'dart:convert';
import 'dart:typed_data';

/// Decodes a malloc-owned C ABI payload after its bytes have been copied.
///
/// New native builds guarantee UTF-8 JSON. `allowMalformed` keeps older
/// bundled Windows DLLs readable when a localized socket error was emitted in
/// the active code page instead, replacing only the invalid text bytes.
Object? decodeNativeTorrentJsonBytes(Uint8List bytes) {
  try {
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } on FormatException {
    return null;
  }
}
