// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch4).
part of '../video_hibiki_page.dart';

/// episode (剧集 push-aside 侧栏 + 自动连播倒计时) domain methods extracted via
/// part-of (TODO-590 batch4); shared private scope. Behaviour-preserving: bodies
/// are verbatim copies — this domain references no `setState(` (so no `_rebuild(`
/// forwarding). UI 巡检 PR-4 后 [_buildAutoAdvanceOverlay] 引用了一个 host
/// `static`（`_VideoHibikiPageState._videoBottomChromeBaseline`，倒计时卡几何
/// 推导），按 batch3 惯例全限定。`kAutoPlayNextCountdownSeconds` is a
/// top-level const in `video_episode_start_policy.dart` (already imported by the
/// main shell), not a host-class static, so it stays a bare reference. The
/// `_episodeListVisible` / `_autoAdvanceCountdownNotifier` notifiers, their
/// timers/fields, and the `_episodes` / `_currentEpisode` playlist state stay in
/// the main shell; the build-subtree parent `_videoWithSubtitlePanel` (subtitle
/// domain) keeps calling the extracted `_episodeSidePanel` through shared private
/// scope.
extension _VideoEpisode on _VideoHibikiPageState {
  void _handlePlaybackCompleted() {
    if (!mounted) return;
    // 有下一集才连播（单集 / 末集 / 越界不推进，停在本集结束）。
    final int cur = _currentEpisode;
    final int? nextEpisode =
        (_episodes.length > 1 && cur >= 0 && cur < _episodes.length - 1)
            ? cur + 1
            : null;
    // TODO-639　三门控(自动连播开关/有下一集/未在换集)任一不满足都停在本集结束。
    if (!shouldAutoPlayNextOnCompletion(
      autoPlayNextEnabled: appModel.videoAutoPlayNext,
      hasNextEpisode: nextEpisode != null,
      alreadyAdvancing: _autoAdvanceInFlight,
    )) {
      return;
    }
    // 不直接进下一集，先弹一个可取消的倒计时 OSD(「N 秒后播放下一集 · 取消」)。
    // 倒计时归零→进下一集；用户点取消→停在本集([_cancelAutoAdvanceCountdown])。
    _startAutoAdvanceCountdown(nextEpisode!);
  }

