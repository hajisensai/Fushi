/// 复习的「同步与历史」页（docs/specs/2026-10-25-srs-sync-v2-design.md §10、§10.6）。取代旧的定时备份页：
///
/// - **同步状态**：本机身份、尚未传到全部位置的操作、各设备的进度 / 落后条数 / 最后见到 / 摘要不一致警告。
/// - **时间线**：自动还原点列表 + 任选时刻；恢复前预览会改动多少，可勾选一起撤回之后的复习。恢复是追加
///   补偿操作、不覆盖任何设备，内核先自动打一个还原点，所以恢复本身也能再恢复回去。
/// - **存储位置**：已有同步通道（云盘 / 互联）各算一个同步 + 媒体位置；另可「＋」本地文件夹（U 盘 / NAS / 被别的
///   同步工具同步的目录），每个勾选用途：同步 / 媒体 / 归档（只写不删，默认不勾）。取消用途或移除不删文件。
/// - **端到端加密**：每个位置一个可选开关（设计 §9，默认关）；别的设备开过的位置在这里输入同一个口令。
/// - **导出 / 导入** `.fushisrs`：离线保存或不连同步地搬家；导入是并入、不覆盖。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_folder_location.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/srs/srs_sync_settings.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

/// 「同步状态」摘要行标题：同步在跑时说进行中（不能说「所有改动都已同步」——数字是开跑前的
/// 快照），否则按未上传条数说。
String srsTimelineSummaryTitle({
  required SrsSyncProgress? syncing,
  required int unpublished,
}) {
  if (syncing != null) return t.srs_timeline_syncing;
  return unpublished > 0
      ? t.srs_timeline_unpublished(n: unpublished)
      : t.srs_timeline_all_published;
}

/// 一个还原点（内核 `sync2_checkpoints` 的一行）。
class SrsCheckpointView {
  const SrsCheckpointView({
    required this.at,
    required this.name,
    required this.reason,
    this.device = '',
    this.seq = 0,
  });

  factory SrsCheckpointView.fromJson(Map<String, Object?> j) =>
      SrsCheckpointView(
        at: (j['at'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        device: j['device'] as String? ?? '',
        seq: (j['seq'] as num?)?.toInt() ?? 0,
      );

  final int at;

  /// 打这个还原点的操作（恢复按它的因果截断）。
  final String device;
  final int seq;
  final String name;
  final String reason;
}

/// 还原点的人读原因（内核写的是稳定的英文短码）。
String srsCheckpointReasonLabel(String reason) => switch (reason) {
  'restore' => t.srs_timeline_reason_restore,
  'import' => t.srs_timeline_reason_import,
  'bulk_delete' => t.srs_timeline_reason_bulk_delete,
  'note_type' => t.srs_timeline_reason_note_type,
  'fsrs_params' => t.srs_timeline_reason_fsrs_params,
  'merge_notes' => t.srs_timeline_reason_merge_notes,
  _ => t.srs_timeline_reason_manual,
};

/// 一次恢复会改动多少（内核 `plan_restore` 的结果）。
class SrsRestorePlanView {
  const SrsRestorePlanView({
    required this.fields,
    required this.revived,
    required this.removed,
    required this.tags,
    required this.reviews,
  });

  factory SrsRestorePlanView.fromJson(Map<String, Object?> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return SrsRestorePlanView(
      fields: n('fields'),
      revived: n('revived'),
      removed: n('removed'),
      tags: n('tags'),
      reviews: n('reviews'),
    );
  }

  final int fields;
  final int revived;
  final int removed;
  final int tags;
  final int reviews;

  bool get isEmpty =>
      fields == 0 && revived == 0 && removed == 0 && tags == 0 && reviews == 0;
}

class SrsHistoryPage extends ConsumerStatefulWidget {
  const SrsHistoryPage({super.key});

  @override
  ConsumerState<SrsHistoryPage> createState() => _SrsHistoryPageState();
}

class _SrsHistoryPageState extends ConsumerState<SrsHistoryPage> {
  bool _loading = true;
  bool _busy = false;
  Map<String, Object?> _status = const <String, Object?>{};
  List<SrsCheckpointView> _checkpoints = const <SrsCheckpointView>[];

  /// 上一次看到的复习同步进度；从非 null 变回 null = 一轮刚跑完，要重读状态。
  SrsSyncProgress? _lastSyncProgress = srsSyncProgress.value;

  @override
  void initState() {
    super.initState();
    srsSyncProgress.addListener(_onSyncProgress);
    unawaited(_reload());
  }

  @override
  void dispose() {
    srsSyncProgress.removeListener(_onSyncProgress);
    super.dispose();
  }

  /// 一轮同步跑完（进度回到 null）后重读状态：未上传 / 落后条数要换成这轮之后的值，
  /// 否则状态卡停在开跑前的「还有 N 条没收到」。进度本身由状态卡就地监听，不整页重建。
  void _onSyncProgress() {
    final SrsSyncProgress? now = srsSyncProgress.value;
    final bool finished = _lastSyncProgress != null && now == null;
    _lastSyncProgress = now;
    if (finished && mounted) unawaited(_reload());
  }

  Future<void> _reload() async {
    final SrsDbStore? store = await readSrsStore(ref);
    Map<String, Object?> status = const <String, Object?>{};
    List<SrsCheckpointView> checkpoints = const <SrsCheckpointView>[];
    if (store != null) {
      try {
        status = await store.sync2Status();
        checkpoints = <SrsCheckpointView>[
          for (final Map<String, Object?> c in await store.sync2Checkpoints())
            SrsCheckpointView.fromJson(c),
        ];
      } catch (e, stack) {
        ErrorLogService.instance.log('SrsHistoryPage.reload', e, stack);
      }
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _checkpoints = checkpoints;
      _loading = false;
    });
  }

  /// 跑一个会改动复习库的操作：期间禁用按钮，失败统一提示。
  Future<void> _run(
    String where,
    Future<void> Function() body, {
    required String failure,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsHistoryPage.$where', e, stack);
      FushiToast.show(msg: failure, severity: ToastSeverity.error);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  // ---------------------------------------------------------------- 时间线

  Future<void> _pickMoment() async {
    final DateTime now = DateTime.now();
    final DateTime? day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 20),
      lastDate: now,
    );
    if (day == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !mounted) return;
    final DateTime at = DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
    );
    await _restore(at.isAfter(now) ? now : at);
  }

