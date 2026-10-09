import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Navigation requirements from the disc index, without decoding any video.
/// Empty BDJO/JAR directories do not prove that a disc has Java menus.
class BlurayMenuInfo {
  const BlurayMenuInfo({
    required this.hasFirstPlay,
    required this.hasTopMenu,
    required this.requiresJava,
    required this.titleCount,
    this.firstPlayInteractive = false,
  });

  final bool hasFirstPlay;
  final bool hasTopMenu;
  final bool requiresJava;
  final int titleCount;
  final bool firstPlayInteractive;

  bool get hasMenu => hasTopMenu || firstPlayInteractive;
}

/// Parses INDX navigation objects, following libbluray bdnav/index_parse.c.
/// All objects must fit inside the declared index block, not merely the file.
BlurayMenuInfo? parseBlurayMenuInfo(Uint8List bytes) {
  if (bytes.length < 78 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'INDX' ||
      !const <String>{
        '0100',
        '0200',
        '0300',
      }.contains(String.fromCharCodes(bytes.sublist(4, 8)))) {
    return null;
  }
  final ByteData data = ByteData.sublistView(bytes);
  final int start = data.getUint32(8);
  if (start < 78 || start > bytes.length - 4) return null;
  final int blockLength = data.getUint32(start);
  if (blockLength < 26 || blockLength > bytes.length - start - 4) {
    return null;
  }
  final int first = start + 4;
  final int count = data.getUint16(first + 24);
  if (26 + count * 12 > blockLength) return null;

  bool requiresJava = false;
  bool? readObject(int offset) {
    final int kind = bytes[offset] >> 6;
    if (kind == 1) {
      final int playbackType = bytes[offset + 4] >> 6;
      if (playbackType > 1) return null;
      return data.getUint16(offset + 6) != 0xffff;
    }
    if (kind == 2) {
      final int playbackType = bytes[offset + 4] >> 6;
      if (playbackType != 2 && playbackType != 3) return null;
      // A BD-J object names a five-digit BDJO file; do not accept path syntax.
      for (int i = offset + 6; i < offset + 11; i++) {
        if (bytes[i] < 0x30 || bytes[i] > 0x39) return null;
      }
      requiresJava = true;
      return true;
    }
    return null;
  }

  final bool? hasFirstPlay = readObject(first);
  final bool? hasTopMenu = readObject(first + 12);
  if (hasFirstPlay == null || hasTopMenu == null) return null;
  for (int i = 0; i < count; i++) {
    if (readObject(first + 26 + i * 12) == null) return null;
  }
  if (!hasFirstPlay && !hasTopMenu && count == 0) return null;
  return BlurayMenuInfo(
    hasFirstPlay: hasFirstPlay,
    hasTopMenu: hasTopMenu,
    requiresJava: requiresJava,
    titleCount: count,
    firstPlayInteractive:
        hasFirstPlay && const <int>{1, 3}.contains(bytes[first + 4] >> 6),
  );
}

/// Reads the primary index, with the same backup fallback as libbluray.
Future<BlurayMenuInfo?> readBlurayMenuInfo(String discRootPath) async {
  for (final String relative in <String>[
    p.join('BDMV', 'index.bdmv'),
    p.join('BDMV', 'BACKUP', 'index.bdmv'),
  ]) {
    try {
      final File file = File(p.join(discRootPath, relative));
      // Bound allocation for malformed/untrusted disc metadata.
      final int length = await file.length();
      if (length < 78 || length > 1024 * 1024) continue;
      final BlurayMenuInfo? info = parseBlurayMenuInfo(
        await file.readAsBytes(),
      );
      if (info != null) return info;
    } on FileSystemException {
      continue;
    }
  }
  return null;
}
