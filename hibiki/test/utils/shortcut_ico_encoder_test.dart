import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/shortcut_icon_sync.dart';
import 'package:image/image.dart' as img;

/// 把一帧纯色图编码成 PNG 字节，喂给 [buildMultiSizeIco]。
Uint8List _solidPng(int w, int h, {int r = 200, int g = 100, int b = 50}) {
  final img.Image image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgba8(r, g, b, 255));
  return Uint8List.fromList(img.encodePng(image));
}

int _u16le(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

void main() {
  group('buildMultiSizeIco', () {
    test('emits a 4-frame .ico header with the expected directory sizes', () {
      final Uint8List? ico = buildMultiSizeIco(_solidPng(64, 64));
      expect(ico, isNotNull);
      final Uint8List bytes = ico!;

      // ICONDIR header: reserved(0) / type(1=icon) / count(4 frames).
      expect(_u16le(bytes, 0), 0, reason: 'reserved must be 0');
      expect(_u16le(bytes, 2), 1, reason: 'type must be 1 (ICO)');
      expect(_u16le(bytes, 4), kShortcutIcoSizes.length,
          reason: 'count must equal number of sizes');

      // Each 16-byte ICONDIRENTRY starts at 6 + i*16. Byte 0 = width, byte 1 =
      // height. ICO spec stores 256 as a 0 byte, so map size 256 -> 0.
      for (int i = 0; i < kShortcutIcoSizes.length; i++) {
        final int entryOffset = 6 + i * 16;
        final int expected =
            kShortcutIcoSizes[i] >= 256 ? 0 : kShortcutIcoSizes[i];
        expect(bytes[entryOffset], expected, reason: 'frame $i width byte');
        expect(bytes[entryOffset + 1], expected,
            reason: 'frame $i height byte');
      }
    });

    test('accepts a source larger than 256 (resizes down, no throw)', () {
      // 512x512 source must not be fed raw to the encoder (>256 throws); helper
      // copyResizes every frame so this stays valid.
      final Uint8List? ico = buildMultiSizeIco(_solidPng(512, 512));
      expect(ico, isNotNull);
      expect(_u16le(ico!, 4), kShortcutIcoSizes.length);
    });

    test('returns null for undecodable bytes', () {
      final Uint8List garbage = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      expect(buildMultiSizeIco(garbage), isNull);
    });
  });

  group('shortcutIcoFileName', () {
    test('is deterministic by content and content-addressed', () {
      final Uint8List a = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final Uint8List b = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final Uint8List c = Uint8List.fromList(<int>[9, 9, 9, 9]);
      expect(shortcutIcoFileName(a), shortcutIcoFileName(b),
          reason: 'same content -> same file name');
      expect(shortcutIcoFileName(a), isNot(shortcutIcoFileName(c)),
          reason: 'different content -> different file name');
    });

    test('matches the shortcut_icon_<hash>.ico shape', () {
      final String name =
          shortcutIcoFileName(Uint8List.fromList(<int>[7, 7, 7]));
      expect(
          RegExp(r'^shortcut_icon_[0-9a-f]{16}\.ico$').hasMatch(name), isTrue,
          reason: 'name was: $name');
    });
  });
}