  Future<void> _restore(DateTime at, {SrsCheckpointView? checkpoint}) async {
    final ({String device, int seq})? cp =
        checkpoint == null || checkpoint.device.isEmpty
        ? null
        : (device: checkpoint.device, seq: checkpoint.seq);
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    final int atMs = at.millisecondsSinceEpoch;
    final SrsRestorePlanView keep;
    final SrsRestorePlanView retract;
    try {
      keep = SrsRestorePlanView.fromJson(
        await store.sync2PlanRestore(
          atMs,
          retractReviews: false,
          checkpoint: cp,
        ),
      );
      retract = SrsRestorePlanView.fromJson(
        await store.sync2PlanRestore(
          atMs,
          retractReviews: true,
          checkpoint: cp,
        ),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsHistoryPage.plan', e, stack);
      FushiToast.show(
        msg: t.srs_timeline_restore_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    final String time = srsTimeLabel(context, at);
    if (keep.isEmpty && retract.isEmpty) {
      FushiToast.show(msg: t.srs_timeline_restore_nothing(time: time));
      return;
    }
    final bool? retractReviews = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RestoreDialog(time: time, keep: keep, retract: retract),
    );
    if (retractReviews == null || !mounted) return;
    await _run('restore', () async {
      await store.sync2Restore(
        atMs,
        retractReviews: retractReviews,
        checkpoint: cp,
      );
      if (mounted) bumpSrsRevision(ref);
      FushiToast.show(
        msg: t.srs_timeline_restore_done(time: time),
        severity: ToastSeverity.success,
      );
    }, failure: t.srs_timeline_restore_failed);
  }

  Future<void> _addCheckpoint() => _run('checkpoint', () async {
    final String name = srsTimeLabel(context, DateTime.now());
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    await store.sync2Checkpoint(name, 'manual');
    FushiToast.show(
      msg: t.srs_timeline_checkpoint_done,
      severity: ToastSeverity.success,
    );
  }, failure: t.srs_timeline_checkpoint_failed);

  // ---------------------------------------------------------------- 存储位置

  Future<void> _saveFolders(List<SrsFolderLocation> folders) async {
    await ref.read(appProvider).setSrsFolderLocations(folders);
    // 改完立刻跑一轮文件夹位置（新加的马上有一份完整副本）；失败显示在该行上。
    await ref.read(srsAppRuntimeProvider)?.sync.syncFolderLocations();
  }

  Future<void> _addFolder() async {
    final String? path = await pickRealDirectoryPath(
      context: context,
      appModel: ref.read(appProvider),
      dialogTitle: t.srs_timeline_location_add,
    );
    if (path == null || !mounted) return;
    final List<SrsFolderLocation> folders = ref
        .read(appProvider)
        .srsFolderLocations;
    if (folders.any((SrsFolderLocation l) => l.path == path)) return;
    await _run('addFolder', () async {
      await _saveFolders(<SrsFolderLocation>[
        ...folders,
        SrsFolderLocation(
          id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
          path: path,
        ),
      ]);
    }, failure: t.srs_timeline_location_unavailable);
  }

  Future<void> _editFolder(SrsFolderLocation l) async {
    final SrsFolderLocation? edited = await showAppDialog<SrsFolderLocation>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _FolderPurposesDialog(location: l),
    );
    if (edited == null || !mounted) return;
    await _run('editFolder', () async {
      await _saveFolders(<SrsFolderLocation>[
        for (final SrsFolderLocation x
            in ref.read(appProvider).srsFolderLocations)
          x.id == l.id ? edited : x,
      ]);
    }, failure: t.srs_timeline_location_unavailable);
  }

  Future<void> _removeFolder(SrsFolderLocation l) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_timeline_location_remove,
      message: t.srs_timeline_location_remove_confirm,
      confirmLabel: t.srs_timeline_location_remove,
      cancelLabel: t.cancel,
      icon: FushiIcons.folder,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(appProvider).setSrsFolderLocations(<SrsFolderLocation>[
      for (final SrsFolderLocation x
          in ref.read(appProvider).srsFolderLocations)
        if (x.id != l.id) x,
    ]);
    if (mounted) setState(() {});
  }

