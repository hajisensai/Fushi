import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';

void main() {
  test('default matches asbplayer subtitle look', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    expect(s.fontSize, 36);
    expect(s.textColor, isNull);
    expect(s.fontWeight, isNull);
    expect(s.resolveFontWeight(1.0), 700);
    expect(s.shadowColor, isNull);
    expect(s.shadowThickness, isNull);
    expect(s.resolveShadowThickness(1.0), 3);
    expect(s.backgroundColor, isNull);
    expect(s.backgroundOpacity, closeTo(0.0, 1e-9));
    expect(s.bottomPadding, 75);
  });

  test('unconfigured weight and shadow follow app UI scale', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;

    expect(s.resolveFontWeight(2.0), 900);
    expect(s.resolveShadowThickness(2.0), 6);
    expect(s.resolveFontWeight(0.5), 400);
    expect(s.resolveShadowThickness(0.5), 1.5);
  });

  test('empty color means subtitle text follows the active theme', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    const Color themeColor = Color(0xFF112233);

    expect(s.resolveTextColor(themeColor), themeColor);
    expect(s.resolveShadowColor(themeColor), themeColor);
    expect(s.resolveBackgroundColor(themeColor), themeColor);
  });

  test('encode/decode round-trips', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 30,
      textColor: Color(0xFFFF0000),
      fontWeight: 500,
      shadowColor: Color(0xFF112233),
      shadowThickness: 6,
      backgroundColor: Color(0xFF445566),
      backgroundOpacity: 0.2,
      bottomPadding: 40,
    );
    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));
    expect(back.fontSize, 30);
    expect(back.textColor, const Color(0xFFFF0000));
    expect(back.fontWeight, 500);
    expect(back.resolveFontWeight(2.0), 500);
    expect(back.shadowColor, const Color(0xFF112233));
    expect(back.shadowThickness, 6);
    expect(back.resolveShadowThickness(2.0), 6);
    expect(back.backgroundColor, const Color(0xFF445566));
    expect(back.backgroundOpacity, closeTo(0.2, 1e-9));
    expect(back.bottomPadding, 40);
  });

  test('encode/decode preserves explicit asb baseline choices', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 36,
      textColor: null,
      fontWeight: VideoSubtitleStyle.defaultFontWeight,
      shadowColor: null,
      shadowThickness: VideoSubtitleStyle.defaultShadowThickness,
      backgroundColor: null,
      backgroundOpacity: 0,
      bottomPadding: 75,
    );

    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));

    expect(back.fontWeight, VideoSubtitleStyle.defaultFontWeight);
    expect(back.shadowThickness, VideoSubtitleStyle.defaultShadowThickness);
    expect(back.resolveFontWeight(2.0), VideoSubtitleStyle.defaultFontWeight);
    expect(
      back.resolveShadowThickness(2.0),
      VideoSubtitleStyle.defaultShadowThickness,
    );
  });

  test('decode tolerates empty/garbage -> defaults', () {
    expect(VideoSubtitleStyle.decode('').fontSize, 36);
    expect(VideoSubtitleStyle.decode('not json').textColor, isNull);
  });

  test('decode migrates stored asb defaults to scale-derived defaults', () {
    final VideoSubtitleStyle s =
        VideoSubtitleStyle.decode('{"fontWeight":700,"shadowThickness":3}');

    expect(s.fontWeight, isNull);
    expect(s.shadowThickness, isNull);
    expect(s.resolveFontWeight(1.0), 700);
    expect(s.resolveShadowThickness(1.0), 3);
  });

  test('decode clamps out-of-range', () {
    final VideoSubtitleStyle s = VideoSubtitleStyle.decode(
        '{"fontSize":999,"fontWeight":9999,"shadowThickness":999,'
        '"backgroundOpacity":5,"bottomPadding":-10}');
    expect(s.fontSize, lessThanOrEqualTo(72));
    expect(s.fontWeight, 900);
    expect(s.shadowThickness, 12);
    expect(s.backgroundOpacity, lessThanOrEqualTo(1.0));
    expect(s.bottomPadding, greaterThanOrEqualTo(0));
  });
}
