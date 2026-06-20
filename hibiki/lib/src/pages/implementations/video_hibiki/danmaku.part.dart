// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch1).
part of '../video_hibiki_page.dart';

/// danmaku (local sidecar + Dandanplay online) domain methods extracted via
/// part-of (TODO-590 batch1); shared private scope. Behaviour-preserving:
/// bodies are verbatim except `setState(` forwarded through the main shell
/// `_rebuild(` helper (extensions cannot call the @protected State.setState
/// directly).
extension _VideoDanmaku on _VideoHibikiPageState {
  Future<void> _loadDanmakuForVideo(String? videoPath) async {
    final int seq = ++_danmakuLoadSeq;
    if (mounted) {
      _rebuild(() => _danmakuItems = const <VideoDanmakuItem>[]);
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
        _rebuild(() => _danmakuItems = local.items);
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
        _rebuild(() => _danmakuItems = result.items);
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
      _danmakuItems = const <VideoDanmakuItem>[];
      return;
    }
    _rebuild(() => _danmakuItems = const <VideoDanmakuItem>[]);
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
}
