part of '../video_fushi_page.dart';

/// 缩略图宽度（px）：对话框里首尾帧 / 查词时画面的预览，不是卡上的图。
const int _kAdvancedMiningThumbWidth = 320;

/// 在线流在对话框打开时落缓冲副本的前后余量（毫秒）：逐帧挪动与起止微调都会越出
/// 句子窗一点，余量内的帧仍从本地副本抽。
const int _kAdvancedMiningSnapshotMarginMs = 3000;

/// 每个对话框会话最多缓存的缩略图张数（逐帧挪动一次一张，超出按最早的先丢）。
const int _kAdvancedMiningMaxCachedFrames = 48;

/// 读 Anki 模板能否渲染视频片段的上限。这只决定对话框里要不要列出「视频片段」：
/// Anki 没开 / 主机不可达时探测可能挂很久，对话框不能为它卡住；判定不了按「可能
/// 支持」列出，落卡前引擎还会按目标模板再判一次（[resolveTargetMiningImageMode]）。
const Duration _kAdvancedMiningTemplateProbeTimeout = Duration(
  milliseconds: 1500,
);

/// 一次「高级制卡」对话框会话的视频侧状态：从 [buildAdvancedMiningSections] 到对话框
/// onClosed。
///
/// 为什么要单独一个会话对象而不是几个页面字段：确认制卡发生在对话框关闭**之前**
/// （视频车道 `releaseWhenPayloadConsumed: true`），制卡的同步前缀要读到「本次对话框」
/// 锁住的那一帧与那份缓冲副本；而对话框关闭后这些必须立刻失效，不能被下一次普通「+」
/// 读走。会话对象让「属于哪一次对话框」有了身份（[closed] / 页面字段换成 null）。
class _VideoAdvancedMiningSession {
  _VideoAdvancedMiningSession({
    required this.controller,
    required this.lookupFrame,
    required this.lookupPositionMs,
  });

  /// 打开对话框时的播放器。换集（换控制器）后本会话的一切都不再适用。
  final VideoPlayerController controller;

  /// 对话框打开那一刻（任何试听之前）截下的画面 = 查词时画面。已接住异常。
  final Future<Uint8List?> lookupFrame;

  /// 查词时的播放位置（播放器轴）。
  final int? lookupPositionMs;

  /// 对话框里试听过（挪动过播放头）：关闭时要把播放头放回 [lookupPositionMs]。
  bool previewed = false;

  /// 对话框已关闭：锁帧 / 副本 / 缩略图都不再交出去。
  bool closed = false;

  Future<CachedMediaSnapshot?>? _snapshot;
  int _snapshotStartMs = 0;
  int _snapshotEndMs = 0;
  bool _snapshotHandedOff = false;

  final Map<int, Future<Uint8List?>> _frames = <int, Future<Uint8List?>>{};

  /// 缩略图抽取串行化：逐帧连点时同一时刻只跑一个 ffmpeg。
  Future<void> _frameTail = Future<void>.value();

  /// 在线流：对话框打开时落的本地缓冲副本（播放器轴 [startMs, endMs]）。
  void attachSnapshot(
    Future<CachedMediaSnapshot?> snapshot, {
    required int startMs,
    required int endMs,
  }) {
    _snapshot = snapshot;
    _snapshotStartMs = startMs;
    _snapshotEndMs = endMs;
  }

  /// 缩略图的抽取源（在线流）；没有副本时 null。
  Future<CachedMediaSnapshot?>? get snapshotForFrames => _snapshot;

  /// 把副本交给这次制卡（引擎用完即删）。覆盖不了写卡要抽的整段、已经交出去过、或
  /// 会话已关闭时返回 null，调用方照旧在确认那一刻另落副本。
  Future<CachedMediaSnapshot?>? takeSnapshotCovering({
    required int clipStartMs,
    required int clipEndMs,
    required int stillFrameAtMs,
  }) {
    final Future<CachedMediaSnapshot?>? snapshot = _snapshot;
    if (snapshot == null || _snapshotHandedOff || closed) return null;
    if (!advancedMiningSnapshotCovers(
      coveredStartMs: _snapshotStartMs,
      coveredEndMs: _snapshotEndMs,
      clipStartMs: clipStartMs,
      clipEndMs: clipEndMs,
      stillFrameAtMs: stillFrameAtMs,
    )) {
      return null;
    }
    _snapshotHandedOff = true;
    return snapshot;
  }

  /// 取 [atMs] 的缩略图：同一时刻只抽一次（单飞 + 按时刻缓存），抽取串行。
  Future<Uint8List?> frame(
    int atMs,
    Future<Uint8List?> Function(int atMs) extract,
  ) {
    final Future<Uint8List?>? cached = _frames[atMs];
    if (cached != null) return cached;
    final Future<Uint8List?> run = _frameTail.then<Uint8List?>(
      (void _) => closed ? Future<Uint8List?>.value() : extract(atMs),
    );
    _frameTail = run.then<void>((Uint8List? _) {}, onError: (Object _) {});
    _frames[atMs] = run;
    if (_frames.length > _kAdvancedMiningMaxCachedFrames) {
      _frames.remove(_frames.keys.first);
    }
    return run;
  }

