import 'dart:async';

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/asr_host/gpu_acceleration.dart';
import 'package:fushi/src/asr_host/gpu_runtime_pack.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置区「语音识别模型」组里的「GPU 加速环境」一行（只在 Windows 出现）。
///
/// GPU 环境不随包：平常在下模型时按显卡自动一起下（`gpuRuntimeToDownload`）。
/// 这里给手动控制：偏好四档（自动 / CUDA / DirectML / 关闭）、检测结果、当前生效
/// 的环境、补下载 / 移除，以及「重启后生效」提示。
class GpuAccelerationSettingsCard extends StatefulWidget {
  const GpuAccelerationSettingsCard({super.key});

  @override
  State<GpuAccelerationSettingsCard> createState() =>
      _GpuAccelerationSettingsCardState();
}

class _GpuAccelerationSettingsCardState
    extends State<GpuAccelerationSettingsCard> {
  GpuAccelerationStatus? _status;
  StreamSubscription<GpuRuntimeInstallProgress>? _install;
  GpuRuntimeInstallProgress? _progress;
  String? _error;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    unawaited(_install?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    final GpuAccelerationStatus status = await gpuAccelerationStatus();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _setPreference(GpuRuntimePreference preference) async {
    await writeGpuRuntimePreference(preference);
    await _refresh();
  }

  Future<void> _download(GpuRuntimeKind kind) async {
    final GpuRuntimeStore store = await gpuRuntimeStore(kind);
    if (!mounted) return;
    setState(() {
      _error = null;
      _progress = null;
    });
    _install = installGpuRuntime(store).listen(
      (GpuRuntimeInstallProgress p) {
        if (mounted) setState(() => _progress = p);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _install = null;
          _error = '$error';
        });
      },
      onDone: () {
        _install = null;
        unawaited(_refresh());
      },
      cancelOnError: true,
    );
    setState(() {});
  }

  Future<void> _cancel() async {
    await _install?.cancel();
    if (!mounted) return;
    setState(() {
      _install = null;
      _progress = null;
    });
  }

  Future<void> _remove(GpuRuntimeKind kind) async {
    setState(() => _removing = true);
    try {
      await (await gpuRuntimeStore(kind)).remove();
    } catch (error) {
      // 本进程正在用的 DLL 删不掉：说明原因，换偏好重启后再删即可。
      if (mounted) setState(() => _error = '$error');
    }
    if (!mounted) return;
    setState(() => _removing = false);
    unawaited(_refresh());
  }

  String _kindLabel(GpuRuntimeKind kind) => switch (kind) {
    GpuRuntimeKind.cuda => t.audiobook_transcribe_accel_cuda,
    GpuRuntimeKind.directml => t.audiobook_transcribe_accel_directml,
  };

  String _detectionText(GpuDetection detection) {
    final CudaDevice? card = detection.cuda.devices.isEmpty
        ? null
        : detection.cuda.devices.first;
    return switch (detectGpuRuntime(detection)) {
      GpuRuntimeKind.cuda => t.audiobook_transcribe_gpu_detected_cuda(
        name: card?.name ?? 'NVIDIA',
      ),
      GpuRuntimeKind.directml => t.audiobook_transcribe_gpu_detected_directml,
      null => t.audiobook_transcribe_gpu_detected_none,
    };
  }

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final GpuAccelerationStatus? status = _status;
    final bool downloading = _install != null;
    final GpuRuntimeKind? target = status?.target;
    final GpuRuntimeKind? active = status?.active;
    final (String badge, IconData badgeIcon, FushiTagTone tone) = downloading
        ? (
            t.manga_panel_model_downloading,
            FushiIcons.downloading,
            FushiTagTone.accent,
          )
        : active != null
        ? (_kindLabel(active), FushiIcons.downloadDone, FushiTagTone.success)
        : status?.restartRequired ?? false
        ? (
            t.audiobook_transcribe_gpu_restart,
            FushiIcons.pending,
            FushiTagTone.warning,
          )
        : (
            t.audiobook_transcribe_accel_cpu,
            FushiIcons.pending,
            FushiTagTone.neutral,
          );
    final String? errorText = _error ?? status?.error;
    final GpuRuntimeInstallProgress? progress = _progress;
    final GpuRuntimeEnvironment? targetEnv = target == null
        ? null
        : gpuRuntimeEnvironmentOf(target);
    return Padding(
      key: const ValueKey<String>('asr-models-row-gpu'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiListLeadingIcon(
                FushiIcons.speed,
                shape: downloading
                    ? FushiLeadingShape.cookie
                    : FushiLeadingShape.circle,
                tone: active != null
                    ? FushiCardTone.tertiary
                    : downloading
                    ? FushiCardTone.primary
                    : FushiCardTone.secondary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            t.audiobook_transcribe_gpu_title,
                            style: type.titleMediumEmphasized,
                          ),
                        ),
                        const SizedBox(width: 8),
                        FushiTag(
                          key: const ValueKey<String>('asr-models-status-gpu'),
                          text: badge,
                          icon: badgeIcon,
                          tone: tone,
                          dense: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.audiobook_transcribe_gpu_description,
                      style: type.bodyMedium.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (status?.detection
                        case final GpuDetection d) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        _detectionText(d),
                        style: type.bodySmall.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (status != null &&
                        status.preference != GpuRuntimePreference.off &&
                        target == null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        t.audiobook_transcribe_gpu_unsupported,
                        style: type.bodySmall.copyWith(color: cs.error),
                      ),
                    ],
                    if (errorText != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        t.audiobook_transcribe_gpu_failed(reason: errorText),
                        style: type.bodySmall.copyWith(color: cs.error),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (status != null) ...<Widget>[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 56),
              child: FushiSegmentedButton<GpuRuntimePreference>(
                key: const ValueKey<String>('asr-models-gpu-preference'),
                segments: <ButtonSegment<GpuRuntimePreference>>[
                  ButtonSegment<GpuRuntimePreference>(
                    value: GpuRuntimePreference.auto,
                    label: Text(t.audiobook_transcribe_gpu_pref_auto),
                  ),
                  ButtonSegment<GpuRuntimePreference>(
                    value: GpuRuntimePreference.cuda,
                    label: Text(t.audiobook_transcribe_accel_cuda),
                  ),
                  ButtonSegment<GpuRuntimePreference>(
                    value: GpuRuntimePreference.directml,
                    label: Text(t.audiobook_transcribe_accel_directml),
                  ),
                  ButtonSegment<GpuRuntimePreference>(
                    value: GpuRuntimePreference.off,
                    label: Text(t.audiobook_transcribe_gpu_pref_off),
                  ),
                ],
                selected: <GpuRuntimePreference>{status.preference},
                showSelectedIcon: false,
                onSelectionChanged: downloading
                    ? null
                    : (Set<GpuRuntimePreference> v) =>
                          unawaited(_setPreference(v.first)),
              ),
            ),
          ],
          FushiAnimatedSize(
            duration: motion.spatialDefault.duration,
            curve: motion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: downloading
                ? Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 56,
                      top: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        FushiLinearProgressIndicator(value: progress?.fraction),
                        const SizedBox(height: 6),
                        Text(
                          t.audiobook_transcribe_model_downloading(
                            name: progress?.fileName ?? '',
                            received: FushiByteFormat.bytes(
                              progress?.received ?? 0,
                            ),
                            total: FushiByteFormat.bytes(
                              progress?.total ?? targetEnv?.downloadBytes ?? 0,
                            ),
                          ),
                          style: type.bodySmall.tabular.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 56),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _actions(status, downloading),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(GpuAccelerationStatus? status, bool downloading) {
    if (status == null) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: FushiCircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (downloading) {
      return FushiTextButton(
        key: const ValueKey<String>('asr-models-cancel-gpu'),
        onPressed: () => unawaited(_cancel()),
        child: Text(t.dialog_cancel),
      );
    }
    final GpuRuntimeKind? target = status.target;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        if (target != null && !status.targetInstalled)
          FushiFilledButton.icon(
            key: const ValueKey<String>('asr-models-download-gpu'),
            onPressed: () => unawaited(_download(target)),
            icon: const FushiIcon(FushiIcons.download, size: 18),
            label: Text(
              t.audiobook_transcribe_gpu_download(
                name: _kindLabel(target),
                size: FushiByteFormat.bytes(
                  gpuRuntimeEnvironmentOf(target).downloadBytes,
                ),
              ),
            ),
          ),
        for (final GpuRuntimeKind kind in status.installed)
          FushiOutlinedButton.icon(
            key: ValueKey<String>('asr-models-delete-gpu-${kind.name}'),
            onPressed: _removing || status.active == kind
                ? null
                : () => unawaited(_remove(kind)),
            icon: const FushiIcon(FushiIcons.delete, size: 18),
            label: Text(
              t.audiobook_transcribe_gpu_remove(name: _kindLabel(kind)),
            ),
          ),
      ],
    );
  }
}
