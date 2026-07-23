import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ── Minimal ZIP reader for tests (no external deps) ──────────────────────────
//
// Reads the Central Directory to enumerate entries, then reads each Local
// File Header to locate file data.  Supports STORE and DEFLATE.
//
// Shared by cues_to_epub_test.dart and text_to_epub_test.dart to verify
// EPUB output produced via EpubBuilder.

class EpubZipReader {
  EpubZipReader(Uint8List bytes) : _b = bytes;
  final Uint8List _b;
  late final Map<String, String> _files = _parseAll();

  /// Returns all file names in the ZIP.
  Set<String> get names => _files.keys.toSet();

  /// Returns the UTF-8 content of [name], or null if absent.
  String? operator [](String name) => _files[name];

  /// Returns the name of the very first entry (by local offset 0).
  String get firstEntry {
    // Signature of local file header: PK\x03\x04
    // The very first local header should be at offset 0.
    final int nameLen = _u16(26);
    return utf8.decode(_b.sublist(30, 30 + nameLen));
  }

  /// Returns the compression method of the very first entry (0 = STORE).
  int get firstEntryMethod => _u16(8);

  Map<String, String> _parseAll() {
    final result = <String, String>{};
    // Find end of central directory (signature 0x06054b50, last 22 bytes minimum)
    int eocdOffset = _findEocd();
    final int cdOffset = _u32(eocdOffset + 16);
    final int cdEntries = _u16(eocdOffset + 10);

    int pos = cdOffset;
    for (int i = 0; i < cdEntries; i++) {
      // Central directory entry signature: 0x02014b50
      final int nameLen = _u16(pos + 28);
      final int extraLen = _u16(pos + 30);
      final int commentLen = _u16(pos + 32);
      final int localOffset = _u32(pos + 42);
      final String name = utf8.decode(_b.sublist(pos + 46, pos + 46 + nameLen));

      // Read local file header for data offset
      // Local file header sig: 0x04034b50
      final int lNameLen = _u16(localOffset + 26);
      final int lExtraLen = _u16(localOffset + 28);
      final int method = _u16(localOffset + 8);
      final int compSize = _u32(localOffset + 18);
      final int dataStart = localOffset + 30 + lNameLen + lExtraLen;

      final Uint8List raw = _b.sublist(dataStart, dataStart + compSize);
      final Uint8List data;
      if (method == 0) {
        data = raw; // STORE
      } else {
        // DEFLATE (raw, wbits = -15)
        data = Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
      }
      result[name] = utf8.decode(data);

      pos += 46 + nameLen + extraLen + commentLen;
    }
    return result;
  }

  int _findEocd() {
    // Search backwards for EOCD signature 0x06054b50
    for (int i = _b.length - 22; i >= 0; i--) {
      if (_b[i] == 0x50 &&
          _b[i + 1] == 0x4b &&
          _b[i + 2] == 0x05 &&
          _b[i + 3] == 0x06) {
        return i;
      }
    }
    throw StateError('EOCD signature not found — not a valid ZIP');
  }

  int _u16(int offset) => _b[offset] | (_b[offset + 1] << 8);

  int _u32(int offset) =>
      _b[offset] |
      (_b[offset + 1] << 8) |
      (_b[offset + 2] << 16) |
      (_b[offset + 3] << 24);
}
