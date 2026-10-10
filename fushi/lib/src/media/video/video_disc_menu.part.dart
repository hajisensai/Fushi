part of 'video_player_controller.dart';

/// Blu-ray navigation uses the existing Player/texture. The disc VM selects
/// titles; the library only binds identity after an atomic native snapshot.
extension VideoDiscMenuController on VideoPlayerController {
  bool get isBlurayNavigationSession => _discRootPath != null;
  String? get discLoadStage => _discLoadStage;

  void _setDiscLoadStage(String stage) {
    if (!isBlurayNavigationSession || _discLoadStage == stage) return;
    _discLoadStage = stage;
    debugPrint('[video-load] disc-stage=$stage');
  }
  bool get discNavigationSupported => _discNavigationSupported;
  bool get discMenuEntryPending => _discInitialMenuPending;
  VideoDiscTrackOwner get discTrackOwner => _discTrackOwner;
  bool get discOwnsTracks => isBlurayNavigationSession &&
      _discTrackOwner == VideoDiscTrackOwner.disc;
  String? get resolvedDiscAudioTrackId => _discResolvedAudioTrackId;
  String? get resolvedDiscSubtitleTrackId => _discResolvedSubtitleTrackId;
  String? get activeAudioTrackId => isBlurayNavigationSession
      ? resolvedDiscAudioTrackId : _player?.state.track.audio.id;
  int? get activeSubtitleStreamIndex {
    final String? id = isBlurayNavigationSession
        ? resolvedDiscSubtitleTrackId : activeSubtitleTrackId;
    if (id == null || id == 'auto' || id == 'no') return null;
    return videoDiscResolvedTrackOrdinal(
      id, subtitleTracks.map((SubtitleTrack track) => track.id),
    );
  }

  /// Explicit Fushi subtitle files, Off and track selections own this visit.
  /// Persisted library choices remain candidates, not commands to the disc VM.
  void claimDiscTrackOwnership() {
    if (!isBlurayNavigationSession || _discTrackOwner == VideoDiscTrackOwner.fushi) {
      return;
    }
    _discTrackOwner = VideoDiscTrackOwner.fushi;
    _notifyDiscMenuChanged();
  }

  void _onDiscTracksChanged(Player player) {
    if (!identical(_player, player) || !isBlurayNavigationSession ||
        !_discNavigationOpened) {
      return;
    }
    unawaited(_sampleDiscMenu(player, _loadToken));
    _notifyDiscMenuChanged();
  }
  VideoDiscNavigationState? get discNavigationState => _discState;
  int get discTitleGeneration => _discTitleGeneration;
  bool get discMenuActive =>
      isBlurayNavigationSession &&
      (_discInitialMenuPending || _discState == null ||
          _discState!.menuActive || _discState!.menuDomain);
  String? get selectedDiscPlaylistPath => _selectedDiscPlaylistPath;
  String? get discMenuError => _discMenuError;
  bool get discMiningAvailable => discTitleReady && _discMiningAvailable &&
      _discResolvedTracksGeneration == _discTitleGeneration &&
      (realAudioStreamCount == 0 || videoDiscResolvedTrackOrdinal(
        _discResolvedAudioTrackId, audioTracks.map((AudioTrack track) => track.id),
      ) != null);
  String? get discMiningUnavailableReason => !discTitleReady
      ? 'title-not-ready'
      : _discResolvedTracksGeneration != _discTitleGeneration
      ? 'title-not-ready'
      : _discResolvedAudioTrackId == 'no' && realAudioStreamCount > 0
      ? 'audio-track-unavailable'
      : _discMiningAvailable
      ? null
      : _discExtractionError ?? 'extraction-source-unavailable';
  bool get discTitleReady =>
      isBlurayNavigationSession &&
      !_discInitialMenuPending &&
      _discState?.allowsStudy == true &&
      _boundDiscPlaylistPath != null &&
      _boundDiscPlaylistPath == _selectedDiscPlaylistPath;

