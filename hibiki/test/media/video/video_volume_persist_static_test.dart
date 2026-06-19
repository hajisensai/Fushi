import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-451 guard: video volume is remembered per video bookUid.
///
/// media_kit Player cannot be constructed in the host unit-test environment, so
/// this locks the persistence wiring at source level. Behavior covered here:
/// - preference key is video_volume_<bookUid>, never per episode;
/// - local and remote loads read the value before controller.load;
/// - controller.load receives and applies initialVolume before autoPlay;
/// - real volume changes persist, but temporary M mute does not;
/// - pending writes debounce and flush on lifecycle / dispose / process exit.
void main() {
  final File pageFile = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );
  final File controllerFile = File(
    'lib/src/media/video/video_player_controller.dart',
  );

  late String page;
  late String controller;

  setUpAll(() {
    expect(pageFile.existsSync(), isTrue);
    expect(controllerFile.existsSync(), isTrue);
    page = pageFile.readAsStringSync();
    controller = controllerFile.readAsStringSync();
  });

  String region(String src, String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  String methodBody(String src, String startSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final List<int> ends = <int>[
      src.indexOf('\n  String ', start + startSig.length),
      src.indexOf('\n  double ', start + startSig.length),
      src.indexOf('\n  void ', start + startSig.length),
      src.indexOf('\n  Future', start + startSig.length),
      src.indexOf('\n  Widget ', start + startSig.length),
      src.indexOf('\n  Material', start + startSig.length),
      src.indexOf('\n  @override', start + startSig.length),
    ].where((int i) => i > start).toList();
    final int end = ends.isEmpty
        ? src.length
        : ends.reduce((int a, int b) => a < b ? a : b);
    return src.substring(start, end);
  }

  group('preference key and initial read', () {
    test('uses video_volume_<bookUid> and never episode-indexed keys', () {
      expect(
        page,
        contains(
            r"String get _volumePrefKey => 'video_volume_${widget.bookUid}'"),
        reason: 'single videos and playlists both key by the video bookUid',
      );
      final String keyRegion = region(
        page,
        'String get _volumePrefKey',
        'double _readPersistedVolume',
      );
      expect(keyRegion, isNot(contains('_currentEpisode')),
          reason: 'playlist episodes must share one volume value');
      expect(keyRegion, isNot(contains('positionMs')),
          reason: 'volume key must not use per-episode progress data');
    });

    test('default is 100 and persisted values clamp to 0..100', () {
      expect(page, contains('double _playbackVolume = 100.0'),
          reason: 'new videos default to 100 volume');
      final String read = methodBody(page, 'double _readPersistedVolume()');
      expect(read, contains('getPref(_volumePrefKey, defaultValue: 100.0)'));
      expect(read, contains('clamp(0.0, 100.0)'));
    });

    test('local and remote init read volume before loading media', () {
      final String localInit = region(
        page,
        'Future<void> _init() async {',
        'Future<void> _initRemote() async {',
      );
      expect(localInit.indexOf('_playbackVolume = _readPersistedVolume()'),
          lessThan(localInit.indexOf('_loadSingle(row)')),
          reason: 'local single-video load must see persisted volume first');
      expect(localInit.indexOf('_playbackVolume = _readPersistedVolume()'),
          lessThan(localInit.indexOf('_loadEpisode(')),
          reason: 'playlist load must see shared persisted volume first');

      final String remoteInit = region(
        page,
        'Future<void> _initRemote() async {',
        'String get _speedPrefKey',
      );
      expect(remoteInit.indexOf('_playbackVolume = _readPersistedVolume()'),
          lessThan(remoteInit.indexOf('_applyLoad(')),
          reason: 'remote load must also apply the saved bookUid volume');
    });

    test('_applyLoad passes initialVolume and syncs display from controller',
        () {
      final String applyLoad = methodBody(
        page,
        'Future<void> _applyLoad({',
      );
      expect(applyLoad, contains('initialVolume: _playbackVolume'));
      expect(applyLoad, contains('_syncVolumeDisplay(controller.volume)'),
          reason:
              'after load, icon / popover display must match actual volume');
    });
  });

  group('controller initialVolume handoff', () {
    test('load accepts initialVolume with default 100', () {
      final String loadSig = region(
        controller,
        'Future<void> load({',
        '}) async {',
      );
      expect(loadSig, contains('double initialVolume = 100.0'));
    });

    test('initialVolume is applied after open and before autoPlay', () {
      final String loadBody = methodBody(controller, 'Future<void> load({');
      final int open = loadBody.indexOf('await player.open(Media(sourceUri)');
      final int lastVolume = loadBody.indexOf('_lastVolume = initialVolume');
      final int setVolume =
          loadBody.indexOf('await player.setVolume(initialVolume)');
      // BUG-342: autoPlay 守卫升级为 _isCurrentLoad 双判据，锚点同步更新。
      final int play = loadBody
          .indexOf('if (autoPlay && _isCurrentLoad(player, loadToken))');
      expect(open, greaterThanOrEqualTo(0));
      expect(lastVolume, greaterThan(open),
          reason:
              '_lastVolume must reflect the saved value before UI reads it');
      expect(setVolume, greaterThan(open),
          reason: 'player must receive saved volume before playback starts');
      expect(setVolume, lessThan(play),
          reason: 'avoid an audible 100 then jump back to saved volume');
    });
  });

  group('real volume changes persist, mute does not', () {
    test('real volume entrypoints use the shared persistence helper', () {
      final String slider =
          methodBody(page, 'void _setVolumeFromSlider(double value)');
      expect(slider, contains('_applyUserVideoVolume(next)'));

      final String adjust =
          methodBody(page, 'Future<void> _adjustVolume(double delta) async');
      expect(adjust, contains('_applyUserVideoVolume(next)'),
          reason: 'keyboard shortcuts and wheel path persist real volume');

      final String mediaKit =
          methodBody(page, 'void _onMediaKitVolumeChanged(double value)');
      expect(mediaKit, contains('_applyUserVideoVolume(pct)'),
          reason: 'right-half vertical drag persists real volume');
    });

    test('shared helper updates display, HUD, playback volume, and persistence',
        () {
      final String helper = methodBody(
        page,
        'Future<void> _applyUserVideoVolume(',
      );
      expect(helper, contains('controller.setVolume(clamped)'));
      expect(helper, contains('_playbackVolume = clamped'));
      expect(helper, contains('_syncVolumeDisplay(clamped)'));
      expect(helper, contains('_showVolumeOsd(clamped)'),
          reason: 'TODO-450 right-side HUD remains display-only feedback');
      expect(helper, contains('_queuePersistVideoVolume(clamped)'));
    });

    test('M mute updates display and HUD without queuing or applying a saved 0',
        () {
      final String mute = methodBody(page, 'Future<void> _toggleMute() async');
      expect(mute, contains('persist: false'));
      expect(mute, contains('applyToController: false'));
      expect(mute, contains('_applyUserVideoVolume('));
      expect(mute, contains('next,'));
      expect(mute, isNot(contains('_queuePersistVideoVolume')),
          reason: 'temporary M mute must not overwrite saved volume');
    });

    test('real volume 0 is still persisted', () {
      final String helper = methodBody(
        page,
        'Future<void> _applyUserVideoVolume(',
      );
      expect(helper, contains('persist = true'));
      expect(helper, isNot(contains('clamped > 0')),
          reason: 'explicitly dragging to 0 is a real saved volume');
      expect(helper, isNot(contains('clamped == 0')),
          reason: '0 must not be filtered out of persistence');
    });
  });

  group('debounce and flush', () {
    test('volume writes debounce, then set the per-book pref', () {
      expect(page, contains('Timer? _volumePersistDebounce'));
      final String queue =
          methodBody(page, 'void _queuePersistVideoVolume(double volume)');
      expect(queue, contains('Duration(milliseconds: 350)'),
          reason:
              'trailing debounce should stay within the planned 250 to 500 ms');
      expect(queue, contains('_flushPersistedVideoVolume()'));

      final String flush =
          methodBody(page, 'Future<void> _flushPersistedVideoVolume() async');
      expect(flush, contains('appModel.prefsRepo.setPref('));
      expect(flush, contains('_volumePrefKey'));
      expect(flush, contains('_pendingVolumePersist'));
    });

    test('pending volume flushes on lifecycle, process exit, and dispose', () {
      final String lifecycle = region(
        page,
        'void didChangeAppLifecycleState(AppLifecycleState state) {',
        'Future<void> _flushAllForProcessExit() async {',
      );
      expect(lifecycle, contains('_flushPersistedVideoVolume()'));

      final String processExit =
          methodBody(page, 'Future<void> _flushAllForProcessExit() async');
      expect(processExit, contains('await _flushPersistedVideoVolume()'));

      final String dispose = methodBody(page, 'void dispose()');
      expect(dispose, contains('_volumePersistDebounce?.cancel()'));
      expect(dispose, contains('_flushPersistedVideoVolume()'));
    });
  });
}
