// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch14).
part of '../video_fushi_page.dart';

/// Dictionary-lookup mining (制卡) domain extracted via part-of (TODO-590
/// batch14); shared private scope. Behaviour-preserving: every method body is
/// moved character-for-character. The stat write that used to go through the
/// mixin's @protected `recordMined()` (via a 1-line shell forwarder) is now
/// [_recordVideoMineStat]: the same `recordMiningEvent` call, but on the
/// database and identity frozen at click time, because an online-video card can
/// land in the background after the page is gone (see [VideoOnlineMiningMode]).
/// No host-class static needed re-qualification: every collaborator
/// ([miningClipTimeMs], [resolveMiningCueForPosition],
/// [extractClipGifViaFfmpeg], [extractAudioSegmentViaFfmpeg], [describeMineOutcome],
/// [statTodayKey], [downsampleCardScreenshot], [AnkiMiningContext], etc.) is a
/// top-level / mixin symbol in the same library.
///
/// The three @override mixin hooks — [onMineEntry], [onUpdateEntry] and the two
/// `onSetSentenceContextToDraft` / `onClearSentenceDraftToDraft` getters — must
/// stay in the main shell (an extension cannot carry `@override`). The two
/// getters already forward to private targets ([_setSentenceContextToDraft] /
/// [_clearSentenceDraft]), so only their private targets moved here. The two
/// `Future<MinePopupResult>` hooks became one-line forwarders in the shell
/// delegating to the byte-exact bodies [_onMineEntryImpl] / [_onUpdateEntryImpl]
/// living here. [buildPopupHeaderFor] stays in the shell (favourite header).
///
/// Covers the sentence-context draft helpers ([_cueRange],
/// [_setSentenceContextToDraft], [_clearSentenceDraft]), the mining range
/// resolver ([_resolveVideoMiningRange]), the mine/update entry bodies
/// ([_onMineEntryImpl], [_onUpdateEntryImpl]), the card landing path
/// ([_mineVideoCard]) and the mined-sentence history row ([_recordMinedSentenceForVideo]).
extension _VideoLookupMining on _VideoFushiPageState {
  /// 把一条 cue 的画面/音频时间窗转成草稿可合并的区间。视频所有 cue 同属一个视频文件，
  /// [audioFileIndex] 统一用 0（合并恒成功，取 min start / max end）。null cue → null
  /// 区间（草稿据此退化为只合文本，不静默拼坏区间）。
  AudioPlaybackRange? _cueRange(AudioCue? cue) {
    if (cue == null) return null;
    return AudioPlaybackRange(
      audioFileIndex: 0,
      startMs: cue.startMs,
      endMs: cue.endMs,
    );
  }

  /// 以当前查词 cue（[_lastLookupCue]）为锚，在**锚点所属的那条字幕流**
  /// （[VideoPlayerController.cueStreamOwning]，按 startMs 升序）里取它之前 [prevCount] 条、
  /// 之后 [nextCount] 条作上下文，整体设进草稿（覆盖上次选择，不累积）。无 cue / 无控制器
  /// 时清空上下文返回 0。
  ///
  /// BUG-1592：以前硬取主字幕流 [VideoPlayerController.cues]。副字幕上查词时锚点不在主流里，
  /// `indexOf` 恒 -1 → 上下 N 句**静默失效**（用户只看到上下文没生效，没有任何报错）。
  Future<int> _setSentenceContextToDraft(int prevCount, int nextCount) async {
    final VideoPlayerController? controller = _controller;
    final AudioCue? anchor = _lastLookupCue;
    if (controller == null || anchor == null) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final List<AudioCue> cues = controller.cueStreamOwning(anchor);
    final int idx = cues.indexOf(anchor);
    if (idx < 0) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final int prevStart = (idx - prevCount).clamp(0, idx);
    final List<MiningDraftSentence> prev = <MiningDraftSentence>[
      for (int i = prevStart; i < idx; i++)
        MiningDraftSentence(
            sentence: cues[i].text, audioRange: _cueRange(cues[i])),
    ];
    final int nextEnd = (idx + 1 + nextCount).clamp(idx + 1, cues.length);
    final List<MiningDraftSentence> next = <MiningDraftSentence>[
      for (int i = idx + 1; i < nextEnd; i++)
        MiningDraftSentence(
            sentence: cues[i].text, audioRange: _cueRange(cues[i])),
    ];
    _miningDraft.setContext(prev: prev, next: next);
    return _miningDraft.length;
  }

  /// 手改草稿里某一句的文本（[DictionaryPageMixin.onEditSentenceContextText] 的私有
  /// 目标）。**只改文本，不动区间**：这句仍是原来那条 cue、仍是同一段时间窗，GIF 与
  /// 句子音频的裁法一字不改，改的只是最终写进卡片 sentence 字段的那行字。
  Future<void> _editSentenceContextText(
    SentenceContextSlot slot,
    int index,
    String text,
  ) async {
    _miningDraft.editSentence(slot: slot, index: index, text: text);
  }

  Future<int> _clearSentenceDraft() async {
    _miningDraft.clear();
    return _miningDraft.length;
  }

