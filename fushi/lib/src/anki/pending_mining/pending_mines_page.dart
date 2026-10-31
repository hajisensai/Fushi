import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart'
    show PendingMineRow, PendingMineStatus;

import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_relay.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_kit.dart' show SettingsCountBadge;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「全部发送」结束后的 toast 文案：停下 / 失败时说清**为什么**。
///
/// 此前停下时一律报「连不上 Anki」——实际原因可能是连不上 Fushi 互联服务端、Anki
/// 未配置、同步客户端未登录……用户无从下手。原因走与单张制卡同一套本地化
/// （[localizeAnkiMineError]），未分类的失败退回后端原文。
@visibleForTesting
String pendingFlushMessage(PendingFlushReport report) {
  final MineOutcome? stop = report.stopOutcome;
  if (report.unreachable) {
    return stop == null
        ? t.anki_pending_mines_unreachable
        : t.anki_pending_mines_stopped(reason: _pendingFailureReason(stop));
  }
  final String summary = t.anki_pending_mines_flush_result(
    delivered: report.delivered,
    failed: report.failed,
    remaining: report.remaining,
  );
  final MineOutcome? failure = report.failureOutcome;
  return failure == null
      ? summary
      : '$summary\n${_pendingFailureReason(failure)}';
}

String _pendingFailureReason(MineOutcome outcome) {
  if (outcome.result == MineResult.notConfigured) {
    return t.card_export_not_configured;
  }
  final String? localized = localizeAnkiMineError(outcome.errorCode);
  if (localized != null) return localized;
  final String? detail = outcome.errorDetail;
  return detail != null && detail.isNotEmpty
      ? t.card_export_failed_detail(reason: detail)
      : t.card_export_failed;
}

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
  const PendingMinesEntryRow({super.key, this.hideWhenEmpty = false});

  /// 队列为空时整行不显示（挖词目标 = Fushi 复习时：新卡不再进这个 Anki 队列，
  /// 只剩切换前攒下的卡要处理）。
  final bool hideWhenEmpty;

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
    if (widget.hideWhenEmpty && _count == 0) return const SizedBox.shrink();
    return AdaptiveSettingsRow(
      icon: FushiIcons.cloudUpload,
      showIcon: true,
      title: t.anki_pending_mines_title,
      subtitle: t.anki_pending_mines_hint,
      trailing: SettingsCountBadge(count: _count),
      onTap: () => Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) => const PendingMinesPage(),
        ),
      ),
    );
  }
}