  void _resetDiscMenu() {
    _discJavaRuntimeProbe?.cancel();
    _discJavaRuntimeProbe = null;
    _discRootPath = null;
    _discState = null;
    _selectedDiscPlaylistPath = null;
    _boundDiscPlaylistPath = null;
    _discMenuError = null;
    _discLoadStage = null;
    _discTitleGeneration++;
    _discSampleFuture = null;
    _discMiningAvailable = false;
    _discExtractionError = null;
    _discNavigationSupported = false;
    _discNavigationOpened = false;
    _discInitialMenuPending = false;
    _discInitialMenuRequested = false;
    _discTrackOwner = VideoDiscTrackOwner.disc;
    _discAacsState = BlurayMenuAacsState.notProtected;
    _discNavigationConfirmed = false;
    _clearDiscResolvedTracks();
  }

  Future<void> _prepareDiscMenu(Player player, int loadToken) async {
    if (!isBlurayNavigationSession && !_discMenuConfigured) return;
    final dynamic native = player.platform;
    // load() already awaited native initialization through its pre-open setup.
    // Read synchronously inside media_kit so disposal cannot slip between an
    // internal initialization await and access to the native handle.
    _setDiscLoadStage('disc-capability');
    final String option =
        await native.getProperty('option-info/disc-menu/name', waitForInitialization: false) as String;
    if (!_isCurrentLoad(player, loadToken)) return;
    if (!isBlurayNavigationSession) {
      if (option.isNotEmpty) {
        runCheckedVideoDiscCommand(native, <String>['set', 'disc-menu', 'no']);
      }
      _discMenuConfigured = false;
      return;
    }
    // Reused Players can still hold the previous disc's demuxer. Dispose that
    // stream before setting a new device, without replacing Player or texture.
    _setDiscLoadStage('disc-stop');
    runCheckedVideoDiscCommand(native, <String>['stop']);
    _setDiscLoadStage('disc-index');
    final BlurayMenuInfo? info = await readBlurayMenuInfo(_discRootPath!);
    if (!_isCurrentLoad(player, loadToken)) return;
    if (info == null) throw const VideoDiscMenuException('invalid-disc-index');
    if (!info.hasMenu) {
      throw const VideoDiscMenuException('disc-has-no-menu');
    }
    _discInitialMenuPending = info.hasTopMenu;
    if (option.isEmpty) {
      throw const VideoDiscMenuException('navigation-not-supported');
    }
    // Our versioned snapshot separates IG menu focus from PGS subtitles and
    // correlates title, playlist, generation and timestamp in one native read.
    final String properties =
        await native.getProperty('property-list', waitForInitialization: false) as String;
    if (!_isCurrentLoad(player, loadToken)) return;
    if (!properties.contains('disc-navigation-state-json')) {
      throw const VideoDiscMenuException('navigation-state-not-supported');
    }
    String? javaHome;
    if (info.requiresJava) {
      _setDiscLoadStage('disc-java');
      final BlurayJavaRuntimeManager manager = BlurayJavaRuntimeManager();
      _discJavaRuntimeProbe = manager;
      try {
        javaHome = await manager.probeJavaHome();
      } finally {
        if (identical(_discJavaRuntimeProbe, manager)) {
          _discJavaRuntimeProbe = null;
        }
      }
    }
    if (!_isCurrentLoad(player, loadToken)) return;
    // libbluray decrypts menus, IG and titles itself through libaacs. Register
    // this disc's KEYDB key with the bundled module before it opens the disc;
    // an encrypted disc without a key fails here with the KEYDB guidance.
    _setDiscLoadStage('disc-aacs');
    final BlurayMenuAacsState aacs =
        await prepareBlurayMenuAacs(_discRootPath!);
    if (!_isCurrentLoad(player, loadToken)) return;
    _discAacsState = aacs;
    // An empty per-player override lets libbluray use its documented system
    // runtime discovery. Clear a previous disc's private override on reuse.
    _setDiscLoadStage('disc-properties');
    runCheckedVideoDiscCommand(native, <String>[
      'set',
      'bluray-java-home',
      javaHome ?? '',
    ]);
    runCheckedVideoDiscCommand(native, <String>[
      'set',
      'bluray-device',
      _discRootPath!,
    ]);
    runCheckedVideoDiscCommand(native, <String>['set', 'disc-menu', 'yes']);
    // Earlier regular-video loads suppress native subtitles for Flutter cues.
    // A disc VM owns its PGS selection; restore visibility before opening it.
    runCheckedVideoDiscCommand(native, <String>['set', 'sid', 'auto']);
    runCheckedVideoDiscCommand(native, <String>['set', 'aid', 'auto']);
    runCheckedVideoDiscCommand(native, <String>['set', 'secondary-sid', 'no']);
    runCheckedVideoDiscCommand(native, <String>['set', 'sub-delay', '0']);
    _delayMs = 0;
    _secondaryDelayMs = null;
    runCheckedVideoDiscCommand(native, <String>[
      'set',
      'sub-visibility',
      'yes',
    ]);
    _discMenuConfigured = true;
    // Clear sticky start from a preceding regular-video load before the VM runs.
    _setDiscLoadStage('disc-start-reset');
    await clearMpvStartPosition(player);
    if (!_isCurrentLoad(player, loadToken)) return;
    _discNavigationSupported = true;
    if (!identical(_discObservedPlayer, player)) {
      // One observer per Player. A late event only prompts a fresh atomic read
      // for the current load; it never carries the previous title's identity.
      _discObservedPlayer = player;
      _setDiscLoadStage('disc-observer');
      await native.observeProperty('disc-navigation-state-json', (
        String _,
      ) async {
        if (identical(_player, player) && isBlurayNavigationSession) {
          await _sampleDiscMenu(player, _loadToken);
        }
      }, waitForInitialization: false);
    }
    _setDiscLoadStage('disc-prepared');
  }

