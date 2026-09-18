// GENERATED-NOTE: extracted from video_fushi_page.dart (TODO-590 batch2).
part of '../video_fushi_page.dart';

/// clip-export (ffmpeg trim) + screenshot domain methods extracted via
/// part-of (TODO-590 batch2); shared private scope. Behaviour-preserving:
/// bodies are verbatim except `setState(` forwarded through the main shell
/// `_rebuild(` helper (extensions cannot call the @protected State.setState
/// directly).
extension _VideoClipExport on _VideoFushiPageState {
  Future<void> _toggleClipExport() async {
    if (_clipExporting) {
      _showOsd(t.video_clip_exporting, severity: ToastSeverity.info);
      return;
    }

    final VideoPlayerController? controller = _controller;
    if (controller == null) {
      // 从前是裸 return：无 OSD、无日志、无 debugPrint，点了就是完全没反应
      // （BUG-2542）。控制器缺失就是「源视频不可用」，与导出层同一条文案。
      _showOsd(
        t.video_clip_export_input_missing,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (_isRemote || _currentVideoPath == null) {
      _showOsd(
        t.video_clip_export_remote_download_required,
        severity: ToastSeverity.warning,
      );
      return;
    }

    if (!_clipExportMarking) {
      final int? positionMs = controller.positionMs;
      if (positionMs == null) {
        _showOsd(
          t.video_clip_export_invalid_range,
          severity: ToastSeverity.error,
        );
        return;
      }
      _rebuild(() {
        _clipExportGeneration++;
        _clipExportMarking = true;
        _clipExportStartMs = positionMs;
        _clipExportStartPath = _currentVideoPath;
        _clipExportStartAudioStreamIndex = controller.currentAudioStreamIndex;
        _clipExportStartAudioStreamCount = controller.realAudioStreamCount;
      });
      _showOsd(t.video_clip_export_start, severity: ToastSeverity.info);
      return;
    }

    final int? startMs = _clipExportStartMs;
    final String? startPath = _clipExportStartPath;
    final int? endMs = controller.positionMs;
    if (startMs == null ||
        startPath == null ||
        endMs == null ||
        startPath != _currentVideoPath) {
      _rebuild(_clearClipExportState);
      _showOsd(
        t.video_clip_export_source_changed,
        severity: ToastSeverity.warning,
      );
      return;
    }
    if (endMs <= startMs) {
      _rebuild(_clearClipExportState);
      _showOsd(
        t.video_clip_export_invalid_range,
        severity: ToastSeverity.error,
      );
      return;
    }

    final int generation = _clipExportGeneration;
    final int? audioStreamIndex = _clipExportStartAudioStreamIndex;
    final int? audioStreamCount = _clipExportStartAudioStreamCount;
    // 桌面弹「另存为」让用户自选目录/文件名（BUG-917 用户诉求「没法设导出路径」），
    // 移动端落 app 文档目录后走系统分享。dialog 是异步阻塞 UI，返回后需重核
    // mounted / generation（用户可能中途换源）。取消对话框视为放弃本次导出。
    final String defaultName = _clipExportFileName(
      inputPath: startPath,
      startMs: startMs,
      endMs: endMs,
    );
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final String? outputPath = await _resolveClipOutputPath(
      defaultName: defaultName,
      isDesktop: isDesktop,
    );
    if (!mounted) return;
    if (outputPath == null) {
      // 桌面用户取消了「另存为」——此刻尚未产出任何文件，直接清状态收场。
      _rebuild(_clearClipExportState);
      _showOsd(t.video_clip_export_cancelled, severity: ToastSeverity.info);
      _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
      return;
    }
    if (generation != _clipExportGeneration || _currentVideoPath != startPath) {
      _rebuild(_clearClipExportState);
      _showOsd(
        t.video_clip_export_source_changed,
        severity: ToastSeverity.warning,
      );
      return;
    }
    _rebuild(() => _clipExporting = true);
    _showOsd(t.video_clip_exporting, severity: ToastSeverity.info);

    final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
      inputPath: startPath,
      startMs: startMs,
      endMs: endMs,
      outputPath: outputPath,
      audioStreamIndex: audioStreamIndex,
      audioStreamCount: audioStreamCount,
      subtitleContents: _clipExportSubtitleContents(
        controller: controller,
        startMs: startMs,
        endMs: endMs,
      ),
      // 硬字幕烧录（BUG-2202）：cue 带时间轴，导出层探出画面尺寸后回调渲染。
      // 内封软字幕轨已经不用了——mp4 里的 tx3g 会让整个片段在 QQ 这类 IM 里判为
      // 不可播（见 resolveClipSubtitleCodec）。
      subtitleCues: _clipExportSubtitleCues(
        controller: controller,
        startMs: startMs,
        endMs: endMs,
      ),
      subtitleRenderer: _clipExportSubtitleRenderer(),
      // 用户设的视频码率（0 = 跟随源，导出层归一成 null）。在这里取值而不是在
      // 标起点时取：用户常在标完起点、按导出前才去快捷面板改码率。
      videoBitrateKbps: appModel.videoClipExportVideoBitrateKbps,
    );

    if (!mounted) {
      // 页面在导出期间被卸载（退视频页 / 换集 / 进退全屏重建）。旧实现在这里把
      // 产物一律删掉：导出**已经成功**时，用户等了十几分钟，既没看到成功也没看到
      // 失败，文件也不存在，错误日志页还是空的——三重静默（BUG-2542）。成功的产物
      // 是有效的，保留并记下落点，至少可追可取；失败的残片仍旧删。
      // 下面的换源分支才是真该删成品的情形：那个产物对应的是**旧源**。
      if (result.isSuccess) {
        ErrorLogService.instance.log(
          'VideoClipExport',
          'page was unmounted before the result could be shown; keeping the '
              'exported clip at ${result.outputPath ?? outputPath}',
          StackTrace.current,
        );
      } else {
        await _deleteClipOutput(result.outputPath ?? outputPath);
      }
      return;
    }
    if (generation != _clipExportGeneration || _currentVideoPath != startPath) {
      await _deleteClipOutput(result.outputPath ?? outputPath);
      if (mounted) {
        _rebuild(_clearClipExportState);
        _showOsd(
          t.video_clip_export_source_changed,
          severity: ToastSeverity.warning,
        );
      }
      return;
    }

    _rebuild(_clearClipExportState);
    final String? exported = result.outputPath;
    if (result.isSuccess && exported != null) {
      // 移动端：产物落 app 私有目录（不进相册、不注册 MediaStore），这次系统分享
      // 面板是用户取回它的**唯一**通道，所以先分享、再按面板到底有没有呈现报结果
      // （BUG-2542）。旧实现先无条件报「已导出」再 fire-and-forget 分享，面板被
      // FushiShare 的防重入门丢弃时，用户看到的是绿色成功提示 + 一个进不去的路径，
      // 相册里没有、分享面板也没弹——体感就是「导出没反应」。
      final bool shared = isDesktop ||
          await FushiShare.shareFiles(<XFile>[
            XFile(exported),
          ], subject: p.basename(exported));
      if (!shared) {
        _showOsd(
          t.video_clip_export_share_unavailable(path: exported),
          severity: ToastSeverity.warning,
        );
      } else {
        // 区分带没带字幕：字幕封装可能被静默降级（容器封不下、旧的桌面精简 ffmpeg 没有
        // movtext 编码器），不告诉用户的话，他只会看到一个「导出成功却没字幕」的片段，
        // 无从判断是自己没选字幕还是导出丢了。
        _showOsd(
          result.subtitleTrackCount > 0
              ? t.video_clip_exported_with_subtitles(path: exported)
              : t.video_clip_exported(path: exported),
          severity: ToastSeverity.success,
        );
      }
    } else {
      // TODO-910：合成**单条** OSD（旧实现两条 _showOsd 互相覆盖，第二条把第一条
      // 可读 reason 顶掉），且 detail 取 ffmpeg stderr **尾段**真因（见
      // exportVideoClipViaFfmpeg → extractFfmpegFailureReason），而非旧的从头
      // substring(0,160)——后者只截到没用的 `Input #0 ... encoder :` 输入 banner。
      // 完整 stderr 仍由 exportVideoClipViaFfmpeg 写进错误日志页。
      final String readable = _clipExportFailureReason(result);
      final String? detail = result.detail?.trim();
      final String reason = (detail == null || detail.isEmpty)
          ? readable
          : '$readable — ${detail.length > 200 ? '${detail.substring(detail.length - 200)}…' : detail}';
      _showOsd(
        t.video_clip_export_failed(reason: reason),
        severity: ToastSeverity.error,
      );
    }
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  /// 收集片段区间内「用户正在看的字幕」，裁成 SRT 文本（主字幕一条、副字幕一条）。
  ///
  /// 真相源是播放器内存里的 cue 列表，不是源文件的 `0:s:N`：Hibiki 的字幕全部由
  /// Flutter overlay 渲染（libmpv 侧被 `setSubtitleTrack(no())` 关掉），外挂字幕在源
  /// 文件里压根没有对应流，内嵌轨也丢掉了用户调过的 [VideoPlayerController.delayMs]
  /// 偏移。从 cue 生成，导出的字幕恰好等于屏幕上看到的那条。
  ///
  /// 区间内无字幕（纯 OP/ED 片段）时返回空列表——调用方据此不加字幕输入。
  List<String> _clipExportSubtitleContents({
    required VideoPlayerController controller,
    required int startMs,
    required int endMs,
  }) {
    final String? primary = buildClipSrtContent(
      cues: controller.cues,
      startMs: startMs,
      endMs: endMs,
      delayMs: controller.delayMs,
    );
    final String? secondary = buildClipSrtContent(
      cues: controller.secondaryCues,
      startMs: startMs,
      endMs: endMs,
      // TODO-2837：主副字幕分开调轴后，副轨 SRT 按副轨生效轴换算（未单独设置时
      // == 主轨，行为与旧版一致），导出的字幕才等于屏幕上看到的那条。
      delayMs: controller.effectiveSecondaryDelayMs,
    );
    return <String>[
      if (primary != null) primary,
      if (secondary != null) secondary,
    ];
  }

  /// 收集片段区间内「用户正在看的字幕」，裁成带时间轴的 cue（硬字幕烧录用）。
  ///
  /// 与 [_clipExportSubtitleContents] 同源同轴——两者都建在 `buildClipSubtitleCues`
  /// 之上，所以烧出来的字幕和 SRT 里的逐条一致，不会因为各挑各的而显示出两套内容。
  /// 副字幕带 `isSecondary` 标记：主副两层在屏幕上锚在画面对侧（主底 → 副顶），
  /// 扁平成一个列表后靠这个标记还原层归属，否则两层会叠印在同一个位置。
  List<ClipSubtitleCue> _clipExportSubtitleCues({
    required VideoPlayerController controller,
    required int startMs,
    required int endMs,
  }) {
    return <ClipSubtitleCue>[
      ...buildClipSubtitleCues(
        cues: controller.cues,
        startMs: startMs,
        endMs: endMs,
        delayMs: controller.delayMs,
      ),
      ...buildClipSubtitleCues(
        cues: controller.secondaryCues,
        startMs: startMs,
        endMs: endMs,
        // 与 SRT 路径同因（TODO-2837）：副轨按其生效轴换算，未单独设置时 == 主轨。
        delayMs: controller.effectiveSecondaryDelayMs,
        isSecondary: true,
      ),
    ];
  }

  /// 造一个「把一条 cue 画成整帧透明 PNG」的回调交给导出层。
  ///
  /// 分工：导出层只懂 ffmpeg，**画成什么样是页面的事**——只有页面知道用户的字幕外观
  /// 设置（[_subtitleStyle]）和屏幕上视频内容有多高。导出层探出画面尺寸后喂回来。
  ///
  /// `viewportHeight` 取的是**屏幕上视频内容区的高度**，不是播放器区域高度：字幕在
  /// 屏幕上是固定逻辑字号，而映射到导出帧上的只有视频内容那一块，所以换算基准必须
  /// 是内容高（letterbox 时 = `min(区域高, 区域宽 × 帧高 / 帧宽)`）。用区域高会让
  /// 上下有黑边的视频导出后字幕偏小。
  ClipSubtitleFrameRenderer _clipExportSubtitleRenderer() {
    // 闭包里不再碰 State（导出是异步的，回调触发时页面可能已经变了），所以样式和
    // 尺寸都在这里一次性取好。
    final VideoSubtitleStyle style = _subtitleStyle;
    final Size? area = context.size;

    return (ClipSubtitleCue cue, ClipFrameSize frame) {
      final double viewportHeight = (area == null || frame.width <= 0)
          ? 0 // 拿不到就交给渲染器的回退基准，绝不让 scale 变成 0 或无穷
          : math.min(
              area.height,
              area.width * frame.height / frame.width,
            );
      // 锚定复用屏幕上那套解析（TODO-2838）：主层只有选了顶部才算显式，副层任何
      // 非 null 都算显式，都没有时副层自动取主层的对侧。ownNonBottom 恒 false——
      // 导出渲染的是纯文本，没有 ASS 自带定位。
      final SubtitleLayerVAnchor? anchor = resolveLayerForcedAnchor(
        isSecondary: cue.isSecondary,
        userAnchor: cue.isSecondary
            ? style.secondaryAnchor
            : (style.mainAnchor == SubtitleLayerVAnchor.top
                ? SubtitleLayerVAnchor.top
                : null),
        mainUserAnchor: style.mainAnchor,
        ownNonBottom: false,
      );
      return renderClipSubtitlePng(
        text: cue.text,
        frame: frame,
        style: style,
        viewportHeight: viewportHeight,
        anchorTop: anchor == SubtitleLayerVAnchor.top,
        // 副层有自己的位置基线；null = 跟随主层（历史行为）。
        overridePadding: cue.isSecondary ? style.secondaryBottomPadding : null,
      );
    };
  }

  void _clearClipExportState() {
    _clipExportGeneration++;
    _clipExportMarking = false;
    _clipExporting = false;
    _clipExportStartMs = null;
    _clipExportStartPath = null;
    _clipExportStartAudioStreamIndex = null;
    _clipExportStartAudioStreamCount = null;
  }

  /// 片段导出的默认文件名：`<源名>_<起>-<止>.mp4`。扩展名恒 `.mp4`——绝不再跟随
  /// 源容器（BUG-917：mkv/webm/avi/ts 源会让 ffmpeg 选中桌面精简 ffmpeg 白名单里
  /// 不存在的 matroska/webm muxer → exit -22 EINVAL）。mp4 桌面 ffmpeg-min 能 mux，
  /// 且任意播放器/浏览器通吃。
  String _clipExportFileName({
    required String inputPath,
    required int startMs,
    required int endMs,
  }) {
    final String rawStem = _safeFileName(p.basenameWithoutExtension(inputPath));
    final String stem = rawStem.isEmpty ? 'video' : rawStem;
    return '${stem}_${_clipExportTimeToken(startMs)}-'
        '${_clipExportTimeToken(endMs)}.mp4';
  }

  /// 决定片段导出目标路径：桌面弹「另存为」让用户选目录/文件名（取消返回 null），
  /// 移动端落 app 文档目录 `video_clips/`（随后走系统分享）。输出恒 `.mp4`。
  Future<String?> _resolveClipOutputPath({
    required String defaultName,
    required bool isDesktop,
  }) async {
    if (isDesktop) {
      final String? picked = await FilePicker.platform.saveFile(
        dialogTitle: t.video_clip_export,
        fileName: defaultName,
        type: FileType.custom,
        allowedExtensions: <String>['mp4'],
      );
      if (picked == null) return null;
      return _ensureMp4Extension(picked);
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'video_clips'));
    return p.join(dir.path, defaultName);
  }

  /// 保证路径以 `.mp4` 结尾：用户在「另存为」里删/换了扩展名时补回，否则 ffmpeg 又
  /// 按扩展名挑 muxer，退回 BUG-917（选中缺失的 matroska/mkv muxer → exit -22）。
  String _ensureMp4Extension(String path) {
    if (p.extension(path).toLowerCase() == '.mp4') return path;
    return p.extension(path).isEmpty
        ? '$path.mp4'
        : '${p.withoutExtension(path)}.mp4';
  }

  String _clipExportTimeToken(int ms) {
    final int totalSeconds = ms ~/ 1000;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final int millis = ms % 1000;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(hours)}${two(minutes)}${two(seconds)}_'
        '${millis.toString().padLeft(3, '0')}';
  }

