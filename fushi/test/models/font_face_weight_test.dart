import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/font_face_weight.dart';
import 'package:material_ui/material_ui.dart';

/// 造一个只有 OS/2 表的最小 sfnt（[weight] 写进 usWeightClass）。
Uint8List _sfntWithWeight(int weight, {bool ttc = false}) {
  const int os2Len = 8;
  const int dirLen = 12 + 16; // offset table + 1 个表记录
  final int faceBase = ttc ? 16 : 0;
  final ByteData d = ByteData(faceBase + dirLen + os2Len);
  if (ttc) {
    d.setUint32(0, 0x74746366); // 'ttcf'
    d.setUint32(4, 0x00010000);
    d.setUint32(8, 1); // numFonts
    d.setUint32(12, faceBase);
  }
  d.setUint32(faceBase, 0x00010000);
  d.setUint16(faceBase + 4, 1); // numTables
  final int rec = faceBase + 12;
  d.setUint32(rec, 0x4F532F32); // 'OS/2'
  d.setUint32(rec + 8, faceBase + dirLen);
  d.setUint32(rec + 12, os2Len);
  d.setUint16(faceBase + dirLen + 4, weight);
  return d.buffer.asUint8List();
}

void main() {
  tearDown(FontFaceWeightRegistry.resetForTesting);

  group('sfntWeightClass', () {
    test('reads usWeightClass from a plain sfnt', () {
      expect(sfntWeightClass(_sfntWithWeight(400)), 400);
      expect(sfntWeightClass(_sfntWithWeight(700)), 700);
    });

    test('reads the first face of a TTC', () {
      expect(sfntWeightClass(_sfntWithWeight(300, ttc: true)), 300);
    });

    test('returns null for garbage / truncated / out-of-range data', () {
      expect(sfntWeightClass(Uint8List(4)), isNull);
      expect(sfntWeightClass(Uint8List(64)), isNull);
      expect(sfntWeightClass(_sfntWithWeight(0)), isNull);
      final Uint8List full = _sfntWithWeight(400);
      expect(sfntWeightClass(Uint8List.sublistView(full, 0, 30)), isNull);
    });
  });

  group('wouldSynthesizeBold', () {
    test('matches the minikin fake-bold rule', () {
      expect(wouldSynthesizeBold(requested: 600, available: 400), isTrue);
      expect(wouldSynthesizeBold(requested: 700, available: 400), isTrue);
      expect(wouldSynthesizeBold(requested: 700, available: 500), isTrue);
      expect(wouldSynthesizeBold(requested: 600, available: 500), isFalse);
      expect(wouldSynthesizeBold(requested: 500, available: 300), isFalse);
      expect(wouldSynthesizeBold(requested: 700, available: 700), isFalse);
    });
  });

  group('withFaceSafeWeight (card term / bold segment weight)', () {
    const TextStyle base = TextStyle(fontFamily: 'Hand Script', fontSize: 20);

    test('single-weight user font: term does not request w600', () {
      FontFaceWeightRegistry.register('Hand Script', 400);
      final TextStyle term = withFaceSafeWeight(base, FontWeight.w600);
      expect(term.fontWeight, isNull);
      expect(term.fontSize, 20);
      expect(faceSafeFontWeight('Hand Script', FontWeight.w700), isNull);
    });

    test('user font whose face is heavy enough keeps w600', () {
      FontFaceWeightRegistry.register('Hand Script', 700);
      expect(
        withFaceSafeWeight(base, FontWeight.w600).fontWeight,
        FontWeight.w600,
      );
    });

    test('multi-weight / system fonts (not registered) keep w600', () {
      expect(
        withFaceSafeWeight(base, FontWeight.w600).fontWeight,
        FontWeight.w600,
      );
      expect(
        withFaceSafeWeight(const TextStyle(), FontWeight.w600).fontWeight,
        FontWeight.w600,
      );
      expect(faceSafeFontWeight(null, FontWeight.w700), FontWeight.w700);
    });

    test('registering an unknown weight clears the old record', () {
      FontFaceWeightRegistry.register('Hand Script', 400);
      FontFaceWeightRegistry.register('Hand Script', null);
      expect(FontFaceWeightRegistry.weightOf('Hand Script'), isNull);
    });
  });

  test('card view routes every emphasis weight through the shared rule', () {
    final String src = File(
      'lib/src/pages/implementations/srs/srs_fushi_card_view.dart',
    ).readAsStringSync();
    // 卡面强调字重（w600/w700）只能经 withFaceSafeWeight / faceSafeFontWeight 给出。
    final RegExp raw = RegExp(r'fontWeight:\s*FontWeight\.w[6-9]00');
    expect(raw.allMatches(src), isEmpty);
    expect(src, contains('withFaceSafeWeight('));
    expect(src, contains('faceSafeFontWeight('));
  });
}