  Future<void> discNavigation(String action) async {
    final List<String> command = videoDiscNavigationCommand(action);
    await _sendDiscCommand(command);
  }

  /// Clicks the authored button at normalized video coordinates (select +
  /// activate in one native step). There is deliberately no hover counterpart:
  /// see [videoDiscNavigationCommand].
  Future<void> clickDiscMenu(double x, double y) async {
    await _sendDiscCommand(
      videoDiscNavigationCommand('mouse-click', x: x, y: y),
    );
  }

  Future<void> _sendDiscCommand(List<String> command) async {
    final Player? player = _player;
    final int token = _loadToken;
    if (player == null ||
        !isBlurayNavigationSession ||
        !_discNavigationOpened ||
        !_discNavigationSupported) {
      throw const VideoDiscMenuException('navigation-not-active');
    }
    if (_discInitialMenuPending) {
      throw const VideoDiscMenuException('navigation-initializing');
    }
    final dynamic native = player.platform;
    await native.getProperty('mpv-version', waitForInitialization: false);
    if (!_isCurrentLoad(player, token)) return;
    runCheckedVideoDiscCommand(native, command);
    // A sampler already in flight may have read the pre-command title. Wait
    // for it, then read again so completion means a post-command snapshot.
    await _discSampleFuture;
    if (!_isCurrentLoad(player, token)) return;
    await _sampleDiscMenu(player, token);
  }

  Future<void> _sampleDiscMenu(Player player, int loadToken) {
    if (!_isCurrentLoad(player, loadToken) || !_discNavigationOpened) {
      return Future<void>.value();
    }
    final Future<void>? pending = _discSampleFuture;
    if (pending != null) return pending;
    final Future<void> next = _readDiscMenu(player, loadToken);
    _discSampleFuture = next;
    return next.whenComplete(() {
      if (identical(_discSampleFuture, next)) _discSampleFuture = null;
    });
  }