  /// 启动自动连播倒计时(TODO-639)。每秒 -1，归零调 [_runAutoAdvance] 进下一集。
  void _startAutoAdvanceCountdown(int targetEpisode) {
    _autoAdvanceCountdownTimer?.cancel();
    _autoAdvanceCountdownTarget = targetEpisode;
    _autoAdvanceCountdownNotifier.value = kAutoPlayNextCountdownSeconds;
    _autoAdvanceCountdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) {
          _cancelAutoAdvanceCountdown();
          return;
        }
        final int remaining = (_autoAdvanceCountdownNotifier.value ?? 0) - 1;
        if (remaining <= 0) {
          final int? target = _autoAdvanceCountdownTarget;
          _cancelAutoAdvanceCountdown();
          if (target != null) _runAutoAdvance(target);
        } else {
          _autoAdvanceCountdownNotifier.value = remaining;
        }
      },
    );
  }

  /// 取消 / 清掉自动连播倒计时(用户点「取消」、倒计时归零推进前、或页面销毁时)。
  void _cancelAutoAdvanceCountdown() {
    _autoAdvanceCountdownTimer?.cancel();
    _autoAdvanceCountdownTimer = null;
    _autoAdvanceCountdownTarget = null;
    _autoAdvanceCountdownNotifier.value = null;
  }

  /// 真正进下一集(倒计时归零后调用)。重入由 [_autoAdvanceInFlight] 守。
  void _runAutoAdvance(int targetEpisode) {
    if (_autoAdvanceInFlight) return;
    if (!mounted) return;
    _autoAdvanceInFlight = true;
    unawaited(() async {
      try {
        if (!mounted) return;
        await _switchEpisode(
          targetEpisode,
          intent: EpisodeStartIntent.autoAdvance,
        );
      } catch (e, stack) {
        debugPrint('[VideoHibikiPage] auto-advance failed: $e\n$stack');
      } finally {
        _autoAdvanceInFlight = false;
      }
    }());
  }

  /// 切到第 [index] 集。统一合集 Phase 3：本地每集是独立 VideoBooks 行 → 换集 =
  /// pushReplacement 到该集的单视频页；远端保持原地 host 驱动换流。切前先把当前集
  /// 精确位置补记落库（tick 只整秒写，补这一下避免丢尾部几百 ms），确保回到本集精确续播。
  Future<void> _switchEpisode(
    int index, {
    required EpisodeStartIntent intent,
  }) async {
    if (index < 0 || index >= _episodes.length) return;
    if (index == _currentEpisode) return;
    // TODO-639：任何换集（手动上/下一集、列表选集、倒计时推进）都先清掉挂着的自动连播
    // 倒计时 overlay，避免它停在旧目标上。
    _cancelAutoAdvanceCountdown();

    // TODO-885: 远端播放列表换集——本端无 VideoBooks 行，先把当前集精确位置落按集
    // prefs（_persistRemotePosition 用 _currentEpisode），再按 episodeIndex 向 host
    // 重新建流（_loadRemoteEpisode 内 ++_episodeLoadSeq 取代慢路径旧集）。
    if (_isRemote) {
      final int? curPos = _controller?.positionMs;
      if (curPos != null) {
        await _persistRemotePosition(widget.bookUid, curPos);
      }
      _watchTracker?.onEpisodeChanged();
      await _loadRemoteEpisode(index, startIntent: intent);
      return;
    }

    // 统一合集 Phase 3：本地每集是独立 VideoBooks 行 → 换集 = pushReplacement 到兄弟集
    // 的单视频页（同 playlistCollectionId 让新页仍带剧集面板/上下集/连播；widget.bookUid
    // 恒为当前集，整套单视频 load/cue/收藏/持久化机制原样复用）。先落当前集精确位置
    // （tick 只整秒写，补这一下避免丢尾部几百 ms）；新页 _init 从该集行 lastPositionMs 续播。
    final String? targetUid = _episodes[index].bookUid;
    if (targetUid == null) return;
    // BUG-839：全屏播放时 app 全屏路由压在剧集页之上（fullscreen.part.dart 推到 root
    // navigator）。若不先退，下面的 pushReplacement 会替换掉栈顶的**全屏路由**、把本集页
    // 漏在栈里 → 每连播一集就残留一层、ESC 需逐层退。故换集前先经既有汇聚点退全屏路由，
    // 让剧集页回到栈顶，pushReplacement 才正确替换本集页（栈恒平、ESC 一次退出）；并记
    // wasFullscreen，给新页 initialFullscreen 让其就绪后重进全屏，保持连播全屏沉浸。
    final BuildContext? fsCtx = _videoControlsContext;
    final bool wasFullscreen =
        fsCtx != null && fsCtx.mounted && isFullscreen(fsCtx);
    if (fsCtx != null && wasFullscreen) {
      await _exitVideoFullscreen(fsCtx);
      if (!context.mounted) return;
    }
    // 捕获 NavigatorState（在 await 前），避免跨 async gap 用 context。
    final NavigatorState navigator = Navigator.of(context);
    final int? curPos = _controller?.positionMs;
    if (curPos != null) {
      await _persistPosition(widget.bookUid, curPos);
    }
    // BUG-823：本地换集用 pushReplacement，Flutter 语义下旧路由要等新页入场过渡动画
    // 结束才被移除并 dispose（旧页 dispose 里才 _controller?.dispose() 停播）。过渡窗口
    // 内旧页 controller 仍在放音，而新页 _init 已新建 player 并 autoPlay 起播 → 两条音轨
    // 短暂同响（观感：切集时上一个视频还在播）。换集前先 pause 旧播放器，音轨即刻静音，
    // 不再依赖延迟 dispose。远端换集复用同一 player + open() 顶替，天然不双开，故只本地分支处理。
    await _controller?.pause();
    if (!context.mounted) return;
    await navigator.pushReplacement<void, void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoHibikiPage.neutralized(
          bookUid: targetUid,
          repo: widget.repo,
          playlistCollectionId: widget.playlistCollectionId,
          initialFullscreen: wasFullscreen,
        ),
      ),
    );
  }

  /// 剧集列表入口（控制条剧集按钮）。TODO-638：从 `showModalBottomSheet`（底部弹层）
  /// 改成与字幕列表同款的 push-aside 侧栏——翻转 [_toggleEpisodeList]，与其它侧栏视觉
  /// 统一、不挡画面。保留方法名 `_showEpisodeList` 作为控制条入口（_handleVideoControlTap
  /// 的 episodeList 分支调它），呈现改为侧栏 toggle。
  void _showEpisodeList() {
    _toggleEpisodeList();
  }

  /// 翻转剧集列表 push-aside 侧栏可见性（TODO-638；控制条剧集按钮入口）。
  ///
  /// 与字幕列表（[_toggleSubtitleJumpList]）同范式：push-aside 布局
  /// （[_videoWithSubtitlePanel] / [_episodeListVisible]，`Row[Expanded(video), 面板列]`）
  /// 真把画面挤窄到左侧、不浮层遮挡。与其它侧栏互斥：开剧集列表先关字幕列表
  /// （[_subtitleListVisible]）与任何打开的浮层（[_videoSidePanel]）——同一时刻右栏只占
  /// 其一，避免两个 push-aside 侧栏分占右栏。打开时唤醒控制条让用户看到入口。
  void _toggleEpisodeList() {
    final bool next = !_episodeListVisible.value;
    if (next) {
      _clearRailHover();
      // 与浮层互斥：开 push-aside 剧集列表前关掉任何打开的浮层（设置/音轨/倍速等）。
      _hideVideoControlEditOverlay(revealControls: false);
      // 与字幕列表互斥：同一时刻右栏只占其一。
      if (_subtitleListVisible.value) {
        _closeSubtitleJumpList();
      }
      _episodeListVisible.value = true;
      if (_videoSidePanel.value != null) {
        _hideVideoSidePanel();
      }
      _markControlsVisible(false);
      _refocusVideo();
    } else {
      _closeEpisodeList();
    }
  }

  /// 关闭 push-aside 剧集列表（TODO-638）。**三条关闭路径的单一真相源**：面板头部 ×
  /// 按钮（[VideoEpisodePanel.onClose]）、Esc 键、控制条剧集按钮（后两者经
  /// [_toggleEpisodeList] 的关闭分支）都调它，避免「关闭副作用各写一份」分叉。关闭时
  /// 必须：隐藏列表（[_episodeListVisible]）、唤回控制条（[_pokeControlsVisible]）、把焦点
  /// 归还视频（[_refocusVideo]，否则键盘 / 手柄后续失焦）。与字幕列表关闭不同的是剧集
  /// 列表无挖词选择，故不调 [_clearSelectedMiningCues]。
  void _closeEpisodeList() {
    _episodeListVisible.value = false;
    _pokeControlsVisible();
    _refocusVideo();
  }

  /// 点剧集列表里某集：切到该集（复用 [_switchEpisode]）。换集后保持列表常驻（用户可
  /// 连续浏览/切集），与 asbplayer 风格的常驻侧栏一致；当前集高亮由面板按 currentIndex
  /// 自动跟随。
  void _handleEpisodeListTap(int index) {
    _pokeControlsVisible();
    _switchEpisode(index, intent: EpisodeStartIntent.listSelect);
  }

  /// [_videoWithSubtitlePanel] 的剧集列表 push-aside 面板列（TODO-638）。与
  /// [_subtitleJumpSidePanel] 同结构：[AnimatedSize] 让列宽在 0 ↔ panelWidth 平滑伸缩，
  /// 可见时渲染 [VideoEpisodePanel]，隐藏时收成 0（[ClipRect] + [OverflowBox] 保证伸缩
  /// 动画里内容布局稳定）。与字幕列表互斥，故两列同时只有一列非零宽。
  /// 把内部集表示 [_PlaylistEpisodeRef] 解析成面板要的 [VideoEpisodeEntry]。
  ///
  /// 封面来源判断**不在这里手写分支**——统一走 [resolveMediaCoverImage]：本地集给
  /// `coverPath`、互联远端集给 `coverUrl` + 稳定缓存键，解析器按固定优先级出图。
  /// 旧单行 playlist 远端模型（`RemoteVideoEpisode`）不下发封面，两者皆空 →
  /// 返回 null，面板退回纯序号形态。
  List<VideoEpisodeEntry> _episodePanelEntries() {
    final RemoteCoverFetcher? fetcher =
        remoteCoverFetcherFor(widget.remoteClient ?? _resolvedStreamClient);
    return <VideoEpisodeEntry>[
      for (final _PlaylistEpisodeRef e in _episodes)
        VideoEpisodeEntry(
          title: e.title,
          cover: resolveMediaCoverImage(
            kind: MediaKind.video,
            localPath: e.coverPath,
            remoteUrl: e.coverUrl,
            remoteFetcher: fetcher,
            remoteCacheKey: e.coverCacheKey,
          ),
        ),
    ];
  }

  Widget _episodeSidePanel(bool visible) {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double panelWidth = (screenWidth * 0.28).clamp(240.0, 420.0);
    return AnimatedSize(
      // eink 下归零（墨水屏残影，UI 巡检 PR-4）。
      duration: einkSafeDuration(context, const Duration(milliseconds: 200)),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: visible ? panelWidth : 0,
        // BUG-391 r5 根因修：选集列表此前**完全无** cursor-reveal 覆盖（字幕列表有救场层但选集
        // 列表裸奔），整列最外层补一层与字幕侧栏同款声明式 opaque MouseRegion（cursor:basic）——
        // 让 MouseTracker 把侧栏列视为独立 annotation、鼠标进列即进干净 basic 会话，绕开「视频列
        // none 会话残留 + lastSession 去重」竞态（见 _withSidePanelOpaqueCursor）。隐藏时透传
        // SizedBox.shrink（零宽、无 region）。
        child: visible
            ? _withSidePanelOpaqueCursor(
                ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: panelWidth,
                    maxWidth: panelWidth,
                    child: SafeArea(
                      left: false,
                      child: VideoEpisodePanel(
                        key: const ValueKey<String>('video-episode-panel'),
                        episodes: _episodePanelEntries(),
                        currentIndex: _currentEpisode,
                        onTapEpisode: _handleEpisodeListTap,
                        onClose: _closeEpisodeList,
                        colorScheme: cs,
                        title: t.video_episode_list,
                        emptyHint: t.video_episode_list_empty,
                        fontSize: 14 * _videoUiScale,
                        width: panelWidth,
                      ),
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  /// 自动连播倒计时 overlay（TODO-639）。一集播完且自动连播开关开着时，画面右下角弹出
  /// 「N 秒后播放下一集」+「取消」可点按钮；点取消调 [_cancelAutoAdvanceCountdown] 停在
  /// 本集。**不**套 [IgnorePointer]（取消按钮必须可点），与纯展示的 [_buildOsdOverlay]
  /// 区分；非倒计时态渲染零尺寸、不拦截画面手势。窗口 / 全屏复用（挂在同一 controls
  /// Stack，与 OSD 同源）。
  Widget _buildAutoAdvanceOverlay() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    // 倒计时卡底部避让从进度条真实几何推导（UI 巡检 PR-4）：与章节刻度层同源的
    // [videoSeekBarTrackBand]（tickHeight 取轨道高 → band 顶缘 = 轨道上缘），卡片
    // 底缘 = 轨道上缘 + 16×缩放 呼吸间距——此前固定 88 不吃 [_videoUiScale] 也不
    // 吃系统 inset，缩放 >1 或手势导航高 inset 时压进进度条 / 按钮条。
    final ({double bottom, double height}) band = videoSeekBarTrackBand(
      isDesktop: _isDesktopVideoControls,
      buttonBarHeight: _videoButtonBarHeight,
      seekBarButtonGap: _videoSeekBarButtonGap,
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      seekBarTrackHeight: _videoSeekBarTrackHeight,
      bottomChromeBaseline: _VideoHibikiPageState._videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
      tickHeight: _videoSeekBarTrackHeight,
    );
    final double countdownBottom =
        band.bottom + band.height + 16 * _videoUiScale;
    return Positioned(
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(right: 16, bottom: countdownBottom),
          child: ValueListenableBuilder<int?>(
            valueListenable: _autoAdvanceCountdownNotifier,
            builder: (BuildContext _, int? seconds, __) {
              if (seconds == null) return const SizedBox.shrink();
              return Material(
                color: _osdSurfaceColor(cs),
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.playlist_play_outlined,
                        size: 18,
                        color: _osdTextColor(cs),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        t.video_auto_play_next_countdown(seconds: seconds),
                        style: TextStyle(
                          color: _osdTextColor(cs),
                          fontSize: 14,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _cancelAutoAdvanceCountdown,
                        style: TextButton.styleFrom(
                          foregroundColor: _osdTextColor(cs),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: Text(t.video_auto_play_next_cancel),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