  /// 会话结束：缩略图缓存清掉；副本没交给制卡就删掉（交出去的归引擎删）。
  void release() {
    if (closed) return;
    closed = true;
    _frames.clear();
    final Future<CachedMediaSnapshot?>? snapshot = _snapshot;
    _snapshot = null;
    if (snapshot == null || _snapshotHandedOff) return;
    unawaited(
      snapshot.then<void>((CachedMediaSnapshot? value) {
        if (value == null) return;
        try {
          final File file = File(value.path);
          if (file.existsSync()) file.deleteSync();
        } on FileSystemException catch (e) {
          debugPrint('[video] advanced mining snapshot cleanup failed: $e');
        }
      }, onError: (Object _) {}),
    );
  }
}

/// 「高级制卡」对话框的视频车道实现（契约见 [AdvancedMiningSections]）。
extension _VideoAdvancedMining on _VideoFushiPageState {
  /// 本页正开着的、属于 [controller] 的对话框会话；没有 / 已关闭 / 已换集时 null。
  _VideoAdvancedMiningSession? _advancedMiningSessionFor(
    VideoPlayerController controller,
  ) {
    final _VideoAdvancedMiningSession? session = _advancedMiningSession;
    if (session == null || session.closed) return null;
    return identical(session.controller, controller) ? session : null;
  }

  /// [buildAdvancedMiningSections] 的实现。**首个 await 之前**锁住查词画面：对话框里
  /// 的试听会挪动播放头，确认制卡时现场截图就不再是用户查词时看到的那一帧。
  Future<AdvancedMiningSections> _buildAdvancedMiningSectionsImpl() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return AdvancedMiningSections.none;
    final Future<Uint8List?> lookupFrame = controller.screenshot().then(
      (Uint8List? bytes) => bytes,
      onError: (Object error, StackTrace stack) {
        // 锁帧在对话框打开时就启动，必须当场接住异常（同 [_mineVideoCard] 的截图）。
        ErrorLogService.instance.log(
          'advancedMining.lockLookupFrame',
          error,
          stack,
        );
        return null;
      },
    );
    _advancedMiningSession?.release();
    final _VideoAdvancedMiningSession session = _VideoAdvancedMiningSession(
      controller: controller,
      lookupFrame: lookupFrame,
      lookupPositionMs: _lastLookupPositionMs ?? controller.positionMs,
    );
    _advancedMiningSession = session;

    // 句子分区：与原「调整上下文」对话框同一组宿主回调（草稿在本页）。
    final AdvancedMiningSentenceSection sentence =
        AdvancedMiningSentenceSection(
          fetchPreview: () async => buildSentenceContextPreview(
            draft: _miningDraft,
            current: _lastLookupSentence,
            currentOffset: null,
          ),
          setContext: _setSentenceContextToDraft,
          editSentence: _editSentenceContextText,
          removeSentence: _removeSentenceContext,
        );
    Future<void> onClosed() => _closeAdvancedMiningSession(session);
    // 蓝光导航会话禁止抽取时整张卡都制不了（[_mineVideoCard] 同一道门），音频 / 图片
    // 分区没有意义。
    if (!_discExtractionAllowed(controller)) {
      return AdvancedMiningSections(sentence: sentence, onClosed: onClosed);
    }

    final VideoMiningRange range = _resolveVideoMiningRange(controller);
    final bool hasClipWindow = range.clipEndMs > range.clipStartMs;
    final String? source = controller.miningSource;
    final bool networkSource = source != null && isNetworkStreamUri(source);
    final String? localSource =
        source != null &&
            !networkSource &&
            p.isAbsolute(source) &&
            // async：本地视频可能在网络盘上，同步 stat 会冻结 UI isolate（BUG-3756）。
            await File(source).exists()
        ? source
        : null;
    // 在线流：缩略图没法对远端逐帧开流，趁这句还在播放器缓冲里落一份本地副本（与制卡
    // 同一个 dump-cache），缩略图从副本抽；确认制卡时够用就把同一份交给引擎。
    if (hasClipWindow && networkSource) {
      final int startMs = math.max(
        0,
        math.min(range.clipStartMs, range.stillFrameAtMs) -
            _kAdvancedMiningSnapshotMarginMs,
      );
      final int endMs = range.clipEndMs + _kAdvancedMiningSnapshotMarginMs;
      session.attachSnapshot(
        getTemporaryDirectory()
            .then(
              (Directory dir) => controller.snapshotCachedRange(
                startMs: startMs,
                endMs: endMs,
                outputPath: p.join(
                  dir.path,
                  'advanced_mining_${DateTime.now().microsecondsSinceEpoch}.mkv',
                ),
              ),
            )
            .then(
              (CachedMediaSnapshot? value) => value,
              onError: (Object _) => null,
            ),
        startMs: startMs,
        endMs: endMs,
      );
    }