  Future<void> _readDiscMenu(Player player, int loadToken) async {
    try {
      final dynamic native = player.platform;
      final String raw =
          await native.getProperty('disc-navigation-state-json', waitForInitialization: false) as String;
      if (!_isCurrentLoad(player, loadToken)) return;
      final VideoDiscNavigationState? next = VideoDiscNavigationState.parse(
        raw,
      );
      if (next == null) {
        // No loaded demuxer yet. Never borrow the previous title's identity.
        _invalidateDiscTitle();
        return;
      }
      if (!next.navigationActive || (next.bdjDetected && !next.bdjHandled)) {
        final String error = next.bdjDetected && !next.bdjHandled
            ? 'java-runtime-unavailable'
            : 'navigation-open-failed';
        _invalidateDiscTitle();
        if (_discMenuError != error) {
          _discMenuError = error;
          onPlaybackError?.call(VideoDiscMenuException(error).toString());
          _notifyDiscMenuChanged();
        }
        return;
      }
      _discNavigationConfirmed = true;
      final VideoDiscNavigationState? previous = _discState;
      if (shouldReturnDiscTrackOwnership(
        owner: _discTrackOwner, previous: previous, next: next,
      )) {
        _returnDiscTrackOwnership(player);
      }
      if (_discInitialMenuPending) {
        final VideoDiscMenuEntryAction action = videoDiscMenuEntryAction(
          next, requested: _discInitialMenuRequested,
        );
        if (action == VideoDiscMenuEntryAction.complete) {
          _discInitialMenuPending = false;
        } else {
          _discState = next;
          if (action == VideoDiscMenuEntryAction.requestTopMenu) {
            // Mark before dispatch: a rejected command is visible and never
            // retried by the sampling loop or allowed to bind a movie instead.
            _discInitialMenuRequested = true;
            runCheckedVideoDiscCommand(native, <String>['discnav', 'menu']);
          }
          if (previous?.generation != next.generation ||
              previous?.menuActive != next.menuActive ||
              previous?.menuCallAllowed != next.menuCallAllowed) {
            _notifyDiscMenuChanged();
          }
          return;
        }
      }
      final String? name = next.playlistFileName;
      final String? path = name == null
          ? null
          : p.join(_discRootPath!, 'BDMV', 'PLAYLIST', name);
      final bool changed =
          path != _selectedDiscPlaylistPath ||
          previous?.generation != next.generation || previous?.angle != next.angle;
      if (changed) _invalidateDiscTitle();
      _discState = next;
      _selectedDiscPlaylistPath = path;
      if (next.isTitle) {
        if (!await _refreshDiscResolvedTracks(player, loadToken, next)) {
          return;
        }
        if (!_isCurrentLoad(player, loadToken)) return;
      }
      if (changed ||
          previous?.menuActive != next.menuActive ||
          previous?.menuDomain != next.menuDomain ||
          previous?.stable != next.stable) {
        _notifyDiscMenuChanged();
      }
      if (discTitleReady) {
        _markMediaOpenedIfEvident(player);
        updateCueForPosition((next.positionSeconds * 1000).round());
      }
    } on Object catch (error) {
      if (_isCurrentLoad(player, loadToken)) {
        _invalidateDiscTitle();
        final String message = error.toString();
        if (_discMenuError != message) {
          _discMenuError = message;
          onPlaybackError?.call(message);
          _notifyDiscMenuChanged();
        }
      }
    }
  }

  /// libbluray reports why a disc cannot open (AACS, BD+, unreadable index)
  /// only as a native `bd` error; mpv then gives a generic "No protocol
  /// handler" `stream` error and the player stays idle with no snapshot.
  /// Until the first navigation snapshot confirms the disc opened, either one
  /// fails the session visibly and records libbluray's actual reason.
  void _onDiscNativeLog(Player player, PlayerLog log) {
    if (!identical(_player, player) ||
        !isBlurayNavigationSession ||
        _discNavigationConfirmed ||
        _discMenuError != null ||
        (_discLoadStage != 'open' && !_discNavigationOpened) ||
        !isVideoDiscOpenFailureLog(prefix: log.prefix, level: log.level)) {
      return;
    }
    _invalidateDiscTitle();
    _discMenuError = 'navigation-open-failed';
    onPlaybackError?.call(
      '${const VideoDiscMenuException('navigation-open-failed')}: '
      '[${log.prefix.trim()}] ${log.text.trim()}',
    );
    _notifyDiscMenuChanged();
  }

  void _invalidateDiscTitle() {
    if (_selectedDiscPlaylistPath == null &&
        _boundDiscPlaylistPath == null &&
        _bookUid == null &&
        _videoPath == null &&
        _cues.isEmpty &&
        _discState == null) {
      return;
    }
    _discTitleGeneration++;
    _clearDiscResolvedTracks();
    _discState = null;
    _boundDiscPlaylistPath = null;
    _selectedDiscPlaylistPath = null;
    _videoPath = null;
    _miningSourceOverride = null;
    _miningAudioSourceOverride = null;
    _bookUid = null;
    _mediaOpened = false;
    _discMiningAvailable = false;
    _discExtractionError = null;
    _lastSavedSec = -1;
    _stopPlayerDecodedText();
    final bool hadSecondaryTrack = _secondaryPlayerDecodedTextSub != null;
    _stopSecondaryPlayerDecodedText(resetPlayerTrack: false);
    if (hadSecondaryTrack && _player != null) {
      runCheckedVideoDiscCommand(_player!.platform, <String>[
        'set', 'secondary-sid', 'no',
      ]);
    }
    _graphicSubtitleActive = false;
    _secondaryCues = <AudioCue>[];
    _secondaryDrawingCues = <AudioCue>[];
    _activeSecondaryCueIndices = const <int>[];
    _activeSecondaryDrawingIndices = const <int>[];
    _blurayChapters = null;
    _clearChaptersForNewLoad();
    _clearRestoreGuard();
    _setPendingSeekLanding(null);
    setCues(const <AudioCue>[]);
  }