/// 「接收其他设备的卡片」开关（跨设备中转的落地设备，见
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

  /// 本机是互联主机：配对的手机经互联看不到主机的落地认领，要改走「制卡到 Fushi
  /// 互联服务端」。这句提示只对主机有意义，其它设备不显示。
  bool _hostingInterconnect = false;

  SyncRepository get _repo => SyncRepository(ref.read(appProvider).database);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final SyncRepository repo = _repo;
      final bool enabled = await repo.getPendingMineLandingClaimedAt() > 0;
      final bool hosting =
          await repo.isServerEnabled() && await repo.isInterconnectEnabled();
      if (mounted) {
        setState(() {
          _enabled = enabled;
          _hostingInterconnect = hosting;
        });
      }
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
      icon: FushiIcons.cloudDownload,
      showIcon: true,
      title: t.anki_pending_mine_landing_title,
      subtitle: _hostingInterconnect
          ? '${t.anki_pending_mine_landing_hint}\n'
                '${t.anki_pending_mine_landing_host_note}'
          : t.anki_pending_mine_landing_hint,
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

  /// 首次读表完成前显示骨架，而不是先闪一下空状态。
  bool _loaded = false;
  bool _sending = false;

  /// 最近一次读表失败（成功后清空）。首次读表就失败时结束骨架、显示错误态与
  /// 重试；已有数据时刷新失败保留旧列表（BUG-2996）。
  Object? _loadError;

  @override
  Future<void> reload() async {
    try {
      final List<PendingMineRow> rows = await store.all();
      if (mounted) {
        setState(() {
          _rows = rows;
          _loaded = true;
          _loadError = null;
        });
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('PendingMinesPage.reload', e, stack);
      if (mounted) {
        setState(() {
          _loaded = true;
          _loadError = e;
        });
      }
    }
  }

  void _retryLoad() {
    setState(() {
      _loaded = false;
      _loadError = null;
    });
    unawaited(reload());
  }

  /// 装饰链里的待发队列层。挖词目标 = Fushi 复习时最外层是 SRS 层，队列在它里面
  /// （切换前攒下的卡仍要补发给 Anki），所以沿 [DelegatingAnkiRepository.inner] 往里找。
  PendingMiningAnkiRepository? get _repo {
    BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    while (true) {
      if (repo is PendingMiningAnkiRepository) return repo;
      if (repo is! DelegatingAnkiRepository) return null;
      repo = repo.inner;
    }
  }

  Future<void> _sendAll() async {
    final PendingMiningAnkiRepository? repo = _repo;
    if (repo == null || _sending) return;
    setState(() => _sending = true);
    try {
      final PendingFlushReport report = await repo.flush(interactive: true);
      if (!mounted || repo.switchesAppPerNote) return;
      FushiToast.show(
        msg: pendingFlushMessage(report),
        severity: report.unreachable || report.failed > 0
            ? ToastSeverity.warning
            : ToastSeverity.success,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(PendingMineRow row) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.anki_pending_mines_delete,
      message: t.anki_pending_mines_delete_confirm,
      confirmLabel: t.anki_pending_mines_delete,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (confirmed) await store.discard(row);
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

  /// 行首状态色块：待发 = 中性、发送中 = primary、失败 = error。
  Widget _statusLeading(PendingMineRow row) => switch (row.status) {
    PendingMineStatus.sending => const FushiListLeadingIcon(
      FushiIcons.cloudUpload,
      tone: FushiCardTone.primary,
    ),
    PendingMineStatus.failed => const FushiListLeadingIcon(
      FushiIcons.error,
      tone: FushiCardTone.error,
    ),
    _ => const FushiListLeadingIcon(FushiIcons.pending),
  };

  Widget _rowTile(PendingMineRow row) {
    return FushiListItem(
      leading: _statusLeading(row),
      title: Text(
        row.reading.isEmpty
            ? row.expression
            : '${row.expression}【${row.reading}】',
      ),
      subtitle: Text(_statusText(row)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (row.status == PendingMineStatus.failed)
            FushiIconButtonControl.filledTonal(
              tooltip: t.retry,
              icon: const FushiIcon(FushiIcons.refresh),
              onPressed: () => store.retry(row.id),
            ),
          FushiIconButtonControl(
            tooltip: t.anki_pending_mines_delete,
            icon: const FushiIcon(FushiIcons.delete),
            onPressed: () => _delete(row),
          ),
        ],
      ),
    );
  }

  Widget _skeleton(BuildContext context, double gutter) {
    // 骨架：三行占位分段卡，与真实行同高，读表完成后原位替换。
    return ListView(
      // 顶部让出「状态栏 + 浮动页头」，与真实列表同位。
      padding: EdgeInsets.fromLTRB(
        gutter,
        8 + MediaQuery.paddingOf(context).top,
        gutter,
        8,
      ),
      children: <Widget>[
        FushiSkeletonShimmer(
          child: FushiGroupedList(
            children: <Widget>[
              for (int i = 0; i < 3; i++)
                SizedBox(
                  height: 72,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: <Widget>[
                        const FushiSkeleton(
                          width: 40,
                          height: 40,
                          circle: true,
                        ),
                        const SizedBox(width: 16),
                        Expanded(child: FushiSkeleton.line(widthFactor: 0.6)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, bool switchesApp) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gutter = tokens.spacing.page;
    if (!_loaded) return _skeleton(context, gutter);
    final Object? loadError = _loadError;
    if (loadError != null && _rows.isEmpty) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.error,
            tone: FushiPlaceholderTone.error,
            message: t.error_load_failed,
            detail: '$loadError',
            action: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('pending-mines-load-retry'),
              onPressed: _retryLoad,
              icon: const FushiIcon(FushiIcons.refresh),
              label: Text(t.retry),
            ),
          ),
        ),
      );
    }
    // 空态走统一占位（M3E 色块图标 + 文案）。
    if (_rows.isEmpty) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.success,
            message: t.anki_pending_mines_empty,
          ),
        ),
      );
    }
    final List<Widget> sections = <Widget>[
      if (switchesApp)
        FushiCard(
          tone: FushiCardTone.tertiary,
          child: Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.info),
              const SizedBox(width: 12),
              Expanded(child: Text(t.anki_pending_mines_ankimobile_hint)),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Row(
          children: <Widget>[
            Text(
              t.anki_pending_mines_title,
              style: context.fushiType.titleSmallEmphasized,
            ),
            const SizedBox(width: 8),
            SettingsCountBadge(count: _rows.length),
          ],
        ),
      ),
      // 分段卡片：首尾大圆角、行间 2px；每行错峰进场。
      FushiGroupedList(
        children: <Widget>[
          for (int i = 0; i < _rows.length; i++)
            FushiStaggeredEntrance(
              key: ValueKey<Object>(_rows[i].id),
              index: i,
              child: _rowTile(_rows[i]),
            ),
        ],
      ),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            gutter,
            // 正文滚到浮动页头底下：顶部让出「状态栏 + 页头」。
            8 + MediaQuery.paddingOf(context).top,
            gutter,
            // 给悬浮 FAB 让出位置。
            tokens.spacing.section * 2 + 72,
          ),
        ),
        itemCount: sections.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: 12),
        itemBuilder: (BuildContext context, int index) => sections[index],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool switchesApp = _repo?.switchesAppPerNote ?? false;
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.anki_pending_mines_title,
      // 「全部发送」按设计系统各取原生位置：Apple = 导航栏右上角按钮（FAB 在
      // Apple 下不存在），MD3 = 右下扩展 FAB。
      actions: <Widget>[
        if (apple && _rows.isNotEmpty)
          FushiIconButton(
            key: const ValueKey<String>('pending-mines-send-all'),
            icon: FushiIcons.upload,
            tooltip: t.anki_pending_mines_send_all,
            enabled: !_sending,
            onTap: _sendAll,
          ),
      ],
      // Builder：正文要在页头脚手架之内取 MediaQuery 顶部让位（状态栏 + 浮动页头）。
      body: Builder(
        builder: (BuildContext context) => _buildBody(context, switchesApp),
      ),
      floatingActionButton: apple || _rows.isEmpty
          ? null
          : FushiFab(
              onPressed: _sending ? null : _sendAll,
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 24,
                      child: FushiCircularProgressIndicator(strokeWidth: 3),
                    )
                  : const FushiIcon(FushiIcons.upload),
              label: Text(t.anki_pending_mines_send_all),
            ),
    );
  }
}
