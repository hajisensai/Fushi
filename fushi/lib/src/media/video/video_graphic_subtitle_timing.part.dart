part of 'video_player_controller.dart';

// 图形字幕（PGS / VobSub / DVB，libmpv 自绘）的逐句时间表：两条来源合成一张表。
//
// 1. **边播边记**（任何播放源、任何位图编码都成立，零额外读流）：libmpv 的位图解码
//    驱动 `sd_lavc` 实现了 `get_times`，画面上有位图时 `sub-start` / `sub-end` 就是
//    那句在字幕时基上的起止（mpv `player/command.c` 的 `get_times` →
//    `sub/dec_sub.c` `sub_get_times` → `sub/sd_lavc.c` `get_times`），且这两个属性
//    挂在 `MPV_EVENT_TICK` 的属性变化表里，可以事件式观测。每出现一句就记一句。
// 2. **整轨抽取**（权威、覆盖整条轨）：按播放源分型取数——本地文件 ffmpeg 读盘；
//    互联 host 有原文件，由 host 抽好整轨只回传几百 KB（client 不读整片）；媒体服务器 /
//    通用 http / 在线源解析出的直链按 URL + 播放器同一份请求头交给 ffmpeg 读流抽轨
//    （与模糊遮蔽层同一个 [FfmpegGraphicSubtitleRegionLoader] 在途任务 / 缓存）。
//
// 观测走比值订阅 `observePropertyChanges`（`MPV_FORMAT_STRING`，media_kit 补丁，
// BUG-3315）：mpv 在核心里比值，只有起止真的变了才来事件，值随事件到达。属性不可用
// （句间空档）时 mpv 只发一次无格式事件、读出 null，监听者不被调用；结束未知的一句由
// 下一句起点收尾——这正是 `sd_lavc` 自己的规则（解到下一句时 `prev->endpts = pts`）。
//
// 抽取结果到了以后以它为准，边播边记只补它没有的句子
// （[mergeGraphicSubtitleTimingTables]）。

/// 观测哪些 mpv 属性来边播边记：起点变 = 换句；结束变 = 同一句的结束段解码出来了。
const List<String> kGraphicSubtitleLiveTimingProperties = <String>[
  'sub-start',
  'sub-end',
];

/// 图形字幕整轨时间表的取数输入，按播放源分型。[streamIndex] 恒为**容器内字幕轨**
/// 的 0 基序号（ffmpeg `0:s:N`，与 libmpv 去掉 auto/no 后的下标同构）。
sealed class GraphicSubtitleTimingInput {
  const GraphicSubtitleTimingInput({
    required this.streamIndex,
    required this.codec,
  });

  final int streamIndex;

  /// 轨编码（`hdmv_pgs_subtitle` / `dvd_subtitle` / `dvb_subtitle` …）。
  final String? codec;
}

/// ffmpeg 直接读的输入：本地文件，或网络流（媒体服务器直出、通用 http、在线源解析出
/// 的直链）的 URL + 请求头。请求头与交给 libmpv 的 `http-header-fields` 是同一份
/// （防盗链 Referer / UA / Cookie），地址是交给播放器之前的原始流地址。
final class GraphicSubtitleTimingStream extends GraphicSubtitleTimingInput {
  const GraphicSubtitleTimingStream({
    required this.input,
    required super.streamIndex,
    required super.codec,
  });

  final GraphicSubtitleInput input;
}

/// host 回传的整轨：抽出的载荷 + 轨头（VobSub 调色板 / DVB 页号等 extradata；PGS 可无）。
typedef GraphicSubtitleHostTrackFiles = ({File payload, File? header});

/// 取回 host 已抽好的整轨（互联：host 有原文件）。拿不到（老 host 无端点 / host 抽取
/// 失败 / 断网）返回 null。文件归控制器处置：解析完即删除。
typedef GraphicSubtitleHostTrackDownload =
    Future<GraphicSubtitleHostTrackFiles?> Function();

/// 远端 host 已在本机抽好的整轨：client 只下几百 KB，不为字幕读整片。
final class GraphicSubtitleTimingHostTrack extends GraphicSubtitleTimingInput {
  const GraphicSubtitleTimingHostTrack({
    required this.download,
    required super.streamIndex,
    required super.codec,
  });