  /// 位置的加密状态（最近一轮同步看到的；还没同步过的位置按本机记的密钥推断）。
  String? _cryptoLabel(String locationId) {
    final SrsLocationCryptoState? s = ref
        .read(srsAppRuntimeProvider)
        ?.sync
        .locationCrypto[locationId];
    if (s?.error == kSrsSync2NeedsKey) return t.srs_timeline_location_needs_key;
    if (s?.error == kSrsSync2WrongKey) return t.srs_timeline_location_wrong_key;
    if (s?.error == kSrsSync2EncryptionMissing) {
      return t.srs_timeline_location_encryption_missing;
    }
    if (s?.error == kSrsSync2BadKdf) return t.srs_timeline_location_bad_kdf;
    if (s?.encrypted ?? false) return t.srs_timeline_location_encrypted;
    final SrsLocationKey? k = ref.read(appProvider).srsLocationKeys[locationId];
    if (k != null && k.pendingEnable) {
      return t.srs_timeline_location_encrypt_pending;
    }
    return null;
  }

  /// 位置的加密：没开 → 设口令开启；要口令 / 口令不对 → 输入口令；已开 → 说明。
  Future<void> _encryption(String locationId) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return;
    final SrsLocationCryptoState? s = ref
        .read(srsAppRuntimeProvider)
        ?.sync
        .locationCrypto[locationId];
    final SrsLocationKey? k = ref.read(appProvider).srsLocationKeys[locationId];
    final SrsKdf? kdf = s?.kdf;
    if (s?.error == kSrsSync2EncryptionMissing && k != null) {
      // 位置上的 kdf 不见了（本机开过加密）：用本机这把密钥重新写上（同一份盐与校验值），不降级成明文。
      await _run('encrypt', () async {
        await ref
            .read(appProvider)
            .setSrsLocationKey(
              locationId,
              SrsLocationKey(keyHex: k.keyHex, kdf: k.kdf, pendingEnable: true),
            );
        await ref.read(srsAppRuntimeProvider)?.syncNow();
        FushiToast.show(
          msg: t.srs_timeline_location_encrypt_done,
          severity: ToastSeverity.success,
        );
      }, failure: t.srs_timeline_location_encrypt_failed);
      return;
    }
    if (s?.error == kSrsSync2BadKdf) {
      FushiToast.show(
        msg: t.srs_timeline_location_bad_kdf,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (s?.error != null && kdf != null) {
      final String? pass = await showAppDialog<String>(
        context: context,
        builder: (_) => const _PassphraseDialog(confirm: false),
      );
      if (pass == null || !mounted) return;
      await _run('unlock', () async {
        final SrsLocationKey key = await srsDeriveLocationKey(
          store,
          pass,
          kdf: kdf,
        );
        await ref.read(appProvider).setSrsLocationKey(locationId, key);
        await ref.read(srsAppRuntimeProvider)?.syncNow();
        final String? err = ref
            .read(srsAppRuntimeProvider)
            ?.sync
            .locationCrypto[locationId]
            ?.error;
        FushiToast.show(
          msg: err == kSrsSync2WrongKey
              ? t.srs_timeline_location_wrong_key
              : t.srs_timeline_location_unlocked,
          severity: err == null ? ToastSeverity.success : ToastSeverity.error,
        );
      }, failure: t.srs_timeline_location_encrypt_failed);
      return;
    }
    if ((s?.encrypted ?? false) || k != null) {
      FushiToast.show(msg: t.srs_timeline_location_encrypted_hint);
      return;
    }
    final String? pass = await showAppDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(confirm: true),
    );
    if (pass == null || !mounted) return;
    await _run('encrypt', () async {
      final SrsLocationKey key = await srsDeriveLocationKey(
        store,
        pass,
        pendingEnable: true,
      );
      await ref.read(appProvider).setSrsLocationKey(locationId, key);
      await ref.read(srsAppRuntimeProvider)?.syncNow();
      FushiToast.show(
        msg: t.srs_timeline_location_encrypt_done,
        severity: ToastSeverity.success,
      );
    }, failure: t.srs_timeline_location_encrypt_failed);
  }

