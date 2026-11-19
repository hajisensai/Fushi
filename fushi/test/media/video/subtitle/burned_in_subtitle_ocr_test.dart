import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/burned_in_subtitle_ocr.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_burned_in_evidence.dart';
import 'package:image/image.dart' as img;

void main() {
  test('字幕带裁剪：只留画面下方 40%，记下上沿与整帧尺寸', () {
    final Uint8List jpeg = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 160, height: 90)),
    );
    final SubtitleBandCrop? band = cropSubtitleBand(jpeg);
    expect(band, isNotNull);
    expect(band!.frameWidth, 160);
    expect(band.frameHeight, 90);
    expect(band.top, (90 * kSubtitleBurnedInBandTop).floor());
    final img.Image? cropped = img.decodeImage(band.bytes);
    expect(cropped!.width, 160);
    expect(cropped.height, 90 - band.top);
    expect(cropSubtitleBand(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  test('带内行坐标换回整帧归一化坐标；竖排行丢掉；换回后能被挑成台词', () {
    final SubtitleBandCrop band = SubtitleBandCrop(
      bytes: Uint8List(0),
      top: 60,
      frameWidth: 200,
      frameHeight: 100,
    );
    final List<SubtitleFrameTextLine> lines = subtitleFrameLinesFromBand(
      const SystemOcrPageResult(
        lines: <SystemOcrTextLine>[
          SystemOcrTextLine(
            text: '堂に行こう',
            rect: Rect.fromLTRB(60, 25, 140, 35),
            isVertical: false,
          ),
          SystemOcrTextLine(
            text: '縦',
            rect: Rect.fromLTRB(5, 0, 15, 40),
            isVertical: true,
          ),
        ],
        imageWidth: 200,
        imageHeight: 40,
      ),
      band,
    );
    expect(lines, hasLength(1));
    final SubtitleFrameTextLine l = lines.single;
    expect(l.left, closeTo(0.3, 1e-9));
    expect(l.right, closeTo(0.7, 1e-9));
    expect(l.top, closeTo(0.85, 1e-9));
    expect(l.bottom, closeTo(0.95, 1e-9));
    expect(burnedInSubtitleText(lines), '堂に行こう');
  });
}