  final GraphicSubtitleHostTrackDownload download;
}

/// host 回传的整轨 → 位图时间表的接口形状（测试替换用）。
typedef GraphicSubtitleTrackFileRegionLoad =
    Future<GraphicSubtitleRegionTrack?> Function(
      GraphicSubtitleHostTrackFiles files, {
      required Size fallbackCanvas,
    });

/// 生产实现：host 回传的整轨 → 位图时间表。轨头放到载荷旁的约定位置
/// （[bitmapSubtitleTrackHeaderPath]）后与本地抽轨产物同一条解码路径
/// （[readGraphicSubtitleTrackInBackground]，后台 isolate，PGS / VobSub / DVB 通吃）。
/// 认不出 / 解不出返回 null。
Future<GraphicSubtitleRegionTrack?> loadGraphicSubtitleRegionsFromTrackFile(
  GraphicSubtitleHostTrackFiles files, {
  required Size fallbackCanvas,
}) async {
  final File? header = files.header;
  final String headerPath = bitmapSubtitleTrackHeaderPath(files.payload.path);
  if (header != null && header.path != headerPath && header.existsSync()) {
    header.renameSync(headerPath);
  }
  final List<BitmapSubtitleCue> cues =
      await readGraphicSubtitleTrackInBackground(
        files.payload.path,
        complete: true,
      );
  if (cues.isEmpty) return null;
  return graphicSubtitleRegionsFromCues(cues, fallbackCanvas: fallbackCanvas);
}

/// 按 [input] 把整轨载荷落到 [outputPath]（旁边带轨头，[bitmapSubtitleTrackHeaderPath]），
/// 供 [readGraphicSubtitleTrackInBackground] 解码——整轨 OCR 与逐句时间表同一个取数口径：
/// - [GraphicSubtitleTimingStream]：ffmpeg 读本地文件 / 网络流（带播放会话请求头）抽轨，
///   边抽边写（[onProgress] / [cancel] 照常生效）；
/// - [GraphicSubtitleTimingHostTrack]：下载 host 抽好的整轨（互联：client 绝不整片读流），
///   下完一次性落位。下载本身不可中途撤销，[cancel] 在落位前生效。
///
/// 成功返回 true；失败 / 取消返回 false（失败摘要交 [onFailure]，取消不报）。
Future<bool> materializeGraphicSubtitleTrack({
  required GraphicSubtitleTimingInput input,
  required String outputPath,
  Future<void>? cancel,
  void Function(Duration processed)? onProgress,
  void Function(String summary)? onFailure,
}) async {
  switch (input) {
    case GraphicSubtitleTimingStream():
      return extractGraphicSubtitleTrack(
        input: input.input,
        streamIndex: input.streamIndex,
        outputPath: outputPath,
        codec: input.codec,
        cancel: cancel,
        onProgress: onProgress,
        onFailure: onFailure,
      );
    case GraphicSubtitleTimingHostTrack():
      bool cancelled = false;
      unawaited(cancel?.then((_) => cancelled = true));
      final GraphicSubtitleHostTrackFiles? files = await input.download();
      if (files == null) {
        if (!cancelled) onFailure?.call('host track download failed');
        return false;
      }
      final File? downloadedHeader = files.header;
      final List<File> downloaded = <File>[
        files.payload,
        if (downloadedHeader != null) downloadedHeader,
      ];
      try {
        if (cancelled || !files.payload.existsSync()) return false;
        final File out = File(outputPath);
        out.parent.createSync(recursive: true);
        // 轨头先于载荷落位：读者拿到载荷时必须已经知道怎么解它。
        if (downloadedHeader != null && downloadedHeader.existsSync()) {
          downloadedHeader.copySync(bitmapSubtitleTrackHeaderPath(outputPath));
        }
        files.payload.copySync(outputPath);
        return out.lengthSync() > 0;
      } on FileSystemException catch (e) {
        onFailure?.call('host track: ${e.message}');
        return false;
      } finally {
        for (final File f in downloaded) {
          try {
            if (f.existsSync()) f.deleteSync();
          } on FileSystemException {
            // 临时文件留给系统清理。
          }
        }
      }
  }
}

