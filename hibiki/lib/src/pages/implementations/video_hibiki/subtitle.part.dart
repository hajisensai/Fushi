// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch5).
part of '../video_hibiki_page.dart';

/// subtitle (字幕源菜单/选择/导入/远端字幕/overlay loading/字幕跳转列表侧栏) domain
/// methods extracted via part-of (TODO-590 batch5); shared private scope.
/// Behaviour-preserving: bodies are verbatim copies except `setState(` is forwarded
/// through the main shell's `_rebuild(` helper (extensions cannot call the
/// @protected `State.setState`), identical to batch1/batch2. No
/// `_VideoHibikiPageState` `static` member is referenced by bare name in this
/// domain (the only host-class static consts live in non-subtitle methods), so no
/// full-qualification rewrite is needed (unlike batch3). All subtitle-related
/// fields (`_subtitleMenuSources` / `_subtitleMenuLoading` / `_subtitleLoadingShown`
/// / `_subtitleImportsInFlight` / `_subtitleListVisible` / `_currentSubtitleSource`
/// / `_subtitleStyle` / `_remoteSubtitlePath` / `_remoteEmbeddedSubtitleTracks`),
/// the load-path subtitle restore helpers (`_restorePersistedSubtitle` /
/// `_subtitleSourcesForMenu` / `_firstMatching` / `_detectSidecar` /
/// `_loadExternalSubtitleCues`), the episode-path helpers
/// (`_handleEmbeddedSubtitleAutoLoad` / `_prewarmNextEpisodeSubtitleCache` /
/// `_remoteSubtitleTempFileName`), the audio-domain `_trackLabel`, the drag-target
/// dispatcher `_handlePlaybackDrop`, the lookup-domain `_handleSubtitleLookupTap`,
/// the subtitle-style helpers (`_persistSubtitleStyle` / `_toggleSubtitleBlur`),
/// and the parent build subtrees (`_buildVideoSidePanelChild` /
/// `_videoWithSubtitlePanel`) stay in the main shell; the parents keep calling the
/// extracted `_buildSubtitleSourcesSidePanel` / `_subtitleJumpSidePanel` through
/// shared private scope.
extension _VideoSubtitle on _VideoHibikiPageState {
  /// 翻转字幕跳转列表面板可见性（TODO-069/TODO-314；裸 L 键 / 控制条入口按钮）。
  ///
  /// asbplayer 式 transcript 面板：右侧出现当前视频的所有字幕句子，点某句 → seek 到该
  /// 句对应画面。**走 push-aside 布局**（[_videoWithSubtitlePanel] / [_subtitleListVisible]，
  /// `Row[Expanded(video), 面板列]`）真把画面挤窄到左侧、不浮层遮挡（TODO-314 根因：此前误经
  /// `_showVideoSidePanel(subtitleList)` 进 overlay 系统，push-aside 成死代码）。与其它浮层
  /// 互斥：开字幕列表先关任何打开的浮层（[_videoSidePanel]）。打开时唤醒控制条让用户看到入口。
  void _toggleSubtitleJumpList() {
    final bool next = !_subtitleListVisible.value;
    if (next) {
      _clearRailHover();
      // 与浮层互斥：开 push-aside 字幕列表前关掉任何打开的浮层（设置/音轨/倍速等）。
      _hideVideoControlEditOverlay(revealControls: false);
      // 与剧集列表互斥（TODO-638）：同一时刻右栏只占其一。
      if (_episodeListVisible.value) {
        _closeEpisodeList();
      }
      _subtitleListVisible.value = true;
      if (_videoSidePanel.value != null) {
        _hideVideoSidePanel();
      }
      // TODO-566：打开字幕列表时不再异步整表重查收藏 DB。收藏缓存
      // _favoritedVideoSentences 是单一真相源：视频 load 时由收藏缓存刷新方法预填
      // 一次，之后列表行 toggle / 查词浮层 toggle 都增量维护它。原先打开面板时再异步
      // 刷新一次，让面板先以旧缓存渲染、DB 往返后才 setState 重建，已收藏行的实心星标
      // 要「等一会」才出现。改为纯读已填充缓存 → 星标随面板同帧 O(1) 渲染，无异步延迟。
      //
      // BUG-371：不再 _markControlsVisible(false)。字幕跳转列表是 push-aside 侧栏（画面
      // 挤窄到左侧、不遮控制条），开列表时控制条 / 左右浮动 rail 应继续在被挤窄的画面上
      // 可见可用（与 [_videoSidePanel] 真 overlay 不同，后者盖控制条故仍收起）。控制条本
      // 由 media_kit 真实可见性驱动（[_pokeControlsVisible] / hover），不在此强制收起。
      _refocusVideo();
    } else {
      _closeSubtitleJumpList();
    }
  }

