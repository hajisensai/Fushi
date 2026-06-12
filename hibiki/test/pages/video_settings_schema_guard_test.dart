import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String destinationSrc;
  late String schemaSrc;

  setUpAll(() {
    destinationSrc =
        File('lib/src/settings/settings_destination.dart').readAsStringSync();
    schemaSrc =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
  });

  test('TODO-186: global settings has a dedicated video destination', () {
    expect(destinationSrc.contains('video,'), isTrue,
        reason: 'SettingsDestinationId must include a dedicated video tab');
    expect(schemaSrc.contains('_videoDestination(),'), isTrue,
        reason:
            'buildSettingsSchema must expose video settings as a top-level destination');
    expect(schemaSrc.contains('id: SettingsDestinationId.video'), isTrue,
        reason: 'missing concrete video SettingsDestination');
    expect(schemaSrc.contains('title: t.settings_destination_video'), isTrue,
        reason: 'video destination title must be i18n-backed');
  });

  test('TODO-186: video destination owns persistent video playback settings',
      () {
    final int start =
        schemaSrc.indexOf('SettingsDestination _videoDestination()');
    expect(start, greaterThanOrEqualTo(0), reason: 'missing _videoDestination');
    final int end =
        schemaSrc.indexOf('SettingsDestination _listeningDestination()', start);
    expect(end, greaterThan(start),
        reason: 'video destination should sit before listening');
    final String body = schemaSrc.substring(start, end);

    for (final String id in <String>[
      'video.playback.immersive_mode',
      'video.playback.picture_fit',
      'video.playback.double_tap',
      'video.playback.lock_window_aspect',
      'video.subtitle.blur',
    ]) {
      expect(body.contains("id: '$id'"), isTrue,
          reason: 'video destination should own $id');
    }
  });
}
