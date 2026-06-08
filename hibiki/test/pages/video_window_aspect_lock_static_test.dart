import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video page locks desktop window aspect ratio from decoded video size',
      () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    expect(
      source,
      contains("import 'package:window_manager/window_manager.dart';"),
    );
    expect(
      source,
      contains('_lockWindowAspectRatio = appModel.videoLockWindowAspectRatio'),
    );
    expect(source, contains('_syncWindowAspectRatioLock'));
    expect(source, contains('windowManager.setAspectRatio(aspectRatio)'));
    expect(source, contains('windowManager.setAspectRatio(0)'));
    expect(source, contains('isDesktopPlatform'));
    expect(source, contains('controller.videoWidth'));
    expect(source, contains('controller.videoHeight'));
  });

  test('video aspect-ratio lock preference defaults on', () {
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final String prefs =
        File('lib/src/models/preferences_repository.dart').readAsStringSync();

    expect(appModel, contains('bool get videoLockWindowAspectRatio'));
    expect(appModel, contains('setVideoLockWindowAspectRatio'));
    expect(prefs, contains("'video_lock_window_aspect_ratio'"));
    expect(prefs, contains('defaultValue: true'));
  });
}