  /// 关闭 push-aside 字幕跳转列表（TODO-637）。**三条关闭路径的单一真相源**：
  /// 面板头部 × 按钮（[onClose]）、Esc 键、控制条字幕按钮（后两者经
  /// [_toggleSubtitleJumpList] 的关闭分支）都调它，避免「关闭副作用各写一份」分叉。
  /// 关闭时必须：清挖词选择（[_clearSelectedMiningCues]）、隐藏列表
  /// （[_subtitleListVisible]）、唤回控制条（[_pokeControlsVisible]）、把焦点归还视频
  /// （[_refocusVideo]，否则键盘 / 手柄后续失焦）。
  void _closeSubtitleJumpList() {
    _clearSelectedMiningCues();
    _subtitleListVisible.value = false;
    _pokeControlsVisible();
    _refocusVideo();
  }

  /// 点字幕跳转列表里某句：seek 到该 cue 起点（复用现成 [VideoPlayerController.skipToCue]）
  /// 并唤醒控制条。不关面板——用户常连点多句逐句跳，保持列表常驻（与 asbplayer 一致）。
  void _handleSubtitleJumpTap(AudioCue cue) {
    _pokeControlsVisible();
    unawaited(_controller?.skipToCue(cue));
  }

  /// 点字幕跳转列表里某句的文本 → 从点击命中的字符起查词（TODO-340，修 TODO-278 的
  /// 「恒从句首」回归）。复用底部字幕字符点击的同一条查词链路 [_lookupAt]（暂停视频 →
  /// 推与阅读器 / 词典页同款查词浮层），[graphemeIndex] 为列表项点击位置命中的 grapheme
  /// 下标（与底部字幕逐字查词同语义），[charRect] 为被点字符的屏幕矩形供浮层定位。
  /// 沉浸锁不允许查词时早返回（与字幕字符点击 [_handleSubtitleLookupTap] 同门控）。
  void _handleSubtitleListLookup(
    AudioCue cue,
    int graphemeIndex,
    Rect charRect,
  ) {
    if (!_immersiveAllowsLookup) return;
    final String sentence = cue.text;
    if (sentence.trim().isEmpty) return;
    unawaited(_lookupAt(sentence, graphemeIndex, charRect));
  }