  void _returnDiscTrackOwnership(Player player) {
    _invalidateDiscTitle();
    final dynamic native = player.platform;
    for (final List<String> command in <List<String>>[
      <String>['set', 'secondary-sid', 'no'],
      <String>['set', 'sid', 'auto'],
      <String>['set', 'aid', 'auto'],
      <String>['set', 'sub-visibility', 'yes'],
      <String>['set', 'sub-delay', '0'],
    ]) {
      runCheckedVideoDiscCommand(native, command);
    }
    _delayMs = 0;
    _secondaryDelayMs = null;
    _discTrackOwner = VideoDiscTrackOwner.disc;
    _notifyDiscMenuChanged();
  }

  void _clearDiscResolvedTracks() {
    _discResolvedAudioTrackId = null;
    _discResolvedSubtitleTrackId = null;
    _discResolvedSubtitleCodec = null;
    _discResolvedTracksGeneration = null;
  }

  Future<bool> _refreshDiscResolvedTracks(
    Player player,
    int loadToken,
    VideoDiscNavigationState expected,
  ) async {
    final int generation = _discTitleGeneration;
    final dynamic native = player.platform;
    // All calls execute their native read before the returned Future completes
    // (initialization is already finished). Re-read the disc epoch afterward so
    // a track switch from a new title cannot attach to the previous MPLS.
    final List<String> values = await Future.wait<String>(<Future<String>>[
      native.getProperty('current-tracks/audio/id', waitForInitialization: false) as Future<String>,
      native.getProperty('current-tracks/sub/id', waitForInitialization: false) as Future<String>,
      native.getProperty('current-tracks/sub/codec', waitForInitialization: false) as Future<String>,
      native.getProperty('disc-navigation-state-json', waitForInitialization: false) as Future<String>,
    ]);
    if (!_isCurrentLoad(player, loadToken) || generation != _discTitleGeneration) {
      return false;
    }
    final VideoDiscNavigationState? confirmed = VideoDiscNavigationState.parse(values[3]);
    if (!videoDiscTitleIdentityMatches(expected, confirmed)) {
      _invalidateDiscTitle();
      return false;
    }
    final VideoDiscResolvedTracks resolved = VideoDiscResolvedTracks.fromMpv(
      audioId: values[0], subtitleId: values[1], subtitleCodec: values[2], stable: true,
    );
    final String? audioId = resolved.audioId;
    final String? subtitleId = resolved.subtitleId;
    final String? codec = resolved.subtitleCodec;
    final bool changed = _discResolvedAudioTrackId != audioId ||
        _discResolvedSubtitleTrackId != subtitleId || _discResolvedSubtitleCodec != codec;
    _discResolvedAudioTrackId = audioId;
    _discResolvedSubtitleTrackId = subtitleId;
    _discResolvedSubtitleCodec = codec;
    _discResolvedTracksGeneration = audioId != null && subtitleId != null ? generation : null;
    if (discOwnsTracks) {
      _graphicSubtitleActive = subtitleFormatForCodec(codec ?? '') == null;
    }
    if (changed) _notifyDiscMenuChanged();
    return true;
  }

