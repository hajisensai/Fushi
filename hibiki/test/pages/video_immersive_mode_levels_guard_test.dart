import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String modeSrc;
  late String prefsSrc;
  late String appModelSrc;
  late String pageSrc;
  late String sheetSrc;

  setUpAll(() {
    String readOrEmpty(String path) {
      final File file = File(path);
      return file.existsSync() ? file.readAsStringSync() : '';
    }

    modeSrc = readOrEmpty('lib/src/media/video/video_immersive_mode.dart');
    prefsSrc = readOrEmpty('lib/src/models/preferences_repository.dart');
    appModelSrc = File('lib/src/models/app_model.dart').readAsStringSync();
    pageSrc = File('lib/src/pages/implementations/video_hibiki_page.dart')
        .readAsStringSync();
    sheetSrc = File('lib/src/media/video/video_quick_settings_sheet.dart')
        .readAsStringSync();
  });

  test(
      'TODO-174: four persisted immersive modes exist and default to lookup-only',
      () {
    expect(modeSrc.contains('enum VideoImmersiveMode'), isTrue);
    for (final String name in <String>[
      'full',
      'seekAndLookup',
      'lookupOnly',
      'unlockOnly',
    ]) {
      expect(modeSrc.contains("$name('"), isTrue,
          reason: 'missing immersive mode $name');
    }
    expect(
        modeSrc
            .contains('static const VideoImmersiveMode fallback = lookupOnly'),
        isTrue,
        reason: 'default immersive mode must be lookup-only');
    expect(prefsSrc.contains("'video_immersive_mode'"), isTrue,
        reason: 'immersive mode must persist in preferences');
    expect(appModelSrc.contains('VideoImmersiveMode get videoImmersiveMode'),
        isTrue,
        reason: 'AppModel must expose the video immersive mode preference');
  });

  test(
      'TODO-174: player gates controls, double-tap, lookup, and shortcuts by mode',
      () {
    for (final String helper in <String>[
      'VideoImmersiveMode get _videoImmersiveMode',
      'bool get _immersiveAllowsFullControls',
      'bool get _immersiveAllowsDoubleTapSeek',
      'bool get _immersiveAllowsLookup',
      'void _runWhenImmersiveAllowsFullControls(',
    ]) {
      expect(pageSrc.contains(helper), isTrue, reason: 'missing $helper');
    }
    expect(
      pageSrc.contains('onCharTap: _handleSubtitleLookupTap,'),
      isTrue,
      reason: 'subtitle lookup must route through the runtime immersive gate',
    );
    expect(
      pageSrc.contains('if (!_immersiveAllowsLookup) return;'),
      isTrue,
      reason: 'subtitle lookup must be disabled only by unlock-only mode',
    );
    expect(
      pageSrc.contains(
          'if (_immersiveLocked.value && !_immersiveAllowsDoubleTapSeek) {'),
      isTrue,
      reason: 'double-tap seek must be mode-gated while immersive locked',
    );
    expect(
      pageSrc.contains(
          'togglePlayPause: () => _runWhenImmersiveAllowsFullControls('),
      isTrue,
      reason:
          'keyboard/media actions must be blocked outside full mode while locked',
    );
  });

  test('TODO-174: video settings sheet exposes the four-mode selector', () {
    expect(sheetSrc.contains('initialImmersiveMode'), isTrue);
    expect(sheetSrc.contains('onImmersiveModeChanged'), isTrue);
    expect(sheetSrc.contains('Widget _buildImmersiveModeRow()'), isTrue);
    expect(sheetSrc.contains('VideoImmersiveMode.values'), isTrue);
    expect(sheetSrc.contains('_buildImmersiveModeRow(),'), isTrue,
        reason:
            'immersive selector must live in the playback video settings group');
  });
}
