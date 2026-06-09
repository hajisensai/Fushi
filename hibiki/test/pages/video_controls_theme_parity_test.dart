import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:hibiki/src/media/video/video_controls_theme_pair.dart';

void main() {
  testWidgets('windowed and fullscreen resolve the identical control themes',
      (WidgetTester tester) async {
    const MaterialVideoControlsThemeData mobile =
        MaterialVideoControlsThemeData(
      buttonBarHeight: 61,
      buttonBarButtonSize: 31,
    );
    const MaterialDesktopVideoControlsThemeData desktop =
        MaterialDesktopVideoControlsThemeData(
      buttonBarHeight: 63,
      buttonBarButtonSize: 33,
    );

    late MaterialVideoControlsTheme mobileScope;
    late MaterialDesktopVideoControlsTheme desktopScope;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoControlsThemePair(
          mobile: mobile,
          desktop: desktop,
          child: Builder(
            builder: (BuildContext context) {
              mobileScope = MaterialVideoControlsTheme.of(context);
              desktopScope = MaterialDesktopVideoControlsTheme.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(identical(mobileScope.normal, mobileScope.fullscreen), isTrue);
    expect(identical(desktopScope.normal, desktopScope.fullscreen), isTrue);
    expect(mobileScope.normal.buttonBarHeight, 61);
    expect(mobileScope.fullscreen.buttonBarButtonSize, 31);
    expect(desktopScope.normal.buttonBarHeight, 63);
    expect(desktopScope.fullscreen.buttonBarButtonSize, 33);
  });
}