  String _purposesLabel(SrsFolderLocation l) {
    if (l.idle) return t.srs_timeline_location_idle;
    return <String>[
      if (l.sync) t.srs_timeline_location_purpose_sync,
      if (l.media) t.srs_timeline_location_purpose_media,
      if (l.archive) t.srs_timeline_location_purpose_archive,
    ].join(' · ');
  }

  String _lastOkLabel(BuildContext context, int? lastOk) => lastOk == null
      ? t.srs_timeline_location_never
      : t.srs_timeline_location_last_ok(
          time: srsTimeLabel(
            context,
            DateTime.fromMillisecondsSinceEpoch(lastOk),
          ),
        );

  Widget _buildLocations(BuildContext context) {
    // 加密位置的上传进度记在 `<位置>#e` 下（srs_sync2_round.dart）：合回同一个位置显示，取较新的一次。
    final Map<String, int?> lastOk = <String, int?>{};
    for (final Object? x
        in (_status['locations'] as List<Object?>?) ?? const <Object?>[]) {
      if (x is! Map) continue;
      final String id = srsLocationOfProgressId(x['location'] as String? ?? '');
      final int? at = (x['lastOk'] as num?)?.toInt();
      final int? prev = lastOk[id];
      lastOk[id] = prev == null || (at != null && at > prev) ? at : prev;
    }
    final List<SrsFolderLocation> folders = ref
        .watch(appProvider)
        .srsFolderLocations;
    final Map<String, Object> errors =
        ref.read(srsAppRuntimeProvider)?.sync.folderErrors ??
        const <String, Object>{};
    final List<String> channels = <String>[
      for (final String id in lastOk.keys)
        if (!id.startsWith('folder:')) id,
    ]..sort();
    return AdaptiveSettingsSection(
      title: t.srs_timeline_locations,
      children: <Widget>[
        for (final String id in channels)
          AdaptiveSettingsRow(
            key: ValueKey<String>('srs_timeline_channel_$id'),
            title: id.contains(':') ? id.substring(id.indexOf(':') + 1) : id,
            subtitle: <String>[
              t.srs_timeline_location_channel,
              ?_cryptoLabel(id),
              _lastOkLabel(context, lastOk[id]),
            ].join(' · '),
            icon: _cryptoLabel(id) == null
                ? FushiIcons.cloudSync
                : FushiIcons.lock,
            showIcon: true,
            subtitleMaxLines: 2,
            onTap: _busy
                ? null
                : () => srsRunLogged(
                    'SrsHistory.encryption',
                    () => _encryption(id),
                  ),
          ),
        for (final SrsFolderLocation l in folders)
          AdaptiveSettingsRow(
            key: ValueKey<String>('srs_timeline_folder_${l.id}'),
            title: l.path,
            titleMaxLines: 3,
            subtitle: <String>[
              _purposesLabel(l),
              ?_cryptoLabel(l.locationId),
              if (errors.containsKey(l.id))
                t.srs_timeline_location_unavailable
              else
                _lastOkLabel(context, lastOk[l.locationId]),
            ].join(' · '),
            subtitleMaxLines: 3,
            icon: errors.containsKey(l.id)
                ? FushiIcons.warning
                : FushiIcons.folder,
            showIcon: true,
            onTap: _busy
                ? null
                : () => srsRunLogged(
                    'SrsHistory.editFolder',
                    () => _editFolder(l),
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIconButton(
                  key: ValueKey<String>('srs_timeline_folder_encrypt_${l.id}'),
                  icon: FushiIcons.lock,
                  tooltip: t.srs_timeline_location_encryption,
                  enabled: !_busy && (l.sync || l.archive),
                  onTap: () => srsRunLogged(
                    'SrsHistory.folderEncryption',
                    () => _encryption(l.locationId),
                  ),
                ),
                FushiIconButton(
                  key: ValueKey<String>('srs_timeline_folder_remove_${l.id}'),
                  icon: FushiIcons.delete,
                  tooltip: t.srs_timeline_location_remove,
                  enabled: !_busy,
                  onTap: () => srsRunLogged(
                    'SrsHistory.removeFolder',
                    () => _removeFolder(l),
                  ),
                ),
              ],
            ),
          ),
        AdaptiveSettingsNavigationRow(
          key: const ValueKey<String>('srs_timeline_location_add'),
          title: t.srs_timeline_location_add,
          subtitle: t.srs_timeline_location_add_hint,
          icon: FushiIcons.add,
          showIcon: true,
          onTap: () {
            if (!_busy) srsRunLogged('SrsHistory.addFolder', _addFolder);
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 导出 / 导入

  Future<Directory?> _mediaRoot(SrsDbStore store) async {
    final SrsMediaStore? media = await ref.read(srsMediaStoreProvider.future);
    return media?.root;
  }

  Future<void> _export() => _run('export', () async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final Directory? mediaRoot = await _mediaRoot(store);
    final DateTime c = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String name =
        'fushi-review-${c.year}${two(c.month)}${two(c.day)}-'
        '${two(c.hour)}${two(c.minute)}.$kSrsFushiSrsExtension';
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.srs_timeline_export,
        fileName: name,
      );
      if (savePath == null) return;
      await srsExportFushiSrs(store, File(savePath), mediaRoot: mediaRoot);
      FushiToast.show(
        msg: t.srs_timeline_export_done,
        severity: ToastSeverity.success,
      );
      return;
    }
    // 移动端走系统分享面板（iOS「存储到文件」/ iCloud 云盘、AirDrop；Android 各存储 app）。
    final Directory staging = await (await getTemporaryDirectory()).createTemp(
      'fushi_srs_export_',
    );
    final File out = File('${staging.path}${Platform.pathSeparator}$name');
    await srsExportFushiSrs(store, out, mediaRoot: mediaRoot);
    await FushiShare.shareFiles(<XFile>[
      XFile(out.path, mimeType: 'application/zip'),
    ], subject: name);
  }, failure: t.srs_timeline_export_failed);

  Future<void> _import() async {
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: <String>{kSrsFushiSrsExtension, 'zip'},
    );
    if (path == null || !mounted) return;
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.srs_timeline_import,
      message: t.srs_timeline_import_confirm,
      confirmLabel: t.srs_timeline_import,
      cancelLabel: t.cancel,
      icon: FushiIcons.importFile,
    );
    if (!ok || !mounted) return;
    String failure = t.srs_timeline_import_failed;
    await _run('import', () async {
      final SrsDbStore? store = await readSrsStore(ref);
      if (store == null) return;
      final SrsFushiSrsImport r;
      try {
        r = await srsImportFushiSrs(
          store,
          File(path),
          mediaRoot: await _mediaRoot(store),
          // 旧格式（v2 之前的定时 / 手动备份）没内嵌媒体时，到本机旧备份的共享媒体池里找。
          legacyMediaPool: Directory(
            p.join((await AppPaths.srsBackupsDirectory()).path, 'media'),
          ),
        );
      } on FormatException catch (e) {
        failure = e.message.contains('another profile')
            ? t.srs_timeline_import_other_profile
            : t.srs_timeline_import_invalid;
        rethrow;
      }
      if (mounted) bumpSrsRevision(ref);
      FushiToast.show(
        msg: t.srs_timeline_import_done(n: r.applied),
        severity: ToastSeverity.success,
      );
    }, failure: failure);
  }

  // ---------------------------------------------------------------- 顶栏

  List<FushiToolbarItem> get _actions => <FushiToolbarItem>[
    FushiToolbarItem(
      key: const ValueKey<String>('srs_timeline_checkpoint'),
      icon: FushiIcons.bookmark,
      label: t.srs_timeline_checkpoint_add,
      onPressed: _busy
          ? null
          : () => srsRunLogged('SrsHistory.checkpoint', _addCheckpoint),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_timeline_export'),
      icon: FushiIcons.upload,
      label: t.srs_timeline_export,
      onPressed: _busy
          ? null
          : () => srsRunLogged('SrsHistory.export', _export),
    ),
    FushiToolbarItem(
      key: const ValueKey<String>('srs_timeline_import'),
      icon: FushiIcons.importFile,
      label: t.srs_timeline_import,
      onPressed: _busy
          ? null
          : () => srsRunLogged('SrsHistory.import', _import),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_timeline_title,
      header: apple ? null : _buildTopBar(context),
      actions: apple
          ? <Widget>[
              for (final FushiToolbarItem a in _actions)
                FushiIconButton(
                  key: a.key,
                  icon: a.icon,
                  tooltip: a.label,
                  enabled: a.onPressed != null,
                  onTap: a.onPressed,
                ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.srs_timeline_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[_actions],
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final List<Map<String, Object?>> devices =
        <Map<String, Object?>>[
          for (final Object? d
              in (_status['devices'] as List<Object?>?) ?? const [])
            (d! as Map).cast<String, Object?>(),
        ]..sort((Map<String, Object?> a, Map<String, Object?> b) {
          if (a['self'] == true) return -1;
          if (b['self'] == true) return 1;
          return ((b['seenAt'] as num?) ?? 0).compareTo(
            (a['seenAt'] as num?) ?? 0,
          );
        });
    final int unpublished = (_status['unpublished'] as num?)?.toInt() ?? 0;
    final int pending = (_status['pending'] as num?)?.toInt() ?? 0;
    final int ops = (_status['ops'] as num?)?.toInt() ?? 0;
    // 状态数字是上次重读时的快照；同步在跑时它们正在变，不能说「都已同步」，
    // 摘要行换成进行中的阶段与进度，对端行的「没收到」换成「正在接收」。
    return ValueListenableBuilder<SrsSyncProgress?>(
      valueListenable: srsSyncProgress,
      builder: (BuildContext context, SrsSyncProgress? syncing, _) =>
          AdaptiveSettingsSection(
            title: t.srs_timeline_status,
            children: <Widget>[
              AdaptiveSettingsRow(
                key: const ValueKey<String>('srs_timeline_status_summary'),
                title: srsTimelineSummaryTitle(
                  syncing: syncing,
                  unpublished: unpublished,
                ),
                subtitle: syncing != null
                    ? srsSyncProgressLine(syncing)
                    : t.srs_timeline_ops(n: ops),
                icon: syncing != null
                    ? FushiIcons.sync
                    : (unpublished > 0
                          ? FushiIcons.cloudSync
                          : FushiIcons.success),
                showIcon: true,
              ),
              if (pending > 0)
                AdaptiveSettingsRow(
                  key: const ValueKey<String>('srs_timeline_status_pending'),
                  title: t.srs_timeline_waiting(n: pending),
                  subtitle: t.srs_timeline_waiting_hint,
                  icon: FushiIcons.schedule,
                  showIcon: true,
                ),
              for (final Map<String, Object?> d in devices)
                _deviceRow(context, d, syncing: syncing != null),
            ],
          ),
    );
  }

  Widget _deviceRow(
    BuildContext context,
    Map<String, Object?> d, {
    required bool syncing,
  }) {
    final String id = d['device'] as String? ?? '';
    final String name = (d['name'] as String?)?.trim() ?? '';
    final bool self = d['self'] == true;
    final int behind = (d['behind'] as num?)?.toInt() ?? 0;
    final int? seenAt = (d['seenAt'] as num?)?.toInt();
    final bool mismatch = d['digestMismatch'] == true;
    final bool frozen = d['frozen'] == true;
    final String? warning = d['warning'] as String?;
    final String title = self
        ? t.srs_timeline_this_device
        : (name.isEmpty ? srsShortDevice(id) : name);
    final List<String> meta = <String>[
      if (!self && seenAt != null)
        t.srs_timeline_seen(
          time: srsTimeLabel(
            context,
            DateTime.fromMillisecondsSinceEpoch(seenAt),
          ),
        ),
      if (behind > 0)
        syncing
            ? t.srs_timeline_receiving(n: behind)
            : t.srs_timeline_behind(n: behind),
      if (frozen) t.srs_timeline_frozen,
      if (mismatch) t.srs_timeline_digest_mismatch,
      if (warning != null && warning.isNotEmpty) t.srs_timeline_device_warning,
    ];
    return AdaptiveSettingsRow(
      key: ValueKey<String>('srs_timeline_device_$id'),
      title: title,
      subtitle: meta.isEmpty ? srsShortDevice(id) : meta.join(' · '),
      icon: mismatch || (warning?.isNotEmpty ?? false)
          ? FushiIcons.warning
          : (self ? FushiIcons.phone : FushiIcons.devices),
      showIcon: true,
      subtitleMaxLines: 3,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> items = <Widget>[
      // 常规同步 / 复习同步在跑时的进度条；都没在跑时零高度。
      const SyncProgressBanner(),
      // 复习数据随已有的同步通道走：没配通道时这里给出去处。
      Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        child: SrsSyncSettingsNotice(
          modules: ref.watch(appProvider).moduleVisibility,
        ),
      ),
      if (_status['enabled'] == true) _buildStatus(context),
      _buildLocations(context),
      AdaptiveSettingsSection(
        title: t.srs_timeline_section,
        children: <Widget>[
          AdaptiveSettingsNavigationRow(
            key: const ValueKey<String>('srs_timeline_restore_moment'),
            title: t.srs_timeline_restore_moment,
            subtitle: t.srs_timeline_restore_moment_hint,
            icon: FushiIcons.history,
            showIcon: true,
            onTap: () {
              if (!_busy) srsRunLogged('SrsHistory.pickMoment', _pickMoment);
            },
          ),
        ],
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.gap,
          tokens.spacing.section,
          tokens.spacing.gap,
          tokens.spacing.gap,
        ),
        child: Text(
          t.srs_timeline_checkpoints,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      if (_checkpoints.isEmpty)
        Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.bookmark,
            message: t.srs_timeline_checkpoints_empty,
            detail: t.srs_timeline_checkpoints_empty_hint,
          ),
        ),
      for (int i = 0; i < _checkpoints.length; i++)
        FushiPressScale(
          child: FushiGroupedListItem(
            key: ValueKey<String>(
              'srs-checkpoint-${_checkpoints[i].at}-${_checkpoints[i].name}',
            ),
            index: i,
            count: _checkpoints.length,
            onTap: _busy
                ? null
                : () => srsRunLogged(
                    'SrsHistory.restoreCheckpoint',
                    () => _restore(
                      DateTime.fromMillisecondsSinceEpoch(_checkpoints[i].at),
                      checkpoint: _checkpoints[i],
                    ),
                  ),
            child: FushiListItem(
              density: srsListDensityOf(context),
              leading: FushiListLeadingIcon(
                _checkpoints[i].reason == 'restore'
                    ? FushiIcons.restoreBackup
                    : FushiIcons.bookmark,
                tone: _checkpoints[i].reason == 'restore'
                    ? FushiCardTone.primary
                    : FushiCardTone.neutral,
              ),
              title: Text(
                srsTimeLabel(
                  context,
                  DateTime.fromMillisecondsSinceEpoch(_checkpoints[i].at),
                ),
              ),
              subtitle: Text(srsCheckpointReasonLabel(_checkpoints[i].reason)),
              trailing: const FushiIcon(FushiIcons.chevronRight),
            ),
          ),
        ),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap + MediaQuery.paddingOf(context).top,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: items.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

/// 恢复确认：列出会改动多少，勾选是否连之后的复习一起撤回。返回 null = 取消，否则是「撤回复习」。
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog({
    required this.time,
    required this.keep,
    required this.retract,
  });

  final String time;
  final SrsRestorePlanView keep;
  final SrsRestorePlanView retract;

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  bool _retract = false;

  @override
  Widget build(BuildContext context) {
    final SrsRestorePlanView p = _retract ? widget.retract : widget.keep;
    final List<String> lines = <String>[
      if (p.fields > 0) t.srs_timeline_plan_fields(n: p.fields),
      if (p.revived > 0) t.srs_timeline_plan_revived(n: p.revived),
      if (p.removed > 0) t.srs_timeline_plan_removed(n: p.removed),
      if (p.tags > 0) t.srs_timeline_plan_tags(n: p.tags),
      if (p.reviews > 0) t.srs_timeline_plan_reviews(n: p.reviews),
    ];
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.restoreBackup),
      title: Text(t.srs_timeline_restore_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(t.srs_timeline_restore_body(time: widget.time)),
          if (lines.isNotEmpty) Text(lines.join('\n')),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs_timeline_restore_retract'),
            title: t.srs_timeline_restore_retract,
            subtitle: t.srs_timeline_restore_retract_hint,
            value: _retract,
            horizontalPadding: 0,
            onChanged: (bool v) => setState(() => _retract = v),
          ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          kind: FushiDialogActionKind.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs_timeline_restore_confirm'),
          label: t.srs_timeline_restore,
          kind: FushiDialogActionKind.destructive,
          onPressed: () => Navigator.of(context).pop(_retract),
        ),
      ],
    );
  }
}

