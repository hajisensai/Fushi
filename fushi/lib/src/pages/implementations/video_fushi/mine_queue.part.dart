part of '../video_fushi_page.dart';

/// 在线视频后台制卡 / 看完再制卡的页面侧（见 [VideoOnlineMiningMode]）：在途计数、
/// 待制卡计数、右上角角标、待制卡列表、离开页面时统一写入。
///
/// 字段（[_minesInFlight] / [_stagedMineCount] / [_backgroundMineJobs]）留在主壳——
/// extension 不能带字段；这里只放方法，与其余 part 同一范式。
extension _VideoMineQueuePart on _VideoFushiPageState {
  /// 暂存队列（`<support>/video_mine_queue`）。不在 initState 同步取：support 目录与
  /// 数据库都要等 AppModel 初始化。
  Future<VideoMineQueue> _videoMineQueue() async {
    final Directory support = await AppPaths.supportRootDirectory();
    return VideoMineQueue(
      db: appModel.database,
      root: Directory(p.join(support.path, VideoMineQueue.dirName)),
    );
  }

  /// 重读本视频的待制卡数（待写入 + 写入失败）。best-effort：未初始化的最小宿主
  /// （smoke / widget 测试没有 AppModel）直接当 0。
  Future<void> _refreshStagedMineCount() async {
    try {
      final VideoMineQueue queue = await _videoMineQueue();
      final int count = (await queue.pending(widget.bookUid)).length +
          (await queue.failed(widget.bookUid)).length;
      if (mounted) _stagedMineCount.value = count;
    } catch (_) {}
  }

  /// 一张卡进了待制卡列表（看完再制卡的「成功」）。
  Future<void> _onVideoMineStaged() async {
    await _refreshStagedMineCount();
    if (!mounted) return;
    _showOsd(
      t.video_mine_staged(count: _stagedMineCount.value),
      icon: Icons.playlist_add_check,
    );
  }

  /// 登记一个后台制卡任务：在途计数 +1，结束 -1；异常报 OSD 并记日志（不能静默——
  /// 弹窗早就显示「已加入」了，失败只剩这里能告诉用户）。
  void _trackBackgroundMine(Future<void> job) {
    _minesInFlight.value++;
    late final Future<void> tracked;
    tracked = job.catchError((Object error, StackTrace stack) {
      try {
        ErrorLogService.instance.log('mineVideoCard.background', error, stack);
      } catch (_) {}
      _showOsd(
        t.card_export_failed_detail(reason: '$error'),
        severity: ToastSeverity.error,
      );
    }).whenComplete(() {
      _backgroundMineJobs.remove(tracked);
      if (mounted && _minesInFlight.value > 0) _minesInFlight.value--;
    });
    _backgroundMineJobs.add(tracked);
  }

  /// 把本视频的待制卡全部写入 Anki。
  Future<VideoMineCommitSummary> _commitStagedMines({
    void Function(int done, int total)? onProgress,
  }) async {
    final VideoMineQueue queue = await _videoMineQueue();
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: widget.bookUid,
      repo: repo,
      onProgress: onProgress,
    );
    await _refreshStagedMineCount();
    return summary;
  }

  /// 打开待制卡列表。
  Future<void> _openVideoMineQueue() async {
    final VideoMineQueue queue = await _videoMineQueue();
    if (!context.mounted) return;
    final VideoMineCommitSummary? summary = await showVideoMineQueueDialog(
      context: context,
      queue: queue,
      bookUid: widget.bookUid,
      commit: (void Function(int done, int total) onProgress) =>
          _commitStagedMines(onProgress: onProgress),
      onChanged: () => unawaited(_refreshStagedMineCount()),
    );
    await _refreshStagedMineCount();
    if (summary != null) _showCommitSummary(summary);
  }

  void _showCommitSummary(VideoMineCommitSummary summary) {
    _showOsd(
      t.video_mine_queue_committed(
          ok: summary.succeeded, failed: summary.failed),
      prominent: true,
      severity:
          summary.failed == 0 ? ToastSeverity.success : ToastSeverity.warning,
    );
  }

  /// 离开播放页 = 看完了：等在途的暂存任务收尾，再把本视频的待制卡统一写入。
  ///
  /// 在 [dispose] 里、`ref` 还能用时取好 Anki 后端与队列根，后面的异步链不再碰本页
  /// 状态；结果由 [commitStagedVideoMinesAfterExit] 报（OSD 随页面没了）。什么都没有就
  /// 什么都不做。
  void _flushStagedMinesOnExit() {
    final List<Future<void>> inFlight =
        List<Future<void>>.of(_backgroundMineJobs);
    if (_stagedMineCount.value == 0 && inFlight.isEmpty) return;
    final String bookUid = widget.bookUid;
    final BaseAnkiRepository repo;
    final Future<VideoMineQueue> queueFuture;
    try {
      repo = ref.read(ankiRepositoryProvider);
      queueFuture = _videoMineQueue();
    } catch (_) {
      return;
    }
    commitStagedVideoMinesAfterExit(
      queue: queueFuture,
      bookUid: bookUid,
      repo: repo,
      inFlight: inFlight,
    );
  }

  /// 右上角角标：后台制卡在途时转圈 +「正在制卡 N」，有待制卡时显示「待制卡 N」、
  /// 点开列表。两者都没有时零尺寸。只有角标本身吃点击（外层 [Align] 不命中空白处），
  /// 且不抢键盘焦点——播放页的快捷键焦点归属不因它变化。窗口与全屏共用（监听 notifier，
  /// 与 OSD 同源）。
  Widget _buildMineQueueBadgeOverlay() {
    return Positioned.fill(
      child: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            _minesInFlight,
            _stagedMineCount,
          ]),
          builder: (BuildContext context, _) {
            final int inFlight = _minesInFlight.value;
            final int staged = _stagedMineCount.value;
            if (inFlight == 0 && staged == 0) return const SizedBox.shrink();
            final ColorScheme cs = _videoChromeColorScheme(context);
            final Color textColor = _osdTextColor(cs);
            final String label = staged > 0
                ? t.video_mine_queue_badge(count: staged)
                : t.video_mine_in_progress(count: inFlight);
            return Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(
                  right: 16,
                  top: _videoButtonBarHeight + 8 * _videoUiScale,
                ),
                child: Material(
                  key: const ValueKey<String>('video-mine-queue-badge'),
                  color: _osdSurfaceColor(cs),
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    canRequestFocus: false,
                    onTap: staged > 0
                        ? () => unawaited(_openVideoMineQueue())
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (inFlight > 0)
                            SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: textColor,
                              ),
                            )
                          else
                            Icon(
                              Icons.playlist_add_check,
                              size: 16,
                              color: textColor,
                            ),
                          const SizedBox(width: 6),
                          Text(label, style: TextStyle(color: textColor)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
