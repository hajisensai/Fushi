import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-134/147 follow-up source guard: mobile video controls must not depend
/// on a top-right overflow menu. Ten-second seek buttons are gated by available
/// width, not by platform, so narrow desktop windows and narrow phones compact
/// the same way while wide controls keep the buttons.
void main() {
  final String src =
      File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  test('mobile top bar exposes actions directly without a more menu', () {
    final String body = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'void _showTrackMenu(',
    );
    final String topBar = topButtonBarRegion(body);
    expect(topBar.contains('Icons.more_vert'), isFalse,
        reason: 'mobile top bar should not depend on an overflow menu');
    expect(topBar.contains('_showMobileMoreMenu('), isFalse,
        reason: 'mobile more menu entry should stay removed');
    expect(topBar.contains('MediaQuery.of(context).size.width >= 600'), isFalse,
        reason:
            'top bar should not branch into narrow more menu / wide inline');
    expect(topBar.contains('Icons.subtitles'), isTrue,
        reason: 'subtitle source must be directly tappable in the top bar');
    expect(topBar.contains('Icons.audiotrack'), isTrue,
        reason: 'audio track must be directly tappable in the top bar');
    expect(topBar.contains('Icons.tune'), isTrue,
        reason: 'settings must be directly tappable in the top bar');
    expect(topBar.contains('Icons.photo_camera_outlined'), isTrue,
        reason: 'screenshot action must remain directly tappable');
    expect(topBar.contains('Icons.speed'), isFalse,
        reason:
            'speed remains reachable from settings without crowding top bar');
  });

  test('video bottom bars are compact by available width, not platform', () {
    final String desktopBody = region(
      'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(',
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    final String mobileBody = region(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
      'void _showTrackMenu(',
    );
    expect(
      src.contains('bool _hasRoomyVideoBottomBar() =>'),
      isTrue,
      reason: 'bottom bar width check should be shared, not mobile-only',
    );
    expect(src.contains('MediaQuery.of(context).size.width >= 600'), isTrue,
        reason: 'bottom bar should branch by available width');

    expectBottomBarUsesWidthGate(desktopBody, 'desktop');
    expectBottomBarUsesWidthGate(mobileBody, 'mobile');
  });
}

void expectBottomBarUsesWidthGate(String methodBody, String label) {
  final String bottomBar = bottomButtonBarRegion(methodBody);
  expect(
    methodBody
        .contains('final bool roomyBottomBar = _hasRoomyVideoBottomBar();'),
    isTrue,
    reason: '$label controls should use the shared width predicate',
  );
  expect(bottomBar.contains('if (roomyBottomBar)'), isTrue,
      reason: '$label controls should hide 10s buttons only on narrow widths');
  expect(bottomBar.contains('PositionIndicator'), isTrue);
  expect(bottomBar.contains('PlayOrPauseButton'), isTrue);
  expect(bottomBar.contains('_buildVolumeButton(controller'), isTrue,
      reason: '$label bottom bar should expose a volume adjustment entry');
  expect(bottomBar.contains('_buildFullscreenButton('), isTrue,
      reason: '$label bottom bar should use Hibiki neutralized fullscreen');
  expect(bottomBar.contains('Icons.replay_10'), isTrue,
      reason: '$label controls should keep -10s when width allows');
  expect(bottomBar.contains('Icons.forward_10'), isTrue,
      reason: '$label controls should keep +10s when width allows');
  expect(bottomBar.contains('Icons.skip_previous'), isTrue,
      reason: '$label controls should keep previous subtitle cue');
  expect(bottomBar.contains('Icons.skip_next'), isTrue,
      reason: '$label controls should keep next subtitle cue');
}

String topButtonBarRegion(String methodBody) {
  final int top = methodBody.indexOf('topButtonBar:');
  final int bottom = methodBody.indexOf('bottomButtonBar:');
  expect(top, greaterThanOrEqualTo(0), reason: 'missing topButtonBar');
  expect(bottom, greaterThan(top), reason: 'missing bottomButtonBar');
  return methodBody.substring(top, bottom);
}

String bottomButtonBarRegion(String methodBody) {
  final int bottom = methodBody.indexOf('bottomButtonBar:');
  final int end = methodBody.indexOf('],', bottom);
  expect(bottom, greaterThanOrEqualTo(0), reason: 'missing bottomButtonBar');
  expect(end, greaterThan(bottom), reason: 'missing bottomButtonBar end');
  return methodBody.substring(bottom, end);
}
