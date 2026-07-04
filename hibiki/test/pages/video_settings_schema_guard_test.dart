import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String destinationSrc;
  late String schemaSrc;
  late String videoSrc;
  late String stringsSrc;

  setUpAll(() {
    destinationSrc =
        File('lib/src/settings/settings_destination.dart').readAsStringSync();
    // TODO-586：buildSettingsSchema 组装留主文件（schemaSrc），video destination
    // 函数体随 _videoDestination 搬到 settings_schema_video.dart（videoSrc）。
    schemaSrc =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    videoSrc =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    stringsSrc = File('lib/i18n/strings.i18n.json').readAsStringSync();
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
      'video.quality.sigmoid', // TODO-1120/BUG-538 sigmoid toggle grouped here
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

  test(
      'TODO-1116/1119: Windows video quality group carries a black-flicker known-issue notice',
      () {
    final int start =
        videoSrc.indexOf('SettingsDestination buildVideoDestination()');
    final int end = videoSrc.indexOf(
      'Future<void> _commitVideoAsbConfig(',
      start,
    );
    final String body = videoSrc.substring(start, end);

    // The notice must live inside the schema (Image quality group) as a
    // dedicated custom item, gated Windows-only via the isWindowsPlatform
    // helper. Never-break-userspace: it is a pure explanation row — it must not
    // wire a switch/default that would degrade non-Windows or Windows users.
    expect(
        body.contains("id: 'video.quality.windows_black_flash_notice'"), isTrue,
        reason: 'video quality group must own the black-flicker notice item');
    expect(body.contains('isWindowsPlatform'), isTrue,
        reason: 'black-flicker notice must be gated to Windows only');
    expect(body.contains('_buildWindowsBlackFlashNotice'), isTrue,
        reason: 'notice item must delegate to its info-row builder');

    // i18n-backed, and it must be a plain info row (no new pref write / default).
    expect(
        videoSrc.contains('t.video_windows_black_flash_notice_title'), isTrue);
    expect(
        videoSrc.contains('t.video_windows_black_flash_notice_body'), isTrue);
    expect(videoSrc.contains('Icons.info_outline'), isTrue,
        reason: 'notice should render as an informational row');

    // The two i18n keys must exist in the base translations (all 17 locales are
    // kept complete by tool/i18n_sync.dart; the i18n completeness test enforces
    // the rest).
    expect(stringsSrc.contains('"video_windows_black_flash_notice_title"'),
        isTrue);
    expect(
        stringsSrc.contains('"video_windows_black_flash_notice_body"'), isTrue);
  });
}
