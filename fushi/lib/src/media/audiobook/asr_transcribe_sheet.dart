/// 「设备端转录生成字幕」弹层：模型下载 → 装载引擎 → 转录进度（可暂停 / 续跑）
/// → 返回生成的 SRT 路径给导入对话框。
///
/// 与重跑匹配的 sheet 同一套外壳：桌面 [FushiDialogFrame] + [showAppDialog]，
/// 移动端 [adaptiveModalSheet]。转录本体跑在 [AsrTranscriptionService] 装配出的
/// 任务里；弹层被关掉时请求在下一个检查点暂停并释放会话，进度留在磁盘。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/onnx/model_file_downloader.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';
import 'package:fushi/utils.dart';

/// 打开转录弹层。返回生成的 SRT 绝对路径；用户关闭 / 暂停 / 失败时返回 null。
Future<String?> showAsrTranscribeSheet({
  required BuildContext context,
  required List<String> audioPaths,
  AsrTranscriptionService? service,
}) {
  final AsrTranscriptionService effective =
      service ?? AsrTranscriptionService();
  Widget build(BuildContext ctx) =>
      AsrTranscribeSheet(audioPaths: audioPaths, service: effective);
  if (isDesktopPlatform) {
    return showAppDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => FushiDialogFrame(
        maxWidth: 520,
        maxHeightFactor: 0.8,
        scrollable: false,
        child: build(ctx),
      ),
    );
  }
  return adaptiveModalSheet<String>(
    context: context,
    showDragHandle: true,
    builder: build,
  );
}

enum _Phase {
  checking,
  needDownload,
  downloading,
  ready,
  loading,
  running,
  pausing,
  paused,
  finished,
  error,
}

@visibleForTesting
class AsrTranscribeSheet extends StatefulWidget {
  const AsrTranscribeSheet({
    required this.audioPaths,
    required this.service,
    super.key,
  });

  final List<String> audioPaths;
  final AsrTranscriptionService service;

  @override
  State<AsrTranscribeSheet> createState() => _AsrTranscribeSheetState();
}

class _AsrTranscribeSheetState extends State<AsrTranscribeSheet> {
  _Phase _phase = _Phase.checking;
  AsrAccelerationPreference _preference = AsrAccelerationPreference.auto;
  AsrTranscribePlan? _plan;
  String? _finishedSrt;
  String? _error;

  // 下载进度。
  int _downloadReceived = 0;
  int _downloadTotal = 0;
  String _downloadFile = '';
  StreamSubscription<ModelDownloadEvent>? _downloadSub;

