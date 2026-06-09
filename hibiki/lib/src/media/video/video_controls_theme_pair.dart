import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoControlsThemePair extends StatelessWidget {
  const VideoControlsThemePair({
    super.key,
    required this.mobile,
    required this.desktop,
    required this.child,
  });

  final MaterialVideoControlsThemeData mobile;
  final MaterialDesktopVideoControlsThemeData desktop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialVideoControlsTheme(
      normal: mobile,
      fullscreen: mobile,
      child: MaterialDesktopVideoControlsTheme(
        normal: desktop,
        fullscreen: desktop,
        child: child,
      ),
    );
  }
}
