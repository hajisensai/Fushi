import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/video/subtitle_pos_mapping.dart';

void main() {
  group('mapPosFractionToContainer', () {
    test('letterbox: 16:9 video in 1:1 container centers vertically', () {
      // video 1920x1080 (16:9) into 800x800 container -> content 800x450,
      // letterboxed vertically: originY=175, height=450.
      final Offset? o = mapPosFractionToContainer(
          const SubtitlePos(0.5, 0.5), 1920, 1080, const Size(800, 800));
      expect(o!.dx, closeTo(400, 1e-6));
      expect(o.dy, closeTo(175 + 225, 1e-6)); // 175 + 0.5*450
    });

    test('exact aspect: maps fraction across full container', () {
      final Offset? o = mapPosFractionToContainer(
          const SubtitlePos(0.25, 0.0), 1600, 900, const Size(1600, 900));
      expect(o!.dx, closeTo(400, 1e-6));
      expect(o.dy, closeTo(0, 1e-6));
    });

    test('undecoded video (w<=0) returns null', () {
      expect(
          mapPosFractionToContainer(
              const SubtitlePos(0.5, 0.5), 0, 0, const Size(800, 800)),
          isNull);
    });
  });
}
