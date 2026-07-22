// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch1).
part of '../video_hibiki_page.dart';

/// danmaku (local sidecar + Dandanplay online) domain methods extracted via
/// part-of (TODO-590 batch1); shared private scope. Behaviour-preserving:
/// bodies are verbatim except `setState(` forwarded through the main shell
/// `_rebuild(` helper (extensions cannot call the @protected State.setState
/// directly).
///
/// TODO-1376 增强：手动搜索/选集匹配、样式即改即生效、屏蔽词/正则过滤。原始弹幕全集
/// 落 [_danmakuItems]，屏蔽过滤后的可见集落 [_danmakuVisibleItems]（overlay 消费）。
extension _VideoDanmaku on _VideoHibikiPageState {
  /// 设置弹幕原始全集并同步屏蔽过滤后的可见集（数据拥有者唯一入口，消除两份不同步）。
  void _applyDanmakuItems(List<VideoDanmakuItem> items) {
    _danmakuItems = items;
    _danmakuVisibleItems = filterVideoDanmaku(items, _danmakuBlockRules);
  }

  Future<void> _loadDanmakuForVideo(String? videoPath) async {
    final int seq = ++_danmakuLoadSeq;
    if (mounted) {
      _rebuild(() => _applyDanmakuItems(const <VideoDanmakuItem>[]));
    }
    if (videoPath == null || !appModel.videoDanmakuEnabled) return;

    final String? sidecarPath = findDanmakuSidecar(videoPath);
    if (sidecarPath != null) {
      final VideoDanmakuLoadResult local =
          await loadDanmakuSidecarFile(File(sidecarPath));
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
    if (!file.existsSync()) return;
    final DandanplayClient client = DandanplayClient();
    try {
      DandanplayFetchResult result;
      final int? savedEpisodeId =
          appModel.getVideoDanmakuEpisodeId(widget.bookUid);
      if (savedEpisodeId != null) {
        final DandanplayMatch cached =
            DandanplayMatch(episodeId: savedEpisodeId);
        final List<VideoDanmakuItem> cachedItems =
            await client.fetchCommentsForMatch(cached);
        if (cachedItems.isNotEmpty) {
          result = DandanplayFetchResult(
            status: DandanplayFetchStatus.hit,
            items: cachedItems,
            match: cached,
          );
        } else {
          result = await client.fetchBestDanmakuForFile(file);
        }
      } else {
        result = await client.fetchBestDanmakuForFile(file);
      }
      if (seq != _danmakuLoadSeq || !mounted) return;
      if (result.status == DandanplayFetchStatus.hit &&
          result.items.isNotEmpty) {
        final int? episodeId = result.match?.episodeId;
        if (episodeId != null) {
          await appModel.setVideoDanmakuEpisodeId(widget.bookUid, episodeId);
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
      _danmakuVisibleItems =
          filterVideoDanmaku(_danmakuItems, _danmakuBlockRules);
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
      final List<VideoDanmakuItem> items = await client.fetchCommentsForMatch(
        DandanplayMatch(episodeId: episode.episodeId),
      );
      if (!mounted) return;
      await appModel.setVideoDanmakuEpisodeId(
          widget.bookUid, episode.episodeId);
      if (!appModel.videoDanmakuEnabled) {
        await appModel.setVideoDanmakuEnabled(true);
      }
      if (!mounted) return;
      // 让任何在途的自动加载作废，避免覆盖用户手动选定的这一集。
      ++_danmakuLoadSeq;
      _rebuild(() => _applyDanmakuItems(items));
      _hideVideoSidePanel();
      debugPrint(
        '[VideoDanmaku] manual bind episode=${episode.episodeId} '
        'comments=${items.length}',
      );
    } catch (e) {
      debugPrint('[VideoDanmaku] manual bind failed: $e');
      // UI 巡检 PR-4：失败给可见反馈（此前只 debugPrint，用户选完集面板不关、
      // 弹幕不出现、零提示）。原始异常只留日志，不进 UI。
      _showOsd(t.video_danmaku_manual_bind_failed, icon: Icons.error_outline);
    } finally {
      client.close();
    }
  }

  /// 手动匹配侧栏内容：以当前视频文件名为初始关键词，注入搜索/绑定回调。
  Widget _buildDanmakuMatchSidePanel() {
    return DanmakuManualMatchPanel(
      initialKeyword: p.basenameWithoutExtension(_currentVideoPath ?? ''),
      colorScheme: _videoChromeColorScheme(context),
      onSearch: _searchDanmakuEpisodes,
      onEpisodeSelected: _bindDanmakuEpisode,
    );
  }
}