/// 一个文件夹位置的用途（可多选）。返回 null = 取消。
class _FolderPurposesDialog extends StatefulWidget {
  const _FolderPurposesDialog({required this.location});

  final SrsFolderLocation location;

  @override
  State<_FolderPurposesDialog> createState() => _FolderPurposesDialogState();
}

class _FolderPurposesDialogState extends State<_FolderPurposesDialog> {
  late SrsFolderLocation _l = widget.location;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.folder),
      title: Text(t.srs_timeline_location_purposes),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(_l.path, maxLines: 3, overflow: TextOverflow.ellipsis),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs_timeline_purpose_sync'),
            title: t.srs_timeline_location_purpose_sync,
            subtitle: t.srs_timeline_location_purpose_sync_hint,
            value: _l.sync,
            horizontalPadding: 0,
            onChanged: (bool v) => setState(() => _l = _l.copyWith(sync: v)),
          ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs_timeline_purpose_media'),
            title: t.srs_timeline_location_purpose_media,
            subtitle: t.srs_timeline_location_purpose_media_hint,
            value: _l.media,
            horizontalPadding: 0,
            onChanged: (bool v) => setState(() => _l = _l.copyWith(media: v)),
          ),
          AdaptiveSettingsSwitchRow(
            key: const ValueKey<String>('srs_timeline_purpose_archive'),
            title: t.srs_timeline_location_purpose_archive,
            subtitle: t.srs_timeline_location_purpose_archive_hint,
            value: _l.archive,
            horizontalPadding: 0,
            onChanged: (bool v) => setState(() => _l = _l.copyWith(archive: v)),
          ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          kind: FushiDialogActionKind.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs_timeline_purposes_save'),
          label: t.srs_note_save,
          kind: FushiDialogActionKind.primary,
          onPressed: () => Navigator.of(context).pop(_l),
        ),
      ],
    );
  }
}