  /// Enumerate the live demuxer's subtitle tracks, including discs whose local
  /// files remain encrypted. streamIndex is subtitle-relative (0:s:N), not the
  /// global ff-index; this matches selectEmbeddedGraphicTrack's mapping.
  Future<List<SubtitleSource>> discSubtitleSources({String? langCode}) async {
    final Player? player = _player;
    final int token = _loadToken;
    final int generation = _discTitleGeneration;
    if (player == null || !discTitleReady) return const <SubtitleSource>[];
    await _waitUntilSubtitleTracksReady(player);
    if (!_isCurrentLoad(player, token) || generation != _discTitleGeneration) {
      return const <SubtitleSource>[];
    }
    final List<SubtitleTrack> real = player.state.tracks.subtitle
        .where((SubtitleTrack track) => track.id != 'auto' && track.id != 'no')
        .toList(growable: false);
    return <SubtitleSource>[
      for (int index = 0; index < real.length; index++)
        if (!real[index].uri && !real[index].data)
          SubtitleSource.embedded(
            streamIndex: index,
            codec: real[index].codec,
            language: real[index].language,
            label: embeddedSubtitleTrackLabel(
              EmbeddedSubtitleTrack(
                streamIndex: index,
                codec: real[index].codec ?? '',
                language: real[index].language,
                title: real[index].title,
              ),
            ),
          ),
    ];
  }

  /// Bind the current native title to its library row without reopening Player.
  /// The page resolves the exact MPLS path; delayed results from previous titles
  /// cannot replace the current identity. Keep MPLS so ffmpeg uses the same axis.
  Future<void> bindDiscTitle({
    required String playlistPath,
    required String bookUid,
    int? expectedGeneration,
  }) async {
    final int generation = _discTitleGeneration;
    final int token = _loadToken;
    final Player? player = _player;
    if (player == null ||
        (expectedGeneration != null && expectedGeneration != generation) ||
        playlistPath != _selectedDiscPlaylistPath ||
        _discState?.isTitle != true) {
      return;
    }
    final BluraySource? source = await resolveBluraySource(playlistPath);
    if (!_isCurrentLoad(player, token) || generation != _discTitleGeneration) {
      return;
    }
    if (source == null) {
      throw const VideoDiscMenuException('playlist-unavailable');
    }
    final String? extractionError = await _checkDiscExtractionSource(playlistPath);
    if (!_isCurrentLoad(player, token) || generation != _discTitleGeneration) {
      return;
    }
    // libbluray can play decrypted packets while the files on disk remain
    // encrypted. A valid title identity must not authorize raw-file extraction.
    _videoPath = extractionError != null ? null : playlistPath;
    _discMiningAvailable = extractionError == null;
    _discExtractionError = extractionError;
    _bookUid = bookUid;
    _boundDiscPlaylistPath = playlistPath;
    _blurayChapters = source.chapters;
    // A bind establishes identity only; it must not send sid/aid, revive old
    // cues, or overwrite an explicit selection made while identity was loading.
    if (_cues.isEmpty) {
      _graphicSubtitleActive = subtitleFormatForCodec(
        _discResolvedSubtitleCodec ?? '',
      ) == null;
    }
    _markMediaOpenedIfEvident(player);
    await _refreshChaptersForLoad(player, token);
    if (!_isCurrentLoad(player, token) || generation != _discTitleGeneration) {
      return;
    }
    _notifyDiscMenuChanged();
  }

  Future<String?> _checkDiscExtractionSource(String playlistPath) async {
    if (_discState?.angle != 0) return 'multi-angle-source';
    final String? root = blurayDiscRootForPlaylistPath(playlistPath);
    if (root == null) return 'extraction-source-unavailable';
    try {
      final BlurayPlaylist? playlist = parseBlurayPlaylist(
        await File(playlistPath).readAsBytes(),
        id: p.basenameWithoutExtension(playlistPath),
      );
      if (playlist == null || playlist.clipIds.isEmpty) {
        return 'extraction-source-unavailable';
      }
      // A playlist can start with a clear studio clip then reference encrypted
      // feature clips. Checking only its primary stream falsely authorizes it.
      for (final String clip in playlist.clipIds.toSet()) {
        final String stream = p.join(root, 'BDMV', 'STREAM', '$clip.m2ts');
        if (!await File(stream).exists()) return 'extraction-source-unavailable';
        // A keyed disc decrypts for FFmpeg too: the shared backend resolves the
        // same exact KEYDB entry through AacsMediaSession.
        if (_discAacsState != BlurayMenuAacsState.keyed &&
            await isAacsEncryptedStreamFile(stream)) {
          return 'encrypted-extraction-source';
        }
      }
      return null;
    } on FileSystemException {
      return 'extraction-source-unavailable';
    }
  }
}
