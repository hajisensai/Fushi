// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch1).
part of '../video_fushi_page.dart';

/// danmaku (local sidecar + Dandanplay online) domain methods extracted via
/// part-of (TODO-590 batch1); shared private scope. Behaviour-preserving:
/// bodies are verbatim except `setState(` forwarded through the main shell
/// `_rebuild(` helper (extensions cannot call the @protected State.setState
/// directly).
///
/// TODO-1376 增强：手动搜索/选集匹配、样式即改即生效、屏蔽词/正则过滤。原始弹幕全集
/// 落 [_danmakuItems]，屏蔽过滤后的可见集落 [_danmakuVisibleItems]（overlay 消费）。
extension _VideoDanmaku on _VideoFushiPageState {
  /// 设置弹幕原始全集并同步屏蔽过滤后的可见集（数据拥有者唯一入口，消除两份不同步）。
  void _applyDanmakuItems(List<VideoDanmakuItem> items) {
    _danmakuItems = items;
    _danmakuVisibleItems = filterVideoDanmaku(items, _danmakuBlockRules);
  }

  /// 远端流播时弹幕的来源（BUG-3614）：远端视频 id + host 侧集下标。来源不能算
  /// 弹弹play 指纹（[RemoteVideoDanmakuKeyFetch] 之外的媒体服务器 / 云盘 / 在线源）
  /// 或不是远端 → null，与改动前一样没有弹幕。
  ({String id, int episodeIndex})? get _remoteDanmakuTarget {
    final RemoteVideoInfo? info = _effectiveRemoteInfo;
    if (info == null || _effectiveRemoteClient is! RemoteVideoDanmakuKeyFetch) {
      return null;
    }
    // 合集连播：每个成员是独立视频（host 侧集下标恒 0）；host 播放列表 / 单视频：
    // 同一 id 换集下标（与 [_loadRemoteEpisode] 的取流口径一致）。
    return (
      id: info.id,
      episodeIndex: _isRemoteCollection ? 0 : _currentEpisode,
    );
  }

  /// 弹弹play 选集记忆的键。本地沿用 [_activeBookUid]；远端按「成员 id + 集下标」
  /// 分开记——合集连播里 [_activeBookUid] 恒是起播那一集，按它记会让整部剧共用
  /// 同一集的弹幕。
  String get _danmakuEpisodeUid {
    final ({String id, int episodeIndex})? remote = _remoteDanmakuTarget;
    if (remote == null) return _activeBookUid;
    return remote.episodeIndex == 0
        ? remote.id
        : '${remote.id}#${remote.episodeIndex}';
  }

  /// 弹幕是否有来源：本地文件，或能向 host 取指纹的远端流（控制条据此显示开关）。
  bool get _hasDanmakuSource =>
      _currentVideoPath != null || _remoteDanmakuTarget != null;

  Future<void> _loadDanmakuForVideo(String? videoPath) async {
    final int seq = ++_danmakuLoadSeq;
    if (mounted) {
      _rebuild(() => _applyDanmakuItems(const <VideoDanmakuItem>[]));
    }
    if (!appModel.videoDanmakuEnabled) return;
    if (videoPath == null) {
      // 远端流播：本机没有文件、没有同目录 sidecar，指纹由持有文件的 host 算
      // （BUG-3614）；之后的在线匹配与本地文件同一条链路。
      final ({String id, int episodeIndex})? remote = _remoteDanmakuTarget;
      final RemoteVideoClient? remoteClient = _effectiveRemoteClient;
      if (remote == null || remoteClient is! RemoteVideoDanmakuKeyFetch) return;
      if (!appModel.videoDanmakuOnlineEnabled) return;
      final RemoteVideoDanmakuKeyFetch keyFetch =
          remoteClient as RemoteVideoDanmakuKeyFetch;
      await _loadOnlineDanmaku(
        seq,
        () => keyFetch.remoteVideoDanmakuKey(
          remote.id,
          episodeIndex: remote.episodeIndex,
        ),
      );
      return;
    }

    final String? sidecarPath = await findDanmakuSidecar(videoPath);
    if (sidecarPath != null) {
      final VideoDanmakuLoadResult local = await loadDanmakuSidecarFile(
        File(sidecarPath),
      );
      if (seq != _danmakuLoadSeq || !mounted) return;
      if (local.tooLarge) {
        debugPrint(
          '[VideoDanmaku] local sidecar too large: ${local.sourcePath}',
        );
      } else if (local.items.isNotEmpty) {
        _rebuild(() => _applyDanmakuItems(local.items));
        debugPrint(
          '[VideoDanmaku] loaded ${local.items.length} local comments '
          'from ${local.sourcePath}',
        );
        return;
      } else if (local.error != null) {
        debugPrint('[VideoDanmaku] local sidecar parse failed: ${local.error}');
      }
    }

    if (!appModel.videoDanmakuOnlineEnabled) return;
    final File file = File(videoPath);
    if (!await file.exists()) return;
    await _loadOnlineDanmaku(seq, () => dandanplayFileKeyOf(file));
  }

