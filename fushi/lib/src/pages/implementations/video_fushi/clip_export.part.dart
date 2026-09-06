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
    if (controller == null) return;
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
    );

    if (!mounted) {
      await _deleteClipOutput(result.outputPath ?? outputPath);
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
      // 区分带没带字幕：字幕封装可能被静默降级（容器封不下、旧的桌面精简 ffmpeg 没有
      // movtext 编码器），不告诉用户的话，他只会看到一个「导出成功却没字幕」的片段，
      // 无从判断是自己没选字幕还是导出丢了。
      _showOsd(
        result.subtitleTrackCount > 0
            ? t.video_clip_exported_with_subtitles(path: exported)
            : t.video_clip_exported(path: exported),
        severity: ToastSeverity.success,
      );
      if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        await FushiShare.shareFiles(<XFile>[
          XFile(exported),
        ], subject: p.basename(exported));
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

  /// 截当前帧存为图片：桌面弹保存对话框，移动端走系统分享（参照 log_exporter
  /// 的平台分流）。复用 [VideoPlayerController.screenshot]（制卡同源，JPEG）。
  Future<void> _saveScreenshot() async {
    final VideoPlayerController? controller = _controller;
    final Uint8List? bytes = await controller?.screenshot();
    if (bytes == null) {
      _showScreenshotFailure('no frame available');
      return;
    }
    File? tmp;
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    try {
      final String defaultScreenshotName = videoScreenshotBaseName(
        sourcePathOrTitle: _screenshotSourcePathOrTitle(),
        positionMs: controller?.positionMs ?? 0,
      );
      final Directory tmpDir = await getTemporaryDirectory();
      final String screenshotName = uniqueVideoScreenshotBaseName(
        defaultScreenshotName,
        exists: (String name) => File(p.join(tmpDir.path, name)).existsSync(),
      );
      tmp = File(p.join(tmpDir.path, screenshotName));
      await tmp.writeAsBytes(bytes);
      if (isDesktop) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.video_screenshot,
          fileName: screenshotName,
          type: FileType.custom,
          allowedExtensions: <String>['jpg'],
        );
        if (savePath != null) {
          final String finalPath = _uniqueScreenshotSavePath(savePath);
          await tmp.copy(finalPath);
          _showOsd(
            t.video_screenshot_saved_to(path: finalPath),
            severity: ToastSeverity.success,
          );
        }
      } else {
        await FushiShare.shareFiles(<XFile>[
          XFile(tmp.path, mimeType: 'image/jpeg'),
        ], subject: screenshotName);
        _showOsd(
          t.video_screenshot_ready(file: screenshotName),
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

  String _uniqueScreenshotSavePath(String savePath) {
    final String desiredPath =
        p.extension(savePath).isEmpty ? '$savePath.jpg' : savePath;
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
