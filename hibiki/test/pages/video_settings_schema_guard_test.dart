import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String destinationSrc;
  late String schemaSrc;
  late String videoSrc;

  setUpAll(() {
    destinationSrc =
        File('lib/src/settings/settings_destination.dart').readAsStringSync();
    // TODO-586：buildSettingsSchema 组装留主文件（schemaSrc），video destination
    // 函数体随 _videoDestination 搬到 settings_schema_video.dart（videoSrc）。
    schemaSrc =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    videoSrc =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
  });

  test('TODO-186: global settings has a dedicated video destination', () {
    expect(destinationSrc.contains('video,'), isTrue,
        reason: 'SettingsDestinationId must include a dedicated video tab');
    expect(schemaSrc.contains('buildVideoDestination(),'), isTrue,
        reason:
            'buildSettingsSchema must expose video settings as a top-level destination');
    expect(videoSrc.contains('id: SettingsDestinationId.video'), isTrue,
        reason: 'missing concrete video SettingsDestination');
    expect(videoSrc.contains('title: t.settings_destination_video'), isTrue,
        reason: 'video destination title must be i18n-backed');
  });

  test('TODO-286: video destination owns the pref-only in-player parity set',
      () {
    final int start =
        videoSrc.indexOf('SettingsDestination buildVideoDestination()');
    expect(start, greaterThanOrEqualTo(0), reason: 'missing _videoDestination');
    final int end = videoSrc.indexOf(
      'Future<void> _commitVideoAsbConfig(',
      start,
    );
    expect(end, greaterThan(start),
        reason: 'video destination should sit before its commit helpers');
    final String body = videoSrc.substring(start, end);

    // TODO-286 parity list: every pref-only video setting that also lives in the
    // in-player VideoQuickSettingsSheet must be reachable from home settings.
    // Controller-bound items (A/V delay, live speed preview, shader download)
    // intentionally stay in-player only and are NOT listed here.
    for (final String id in <String>[
      // Playback
      'video.playback.auto_play_next', // TODO-639 auto-play-next toggle
      'video.playback.immersive_mode',
      'video.playback.picture_fit',
      'video.playback.double_tap',
      'video.playback.lock_window_aspect',
      'video.playback.long_press_speed',
      'video.playback.seek_seconds',
      'video.playback.pause_at_subtitle_end',
      // Image quality (mpv pure-pref subset)
      'video.quality.enhancement',
      'video.quality.hwdec',
      'video.quality.deband',
      'video.quality.loop',
      // Subtitle appearance
      'video.subtitle.obscure',
      'video.subtitle.font_size',
      'video.subtitle.font_weight',
      'video.subtitle.shadow',
      'video.subtitle.bg_opacity',
      'video.subtitle.no_background',
      'video.subtitle.position',
      // Danmaku
      'video.danmaku.enabled',
      'video.danmaku.online',
      'video.danmaku.max_active',
    ]) {
      expect(body.contains("id: '$id'"), isTrue,
          reason: 'video destination should own $id');
    }
  });

  test('TODO-286: home video settings stay pref-only (no live controller)', () {
    final int start =
        videoSrc.indexOf('SettingsDestination buildVideoDestination()');
    final int end = videoSrc.indexOf(
      'Future<void> _commitVideoAsbConfig(',
      start,
    );
    final String body = videoSrc.substring(start, end);

    // The whole point of TODO-286 is that these settings work with no player
    // open: they only read/write appModel-backed prefs. If anyone wires a live
    // VideoPlayerController / Player into the schema here, the "applies on next
    // play" contract breaks — fail loudly so they move it to the in-player sheet.
    for (final String forbidden in <String>[
      'VideoPlayerController',
      'controller.',
      'Player(',
    ]) {
      expect(body.contains(forbidden), isFalse,
          reason: 'home video settings must not depend on a live player '
              '($forbidden found)');
    }

    // Persistence must go through the JSON config models (pure pref), proving
    // every added item round-trips a pref rather than poking a controller.
    expect(body.contains('VideoAsbplayerConfig.decode'), isTrue);
    expect(body.contains('VideoMpvConfig.decode'), isTrue);
    expect(body.contains('VideoSubtitleStyle.decode'), isTrue);
  });

  test('TODO-522: global video settings can reset player button layout', () {
    final int start =
        videoSrc.indexOf('SettingsDestination buildVideoDestination()');
    final int end = videoSrc.indexOf(
      'Future<void> _commitVideoAsbConfig(',
      start,
    );
    final String body = videoSrc.substring(start, end);

    expect(body.contains("id: 'video.controls.reset_layout'"), isTrue);
    expect(body.contains('t.video_control_reset_layout'), isTrue);
    expect(body.contains('t.video_control_reset_layout_hint'), isTrue);
    expect(body.contains('setVideoControlLayout('), isTrue);
    expect(body.contains('VideoControlLayout.currentChrome'), isTrue);
  });
}
