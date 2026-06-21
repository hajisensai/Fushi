// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch13).
part of '../video_hibiki_page.dart';

/// Subtitle lookup + sentence-favourite domain methods extracted via part-of
/// (TODO-590 batch13); shared private scope. Behaviour-preserving: the method
/// bodies are moved character-for-character except the six `setState(...)`
/// rebuilds (inside [_refreshVideoSentenceFavorite],
/// [_toggleFavoriteSentenceForVideo], [_toggleFavoriteCueForVideo] and
/// [_refreshFavoritedCueCache]) which are routed through the main shell's
/// `_rebuild(...)` forwarder (the established part paradigm — an extension
/// cannot call the @protected `State.setState` directly). No host-class static
/// needed re-qualification: every collaborator ([videoFavoriteCacheKey],
/// [resolveMiningCueForPosition], [statTodayKey], [kFavoriteSentenceSourceVideo],
/// [pushNestedPopup], etc.) is a top-level / mixin symbol in the same library.
///
/// Covers the subtitle-character lookup entry ([_lookupAt]) plus the sentence /
/// cue favourite surface ([_refreshVideoSentenceFavorite],
/// [_toggleFavoriteSentenceForVideo], [_copyCueText], [_isCueFavorited],
/// [_toggleFavoriteCueForVideo], [_refreshFavoritedCueCache],
/// [_videoFavoriteCacheKey], [_matchingVideoFavorites]). The popup-stack
/// infrastructure and the @override mining hooks stay in the main shell.
extension _VideoLookupFavorite on _VideoHibikiPageState {
  /// 点字幕第 [graphemeIndex] 个字符：暂停 → 从该位置起取词 → 推入与阅读器/词典页
  /// 同款的 [DictionaryPopupLayer] 浮层（定位到被点字符的屏幕 [charRect] 附近）。
  ///
  /// [charRect] 来自字符 box 的 `localToGlobal`，是 [HibikiAppUiScale] 缩放后的**真实
  /// 屏幕坐标**。浮层子树经 [_buildPopupOverlay] 的 [HibikiAppUiScaleNeutralizer] 中和回
  /// 真实视口空间（净变换=1），其坐标系即真实屏幕空间，故这里**直接**用 [charRect] 定位、
  /// 不再换算到缩放画布——界面任意缩放下定位都不偏（BUG-051）。
  ///
  /// 查词/递归查词/单词发音/auto-read/制卡全部走 [DictionaryPageMixin]，与书内一致。
  Future<void> _lookupAt(
    String sentence,
    int graphemeIndex,
    Rect charRect,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final Stopwatch swLookup = Stopwatch()..start();
    final String term = sentence.characters.skip(graphemeIndex).join();
    debugPrint('[video-lookup] tap idx=$graphemeIndex term="$term"');
    // 先判空再暂停：空词不弹浮层，不能暂停后无浮层可关→恢复路径永不触发（卡暂停）。
    if (term.isEmpty) return;
    // 仅当视频正在播放才暂停并标记，浮层全关后据此恢复（BUG-072）。查词前本就
    // 暂停 / 递归查词（已暂停）时 isPlaying==false，不暂停也不覆写标记。
    // 性能（弹窗弹出慢）：暂停是副作用，不该卡住弹窗推送。media_kit/libmpv 的
    // pause() 在桌面有 IPC 往返延迟，原先 `await` 把第一次查词的弹窗整整推迟一个
    // 暂停耗时。改为先置标记、fire-and-forget 暂停，弹窗立刻推。
    if (controller.isPlaying) {
      _pausedForLookup = true;
      unawaited(controller.pause());
    }
    _lastLookupSentence = sentence;
    // TODO-393 / BUG-缓存串味：每次新查词都从「只制当前句」起步，丢弃上一个词的
    // 「上 N 句 / 下 N 句」上下文选择。热槽 WebView 复用使弹窗 DOM 不重载，草稿若不
    // 在此清空，上一个词攒的上下文会带到下一个词的卡（用户报「弹窗会缓存」）。
    _miningDraft.clear();
    // 制卡要裁「用户正在学的那句」的真实声轨音频。currentCue 在字幕 gap / 末句后被
    // 清成 null（BUG-074 字幕条该消失），而查词往往就发生在字幕刚消失那一瞬——若直接
    // 取 currentCue，制卡时句子音频字段会空（TODO-104b / BUG-188）。故 null 时按当前
    // 播放位置独立解析最近一条 cue（只读 controller，不复用被 gap 清空的 UI 状态）。
    _lastLookupCue = controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.cues,
          positionMs: controller.positionMs ?? 0,
          delayMs: controller.delayMs,
        );
    await pushNestedPopup(
      query: term,
      selectionRect: charRect,
      controller: _popup,
      replaceStack: true,
      reuseWarmSlot: true,
      autoRead: true,
    );
    debugPrint(
      '[video-lookup] popup ready in ${swLookup.elapsedMilliseconds}ms term="$term"',
    );
    // 刷新查词浮层顶部收藏星标：判定当前字幕句是否已收藏（异步，不阻塞弹窗）。
    unawaited(_refreshVideoSentenceFavorite());
  }

  /// 当前查词字幕句的收藏键：视频句子把 cue.startMs 兼容写入
  /// [FavoriteSentence.normCharOffset]，用 `bookUid + startMs` 指回时间轴；没有 cue 的
  /// 旧条目继续以 `text + bookUid` 兼容匹配。
  Future<void> _refreshVideoSentenceFavorite() async {
    final String sentence = _lastLookupSentence;
    final AudioCue? cue = _lastLookupCue;
    if (sentence.isEmpty) {
      if (mounted && _currentVideoSentenceIsFavorited) {
        _rebuild(() => _currentVideoSentenceIsFavorited = false);
      }
      return;
    }
    final bool favorited = (await _matchingVideoFavorites(
      sentence,
      cue,
    ))
        .isNotEmpty;
    if (mounted && favorited != _currentVideoSentenceIsFavorited) {
      _rebuild(() => _currentVideoSentenceIsFavorited = favorited);
    }
  }

  /// 收藏/取消收藏当前查词所在的字幕句（视频端，TODO-047 ④）。来源标
  /// [kFavoriteSentenceSourceVideo]、记 [dateKey]=今日键，使其计入视频统计的「收藏语句」
  /// 卡片，并能在收藏夹页按视频来源展示。不恢复 BUG-123 删除的单词 ☆ 按钮——这是
  /// 句子收藏星标，与书内 [ReaderHibikiPage] 的 buildPopupAudioControls 星标同语义。
  Future<void> _toggleFavoriteSentenceForVideo() async {
    final String sentence = _lastLookupSentence;
    if (sentence.isEmpty) {
      HibikiToast.show(msg: t.no_sentence_selected);
      return;
    }
    final AudioCue? cue = _lastLookupCue;
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    if (_currentVideoSentenceIsFavorited) {
      for (final FavoriteSentence fav in await _matchingVideoFavorites(
        sentence,
        cue,
      )) {
        await repo.removeById(fav.id);
      }
      if (mounted) {
        _rebuild(() {
          _currentVideoSentenceIsFavorited = false;
          if (cue != null) {
            _favoritedVideoSentences.remove(_videoFavoriteCacheKey(
              sentence,
              cue.startMs,
              _currentEpisode,
            ));
          }
          _favoritedVideoSentences.remove(
            _videoFavoriteCacheKey(sentence, null, null),
          );
        });
      }
      HibikiToast.show(msg: t.favorite_removed);
      return;
    }
    await repo.add(
      FavoriteSentence(
        // 视频标题尚未加载（_title==null）时回退到 bookUid，保证 bookTitle 永远非空
        // ——收藏夹页 / 统计页都按 bookTitle 展示来源行，空标题会显示成空白条目。
        text: sentence,
        bookTitle: _title ?? widget.bookUid,
        createdAt: DateTime.now(),
        bookKey: widget.bookUid,
        sectionIndex: _currentEpisode,
        normCharOffset: cue?.startMs,
        normCharLength: cue == null
            ? null
            : (cue.endMs - cue.startMs).clamp(0, 1 << 31).toInt(),
        source: kFavoriteSentenceSourceVideo,
        dateKey: statTodayKey(),
      ),
    );
    if (mounted) {
      _rebuild(() {
        _currentVideoSentenceIsFavorited = true;
        _favoritedVideoSentences.add(_videoFavoriteCacheKey(
          sentence,
          cue?.startMs,
          _episodes.isEmpty ? null : _currentEpisode,
        ));
      });
    }
    HibikiToast.show(msg: t.favorite_added);
  }

  /// 从字幕跳转列表面板行内复制某句文本到剪贴板（TODO-152 子A）。不暂停 / 不查词。
  void _copyCueText(AudioCue cue) {
    final String text = cue.text.trim();
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    HibikiToast.show(msg: t.copied_to_clipboard);
  }

  /// 字幕跳转列表面板某句是否已收藏（同步，读缓存 [_favoritedVideoSentences]）。
  bool _isCueFavorited(AudioCue cue) {
    final String text = cue.text.trim();
    return _favoritedVideoSentences.contains(_videoFavoriteCacheKey(
          text,
          cue.startMs,
          _episodes.isEmpty ? null : _currentEpisode,
        )) ||
        _favoritedVideoSentences
            .contains(_videoFavoriteCacheKey(text, null, null));
  }

  /// 从字幕跳转列表面板行内 toggle 某句收藏（TODO-152 子A）。与查词浮层收藏走同一
  /// [FavoriteSentenceRepository]，视频句键优先用 `bookUid + cue.startMs`，并兼容旧
  /// text-only 条目。toggle 后更新缓存集；若恰好是当前查词句，
  /// 同步 [_currentVideoSentenceIsFavorited] 让浮层星标也刷新。
  Future<void> _toggleFavoriteCueForVideo(AudioCue cue) async {
    final String sentence = cue.text.trim();
    if (sentence.isEmpty) return;
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    final bool wasFavorited = _isCueFavorited(cue);
    if (wasFavorited) {
      for (final FavoriteSentence fav in await _matchingVideoFavorites(
        sentence,
        cue,
      )) {
        await repo.removeById(fav.id);
      }
    } else {
      await repo.add(
        FavoriteSentence(
          text: sentence,
          bookTitle: _title ?? widget.bookUid,
          createdAt: DateTime.now(),
          bookKey: widget.bookUid,
          sectionIndex: _currentEpisode,
          normCharOffset: cue.startMs,
          normCharLength: (cue.endMs - cue.startMs).clamp(0, 1 << 31).toInt(),
          source: kFavoriteSentenceSourceVideo,
          dateKey: statTodayKey(),
        ),
      );
    }
    if (!mounted) return;
    _rebuild(() {
      if (wasFavorited) {
        _favoritedVideoSentences
          ..remove(_videoFavoriteCacheKey(
            sentence,
            cue.startMs,
            _episodes.isEmpty ? null : _currentEpisode,
          ))
          ..remove(_videoFavoriteCacheKey(sentence, null, null));
      } else {
        _favoritedVideoSentences.add(_videoFavoriteCacheKey(
          sentence,
          cue.startMs,
          _episodes.isEmpty ? null : _currentEpisode,
        ));
      }
      // 列表 toggle 的若是当前查词那句，同步浮层星标态（两处共用同一收藏记录）。
      if (sentence == _lastLookupSentence.trim()) {
        _currentVideoSentenceIsFavorited = !wasFavorited;
      }
    });
    HibikiToast.show(msg: wasFavorited ? t.favorite_removed : t.favorite_added);
  }

  /// 拉本视频已收藏句填充 [_favoritedVideoSentences]（打开字幕跳转列表前调一次）。
  /// 只取本 bookKey + video 来源那批，按 `text` 建集供同步查询。
  Future<void> _refreshFavoritedCueCache() async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
    final List<FavoriteSentence> all = await repo.getAll();
    if (!mounted) return;
    _rebuild(() {
      _favoritedVideoSentences
        ..clear()
        ..addAll(
          all
              .where(
                (FavoriteSentence s) =>
                    s.bookKey == widget.bookUid &&
                    s.source == kFavoriteSentenceSourceVideo,
              )
              .map(
                (FavoriteSentence s) => _videoFavoriteCacheKey(
                  s.text.trim(),
                  s.normCharOffset,
                  s.sectionIndex,
                ),
              ),
        );
    });
  }

  String _videoFavoriteCacheKey(String text, int? startMs, int? episodeIndex) =>
      videoFavoriteCacheKey(
        text: text,
        startMs: startMs,
        episodeIndex: episodeIndex,
        isPlaylist: _episodes.isNotEmpty,
      );

  Future<List<FavoriteSentence>> _matchingVideoFavorites(
    String sentence,
    AudioCue? cue,
  ) async {
    final String text = sentence.trim();
    final List<FavoriteSentence> all = await FavoriteSentenceRepository(
      appModel.database,
    ).getAll();
    final int? episodeIndex = _episodes.isEmpty ? null : _currentEpisode;
    return all
        .where(
          (FavoriteSentence s) =>
              s.source == kFavoriteSentenceSourceVideo &&
              s.bookKey == widget.bookUid &&
              s.text.trim() == text &&
              (cue == null
                  ? s.normCharOffset == null
                  : (s.normCharOffset == cue.startMs &&
                          (_episodes.isEmpty ||
                              s.sectionIndex == episodeIndex)) ||
                      (s.normCharOffset == null && s.sectionIndex == null)),
        )
        .toList();
  }
}