/// 按当前播放源推导整轨时间表的取数输入（互联 host 走调用方显式给的
/// [GraphicSubtitleTimingHostTrack]，不经这里）：
/// - [videoPath] 是本地路径 → 本地文件；
/// - 否则 [mediaUri] 是 http(s) → 网络流（带 [httpHeaders]）；
/// - 其余（`edl://` 拼接、`bd://` 菜单、无源）→ null，时间表只靠边播边记。
GraphicSubtitleTimingInput? graphicSubtitleTimingInputForSource({
  required String? videoPath,
  required String? mediaUri,
  required Map<String, String> httpHeaders,
  required int streamIndex,
  required String? codec,
}) {
  if (videoPath != null && videoPath.isNotEmpty) {
    final GraphicSubtitleInput local = GraphicSubtitleInput.local(videoPath);
    if (local.isSupported && !local.isRemote) {
      return GraphicSubtitleTimingStream(
        input: local,
        streamIndex: streamIndex,
        codec: codec,
      );
    }
  }
  if (mediaUri == null) return null;
  final GraphicSubtitleInput remote = GraphicSubtitleInput(
    uri: mediaUri,
    headers: Map<String, String>.unmodifiable(httpHeaders),
  );
  if (!remote.isRemote) return null;
  return GraphicSubtitleTimingStream(
    input: remote,
    streamIndex: streamIndex,
    codec: codec,
  );
}

extension VideoGraphicSubtitleTimingController on VideoPlayerController {
  /// 新的一条图形轨 / 换片 / 销毁：两张表、暂定句、在途抽取一起作废。
  void _resetGraphicTimingTables() {
    _graphicExtractedTimingCues = const <AudioCue>[];
    _graphicLiveTimingCues = const <AudioCue>[];
    _graphicTimingCues = const <AudioCue>[];
    _graphicLiveProvisionalCue = null;
    _graphicTimingGeneration++;
    _graphicLiveGeneration++;
    _graphicTimingInputOverride = null;
    _graphicRegionTrack.value = null;
    _cancelGraphicTimingFetch();
  }

