part of '../video_fushi_page.dart';

/// 视频观看统计侧栏 + 手动计时开关（2026-11-07 所有者拍板「统计逻辑对齐小说，并且也要
/// 有和小说一样的统计界面侧边栏」）。
///
/// - 侧栏内容就是小说那份 [ReaderStatisticsSheet]（`media: video`），挂进视频侧板外壳
///   （[_VideoSidePanelKind.statistics]，切换条成员）。侧栏开着不停表——同小说统计
///   侧栏，见 [videoStudyClockLocallyCovered]。
/// - 计时开关只翻 [_studyClockGate] 的手动暂停旗；[_studyClockManualPaused] 只是给
///   控制条按钮图标重建用的读口（门才是状态持有者）。
/// - 「打开完整记录」= 关侧栏 + 推统计中心「观看」页签；那是整页路由，被
///   `StudyCoverTracker` 判成盖住本页，自动停表。
extension _VideoStudyStats on _VideoFushiPageState {
  /// 控制条「统计」键 / 菜单项：开（或在切换条里换到）统计侧栏；已开着就关。
  void _toggleVideoStatisticsPanel({VideoControlSlot? sourceSlot}) {
    final _VideoSidePanelState? current = _videoSidePanel.value;
    if (current?.kind == _VideoSidePanelKind.statistics) {
      _hideVideoSidePanel();
      return;
    }
    if (current != null &&
        _videoPanelSwitcherKinds().contains(current.kind) &&
        _videoPanelSwitcherKinds().contains(_VideoSidePanelKind.statistics)) {
      _switchVideoSidePanel(_VideoSidePanelKind.statistics);
      return;
    }
    _showVideoSidePanel(_VideoSidePanelKind.statistics, sourceSlot: sourceSlot);
  }

  /// 手动暂停 / 继续计时（控制条计时键、统计侧栏暂停键同一入口）。切后台期间点
  /// 「继续」只是清旗，回前台再起表（门的统一判据）。
  void _toggleVideoStudyClockManualPause() {
    _studyClockGate.toggleManualPause();
    _studyClockManualPaused.value = _studyClockGate.manualPause;
  }

  StudySessionTotals _videoStudySessionTotals() =>
      _watchTracker?.clock.sessionTotals() ??
      (durationMs: 0, chars: 0, active: false);

  /// 本视频的今日 / 累计（统一事实面，身份 = 观看统计身份 [_watchStatsIdentity] 的 uid，
  /// 与时钟 `mediaKey` 同一个键）。
  Future<ReaderBookStatTotals> _loadVideoStatTotals() async {
    final String key = _watchTracker?.bookUid ?? _watchStatsIdentity.$1;
    final StatFacts facts = await loadStatFacts(
      appModel.database,
      activityLimit: 0,
      includeCounters: true,
    );
    return summarizeReaderBookStats(
      facts.dailyVideos,
      counters: facts.counters.lookupCounters,
      bookKey: key,
      title: _title,
      now: DateTime.now(),
    );
  }

  Widget _buildVideoStatisticsPanel() {
    return ReaderStatisticsSheet(
      media: ReaderStatsMedia.video,
      showHeader: false,
      bookTitle: _title ?? '',
      sessionTotals: _videoStudySessionTotals,
      loadBookTotals: _loadVideoStatTotals,
      playbackSpeed: () => _playbackSpeed,
      progress: () {
        final VideoPlayerController? controller = _controller;
        final int episodes = _episodes.length;
        return (
          chapterCurrent: controller?.positionMs,
          chapterTotal: controller?.durationMs,
          bookCurrent: episodes > 1 ? _currentEpisode + 1 : null,
          bookTotal: episodes > 1 ? episodes : null,
        );
      },
      onTogglePause: _toggleVideoStudyClockManualPause,
      onOpenFullRecords: () {
        _hideVideoSidePanel();
        unawaited(_openVideoStatisticsCenter());
      },
    );
  }

  Future<void> _openVideoStatisticsCenter() async {
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const StatisticsCenterPage(initialTab: StatsCenterTab.video),
      ),
    );
  }
}