    // ref 只在同步前缀里读：下面的 await 期间页面可能已卸载。
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final double? fps = await controller.containerFps();
    final bool? templateRendersClip = hasClipWindow
        ? await probeSynchronizedClipSupport(
            repo,
          ).timeout(_kAdvancedMiningTemplateProbeTimeout, onTimeout: () => null)
        : null;
    if (!mounted || session.closed) {
      session.release();
      return AdvancedMiningSections.none;
    }

    final List<VideoMiningImageMode> modes = advancedMiningVideoImageModes(
      hasClipWindow: hasClipWindow,
      hasMediaSource: source != null,
      templateRendersClip: templateRendersClip,
    );
    Future<Uint8List?> frameAt(int atMs) {
      final int? lookupMs = session.lookupPositionMs;
      if (lookupMs != null && atMs == lookupMs) return session.lookupFrame;
      if (localSource == null && session.snapshotForFrames == null) {
        return Future<Uint8List?>.value();
      }
      return session.frame(
        atMs,
        (int ms) => _extractAdvancedMiningFrame(session, ms, localSource),
      );
    }

    return AdvancedMiningSections(
      sentence: sentence,
      audio: AdvancedMiningAudioSection(
        describe: (int startDeltaMs, int endDeltaMs) async =>
            identical(_controller, controller)
            ? _videoMiningAudioWindow(
                controller,
                startDeltaMs: startDeltaMs,
                endDeltaMs: endDeltaMs,
              )
            : null,
        preview: (int startDeltaMs, int endDeltaMs) =>
            identical(_controller, controller)
            ? _previewVideoMiningAudio(
                startDeltaMs: startDeltaMs,
                endDeltaMs: endDeltaMs,
              )
            : Future<RangePlayback?>.value(),
        stopPreview: () async {
          if (identical(_controller, controller)) {
            await controller.stopPlayRange();
          }
        },
      ),
      videoImage: AdvancedMiningVideoImageSection(
        modes: modes,
        defaultMode: advancedMiningDefaultVideoImageMode(
          appModel.videoMiningImageMode,
          modes,
        ),
        frameAt: frameAt,
        frameStepMs: videoFrameStepMsForFps(fps),
        lookupFrameMs: session.lookupPositionMs,
        // 未留白的句首（播放器轴），与「字幕开头」写卡时的取帧时刻同一个值。
        subtitleStartMs: hasClipWindow ? range.stillFrameAtMs : null,
      ),
      onClosed: onClosed,
    );
  }

  /// 抽一张缩略图：本地文件直接抽，在线流从对话框副本抽（副本 0 点 = 播放器轴
  /// `zeroMs`，见 [CachedMediaSnapshot]）。失败一律 null，不打断对话框。
  Future<Uint8List?> _extractAdvancedMiningFrame(
    _VideoAdvancedMiningSession session,
    int atMs,
    String? localSource,
  ) async {
    String? input = localSource;
    int zeroMs = 0;
    if (input == null) {
      final CachedMediaSnapshot? snapshot = await session.snapshotForFrames;
      if (snapshot == null) return null;
      input = snapshot.path;
      zeroMs = snapshot.zeroMs;
    }
    if (session.closed) return null;
    final Directory dir = await getTemporaryDirectory();
    final String output = p.join(
      dir.path,
      'advanced_mining_frame_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      final String? produced = await extractVideoFrameViaFfmpeg(
        inputPath: input,
        outputPath: output,
        atSeconds: math.max(0, atMs - zeroMs) / 1000.0,
        scaleWidth: _kAdvancedMiningThumbWidth,
        // 预览缩略图取不到（副本被引擎用完删掉、落在空洞）是预期内的，不进错误日志。
        diagnosticOnly: true,
      );
      if (produced == null) return null;
      return await File(produced).readAsBytes();
    } on FileSystemException catch (e) {
      debugPrint('[video] advanced mining frame read failed: $e');
      return null;
    } finally {
      try {
        final File file = File(output);
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException catch (_) {}
    }
  }

  /// 对话框关闭（确认或取消）：释放会话；试听挪过播放头的，停试听并把播放头放回
  /// 查词位置（保持暂停）——用户回到的仍是查词时那一帧。
  Future<void> _closeAdvancedMiningSession(
    _VideoAdvancedMiningSession session,
  ) async {
    if (session.closed) return;
    final bool previewed = session.previewed;
    session.release();
    if (identical(_advancedMiningSession, session)) {
      _advancedMiningSession = null;
    }
    final VideoPlayerController controller = session.controller;
    if (!previewed || !mounted || !identical(_controller, controller)) return;
    await controller.stopPlayRange();
    final int? lookupMs = session.lookupPositionMs;
    if (lookupMs != null) await controller.seekMs(lookupMs);
  }

  /// 退页：丢掉还开着的会话（副本删掉），不碰播放器。
  void _discardAdvancedMiningSession() {
    _advancedMiningSession?.release();
    _advancedMiningSession = null;
  }
}
