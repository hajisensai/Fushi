/// 牌组设置里 RWKV 的说明、模型选择（本机）与下载 / 准备状态。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_asr_core/asr_core.dart' show ModelDownloadEvent;
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';

/// 下载大小（显示用）。
String _sizeOf(SrsRwkvModelChoice choice) =>
    choice == SrsRwkvModelChoice.small ? '5.6 MB' : '11 MB';

class SrsRwkvPanel extends ConsumerStatefulWidget {
  const SrsRwkvPanel({super.key});

  @override
  ConsumerState<SrsRwkvPanel> createState() => _SrsRwkvPanelState();
}

class _SrsRwkvPanelState extends ConsumerState<SrsRwkvPanel> {
  StreamSubscription<ModelDownloadEvent>? _download;
  double? _progress;
  Object? _downloadError;
  StreamSubscription<SrsRwkvStatus>? _statusSubscription;
  SrsRwkvService? _watched;
  SrsRwkvStatus? _status;

  @override
  void dispose() {
    unawaited(_download?.cancel());
    unawaited(_statusSubscription?.cancel());
    super.dispose();
  }

  void _watch(SrsRwkvService? service) {
    if (identical(service, _watched)) return;
    unawaited(_statusSubscription?.cancel());
    _watched = service;
    _status = service?.status;
    _statusSubscription = service?.statusChanges.listen((SrsRwkvStatus s) {
      if (mounted) setState(() => _status = s);
    });
  }

  Future<void> _startDownload(
    SrsRwkvModels models,
    SrsRwkvModelChoice choice,
  ) async {
    setState(() {
      _progress = 0;
      _downloadError = null;
    });
    _download = models
        .download(choice)
        .listen(
          (ModelDownloadEvent e) {
            if (mounted && e.totalBytes > 0) {
              setState(() => _progress = e.receivedBytes / e.totalBytes);
            }
          },
          onError: (Object error) {
            if (mounted) {
              setState(() {
                _progress = null;
                _downloadError = error;
              });
            }
          },
          onDone: () {
            if (!mounted) return;
            setState(() => _progress = null);
            final SrsRwkvService? service = _watched;
            if (service != null && _downloadError == null) {
              srsRunLogged('SrsRwkvService.start', service.start);
            }
          },
          cancelOnError: true,
        );
  }

  @override
  Widget build(BuildContext context) {
    final SrsRwkvModelChoice choice = ref.watch(srsRwkvModelChoiceProvider);
    final SrsRwkvModels? models = ref.watch(srsRwkvModelsProvider).valueOrNull;
    _watch(ref.watch(srsRwkvServiceProvider).valueOrNull);
    final TextStyle hintStyle = context.fushiType.bodySmall;
    final bool ready = models?.isReady(choice) ?? false;
    final SrsRwkvStatus? status = _status;

    final List<Widget> children = <Widget>[
      Text(t.srs_settings_rwkv_hint, style: hintStyle),
      Text(t.srs_settings_rwkv_retention_note, style: hintStyle),
      AdaptiveSettingsSegmentedRow<SrsRwkvModelChoice>(
        key: const ValueKey<String>('srs-settings-rwkv-model'),
        title: t.srs_settings_rwkv_model,
        subtitle: t.srs_settings_rwkv_model_hint,
        segments: <ButtonSegment<SrsRwkvModelChoice>>[
          ButtonSegment<SrsRwkvModelChoice>(
            value: SrsRwkvModelChoice.small,
            label: Text(t.srs_settings_rwkv_model_small),
          ),
          ButtonSegment<SrsRwkvModelChoice>(
            value: SrsRwkvModelChoice.large,
            label: Text(t.srs_settings_rwkv_model_large),
          ),
        ],
        selected: choice,
        onChanged: (SrsRwkvModelChoice v) {
          unawaited(ref.read(appProvider).setSrsRwkvModel(v.wire));
        },
      ),
    ];
    if (!ready) {
      final double? progress = _progress;
      children.add(
        progress != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.srs_settings_rwkv_downloading(
                      percent: (progress * 100).round(),
                    ),
                    style: hintStyle,
                  ),
                  LinearProgressIndicator(value: progress),
                ],
              )
            : Align(
                alignment: AlignmentDirectional.centerStart,
                child: FushiFilledButton(
                  key: const ValueKey<String>('srs-settings-rwkv-download'),
                  onPressed: models == null
                      ? null
                      : () => unawaited(_startDownload(models, choice)),
                  child: Text(
                    t.srs_settings_rwkv_download(size: _sizeOf(choice)),
                  ),
                ),
              ),
      );
      if (choice == SrsRwkvModelChoice.small) {
        children.add(Text(t.srs_settings_rwkv_license_small, style: hintStyle));
      }
      if (_downloadError case final Object error) {
        children.add(
          Text(
            t.srs_settings_rwkv_failed(error: error.toString()),
            style: hintStyle.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        );
      }
    } else if (status != null) {
      children.add(
        Text(
          switch (status.phase) {
            SrsRwkvPhase.ready => t.srs_settings_rwkv_ready,
            SrsRwkvPhase.preparing when status.total > 0 =>
              t.srs_settings_rwkv_preparing(
                done: status.replayed,
                total: status.total,
              ),
            SrsRwkvPhase.failed => t.srs_settings_rwkv_failed(
              error: '${status.error}',
            ),
            _ => t.srs_settings_rwkv_preparing_start,
          },
          style: status.phase == SrsRwkvPhase.failed
              ? hintStyle.copyWith(color: Theme.of(context).colorScheme.error)
              : hintStyle,
        ),
      );
    }
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final Widget child in children) ...<Widget>[
          child,
          SizedBox(height: gap),
        ],
      ],
    );
  }
}