  /// 制卡（覆写 [DictionaryPageMixin.onMineEntry]）：在词典 [fields]（已含单词
  /// 发音 `{audio}`、例句字段等）基础上，注入视频专属上下文——当前帧截图
  /// coverPath（→`{book-cover}`）+ 当前字幕 cue 的音频片段（裁**当前选中音轨**）
  /// sasayakiAudioPath（→`{sentence-audio}`）+ 例句 sentence。复用现有 Anki 字段。
  /// 视频制卡/覆盖共用的「解析这一张卡的区间 + 文本」。把两个并存入口收口成一处，避免
  /// [onMineEntry] / [onUpdateEntry] 两份漂移：**查词窗口多句合一草稿**（TODO-270 E）：
  /// 当前 cue 取「lookup 缓存 → currentCue → 按位置解析」多段兜底（含 gap，BUG-188）；
  /// 文本用 [MiningSentenceDraft.composeText] 合并草稿全部句 + 当前句，区间用
  /// [MiningSentenceDraft.composeAudioRange] 合并成首句起→末句止（草稿空时等价于单句
  /// 原行为：trim 文本 + 单 cue 区间）。
  ({
    int clipStartMs,
    int clipEndMs,
    int stillFrameAtMs,
    String sentence,
    String? cueSentence,
  }) _resolveVideoMiningRange(VideoPlayerController controller) {
    final CardSourceLink? restored = widget.sourceReview;
    final (String currentUid, int currentEpisode) = _isRemote
        ? _remotePositionKeyForIndex(_currentEpisode)
        : (widget.bookUid, 0);
    if (restored?.startMs != null &&
        restored?.endMs != null &&
        restored?.uid == currentUid &&
        restored?.episodeIndex == currentEpisode &&
        _lastLookupCue == null &&
        _miningDraft.isEmpty) {
      final String text = controller.miningCues
          .where((AudioCue cue) {
            final int delayMs = controller.delayMsForCue(cue);
            return miningClipTimeMs(cue.endMs, delayMs) > restored!.startMs! &&
                miningClipTimeMs(cue.startMs, delayMs) < restored.endMs!;
          })
          .map((AudioCue cue) => cue.text)
          .join('\n');
      return (
        clipStartMs: restored!.startMs!,
        clipEndMs: restored.endMs!,
        // 回看会话没有「未 pad 的字幕起点」可用，封面锚在卡片自己记的片段起点。
        stillFrameAtMs: restored.startMs!,
        sentence: text,
        cueSentence: text,
      );
    }
    // 查词窗口多句合一（TODO-270 E）。当前 cue 多段兜底（含 gap，BUG-188）。
    // BUG-1592：按位置兜底走**有效流**（主字幕流为空即副字幕流）。命中项已带 cue 的入口
    // （点击 / hover / 手柄光标 / 列表）走 [_lastLookupCue]，这条只服务「没有命中项」的
    // 入口（如无查词直接制卡）——它以前硬认主流，主字幕关闭时恒 null → 区间 `0..0`。
    final AudioCue? cue = _lastLookupCue ??
        controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.miningCues,
          positionMs: controller.positionMs ?? 0,
          // TODO-2837：按位置解析必须与有效流的 cue 命中同一根轴（主流空落副流
          // 时用副轨生效轴，否则副轨独立调轴后锚错句）。
          delayMs: controller.miningDelayMs,
        );
    // 草稿全部句 + 当前查词句合成 sentence（草稿空 → 单句 _lastLookupSentence trim）。
    final String mergedSentence = _miningDraft.composeText(_lastLookupSentence);
    // 草稿全部句区间 + 当前 cue 区间合并成首句起→末句止（草稿空 → 单 cue 区间）。
    final AudioPlaybackRange? mergedRange = _miningDraft.composeAudioRange(
      cue == null
          ? null
          : AudioPlaybackRange(
              audioFileIndex: 0,
              startMs: cue.startMs,
              endMs: cue.endMs,
            ),
    );
    // TODO-680 / BUG-392：mergedRange / cue 的 startMs/endMs 都是字幕文件坐标，裁
    // 音频/封面前逆变换回播放器轴（+ delayMs），与字幕显示用的 effectiveSubtitlePositionMs
    // 方向相反，保证裁的就是用户实际听到/看到的那段。TODO-2837：主副分开调轴后
    // 按锚定 cue 所属流取轴（查副字幕词制卡时用副轨生效轴；无 cue 回落有效流轴）。
    final int clipDelayMs =
        cue == null ? controller.miningDelayMs : controller.delayMsForCue(cue);
    // 头/尾 padding（用户偏好，对齐 asbplayer）：字幕 cue 的时间窗通常比实际发声短，
    // 尾音直接被硬切。与有声书制卡共用 [padSentenceRange]：在字幕文件时基（未加
    // delay）上加 padding，并夹在锚定 cue 所属流的相邻 cue 边界内，不把邻句混进来；
    // 之后再整体逆变换回播放器轴（先 pad 再 shift，与有声书链同序）。非正区间（无
    // cue → `0..0`）不 pad——那是下游「不抽媒体」的哨兵，pad 了会把哨兵变成真区间。
    final AudioPlaybackRange? paddedRange =
        (mergedRange == null || mergedRange.endMs <= mergedRange.startMs)
            ? mergedRange
            : padSentenceRange(
                mergedRange,
                cues: cue == null
                    ? controller.miningCues
                    : controller.cueStreamOwning(cue),
                headPadMs: appModel.miningAudioHeadPadMs,
                tailPadMs: appModel.miningAudioTailPadMs,
              );
    return (
      clipStartMs: miningClipTimeMs(paddedRange?.startMs ?? 0, clipDelayMs),
      clipEndMs: miningClipTimeMs(paddedRange?.endMs ?? 0, clipDelayMs),
      // 「字幕起始帧」封面锚点用**未 pad** 的字幕起点（同一逆变换）：封面承诺的是字幕
      // 开始那一刻的画面，不能跟着音频头 padding 往前退到上一个镜头。
      stillFrameAtMs: miningClipTimeMs(mergedRange?.startMs ?? 0, clipDelayMs),
      // 多句时 cueSentence 用合并文本与 sentence 一致；草稿空时退回单 cue 文本作 fallback。
      cueSentence: _miningDraft.isEmpty ? cue?.text : mergedSentence,
      sentence: mergedSentence,
    );
  }

  Future<MinePopupResult> _onMineEntryImpl(Map<String, String> fields) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();

    final ({
      int clipStartMs,
      int clipEndMs,
      int stillFrameAtMs,
      String sentence,
      String? cueSentence,
    }) range = _resolveVideoMiningRange(controller);
    final int queuedEpisode = _currentEpisode;
    final AudioCue? historyCue = _lastLookupCue;
    final VideoMiningHistorySnapshot historySnapshot =
        VideoMiningHistorySnapshot.capture(
      fields: fields,
      sentence: range.sentence,
      documentTitle: _title ?? widget.bookUid,
      bookKey: widget.bookUid,
      sectionIndex: _favoriteSectionIndex,
      cueStartMs: historyCue?.startMs,
      cueEndMs: historyCue?.endMs,
      dateKey: statTodayKey(),
    );

    final bool recordHistory = _sourceReviewSession == null;
    // 后台落卡时页面可能已经关了：历史行写进点击时的库，不经 `ref`。
    final FushiDatabase historyDb = appModel.database;
    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      // 音频/封面区间 = 合并后的首句起→末句止（单句即该 cue 时间窗，两端相等→不抽）。
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      stillFrameAtMs: range.stillFrameAtMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
      historySnapshot: recordHistory ? historySnapshot : null,
      // 在线视频后台制卡：卡在弹窗返回之后才落地，历史行跟着落地时再写。
      onBackgroundLanded: (MinePopupResult landed) {
        if (landed.ankiConnect && recordHistory) {
          unawaited(_recordMinedSentenceForVideo(
            historySnapshot,
            landed.noteId,
            db: historyDb,
          ));
        }
      },
    );
    if (result.queued) {
      // 后台 / 看完再制卡：请求已冻结了草稿里的句子，当场清空（popup.js 在同一次回包
      // 里把上下文角标归零），下一次查词从空草稿重新累积。与落卡路径同一道门：页面
      // 已销毁或已换集就不碰新页面 / 新集的草稿。
      if (!mounted || _currentEpisode != queuedEpisode) return result;
      _miningDraft.clear();
      return result;
    }
    // result.ankiConnect 是「制卡成功」信号（两后端成功时都置 true；noteId 仅
    // AnkiConnect 非空，故清选中句不能以 noteId 为判据，否则 AnkiDroid 成功也不清）。
    if (result.ankiConnect) {
      // TODO-633: success also lands one mined-sentence history row with the
      // video locator (bookUid + episode + cue time window), mirroring the
      // favorite-sentence anchors so collections can jump back via the video page.
      if (_sourceReviewSession == null) {
        unawaited(_recordMinedSentenceForVideo(historySnapshot, result.noteId));
      }
      if (!mounted || _currentEpisode != queuedEpisode) return result;
      // TODO-270 E：合并卡已落地 → 清空多句草稿（popup.js 同事件把角标清零，两端在
      // 同一事件归零、不漂移）。下一次查词从空草稿重新累积。
      _miningDraft.clear();
    }
    return result;
  }

  Future<MinePopupResult> _onUpdateEntryImpl(
    int noteId,
    Map<String, String> fields,
  ) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();

    final ({
      int clipStartMs,
      int clipEndMs,
      int stillFrameAtMs,
      String sentence,
      String? cueSentence,
    }) range = _resolveVideoMiningRange(controller);
    final int queuedEpisode = _currentEpisode;

    final MinePopupResult result = await _mineVideoCard(
      fields: fields,
      clipStartMs: range.clipStartMs,
      clipEndMs: range.clipEndMs,
      stillFrameAtMs: range.stillFrameAtMs,
      sentence: range.sentence,
      cueSentence: range.cueSentence,
      updateNoteId: noteId,
    );
    if (result.ankiConnect) {
      if (!mounted || _currentEpisode != queuedEpisode) return result;
      _miningDraft.clear();
    }
    return result;
  }

  /// 制卡 `documentTitle`（渲染到 Anki `{document-title}`）。播放列表（[_isPlaylist]）
  /// 且系列名（[_playlistTitle]）非空时拼「系列名 - 剧集名」；单视频 / 远端退化为剧集名
  /// （[_title]）。纯拼接逻辑下沉到顶层 [composeVideoMiningDocumentTitle] 便于单测。
  String? _videoMiningDocumentTitle() => composeVideoMiningDocumentTitle(
        isPlaylist: _isPlaylist,
        playlistTitle: _playlistTitle,
        episodeTitle: _title,
      );

  /// 视频制卡/覆盖的落卡链路（单句 [onMineEntry]/[onUpdateEntry] 走这里）：把音频/封面
  /// 区间 `[clipStartMs, clipEndMs]`（单句即该 cue 的时间窗）抽成 GIF + 音频片段，配
  /// [sentence]/[cueSentence]/[fields] 经 [BaseAnkiRepository] 生成**一张**卡，回 OSD。
  /// [updateNoteId] 为空时新制一张（计入视频统计），非空时按 id 覆盖那张卡（不计入统计、
  /// 走 [BaseAnkiRepository.updateMinedNote]）。返回 [MinePopupResult]：成功带回 note id
  /// （新制时来自 addNote，覆盖时即 [updateNoteId]），让弹窗保持「最新可改」第三态。
  /// 区间非正（`clipEndMs <= clipStartMs`，如无 cue）时不抽媒体、回退当前帧截图作封面。
  Future<MinePopupResult> _mineVideoCard({
    required Map<String, String> fields,
    required int clipStartMs,
    required int clipEndMs,
    required int stillFrameAtMs,
    required String sentence,
    String? cueSentence,
    int? updateNoteId,
    VideoMiningHistorySnapshot? historySnapshot,
    void Function(MinePopupResult result)? onBackgroundLanded,
  }) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return const MinePopupResult();
    // 在线视频：弹窗等不等这张卡（见 [VideoOnlineMiningMode]）。覆盖已有卡片 / 回看会话
    // 要拿到落卡结果才有意义，恒等待；本地文件本就秒出，恒等待（= 改动前行为）。
    final VideoOnlineMiningMode onlineMode = resolveVideoOnlineMiningMode(
      preferred: appModel.videoOnlineMiningMode,
      mediaSource: controller.miningSource,
      overwrite: updateNoteId != null,
      sourceReview: _sourceReviewSession != null,
    );

    // 入队前立即冻结所有播放器/页面输入。换集会复用或 dispose controller，后续任务绝不能
    // 到真正出队时再读“当前集”。截图 Future 也在点击当下启动，current-frame 模式不会因
    // 本地 pushReplacement / 远端换流而截到下一集或访问已释放播放器。
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final MiningMediaCompression mediaCompression =
        MiningMediaCompression.resolve(
      imageTier: appModel.miningImageQuality,
      audioTier: appModel.miningAudioQuality,
      // 顶格档的动图参数随格式变（AVIF 源直通 / WebP·GIF 封顶），故必须把格式一并传进来
      // 解析——否则顶格档会拿到 GIF 的封顶值，用户选了 AVIF 也享受不到原图档。
      format: appModel.videoMiningAnimatedFormat,
    );
    String? mediaSource = controller.miningSource;
    final String? audioSource = controller.miningAudioSource;
    // BUG-2642 残留：在线视频源（扩展 hoster / 粘贴的流）常把 HLS 分片伪装成图片——
    // `.jpg` / `.image` 名、正文前垫一张 PNG。播放器经本机中继 + mpv 自己的放宽都能播，
    // 制卡 ffmpeg 直连原始地址则被扩展名白名单拒掉、或把分片认成一张图。改走与播放器
    // 同一条中继；地址当场改写（同步，保持点击顺序入队），登记在队列里等。
    // 媒体服务器同理，判据见 [videoMiningInputUsesPlaybackRelay]。
    Future<void>? mediaSourceRouteReady;
    if (mediaSource != null &&
        videoMiningInputUsesPlaybackRelay(
          remoteClient: _effectiveRemoteClient,
          mediaSource: mediaSource,
        )) {
      final ({String url, Future<void> ready}) relayed = relayFfmpegRemoteInput(
        mediaSource,
        isHls: controller.isHlsStream(),
        headers: _streamHttpHeaderFields,
      );
      mediaSource = relayed.url;
      mediaSourceRouteReady = relayed.ready;
    }
    final int? audioStreamIndex = controller.currentAudioStreamIndex;
    final int audioStreamCount = controller.realAudioStreamCount;
    final int episode = _currentEpisode;
    final SourceReviewSession? reviewSession = _sourceReviewSession;
    final (String sourceUid, int sourceEpisode) =
        _isRemote ? _remotePositionKeyForIndex(episode) : (widget.bookUid, 0);
    final String sourceId =
        reviewSession?.link.sourceId ?? CardSourceLink.newSourceId();
    final String? localSourcePath = controller.videoPath;
    // A still-only card has no subtitle range, but its source is the frame
    // being viewed now; it must not accidentally link to the start of the film.
    final int sourceStartMs = clipEndMs > clipStartMs
        ? clipStartMs
        : (controller.positionMs ?? clipStartMs);
    final int sourceEndMs = clipEndMs > clipStartMs ? clipEndMs : sourceStartMs;
    Future<CardSourceLink?> resolveSourceLink() async {
      if (!VideoSourceFingerprint.isLocalPath(localSourcePath)) return null;
      final String fingerprint =
          await VideoSourceFingerprint.instance.fingerprint(localSourcePath!);
      return CardSourceLink(
        kind: CardSourceKind.video,
        uid: sourceUid,
        sourceId: sourceId,
        episodeIndex: sourceEpisode,
        startMs: sourceStartMs,
        endMs: sourceEndMs,
        fingerprint: fingerprint,
      );
    }

    final String? documentTitle = _videoMiningDocumentTitle();
    final VideoMiningImageMode imageMode = appModel.videoMiningImageMode;
    final MiningAnimatedFormat animatedFormat =
        appModel.videoMiningAnimatedFormat;
    final MiningStillFormat stillFormat = appModel.videoMiningStillFormat;
    final String? bookTitleTag = appModel.autoAddBookNameToTags
        ? BaseAnkiRepository.sanitizeTitleTag(_title)
        : null;
    final String? collectionTag = appModel.autoAddBookNameToTags
        ? BaseAnkiRepository.sanitizeTitleTag(_playlistTitle)
        : null;
    final Future<Uint8List?> currentFrameSnapshot =
        controller.screenshot().catchError((Object error, StackTrace stack) {
      // 截图在入队时就启动，必须立刻接住异常；否则任务排队期间 Future 已失败会成为
      // unhandled async error。GIF/字幕起点帧路径仍可继续，截图只作为对应模式/兜底。
      try {
        ErrorLogService.instance.log(
          'mineVideoCard.snapshotCurrentFrame',
          error,
          stack,
        );
      } catch (_) {}
      return null;
    });
    // 不 await：先把本任务按点击顺序送进共享队列，轮到它时再解析临时目录。否则两个
    // 连续点击可能因 path_provider 返回先后不同而逆序入队。
    final Future<String> tempDir =
        getTemporaryDirectory().then((Directory value) => value.path);
    // 在线视频：这句多半刚播完、还在播放器缓冲里——点击当下就让播放器把它落成本地
    // 副本（落盘毫秒级），引擎对副本抽取，不再为音频和封面各开一次远端流。必须现在
    // 发起而不是等轮到本任务：那时缓冲可能已被挤掉、甚至已换集。分离音轨（YouTube）
    // 不在播放的这条流里，不落副本。拿不到副本引擎照旧远端抽取。
    final String? playbackSource = controller.miningSource;
    final Future<CachedMediaSnapshot?>? cachedSnapshot =
        playbackSource != null &&
                isNetworkStreamUri(playbackSource) &&
                audioSource == null &&
                clipEndMs > clipStartMs
            ? tempDir.then(
                (String dir) => controller.snapshotCachedRange(
                  startMs: math.min(clipStartMs, stillFrameAtMs),
                  endMs: clipEndMs,
                  outputPath: p.join(
                    dir,
                    'mine_snapshot_${DateTime.now().microsecondsSinceEpoch}.mkv',
                  ),
                ),
              )
            : null;
    // 统计 / 历史归属在点击当下冻结：后台落卡时页面可能已经关了。
    final FushiDatabase mineDb = appModel.database;
    final ({String bookKey, String title}) statIdentity =
        (bookKey: widget.bookUid, title: _title ?? '');
    // 看完再制卡：媒体照常备好，但交给暂存队列而不是 Anki（见 [VideoMineQueue]）。
    Future<MineOutcome> Function({
      required String rawPayloadJson,
      required AnkiMiningContext context,
    })? stageNote;
    if (onlineMode == VideoOnlineMiningMode.deferred) {
      final Future<VideoMineQueue> queueFuture = _videoMineQueue();
      final String queueBookUid = widget.bookUid;
      final String videoKey = '$sourceUid#$sourceEpisode';
      final VideoMineStagedMeta meta = VideoMineStagedMeta(
        documentTitle: _videoMiningDocumentTitle(),
        bookTitleTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(_title)
            : null,
        collectionTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(_playlistTitle)
            : null,
        statBookKey: statIdentity.bookKey,
        statTitle: statIdentity.title,
        recordHistory: historySnapshot != null,
        historyDateKey: historySnapshot?.dateKey ?? '',
        historyDocumentTitle: historySnapshot?.documentTitle,
        historyBookKey: historySnapshot?.bookKey,
        historySectionIndex: historySnapshot?.sectionIndex,
        historyCueStartMs: historySnapshot?.normCharOffset,
        historyCueLengthMs: historySnapshot?.normCharLength,
      );
      stageNote = ({
        required String rawPayloadJson,
        required AnkiMiningContext context,
      }) async {
        final VideoMineQueue queue = await queueFuture;
        await queue.stage(
          bookUid: queueBookUid,
          videoKey: videoKey,
          fields: decodeWebMineFields(rawPayloadJson),
          context: context,
          meta: meta,
        );
        return const MineOutcome.success();
      };
    }
    // BUG-891：远端 Hibiki 库视频的 miningSource 是自签 https 流 URL。把该 host 当前会话
    // 已 TOFU 钉扎的证书指纹带给引擎，使 ffmpeg（自编 ffmpeg-kit `--enable-gnutls` + pin
    // 补丁）按指纹接受自签流抽音频/帧，绕过「Protocol not found」。非 Hibiki host（本地 /
    // YouTube / 直链）为 null，不钉扎。
    final RemoteVideoClient? remoteClient = _effectiveRemoteClient;
    final String? mediaSourceTlsPin = remoteClient is InterconnectSyncBackend
        ? remoteClient.activeFingerprintSha256
        : null;
    // BUG-1004：互联 host（LAN Hibiki 库）远端流——注入「host 端裁音频段」裁切器：host 用
    // 本地文件裁好句子音频再经已鉴权/钉扎的下载通道回传，client 全程不用 ffmpeg 抓远端流，
    // 从根上绕开 client ffmpeg 打不开 host 自签 https/token 流的整类失败（BUG-891 pin 路径
    // 的残余缺口：移动端指纹缺失/URL 编码/网络脆弱仍 I/O error）。老 host 无 clipaudio 端点
    // → 404 → 裁切器返 null → 引擎回退现有 ffmpeg-over-URL 抽取。非 Hibiki host（本地/
    // YouTube/直链）不注入。
    final RemoteVideoInfo? remoteInfo = _effectiveRemoteInfo;
    Future<String?> Function({
      required int startMs,
      required int endMs,
      required String outputPath,
    })? remoteAudioClipper;
    if (remoteClient is InterconnectSyncBackend && remoteInfo != null) {
      final InterconnectSyncBackend backend = remoteClient;
      final String remoteId = remoteInfo.id;
      final int ac = mediaCompression.audioChannels;
      final String bitrate = mediaCompression.audioBitrate;
      remoteAudioClipper = ({
        required int startMs,
        required int endMs,
        required String outputPath,
      }) async {
        final File dest = File(outputPath);
        try {
          await backend.getRemoteVideoAudioClip(
            remoteId,
            dest,
            startMs: startMs,
            endMs: endMs,
            episodeIndex: episode,
            audioStreamIndex: audioStreamIndex,
            audioStreamCount: audioStreamCount,
            audioChannels: ac,
            audioBitrate: bitrate,
          );
          if (dest.existsSync() && dest.lengthSync() > 0) return dest.path;
        } catch (e, st) {
          // 老 host 无端点(404)/网络失败：记录并回 null，让引擎回退直连 ffmpeg 抽取。
          ErrorLogService.instance.log('mineVideoCard.remoteAudioClip', e, st);
        }
        if (dest.existsSync()) {
          try {
            dest.deleteSync();
          } catch (_) {}
        }
        return null;
      };
    }
    // TODO-1000：委托统一沉浸制卡引擎。媒体降级阶梯 / 无音频中止 / 组 context / 落卡都在
    // 引擎内；本壳只管 OSD + 视频统计。
    //
    // BUG-1205：两个失败摘要过去靠**同一个 onFailure 的调用顺序**区分（首个当 GIF、末个
    // 当音频）。引擎现在让封面与音频并行跑，顺序不再确定——改按来源取：封面失败进
    // [coverFailure]（喂「降级为静态」OSD 的原因），音频失败进 [audioFailure]（喂「无音频
    // 中止」OSD 的原因）。语义由参数名承载，不再依赖时序。
    String? coverFailure;
    String? audioFailure;
    final Future<ImmersionMiningResult> job = ImmersionMiningEngine().mine(
      ImmersionMiningRequest(
        fields: fields,
        mediaSource: mediaSource,
        audioSource: audioSource,
        mediaSourceTlsPinSha256: mediaSourceTlsPin,
        // BUG-2625：制卡源是远端流时，把**播放器取到这条流用的同一组防盗链请求头**
        // 一起交给引擎。在线视频源（Aniyomi 扩展）的 hoster 直链几乎都校验
        // Referer/UA，ffmpeg 裸请求会被 403（`required audio missing`）。本地文件与
        // 无防盗链源这里是空 map，抽取器据此 no-op，既有路径零影响。
        mediaSourceHttpHeaders: _streamHttpHeaderFields,
        mediaSourceRouteReady: mediaSourceRouteReady,
        // BUG-1004：互联 host 远端流句子音频优先走 host 端裁（绕开 client ffmpeg 抓远端流）。
        remoteAudioClipper: remoteAudioClipper,
        clipStartMs: clipStartMs,
        clipEndMs: clipEndMs,
        stillFrameAtMs: stillFrameAtMs,
        sentence: sentence,
        cueSentence: cueSentence,
        // TODO-761（方案 B）：播放列表下拼「系列名 - 剧集名」，单视频/远端仍是剧集名，零变化。
        documentTitle: documentTitle,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        // TODO-115：视频来源 → 卡片追加 `video` 分类标签。
        source: AnkiMiningSource.video,
        sourceLinkResolver: resolveSourceLink,
        sourceReviewMine: reviewSession == null
            ? null
            : ({
                required String rawPayloadJson,
                required AnkiMiningContext context,
              }) =>
                _mineSourceReview(
                  reviewSession,
                  rawPayloadJson: rawPayloadJson,
                  context: context,
                ),
        // TODO-681 / BUG-393：番名/标题作书名标签，开关关闭或无标题时 null 不追加。
        bookTitleTag: bookTitleTag,
        // 合集/系列名标签（同上开关）：播放列表下用系列名 _playlistTitle（col.name，已在内存）
        // 作独立 tag，与剧集名并列；单视频/远端无系列名时为 null 不追加。
        collectionTag: collectionTag,
        updateNoteId: updateNoteId,
        stillFallback: () => currentFrameSnapshot,
        // 用户在 Anki 设置里选的封面图片模式（GIF / 制卡时当前帧 / 字幕开头帧）；
        // 默认 gif=现状。静态模式引擎不置 degradedToStill，故不弹「降级为静态」OSD。
        imageMode: imageMode,
        // 动图编码格式（默认 AVIF）。引擎在编码失败时会自动降级 GIF 重试一次——旧版本
        // 包捆绑的 ffmpeg 没有 libsvtav1/libwebp，靠这条保证不会因换默认格式而制不出卡。
        animatedFormat: animatedFormat,
        // 静图编码格式（默认 JPG）：两种截图档与动图抽取失败后的静帧降级都走它。
        // 选 PNG 而捕绑 ffmpeg 缺编码器时引擎自动退回 JPG，不会因换格式而丢封面。
        stillFormat: stillFormat,
        // 在线视频的本地缓冲副本（拿不到就是 null，引擎远端抽取）。
        cachedMediaSnapshot: cachedSnapshot,
        // 看完再制卡：备好媒体后暂存，不落卡。
        stageNote: stageNote,
      ),
      compression: mediaCompression,
      tempDir: tempDir,
      repo: repo,
      // 各取首个摘要：同一来源多次回退（GIF→起点帧→当前帧）时，最先的那条最贴近根因。
      onCoverFailure: (String summary) => coverFailure ??= summary,
      onAudioFailure: (String summary) => audioFailure ??= summary,
    );
    MinePopupResult land(ImmersionMiningResult res) => _landVideoMine(
          res,
          coverFailure: coverFailure,
          audioFailure: audioFailure,
          staged: stageNote != null,
          overwrite: reviewSession != null || updateNoteId != null,
          recordStats: reviewSession == null,
          mineDb: mineDb,
          statIdentity: statIdentity,
        );
    if (onlineMode == VideoOnlineMiningMode.wait) return land(await job);
    // 后台 / 看完再制卡：弹窗不陪着等。结局（成功 / 暂存 / 失败）在落地时由 OSD 报告。
    _trackBackgroundMine(job.then((ImmersionMiningResult res) {
      final MinePopupResult landed = land(res);
      onBackgroundLanded?.call(landed);
    }));
    return const MinePopupResult.queued();
  }

  /// 一张视频卡落地后的收尾（OSD / 统计），等待与后台两条路共用。后台路径上页面可能
  /// 已经关了：OSD 自带 mounted 判断，统计用点击时冻结的 [mineDb] / [statIdentity]。
  ///
  /// [staged] = 看完再制卡：这次只是暂存成功，不是制卡成功——不记统计、报「已加入待制卡」，
  /// 回给调用方的是「未落卡」（不写制卡历史），真正的账在写入 Anki 时记。
  MinePopupResult _landVideoMine(
    ImmersionMiningResult res, {
    required String? coverFailure,
    required String? audioFailure,
    required bool staged,
    required bool overwrite,
    required bool recordStats,
    required FushiDatabase mineDb,
    required ({String bookKey, String title}) statIdentity,
  }) {
    // BUG-296 / TODO-390：应带句子音频却抽取失败 → 显式 OSD + 中止，不建无音频卡。
    if (res.aborted) {
      if (mounted) {
        _showOsd(
          t.card_export_failed_detail(
            reason: res.abortReason ??
                (audioFailure == null
                    ? 'sentence audio export failed'
                    : 'sentence audio export failed: $audioFailure'),
          ),
          severity: ToastSeverity.error,
        );
      }
      return const MinePopupResult();
    }
    // W2a：动图降级为静态帧时可感知 OSD（原因取 GIF 失败摘要，最贴近根因）。
    if (res.degradedToStill && mounted) {
      _showOsd(
        t.card_cover_degraded_to_static(
          reason: coverFailure ?? 'animated clip unavailable',
        ),
        severity: ToastSeverity.warning,
      );
    }
    final MineOutcome outcome = res.outcome! as MineOutcome;
    if (staged) {
      // 看完再制卡：只是进了待制卡列表。统计 / 历史等写入 Anki 时再记。
      if (outcome.result == MineResult.success) unawaited(_onVideoMineStaged());
      return const MinePopupResult();
    }
    final MinePopupResult result = outcome.result == MineResult.success
        ? MinePopupResult(ankiConnect: true, noteId: outcome.noteId)
        : MinePopupResult.failed(outcome);
    // 牌组名由后端随成功结果带回（outcome.deckName，BUG-1549）。
    // overwrite=true（updateNoteId 非空）→ 收口产 card_overwritten + record=false；
    // 新制 → card_exported + record=true（消息/记账判定统一在 describeMineOutcome）。
    final described = describeMineOutcome(outcome, overwrite: overwrite);
    // 新制成功计入视频统计（dictionarySourceType=video）；覆盖 record=false 故不记账。
    // 本页覆写了 onMineEntry、绕过基类成功分支，故在此显式记账（与 mixin 的
    // recordMined 同一次 DB 写入）。用点击时冻结的库与归属：后台制卡落地时页面可能
    // 已经关了，卡进了 Anki，账也得记上。
    if (described.record && recordStats) {
      unawaited(_recordVideoMineStat(mineDb, statIdentity));
    }
    // State 的 `mounted`，不是 `context.mounted`：后台落地时页面可能早已 unmount，
    // 那时连取 `context` 都会抛（debug FlutterError / release 空检查），落地回调
    // （写制卡历史）就跟着没了，还会记一条假失败。
    if (!mounted) return result;
    // TODO-971：制卡成功（card_exported / card_overwritten，含牌组名）走突出 OSD——
    // 居中、更大、停留更久，区别于音量/亮度小角标，避免用户「制卡了没反馈」。
    // describeMineOutcome 早就算出了 status，此前只被拿去选 prominent 布尔、颜色
    // 整个丢掉，于是视频页制卡成功与失败长得一模一样。透传语义即可对齐其它入口。
    _showOsd(
      described.message,
      prominent: true,
      severity: mineToastSeverity(described.status),
    );
    return result;
  }

  /// 视频制卡的统计记账（= [DictionaryPageMixin.recordMined] 对视频来源的那一次写入），
  /// 但不经 `ref`：后台落卡时页面可能已经销毁。best-effort，失败吞掉。
  Future<void> _recordVideoMineStat(
    FushiDatabase db,
    ({String bookKey, String title}) identity,
  ) async {
    try {
      await db.recordMiningEvent(
        bookKey: identity.bookKey,
        title: identity.title,
        sourceType: kStatSourceVideo,
        at: DateTime.now(),
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] video recordMiningEvent failed: $e\n$st');
    }
  }

  /// TODO-633: land one mined-sentence history row for a video card. Locator
  /// anchors mirror _toggleFavoriteSentenceForVideo (bookUid + episode +
  /// cue.startMs/duration) so collections reuses _openVideoSentence to jump back.
  /// Best-effort; failure is swallowed + logged (does not break mining).
  Future<void> _recordMinedSentenceForVideo(
    VideoMiningHistorySnapshot snapshot,
    int? noteId, {
    FushiDatabase? db,
  }) async {
    try {
      await (db ?? appModel.database).addMinedSentence(
        source: kStatSourceVideo,
        dateKey: snapshot.dateKey,
        expression: snapshot.expression,
        reading: snapshot.reading,
        glossary: snapshot.glossary,
        sentence: snapshot.sentence,
        documentTitle: snapshot.documentTitle,
        bookKey: snapshot.bookKey,
        sectionIndex: snapshot.sectionIndex,
        normCharOffset: snapshot.normCharOffset,
        normCharLength: snapshot.normCharLength,
        noteId: noteId,
      );
    } catch (e, st) {
      debugPrint('[fushi-stats] video addMinedSentence failed: $e\n$st');
    }
  }
}

