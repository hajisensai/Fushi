import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';

void main() {
  test('default matches asbplayer subtitle look', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    expect(s.fontSize, 36);
    expect(s.textColor, isNull);
    expect(s.backgroundOpacity, closeTo(0.0, 1e-9));
    expect(s.bottomPadding, 75);
  });

  test('empty color means subtitle text follows the active theme', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    const Color themeColor = Color(0xFF112233);

    expect(s.resolveTextColor(themeColor), themeColor);
  });

  test('encode/decode round-trips', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 30,
      textColor: Color(0xFFFF0000),
      backgroundOpacity: 0.2,
      bottomPadding: 40,
    );
    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));
    expect(back.fontSize, 30);
    expect(back.textColor, const Color(0xFFFF0000));
    expect(back.backgroundOpacity, closeTo(0.2, 1e-9));
    expect(back.bottomPadding, 40);
  });

  test('decode tolerates empty/garbage -> defaults', () {
    expect(VideoSubtitleStyle.decode('').fontSize, 36);
    expect(VideoSubtitleStyle.decode('not json').textColor, isNull);
  });

  test('decode clamps out-of-range', () {
    final VideoSubtitleStyle s = VideoSubtitleStyle.decode(
        '{"fontSize":999,"backgroundOpacity":5,"bottomPadding":-10}');
    expect(s.fontSize, lessThanOrEqualTo(72));
    expect(s.backgroundOpacity, lessThanOrEqualTo(1.0));
    expect(s.bottomPadding, greaterThanOrEqualTo(0));
  });
}
