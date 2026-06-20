// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch2).
part of '../video_hibiki_page.dart';

/// clip-export (ffmpeg trim) + screenshot domain methods extracted via
/// part-of (TODO-590 batch2); shared private scope. Behaviour-preserving:
/// bodies are verbatim except `setState(` forwarded through the main shell
/// `_rebuild(` helper (extensions cannot call the @protected State.setState
/// directly).
extension _VideoClipExport on _VideoHibikiPageState {
  Future<void> _toggleClipExport() async {
    if (_clipExporting) {
      _showOsd(t.video_clip_exporting);
      return;
    }

    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    if (_isRemote || _currentVideoPath == null) {
      _showOsd(t.video_clip_export_remote_download_required);
      return;
    }

    if (!_clipExportMarking) {
      final int? positionMs = controller.positionMs;
      if (positionMs == null) {
        _showOsd(t.video_clip_export_invalid_range);
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
      _showOsd(t.video_clip_export_start);
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
      _showOsd(t.video_clip_export_source_changed);
      return;
    }
    if (endMs <= startMs) {
      _rebuild(_clearClipExportState);
      _showOsd(t.video_clip_export_invalid_range);
      return;
    }

    final int generation = _clipExportGeneration;
    final int? audioStreamIndex = _clipExportStartAudioStreamIndex;
    final int? audioStreamCount = _clipExportStartAudioStreamCount;
    final String outputPath = await _clipExportOutputPath(
      inputPath: startPath,
      startMs: startMs,
      endMs: endMs,
    );
    if (!mounted) {
      await _deleteClipOutput(outputPath);
      return;
    }
    if (generation != _clipExportGeneration || _currentVideoPath != startPath) {
      await _deleteClipOutput(outputPath);
      if (mounted) {
        _rebuild(_clearClipExportState);
        _showOsd(t.video_clip_export_source_changed);
      }
      return;
    }
    _rebuild(() => _clipExporting = true);
    _showOsd(t.video_clip_exporting);

    final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
      inputPath: startPath,
      startMs: startMs,
      endMs: endMs,
      outputPath: outputPath,
      audioStreamIndex: audioStreamIndex,
      audioStreamCount: audioStreamCount,
    );

    if (!mounted) {
      await _deleteClipOutput(result.outputPath ?? outputPath);
      return;
    }
    if (generation != _clipExportGeneration || _currentVideoPath != startPath) {
      await _deleteClipOutput(result.outputPath ?? outputPath);
      if (mounted) {
        _rebuild(_clearClipExportState);
        _showOsd(t.video_clip_export_source_changed);
      }
      return;
    }

    _rebuild(_clearClipExportState);
    final String? exported = result.outputPath;
    if (result.isSuccess && exported != null) {
      _showOsd(t.video_clip_exported(path: exported));
      if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        await Share.shareXFiles(<XFile>[
          XFile(exported),
        ], subject: p.basename(exported));
      }
    } else {
      _showOsd(t.video_clip_export_failed(
        reason: _clipExportFailureReason(result),
      ));
      // C 修（BUG-345）：把 ffmpeg 真实 detail 截断追加到 OSD，给用户/真机一个可见
      // 线索（完整 stderr 已由 exportVideoClipViaFfmpeg 写进错误日志页）。
      final String? detail = result.detail?.trim();
      if (detail != null && detail.isNotEmpty) {
        _showOsd(detail.length > 160 ? '${detail.substring(0, 160)}…' : detail);
      }
    }
    _refocusVideo();
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

  Future<String> _clipExportOutputPath({
    required String inputPath,
    required int startMs,
    required int endMs,
  }) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'video_clips'));
    final String rawStem = _safeFileName(p.basenameWithoutExtension(inputPath));
    final String stem = rawStem.isEmpty ? 'video' : rawStem;
    final String ext = p.extension(inputPath).isEmpty
        ? '.mkv'
        : p.extension(inputPath).toLowerCase();
    final String name =
        '${stem}_${_clipExportTimeToken(startMs)}-${_clipExportTimeToken(endMs)}$ext';
    return p.join(dir.path, name);
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
          _showOsd(t.video_screenshot_saved_to(path: finalPath));
        }
      } else {
        await Share.shareXFiles(<XFile>[
          XFile(tmp.path, mimeType: 'image/jpeg'),
        ], subject: screenshotName);
        _showOsd(t.video_screenshot_ready(file: screenshotName));
      }
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] screenshot save failed: $e\n$stack');
      _showScreenshotFailure(e);
    } finally {
      // 桌面端清理临时文件；移动端分享需保留供系统面板异步读取。
      if (isDesktop && tmp != null) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      _refocusVideo();
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
    );
  }
}