/// 制卡 ffmpeg 的远端输入是否改走本机中继（与播放器同一条取流路径）。
///
/// - 在线视频源（[RemoteVideoStreamHeaders]：扩展 hoster / 粘贴的流）：BUG-2642 残留，
///   伪装成图片的 HLS 分片只有中继 + 放开扩展名才读得动。
/// - 媒体服务器（[MediaServerBrowser]：Emby / Jellyfin）：BUG-2692。播放器早就经
///   [nativePlaybackUri] 走中继（Dart 的 TLS + 应用代理），制卡 ffmpeg 却直连原始
///   https——移动端 ffmpeg-kit 用自己编进去的 TLS、也不认应用代理，于是「能播放、
///   制不了卡」，截图 / 动图 / 句子音频三条抽取全报 `I/O error`。
/// - 互联主机**不在此列**：它有指纹钉扎（`-tls_pin_sha256` 只对 https 输入有效，
///   改成中继的明文地址反而让 ffmpeg 报选项不认）与 host 端裁音频两条专用通道。
/// - 本地文件 / YouTube（没有远端 client）不改道。
bool videoMiningInputUsesPlaybackRelay({
  required RemoteVideoClient? remoteClient,
  required String mediaSource,
}) {
  if (!isNetworkStreamUri(mediaSource)) return false;
  return remoteClient is RemoteVideoStreamHeaders ||
      remoteClient is MediaServerBrowser;
}

/// 纯函数：据是否播放列表 + 系列名 + 剧集名算制卡 `documentTitle`（TODO-761，方案 B）。
///
/// - 播放列表且系列名非空 → 「系列名 - 剧集名」（剧集名为空时只回系列名，避免尾随分隔符）。
/// - 单视频 / 远端 / 系列名为空（[isPlaylist] 假或 [playlistTitle] 空）→ 原 [episodeTitle]，
///   向后兼容零变化。
/// 分隔符固定 " - "（与卡片标题习惯一致）；不做系列名==剧集名去重（避免过度设计）。
String? composeVideoMiningDocumentTitle({
  required bool isPlaylist,
  required String? playlistTitle,
  required String? episodeTitle,
}) {
  if (!isPlaylist || playlistTitle == null || playlistTitle.isEmpty) {
    return episodeTitle;
  }
  if (episodeTitle == null || episodeTitle.isEmpty) {
    return playlistTitle;
  }
  return '$playlistTitle - $episodeTitle';
}