  /// 弹弹play 在线弹幕：先试记住的那一集，没有 / 记错了再按文件指纹 [keyOf] 匹配。
  /// [keyOf] 只在真要匹配时才算（本地要读 16 MiB、远端要问一次 host）；返回 null =
  /// 拿不到指纹，当作没有弹幕。
  Future<void> _loadOnlineDanmaku(
    int seq,
    Future<DandanplayFileKey?> Function() keyOf,
  ) async {
    final String episodeUid = _danmakuEpisodeUid;
    final DandanplayClient client = DandanplayClient();
    Future<DandanplayFetchResult> matchByKey() async {
      final DandanplayFileKey? key = await keyOf();
      if (key == null) {
        return const DandanplayFetchResult(
          status: DandanplayFetchStatus.noMatch,
        );
      }
      return client.fetchBestDanmakuForKey(key);
    }

    try {
      DandanplayFetchResult result;
      final int? savedEpisodeId = appModel.getVideoDanmakuEpisodeId(episodeUid);
      if (savedEpisodeId != null) {
        final DandanplayFetchResult cached = await client.fetchCommentsForMatch(
          DandanplayMatch(episodeId: savedEpisodeId),
        );
        // 只有「记住的这一集有效、但确实 0 条弹幕」才值得退回整文件匹配（多半是记错了
        // 集）；网络/服务器失败退回去走的是同一条链路，只会白算一次 16MiB 文件 hash
        // 再失败一遍（BUG-1057：此前失败被吞成空列表，与 0 条弹幕无从区分）。
        result =
            cached.status == DandanplayFetchStatus.hit && cached.items.isEmpty
            ? await matchByKey()
            : cached;
      } else {
        result = await matchByKey();
      }
      if (seq != _danmakuLoadSeq || !mounted) return;
      if (result.status == DandanplayFetchStatus.hit &&
          result.items.isNotEmpty) {
        final int? episodeId = result.match?.episodeId;
        if (episodeId != null) {
          await appModel.setVideoDanmakuEpisodeId(episodeUid, episodeId);
        }
        if (seq != _danmakuLoadSeq || !mounted) return;
        _rebuild(() => _applyDanmakuItems(result.items));
        debugPrint(
          '[VideoDanmaku] loaded ${result.items.length} Dandanplay comments '
          'episode=${episodeId ?? savedEpisodeId}',
        );
      } else {
        debugPrint(
          '[VideoDanmaku] online fallback: ${result.status} '
          'matches=${result.matches.length}',
        );
      }
    } catch (e) {
      debugPrint('[VideoDanmaku] online load failed: $e');
    } finally {
      client.close();
    }
  }

  void _clearDanmakuForCurrentVideo() {
    ++_danmakuLoadSeq;
    if (!mounted) {
      _applyDanmakuItems(const <VideoDanmakuItem>[]);
      return;
    }
    _rebuild(() => _applyDanmakuItems(const <VideoDanmakuItem>[]));
  }

  Future<void> _setVideoDanmakuEnabled(bool value) async {
    await appModel.setVideoDanmakuEnabled(value);
    if (!mounted) return;
    if (value) {
      unawaited(_loadDanmakuForVideo(_currentVideoPath));
    } else {
      _clearDanmakuForCurrentVideo();
    }
  }

  Future<void> _setVideoDanmakuOnlineEnabled(bool value) async {
    await appModel.setVideoDanmakuOnlineEnabled(value);
    if (!mounted) return;
    if (appModel.videoDanmakuEnabled) {
      unawaited(_loadDanmakuForVideo(_currentVideoPath));
    } else {
      _rebuild(() {});
    }
  }

  Future<void> _setVideoDanmakuMaxActive(int value) async {
    await appModel.setVideoDanmakuMaxActive(value);
    if (!mounted) return;
    _rebuild(() {});
  }

  /// TODO-1376：拖动中即时预览样式（不落盘），仅更新内存态让 overlay 实时变化。
  void _previewVideoDanmakuStyle(VideoDanmakuStyle style) {
    if (!mounted) return;
    _rebuild(() => _danmakuStyle = style.normalized());
  }

  /// TODO-1376：提交并持久化弹幕样式（拖动结束时）。
  Future<void> _setVideoDanmakuStyle(VideoDanmakuStyle style) async {
    final VideoDanmakuStyle normalized = style.normalized();
    await appModel.setVideoDanmakuStyle(normalized);
    if (!mounted) return;
    _rebuild(() => _danmakuStyle = normalized);
  }

  /// TODO-1376：保存屏蔽规则原文并重算可见弹幕（即改即生效）。
  Future<void> _setVideoDanmakuBlockRules(String rulesText) async {
    await appModel.setVideoDanmakuBlockRulesText(rulesText);
    if (!mounted) return;
    _rebuild(() {
      _danmakuBlockRules = parseVideoDanmakuBlockRules(rulesText);
      _danmakuVisibleItems = filterVideoDanmaku(
        _danmakuItems,
        _danmakuBlockRules,
      );
    });
  }

