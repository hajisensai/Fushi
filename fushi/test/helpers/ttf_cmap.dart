import 'dart:typed_data';

/// 解析 TTF 的 cmap format 4 子表，返回其中出现的全部码位。
///
/// 只支持 format 4（BMP）——Material Symbols 的私用区码位全在 BMP，够用；读不到
/// format 4 时返回空集，由调用方断言成失败而不是静默放过。
Set<int> ttfCmapCodePoints(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  final int numTables = data.getUint16(4);

  int? cmapOffset;
  for (int i = 0; i < numTables; i++) {
    final int rec = 12 + 16 * i;
    final String tag = String.fromCharCodes(bytes.sublist(rec, rec + 4));
    if (tag == 'cmap') {
      cmapOffset = data.getUint32(rec + 8);
      break;
    }
  }
  if (cmapOffset == null) return <int>{};

  final int numSubtables = data.getUint16(cmapOffset + 2);
  int? format4Offset;
  for (int i = 0; i < numSubtables; i++) {
    final int rec = cmapOffset + 4 + 8 * i;
    final int subtableOffset = cmapOffset + data.getUint32(rec + 4);
    if (data.getUint16(subtableOffset) == 4) {
      format4Offset = subtableOffset;
      break;
    }
  }
  if (format4Offset == null) return <int>{};

  final int segCountX2 = data.getUint16(format4Offset + 6);
  final int segCount = segCountX2 ~/ 2;
  final int endBase = format4Offset + 14;
  final int startBase = endBase + segCountX2 + 2;

  final Set<int> result = <int>{};
  for (int seg = 0; seg < segCount; seg++) {
    final int end = data.getUint16(endBase + 2 * seg);
    final int start = data.getUint16(startBase + 2 * seg);
    if (start == 0xFFFF) continue;
    for (int cp = start; cp <= end && cp != 0xFFFF; cp++) {
      result.add(cp);
    }
  }
  return result;
}
