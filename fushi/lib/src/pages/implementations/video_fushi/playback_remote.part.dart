part of '../video_fushi_page.dart';

/// 本页对桌面控制通道（`fushi_cli play ...`）的遥控实现，登记进
/// [videoPlaybackRemotes]（initState 登记、dispose 注销，见 [_VideoFushiPageState]）。
///
/// 每个动作只转调页内已有执行体，与悬浮球 / 底栏同名按钮同一条路径
/// （[_buildVideoFloatingBallScene]：播放暂停、上 / 下一句；细进度条的
/// `controller.seekMs`；倍速菜单的 [_VideoFushiPageState._setSpeed]），且同样不唤起
/// 控制条——遥控时用户的手不在控制条上。控制器尚未就绪时 [snapshot] 为 null、
/// 动作为 no-op（路由层先看快照再下发）。
class _VideoPagePlaybackRemote
    implements
        VideoPlaybackRemote,
        VideoPlayerRemoteControl,
        VideoDiscRemoteControl,
        VideoQuickSettingsHostProvider {
  _VideoPagePlaybackRemote(this._state);

  /// 与快捷设置面板同一个宿主（[_VideoFushiPageState._buildVideoQuickSettingsHost]）。
  @override
  Object? quickSettingsHost() =>
      _state.mounted ? _state._buildVideoQuickSettingsHost() : null;

  final _VideoFushiPageState _state;

  VideoPlayerController? get _controller =>
      _state.mounted ? _state._controller : null;

  @override
  VideoPlaybackSnapshot? snapshot() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    return VideoPlaybackSnapshot(
      title: _state._title,
      bookUid: _state.widget.bookUid,
      positionMs: controller.positionMs,
      durationMs: controller.durationMs,
      playing: controller.isPlaying,
      speed: controller.speed,
      cue: controller.currentCue?.text,
      volume: _state._volumeDisplay.value,
      audioTrackId: _state._currentAudioTrackId,
      subtitleSource: _state._currentSubtitleSource,
      secondarySubtitleSource: _state._currentSecondarySubtitleSource,
    );
  }

  // play() 的 Future 可能挂到下一次暂停才 settle（与有声书 BUG-1736 同理），页内
  // 所有入口都 unawaited，这里同样不等，免得遥控请求被挂住。
  @override
  Future<void> play() async {
    final VideoPlayerController? controller = _controller;
    if (controller != null) unawaited(controller.play());
  }

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> toggle() async {
    final VideoPlayerController? controller = _controller;
    if (controller != null) unawaited(controller.playOrPause());
  }

  @override
  Future<void> seekToMs(int positionMs) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    // 绝对 seek 是一次跳转（进「跳转回退」历史，跨度不够自动不算）；seekByMs 是步进。
    _state._recordVideoJumpDeparture(positionMs);
    await controller.seekMs(positionMs);
  }

  @override
  Future<void> seekByMs(int deltaMs) async =>
      _controller?.seekRelative(deltaMs);

  @override
  Future<void> setRate(double rate) async {
    if (_controller == null) return;
    await _state._setSpeed(rate);
  }

  @override
  Future<void> previousCue() async => _controller?.skipToPrevCueOrSeekBack(
    seekSeconds: _state._asbConfig.seekSeconds,
  );

  @override
  Future<void> nextCue() async => _controller?.skipToNextCueOrSeekForward(
    seekSeconds: _state._asbConfig.seekSeconds,
  );

  // ── 扩展遥控面（`fushi_cli video ...`，见 [VideoPlayerRemoteControl]） ──────

  VideoPlayerController _requireController() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) {
      throw const VideoRemoteFailure('no_video', '视频还在加载，稍后再试');
    }
    return controller;
  }

  void _requireLocalVideo(String what) {
    if (_state._isRemote || _state._currentVideoPath == null) {
      throw VideoRemoteFailure('unsupported', '$what只支持本机视频文件');
    }
  }

  /// 在 [action] 执行期间收集页面弹出的 OSD 提示（页内各入口的失败只经 OSD 告知用户，
  /// CLI 拿同一句话当失败原因）。
  Future<T> _collectingOsd<T>(
    List<_VideoOsdMessage> sink,
    Future<T> Function() action,
  ) async {
    void listener() {
      final _VideoOsdMessage? message = _state._osdNotifier.value;
      if (message != null) sink.add(message);
    }

    _state._osdNotifier.addListener(listener);
    try {
      return await action();
    } finally {
      // 页面在动作期间被卸载时通知器已释放，不能再碰。
      if (_state.mounted) _state._osdNotifier.removeListener(listener);
    }
  }

  /// OSD 里最能说明失败的那句：优先错误 / 警告，其次最后一条。
  static String _failureText(List<_VideoOsdMessage> osd, String fallback) {
    for (final _VideoOsdMessage message in osd.reversed) {
      if (message.severity == ToastSeverity.error ||
          message.severity == ToastSeverity.warning) {
        return message.message;
      }
    }
    return osd.isEmpty ? fallback : osd.last.message;
  }

  @override
  String get activeBookUid => _state._activeBookUid;

  @override
  Future<double> setVolume(double volume) async {
    _requireController();
    // 音量滑条同一入口（写播放器 + 显示真相源 + 防抖持久化 + OSD）。
    await _state._applyUserVideoVolume(volume);
    return _state._volumeDisplay.value;
  }

  @override
  Future<double> toggleMute() async {
    _requireController();
    await _state._toggleMute();
    return _state._volumeDisplay.value;
  }

  @override
  List<VideoRemoteAudioTrack> audioTracks() {
    final VideoPlayerController controller = _requireController();
    return <VideoRemoteAudioTrack>[
      for (final AudioTrack track in controller.audioTracks)
        VideoRemoteAudioTrack(
          id: track.id,
          label: _state._trackLabel(track.title, track.language, track.id),
          selected: _state._currentAudioTrackId == track.id,
          language: track.language,
          title: track.title,
        ),
    ];
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    final VideoPlayerController controller = _requireController();
    final AudioTrack? track = controller.audioTracks.firstWhereOrNull(
      (AudioTrack t) => t.id == id,
    );
    if (track == null) {
      throw VideoRemoteFailure('not_found', '没有音轨 $id（video tracks 查看）');
    }
    if (_state._discLearningBlocked) {
      throw const VideoRemoteFailure('unsupported', '光盘菜单阶段不能切音轨');
    }
    // 设置面板「音频」分类同一入口（切轨 + 系列 / 本集持久化 + OSD）。
    await _state._selectAudioTrack(controller, track);
  }

  @override
  Future<VideoRemoteSubtitleState> subtitleState() async {
    final VideoPlayerController controller = _requireController();
    final bool remote = _state._isRemote;
    if (!remote) {
      // 打开设置面板「字幕」分类时的同一条枚举（按视频路径缓存，只跑一次）。
      await _state._ensureSubtitleMenuSourcesLoaded();
    }
    final String? primary = _state._currentSubtitleSource;
    final String? secondary = _state._currentSecondarySubtitleSource;
    return VideoRemoteSubtitleState(
      tracks: remote
          ? <VideoRemoteSubtitleTrack>[
              for (final _RemoteSubtitleRow row in _remoteRows(controller))
                row.track,
            ]
          : <VideoRemoteSubtitleTrack>[
              for (final SubtitleSource source in _state._menuSubtitleSources)
                VideoRemoteSubtitleTrack(
                  source: source.toPersistedValue(),
                  label: source.label,
                  kind: source.isGraphicEmbedded
                      ? VideoRemoteSubtitleKind.graphic
                      : source.isEmbedded
                      ? VideoRemoteSubtitleKind.embedded
                      : VideoRemoteSubtitleKind.external,
                  primary: subtitleSourceMatchesPersistedForMenu(
                    source,
                    primary,
                  ),
                  secondary: source.matchesPersisted(secondary),
                  ocrAvailable:
                      _state._graphicTrackOcrInput(controller, source) != null,
                  // 副字幕走文本 cue 流，图形轨抽不出文字（面板里点了也是报失败）。
                  secondarySelectable: !source.isGraphicEmbedded,
                  language: source.language,
                  codec: source.codec,
                ),
            ],
      primarySource: primary,
      secondarySource: secondary,
      remote: remote,
      asrAvailable: _state._canResolveSubtitleTimingAudio && isAsrSupported,
      alignAvailable: _state._currentVideoPath != null,
      clipAvailable: !remote && _state._currentVideoPath != null,
    );
  }

  /// 远端视频的字幕轨行：与字幕面板远端分支（[_VideoSubtitle._buildSubtitleTrackRows]
  /// 与副字幕区）逐类对应——YouTube 字幕轨、host 外挂、host / 流内封轨、本机导入的
  /// 档案（与 host 外挂按路径去重）。每行带上点它时面板会调的处理。
  List<_RemoteSubtitleRow> _remoteRows(VideoPlayerController controller) {
    final String? primary = _state._currentSubtitleSource;
    final String? secondary = _state._currentSecondarySubtitleSource;
    final String? hostSub = _state._remoteSubtitlePath;
    final List<_RemoteSubtitleRow> rows = <_RemoteSubtitleRow>[];
    for (final YoutubeCaptionTrack track in _state._youtubeCaptionTracks) {
      rows.add(
        _RemoteSubtitleRow(
          track: VideoRemoteSubtitleTrack(
            source: track.trackKey,
            label: _state._youtubeCaptionTrackLabel(track),
            kind: VideoRemoteSubtitleKind.youtube,
            primary: primary == track.trackKey,
            secondary: false,
            ocrAvailable: false,
            // 面板的副字幕区没有 YouTube 轨。
            secondarySelectable: false,
            language: track.languageCode,
          ),
          applyPrimary: () =>
              _state._applyYoutubeCaptionTrack(controller, track),
        ),
      );
    }
    if (hostSub != null) {
      rows.add(
        _RemoteSubtitleRow(
          track: VideoRemoteSubtitleTrack(
            source: hostSub,
            label: p.basename(hostSub),
            kind: VideoRemoteSubtitleKind.host,
            primary: primary == hostSub,
            secondary: secondary == hostSub,
            ocrAvailable: false,
          ),
          applyPrimary: () => _state._applyRemoteSubtitle(controller, hostSub),
          applySecondary: () =>
              _state._applyRemoteSecondarySubtitle(controller, hostSub),
        ),
      );
    }
    for (final RemoteVideoEmbeddedSubtitleTrack track
        in _state._remoteEmbeddedSubtitleTracks) {
      final String source = _state._remoteEmbeddedSubtitleSource(track);
      final bool selectable = _state._remoteEmbeddedTrackSelectable(track);
      rows.add(
        _RemoteSubtitleRow(
          track: VideoRemoteSubtitleTrack(
            source: source,
            label: _state._remoteEmbeddedSubtitleLabel(track),
            kind: track.isText
                ? (track.isExternalFile
                      ? VideoRemoteSubtitleKind.external
                      : VideoRemoteSubtitleKind.embedded)
                : VideoRemoteSubtitleKind.graphic,
            primary: primary == source,
            secondary: secondary == source,
            ocrAvailable:
                _state._remoteGraphicTrackOcrInput(controller, track) != null,
            selectable: selectable,
            secondarySelectable: track.isText,
            language: track.language,
            codec: track.codec,
          ),
          applyPrimary: selectable
              ? () => _state._applyRemoteEmbeddedSubtitle(controller, track)
              : null,
          applySecondary: track.isText
              ? () => _state._applyRemoteEmbeddedSecondarySubtitle(
                  controller,
                  track,
                )
              : null,
          remoteTrack: track,
        ),
      );
    }
    for (final SubtitleSource source in _state._importedSubtitleSources) {
      if (hostSub != null && sameExternalSubtitlePathForMenu(source, hostSub)) {
        continue;
      }
      final String path = source.externalPath!;
      rows.add(
        _RemoteSubtitleRow(
          track: VideoRemoteSubtitleTrack(
            source: path,
            label: source.label,
            kind: VideoRemoteSubtitleKind.external,
            primary: subtitleSourceMatchesPersistedForMenu(source, primary),
            secondary: subtitleSourceMatchesPersistedForMenu(source, secondary),
            ocrAvailable: false,
          ),
          applyPrimary: () => _state._applyRemoteSubtitle(
            controller,
            path,
            label: source.label,
          ),
          applySecondary: () => _state._applyRemoteSecondarySubtitle(
            controller,
            path,
            label: source.label,
          ),
        ),
      );
    }
    return rows;
  }

  _RemoteSubtitleRow _remoteRow(
    VideoPlayerController controller,
    String source,
  ) =>
      _remoteRows(
        controller,
      ).firstWhereOrNull((_RemoteSubtitleRow r) => r.track.source == source) ??
      (throw VideoRemoteFailure('not_found', '没有字幕轨 $source（video subs 查看）'));

  /// 本地视频的可选字幕源里找 [source]（持久化值）。
  Future<SubtitleSource> _menuSource(String source) async {
    await _state._ensureSubtitleMenuSourcesLoaded();
    final SubtitleSource? found = _state._menuSubtitleSources.firstWhereOrNull(
      (SubtitleSource s) => s.toPersistedValue() == source,
    );
    if (found == null) {
      throw VideoRemoteFailure('not_found', '没有字幕轨 $source（video subs 查看）');
    }
    return found;
  }

  @override
  Future<void> selectSubtitle(String source, {required bool secondary}) async {
    final VideoPlayerController controller = _requireController();
    if (_state._subtitleLoadingShown) {
      throw const VideoRemoteFailure('busy', '字幕正在加载，稍后再试');
    }
    if (_state._isRemote) {
      await _selectRemoteSubtitle(controller, source, secondary: secondary);
      return;
    }
    final SubtitleSource found = await _menuSource(source);
    final List<_VideoOsdMessage> osd = <_VideoOsdMessage>[];
    // 字幕面板的主字幕行 / 副字幕可展开区同一入口（抽 cue → 切 overlay → 持久化）。
    final bool applied = await _collectingOsd(
      osd,
      () => secondary
          ? _state._selectSecondarySubtitleSource(controller, found)
          : _state._selectSubtitleSource(controller, found),
    );
    if (!applied) {
      throw VideoRemoteFailure(
        'failed',
        _failureText(osd, '字幕「${found.label}」没有应用（页面已切换或该轨不可用）'),
      );
    }
  }

  /// 远端：按轨类型分派到面板同一行的处理，结论按当前源有没有换成它判定（几类处理
  /// 的失败都只经 OSD 告知）。
  Future<void> _selectRemoteSubtitle(
    VideoPlayerController controller,
    String source, {
    required bool secondary,
  }) async {
    final _RemoteSubtitleRow row = _remoteRow(controller, source);
    final Future<void> Function()? apply = secondary
        ? row.applySecondary
        : row.applyPrimary;
    if (apply == null) {
      throw VideoRemoteFailure(
        'unsupported',
        secondary
            ? '「${row.track.label}」不能作副字幕（面板里同样不可选）'
            : '「${row.track.label}」当前不可选（转码流不带图形轨，面板里同样灰掉）',
      );
    }
    final List<_VideoOsdMessage> osd = <_VideoOsdMessage>[];
    await _collectingOsd(osd, apply);
    final String? now = secondary
        ? _state._currentSecondarySubtitleSource
        : _state._currentSubtitleSource;
    if (now != source) {
      throw VideoRemoteFailure(
        'failed',
        _failureText(osd, '字幕「${row.track.label}」没有应用'),
      );
    }
  }

  @override
  Future<void> subtitleOff({required bool secondary}) async {
    final VideoPlayerController controller = _requireController();
    if (_state._discLearningBlocked) {
      throw const VideoRemoteFailure('unsupported', '光盘菜单阶段不能切字幕');
    }
    if (secondary) {
      await (_state._isRemote
          ? _state._clearRemoteSecondarySubtitle(controller)
          : _state._selectSecondarySubtitleOff(controller));
    } else {
      // 字幕面板「关闭」行同一入口（远端只清内存，本地持久化关闭哨兵）。
      await (_state._isRemote
          ? _state._clearRemoteSubtitle(controller)
          : _state._selectSubtitleOff(controller));
    }
  }

  @override
  Future<String> importSubtitle(String path, {bool secondary = false}) async {
    final VideoPlayerController controller = _requireController();
    if (!await File(path).exists()) {
      throw VideoRemoteFailure('not_found', '字幕文件不存在：$path');
    }
    if (subtitleFormatForPath(path) == null) {
      throw VideoRemoteFailure('unsupported', '不支持的字幕格式：${p.extension(path)}');
    }
    final bool remote = _state._isRemote;
    if (!remote && _state._currentVideoPath == null) {
      throw const VideoRemoteFailure('unsupported', '当前视频没有可挂字幕的本机文件');
    }
    if (secondary && !remote) {
      // 本地视频的副字幕区没有「导入」行：导入的档案进同一份可选列表，再选为副字幕。
      throw const VideoRemoteFailure(
        'unsupported',
        '本机视频的副字幕请先 video sub-import 导入，再用 video sub2 选它（面板也是这样）',
      );
    }
    final List<_VideoOsdMessage> osd = <_VideoOsdMessage>[];
    // 「导入字幕文件」同一条链路：本地拷进字幕目录 → 选中 → 并入列表；远端拷进字幕
    // 目录 → 内存应用并按集持久化 → 同步到 host（主字幕）。
    await _collectingOsd(osd, () async {
      if (!remote) {
        await _state._importExternalSubtitle(controller, path);
      } else if (secondary) {
        await _state._importRemoteSecondarySubtitleFile(controller, path);
      } else {
        await _state._importRemoteSubtitleFile(controller, path);
      }
    });
    final String? current = secondary
        ? _state._currentSecondarySubtitleSource
        : _state._currentSubtitleSource;
    if (current == null ||
        SubtitleSource.isOff(current) ||
        SubtitleSource.isEmbeddedPersisted(current) ||
        p.basename(current) != p.basename(path)) {
      throw VideoRemoteFailure('failed', _failureText(osd, '字幕没有导入'));
    }
    return current;
  }

  /// 起一个长任务：同类任务不并发；[body] 返回结果即成功，抛 [VideoRemoteFailure]
  /// 即失败；期间页面弹出的 OSD 记进任务消息。
  VideoRemoteJob _startJob(
    VideoRemoteJobKind kind,
    Future<Map<String, Object?>> Function(
      VideoRemoteJob job,
      List<_VideoOsdMessage> osd,
    )
    body,
  ) {
    final VideoRemoteJob? running = videoRemoteJobs.running(kind);
    if (running != null) {
      throw VideoRemoteFailure('busy', '已有同类任务 ${running.id} 在进行');
    }
    final VideoRemoteJob job = videoRemoteJobs.register(
      VideoRemoteJob(kind: kind, bookUid: _state._activeBookUid),
    );
    final List<_VideoOsdMessage> osd = <_VideoOsdMessage>[];
    unawaited(() async {
      try {
        final Map<String, Object?> result = await _collectingOsd(osd, () async {
          final Map<String, Object?> value = await body(job, osd);
          return value;
        });
        for (final _VideoOsdMessage m in osd) {
          job.addMessage(m.message);
        }
        job.succeed(result);
      } on VideoRemoteFailure catch (e) {
        for (final _VideoOsdMessage m in osd) {
          job.addMessage(m.message);
        }
        job.fail(e.code, e.message);
      } catch (error, stack) {
        ErrorLogService.instance.log(
          'video.remoteJob.${kind.name}',
          error,
          stack,
        );
        job.fail('failed', '$error');
      }
    }());
    return job;
  }

  /// 任务跑完后主字幕是否换成了新产物；没换就按 OSD / 取消状态报失败。
  Map<String, Object?> _subtitleOutcome(
    VideoRemoteJob job,
    List<_VideoOsdMessage> osd, {
    required String? before,
    required String fallback,
  }) {
    if (!_state.mounted) {
      throw const VideoRemoteFailure('no_video', '视频页已关闭');
    }
    final String? after = _state._currentSubtitleSource;
    if (job.cancelRequested) {
      throw const VideoRemoteFailure('cancelled', '已取消');
    }
    if (after != null && after != before && !SubtitleSource.isOff(after)) {
      return <String, Object?>{'subtitle': after, 'label': p.basename(after)};
    }
    throw VideoRemoteFailure('failed', _failureText(osd, fallback));
  }

  @override
  Future<VideoRemoteJob> startSubtitleOcr(
    String source, {
    bool? consentLlm,
    bool consentUpload = false,
  }) async {
    final VideoPlayerController controller = _requireController();
    // 本地：枚举出的图形轨；远端：可整轨取数的远端图形轨（host 整轨 / 流地址抽取）。
    final Future<void> Function(_GraphicOcrConsentGates consent) run;
    final String label;
    if (_state._isRemote) {
      final _RemoteSubtitleRow row = _remoteRow(controller, source);
      final RemoteVideoEmbeddedSubtitleTrack? track = row.remoteTrack;
      label = row.track.label;
      if (track == null || track.isText) {
        throw VideoRemoteFailure('unsupported', '「$label」不是图形字幕轨，不需要 OCR');
      }
      if (_state._remoteGraphicTrackOcrInput(controller, track) == null) {
        throw VideoRemoteFailure(
          'unsupported',
          '「$label」取不到整轨数据或编码不支持（面板里同样没有「整轨转文字」）',
        );
      }
      run = (_GraphicOcrConsentGates consent) =>
          _state._generateSubtitleFromRemoteGraphicTrack(
            controller,
            track,
            startConfirmed: true,
            consent: consent,
          );
    } else {
      final SubtitleSource found = await _menuSource(source);
      label = found.label;
      if (!found.isGraphicEmbedded) {
        throw VideoRemoteFailure('unsupported', '「$label」不是图形字幕轨，不需要 OCR');
      }
      if (_state._graphicTrackOcrInput(controller, found) == null) {
        throw VideoRemoteFailure(
          'unsupported',
          '「$label」的编码不支持整轨 OCR（${found.codec ?? '未知编码'}）',
        );
      }
      run = (_GraphicOcrConsentGates consent) =>
          _state._generateSubtitleFromGraphicTrack(
            controller,
            found,
            startConfirmed: true,
            consent: consent,
          );
    }
    if (_state._graphicSubtitleOcrRunning) {
      throw const VideoRemoteFailure('busy', '已有整轨 OCR 在进行');
    }
    // 「默认交给 LLM」能在开始前判定：需要回答却没给 --consent-llm 就当场报错。
    if (!await decideMangaAiOcrDefaultHeadless(
      _state.appModel,
      consent: consentLlm,
    )) {
      throw const VideoRemoteFailure(
        'consent_required',
        '低置信度结果是否默认交给 LLM 还没选过：加 --consent-llm（开启）或 '
            '--no-consent-llm（不用），与 app 内首次询问写同一个档位',
      );
    }
    return _startJob(VideoRemoteJobKind.subtitleOcr, (
      VideoRemoteJob job,
      List<_VideoOsdMessage> osd,
    ) async {
      final String? before = _state._currentSubtitleSource;
      bool uploadDeclined = false;
      // 两个一次性同意的无头答案：写入与 app 同意框相同的状态，不弹框。Lens 只在
      // 引擎真的解析到它时才问，所以只能在这里记下「没同意」再报。
      final _GraphicOcrConsentGates consent = _GraphicOcrConsentGates(
        decideAiDefault: () async {
          await decideMangaAiOcrDefaultHeadless(
            _state.appModel,
            consent: consentLlm,
          );
        },
        confirmLensUpload: () async {
          final bool ok = await acceptGoogleLensUploadHeadless(
            scene: GoogleLensDisclosureScene.videoFrames,
            consent: consentUpload,
          );
          if (!ok) uploadDeclined = true;
          return ok;
        },
      );
      job.onCancel = _state._cancelGraphicSubtitleOcr;
      void progress() {
        final GraphicSubtitleOcrJobState? state =
            _state._graphicSubtitleOcrJob.value;
        if (state == null) return;
        job.update(
          phase: state.phase.name,
          fraction: state.fraction,
          detail: state.total > 0 ? '${state.done}/${state.total}' : null,
        );
      }

      final ValueNotifier<GraphicSubtitleOcrJobState?> notifier =
          _state._graphicSubtitleOcrJob;
      notifier.addListener(progress);
      try {
        // 字幕面板图形轨下「整轨转文字」同一入口；CLI 已用 --yes 确认开始。
        await run(consent);
      } finally {
        if (_state.mounted) notifier.removeListener(progress);
      }
      if (uploadDeclined) {
        throw const VideoRemoteFailure(
          'consent_required',
          'OCR 引擎要把视频画面上传到 Google Lens，尚未同意：加 --consent-upload '
              '（与 app 内上传披露框的「同意」写同一份记录），或在 OCR 设置里换本机引擎',
        );
      }
      return _subtitleOutcome(
        job,
        osd,
        before: before,
        fallback: '「$label」整轨 OCR 没有产出字幕',
      );
    });
  }

  @override
  VideoRemoteJob startTranscribe({String? language, required bool retime}) {
    final VideoPlayerController controller = _requireController();
    if (!isAsrSupported || !_state._canResolveSubtitleTimingAudio) {
      throw const VideoRemoteFailure('unsupported', '本机不支持语音转录，或当前视频取不到音轨');
    }
    if (language != null && AsrLanguage.fromTag(language) == null) {
      throw VideoRemoteFailure('bad_request', '不支持的转录语言：$language');
    }
    if (retime && controller.cues.isEmpty) {
      throw const VideoRemoteFailure('failed', '重定时需要先选一条字幕轨');
    }
    final VideoRemoteJobKind kind = retime
        ? VideoRemoteJobKind.retime
        : VideoRemoteJobKind.transcribe;
    return _startJob(kind, (
      VideoRemoteJob job,
      List<_VideoOsdMessage> osd,
    ) async {
      final String? before = _state._currentSubtitleSource;
      final AudiobookTranscribeCancelToken cancel =
          AudiobookTranscribeCancelToken();
      job.onCancel = cancel.cancel;
      String? transcribeError;
      // 无界面转录：与有声书「下载后自动转录」同一个转录端口（同一服务工厂、缺模型
      // 自动下载、进度 / 取消），替换转录弹层这一步；抽音轨与落盘选中链路不变。
      Future<String?> transcribe(String audioPath) async {
        final AppAudiobookTranscriber transcriber = AppAudiobookTranscriber(
          serviceFactory: createAsrTranscriptionService,
          preferredLanguageTag: () =>
              language ?? _state.appModel.asrTranscribeLanguage,
        );
        final int now = DateTime.now().millisecondsSinceEpoch;
        try {
          return await transcriber.transcribe(
            AudiobookTranscribeJob(
              id: job.id,
              title: _state._title ?? p.basename(audioPath),
              audioPaths: <String>[audioPath],
              createdAt: now,
              updatedAt: now,
            ),
            onProgress: (AudiobookTranscribeJobPhase phase, double? value) =>
                job.update(phase: phase.name, fraction: value),
            cancel: cancel,
          );
        } on AudiobookTranscribeCancelled {
          return null;
        } catch (error) {
          transcribeError = '$error';
          rethrow;
        }
      }

      if (retime) {
        await _state._retimeSubtitleWithSpeechModel(
          controller,
          transcribe: transcribe,
        );
      } else {
        await _state._generateSubtitleWithSpeechModel(
          controller,
          transcribe: transcribe,
        );
      }
      final String? error = transcribeError;
      if (error != null) throw VideoRemoteFailure('failed', error);
      return _subtitleOutcome(
        job,
        osd,
        before: before,
        fallback: retime ? '重定时没有产出新字幕' : '转录没有产出字幕',
      );
    });
  }

  @override
  VideoRemoteJob startSubtitleAlign({required bool confirm}) {
    final VideoPlayerController controller = _requireController();
    _requireLocalVideo('对轴（按本机容器里的内封轨，远端 / 流视频面板里同样没有此入口）');
    if (_state._referenceSyncRunning) {
      throw const VideoRemoteFailure('busy', '已有对轴在进行');
    }
    // 同步入口只做零 IO 的选择预检；文件是否还在放进任务里 async 判（BUG-3756：
    // 字幕可能在网络盘上，同步 stat 会冻结 UI isolate）。
    if (_state._currentExternalSubtitleSelection() == null) {
      throw const VideoRemoteFailure(
        'failed',
        '对轴需要当前选中一份外挂字幕文件（内封轨 / 关闭时不能对）',
      );
    }
    return _startJob(VideoRemoteJobKind.align, (
      VideoRemoteJob job,
      List<_VideoOsdMessage> osd,
    ) async {
      final String? before = _state._currentSubtitleSource;
      String? declined;
      // 页内两处确认框的答案由 --yes 给出；没给就如实报「需要确认」，什么都不改。
      Future<bool> answer({
        required String title,
        required String body,
        required String action,
      }) async {
        if (confirm) return true;
        declined = '$title：$body';
        return false;
      }

      if (await _state._currentExternalSubtitlePath() == null) {
        throw const VideoRemoteFailure('failed', '当前选中的外挂字幕文件已不在磁盘上');
      }
      job.update(phase: 'aligning');
      await _state._alignSubtitleToEmbeddedTracks(controller, confirm: answer);
      final String? needs = declined;
      if (needs != null) {
        throw VideoRemoteFailure('needs_confirmation', '$needs（加 --yes 应用）');
      }
      return _subtitleOutcome(job, osd, before: before, fallback: '对轴没有改动字幕');
    });
  }

  @override
  VideoRemoteJob startClipExport({
    required int startMs,
    required int endMs,
    String? outputPath,
  }) {
    final VideoPlayerController controller = _requireController();
    _requireLocalVideo('片段导出（远端 / 流视频面板里同样要求先下载到本机）');
    if (!_state._discExtractionAllowed(controller)) {
      throw const VideoRemoteFailure('unsupported', '当前光盘阶段不能导出片段');
    }
    if (_state._clipExporting) {
      throw const VideoRemoteFailure('busy', '已有片段在导出');
    }
    final int durationMs = controller.durationMs ?? 0;
    if (startMs < 0 ||
        endMs <= startMs ||
        (durationMs > 0 && endMs > durationMs)) {
      throw VideoRemoteFailure(
        'bad_request',
        '区间无效：$startMs–$endMs ms（片长 $durationMs ms）',
      );
    }
    final String inputPath = _state._currentVideoPath!;
    final int? audioStreamIndex = controller.currentAudioStreamIndex;
    final int audioStreamCount = controller.realAudioStreamCount;
    return _startJob(VideoRemoteJobKind.clip, (
      VideoRemoteJob job,
      List<_VideoOsdMessage> osd,
    ) async {
      final String target = _state._ensureMp4Extension(
        outputPath ??
            p.join(
              (await getApplicationDocumentsDirectory()).path,
              'video_clips',
              _state._clipExportFileName(
                inputPath: inputPath,
                startMs: startMs,
                endMs: endMs,
              ),
            ),
      );
      await Directory(p.dirname(target)).create(recursive: true);
      if (!_state.mounted) {
        throw const VideoRemoteFailure('no_video', '视频页已关闭');
      }
      job.update(phase: 'exporting');
      _state._rebuild(() => _state._clipExporting = true);
      final VideoClipExportResult result;
      try {
        // 片段导出的同一个 ffmpeg 导出（含当前字幕烧录、用户设的码率）。
        result = await _state._exportClipFile(
          controller: controller,
          inputPath: inputPath,
          startMs: startMs,
          endMs: endMs,
          outputPath: target,
          audioStreamIndex: audioStreamIndex,
          audioStreamCount: audioStreamCount,
        );
      } finally {
        if (_state.mounted) {
          _state._rebuild(() => _state._clipExporting = false);
        }
      }
      final String? exported = result.outputPath;
      if (!result.isSuccess || exported == null) {
        await _state._deleteClipOutput(exported ?? target);
        final String? detail = result.detail?.trim();
        throw VideoRemoteFailure(
          'failed',
          detail == null || detail.isEmpty
              ? _state._clipExportFailureReason(result)
              : '${_state._clipExportFailureReason(result)} — '
                    '${detail.length > 200 ? detail.substring(detail.length - 200) : detail}',
        );
      }
      return <String, Object?>{
        'path': exported,
        'startMs': startMs,
        'endMs': endMs,
        'subtitleTracks': result.subtitleTrackCount,
      };
    });
  }

  @override
  Future<VideoRemoteMineResult> mineCurrentCue(
    Map<String, String> fields,
  ) async {
    final VideoPlayerController controller = _requireController();
    if (!_state._discExtractionAllowed(controller)) {
      throw const VideoRemoteFailure('unsupported', '当前光盘阶段不能制卡');
    }
    // 与在字幕上查词再点「+」同一条路：查词时记下锚点句与句子（见
    // [_VideoLookupFavorite] 的 _lookupAt），草稿从空起步，再走弹窗的落卡入口。
    final AudioCue? cue = resolveVideoLookupAnchorCue(
      currentCue: controller.currentCue,
      cues: controller.miningCues,
      positionMs: controller.miningPositionMs ?? 0,
      delayMs: controller.miningDelayMs,
    );
    _state._lastLookupCue = cue;
    _state._lastLookupSentence = cue?.text.trim() ?? '';
    _state._miningDraft.clear();
    final Map<String, String> payload = <String, String>{
      ...fields,
      if ((fields['sentence'] ?? '').isEmpty && cue != null)
        'sentence': cue.text.trim(),
    };
    final String sentence = _state._lastLookupSentence;
    final List<_VideoOsdMessage> osd = <_VideoOsdMessage>[];
    final MinePopupResult result = await _collectingOsd(
      osd,
      () => _state._onMineEntryImpl(payload),
    );
    if (!result.accepted && !result.duplicate) {
      throw VideoRemoteFailure('failed', _failureText(osd, '制卡没有成功'));
    }
    return VideoRemoteMineResult(
      success: result.accepted,
      queued: result.queued,
      duplicate: result.duplicate,
      noteId: result.noteId,
      sentence: sentence.isEmpty ? null : sentence,
    );
  }

  @override
  Future<void> refreshMineQueue() async {
    if (!_state.mounted) return;
    await _state._refreshStagedMineCount();
  }

  // ── 原盘会话（`fushi_cli disc …`，见 [VideoDiscRemoteControl]） ─────────────

  @override
  VideoDiscSessionSnapshot? discSession() {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.isBlurayNavigationSession) {
      return null;
    }
    return VideoDiscSessionSnapshot(
      bookUid: _state.widget.bookUid,
      title: _state._title,
      discType: controller.discType,
      remote: controller.isRemoteDiscSession,
      navigationSupported: controller.discNavigationSupported,
      menuStarting: controller.discMenuEntryPending,
      menuActive: controller.discMenuActive,
      titleReady: controller.discTitleReady,
      discTitle: controller.discNavigationState?.title,
      playlistPath: controller.selectedDiscPlaylistPath,
      error: controller.discMenuError,
    );
  }

  /// 与盘菜单键位 / 遥控器同一条路径（[_VideoFushiPageState._runDiscNavigation] 里的
  /// `controller.discMenuKey`），只是失败不弹 OSD、带回给调用方；同样不唤起控制栏。
  @override
  Future<void> discMenuKey(VideoDiscMenuKey key) async {
    final VideoPlayerController controller = _requireController();
    if (!controller.isBlurayNavigationSession) {
      throw const VideoRemoteFailure('unsupported', '当前播放页不是原盘会话');
    }
    if (controller.discMenuEntryPending) {
      throw const VideoRemoteFailure('busy', '原盘菜单还在启动，稍后再试');
    }
    try {
      await controller.discMenuKey(key);
    } on VideoDiscMenuException catch (e) {
      throw switch (e.code) {
        'navigation-initializing' => const VideoRemoteFailure(
          'busy',
          '原盘菜单还在启动，稍后再试',
        ),
        'navigation-not-active' => const VideoRemoteFailure(
          'unsupported',
          '这张盘当前不能导航菜单（播放组件不支持或菜单没打开）',
        ),
        _ => VideoRemoteFailure('failed', '原盘菜单操作失败：${e.code}'),
      };
    }
  }

  /// 「退出原盘」/ 按住 Esc 背后的同一个退出汇聚点。
  @override
  Future<void> exitDiscSession() async {
    final VideoPlayerController controller = _requireController();
    if (!controller.isBlurayNavigationSession) {
      throw const VideoRemoteFailure('unsupported', '当前播放页不是原盘会话');
    }
    await _state._exitDiscSession();
  }
}

/// 远端字幕轨的一行：给 CLI 的描述 + 面板同一行点下去会调的处理。
class _RemoteSubtitleRow {
  const _RemoteSubtitleRow({
    required this.track,
    this.applyPrimary,
    this.applySecondary,
    this.remoteTrack,
  });

  final VideoRemoteSubtitleTrack track;

  /// 选为主 / 副字幕；null = 面板里这一行不可选。
  final Future<void> Function()? applyPrimary;
  final Future<void> Function()? applySecondary;

  /// host / 流内封轨（整轨 OCR 要用）；其它类为 null。
  final RemoteVideoEmbeddedSubtitleTrack? remoteTrack;
}
