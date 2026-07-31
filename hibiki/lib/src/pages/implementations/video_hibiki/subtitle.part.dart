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
/// extracted `_buildSubtitleTrackSettingsSection` (TODO-1351: subtitle-track
/// switching folded into the settings sheet's `subtitle` category) /
/// `_subtitleJumpSidePanel` through shared private scope.
/// TODO-1302：YouTube 预解析字幕（[UrlStreamVideoClient.preresolvedCues]）的合成字幕源
/// 哨兵。YouTube 字幕不是 host 外挂文件、也不是容器内嵌轨枚举，而是 resolver 预解析好的
/// cue 直接注入 overlay。用一个非空源标识它，让远端字幕菜单能渲染并高亮「YouTube 字幕」行，
/// 且「关闭」（[_currentSubtitleSource]==null 判据）不被误显选中（根因：此前不登记任何源，
/// _currentSubtitleSource 留 null → 菜单无行 + 关闭高亮 → 选不到 YouTube 字幕）。
const String _kYoutubeCaptionsSource = 'youtube:captions';

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
      _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
    } else {
      _closeSubtitleJumpList();
    }
  }

  /// 关闭 push-aside 字幕跳转列表（TODO-637）。**三条关闭路径的单一真相源**：
  /// 面板头部 × 按钮（[onClose]）、Esc 键、控制条字幕按钮（后两者经
  /// [_toggleSubtitleJumpList] 的关闭分支）都调它，避免「关闭副作用各写一份」分叉。
  /// 关闭时必须：清挖词选择（[_clearSelectedMiningCues]）、隐藏列表
  /// （[_subtitleListVisible]）、唤回控制条（[_pokeControlsVisible]）、把焦点归还视频
  /// （[_focusOwnership]，否则键盘 / 手柄后续失焦）。
  void _closeSubtitleJumpList() {
    _clearSelectedMiningCues();
    _subtitleListVisible.value = false;
    _pokeControlsVisible();
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
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
    // BUG-966：把被点的列表 cue 透传给查词，作为制卡音频锚点——列表里的句可能远离播放头
    // （点列表只暂停不 seek），不透传会回落到播放位置那句、截出别的句子的声音。
    unawaited(_lookupAt(sentence, graphemeIndex, charRect, overrideCue: cue));
  }

  /// TODO-1351：字幕轨/字幕源切换区，收进设置面板「字幕」分类顶部（取代原来外面浮的
  /// 字幕轨侧栏）。用 [Builder] 让配色随设置面板浅色 MD3 主题解析（而非视频 chrome 深色）；
  /// 行内容（自动获取字幕 / 打开字幕文件 / 关闭 / 本地内嵌+外挂源 / 远端 YouTube+内嵌+host
  /// / 副字幕入口）与选择逻辑与旧侧栏逐行一致，数据随视频页 `_rebuild` 重建。
  Widget _buildSubtitleTrackSettingsSection(VideoPlayerController controller) {
    return Builder(
      builder: (BuildContext context) => _buildSubtitleTrackRows(
        context,
        controller,
      ),
    );
  }

  Widget _buildSubtitleTrackRows(
    BuildContext context,
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
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
        // TODO-818：「关闭」项高亮判据。本地用显式关闭哨兵；远端模式不落库（关闭仅
        // 清内存 _currentSubtitleSource=null），故 null 也算关闭，覆盖两种表面。
        selected: SubtitleSource.isOff(_currentSubtitleSource) ||
            (_isRemote && _currentSubtitleSource == null),
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
      // TODO-1302 track-list-first：每条 YouTube 字幕轨一行（元数据先来、cue 懒下载 on-select）。
      // 轨列表由 [_resolveDeferredYoutubeCaptionTracks] 起播后回填 client（不依赖 cue 就绪 →
      // 修「字幕整个消失」），点某行经 [_applyYoutubeCaptionTrack] 懒下载那一轨 cue 挂 overlay，
      // 选中态由 [YoutubeCaptionTrack.trackKey] 判定；A3：人工>ASR 已在轨表排序，含母语对照变体。
      if (_isRemote)
        for (final YoutubeCaptionTrack track in _youtubeCaptionTracks)
          ListTile(
            leading: const Icon(Icons.closed_caption_outlined),
            title: Text(_youtubeCaptionTrackLabel(track)),
            selected: _currentSubtitleSource == track.trackKey,
            selectedColor: cs.primary,
            enabled: !_subtitleLoadingShown,
            onTap: _subtitleLoadingShown
                ? null
                : () => unawaited(_applyYoutubeCaptionTrack(controller, track)),
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
      // TODO-857 / TODO-1312 视频双字幕：副字幕入口。副字幕走 Flutter overlay 副层
      // cue 流（可逐字符查词），仅本地视频内嵌轨（远端无内嵌轨枚举，不显示）。
      // TODO-1350：副字幕源改内联可展开区（ExpansionTile），在「字幕」分类里就地切换，
      // 不再点一下跳到另一个浮层窗口（用户报「副字幕打开会去到另一个窗口」）。
      if (!_isRemote) const Divider(height: 1),
      if (!_isRemote)
        ExpansionTile(
          // TODO-1350：副字幕入口的 leading 图标要和上面字幕轨 ListTile 的图标同一
          // 缩进（ListTile 默认水平 16px）。此前 tilePadding: EdgeInsets.zero 把表头
          // 图标顶到最左边、比其它行图标偏左没对齐（用户报「副字幕图标位置不对」）；
          // 去掉该覆盖走 ExpansionTile 默认 16px 缩进即与兄弟行对齐。childrenPadding
          // 保持零：展开项本身是带默认 contentPadding 的 ListTile，各自缩进已对齐。
          leading: const Icon(Icons.subtitles_outlined),
          title: Text(t.video_secondary_subtitle_sources),
          subtitle: Text(t.video_secondary_subtitle_hint),
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          children: _buildSecondarySubtitleRows(context, controller),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  /// 副字幕源行（TODO-857 / TODO-1312 视频双字幕）：顶部「关闭」项 + 与主字幕**同一份**
  /// 可用字幕列表 [_subtitleMenuSources]（内嵌轨 + 同目录外挂文件；BUG-900：此前只取
  /// 内嵌轨，用户下载的外挂字幕没法选为副字幕——「副字幕没办法添加」）。选择链路
  /// [_selectSecondarySubtitleSource] 走同一 [loadCuesForSource]（内嵌 ffmpeg demux、
  /// 外挂读文件）本就支持两类源；图形位图轨抽不出文本 cue，选中时返回空、诚实提示失败。
  /// 副字幕走 Flutter overlay 副层 cue 流（**可逐字符查词**），与主字幕同款。TODO-1350：
  /// 这些行以前住在一个独立浮层侧栏里（点「副字幕」跳到另一个窗口，用户报「副字幕打开
  /// 会去到另一个窗口」）；现直接内联在「字幕」分类的可展开区里就地切换。
  /// [context] 是设置面板（浅色 MD3）的构建上下文，配色随之解析（与主字幕轨行一致）。
  List<Widget> _buildSecondarySubtitleRows(
    BuildContext context,
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return <Widget>[
      if (_subtitleMenuLoading) const LinearProgressIndicator(),
      ListTile(
        leading: const Icon(Icons.subtitles_off),
        title: Text(t.video_subtitle_off),
        // 「关闭」高亮：显式关闭哨兵或无副字幕（null）。
        selected: SubtitleSource.isOff(_currentSecondarySubtitleSource) ||
            _currentSecondarySubtitleSource == null,
        selectedColor: cs.primary,
        enabled: !_subtitleLoadingShown,
        onTap: _subtitleLoadingShown
            ? null
            : () => unawaited(_selectSecondarySubtitleOff(controller)),
      ),
      const Divider(height: 1),
      // BUG-900：遍历完整 [_subtitleMenuSources]（与主字幕轨行同一份可用列表），外挂
      // 字幕文件也能选为副字幕。图标与主字幕轨行一致：图形轨 image / 内嵌 movie /
      // 外挂 subtitles。
      for (final SubtitleSource source in _subtitleMenuSources)
        ListTile(
          leading: Icon(
            source.isGraphicEmbedded
                ? Icons.image_outlined
                : (source.isEmbedded ? Icons.movie : Icons.subtitles),
          ),
          title: Text(source.label),
          selected: source.matchesPersisted(_currentSecondarySubtitleSource),
          selectedColor: cs.primary,
          enabled: !_subtitleLoadingShown,
          onTap: _subtitleLoadingShown
              ? null
              : () =>
                  unawaited(_selectSecondarySubtitleSource(controller, source)),
        ),
    ];
  }

  /// 弹「字幕源」菜单：枚举当前视频的全部字幕源（内嵌轨 + 同目录外挂文件）+
  /// 顶部「关闭字幕」项。选某源 → 解析成 cue → 切 overlay + 持久化 + SnackBar。
  ///
  /// 这是运行时覆盖；默认 load 行为（自动 sidecar 优先 + 内嵌兜底）不变。
  Future<void> _showSubtitleSourceMenu(
    VideoPlayerController controller, {
    VideoControlSlot? sourceSlot,
  }) async {
    // BUG-939：控制条「字幕轨」按钮不再自己枚举字幕源。枚举的单一真相源是
    // [_ensureSubtitleMenuSourcesLoaded]——它由设置面板「字幕」分类被打开这一事件驱动
    // （[VideoQuickSettingsSheet.onSubtitleCategoryShown]，initState / didUpdateWidget /
    // 手动切分类三条路径都会触发），并按视频路径缓存。此前这里额外清空 `_subtitleMenuSources`
    // 再重跑 ffprobe，导致每次点按钮已枚举的字幕轨先消失、且与面板回调重复枚举显加载条。
    // 现在退化为纯粹打开面板即可；无本地路径时顺手清掉可能残留的旧枚举缓存。
    if (_isRemote || _currentVideoPath == null) {
      if (_subtitleMenuSources.isNotEmpty ||
          _subtitleMenuLoading ||
          _subtitleMenuSourcesPath != null) {
        _rebuild(() {
          _subtitleMenuSources = const <SubtitleSource>[];
          _subtitleMenuLoading = false;
          _subtitleMenuSourcesPath = null;
        });
      }
    }
    // TODO-1351：字幕轨切换收进设置面板「字幕」分类顶部（取代外面浮的字幕轨侧栏）。
    _showPlayerSettings(sourceSlot: sourceSlot, initialCategory: 'subtitle');
  }

  /// TODO-1350（字幕轨即时加载）：进入设置面板「字幕」分类时（重新）枚举当前视频的字幕源
  /// 填 [_subtitleMenuSources]（主字幕轨行 + 内联副字幕轨行都读它）。此前 [_subtitleMenuSources]
  /// 只由「字幕轨」控制按钮的 [_showSubtitleSourceMenu] 预填——用户经设置齿轮进面板再点
  /// 「字幕」分类 chip / 导航行时不走那条路径，字幕轨列表就空着，得关掉重开才加载（用户报
  /// 「字幕轨不即时加载」）。改由「字幕分类被打开」事件
  /// （[VideoQuickSettingsSheet.onSubtitleCategoryShown]）驱动，两个入口统一：
  ///  - 远端 / 无本地视频路径：字幕轨走 [_youtubeCaptionTracks] / [_remoteEmbeddedSubtitleTracks]，
  ///    本地源列表清空即可（[_buildSubtitleTrackRows] 远端分支不读 [_subtitleMenuSources]）。
  ///  - 本地视频：ffprobe 枚举内嵌轨 + 同目录外挂（[_subtitleSourcesForMenu]，只探测轨元数据、
  ///    非全量 demux，开销小），loading 期间字幕轨区顶部显 [LinearProgressIndicator]。
  /// 已在枚举中（[_subtitleMenuLoading]）则跳过，避免与 [_showSubtitleSourceMenu] 的加载重复。
  Future<void> _ensureSubtitleMenuSourcesLoaded() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final String? videoPath = _currentVideoPath;
    if (_isRemote || videoPath == null) {
      if (_subtitleMenuSources.isNotEmpty ||
          _subtitleMenuLoading ||
          _subtitleMenuSourcesPath != null) {
        _rebuild(() {
          _subtitleMenuSources = const <SubtitleSource>[];
          _subtitleMenuLoading = false;
          _subtitleMenuSourcesPath = null;
        });
      }
      return;
    }
    // BUG-939：已为当前视频枚举过就直接用缓存，不再重跑 ffprobe、不再显加载条。
    // 修「每次进字幕分类都要加载、明明没可加载的地方」——无内嵌轨/外挂的视频枚举结果
    // 恒空，但只跑一次；有轨的视频重开时也不再把已枚举的字幕轨先清空重来。缓存在换视频
    // （路径变）与导入新字幕档（[_invalidateSubtitleMenuSourcesCache]）时失效。
    if (_subtitleMenuSourcesPath == videoPath) return;
    if (_subtitleMenuLoading) return;
    _rebuild(() => _subtitleMenuLoading = true);
    final List<SubtitleSource> sources;
    try {
      sources = await _subtitleSourcesForMenu(
        videoPath: videoPath,
        currentSubtitleSource: _currentSubtitleSource,
        currentCues: controller.cues,
      );
    } catch (_) {
      // 枚举失败不写缓存 key，下次打开重试（ffprobe 偶发失败不该被缓存成「已加载空」）。
      if (!mounted) return;
      _rebuild(() => _subtitleMenuLoading = false);
      return;
    }
    if (!mounted) return;
    _rebuild(() {
      _subtitleMenuSources = sources;
      _subtitleMenuLoading = false;
      _subtitleMenuSourcesPath = videoPath;
    });
  }

  /// BUG-939：让字幕轨枚举缓存失效（下次打开「字幕」分类重新 ffprobe 枚举）。导入新字幕
  /// 档（[_importExternalSubtitleInner] / Jimaku 下载）后调用——新档不在旧枚举结果里，
  /// 靠这条让它下次出现在字幕轨列表。换视频不需调它（缓存 key 是视频路径，路径变自然失效）。
  void _invalidateSubtitleMenuSourcesCache() {
    _subtitleMenuSourcesPath = null;
  }

  /// 选中某副字幕源（TODO-857 / TODO-1312）：抽 cue → [VideoPlayerController.setSecondaryCues]
  /// 交给 Flutter overlay 副层渲染（**不再** libmpv `secondary-sid` 自渲染）→ 持久化
  /// `embedded:<n>` / 外挂路径 → setState。副字幕因此与主字幕同款可逐字符查词。与主字幕
  /// 复用同一 [loadCuesForSource]（内嵌走 ffmpeg demux、外挂读文件）；空 cue（图形位图轨 /
  /// 抽取失败 / 坏轨）诚实提示失败、不切换、不持久化（不覆盖当前副字幕）。
  Future<bool> _selectSecondarySubtitleSource(
    VideoPlayerController controller,
    SubtitleSource source,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return false;
    _showSubtitleLoadingOverlay();
    final List<AudioCue> cues;
    try {
      cues = await loadCuesForSource(source, videoPath, widget.bookUid);
    } finally {
      _hideSubtitleLoadingOverlay();
    }
    if (!mounted) return false;
    if (cues.isEmpty) {
      _showOsd(t.video_subtitle_load_failed(label: source.label));
      return false;
    }
    controller.setSecondaryCues(cues);
    final String persisted = source.toPersistedValue();
    await widget.repo.updateSecondarySubtitleSource(widget.bookUid, persisted);
    if (!mounted) return false;
    _rebuild(() => _currentSecondarySubtitleSource = persisted);
    _showOsd(t.video_subtitle_switched(label: source.label));
    return true;
  }

  /// 关闭副字幕（TODO-857 / TODO-1312）：清副字幕 cue 流 + 持久化「显式关闭」哨兵。
  /// 与主字幕「关闭」对称（哨兵区分「无偏好 null」与「显式关闭」，恢复时不自动重选）。
  Future<void> _selectSecondarySubtitleOff(
    VideoPlayerController controller,
  ) async {
    controller.clearSecondaryCues();
    await widget.repo.updateSecondarySubtitleSource(
      widget.bookUid,
      SubtitleSource.offSentinel,
    );
    if (!mounted) return;
    _rebuild(
        () => _currentSecondarySubtitleSource = SubtitleSource.offSentinel);
  }

  /// 视频就绪后恢复用户选过的副字幕轨（TODO-857 / TODO-1312）。支持内嵌轨（`embedded:<n>`）
  /// 与外挂字幕文件绝对路径（BUG-900：与主字幕同一份可用列表后，副字幕也能选外挂，恢复
  /// 须对称支持外挂——否则重开视频副字幕丢失）：
  ///  - 内嵌：解析 streamIndex → [SubtitleSource.embedded]。
  ///  - 外挂：绝对路径存在 → [SubtitleSource.external]（文件不在则跳过，与主字幕
  ///    [_restorePersistedSubtitle] 同判据）。
  /// 再 [loadCuesForSource] 抽 cue → [VideoPlayerController.setSecondaryCues]。
  /// null=无偏好 / `off:`=显式关闭 都不加载，保持无副字幕。空 cue（图形轨 / 抽取失败 /
  /// 坏文件）静默跳过（不弹失败——恢复是后台行为，不打扰用户）。
  Future<void> _restoreSecondarySubtitle(
    VideoPlayerController controller,
  ) async {
    final String? persisted = _currentSecondarySubtitleSource;
    if (persisted == null || persisted.isEmpty) return;
    if (SubtitleSource.isOff(persisted)) return;
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return;
    final SubtitleSource? source;
    if (persisted.startsWith(SubtitleSource.embeddedPrefix)) {
      final int? streamIndex = int.tryParse(
        persisted.substring(SubtitleSource.embeddedPrefix.length),
      );
      if (streamIndex == null) return;
      source = SubtitleSource.embedded(
        streamIndex: streamIndex,
        label: 'embedded:$streamIndex',
      );
    } else if (File(persisted).existsSync()) {
      // 外挂源持久化值即其绝对路径（[SubtitleSource.toPersistedValue]）。
      source = SubtitleSource.external(
        externalPath: persisted,
        label: p.basename(persisted),
      );
    } else {
      return;
    }
    if (!mounted || _controller != controller) return;
    final List<AudioCue> cues =
        await loadCuesForSource(source, videoPath, widget.bookUid);
    if (!mounted || _controller != controller) return;
    if (cues.isEmpty) return;
    controller.setSecondaryCues(cues);
  }

  /// 视频内嵌字体加载（对齐 mpv/libass 的 attachment 字体）：本地视频 + 开「尊重 .ass
  /// 自带样式」时，抽 MKV 内嵌字体附件注册进 Flutter 引擎，字幕 overlay 的
  /// `_styleForGrapheme` 用 `cue.fontName` 即可命中真实字体（无需改 overlay）。加载完成若
  /// 有 family 注册成功，[_rebuild] 触发 overlay 重渲染以套用新字体。
  ///
  /// 门控 [AppModel.videoRespectAssStyle]：关时字幕走 App 统一样式、不认 ASS 字体名，抽字体
  /// 无意义（省一次 ffmpeg）。降级链在 [SubtitleEmbeddedFontLoader] 内：远端/无本地文件/无
  /// ffmpeg/无附件/解析失败一律返回空集，overlay 继续走 [_kSubtitleCjkFallback]，不崩不阻塞
  /// 播放（fire-and-forget）。
  Future<void> _maybeLoadEmbeddedSubtitleFonts(String videoPath) async {
    if (_isRemote) return;
    if (!appModel.videoRespectAssStyle) return;
    final Set<String> families =
        await _embeddedFontLoader.loadForVideo(videoPath);
    if (!mounted || families.isEmpty) return;
    // 字体已进引擎；重建让字幕 overlay 按 cue.fontName 重解析并命中新注册的 family。
    _rebuild(() {});
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
    // TODO-1236：经 AppPaths 解析（跟随桌面自定义数据根 → `<dataRoot>/documents/`
    // `video_subtitles`；默认根仍是平台 Documents），与 TODO-1226 迁移白名单一致。
    final String saveDir = (await AppPaths.videoSubtitlesDirectory()).path;
    if (!context.mounted) return;
    // 语言记忆按系列（番名）粒度：seriesKey = query 归一（小写 + trim），与
    // PreferencesRepository 的 map key 约定一致。打开时读上次语言、选中时写回。
    final String seriesKey = query.trim().toLowerCase();
    // 该系列没有记忆时兜底设置页的默认字幕语言（三个 Jimaku 界面同一兜底）。
    final String? preferredLanguage =
        appModel.jimakuPreferredLanguages[seriesKey] ??
            appModel.jimakuDefaultLanguageOrNull;
    final String? downloaded = await showDialog<String>(
      context: context,
      builder: (_) => JimakuSubtitleDialog(
        initialQuery: query,
        initialApiKey: appModel.jimakuApiKey,
        onApiKeyChanged: (String key) => appModel.setJimakuApiKey(key),
        saveDirectory: saveDir,
        httpClientFactory: appModel.createDownloadHttpClient,
        initialPreferredLanguage: preferredLanguage,
        onPreferredLanguageChanged: (String lang) =>
            appModel.setJimakuPreferredLanguage(seriesKey, lang),
      ),
    );
    // Jimaku 对话框内含联网搜索/下载，会夺焦；关闭后把焦点还给 Video。
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
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
    // BUG-939：Jimaku 下载的新字幕档不在旧枚举结果里 → 失效缓存，下次打开字幕分类重枚举。
    if (applied) {
      _invalidateSubtitleMenuSourcesCache();
    }
    // 仅在字幕真被应用（解析出 cue）时报「已下载并应用」；cue 为空时
    // _selectSubtitleSource 已弹失败提示，不再叠加误导性的成功提示。
    if (applied && mounted) {
      _showOsd(t.video_jimaku_downloaded);
    }
  }

  /// 弹系统文件选择器挑一个字幕文件（srt/ass/ssa/vtt）→ 经 [_importExternalSubtitle]
  /// 落盘并应用。FilePicker 会夺走视频键盘焦点，关闭后 [_focusOwnership] 归还。
  Future<void> _pickAndImportSubtitle(VideoPlayerController controller) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
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
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
    final String? path = result?.files.single.path;
    if (path == null) return;
    if (subtitleFormatForPath(path) == null) {
      _showOsd(t.video_subtitle_import_unsupported);
      return;
    }
    // 复制到 video_subtitles/ 持久目录再应用：远端选择按文件路径持久化（见
    // _applyRemoteSubtitle），原始 pick 可能是 SAF 临时缓存，退出后失效；复制到 app
    // 拥有的目录才能在重进时按路径重放。复制失败则退回原路径（尽力而为，不阻断应用）。
    String applyPath = path;
    try {
      final Directory destDir = await AppPaths.videoSubtitlesDirectory();
      await destDir.create(recursive: true);
      final String dest = p.join(destDir.path, p.basename(path));
      if (!p.equals(path, dest)) {
        await File(path).copy(dest);
      }
      applyPath = dest;
    } catch (_) {
      // 保留原始 pick 路径应用；本次可播，只是可能不持久。
    }
    await _applyRemoteSubtitle(controller, applyPath);
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
    final String source = selectedSource ?? path;
    _rebuild(() => _currentSubtitleSource = source);
    // 持久化用户为该远端集的字幕选择（根因修复：远端字幕原本只进内存、退出即丢）。
    // 本地已下载/导入的字幕文件路径（Jimaku 落 video_subtitles/、导入亦复制到该目录）可
    // 在重进时按路径重放；embedded:<n> 等非文件源退出后落回 host 默认，不阻塞当前应用。
    // 合集连播下按当前成员 id 记忆字幕选择（键 = (成员 id, 0)），与 _loadRemoteEpisode 读取
    // 端同源；单视频/host-playlist 沿用 (widget.bookUid, _currentEpisode)。
    final (String subUid, int subEp) =
        _remotePositionKeyForIndex(_currentEpisode);
    unawaited(
      appModel.setRemoteSubtitleSource(subUid, subEp, source),
    );
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
    // TODO-1307：用户显式关字幕后，字幕后置解析完成也不再自动抢占应用（尊重用户选择，
    // 见 [_resolveDeferredYoutubeCaptions]）；仍回填 cue 使「YouTube 字幕」行可再手选。
    _remoteSubtitleUserDismissed = true;
    _rebuild(() => _currentSubtitleSource = null);
    // 持久化「显式关闭」（off: 哨兵）：重进 _loadRemoteEpisode 时保持关闭，不再自动加载
    // host 默认字幕（否则用户每次进影片都要重新关一遍）。
    final (String subUid, int subEp) =
        _remotePositionKeyForIndex(_currentEpisode);
    unawaited(
      appModel.setRemoteSubtitleSource(
        subUid,
        subEp,
        SubtitleSource.offSentinel,
      ),
    );
  }

  /// TODO-1302 track-list-first：当前有效远端客户端已解析好的 YouTube 字幕轨列表
  /// （[UrlStreamVideoClient.youtubeCaptionTracks]，元数据，无 cue 正文）。字幕轨选择器据此每
  /// 轨渲染一行；派生自真实客户端，无独立可失步状态。非 YouTube 客户端返回空表。
  List<YoutubeCaptionTrack> get _youtubeCaptionTracks {
    final RemoteVideoClient? client = _effectiveRemoteClient;
    return client is UrlStreamVideoClient
        ? client.youtubeCaptionTracks
        : const <YoutubeCaptionTrack>[];
  }

  /// TODO-1302 track-list-first：字幕轨选择器行的显示名。
  ///
  /// BUG-1289：语言名走 [youtubeCaptionLanguageLabel]（而非直接读
  /// [YoutubeCaptionTrack.languageName]），并**显式标注自动生成轨**。旧实现依赖两条在
  /// androidVr 路径上不成立的假设，两条都会让用户「选不出哪条是哪条」：
  ///  1. 「YouTube 会给本地化名」——实测 androidVr player response 的 `languageName` 恒 null，
  ///     退化成裸语言码，列表显示 `en` / `es-419` 这种机器码；
  ///  2. 「ASR 轨自带 (auto-generated) 标注、人工/ASR 由排序区分」——名字既然是 null 兜底出来的
  ///     语言码，同一语言的人工轨与 ASR 轨标签**完全相同**（两行都叫 `en`），排序上下相邻却
  ///     无任何可见差异，用户无从分辨。
  /// 故标签改由 [youtubeCaptionTrackLabel] 合成（可读语言名 + ASR 标注 + 翻译标注），
  /// 本方法只负责注入 i18n 文案——合成规则连同「不同轨标签必不同」的不变式一起留在数据层
  /// 纯函数里可离线单测。
  String _youtubeCaptionTrackLabel(YoutubeCaptionTrack track) =>
      youtubeCaptionTrackLabel(
        track,
        translated: (String lang) =>
            t.video_subtitle_youtube_translated(lang: lang),
        autoGenerated: (String lang) =>
            t.video_subtitle_youtube_auto_generated(lang: lang),
      );

  /// TODO-1302 track-list-first 的 on-select：懒下载 [track] 的 cue（缓存命中直接用）→ 灌
  /// overlay + 关 libmpv 画面字幕 + 登记 [YoutubeCaptionTrack.trackKey] 为当前源。用户从菜单点
  /// 某轨、或 [_resolveDeferredYoutubeCaptionTracks] 自动应用最佳轨（[loadSeq] 非空校验仍是当前
  /// load，防后置自动应用串到已切走的集）时调。best-effort：cue 空时手选提示无字幕、不改当前源。
  Future<void> _applyYoutubeCaptionTrack(
    VideoPlayerController controller,
    YoutubeCaptionTrack track, {
    int? loadSeq,
  }) async {
    final RemoteVideoClient? client = _effectiveRemoteClient;
    if (client is! UrlStreamVideoClient) return;
    List<AudioCue> cues = client.cachedCaptionCues(track.trackKey);
    if (cues.isEmpty) {
      if (mounted) _rebuild(() => _subtitleMenuLoading = true);
      cues = await resolveYoutubeCaptionCues(track,
          bookKey: 'yt:${widget.bookUid}');
      if (!mounted) return;
      if (loadSeq != null && loadSeq != _episodeLoadSeq) {
        _rebuild(() => _subtitleMenuLoading = false);
        return;
      }
      if (cues.isNotEmpty) client.cacheCaptionCues(track.trackKey, cues);
      _rebuild(() => _subtitleMenuLoading = false);
    }
    if (cues.isEmpty) {
      // 手选到空轨（机翻失败 / 该轨无文字）：提示；自动应用（loadSeq!=null）静默不打扰。
      if (loadSeq == null) _showOsd(t.video_subtitle_youtube_empty);
      return;
    }
    controller.setCues(cues);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    if (!mounted) return;
    _rebuild(() => _currentSubtitleSource = track.trackKey);
    if (loadSeq == null) {
      _showOsd(
        t.video_subtitle_switched(label: _youtubeCaptionTrackLabel(track)),
      );
    }
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
    // TODO-1236：经 AppPaths 解析（跟随桌面自定义数据根），与迁移白名单 `video_subtitles`
    // 一致；导入字幕副本落数据根而非平台 Documents。
    final Directory destDir = await AppPaths.videoSubtitlesDirectory();
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
    // BUG-939：导入了新外挂字幕档，它不在旧枚举结果里 → 失效缓存，下次打开「字幕」分类
    // 重新枚举把它列进字幕轨列表。
    _invalidateSubtitleMenuSourcesCache();
    debugPrint(
      '[hibiki-drop] [video-playback] externalSubtitle imported '
      'path=$dest',
    );
  }

  /// 在字幕源视图里展示非阻塞加载状态（BUG-104：大容器内嵌字幕 demux 可达数十秒）。
  /// TODO-1351：字幕源已收进设置面板「字幕」分类，加载态确保设置面板开在该分类可见。
  void _showSubtitleLoadingOverlay() {
    if (_subtitleLoadingShown || !mounted) return;
    _rebuild(() => _subtitleLoadingShown = true);
    if (_videoSidePanel.value?.kind != _VideoSidePanelKind.settings) {
      _showPlayerSettings(initialCategory: 'subtitle');
    }
  }

  /// 关闭字幕抽取加载状态。配对 [_showSubtitleLoadingOverlay]，幂等，并在下一帧把
  /// 键盘焦点还给视频，避免文件选择器/外部对话框返回后快捷键悬空。
  void _hideSubtitleLoadingOverlay() {
    if (!_subtitleLoadingShown) return;
    if (mounted) {
      _rebuild(() => _subtitleLoadingShown = false);
      _focusOwnership.reclaimAfterFrame(FocusReclaimCause.overlayClosed);
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

  /// 关闭字幕：清空 cue overlay + 关 libmpv 字幕轨 + 持久化「显式关闭」哨兵。
  ///
  /// TODO-818：持久化 [SubtitleSource.offSentinel] 而非 `null`。`null` 与「从未选过/
  /// 无偏好」撞，重启会被恢复路径当「无偏好→自动选默认」处理，导致用户明明关了字幕
  /// 重启又自动选上。哨兵让恢复路径（[_loadSingle]/[_loadEpisode]）识别为「显式关闭」
  /// 并短路掉 sidecar 探测与内嵌轨自动抽取两个自动重选向量。
  Future<void> _selectSubtitleOff(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    // BUG-081: 关字幕也要清掉单视频已落库的 cue，否则重进时 `loadCues` 命中旧
    // cue 又把字幕显示回来。cue 与源指针原子写入（事务）。播放列表不入 cue，只
    // 写源指针。
    if (_episodes.isEmpty) {
      await widget.repo.saveSubtitleSelection(
        bookUid: widget.bookUid,
        subtitleSource: SubtitleSource.offSentinel,
        cues: const <AudioCue>[],
      );
    } else {
      await widget.repo
          .updateSubtitleSource(widget.bookUid, SubtitleSource.offSentinel);
    }
    if (!mounted) return;
    _rebuild(() => _currentSubtitleSource = SubtitleSource.offSentinel);
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
    // BUG-877：面板宽度可自定义并持久化。未自定义（存值 0）时按屏宽自适应；用户拖拽左边缘
    // 把手改宽后存实际像素、跨开关 / 跨重启记住。存值 / 拖拽值都再 clamp 到 [minWidth,
    // maxWidth]（防跨设备屏宽差异下越界，且面板不至于宽到吞掉整块画面）。
    final double autoWidth = (screenWidth * 0.28).clamp(240.0, 420.0);
    const double minPanelWidth = 240.0;
    final double maxPanelWidth =
        (screenWidth * 0.6).clamp(minPanelWidth, 720.0);
    final double storedWidth = appModel.videoSubtitleListWidth;
    final double panelWidth =
        (_subtitleListWidthDrag ?? (storedWidth > 0 ? storedWidth : autoWidth))
            .clamp(minPanelWidth, maxPanelWidth);
    return AnimatedSize(
      // eink 下归零（墨水屏残影，UI 巡检 PR-4），与剧集侧栏同款。
      duration: einkSafeDuration(context, const Duration(milliseconds: 200)),
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
                        // BUG-877：面板叠一层左边缘拖拽把手（[_subtitleListResizeHandle]）
                        // 改宽度并持久化；Stack 让把手浮在面板左边缘、不占面板内容宽度。
                        child: Stack(
                          children: <Widget>[
                            VideoSubtitleJumpPanel(
                              key: const ValueKey<String>(
                                  'video-subtitle-jump-panel'),
                              controller: controller,
                              onTapCue: _handleSubtitleJumpTap,
                              onLookupCue: _handleSubtitleListLookup,
                              // BUG-874：把命中句柄绑给面板，查词浮层 dismiss barrier 据此把
                              // 「点列表下一个词」切换查词而非吞成关闭浮层。
                              hitTester: _subtitleListHitTester,
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
                              // BUG-878：行字号档位初值从 Drift preferences 读，A+/A- 或
                              // Ctrl+滚轮调节时落盘，跨开关 / 跨重启记住。
                              initialFontScaleIndex:
                                  appModel.videoSubtitleListFontScaleIndex,
                              onFontScaleIndexChanged: (int value) => unawaited(
                                appModel
                                    .setVideoSubtitleListFontScaleIndex(value),
                              ),
                              // BUG-879：列表行文本 Shift-悬停查词门控，与画面字幕同源。
                              hoverAutoLookupEnabled:
                                  ReaderHibikiSource.instance.hoverAutoLookup,
                              onClose: _closeSubtitleJumpList,
                              colorScheme: cs,
                              title: t.video_subtitle_list,
                              emptyHint: t.video_subtitle_list_empty,
                              loadingHint: t.video_subtitle_list_loading,
                              fontSize: 14 * _videoUiScale,
                              width: panelWidth,
                            ),
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              child: _subtitleListResizeHandle(
                                currentWidth: panelWidth,
                                minWidth: minPanelWidth,
                                maxWidth: maxPanelWidth,
                                colorScheme: cs,
                              ),
                            ),
                          ],
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

  /// BUG-877：字幕列表面板左边缘拖拽把手。面板在屏幕右侧，把左边缘向左（`delta.dx < 0`）
  /// 拖即变宽，故 `base - delta.dx`；松手把最终宽度落 Drift preferences；双击复位为自适应
  /// （存 0 = 跟随屏宽）。8px 命中宽度 + resizeLeftRight 光标，中间画一条细可视竖条提示可拖。
  Widget _subtitleListResizeHandle({
    required double currentWidth,
    required double minWidth,
    required double maxWidth,
    required ColorScheme colorScheme,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      // BUG-930：进 / 出把手时翻 [_pointerOverSubtitleResizeHandle]，让侧栏
      // [_forceRevealOsCursorForPanel] 的每帧原生「强设 basic」在把手上让位，
      // 使框架声明的 resizeLeftRight 光标不被盖掉（enter 早于同帧 parent onHover 处理，
      // 稳态下光标即为 resize；退出把手复位、面板其余区域仍走 basic 唤回缓解）。
      onEnter: (PointerEnterEvent _) => _pointerOverSubtitleResizeHandle = true,
      onExit: (PointerExitEvent _) => _pointerOverSubtitleResizeHandle = false,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          final double base = _subtitleListWidthDrag ?? currentWidth;
          final double next =
              (base - details.delta.dx).clamp(minWidth, maxWidth);
          _rebuild(() => _subtitleListWidthDrag = next);
        },
        onHorizontalDragEnd: (DragEndDetails details) {
          final double? dragged = _subtitleListWidthDrag;
          if (dragged != null) {
            unawaited(appModel.setVideoSubtitleListWidth(dragged));
          }
          _rebuild(() => _subtitleListWidthDrag = null);
        },
        onDoubleTap: () {
          unawaited(appModel.setVideoSubtitleListWidth(0));
          _rebuild(() => _subtitleListWidthDrag = null);
        },
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 2,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// asbplayer 式「字幕偏移对齐」快捷键胶水（用户请求，默认 Ctrl+Shift+←/→）：把
  /// **上一句 / 下一句**字幕的起点整体平移到当前播放点，一键把整轨粗对齐到当前台词时刻
  /// （再配合 z/x 微调）。与 z/x 的固定步进平移不同——这里按目标 cue 求**绝对**偏移。
  ///
  /// 决策全部集中在纯函数 [VideoPlayerController.snapSubtitleDelayMs]（选相邻 cue + 求
  /// 新 delayMs，可单测）；本方法只做胶水：取 controller 实时 cues/positionMs 与当前
  /// `_delayMs`，拿到新延迟后走既有权威写穿 [_setDelayMs]（clamp + 落盘 + OSD + 即时重算）。
  /// 无 controller / 无 cue / 位置未就绪 / 已是首末句无相邻 cue 时 no-op（不弹窗、不改延迟）。
  void _snapSubtitleDelayToCue({required bool next}) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final int? newDelayMs = VideoPlayerController.snapSubtitleDelayMs(
      cues: controller.cues,
      positionMs: controller.positionMs,
      currentDelayMs: _delayMs,
      next: next,
    );
    if (newDelayMs == null) return;
    unawaited(_setDelayMs(newDelayMs));
  }

  /// TODO-701 阶段1：一键字幕自动对轴。抽当前视频的逐帧音频能量包络（[extractAudioEnergyEnvelope]
  /// 经 ffmpeg 抽象），与字幕 cue 时间轴栅格化后做互相关（[bestOffsetMsByCrossCorrelation]）
  /// 求**整体平移** offset，再走现有 [_setDelayMs] 写穿 `delayMs` 落盘（零新持久化）。
  ///
  /// **只整体平移、不重排 cue、不解帧率漂移**——等价于自动算出「手动延迟」该填多少。
  /// 输入不足（无 cue/无视频路径/无音频包络）或置信度低于阈值时**不**改动延迟，仅弹
  /// 低置信 OSD（避免乱平移）。移动端 [KitFfmpegBackend] 拿不到逐帧 RMS 时包络为空，
  /// 走 noData 分支安全降级（[extractAudioEnergyEnvelope] 已 debugPrint 诊断）。
  ///
  /// TODO-1206：返回本次实际写穿的整体平移 offset（毫秒），供快速设置面板把滑条/数值
  /// 输入框/波形预览同步刷新到自动算出的延迟；低置信 / noData / 输入不足等**不改延迟**
  /// 的分支返回 null（面板据此保持原值不动）。
  Future<int?> _autoAlignSubtitle() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    final List<AudioCue> cues = controller.cues;
    final String? videoPath = controller.videoPath;
    final int? durationMs = controller.durationMs;
    if (cues.isEmpty || videoPath == null || videoPath.isEmpty) {
      _showOsd(t.video_subtitle_auto_align_low_confidence);
      return null;
    }
    // 时长缺失时用最后一条 cue 的结束时间兜底（cue 升序由 setCues 保证），仍能栅格化。
    final int rawDurationMs =
        (durationMs != null && durationMs > 0) ? durationMs : cues.last.endMs;
    // 性能截断（TODO-413）：cue 栅格化上界与 [extractAudioEnergyEnvelope] 的 ffmpeg `-t`
    // 取同一上界（前 N 分钟），两侧栅格都从 t=0 同 binMs 起、截到同一上界，相位一致不偏；
    // 超界的 cue 在 [buildCueActivityEnvelope] 内按 length 自然 clamp/跳过（不进活动序列）。
    final int effectiveDurationMs =
        math.min(rawDurationMs, kSubtitleAutoAlignProbeLimitMs);

    _showOsd(
      t.video_subtitle_auto_align_running,
      icon: Icons.auto_fix_high,
    );

    final List<double> rawRms = await extractAudioEnergyEnvelope(
      videoPath: videoPath,
      windowMs: kSubtitleAutoAlignBinMs,
      audioStreamIndex: controller.currentAudioStreamIndex,
      audioStreamCount: controller.realAudioStreamCount,
      limitMs: kSubtitleAutoAlignProbeLimitMs,
    );
    if (!mounted) return null;

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
        if (!mounted) return null;
        _showOsd(
          t.video_subtitle_auto_align_done(ms: result.offsetMs),
          icon: Icons.auto_fix_high,
        );
        // TODO-1206：回传实际平移量，让面板把滑条/数值/波形同步到新延迟。
        return result.offsetMs;
      case SubtitleAutoAlignStatus.lowConfidence:
      case SubtitleAutoAlignStatus.noData:
        _showOsd(t.video_subtitle_auto_align_low_confidence);
        return null;
    }
  }

  /// TODO-1051 阶段B：为字幕对轴波形面板抽当前视频的逐帧音频能量包络（原始 dB 序列）。
  ///
  /// 复用与 [_autoAlignSubtitle] 同一探测入口 [extractAudioEnergyEnvelope]（同音轨、同前
  /// N 分钟截断），返回原始逐帧包络交给面板降采样成 0..1 波形桶（降采样在面板层随宽度算，
  /// 不在此处、不在 paint 里跑 ffmpeg）。无 controller / 无视频路径 / 移动端拿不到逐帧行时
  /// 返回空列表，面板据此退化成纯 stepper（不崩不空白）。
  Future<List<double>> _loadSubtitleWaveformEnvelope() async {
    final VideoPlayerController? controller = _controller;
    final String? videoPath = controller?.videoPath;
    if (controller == null || videoPath == null || videoPath.isEmpty) {
      return const <double>[];
    }
    // TODO-1244：按「视频路径 + 当前音轨」缓存已抽出的波形包络。同一视频/音轨重复打开
    // 快速设置面板或波形对轴视图时直接复用，不再重跑 ffmpeg（抽整轨对大 REMUX 要数十秒）。
    // 切视频或切音轨时 key 变化 → miss → 重抽（不显示旧音频波形），只缓存非空结果。
    final String cacheKey = '$videoPath|${controller.currentAudioStreamIndex}';
    return _subtitleWaveformCache.resolve(
      cacheKey,
      // TODO-1244：波形显示走更细的 [kSubtitleWaveformWindowMs]（20ms=50 帧/秒），密度接近
      // 成熟波形工具、句间静音可辨；自动对轴仍用 100ms 采样，两者互不影响（独立探测/缓存）。
      () => extractAudioEnergyEnvelope(
        videoPath: videoPath,
        windowMs: kSubtitleWaveformWindowMs,
        audioStreamIndex: controller.currentAudioStreamIndex,
        audioStreamCount: controller.realAudioStreamCount,
        limitMs: kSubtitleAutoAlignProbeLimitMs,
      ),
    );
  }

  /// 字幕对轴/匹配快捷键（用户请求，默认 Shift+A）：从键盘一键弹波形对轴放大视图，
  /// 免去「控制栏 tune → 快速设置面板 → 字幕调轴区 → 点入口」四级操作。逻辑与
  /// [SubtitleWaveformAlignPanel] 的入口点击（懒抽波形 → 非空才弹 [SubtitleWaveformZoomView]）
  /// 完全一致、零第二套状态：调轴仍经 [_setDelayMs] 写回权威 `_delayMs`，自动对轴复用
  /// [_autoAlignSubtitle]，逐句试听 / 播放头 / 弹窗内快捷键与快速设置面板路径同源。
  ///
  /// 降级路径与面板入口同款：无 controller / 无字幕 cue / 无本地视频路径 / 抽波形返回空
  /// （移动端拿不到逐帧行 / ffmpeg 不可用）时不弹窗，改弹 OSD 提示不可用（不崩不空白）。
  Future<void> _openSubtitleWaveformAlign() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final List<AudioCue> cues = controller.cues;
    final String? videoPath = controller.videoPath;
    if (cues.isEmpty || videoPath == null || videoPath.isEmpty) {
      _showOsd(t.video_subtitle_waveform_unavailable);
      return;
    }
    final List<double> env = await _loadSubtitleWaveformEnvelope();
    if (!mounted) return;
    if (env.isEmpty) {
      _showOsd(t.video_subtitle_waveform_unavailable);
      return;
    }
    // 波形时间窗上界：与 extractAudioEnergyEnvelope 探测上界同源（前 N 分钟截断），
    // 与 _SubtitleWaveformAlignPanelState._windowEndMs 同一算式，保证键盘直达路径与
    // 面板入口路径画出的时间轴一致。
    final int durationMs = controller.durationMs ?? 0;
    final int windowEndMs =
        (durationMs > 0 && durationMs < kSubtitleAutoAlignProbeLimitMs)
            ? durationMs
            : kSubtitleAutoAlignProbeLimitMs;
    final bool canAutoAlign = cues.isNotEmpty && videoPath.isNotEmpty;
    if (!context.mounted) return;
    // guardOverlay：对轴弹窗（root navigator）会夺走视频键盘焦点，任何退出路径
    // （Esc / 点外部 / 抛异常）都必须归还——此前这里漏了归还，关掉弹窗后视频快捷键
    // 直到下次点画面才恢复，与同文件 Jimaku 对话框 / FilePicker 的既有范式不一致。
    await _focusOwnership.guardOverlay(
      () => showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (BuildContext _) => SubtitleWaveformZoomView(
          rawEnvelope: env,
          cues: cues,
          windowEndMs: windowEndMs,
          initialDelayMs: _delayMs,
          onCommitDelay: _setDelayMs,
          onAutoAlign: canAutoAlign ? _autoAlignSubtitle : null,
          onPlayCue: (int startMs) async {
            await controller.seekMs(startMs);
            await controller.play();
          },
          isPlaying: () => controller.isPlaying,
          onTogglePlayPause: () async {
            await controller.togglePlayPause();
          },
          // 弹窗内复用视频页 registry 驱动的整表（尊重重映射）；排除会破坏弹窗自身的动作
          // （Escape 关弹窗 / 全屏 / 打开字幕列表 / 沉浸锁 / 再次打开对轴弹窗——避免递归叠栈）。
          keyboardShortcuts: buildVideoPlayerShortcutsFromRegistry(
            appModel.shortcutRegistry,
            _buildVideoShortcutActions(controller),
            exclude: const <ShortcutAction>{
              ShortcutAction.videoEscape,
              ShortcutAction.videoToggleFullscreen,
              ShortcutAction.videoToggleSubtitleList,
              ShortcutAction.videoToggleImmersiveLock,
              ShortcutAction.videoOpenSubtitleAlign,
            },
          ),
          onSeek: (int ms) async {
            await controller.seekMs(ms);
          },
          positionListenable: controller,
          // positionMs 可空（未就绪）；与快速设置面板路径同用 -1 哨兵 = 不画播放头。
          currentPositionMs: () => controller.positionMs ?? -1,
        ),
      ),
    );
  }
}

/// 字幕延迟 +/- 快捷键（用户请求，默认 z/x）每次整体平移的步进（毫秒）。取 100ms
/// = mpv 字幕延迟键 `z`/`x` 的 0.1s 惯例；与快速设置面板 ±50 / ±1000 步进正交（都经
/// [_setDelayMs] 写穿同一权威 `_delayMs`）。
const int _kSubtitleDelayNudgeMs = 100;
