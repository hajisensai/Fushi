part of '../video_fushi_page.dart';

/// The disc supplies the picture and buttons. Flutter only forwards input and
/// binds a selected physical playlist to the existing learning pipeline.
extension _VideoDiscMenu on _VideoFushiPageState {
  Future<bool> _ensureDiscMenuRuntime(String playlistPath) async {
    final String? root = blurayDiscRootForPlaylistPath(playlistPath);
    if (root == null) return true; // Controller reports malformed input.
    try {
      final BlurayMenuInfo? info = await readBlurayMenuInfo(root);
      if (!mounted) return false;
      if (info?.requiresJava != true) return true;
      final BlurayJavaRuntimeManager manager = BlurayJavaRuntimeManager();
      if (await manager.probeJavaHome() != null) return mounted;
      if (!mounted) return false;
      if (!manager.canInstall) {
        if (!Platform.isWindows) return true;
        throw const VideoDiscMenuException('java-runtime-unavailable');
      }
      final bool installed =
          await _focusOwnership.guardOverlay(
            () => showAppDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => _BlurayJavaRuntimeInstallDialog(manager: manager),
            ),
          ) ??
          false;
      if (!installed && mounted) {
        _rebuild(() {
          _failed = true;
          _failReason = t.video_disc_runtime_required;
        });
      }
      return installed && mounted;
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.runtime', error, stack);
      if (mounted) {
        _rebuild(() {
          _failed = true;
          _failReason = t.video_disc_runtime_required;
        });
      }
      return false;
    }
  }

  bool _discExtractionAllowed(VideoPlayerController controller) {
    if (!controller.isBlurayNavigationSession) return true;
    if (controller.discMiningAvailable && !_discLearningBlocked) return true;
    final String message = switch (controller.discMiningUnavailableReason) {
      'multi-angle-source' => t.video_disc_angle_extraction_unavailable,
      'audio-track-unavailable' => t.video_disc_audio_selection_pending,
      'extraction-source-unavailable' => t.video_clip_export_input_missing,
      'encrypted-extraction-source' => t.video_disc_extraction_unavailable,
      _ => t.video_disc_title_binding_failed,
    };
    _showOsd(message, severity: ToastSeverity.warning);
    return false;
  }

  // Pending menus still own input so arrows cannot leak into seek/volume.
  // Dispatch below consumes them without sending commands until Top is ready.
  bool get _discOwnsInput =>
      _discLearningBlocked &&
      !_videoNavigablePanelOpen &&
      !_hasVisiblePopup &&
      ModalRoute.of(_videoControlsContext ?? context)?.isCurrent != false;

  void _reclaimDiscMenuFocusAfterAttachment(BuildContext hostContext) {
    if (!mounted ||
        !hostContext.mounted ||
        !_discOwnsInput ||
        ModalRoute.of(hostContext)?.isCurrent != true) {
      return;
    }
    // Runs after the replacement Focus host has attached and the old adaptive
    // controls have detached. Keep all page/popup focus policy centralized.
    _focusOwnership.reclaim(FocusReclaimCause.contentReady);
  }

  Future<void> _runDiscNavigation(String action) async {
    if (_controller?.discMenuEntryPending == true) return;
    try {
      await _controller?.discNavigation(action);
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.navigate', error, stack);
      if (mounted) {
        _showOsd(t.video_disc_navigation_failed, severity: ToastSeverity.error);
      }
    }
  }

  bool _handleDiscMenuKey(KeyEvent event) {
    if (!_discOwnsInput ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    final String? action = blurayMenuKeyAction(event.logicalKey);
    if (action == null) return false;
    if (_controller?.discMenuEntryPending == true) {
      if (action == 'prev' && event is KeyDownEvent) {
        unawaited(_handleBackOrExit());
      }
      return true;
    }
    if (event is KeyDownEvent ||
        event is KeyRepeatEvent && action != 'select') {
      unawaited(_runDiscNavigation(action));
    }
    return true;
  }

  bool _handleDiscMenuGamepad(GamepadButton button) {
    if (!_discOwnsInput) return false;
    final String? action = blurayMenuGamepadAction(button);
    if (action == null) return false;
    if (_controller?.discMenuEntryPending == true) {
      if (action == 'prev') unawaited(_handleBackOrExit());
      return true;
    }
    unawaited(_runDiscNavigation(action));
    return true;
  }

  void _syncDiscTrackSelection(VideoPlayerController controller) {
    final BlurayDiscTrackSelection selection = resolveBlurayDiscTrackSelection(
      discOwnsTracks: controller.discOwnsTracks,
      nativeAudioId: controller.activeAudioTrackId,
      nativeSubtitleId: controller.resolvedDiscSubtitleTrackId,
      nativeSubtitleStreamIndex: controller.activeSubtitleStreamIndex,
      currentSubtitleSource: _currentSubtitleSource,
      currentSecondarySubtitleSource: _currentSecondarySubtitleSource,
    );
    final List<SubtitleTrack> tracks = controller.subtitleTracks;
    final bool tracksChanged = !identical(_discLastSubtitleTracks, tracks);
    if (_currentAudioTrackId == selection.audioId &&
        _currentSubtitleSource == selection.subtitleSource &&
        _currentSecondarySubtitleSource == selection.secondarySubtitleSource &&
        !tracksChanged &&
        (!controller.discOwnsTracks ||
            (_delayMs == 0 && _secondaryDelayMs == null))) {
      return;
    }
    _rebuild(() {
      if (controller.discOwnsTracks) {
        _delayMs = 0;
        _secondaryDelayMs = null;
      }
      _currentAudioTrackId = selection.audioId;
      _currentSubtitleSource = selection.subtitleSource;
      _currentSecondarySubtitleSource = selection.secondarySubtitleSource;
      if (tracksChanged) {
        _discLastSubtitleTracks = tracks;
        _discSubtitleTracksRevision++;
        _subtitleMenuSourcesPath = null;
        _subtitleMenuLoading = false;
      }
    });
    if (tracksChanged &&
        !_discLearningBlocked &&
        _videoSidePanel.value?.kind == _VideoSidePanelKind.settings) {
      unawaited(_ensureSubtitleMenuSourcesLoaded());
    }
  }

  void _onDiscNavigationChanged() {
    final VideoPlayerController? controller = _controller;
    if (!mounted ||
        controller == null ||
        !controller.isBlurayNavigationSession) {
      return;
    }
    _syncDiscTrackSelection(controller);
    final String? error = controller.discMenuError;
    if (error != null && !_failed) {
      unawaited(controller.pause());
      _rebuild(() {
        _failed = true;
        _failReason = error.contains('java-runtime-unavailable')
            ? t.video_disc_runtime_required
            : error == 'navigation-open-failed'
            ? t.video_disc_menu_open_failed
            : t.video_disc_navigation_failed;
      });
    }
    final bool blocked =
        controller.discMenuActive || !controller.discTitleReady;
    if (blocked && !_discMenuWasActive) {
      // These panels are replaced by the authored menu surface. Clear their
      // ownership too, otherwise invisible panels keep swallowing menu arrows.
      if (_videoSidePanel.value != null) _hideVideoSidePanel();
      if (_subtitleListVisible.value) _closeSubtitleJumpList();
      if (_episodeListVisible.value) _closeEpisodeList();
      _hideVideoControlEditOverlay(revealControls: false);
      _watchTracker?.dispose();
      _watchTracker = null;
      _watchTrackerCoverageKey = null;
      _miningDraft.clear();
      _lastLookupCue = null;
      _lastLookupSentence = '';
      _subtitleLookupHighlight = null;
      _clearClipExportState();
      _pausedForLookup = false;
      if (_hasVisiblePopup) _popNestedPopupAt(0);
    }
    _discMenuWasActive = blocked;
    final String? selected = controller.selectedDiscPlaylistPath;
    if (selected != _discBindingPath ||
        _discNativeGeneration != controller.discTitleGeneration) {
      _discNativeGeneration = controller.discTitleGeneration;
      _episodeLoadSeq++;
      _discBindingPath = selected;
      final int generation = ++_discBindingGeneration;
      if (selected != null) {
        unawaited(
          _bindDiscPlaylist(
            controller,
            selected,
            generation,
            controller.discTitleGeneration,
          ),
        );
      }
    } else if (!blocked) {
      _ensureWatchTracker(controller, _title ?? '');
    }
  }

  Future<void> _bindDiscPlaylist(
    VideoPlayerController controller,
    String path,
    int generation,
    int nativeGeneration,
  ) async {
    bool current() =>
        mounted &&
        identical(_controller, controller) &&
        generation == _discBindingGeneration &&
        controller.selectedDiscPlaylistPath == path &&
        controller.discTitleGeneration == nativeGeneration;
    try {
      final VideoBookRow? row = await appModel.database.transaction(() async {
        VideoBookRow? existing = await widget.repo.findByVideoPath(path);
        if (!current() || existing != null) return existing;
        // Menu-only bonus titles can be absent from the importer's filtered list.
        // Lookup, collision allocation and insertion share one DB transaction.
        final List<VideoBookRow> books = await widget.repo.listAll();
        if (!current()) return null;
        final String uid = coreUniqueVideoBookUid(
          coreSingleVideoBookUid(path),
          books.map((VideoBookRow book) => book.bookUid).toSet(),
        );
        final String root = blurayDiscRootForPlaylistPath(path)!;
        await widget.repo.saveVideoBook(
          VideoBooksCompanion(
            bookUid: Value(uid),
            title: Value(
              '${p.basename(root)} · ${p.basenameWithoutExtension(path)}',
            ),
            videoPath: Value(path),
            importedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
        return widget.repo.getByBookUid(uid);
      });
      if (!current() || row == null) return;
      final VideoBookRow selected = row;
      // Identity changes atomically before enabling title playback consumers.
      _rebuild(() {
        _discBookUid = selected.bookUid;
        _bookRow = selected;
        final int episode = _episodes.indexWhere(
          (_PlaylistEpisodeRef entry) => entry.bookUid == selected.bookUid,
        );
        _currentEpisode = episode < 0 ? 0 : episode;
        _title = selected.title;
        _currentVideoPath = path;
        // Stored choices remain library candidates; the disc VM owns startup.
        _currentSubtitleSource = null;
        _currentSecondarySubtitleSource = null;
        _currentAudioTrackId = null;
        _delayMs = 0;
        _secondaryDelayMs = null;
        _subtitleMenuSources = const <SubtitleSource>[];
        _importedSubtitleSources = const <SubtitleSource>[];
        _favoritedVideoSentences.clear();
        _danmakuVisibleItems = const <VideoDanmakuItem>[];
        _subtitleMenuSourcesPath = null;
        _subtitleMenuLoading = false;
      });
      _titleNotifier.value = selected.title;
      await controller.bindDiscTitle(
        playlistPath: path,
        bookUid: selected.bookUid,
        expectedGeneration: nativeGeneration,
      );
      if (!current()) return;
      if (controller.discMiningAvailable) _setupThumbnailPreview(path);
      _ensureWatchTracker(controller, selected.title);
      _syncDiscTrackSelection(controller);
      unawaited(_refreshFavoritedCueCache());
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.bindTitle', error, stack);
      if (current()) {
        _showOsd(
          t.video_disc_title_binding_failed,
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Widget _buildDiscMenuSurface(VideoPlayerController controller) {
    if (controller.discMenuEntryPending) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        Future<void> pointer(Offset position, {bool select = false}) async {
          if (controller.discMenuEntryPending) return;
          final Offset? point = blurayMenuPointerPosition(
            position: position,
            viewport: constraints.biggest,
            video: Size(
              (controller.videoWidth ?? 0).toDouble(),
              (controller.videoHeight ?? 0).toDouble(),
            ),
            fit: videoFitModeToBoxFit(_videoFitMode),
          );
          if (point == null) return;
          try {
            await controller.setDiscPointerPosition(
              point.dx,
              point.dy,
              select: select,
            );
          } catch (error, stack) {
            ErrorLogService.instance.log('VideoDiscMenu.pointer', error, stack);
            if (select && mounted) {
              _showOsd(
                t.video_disc_navigation_failed,
                severity: ToastSeverity.error,
              );
            }
          }
        }

        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          onHover: (PointerHoverEvent event) =>
              unawaited(pointer(event.localPosition)),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) {
              unawaited(pointer(details.localPosition, select: true));
              _focusOwnership.reclaim(FocusReclaimCause.gesture);
            },
            // Claim press gestures so authored buttons never become speed/seek.
            onLongPress: () {},
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  Widget _buildDiscMenuBar(VideoPlayerController controller) => Positioned(
    top: 8,
    left: 8,
    right: 8,
    child: SafeArea(
      child: BlurayDiscMenuBar(
        navigationEnabled: !controller.discMenuEntryPending,
        backLabel: t.back,
        topMenuLabel: t.video_disc_top_menu,
        popupMenuLabel: t.video_disc_popup_menu,
        onBack: () => unawaited(_handleBackOrExit()),
        onTopMenu: () => unawaited(_runDiscNavigation('menu')),
        onPopupMenu: () => unawaited(_runDiscNavigation('popup')),
      ),
    ),
  );
}

class _BlurayJavaRuntimeInstallDialog extends StatefulWidget {
  const _BlurayJavaRuntimeInstallDialog({required this.manager});
  final BlurayJavaRuntimeManager manager;
  @override
  State<_BlurayJavaRuntimeInstallDialog> createState() =>
      _BlurayJavaRuntimeInstallDialogState();
}

class _BlurayJavaRuntimeInstallDialogState
    extends State<_BlurayJavaRuntimeInstallDialog> {
  bool _installing = false;
  bool _failed = false;
  double? _progress;

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _failed = false;
    });
    try {
      await widget.manager.install(
        onProgress: (int received, int? total) {
          if (mounted) {
            setState(
              () => _progress = total == null || total <= 0
                  ? null
                  : (received / total).clamp(0.0, 1.0),
            );
          }
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'VideoDiscMenu.installRuntime',
        error,
        stack,
      );
      if (mounted) {
        setState(() {
          _failed = true;
          _installing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.manager.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_installing,
    child: FushiAlertDialog(
      title: Text(t.video_disc_runtime_install),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.video_disc_runtime_description),
          if (_installing) ...<Widget>[
            const SizedBox(height: 16),
            FushiLinearProgressIndicator(value: _progress),
          ],
          if (_failed) ...<Widget>[
            const SizedBox(height: 16),
            Text(t.video_disc_runtime_install_failed),
          ],
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () {
            widget.manager.cancel();
            Navigator.of(context).pop(false);
          },
          child: Text(t.cancel),
        ),
        FushiFilledButton(
          onPressed: _installing ? null : _install,
          child: Text(t.video_disc_runtime_install),
        ),
      ],
    ),
  );
}