  Widget _buildSubtitleSourcesSidePanel(VideoPlayerController controller) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final String? hostSub = _remoteSubtitlePath;
    final List<Widget> rows = <Widget>[
      if (_subtitleMenuLoading) const LinearProgressIndicator(),
      // TODO-573：「自动获取字幕(Jimaku)」对本地和远端视频都显示。Jimaku 只需要一个
      // 番名 query + 一个本地落盘目录；远端流没有本地视频文件（_currentVideoPath 恒
      // null），但有 host 下发的标题（_title / remoteInfo.title）可作 query，下载的
      // srt 文件经 _applyRemoteSubtitle 内存应用即可（与远端「本地导入字幕」同链路）。
      // 唯一前提是能算出非空 query，见 _jimakuQuery()。
      if (_jimakuQuery() != null)
        ListTile(
          leading: const Icon(Icons.cloud_download_outlined),
          title: Text(t.video_jimaku_fetch),
          enabled: !_subtitleLoadingShown,
          onTap: _subtitleLoadingShown
              ? null
              : () => unawaited(_openJimakuDialog(controller)),
        ),
      ListTile(
        leading: const Icon(Icons.file_open_outlined),
        title: Text(t.video_subtitle_import_file),
        enabled: !_subtitleLoadingShown,
        onTap: _subtitleLoadingShown
            ? null
            : () => unawaited(
                  _isRemote
                      ? _pickAndImportRemoteSubtitle(controller)
                      : _pickAndImportSubtitle(controller),
                ),
      ),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.subtitles_off),
        title: Text(t.video_subtitle_off),
        selected: _currentSubtitleSource == null,
        selectedColor: cs.primary,
        enabled: !_subtitleLoadingShown,
        onTap: _subtitleLoadingShown
            ? null
            : () => unawaited(
                  _isRemote
                      ? _clearRemoteSubtitle(controller)
                      : _selectSubtitleOff(controller),
                ),
      ),
      if (_isRemote && hostSub != null)
        ListTile(
          leading: const Icon(Icons.cloud_done_outlined),
          title: Text(t.video_subtitle_remote_host),
          subtitle: Text(p.basename(hostSub)),
          selected: _currentSubtitleSource == hostSub,
          selectedColor: cs.primary,
          enabled: !_subtitleLoadingShown,
          onTap: _subtitleLoadingShown
              ? null
              : () => unawaited(_applyRemoteSubtitle(controller, hostSub)),
        ),
      if (_isRemote)
        for (final RemoteVideoEmbeddedSubtitleTrack track
            in _remoteEmbeddedSubtitleTracks)
          ListTile(
            leading: Icon(
              track.isText
                  ? Icons.movie_filter_outlined
                  : Icons.image_not_supported_outlined,
            ),
            title: Text(_remoteEmbeddedSubtitleLabel(track)),
            subtitle: Text(
              track.isText
                  ? (track.fileName ?? track.codec)
                  : t.video_subtitle_import_unsupported,
            ),
            enabled: track.isText && !_subtitleLoadingShown,
            selected:
                _currentSubtitleSource == _remoteEmbeddedSubtitleSource(track),
            selectedColor: cs.primary,
            onTap: track.isText && !_subtitleLoadingShown
                ? () => unawaited(
                      _applyRemoteEmbeddedSubtitle(controller, track),
                    )
                : null,
          ),
      if (!_isRemote)
        for (final SubtitleSource source in _subtitleMenuSources)
          ListTile(
            leading: Icon(
              source.isGraphicEmbedded
                  ? Icons.image_outlined
                  : (source.isEmbedded ? Icons.movie : Icons.subtitles),
            ),
            title: Text(source.label),
            subtitle: source.isGraphicEmbedded
                ? Text(t.video_subtitle_graphic_hint)
                : null,
            selected: subtitleSourceMatchesPersistedForMenu(
              source,
              _currentSubtitleSource,
            ),
            selectedColor: cs.primary,
            enabled: !_subtitleLoadingShown,
            onTap: _subtitleLoadingShown
                ? null
                : () => unawaited(_selectSubtitleSource(controller, source)),
          ),
    ];
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rows,
    );
  }

  /// 弹「字幕源」菜单：枚举当前视频的全部字幕源（内嵌轨 + 同目录外挂文件）+
  /// 顶部「关闭字幕」项。选某源 → 解析成 cue → 切 overlay + 持久化 + SnackBar。
  ///
  /// 这是运行时覆盖；默认 load 行为（自动 sidecar 优先 + 内嵌兜底）不变。
  Future<void> _showSubtitleSourceMenu(
    VideoPlayerController controller, {
    VideoControlSlot? sourceSlot,
  }) async {
    if (_isRemote) {
      _rebuild(() {
        _subtitleMenuSources = const <SubtitleSource>[];
        _subtitleMenuLoading = false;
      });
      _showVideoSidePanel(
        _VideoSidePanelKind.subtitleSources,
        sourceSlot: sourceSlot,
      );
      return;
    }
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) {
      _rebuild(() {
        _subtitleMenuSources = const <SubtitleSource>[];
        _subtitleMenuLoading = false;
      });
      _showVideoSidePanel(
        _VideoSidePanelKind.subtitleSources,
        sourceSlot: sourceSlot,
      );
      return;
    }

    _rebuild(() {
      _subtitleMenuSources = const <SubtitleSource>[];
      _subtitleMenuLoading = true;
    });
    _showVideoSidePanel(
      _VideoSidePanelKind.subtitleSources,
      sourceSlot: sourceSlot,
    );
    final List<SubtitleSource> sources;
    try {
      sources = await _subtitleSourcesForMenu(
        videoPath: videoPath,
        currentSubtitleSource: _currentSubtitleSource,
        currentCues: controller.cues,
      );
    } catch (_) {
      if (!mounted) return;
      _rebuild(() => _subtitleMenuLoading = false);
      return;
    }
    if (!mounted) return;
    _rebuild(() {
      _subtitleMenuSources = sources;
      _subtitleMenuLoading = false;
    });
  }

  /// Jimaku 搜索用的番名 query。能算出非空 query 时返回它，否则返回 null
  /// （= 字幕菜单不显示「自动获取字幕」入口）。
  ///
  /// - 本地视频（[_currentVideoPath] 非空）：用文件名解析出的 series（番名）。
  /// - 远端视频（[_isRemote]，无本地文件名）：用 host 下发的标题
  ///   `_title ?? remoteInfo.title`（= host 库里的 VideoBook.title，本身就是番名/
  ///   系列名）。再过一道 [parseVideoFilename]，标题里带集数/扩展名时也能收敛成 series。
  String? _jimakuQuery() {
    final String? videoPath = _currentVideoPath;
    if (videoPath != null && videoPath.trim().isNotEmpty) {
      final String series =
          parseVideoFilename(p.basename(videoPath)).series.trim();
      return series.isEmpty ? null : series;
    }
    if (_isRemote) {
      final String title = (_title ?? widget.remoteInfo?.title ?? '').trim();
      if (title.isEmpty) return null;
      final String series = parseVideoFilename(title).series.trim();
      return series.isEmpty ? title : series;
    }
    return null;
  }

  /// 打开「自动获取字幕（Jimaku）」对话框：用番名（[_jimakuQuery]）搜 → 下载到
  /// `<appDocs>/video_subtitles/` → 应用。
  ///
  /// - 本地视频：构造外挂 [SubtitleSource] 经 [_selectSubtitleSource] 持久化链路应用。
  /// - 远端视频（[_isRemote]）：没有本地 DB 行，按远端契约只在内存里应用，经
  ///   [_applyRemoteSubtitle]（与远端「本地导入字幕」同一不落 DB 的链路）。
  ///
  /// 真实拉取需有效 Jimaku API key + 联网（验证待用户）。
  Future<void> _openJimakuDialog(VideoPlayerController controller) async {
    final String? query = _jimakuQuery();
    if (query == null) return;
    final Directory docs = await getApplicationDocumentsDirectory();
    final String saveDir = p.join(docs.path, 'video_subtitles');
    if (!context.mounted) return;
    final String? downloaded = await showDialog<String>(
      context: context,
      builder: (_) => JimakuSubtitleDialog(
        initialQuery: query,
        initialApiKey: appModel.jimakuApiKey,
        onApiKeyChanged: (String key) => appModel.setJimakuApiKey(key),
        saveDirectory: saveDir,
      ),
    );
    // Jimaku 对话框内含联网搜索/下载，会夺焦；关闭后把焦点还给 Video。
    _refocusVideo();
    if (downloaded == null || !context.mounted) return;
    if (_isRemote) {
      // 远端：内存应用，不写本地 DB（_applyRemoteSubtitle 自带 cue 为空时的失败提示
      // + 成功 OSD），不叠加额外提示。
      await _applyRemoteSubtitle(controller, downloaded);
      return;
    }
    final SubtitleSource source = SubtitleSource.external(
      externalPath: downloaded,
      label: p.basename(downloaded),
    );
    final bool applied = await _selectSubtitleSource(controller, source);
    // 仅在字幕真被应用（解析出 cue）时报「已下载并应用」；cue 为空时
    // _selectSubtitleSource 已弹失败提示，不再叠加误导性的成功提示。
    if (applied && mounted) {
      _showOsd(t.video_jimaku_downloaded);
    }
  }

  /// 弹系统文件选择器挑一个字幕文件（srt/ass/ssa/vtt）→ 经 [_importExternalSubtitle]
  /// 落盘并应用。FilePicker 会夺走视频键盘焦点，关闭后 [_refocusVideo] 归还。
  Future<void> _pickAndImportSubtitle(VideoPlayerController controller) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    _refocusVideo();
    final String? path = result?.files.single.path;
    if (path == null) return;
    await _importExternalSubtitle(controller, path);
  }

  /// 远端模式：弹文件选择器挑字幕 → 直接在内存里应用到当前流（不拷盘、不持久化）。
  Future<void> _pickAndImportRemoteSubtitle(
    VideoPlayerController controller,
  ) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    _refocusVideo();
    final String? path = result?.files.single.path;
    if (path == null) return;
    if (subtitleFormatForPath(path) == null) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    await _applyRemoteSubtitle(controller, path);
  }

  /// 远端模式：把 [path] 字幕文件解析成 cue 并切到 overlay（仅内存，不写本地 DB）。
  /// 解析空 cue（坏字幕 / 图形轨）时诚实告知失败、不切换。
  Future<void> _applyRemoteSubtitle(
    VideoPlayerController controller,
    String path, {
    String? selectedSource,
    String? label,
  }) async {
    final String displayLabel = label ?? p.basename(path);
    _showSubtitleLoadingOverlay();
    final List<AudioCue> cues;
    try {
      cues = await _loadExternalSubtitleCues(path, widget.bookUid);
    } finally {
      _hideSubtitleLoadingOverlay();
    }
    if (!mounted) return;
    if (cues.isEmpty) {
      _showOsd(t.video_subtitle_load_failed(label: displayLabel));
      return;
    }
    controller.setCues(cues);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    if (!mounted) return;
    _rebuild(() => _currentSubtitleSource = selectedSource ?? path);
    _showOsd(t.video_subtitle_switched(label: displayLabel));
  }

  String _remoteEmbeddedSubtitleSource(
    RemoteVideoEmbeddedSubtitleTrack track,
  ) =>
      'embedded:${track.streamIndex}';

  String _remoteEmbeddedSubtitleLabel(RemoteVideoEmbeddedSubtitleTrack track) {
    final List<String> parts = <String>[
      if ((track.language ?? '').isNotEmpty) track.language!,
      if ((track.title ?? '').isNotEmpty) track.title!,
      track.codec,
    ];
    return 'Embedded ${track.streamIndex}: ${parts.join(' / ')}';
  }

  Future<void> _applyRemoteEmbeddedSubtitle(
    VideoPlayerController controller,
    RemoteVideoEmbeddedSubtitleTrack track,
  ) async {
    if (!track.isText) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    final RemoteVideoClient? client = widget.remoteClient;
    final RemoteVideoInfo? info = widget.remoteInfo;
    if (client == null || info == null) return;
    final Directory temp = await getTemporaryDirectory();
    final File subtitle = File(
      p.join(
        temp.path,
        _remoteSubtitleTempFileName(
          info.id,
          track.fileName ?? 'embedded_${track.streamIndex}.srt',
        ),
      ),
    );
    await client.getRemoteVideoSubtitle(
      info.id,
      subtitle,
      embeddedStreamIndex: track.streamIndex,
    );
    final String source = _remoteEmbeddedSubtitleSource(track);
    await _applyRemoteSubtitle(
      controller,
      subtitle.path,
      selectedSource: source,
      label: _remoteEmbeddedSubtitleLabel(track),
    );
  }

  /// 远端模式：关闭字幕（清空 cue overlay + 关 libmpv 字幕轨；仅内存，不写本地 DB）。
  Future<void> _clearRemoteSubtitle(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    if (!mounted) return;
    _rebuild(() => _currentSubtitleSource = null);
  }

  Future<void> _importExternalSubtitle(
    VideoPlayerController controller,
    String srcPath,
  ) async {
    if (_currentVideoPath == null) return;
    if (_subtitleImportsInFlight.contains(srcPath)) return;
    _subtitleImportsInFlight.add(srcPath);
    try {
      await _importExternalSubtitleInner(controller, srcPath);
    } finally {
      _subtitleImportsInFlight.remove(srcPath);
    }
  }

  /// [_importExternalSubtitle] 的实体（去重外壳已挡住并发同路径重入）。
  Future<void> _importExternalSubtitleInner(
    VideoPlayerController controller,
    String srcPath,
  ) async {
    if (subtitleFormatForPath(srcPath) == null) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory destDir = Directory(p.join(docs.path, 'video_subtitles'));
    await destDir.create(recursive: true);
    final String dest = p.join(destDir.path, p.basename(srcPath));
    if (!p.equals(srcPath, dest)) {
      try {
        await File(srcPath).copy(dest);
      } catch (_) {
        if (!mounted) return;
        _showOsd(t.video_subtitle_import_failed);
        return;
      }
    }
    if (!mounted) return;
    final SubtitleSource source = SubtitleSource.external(
      externalPath: dest,
      label: p.basename(dest),
    );
    await _selectSubtitleSource(controller, source);
    debugPrint(
      '[hibiki-drop] [video-playback] externalSubtitle imported '
      'path=$dest',
    );
  }

  /// 在字幕源侧栏里展示非阻塞加载状态（BUG-104：大容器内嵌字幕 demux 可达数十秒）。
  void _showSubtitleLoadingOverlay() {
    if (_subtitleLoadingShown || !mounted) return;
    _rebuild(() => _subtitleLoadingShown = true);
    if (_videoSidePanel.value?.kind != _VideoSidePanelKind.subtitleSources) {
      _showVideoSidePanel(_VideoSidePanelKind.subtitleSources);
    }
  }

  /// 关闭字幕抽取加载状态。配对 [_showSubtitleLoadingOverlay]，幂等，并在下一帧把
  /// 键盘焦点还给视频，避免文件选择器/外部对话框返回后快捷键悬空。
  void _hideSubtitleLoadingOverlay() {
    if (!_subtitleLoadingShown) return;
    if (mounted) {
      _rebuild(() => _subtitleLoadingShown = false);
      WidgetsBinding.instance.addPostFrameCallback((_) => _refocusVideo());
    }
  }

  /// 选中某字幕源：加载 cue → 切 overlay → 持久化 → SnackBar。
  /// 返回 true 表示字幕真被应用（解析出 cue 并切换/持久化）；false 表示空 cue
  /// 失败（已弹失败提示、未切换、未持久化、未覆盖当前可用字幕）。
  Future<bool> _selectSubtitleSource(
    VideoPlayerController controller,
    SubtitleSource source,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return false;

    // BUG-122: 图形内封轨（PGS/DVD 等位图）无法转文本 cue（ffmpeg 抽 srt 直接报
    // bitmap→bitmap 拒绝），交给 libmpv 当画面字幕渲染：看得到、不可逐字查词。瞬时
    // 切轨、无需抽取，故不走加载遮罩 / loadCuesForSource。
    if (source.isGraphicEmbedded) {
      final bool shown = await controller.selectEmbeddedGraphicTrack(
        source.streamIndex!,
      );
      if (!mounted) return false;
      if (!shown) {
        _showOsd(t.video_subtitle_load_failed(label: source.label));
        return false;
      }
      final String persisted = source.toPersistedValue();
      // 图形轨没有 cue，只落源指针（单视频也清掉旧 cue，避免上次文本 cue 残留把
      // overlay 又显示回来）；播放列表各集只存源指针，与文本分支一致。
      if (_episodes.isEmpty) {
        await widget.repo.saveSubtitleSelection(
          bookUid: widget.bookUid,
          subtitleSource: persisted,
          cues: const <AudioCue>[],
        );
      } else {
        await widget.repo.updateSubtitleSource(widget.bookUid, persisted);
      }
      if (!mounted) return false;
      _rebuild(() => _currentSubtitleSource = persisted);
      _showOsd(t.video_subtitle_graphic_shown(label: source.label));
      return true;
    }

    // BUG-104: 内嵌字幕要从容器里 demux 抽取，大文件（如 27GB REMUX）首次可达
    // ~20s。期间给一个不可关的加载遮罩，否则底栏菜单一关、画面字幕没变，用户会以为
    // 「点了没反应、没切换过去」。抽取走单趟全轨缓存，同一视频后续切换瞬时命中。
    _showSubtitleLoadingOverlay();
    final List<AudioCue> cues;
    try {
      cues = await loadCuesForSource(source, videoPath, widget.bookUid);
    } finally {
      _hideSubtitleLoadingOverlay();
    }
    if (!mounted) return false;
    // 抽取/解析后无任何 cue（图形字幕、ffmpeg 缺失、轨损坏等）：诚实告知失败，
    // **不切换、不持久化**——避免谎报「已切换」却空屏，也避免用一个坏内封轨覆盖掉
    // 当前正常工作的字幕源（下次进来还是空）。
    if (cues.isEmpty) {
      _showOsd(t.video_subtitle_load_failed(label: source.label));
      return false;
    }
    controller.setCues(cues);
    // 选了文本字幕源就关掉 libmpv 画面字幕，避免与可点 overlay 双重渲染。
    await controller.selectSubtitleTrack(SubtitleTrack.no());

    final String persisted = source.toPersistedValue();
    // BUG-081: 单视频把解析出的 cue 落库，重进时 `_loadSingle` 的 `loadCues`
    // 直接命中，无需用户再手动加载。cue 与字幕源指针**原子**写入（事务），避免
    // 半落库导致下次恢复内容与源标签不一致。播放列表各集有意不存 cue（每集外部
    // 文件按磁盘动态解析，避免跨集 bookUid 错配，见 `_loadEpisode` 注释），故只
    // 写源指针。
    if (_episodes.isEmpty) {
      await widget.repo.saveSubtitleSelection(
        bookUid: widget.bookUid,
        subtitleSource: persisted,
        cues: cues,
      );
    } else {
      await widget.repo.updateSubtitleSource(widget.bookUid, persisted);
    }
    if (!mounted) return false;
    _rebuild(() => _currentSubtitleSource = persisted);
    _showOsd(t.video_subtitle_switched(label: source.label));
    return true;
  }

  /// 关闭字幕：清空 cue overlay + 关 libmpv 字幕轨 + 持久化 null。
  Future<void> _selectSubtitleOff(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    // BUG-081: 关字幕也要清掉单视频已落库的 cue，否则重进时 `loadCues` 命中旧
    // cue 又把字幕显示回来。cue 与源指针原子清空（事务）。播放列表不入 cue，只
    // 清源指针。
    if (_episodes.isEmpty) {
      await widget.repo.saveSubtitleSelection(
        bookUid: widget.bookUid,
        subtitleSource: null,
        cues: const <AudioCue>[],
      );
    } else {
      await widget.repo.updateSubtitleSource(widget.bookUid, null);
    }
    if (!mounted) return;
    _rebuild(() => _currentSubtitleSource = null);
  }

  /// [_videoWithSubtitlePanel] 的右侧面板列。用 [AnimatedSize] 让列宽在 0 ↔ panelWidth
  /// 之间平滑伸缩（画面被挤窄/还原也跟着动），可见时渲染 [VideoSubtitleJumpPanel]，隐藏
  /// 时宽度收成 0（[ClipRect] 裁掉收缩中溢出的内容，避免动画期文字越界）。[OverflowBox]
  /// 把面板内容固定在 panelWidth、不随收缩中的列宽被挤压，故伸缩动画里文字布局稳定。
  Widget _subtitleJumpSidePanel(
    VideoPlayerController controller,
    bool visible,
  ) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double panelWidth = (screenWidth * 0.28).clamp(240.0, 420.0);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: visible ? panelWidth : 0,
        // BUG-391 r5 根因修：整列最外层包一层声明式 opaque MouseRegion（cursor:basic），
        // 让 MouseTracker 把侧栏列视为独立 annotation、鼠标进列即进干净 basic 会话，绕开
        // 「视频列 none 会话残留 + lastSession 去重」竞态（见 _withSidePanelOpaqueCursor）。
        // 仅可见时存在 annotation；隐藏时透传 SizedBox.shrink（零宽、无 region）。
        child: visible
            ? _withSidePanelOpaqueCursor(
                ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: panelWidth,
                    maxWidth: panelWidth,
                    // BUG-391：字幕列表是 push-aside 侧栏（[_videoWithSubtitlePanel] 的
                    // Row 兄弟列），不在视频区 controls 的 cursor:none 胜出层几何内。但鼠标
                    // 从画面区（控制条 2s 淡出后 media_kit `hideMouseOnControlsRemoval` +
                    // 顶层 [_buildCursorOverlay] 把光标置 none）移进侧栏时，侧栏没有任何
                    // region 主动唤回光标 / 续命 media_kit 控制条 → 桌面 OS 光标残留隐藏态
                    // （与画面字幕盒 BUG-283 同根：cursor:none 胜出 + 缺 hover 唤回）。这里
                    // 复用字幕盒同款救场 [_handleSubtitleHover]：鼠标进 / 移动在侧栏上即
                    // [_setCursorHidden]false 让顶层胜出层让位 + [_pokeControlsVisible] 续命
                    // 控制条（避免 media_kit `mount=false` 让其自己的 cursor 置 none），使光标
                    // 在字幕列表上可见。`opaque:false` 不阻断指针下探（cue 行点击 / 查词 /
                    // 滚动照常）；仅桌面有 OS 光标语义才挂（移动端透传，零开销）。
                    child: _withSubtitleListCursorReveal(
                      SafeArea(
                        left: false,
                        child: VideoSubtitleJumpPanel(
                          key: const ValueKey<String>(
                              'video-subtitle-jump-panel'),
                          controller: controller,
                          onTapCue: _handleSubtitleJumpTap,
                          onLookupCue: _handleSubtitleListLookup,
                          onCopyCue: _copyCueText,
                          onFavoriteCue: _toggleFavoriteCueForVideo,
                          isCueFavorited: _isCueFavorited,
                          isCueSelectedForCard: _isCueSelectedForCard,
                          onToggleCueSelection: _toggleCueSelectedForCard,
                          onClearCueSelection: _clearSelectedMiningCues,
                          // TODO-613：自动滚动开关初值从 Drift preferences 读，切换时落盘。
                          initialAutoScroll:
                              appModel.videoSubtitleListAutoScroll,
                          onAutoScrollChanged: (bool value) => unawaited(
                            appModel.setVideoSubtitleListAutoScroll(value),
                          ),
                          onClose: _closeSubtitleJumpList,
                          colorScheme: cs,
                          title: t.video_subtitle_list,
                          emptyHint: t.video_subtitle_list_empty,
                          loadingHint: t.video_subtitle_list_loading,
                          fontSize: 14 * _videoUiScale,
                          width: panelWidth,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  /// TODO-701 阶段1：一键字幕自动对轴。抽当前视频的逐帧音频能量包络（[extractAudioEnergyEnvelope]
  /// 经 ffmpeg 抽象），与字幕 cue 时间轴栅格化后做互相关（[bestOffsetMsByCrossCorrelation]）
  /// 求**整体平移** offset，再走现有 [_setDelayMs] 写穿 `delayMs` 落盘（零新持久化）。
  ///
  /// **只整体平移、不重排 cue、不解帧率漂移**——等价于自动算出「手动延迟」该填多少。
  /// 输入不足（无 cue/无视频路径/无音频包络）或置信度低于阈值时**不**改动延迟，仅弹
  /// 低置信 OSD（避免乱平移）。移动端 [KitFfmpegBackend] 拿不到逐帧 RMS 时包络为空，
  /// 走 noData 分支安全降级（[extractAudioEnergyEnvelope] 已 debugPrint 诊断）。
  Future<void> _autoAlignSubtitle() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final List<AudioCue> cues = controller.cues;
    final String? videoPath = controller.videoPath;
    final int? durationMs = controller.durationMs;
    if (cues.isEmpty || videoPath == null || videoPath.isEmpty) {
      _showOsd(t.video_subtitle_auto_align_low_confidence);
      return;
    }
    // 时长缺失时用最后一条 cue 的结束时间兜底（cue 升序由 setCues 保证），仍能栅格化。
    final int effectiveDurationMs =
        (durationMs != null && durationMs > 0) ? durationMs : cues.last.endMs;

    _showOsd(
      t.video_subtitle_auto_align_running,
      icon: Icons.auto_fix_high,
    );

    final List<double> rawRms = await extractAudioEnergyEnvelope(
      videoPath: videoPath,
      windowMs: kSubtitleAutoAlignBinMs,
      audioStreamIndex: controller.currentAudioStreamIndex,
    );
    if (!mounted) return;

    final List<double> audioActivity = normalizeAudioEnergyEnvelope(rawRms);
    final List<double> cueActivity = buildCueActivityEnvelope(
      cues,
      effectiveDurationMs,
      binMs: kSubtitleAutoAlignBinMs,
    );
    final SubtitleAutoAlignResult result = bestOffsetMsByCrossCorrelation(
      audioActivity,
      cueActivity,
      binMs: kSubtitleAutoAlignBinMs,
    );

    switch (result.status) {
      case SubtitleAutoAlignStatus.aligned:
        // 走现有写穿路径：controller 即时重算 cue + 落盘 delayMs + 角标 OSD。
        await _setDelayMs(result.offsetMs);
        if (!mounted) return;
        _showOsd(
          t.video_subtitle_auto_align_done(ms: result.offsetMs),
          icon: Icons.auto_fix_high,
        );
        break;
      case SubtitleAutoAlignStatus.lowConfidence:
      case SubtitleAutoAlignStatus.noData:
        _showOsd(t.video_subtitle_auto_align_low_confidence);
        break;
    }
  }
}
