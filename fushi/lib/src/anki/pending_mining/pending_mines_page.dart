import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart'
    show PendingMineRow, PendingMineStatus;

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_relay.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';

/// 订阅待发队列：表一变就重读一次（行数 / 行列表）。
mixin _PendingMineQueueListener<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  late final PendingMineStore store = pendingMineStoreFor(
    ref.read(appProvider),
  );
  StreamSubscription<void>? _changes;

  /// 表有变化（以及首帧）时调用。
  Future<void> reload();

  @override
  void initState() {
    super.initState();
    _changes = store.changes().listen((_) => unawaited(reload()));
    unawaited(reload());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }
}

/// Anki 设置页里的「待发卡片」入口行：显示张数，点进列表页。
class PendingMinesEntryRow extends ConsumerStatefulWidget {
  const PendingMinesEntryRow({super.key});

  @override
  ConsumerState<PendingMinesEntryRow> createState() =>
      _PendingMinesEntryRowState();
}

class _PendingMinesEntryRowState extends ConsumerState<PendingMinesEntryRow>
    with _PendingMineQueueListener<PendingMinesEntryRow> {
  int _count = 0;

  @override
  Future<void> reload() async {
    try {
      final int n = await store.count();
      if (mounted) setState(() => _count = n);
    } catch (_) {
      // 未初始化的最小宿主（widget 测试）没有库：当 0。
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      icon: Icons.outbox_outlined,
      showIcon: true,
      title: t.anki_pending_mines_title,
      subtitle: t.anki_pending_mines_hint,
      trailing: Text('$_count'),
      onTap: () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) => const PendingMinesPage(),
        ),
      ),
    );
  }
}

/// 「本机负责落地其他设备的卡片」开关（跨设备中转的落地设备，见
/// [PendingMineRelay]）。写同步域的设备本地偏好，下一轮同步时生效。
class PendingMineLandingSwitchRow extends ConsumerStatefulWidget {
  const PendingMineLandingSwitchRow({super.key});

  @override
  ConsumerState<PendingMineLandingSwitchRow> createState() =>
      _PendingMineLandingSwitchRowState();
}

class _PendingMineLandingSwitchRowState
    extends ConsumerState<PendingMineLandingSwitchRow> {
  bool _enabled = false;

  SyncRepository get _repo => SyncRepository(ref.read(appProvider).database);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bool enabled = await _repo.getPendingMineLandingClaimedAt() > 0;
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      // 未初始化的最小宿主（widget 测试）没有库：当关。
    }
  }

  Future<void> _set(bool enabled) async {
    setState(() => _enabled = enabled);
    await _repo.setPendingMineLanding(enabled);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsSwitchRow(
      icon: Icons.move_to_inbox_outlined,
      showIcon: true,
      title: t.anki_pending_mine_landing_title,
      subtitle: t.anki_pending_mine_landing_hint,
      value: _enabled,
      onChanged: (bool v) => unawaited(_set(v)),
    );
  }
}

/// 待发卡片列表：全部发送 / 单条重试 / 删除。
class PendingMinesPage extends ConsumerStatefulWidget {
  const PendingMinesPage({super.key});

  @override
  ConsumerState<PendingMinesPage> createState() => _PendingMinesPageState();
}

class _PendingMinesPageState extends ConsumerState<PendingMinesPage>
    with _PendingMineQueueListener<PendingMinesPage> {
  List<PendingMineRow> _rows = const <PendingMineRow>[];
  bool _sending = false;

  @override
  Future<void> reload() async {
    final List<PendingMineRow> rows = await store.all();
    if (mounted) setState(() => _rows = rows);
  }

  PendingMiningAnkiRepository? get _repo {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    return repo is PendingMiningAnkiRepository ? repo : null;
  }

  Future<void> _sendAll() async {
    final PendingMiningAnkiRepository? repo = _repo;
    if (repo == null || _sending) return;
    setState(() => _sending = true);
    try {
      final PendingFlushReport report = await repo.flush(interactive: true);
      if (!mounted || repo.switchesAppPerNote) return;
      FushiToast.show(
        msg: report.unreachable
            ? t.anki_pending_mines_unreachable
            : t.anki_pending_mines_flush_result(
                delivered: report.delivered,
                failed: report.failed,
                remaining: report.remaining,
              ),
        severity: report.unreachable || report.failed > 0
            ? ToastSeverity.warning
            : ToastSeverity.success,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(PendingMineRow row) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => FushiAlertDialog(
        content: Text(t.anki_pending_mines_delete_confirm),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          FushiTextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.anki_pending_mines_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.discard(row);
  }

  String _statusText(PendingMineRow row) => switch (row.status) {
    PendingMineStatus.sending => t.anki_pending_mines_status_sending,
    PendingMineStatus.failed => t.anki_pending_mines_status_failed(
      error: row.lastError ?? '',
    ),
    _ =>
      row.lastError == null
          ? t.anki_pending_mines_status_pending
          : '${t.anki_pending_mines_status_pending} · ${row.lastError}',
  };

  @override
  Widget build(BuildContext context) {
    final bool switchesApp = _repo?.switchesAppPerNote ?? false;
    return Scaffold(
      appBar: FushiAppBar(title: Text(t.anki_pending_mines_title)),
      // 空态走统一占位（图标 + 文案），不再是孤零零一行正文；行收进一个设置
      // 分组：MD3 = 中性圆角组，Apple = inset grouped 实色组 + 细分隔线，而不是
      // 散落在页面底色上的裸行。
      body: _rows.isEmpty
          ? Center(
              child: FushiPlaceholderMessage(
                icon: Icons.outbox_outlined,
                message: t.anki_pending_mines_empty,
              ),
            )
          : ListView(
              padding: EdgeInsets.only(
                bottom: FushiDesignTokens.of(context).spacing.section * 2,
              ),
              children: <Widget>[
                if (switchesApp)
                  AdaptiveSettingsSection(
                    children: <Widget>[
                      AdaptiveSettingsRow(
                        icon: Icons.info_outline,
                        showIcon: true,
                        title: t.anki_pending_mines_ankimobile_hint,
                        titleMaxLines: 4,
                      ),
                    ],
                  ),
                AdaptiveSettingsSection(
                  children: <Widget>[
                    for (final PendingMineRow row in _rows)
                      AdaptiveSettingsRow(
                        title: row.reading.isEmpty
                            ? row.expression
                            : '${row.expression}【${row.reading}】',
                        subtitle: _statusText(row),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (row.status == PendingMineStatus.failed)
                              FushiIconButtonControl(
                                tooltip: t.retry,
                                icon: const FushiIcon(Icons.refresh),
                                onPressed: () => store.retry(row.id),
                              ),
                            FushiIconButtonControl(
                              tooltip: t.anki_pending_mines_delete,
                              icon: const FushiIcon(Icons.delete_outline),
                              onPressed: () => _delete(row),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
      floatingActionButton: _rows.isEmpty
          ? null
          : FushiFab(
              onPressed: _sending ? null : _sendAll,
              icon: const FushiIcon(Icons.send),
              label: Text(t.anki_pending_mines_send_all),
            ),
    );
  }
}
