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
    final int delayMs = controller.delayMs;
    final String? primary = buildClipSrtContent(
      cues: controller.cues,
      startMs: startMs,
      endMs: endMs,
      delayMs: delayMs,
    );
    final String? secondary = buildClipSrtContent(
      cues: controller.secondaryCues,
      startMs: startMs,
      endMs: endMs,
      delayMs: delayMs,
    );
    return <String>[
      if (primary != null) primary,
      if (secondary != null) secondary,
    ];
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
