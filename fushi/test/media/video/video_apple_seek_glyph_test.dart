import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_apple_seek_glyph.dart';

void main() {
  test('SF numbered glyphs are used exactly for the seconds SF ships', () {
    expect(
      videoAppleNumberedSeekIcon(forward: false, seconds: 10),
      CupertinoIcons.gobackward_10,
    );
    expect(
      videoAppleNumberedSeekIcon(forward: true, seconds: 30),
      CupertinoIcons.goforward_30,
    );
    for (final int seconds in kVideoAppleNumberedSeekSeconds) {
      expect(
        videoAppleNumberedSeekIcon(forward: true, seconds: seconds),
        isNotNull,
      );
      expect(
        videoAppleNumberedSeekIcon(forward: false, seconds: seconds),
        isNotNull,
      );
    }
    for (final int seconds in <int>[5, 20, 120, 300]) {
      expect(
        videoAppleNumberedSeekIcon(forward: true, seconds: seconds),
        isNull,
      );
    }
  });

  testWidgets('seconds without an SF glyph draw the number over the arrow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: VideoAppleSeekGlyph(
            forward: true,
            seconds: 120,
            size: 24,
            color: Color(0xFFFFFFFF),
            semanticLabel: '+120s',
          ),
        ),
      ),
    );
    expect(find.text('120'), findsOneWidget);
  });

  testWidgets('seconds with an SF glyph draw no extra number', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: VideoAppleSeekGlyph(
            forward: false,
            seconds: 30,
            size: 24,
            color: Color(0xFFFFFFFF),
          ),
        ),
      ),
    );
    expect(find.text('30'), findsNothing);
  });
}
