import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-929 guard: the reported ASS requests a font that is not installed on
/// Windows. mpv/libass (DirectWrite) resolves its Japanese glyphs through
/// Microsoft YaHei UI, so Hibiki must use the same first fallback for both
/// Flutter glyph rendering and ASS cell/em size conversion.
const String _reportedAss = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080
LayoutResX: 1920
LayoutResY: 1080
WrapStyle: 2
ScaledBorderAndShadow: yes
YCbCr Matrix: TV.709

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Text_JP,A-OTF Shin Maru Go Pr6N DB,65,&H00FFFFFF,&H000000FF,&H00613FD9,&H00000000,0,0,0,0,100,100,2.5,0,1,3,0,2,10,10,30,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:23.80,0:00:25.00,Text_JP,,0,0,0,,きれえ
''';

Text _fill(WidgetTester tester, String character) => tester
    .widgetList<Text>(find.text(character))
    .firstWhere((Text text) => text.style?.foreground == null);

Text _stroke(WidgetTester tester, String character) => tester
    .widgetList<Text>(find.text(character))
    .firstWhere((Text text) => text.style?.foreground != null);

void main() {
  test('Windows fallback mirrors mpv without changing other platforms', () {
    expect(
      subtitleCjkFontFallbacks(TargetPlatform.windows).take(2),
      <String>['Microsoft YaHei UI', 'Microsoft YaHei'],
    );
    expect(
      subtitleCjkFontFallbacks(TargetPlatform.linux).take(2),
      <String>['Yu Gothic', 'Yu Gothic UI'],
    );
    expect(
      assMissingFontRasterCompensation(
        TargetPlatform.windows,
        hasRequestedFamily: true,
        requestedFamilyResolved: false,
        fallbackFamilyAvailable: true,
      ),
      (fontScale: 1.09, yScale: 1.055),
    );
    expect(
      assMissingFontRasterCompensation(
        TargetPlatform.windows,
        hasRequestedFamily: true,
        requestedFamilyResolved: false,
        fallbackFamilyAvailable: false,
      ),
      (fontScale: 1.0, yScale: 1.0),
      reason: 'Flutter test fonts must not activate production calibration',
    );
  });

  testWidgets(
      'reported ASS keeps mpv size, colors, spacing, outline and Windows fallback',
      (WidgetTester tester) async {
    final TargetPlatform? previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final List<AudioCue> cues =
        AssParser.parseString(content: _reportedAss, bookKey: 'bug-929');
    final VideoPlayerController controller = VideoPlayerController()
      ..debugVideoWidthOverride = 1920
      ..debugVideoHeightOverride = 1080
      ..setCues(cues)
      ..debugSetPositionForTesting(24000)
      ..debugUpdateCueForPosition(24000);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(
            controller: controller,
            respectAssStyle: true,
            bottomPadding: 30,
          ),
        ),
      ),
    );
    await tester.pump();

    final Text fill = _fill(tester, 'き');
    final Text stroke = _stroke(tester, 'き');
    expect(fill.style?.fontFamily, 'A-OTF Shin Maru Go Pr6N DB');
    expect(
      fill.style?.fontFamilyFallback?.take(2),
      <String>['Microsoft YaHei UI', 'Microsoft YaHei'],
    );
    expect(fill.style?.fontSize, closeTo(65, 0.01));
    expect(fill.style?.letterSpacing, closeTo(2.5, 0.01));
    expect(fill.style?.color?.toARGB32(), 0xFFFFFFFF);
    expect(stroke.style?.foreground?.color.toARGB32(), 0xFFD93F61);
    debugDefaultTargetPlatformOverride = previousPlatform;
    expect(stroke.style?.foreground?.strokeWidth, closeTo(6, 0.01));
  });
}