  // 转录进度。
  AsrRunningTranscription? _running;
  StreamSubscription<AsrTranscribeEvent>? _runSub;
  AsrTranscribeProgress? _progress;
  AsrTranscribeResult? _result;
  OnnxProviderResolution? _resolution;

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    // 关闭弹层不等于取消：请求在下一个检查点暂停，暂停后释放会话；进度已落盘。
    final AsrRunningTranscription? running = _running;
    final StreamSubscription<AsrTranscribeEvent>? sub = _runSub;
    if (running != null && sub != null) {
      running.requestPause();
      sub.onDone(() => running.dispose());
      sub.onError((Object _, StackTrace __) => running.dispose());
      sub.onData((AsrTranscribeEvent _) {});
    } else {
      _runSub?.cancel();
      _running?.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshPlan() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      final AsrTranscribePlan plan = await widget.service.plan(_preference);
      final String? finished = await widget.service.finishedSrtPath(
        widget.audioPaths,
      );
      final AsrJobState? existing = await widget.service.existingState(
        widget.audioPaths,
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _finishedSrt = finished;
        if (finished != null) {
          _phase = _Phase.finished;
        } else if (!plan.modelReady) {
          _phase = _Phase.needDownload;
        } else if (existing != null && !existing.finished) {
          _phase = _Phase.paused;
        } else {
          _phase = _Phase.ready;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = '$e';
      });
    }
  }

  void _startDownload() {
    final AsrTranscribePlan? plan = _plan;
    if (plan == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _downloadTotal = plan.modelStatus.totalBytes;
      _downloadReceived = plan.modelStatus.obtainedBytes;
      _downloadFile = '';
    });
    // 逐文件事件：把「之前文件」的字节累计起来展示总进度。
    int completedBytes = 0;
    String lastFile = '';
    int lastFileTotal = 0;
    _downloadSub = widget.service
        .downloadModel(plan.variant)
        .listen(
          (ModelDownloadEvent e) {
            if (e.fileName != lastFile) {
              completedBytes += lastFileTotal;
              lastFile = e.fileName;
              lastFileTotal = e.totalBytes;
            }
            if (!mounted) return;
            setState(() {
              _downloadFile = e.fileName;
              _downloadReceived = completedBytes + e.receivedBytes;
            });
          },
          onError: (Object e, StackTrace _) {
            if (!mounted) return;
            setState(() {
              _phase = _Phase.error;
              _error = '$e';
            });
          },
          onDone: () {
            if (!mounted) return;
            _refreshPlan();
          },
        );
  }

  Future<void> _startTranscription() async {
    final AsrTranscribePlan? plan = _plan;
    if (plan == null) return;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _result = null;
    });
    try {
      final AsrRunningTranscription running = await widget.service.start(
        audioPaths: widget.audioPaths,
        variant: plan.variant,
        preference: _preference,
      );
      if (!mounted) {
        await running.dispose();
        return;
      }
      _running = running;
      setState(() {
        _resolution = running.encoderResolution;
        _phase = _Phase.running;
      });
      _runSub = running.run().listen(
        (AsrTranscribeEvent e) {
          if (!mounted) return;
          switch (e) {
            case AsrTranscribeProgressEvent(
              progress: final AsrTranscribeProgress p,
            ):
              setState(() => _progress = p);
            case AsrTranscribePausedEvent(
              progress: final AsrTranscribeProgress p,
            ):
              setState(() {
                _progress = p;
                _phase = _Phase.paused;
              });
            case AsrTranscribeFinishedEvent(
              result: final AsrTranscribeResult r,
            ):
              setState(() {
                _result = r;
                _finishedSrt = r.srtPath;
                _phase = _Phase.finished;
              });
          }
        },
        onError: (Object e, StackTrace _) async {
          await _releaseRunning();
          if (!mounted) return;
          setState(() {
            _phase = _Phase.error;
            _error = '$e';
          });
        },
        onDone: () async {
          await _releaseRunning();
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = '$e';
      });
    }
  }

  Future<void> _releaseRunning() async {
    final AsrRunningTranscription? running = _running;
    _running = null;
    _runSub = null;
    await running?.dispose();
  }

  void _pause() {
    _running?.requestPause();
    setState(() => _phase = _Phase.pausing);
  }

  Future<void> _discard() async {
    await widget.service.discard(widget.audioPaths);
    if (!mounted) return;
    _result = null;
    _finishedSrt = null;
    _progress = null;
    await _refreshPlan();
  }

  // ── 展示 ───────────────────────────────────────────────────────────────────

  String _providerLabel(OnnxExecutionProvider p) => switch (p) {
    OnnxExecutionProvider.cuda => 'CUDA (GPU)',
    OnnxExecutionProvider.directml => 'DirectML (GPU)',
    OnnxExecutionProvider.coreml => 'CoreML',
    OnnxExecutionProvider.cpu => 'CPU',
  };

  String _variantLabel(AsrEncoderVariant v) => switch (v) {
    AsrEncoderVariant.fp32 => 'fp32 · GPU',
    AsrEncoderVariant.int8 => 'int8 · CPU',
  };

  static String _fmtDuration(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes % 60;
    final int s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String _statusLine() {
    final AsrTranscribePlan? plan = _plan;
    switch (_phase) {
      case _Phase.checking:
        return t.audiobook_transcribe_preparing;
      case _Phase.needDownload:
        return t.audiobook_transcribe_model_download_needed(
          size: FushiByteFormat.bytes(plan?.bytesToDownload),
        );
      case _Phase.downloading:
        return t.audiobook_transcribe_model_downloading(
          name: _downloadFile,
          received: FushiByteFormat.bytes(_downloadReceived),
          total: FushiByteFormat.bytes(_downloadTotal),
        );
      case _Phase.ready:
      case _Phase.paused:
        final String ready = t.audiobook_transcribe_model_ready(
          variant: plan == null ? '' : _variantLabel(plan.variant),
        );
        if (_phase == _Phase.paused) {
          return '$ready\n${t.audiobook_transcribe_paused_hint}';
        }
        return ready;
      case _Phase.loading:
        return t.audiobook_transcribe_preparing;
      case _Phase.running:
      case _Phase.pausing:
        final AsrTranscribeProgress? p = _progress;
        final StringBuffer sb = StringBuffer();
        final OnnxProviderResolution? r = _resolution;
        if (r != null) {
          sb.writeln(
            t.audiobook_transcribe_running_on(
              provider: _providerLabel(r.effective),
            ),
          );
          if (r.didFallBack) {
            sb.writeln(
              t.audiobook_transcribe_fallback(reason: r.fallbackReason ?? ''),
            );
          }
        }
        if (p != null) {
          sb.writeln(
            t.audiobook_transcribe_progress(
              done: _fmtDuration(Duration(milliseconds: p.processedMs)),
              total: _fmtDuration(Duration(milliseconds: p.totalMs)),
              file: p.fileIndex + 1,
              files: p.filesTotal,
            ),
          );
          final double? rtf = p.rtf;
          final Duration? eta = p.eta;
          sb.write(
            t.audiobook_transcribe_speed(
              elapsed: _fmtDuration(p.elapsed),
              eta: eta == null ? '—' : _fmtDuration(eta),
              speed: rtf == null || rtf <= 0
                  ? '—'
                  : (1 / rtf).toStringAsFixed(1),
            ),
          );
        }
        if (_phase == _Phase.pausing) {
          sb
            ..writeln()
            ..write(t.audiobook_transcribe_pausing);
        }
        return sb.toString().trimRight();
      case _Phase.finished:
        final AsrTranscribeResult? r = _result;
        if (r != null) {
          return t.audiobook_transcribe_done(
            cues: r.cueCount,
            segments: r.segmentCount,
          );
        }
        return t.audiobook_transcribe_result_name;
      case _Phase.error:
        return t.audiobook_transcribe_failed(error: _error ?? '');
    }
  }

  double? _progressValue() {
    switch (_phase) {
      case _Phase.downloading:
        return _downloadTotal > 0
            ? (_downloadReceived / _downloadTotal).clamp(0.0, 1.0)
            : null;
      case _Phase.running:
      case _Phase.pausing:
        return _progress?.fraction;
      case _Phase.finished:
        return 1;
      case _Phase.checking:
      case _Phase.loading:
        return null;
      case _Phase.needDownload:
      case _Phase.ready:
      case _Phase.paused:
      case _Phase.error:
        return 0;
    }
  }

  bool get _busy =>
      _phase == _Phase.checking ||
      _phase == _Phase.downloading ||
      _phase == _Phase.loading ||
      _phase == _Phase.running ||
      _phase == _Phase.pausing;

  bool get _canChangePreference =>
      _phase == _Phase.needDownload ||
      _phase == _Phase.ready ||
      _phase == _Phase.paused ||
      _phase == _Phase.error;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool showProgressBar =
        _phase == _Phase.downloading ||
        _phase == _Phase.running ||
        _phase == _Phase.pausing ||
        _phase == _Phase.loading ||
        _phase == _Phase.checking;
    return FushiModalSheetFrame(
      title: t.audiobook_transcribe_title,
      leadingIcon: Icons.record_voice_over_outlined,
      scrollable: true,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.audiobook_transcribe_intro, style: tokens.type.metadata),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            t.audiobook_transcribe_accel_label,
            style: tokens.type.listTitle,
          ),
          SizedBox(height: tokens.spacing.gap),
          adaptiveSegmentedButton<AsrAccelerationPreference>(
            context: context,
            segments: <ButtonSegment<AsrAccelerationPreference>>[
              ButtonSegment<AsrAccelerationPreference>(
                value: AsrAccelerationPreference.auto,
                label: Text(t.audiobook_transcribe_accel_auto),
              ),
              ButtonSegment<AsrAccelerationPreference>(
                value: AsrAccelerationPreference.cpuOnly,
                label: Text(t.audiobook_transcribe_accel_cpu),
              ),
            ],
            selected: <AsrAccelerationPreference>{_preference},
            onSelectionChanged: !_canChangePreference
                ? (Set<AsrAccelerationPreference> _) {}
                : (Set<AsrAccelerationPreference> s) {
                    _preference = s.first;
                    _refreshPlan();
                  },
          ),
          SizedBox(height: tokens.spacing.rowVertical),
          Text(
            _statusLine(),
            key: const ValueKey<String>('asr-transcribe-status'),
            style: tokens.type.metadata,
          ),
          if (showProgressBar) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            LinearProgressIndicator(value: _progressValue()),
          ],
        ],
      ),
      // Wrap 而不是 Row：完成态有三个按钮，窄窗/移动端一行放不下会横向溢出。
      footer: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: tokens.spacing.gap,
        runSpacing: tokens.spacing.gap,
        children: _footerButtons(context, tokens),
      ),
    );
  }

  List<Widget> _footerButtons(BuildContext context, FushiDesignTokens tokens) {
    final List<Widget> buttons = <Widget>[];
    void add(Widget w) => buttons.add(w);

    add(
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t.cancel),
      ),
    );
    switch (_phase) {
      case _Phase.needDownload:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(t.audiobook_transcribe_model_download),
            onPressed: _startDownload,
          ),
        );
      case _Phase.ready:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_outlined, size: 18),
            label: Text(t.audiobook_transcribe_start),
            onPressed: _startTranscription,
          ),
        );
      case _Phase.paused:
        add(
          TextButton(
            onPressed: _discard,
            child: Text(t.audiobook_transcribe_discard),
          ),
        );
        add(
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow_outlined, size: 18),
            label: Text(t.audiobook_transcribe_resume),
            onPressed: _startTranscription,
          ),
        );
      case _Phase.running:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.pause_outlined, size: 18),
            label: Text(t.audiobook_transcribe_pause),
            onPressed: _pause,
          ),
        );
      case _Phase.finished:
        add(
          TextButton(
            onPressed: _discard,
            child: Text(t.audiobook_transcribe_discard),
          ),
        );
        add(
          FilledButton.icon(
            icon: const Icon(Icons.check_outlined, size: 18),
            label: Text(t.audiobook_transcribe_use_result),
            onPressed: _finishedSrt == null
                ? null
                : () => Navigator.pop(context, _finishedSrt),
          ),
        );
      case _Phase.error:
        add(
          FilledButton.icon(
            icon: const Icon(Icons.refresh_outlined, size: 18),
            label: Text(t.audiobook_transcribe_resume),
            onPressed: _refreshPlan,
          ),
        );
      case _Phase.checking:
      case _Phase.downloading:
      case _Phase.loading:
      case _Phase.pausing:
        break;
    }
    if (_busy && _phase != _Phase.running) {
      // 忙碌态给一个不可点的占位，避免按钮区跳动。
      add(
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return buttons;
  }
}
