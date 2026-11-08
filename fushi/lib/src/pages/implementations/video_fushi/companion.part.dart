part of '../video_fushi_page.dart';

/// The video page as the second-screen companion sees it ([VideoCompanionHook],
/// `second_screen/companion/modules/video_companion_hook.dart`). Every control
/// goes through the same executors as the desktop remote control
/// ([_VideoPagePlaybackRemote]) or the page's own subtitle list, so the panel
/// behaves exactly like the buttons on top. Nothing here runs while the
/// companion is not up (the hook only calls in from its snapshot tick and
/// from panel commands).
class _VideoCompanionPageAdapter implements VideoCompanionPage {
  _VideoCompanionPageAdapter(this._state);

  final _VideoFushiPageState _state;

  _VideoPagePlaybackRemote get _remote => _state._playbackRemote;

  VideoPlayerController? get _controller =>
      _state.mounted ? _state._controller : null;

  @override
  String? get title => _state.mounted ? _state._title : null;

  @override
  bool get playing => _controller?.isPlaying ?? false;

  @override
  VideoCompanionFrame? frame() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    final int episodes = _state._episodes.length;
    return VideoCompanionFrame(
      bookUid: _state._activeBookUid,
      collectionId: _state.widget.playlistCollectionId,
      title: _state._title ?? '',
      series: _state._playlistTitle,
      coverPath: _state._bookRow?.coverPath,
      episodeIndex: episodes > 1 ? _state._currentEpisode : -1,
      episodeCount: episodes,
      playing: controller.isPlaying,
      positionMs: controller.positionMs ?? 0,
      durationMs: controller.durationMs ?? 0,
      speed: controller.speed,
      cues: controller.cues,
      currentCueIndex: controller.currentCueIndex,
      audioTracks: <VideoCompanionTrack>[
        for (final AudioTrack track in controller.audioTracks)
          VideoCompanionTrack(
            id: track.id,
            label: _state._trackLabel(track.title, track.language, track.id),
            selected: _state._currentAudioTrackId == track.id,
          ),
      ],
      subtitleSource: _state._currentSubtitleSource,
      autoPause: controller.autoPauseAtCueEnd,
      loopOn: controller.loopCurrentCue,
      loopTimes: controller.loopRepeatTimes,
      loopRemaining: controller.loopRepeatsRemaining,
      abAMs: controller.abLoopA?.inMilliseconds,
      abBMs: controller.abLoopB?.inMilliseconds,
    );
  }

  @override
  Future<List<VideoCompanionTrack>> subtitleTracks() async {
    if (_controller == null) return const <VideoCompanionTrack>[];
    final VideoRemoteSubtitleState state;
    try {
      state = await _remote.subtitleState();
    } on VideoRemoteFailure catch (error) {
      // The player went away meanwhile: no list (the next video loads one).
      ErrorLogService.instance.logDiagnostic(
        'VideoCompanion.subtitleTracks',
        error,
      );
      return const <VideoCompanionTrack>[];
    }
    return <VideoCompanionTrack>[
      for (final VideoRemoteSubtitleTrack track in state.tracks)
        if (track.selectable)
          VideoCompanionTrack(
            id: track.source,
            label: track.label,
            selected: track.primary,
          ),
    ];
  }

  @override
  Future<VideoCompanionInfo?> loadInfo(String bookUid, int? collectionId) =>
      loadVideoCompanionInfo(
        _state.appModel.database,
        bookUid: bookUid,
        collectionId: collectionId,
      );

  /// Runs a remote-control action. Its failures are the page's own: the
  /// executors already showed them on top as an OSD (subtitle / mining
  /// paths), or the action is not possible right now (no player, disc menu
  /// phase), which the panel cannot fix either — logged, not rethrown into
  /// the command dispatch.
  Future<void> _remoteAction(
    String what,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on VideoRemoteFailure catch (error) {
      ErrorLogService.instance.logDiagnostic('VideoCompanion.$what', error);
    }
  }

  @override
  Future<void> toggle() => _remoteAction('toggle', _remote.toggle);

  @override
  Future<void> previousCue() =>
      _remoteAction('previousCue', _remote.previousCue);

  @override
  Future<void> nextCue() => _remoteAction('nextCue', _remote.nextCue);

  @override
  Future<void> seekToMs(int positionMs) =>
      _remoteAction('seekTo', () => _remote.seekToMs(positionMs));

  @override
  Future<void> seekByMs(int deltaMs) =>
      _remoteAction('seekBy', () => _remote.seekByMs(deltaMs));

  /// The page's subtitle-list tap ([_VideoSubtitle._handleSubtitleJumpTap])
  /// minus waking the controls (the user's hands are on the panel).
  @override
  Future<void> jumpToCue(int startMs, String text) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final List<AudioCue> cues = controller.cues;
    final AudioCue? cue =
        cues.firstWhereOrNull(
          (AudioCue c) => c.startMs == startMs && c.text == text,
        ) ??
        cues.firstWhereOrNull((AudioCue c) => c.startMs == startMs);
    if (cue == null) return;
    _state._recordVideoCueJumpDeparture(cue, source: JumpSource.cue);
    await controller.skipToCue(cue);
  }

  @override
  Future<void> selectAudioTrack(String id) =>
      _remoteAction('selectAudio', () => _remote.selectAudioTrack(id));

  @override
  Future<void> selectSubtitle(String source) => _remoteAction(
    'selectSubtitle',
    () => _remote.selectSubtitle(source, secondary: false),
  );

  @override
  Future<void> subtitleOff() =>
      _remoteAction('subtitleOff', () => _remote.subtitleOff(secondary: false));

  @override
  Future<void> mineLine() => _remoteAction(
    'mineLine',
    () => _remote.mineCurrentCue(const <String, String>{}),
  );

  /// Line study: the same controller methods as the page's shortcuts
  /// ([_VideoFushiPageState._replayCurrentCueThenPause] etc.), without the
  /// on-top OSD (the state shows on the panel).
  @override
  Future<void> replayLineThenPause() async {
    await _controller?.replayCurrentCueThenPause();
  }

  @override
  Future<void> setAutoPause(bool on) async {
    _controller?.setAutoPauseAtCueEnd(on);
  }

  @override
  Future<void> loopLine(int times) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    if (times < 0) {
      controller.stopCueLoop();
    } else if (controller.cues.isNotEmpty) {
      controller.startCueLoop(times: times);
    }
  }

  @override
  Future<void> abLoop(VideoCompanionAbStep step) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    switch (step) {
      case VideoCompanionAbStep.setA:
        controller.setAbLoopA();
      case VideoCompanionAbStep.setB:
        controller.setAbLoopB();
      case VideoCompanionAbStep.clear:
        controller.clearAbLoop();
      case VideoCompanionAbStep.toggle:
        controller.toggleAbLoop();
    }
  }

  /// The page's own counter ([_VideoFushiPageState.recordLookup], which skips
  /// source review), so companion lookups count for this video.
  @override
  void countLookup() {
    if (_state.mounted) _state.recordLookup();
  }
}