/// 输入口令（[confirm] = 新开加密：输两遍、提示口令丢失的后果）。返回 null = 取消。
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.confirm});

  final bool confirm;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final TextEditingController _a = TextEditingController();
  final TextEditingController _b = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _submit() {
    final String pass = _a.text;
    if (pass.length < 8) {
      setState(() => _error = t.srs_timeline_passphrase_too_short);
      return;
    }
    if (widget.confirm && _b.text != pass) {
      setState(() => _error = t.srs_timeline_passphrase_mismatch);
      return;
    }
    Navigator.of(context).pop(pass);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.lock),
      title: Text(
        widget.confirm
            ? t.srs_timeline_location_encrypt
            : t.srs_timeline_location_unlock,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            widget.confirm
                ? t.srs_timeline_location_encrypt_body
                : t.srs_timeline_location_unlock_body,
          ),
          FushiTextField(
            key: const ValueKey<String>('srs_timeline_passphrase'),
            controller: _a,
            obscureText: true,
            autofocus: true,
            labelText: t.srs_timeline_passphrase,
            errorText: widget.confirm ? null : _error,
            onSubmitted: widget.confirm ? null : (_) => _submit(),
          ),
          if (widget.confirm)
            FushiTextField(
              key: const ValueKey<String>('srs_timeline_passphrase_again'),
              controller: _b,
              obscureText: true,
              labelText: t.srs_timeline_passphrase_again,
              errorText: _error,
              onSubmitted: (_) => _submit(),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          kind: FushiDialogActionKind.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs_timeline_passphrase_ok'),
          label: widget.confirm
              ? t.srs_timeline_location_encrypt
              : t.srs_timeline_location_unlock,
          kind: FushiDialogActionKind.primary,
          onPressed: _submit,
        ),
      ],
    );
  }
}