  String _clipExportFailureReason(VideoClipExportResult result) {
    switch (result.failure) {
      case VideoClipExportFailure.invalidRange:
        return t.video_clip_export_invalid_range;
      case VideoClipExportFailure.inputMissing:
        return t.video_clip_export_input_missing;
      case VideoClipExportFailure.ffmpegUnavailable:
        return t.video_clip_export_ffmpeg_unavailable;
      case VideoClipExportFailure.ffmpegFailed:
        return t.video_clip_export_ffmpeg_failed;
      case VideoClipExportFailure.outputMissing:
        return t.video_clip_export_output_missing;
      case null:
        return t.video_clip_export_ffmpeg_failed;
    }
  }

  Future<void> _deleteClipOutput(String? path) async {
    if (path == null) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 截当前帧存为图片。
  ///
  /// 两个独立快捷键共用这一个执行体，只差 [withSubtitles]：字幕由 Flutter overlay
  /// 渲染、**不在解码帧里**（libmpv 侧 `sub-visibility=no`），所以「带字幕」那条要
  /// 在 Dart 侧把屏幕上正在显示的那条字幕合成回画面（见
  /// `video_screenshot_compose.dart`），用的是片段导出同一套渲染器，外观与屏幕一致。
  ///
  /// 去向由 [VideoScreenshotDestination] 决定：弹对话框（历史行为）/ 进剪贴板 /
  /// 静默写进指定目录。复用 [VideoPlayerController.screenshot]（制卡同源，JPEG）。
  Future<void> _saveScreenshot({bool withSubtitles = false}) async {
    final VideoPlayerController? controller = _controller;
    final Uint8List? raw = await controller?.screenshot();
    if (raw == null) {
      _showScreenshotFailure('no frame available');
      return;
    }

    Uint8List bytes = raw;
    String extension = 'jpg';
    if (withSubtitles && controller != null) {
      final Uint8List? composed =
          await _composeScreenshotWithSubtitles(controller, raw);
      // 合成不出来（此刻屏幕上本就没字幕 / 渲染失败）就落回裸帧：少一层字幕远好过
      // 整张截图失败。
      if (composed != null) {
        bytes = composed;
        extension = 'png';
      }
    }
    if (!mounted) return;

    final String screenshotName = videoScreenshotBaseName(
      sourcePathOrTitle: _screenshotSourcePathOrTitle(),
      positionMs: controller?.positionMs ?? 0,
      extension: extension,
    );
    switch (appModel.videoScreenshotDestination) {
      case VideoScreenshotDestination.clipboard:
        await _copyScreenshotToClipboard(bytes: bytes, extension: extension);
      case VideoScreenshotDestination.directory:
        final String directory = appModel.videoScreenshotDirectory.trim();
        if (directory.isEmpty) {
          // 没设过目录就退回对话框而不是静默丢文件：宁可多一次对话框，也不要把图
          // 写到用户不知道的地方。
          _showOsd(
            t.video_screenshot_directory_unset,
            severity: ToastSeverity.error,
          );
          await _saveScreenshotViaDialog(
            bytes: bytes,
            screenshotName: screenshotName,
            extension: extension,
          );
        } else {
          await _writeScreenshotToDirectory(
            bytes: bytes,
            directory: directory,
            screenshotName: screenshotName,
          );
        }
      case VideoScreenshotDestination.ask:
        await _saveScreenshotViaDialog(
          bytes: bytes,
          screenshotName: screenshotName,
          extension: extension,
        );
    }
  }

  /// 把此刻屏幕上显示的字幕合成回 [frameBytes] 这一帧，返回 PNG；没字幕或渲染失败
  /// 返回 null（调用方据此落回裸帧）。
  ///
  /// cue 的选取与片段导出**同源同轴**（[_clipExportSubtitleCues] → `buildClipSubtitleCues`，
  /// 含主副轨各自的 delay 与文本清洗），窗口取当前播放位置起 1ms——该函数要求
  /// `endMs > startMs`，而「与区间有交集」的判据配 1ms 窗口恰好选中屏幕上那条。
  /// 排版换算（字号/底距/描边按 画面高 ÷ 视频显示区高 缩放）走
  /// [_clipExportSubtitleRenderer]，于是截图里的字幕与屏幕上、与导出的片段逐像素同源。
  Future<Uint8List?> _composeScreenshotWithSubtitles(
    VideoPlayerController controller,
    Uint8List frameBytes,
  ) async {
    final ({int width, int height})? size =
        await screenshotFrameSize(frameBytes);
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    // 位置未知时按 0 处理：取不到当前时刻就选不出 cue，下面 cues 为空、落回裸帧。
    final int positionMs = controller.positionMs ?? 0;
    final List<ClipSubtitleCue> cues = _clipExportSubtitleCues(
      controller: controller,
      startMs: positionMs,
      endMs: positionMs + 1,
    );
    if (cues.isEmpty) return null;

    final ClipFrameSize frame = ClipFrameSize(size.width, size.height);
    final ClipSubtitleFrameRenderer renderer = _clipExportSubtitleRenderer();
    final List<Uint8List> layers = <Uint8List>[];
    for (final ClipSubtitleCue cue in cues) {
      final Uint8List? png = await renderer(cue, frame);
      if (png != null) layers.add(png);
    }
    if (layers.isEmpty) return null;
    return composeScreenshotWithOverlays(
      frameBytes: frameBytes,
      overlayPngs: layers,
    );
  }

  /// 去向 = 剪贴板。各端剪贴板收的都是 PNG，裸帧是 JPEG，所以先转一道。
  Future<void> _copyScreenshotToClipboard({
    required Uint8List bytes,
    required String extension,
  }) async {
    try {
      final Uint8List? png = extension == 'png'
          ? bytes
          : await composeScreenshotWithOverlays(
              frameBytes: bytes,
              overlayPngs: const <Uint8List>[],
            );
      if (png == null) {
        _showScreenshotFailure('png encode failed');
        return;
      }
      final bool copied = await copyImageToClipboard(png);
      if (!mounted) return;
      if (copied) {
        _showOsd(t.video_screenshot_copied, severity: ToastSeverity.success);
      } else {
        _showScreenshotFailure(t.video_screenshot_clipboard_unsupported);
      }
    } catch (e, stack) {
      debugPrint('[VideoFushiPage] screenshot clipboard failed: $e\n$stack');
      if (mounted) _showScreenshotFailure(e);
    }
  }

  /// 去向 = 指定目录：不弹任何对话框，直接落盘。重名走与保存对话框同一套 ` (n)`
  /// 计数后缀（[uniqueVideoScreenshotPath]），连按截图不会互相覆盖。
  Future<void> _writeScreenshotToDirectory({
    required Uint8List bytes,
    required String directory,
    required String screenshotName,
  }) async {
    try {
      final Directory dir = Directory(directory);
      if (!await dir.exists()) await dir.create(recursive: true);
      final String finalPath = uniqueVideoScreenshotPath(
        p.join(directory, screenshotName),
        exists: (String path) => File(path).existsSync(),
      );
      await File(finalPath).writeAsBytes(bytes);
      if (!mounted) return;
      _showOsd(
        t.video_screenshot_saved_to(path: finalPath),
        severity: ToastSeverity.success,
      );
    } catch (e, stack) {
      debugPrint(
        '[VideoFushiPage] screenshot directory write failed: $e\n$stack',
      );
      if (mounted) _showScreenshotFailure(e);
    }
  }

  /// 去向 = 询问（历史行为）：桌面弹保存对话框，移动端走系统分享（参照 log_exporter
  /// 的平台分流）。两条都要先落一个临时文件——对话框拿到路径后 copy，分享面板要一个
  /// 真实文件路径。
  Future<void> _saveScreenshotViaDialog({
    required Uint8List bytes,
    required String screenshotName,
    required String extension,
  }) async {
    File? tmp;
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    try {
      final Directory tmpDir = await getTemporaryDirectory();
      final String uniqueName = uniqueVideoScreenshotBaseName(
        screenshotName,
        exists: (String name) => File(p.join(tmpDir.path, name)).existsSync(),
      );
      tmp = File(p.join(tmpDir.path, uniqueName));
      await tmp.writeAsBytes(bytes);
      if (isDesktop) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.video_screenshot,
          fileName: uniqueName,
          type: FileType.custom,
          allowedExtensions: <String>[extension],
        );
        if (savePath != null) {
          final String finalPath =
              _uniqueScreenshotSavePath(savePath, extension: extension);
          await tmp.copy(finalPath);
          _showOsd(
            t.video_screenshot_saved_to(path: finalPath),
            severity: ToastSeverity.success,
          );
        }
      } else {
        await FushiShare.shareFiles(<XFile>[
          XFile(
            tmp.path,
            mimeType: extension == 'png' ? 'image/png' : 'image/jpeg',
          ),
        ], subject: uniqueName);
        _showOsd(
          t.video_screenshot_ready(file: uniqueName),
          severity: ToastSeverity.success,
        );
      }
    } catch (e, stack) {
      debugPrint('[VideoFushiPage] screenshot save failed: $e\n$stack');
      _showScreenshotFailure(e);
    } finally {
      // 桌面端清理临时文件；移动端分享需保留供系统面板异步读取。
      if (isDesktop && tmp != null) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      // 只有这条路径真弹过系统对话框 / 分享面板，焦点才需要收回；剪贴板与直写目录
      // 全程无 overlay，无条件 reclaim 会平白夺一次焦点。
      _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
    }
  }

  String _screenshotSourcePathOrTitle() {
    final String? currentVideoPath = _currentVideoPath;
    if (currentVideoPath != null && currentVideoPath.trim().isNotEmpty) {
      return currentVideoPath;
    }
    final String? title = _title ?? widget.remoteInfo?.title;
    if (title != null && title.trim().isNotEmpty) return title;
    return 'video';
  }

  String _uniqueScreenshotSavePath(
    String savePath, {
    String extension = 'jpg',
  }) {
    final String desiredPath =
        p.extension(savePath).isEmpty ? '$savePath.$extension' : savePath;
    return uniqueVideoScreenshotPath(
      desiredPath,
      exists: (String path) => File(path).existsSync(),
    );
  }

  void _showScreenshotFailure(Object reason) {
    final String text = reason.toString().trim();
    _showOsd(
      t.video_screenshot_failed_reason(
        reason: text.isEmpty ? 'unknown error' : text,
      ),
      severity: ToastSeverity.error,
    );
  }
}
