/// 牌组设置里 RWKV 的说明与下载 / 准备状态。下载由 [SrsRwkvService] 自己发起（RWKV 是默认算法，
/// 不能要求用户先来这里点下载）；这里只显示进度，失败时给「重试」。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';

import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/utils.dart';

/// 下载大小（显示用，小模型发布包）。
const String _downloadSize = '5.6 MB';

class SrsRwkvPanel extends ConsumerStatefulWidget {
  const SrsRwkvPanel({super.key});

  @override
  ConsumerState<SrsRwkvPanel> createState() => _SrsRwkvPanelState();
}

class _SrsRwkvPanelState extends ConsumerState<SrsRwkvPanel> {
  StreamSubscription<SrsRwkvStatus>? _statusSubscription;
  SrsRwkvService? _watched;
  SrsRwkvStatus? _status;

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final SrsRwkvService? service = ref
        .watch(srsRwkvServiceProvider)
        .valueOrNull;
    _watch(service);
    final TextStyle hintStyle = context.fushiType.bodySmall;
    final SrsRwkvStatus? status = _status;

    final List<Widget> children = <Widget>[
      Text(t.srs_settings_rwkv_hint, style: hintStyle),
      Text(t.srs_settings_rwkv_retention_note, style: hintStyle),
    ];
    if (status != null) {
      final TextStyle errorStyle = hintStyle.copyWith(
        color: Theme.of(context).colorScheme.error,
      );
      switch (status.phase) {
        case SrsRwkvPhase.downloading:
          final double? progress = status.total > 0
              ? status.done / status.total
              : null;
          children.add(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.srs_settings_rwkv_downloading(
                    percent: ((progress ?? 0) * 100).round(),
                  ),
                  style: hintStyle,
                ),
                FushiLinearProgressIndicator(value: progress),
              ],
            ),
          );
        case SrsRwkvPhase.failed:
          children
            ..add(
              Text(
                t.srs_settings_rwkv_failed(error: '${status.error}'),
                style: errorStyle,
              ),
            )
            ..add(
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FushiFilledButton(
                  key: const ValueKey<String>('srs-settings-rwkv-download'),
                  onPressed: service == null
                      ? null
                      : () => srsRunLogged(
                          'SrsRwkvService.start',
                          () => service.start(force: true),
                        ),
                  child: Text(
                    t.srs_settings_rwkv_download(size: _downloadSize),
                  ),
                ),
              ),
            );
        case SrsRwkvPhase.ready:
          children
            ..add(Text(t.srs_settings_rwkv_ready, style: hintStyle))
            ..add(
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FushiOutlinedButton(
                  key: const ValueKey<String>('srs-settings-rwkv-rebuild'),
                  onPressed: service == null
                      ? null
                      : () => srsRunLogged(
                          'SrsRwkvService.rebuild',
                          service.rebuild,
                        ),
                  child: Text(t.srs_settings_rwkv_rebuild),
                ),
              ),
            )
            ..add(Text(t.srs_settings_rwkv_rebuild_hint, style: hintStyle));
        case SrsRwkvPhase.preparing when status.total > 0:
          children.add(
            Text(
              t.srs_settings_rwkv_preparing(
                done: status.done,
                total: status.total,
              ),
              style: hintStyle,
            ),
          );
        case SrsRwkvPhase.preparing || SrsRwkvPhase.idle:
          children.add(
            Text(t.srs_settings_rwkv_preparing_start, style: hintStyle),
          );
      }
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