  /// 结束在途的整轨抽取（网络流的抽取要读整条流，换轨 / 换片 / 离开图形模式不能让它
  /// 继续占带宽）。
  void _cancelGraphicTimingFetch() {
    final Completer<void>? cancel = _graphicTimingCancel;
    _graphicTimingCancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  void _recomputeGraphicTimingCues() {
    _graphicTimingCues = mergeGraphicSubtitleTimingTables(
      extracted: _graphicExtractedTimingCues,
      live: _graphicLiveTimingCues,
    );
  }

  /// 每个 Player 只挂一次观测（media_kit 同一属性只允许一个监听者，且 Player 销毁时
  /// 观测随之释放）；监听里只发起一次「读当前句」，是否还在图形模式、是不是当前片由
  /// 采样自己判。
  Future<void> _ensureGraphicLiveObserver(Player player) async {
    if (identical(_graphicLiveObservedPlayer, player)) return;
    final dynamic native = player.platform;
    if (native == null) return;
    _graphicLiveObservedPlayer = player;
    for (final String property in kGraphicSubtitleLiveTimingProperties) {
      try {
        // 比值订阅：这两个属性挂在 `MPV_EVENT_TICK` 上，无格式的 `observeProperty` 会
        // 每帧来一次事件、且每次先同步读一次属性（拿 mpv 核心锁）；比值订阅只在真的换句 /
        // 结束段到了时才来（BUG-3315）。
        await native.observePropertyChanges(property, (String _) async {
          if (!identical(_player, player)) return;
          _requestGraphicLiveSample(player);
        }, waitForInitialization: false);
      } catch (error) {
        // 观测挂不上（Player 已销毁等）：时间表仍有整轨抽取那条来源。
        debugPrint('[fushi] graphic subtitle observe $property failed: $error');
      }
    }
  }

  /// 合并突发事件：采样进行中再来事件只记一笔「再读一次」，读完补读，不并发读属性。
  void _requestGraphicLiveSample(Player player) {
    if (!_graphicSubtitleActive) return;
    if (_graphicLiveSampleRunning) {
      _graphicLiveSampleAgain = true;
      return;
    }
    _graphicLiveSampleRunning = true;
    unawaited(_runGraphicLiveSamples(player));
  }

  Future<void> _runGraphicLiveSamples(Player player) async {
    try {
      do {
        _graphicLiveSampleAgain = false;
        await _sampleGraphicLiveTiming(player);
      } while (_graphicLiveSampleAgain &&
          identical(_player, player) &&
          _graphicSubtitleActive);
    } finally {
      _graphicLiveSampleRunning = false;
    }
  }

  /// 读 mpv 当前句的起止并记进表。起止是两次独立读取：读完再核对一次起点，换句了
  /// 就丢弃这对（结束属于下一句）并补读。读取期间换片 / 换轨 / 离开图形模式一律作废。
  Future<void> _sampleGraphicLiveTiming(Player player) async {
    if (!_graphicSubtitleActive) return;
    final int loadToken = _loadToken;
    final int liveGeneration = _graphicLiveGeneration;
    final String rawStart = await _getMpvProperty('sub-start');
    final String rawEnd = await _getMpvProperty('sub-end');
    final String confirm = await _getMpvProperty('sub-start');
    if (!_isCurrentLoad(player, loadToken) ||
        liveGeneration != _graphicLiveGeneration ||
        !_graphicSubtitleActive) {
      return;
    }
    if (confirm != rawStart) {
      _graphicLiveSampleAgain = true;
      return;
    }
    _acceptGraphicLiveTiming(rawStart: rawStart, rawEnd: rawEnd);
  }

  /// 把一对 mpv 原始秒值记进边播边记表（测试钩子同走这里）。返回表是否有变化。
  ///
  /// 上一句结束未知（暂定时长）而新的一句开始了：按 mpv 自己的规则收尾——
  /// `sd_lavc` 解码到下一句时把上一句的 `endpts` 夹到下一句起点。
  bool _acceptGraphicLiveTiming({
    required String rawStart,
    required String rawEnd,
  }) {
    if (!_graphicSubtitleActive) return false;
    final int? startMs = parseMpvSecondsToMs(rawStart);
    if (startMs == null) return false;
    final int? endMs = parseMpvSecondsToMs(rawEnd);
    bool changed = false;
    final AudioCue? provisional = _graphicLiveProvisionalCue;
    if (provisional != null && provisional.startMs != startMs) {
      _graphicLiveProvisionalCue = null;
      if (closePlayerDecodedCue(provisional, startMs)) changed = true;
    }
    final ({List<AudioCue> cues, AudioCue cue, bool changed, bool inserted})
    merged = mergeGraphicSubtitleLiveTiming(
      _graphicLiveTimingCues,
      startMs: startMs,
      endMs: endMs,
    );
    _graphicLiveTimingCues = merged.cues;
    if (merged.changed) changed = true;
    final bool endKnown = endMs != null && endMs > startMs;
    if (endKnown) {
      if (identical(_graphicLiveProvisionalCue, merged.cue)) {
        _graphicLiveProvisionalCue = null;
      }
    } else if (merged.inserted) {
      // 新出现、结束段还没解码的一句：暂定时长，等真实结束或下一句来收尾。
      _graphicLiveProvisionalCue = merged.cue;
    }
    if (!changed) return false;
    _recomputeGraphicTimingCues();
    _notifyGraphicTimingChanged();
    return true;
  }

  /// 本次选轨的整轨时间表取数输入：调用方显式给的（互联 host 整轨）优先，否则按当前
  /// 播放源推导（[graphicSubtitleTimingInputForSource]）。
  GraphicSubtitleTimingInput? _graphicTimingInputFor({
    required int streamIndex,
    required String? codec,
  }) =>
      _graphicTimingInputOverride ??
      graphicSubtitleTimingInputForSource(
        videoPath: _videoPath,
        mediaUri: _mediaUri,
        httpHeaders: _mediaHttpHeaders,
        streamIndex: streamIndex,
        codec: codec,
      );

  /// 第 [streamIndex] 条图形轨的整轨取数输入，与本控制器取逐句时间表**同一个口径**：
  /// 本次选轨显式给的输入（互联 host 整轨）只在轨序号对得上时沿用，否则按当前播放源
  /// 推导（本地文件 / 网络流 URL + 播放会话请求头）。整轨 OCR 据此取数——互联视频不读
  /// 流、网络流带同一份请求头。推导不出（`edl://` / `bd://` / 无源）返回 null。
  GraphicSubtitleTimingInput? graphicSubtitleTimingInputForTrack({
    required int streamIndex,
    required String? codec,
  }) {
    final GraphicSubtitleTimingInput? override = _graphicTimingInputOverride;
    if (override != null && override.streamIndex == streamIndex) {
      return override;
    }
    return graphicSubtitleTimingInputForSource(
      videoPath: _videoPath,
      mediaUri: _mediaUri,
      httpHeaders: _mediaHttpHeaders,
      streamIndex: streamIndex,
      codec: codec,
    );
  }

  /// 当前图形轨若按**网络流**抽取（媒体服务器 / 通用 http / 在线源直链），给出同一份
  /// 抽取输入（URL + 请求头）：模糊遮蔽层拿它发的请求与这里的时间表抽取命中
  /// [FfmpegGraphicSubtitleRegionLoader] 的同一个在途任务 / 缓存，整条流只读一遍。
  /// 本地文件（遮蔽层自己按路径推导）/ 互联 host 整轨（不许按流地址整片读）/ 非图形
  /// 模式 → null。
  GraphicSubtitleInput? get activeGraphicSubtitleRemoteInput {
    final ({int streamIndex, String? codec})? track =
        activeGraphicSubtitleTrack;
    if (track == null) return null;
    final GraphicSubtitleTimingInput? input = _graphicTimingInputFor(
      streamIndex: track.streamIndex,
      codec: track.codec,
    );
    return input is GraphicSubtitleTimingStream && input.input.isRemote
        ? input.input
        : null;
  }

  /// 按输入类型取整轨位图时间表；拿不到返回 null。[stale] 为 true 时尽早放弃。
  Future<GraphicSubtitleRegionTrack?> _fetchGraphicRegionTrack(
    GraphicSubtitleTimingInput input, {
    required Size fallbackCanvas,
    required Future<void> cancel,
    required bool Function() stale,
  }) async {
    switch (input) {
      case GraphicSubtitleTimingStream():
        final GraphicSubtitleRegionRequest? request =
            graphicSubtitleRegionRequestForInput(
              input: input.input,
              track: (streamIndex: input.streamIndex, codec: input.codec),
            );
        if (request == null) return null;
        // 本地抽轨不挂 [cancel]：它是与模糊遮蔽层共享的在途任务，这里撤销会连带撤掉
        // 遮蔽层那一份。网络流抽取要读整条流，换轨 / 换片 / 离开图形模式必须撤销。
        final Future<void>? fetchCancel = input.input.isRemote ? cancel : null;
        GraphicSubtitleRegionTrack? track;
        // 与模糊遮蔽层共用一次抽轨；遮蔽层先发起又中途取消（换轨 / 卸载）时这里也会
        // 拿到 null——仍是当前轨就自己再要一次。
        for (int attempt = 0; attempt < 2 && track == null; attempt++) {
          if (stale()) return null;
          track = await graphicSubtitleRegionLoader.load(
            request,
            fallbackCanvas: fallbackCanvas,
            cancel: fetchCancel,
          );
        }
        return track;
      case GraphicSubtitleTimingHostTrack():
        final GraphicSubtitleHostTrackFiles? files = await input.download();
        if (files == null) return null;
        try {
          if (stale()) return null;
          return await graphicSubtitleTrackFileRegionLoad(
            files,
            fallbackCanvas: fallbackCanvas,
          );
        } finally {
          final String payloadPath = files.payload.path;
          for (final String path in <String>[
            payloadPath,
            bitmapSubtitleTrackHeaderPath(payloadPath),
            if (files.header != null) files.header!.path,
          ]) {
            try {
              final File f = File(path);
              if (f.existsSync()) f.deleteSync();
            } on FileSystemException {
              // 临时文件留给系统清理。
            }
          }
        }
    }
  }

  /// 切到图形轨后在后台取它的整轨时间表（来源见 [_graphicTimingInputFor]）。抽取
  /// 世代 / 加载令牌 / 轨序号任一变了就丢弃结果；结果到了与边播边记表合并。
  void _loadGraphicSubtitleTimings({
    required int streamIndex,
    required String? codec,
  }) {
    final int generation = ++_graphicTimingGeneration;
    final int loadToken = _loadToken;
    final GraphicSubtitleTimingInput? input = _graphicTimingInputFor(
      streamIndex: streamIndex,
      codec: codec,
    );
    if (input == null) return;
    _cancelGraphicTimingFetch();
    final Completer<void> cancel = Completer<void>();
    _graphicTimingCancel = cancel;
    final Size fallbackCanvas = Size(
      (videoWidth ?? 0).toDouble(),
      (videoHeight ?? 0).toDouble(),
    );
    bool stale() =>
        generation != _graphicTimingGeneration ||
        loadToken != _loadToken ||
        !_graphicSubtitleActive ||
        _graphicSubtitleStreamIndex != streamIndex;
    unawaited(() async {
      GraphicSubtitleRegionTrack? track;
      try {
        track = await _fetchGraphicRegionTrack(
          input,
          fallbackCanvas: fallbackCanvas,
          cancel: cancel.future,
          stale: stale,
        );
      } catch (error, stack) {
        debugPrint('[fushi] graphic subtitle timings failed: $error\n$stack');
        return;
      } finally {
        if (identical(_graphicTimingCancel, cancel)) {
          _graphicTimingCancel = null;
        }
      }
      if (track == null || stale()) return;
      // 模糊遮蔽层按位图糊用同一份（互联播放时它是唯一来源，见
      // [VideoPlayerController.graphicSubtitleRegionTrack]）。
      _graphicRegionTrack.value = track;
      _graphicExtractedTimingCues = graphicSubtitleTimingCuesFromRegions(track);
      _recomputeGraphicTimingCues();
      _notifyGraphicTimingChanged();
    }());
  }

  /// 测试钩子：宿主无 libmpv 观测不到属性，直接喂一对 mpv 原始秒值，走与真实采样
  /// 完全同一条 [_acceptGraphicLiveTiming]。
  @visibleForTesting
  bool debugAcceptGraphicLiveTimingForTesting({
    required String rawStart,
    required String rawEnd,
  }) => _acceptGraphicLiveTiming(rawStart: rawStart, rawEnd: rawEnd);

  /// 测试钩子：设定当前网络流源（宿主无 libmpv，走不了 [VideoPlayerController.load]）。
  @visibleForTesting
  void debugSetMediaSourceForTesting({
    String? mediaUri,
    Map<String, String> httpHeaders = const <String, String>{},
  }) {
    _mediaUri = mediaUri;
    _mediaHttpHeaders = httpHeaders;
  }

  /// 测试钩子：带显式取数输入触发一次整轨时间表加载（与选轨时传
  /// `timingInput` 同一路径）。
  @visibleForTesting
  void debugLoadGraphicSubtitleTimingsWithInputForTesting(
    GraphicSubtitleTimingInput input,
  ) {
    _graphicTimingInputOverride = input;
    _loadGraphicSubtitleTimings(
      streamIndex: input.streamIndex,
      codec: input.codec,
    );
  }

  /// 测试钩子：直接装入当前图形轨的位图时间表（宿主无 libmpv，选不了真图形轨）。
  @visibleForTesting
  void debugSetGraphicRegionTrackForTesting(GraphicSubtitleRegionTrack? track) {
    _graphicRegionTrack.value = track;
  }

  /// 测试钩子：选轨 / 换片时的同一个复位（[_resetGraphicTimingTables]）。
  @visibleForTesting
  void debugResetGraphicTimingTablesForTesting() => _resetGraphicTimingTables();

  /// 测试可见：本次选轨实际会用的整轨取数输入。
  @visibleForTesting
  GraphicSubtitleTimingInput? debugGraphicTimingInputForTesting({
    required int streamIndex,
    required String? codec,
  }) => _graphicTimingInputFor(streamIndex: streamIndex, codec: codec);
}