  /// TODO-1376：打开手动搜索/选集侧栏（自动匹配失败或匹配错集时的兜底入口）。
  void _openDanmakuManualMatch() {
    _showVideoSidePanel(_VideoSidePanelKind.danmakuMatch);
  }

  /// 手动搜索候选集（弹弹play `searchEpisodes`），每次用独立 client、用完即关。
  Future<DandanplaySearchResult> _searchDanmakuEpisodes(String keyword) async {
    final DandanplayClient client = DandanplayClient();
    try {
      return await client.searchEpisodes(keyword);
    } finally {
      client.close();
    }
  }

  /// 用户选定某集 → 拉该集弹幕、持久化 episodeId（供下次自动恢复）、开弹幕、关面板。
  Future<void> _bindDanmakuEpisode(DandanplaySearchEpisode episode) async {
    final DandanplayClient client = DandanplayClient();
    try {
      final DandanplayFetchResult result = await client.fetchCommentsForMatch(
        DandanplayMatch(episodeId: episode.episodeId),
      );
      if (!mounted) return;
      if (result.status != DandanplayFetchStatus.hit) {
        // BUG-1057：拉弹幕失败时保持面板打开、不落 episodeId，并按失败类型给具体
        // 文案。此前非 2xx 被吞成空列表，反而走「成功」分支：面板关闭、episodeId
        // 落库、弹幕为空、零提示。
        debugPrint(
          '[VideoDanmaku] manual bind failed: episode=${episode.episodeId} '
          'status=${result.status} error=${result.error}',
        );
        _showOsd(
          result.status == DandanplayFetchStatus.networkError
              ? t.video_danmaku_manual_network_error
              : t.video_danmaku_manual_bind_server_error,
          icon: Icons.error_outline,
          severity: ToastSeverity.error,
        );
        return;
      }
      await appModel.setVideoDanmakuEpisodeId(
        _danmakuEpisodeUid,
        episode.episodeId,
      );
      if (!appModel.videoDanmakuEnabled) {
        await appModel.setVideoDanmakuEnabled(true);
      }
      if (!mounted) return;
      // 让任何在途的自动加载作废，避免覆盖用户手动选定的这一集。
      ++_danmakuLoadSeq;
      _rebuild(() => _applyDanmakuItems(result.items));
      _hideVideoSidePanel();
      // 该集有效但暂无弹幕：绑定照样生效（之后有人发就会出现），但要说清楚，
      // 否则用户只看到「面板关了、什么都没有」。
      if (result.items.isEmpty) {
        // 绑定本身成功（episodeId 已落库），只是这集暂无弹幕——状态告知而非失败。
        _showOsd(
          t.video_danmaku_manual_bind_empty,
          icon: Icons.info_outline,
          severity: ToastSeverity.info,
        );
      }
      debugPrint(
        '[VideoDanmaku] manual bind episode=${episode.episodeId} '
        'comments=${result.items.length}',
      );
    } catch (e) {
      debugPrint('[VideoDanmaku] manual bind failed: $e');
      // UI 巡检 PR-4：失败给可见反馈（此前只 debugPrint，用户选完集面板不关、
      // 弹幕不出现、零提示）。原始异常只留日志，不进 UI。
      _showOsd(
        t.video_danmaku_manual_bind_failed,
        icon: Icons.error_outline,
        severity: ToastSeverity.error,
      );
    } finally {
      client.close();
    }
  }

  /// 手动匹配的初始关键词：本地文件名；远端流播没有本地路径，用 host 下发的文件名
  /// （旧 host 没有就用标题——标题不是文件名，不去「扩展名」）。
  String _danmakuManualMatchKeyword() {
    final String? path = _currentVideoPath;
    if (path != null) return p.basenameWithoutExtension(path);
    final RemoteVideoInfo? info = _effectiveRemoteInfo;
    if (info == null) return '';
    final String? fileName = info.fileName;
    return fileName != null && fileName.isNotEmpty
        ? p.basenameWithoutExtension(fileName)
        : info.title;
  }

  /// 手动匹配侧栏内容：以当前视频文件名为初始关键词，注入搜索/绑定回调。
  Widget _buildDanmakuMatchSidePanel() {
    // 配色读侧栏表面**内部**的主题（M3E = 面板中性深色主题），不是页面主题。
    return Builder(
      builder: (BuildContext panelContext) => DanmakuManualMatchPanel(
        initialKeyword: _danmakuManualMatchKeyword(),
        colorScheme: Theme.of(panelContext).colorScheme,
        onSearch: _searchDanmakuEpisodes,
        onEpisodeSelected: _bindDanmakuEpisode,
      ),
    );
  }
}
