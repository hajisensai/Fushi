/// 复习的同步冲突：两台设备同时改了同一项设置 / 卡片标志时，后写的生效、被覆盖的
/// 留在这里，逐条「改回」（写被覆盖的值）或「确认」（写当前值）；另列出内容类
/// 待裁决的笔记（字段并发修改），点开进编辑页处理；以及同步 v2 扣住的删除（一台设备删了、
/// 另一台同时还在改 / 复习 / 移动它：删除先不生效、条目照常可见，等这里选「删除」或「保留」，
/// docs/specs/2026-10-25-srs-sync-v2-design.md §5.3）；以及疑似重复的笔记（两台设备各自制了同一个词，§5.4），
/// 用户选「合并」才合并（复习历史并入保留的那条），选「不是重复」就不再提示。
///
/// 每一边都显示是哪台设备（「<名称>（Fushi X.Y）」，srs/srs_device_view.dart）、什么时候改的；文本值画出差异；
/// 每条给默认推荐并写明理由（设置类：修改时间更晚的一边；扣住的删除：保留——另一边还有复习 / 修改，保留不丢数据），
/// 同类冲突（同一种实体的同一项 / 同一种删除冲突）可以一次都按这个选；顶栏「批量处理」再把被替换的设置、
/// 扣住的删除、可能重复的笔记各自一次处理完（待确认的设备与等你决定的笔记仍逐条处理）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show SrsNoteCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_duplicate_notes.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/pages/implementations/srs/srs_value_diff.dart';
import 'package:fushi/src/srs/srs_conflict_groups.dart';
import 'package:fushi/src/srs/srs_device_view.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/pages/implementations/srs/srs_load_error.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/srs/srs_navigation.dart';

/// 同步 v2 扣住的一次删除（内核 `sync2_conflicts` 的一行）。
class _HeldDelete {
  const _HeldDelete({
    required this.id,
    required this.kind,
    required this.by,
    required this.others,
    required this.at,
    required this.label,
  });

  final String id;

  /// `delete_edit` / `delete_review` / `delete_move`。
  final String kind;

  /// 删除它的设备。
  final String by;

  /// 与删除并发的修改条数。
  final int others;
  final int at;
  final String label;
}

/// 「批量处理」的选项：每一节一次按同一个选择处理全部条目。
enum _BulkAction {
  /// 被替换的设置：每条按它自己的推荐（修改时间更晚的一边）。
  settingsRecommended,

  /// 被替换的设置：都保留当前生效的值（原「全部确认」）。
  settingsCurrent,

  /// 扣住的删除：全部保留（推荐，不丢另一边的修改 / 复习）。
  heldKeep,

  /// 扣住的删除：全部以删除为准。
  heldDelete,

  /// 可能重复的笔记：每组保留复习最多的那条、其余并进来。
  duplicatesMerge,

  /// 可能重复的笔记：都标为不是重复。
  duplicatesDismiss;

  /// 删除 / 合并不好撤回：执行前再确认一次。
  bool get irreversible =>
      this == _BulkAction.heldDelete || this == _BulkAction.duplicatesMerge;
}

/// 冲突页的一条（标志 / 设置类）。
class _Conflict {
  const _Conflict({
    required this.kind,
    required this.entityId,
    required this.register,
    required this.entityLabel,
    this.valueLabels = const <String, String>{},
  });

  final SrsEntityKind kind;
  final String entityId;
  final SrsRegister register;

  /// 牌组名 / 卡片所属笔记的排序字段。
  final String entityLabel;

  /// 值是 ID 时的人读名（笔记的「笔记类型」冲突：类型 ID → 类型名）。
  final Map<String, String> valueLabels;

  String formatValue(Object? v) =>
      (v is String ? valueLabels[v] : null) ?? srsFormatValue(v);

  SrsFieldEdit get winner => register.winner!;
  SrsFieldEdit get loser => register.visibleLosers.first;

  /// 「同类」：同一种实体的同一项设置。
  String get group => '${kind.wire}/${register.key}';

  /// 推荐保留修改时间更晚的一边（一般就是当前生效的；时钟不准时可能是被替换的那边）。
  bool get recommendRevert => loser.hlc.physical > winner.hlc.physical;
}

class SrsConflictsPage extends ConsumerStatefulWidget {
  const SrsConflictsPage({super.key});

  @override
  ConsumerState<SrsConflictsPage> createState() => _SrsConflictsPageState();
}

class _SrsConflictsPageState extends ConsumerState<SrsConflictsPage> {
  bool _loading = true;
  List<_Conflict> _conflicts = const <_Conflict>[];
  List<SrsNoteCacheRow> _pending = const <SrsNoteCacheRow>[];
  List<_HeldDelete> _held = const <_HeldDelete>[];
  List<SrsDuplicateGroup> _duplicates = const <SrsDuplicateGroup>[];
  SrsDeviceDirectory _devices = SrsDeviceDirectory.empty;

  /// 本机还没信任的设备（待确认在前，再是已拒绝的）：它们的删除与彻底清除在本机扣着（内核 trust.rs）。
  List<SrsDeviceView> _untrusted = const <SrsDeviceView>[];

  /// 勾了「同类都按这个选」的组（[_Conflict.group] / 扣住删除的 `held/<kind>`）。
  final Set<String> _applySame = <String>{};

  /// 每组的条数（键同 [_applySame]），随数据载入一趟算好，build 只查表（BUG-4950）。
  Map<String, int> _sameCounts = const <String, int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  /// 读失败（复习库打开失败原样抛出、或读的途中出错）：页面显示错误态 + 重试，不停在转圈、不变成未处理异常。
  Object? _loadError;

  /// 有一次处理（写库）在跑：所有处理按钮禁用，不会对同一条冲突再排一次写（d6njR3G6zE：处理慢时连点
  /// 「保留」，后排的那几次写到已解决的冲突上，内核报 no such conflict）。
  bool _acting = false;

  /// 读的代次：只有最新一次 [_reload] 的结果落到页面上，先发后到的旧读不会把已处理掉的条目画回来。
  int _loadGen = 0;

  Future<void> _reload() async {
    final int gen = ++_loadGen;
    try {
      await _load(gen);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsConflictsPage.reload', e, stack);
      if (mounted && gen == _loadGen) {
        setState(() {
          _loadError = e;
          _loading = false;
        });
      }
    }
  }

  /// 错误态的「重试」：作废缓存着失败的复习库 provider 再重读。
  void _retryLoad() {
    retrySrsStoreOpen(ref);
    setState(() {
      _loadError = null;
      _loading = true;
    });
    unawaited(_reload());
  }

  Future<void> _load(int gen) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) {
      // 这里没有复习库（模块关着 / 存储此刻不可用）：说明原因，不停在转圈。
      if (mounted && gen == _loadGen) {
        setState(() {
          _loadError = t.module_disabled_hint;
          _loading = false;
        });
      }
      return;
    }
    final SrsDeckTree tree = await store.deckTree();
    final List<(SrsEntityKind, String, SrsRegister)> raw = await store
        .syncConflicts();
    final List<SrsNoteCacheRow> pending = await store.notesPendingDecision();
    final List<Map<String, Object?>> heldRaw = await store.sync2Conflicts();
    // 人读名整页一次批量取（BUG-4948）：以前逐条 cardDetail / note，6950 条冲突的库上一次重读 2 万次读、
    // 63 s，常驻内存翻倍到 3.3 GB，停在本页时进程意外退出。
    final List<(SrsEntityKind?, String)> refs = <(SrsEntityKind?, String)>[
      for (final (SrsEntityKind kind, String id, SrsRegister _) in raw)
        (kind, id),
      for (final Map<String, Object?> c in heldRaw)
        (
          SrsEntityKind.tryParse(c['entityKind'] as String?),
          c['entity'] as String? ?? '',
        ),
    ];
    final _EntityLabels labels = await _EntityLabels.load(
      store,
      tree,
      refs,
      needTypeNames: raw.any(
        ((SrsEntityKind, String, SrsRegister) c) =>
            c.$3.key == SrsFieldKeys.noteType,
      ),
    );
    final List<_Conflict> conflicts = <_Conflict>[
      for (final (SrsEntityKind kind, String id, SrsRegister reg) in raw)
        _Conflict(
          kind: kind,
          entityId: id,
          register: reg,
          entityLabel: labels.of(kind, id),
          valueLabels: reg.key == SrsFieldKeys.noteType
              ? labels.typeNames
              : const <String, String>{},
        ),
    ];
    final List<_HeldDelete> held = <_HeldDelete>[
      for (final Map<String, Object?> c in heldRaw)
        _HeldDelete(
          id: c['id'] as String? ?? '',
          kind: c['kind'] as String? ?? '',
          by: c['by'] as String? ?? '',
          others: (c['others'] as num?)?.toInt() ?? 0,
          at: (c['at'] as num?)?.toInt() ?? 0,
          label: labels.of(
            SrsEntityKind.tryParse(c['entityKind'] as String?),
            c['entity'] as String? ?? '',
          ),
        ),
    ];
    final List<SrsDuplicateGroup> duplicates = await store
        .duplicateNoteGroups();
    final SrsDeviceDirectory devices = await srsLoadDeviceDirectory(store);
    final List<SrsDeviceView> untrusted = srsUntrustedDevices(devices.all);
    final Map<String, int> sameCounts = <String, int>{
      ...srsSameGroupCounts(held, _heldGroup),
      ...srsSameGroupCounts(conflicts, (_Conflict c) => c.group),
    };
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _devices = devices;
      _untrusted = untrusted;
      _conflicts = conflicts;
      _pending = pending;
      _held = held;
      _sameCounts = sameCounts;
      _duplicates = duplicates;
      _loadError = null;
      _loading = false;
    });
  }

  /// 写入者的显示名：本机 / 「<名称>（Fushi X.Y）」/ 认不出给前 8 位 ID。
  String _who(String writerId) => _devices.label(
    writerId,
    selfLabel: t.srs_timeline_this_device,
    fallback: srsShortDevice(writerId),
    formatTime: (DateTime x) => srsTimeLabel(context, x),
  );

  static String _heldGroup(_HeldDelete c) => 'held/${c.kind}';

  /// build 里每张卡片都调：只查 [_sameCounts]，不得在这里扫列表（BUG-4949 / BUG-4950：
  /// 逐卡全表扫是 O(n²)，几千条扣住的删除让一次重建在主线程上跑几秒，iOS 退出时被看门狗杀）。
  int _sameCount(String group) => _sameCounts[group] ?? 0;

  void _toggleSame(String group, bool on) =>
      setState(() => on ? _applySame.add(group) : _applySame.remove(group));

  void _toastMany(int n) {
    if (n > 1) {
      FushiToast.show(
        msg: t.srs_conflict_resolved_many(n: n),
        severity: ToastSeverity.success,
      );
    }
  }

  /// 跑一次处理（写库）：同一时刻只跑一次，跑的期间所有处理按钮禁用；跑完（成功或失败）都重读整页。
  ///
  /// [body] 返回是否动过库（确认框里取消返回 false，不必重读）。失败也要重读（d6njR3G6zE）：以前写失败
  /// 就停在原处、不重读，列表里那条已经不存在的冲突（别处已处理、同步过来，或前一次点击已处理）一直留着，
  /// 每点一次「保留」都再报一次 no such conflict，用户只能看到点了没反应。批量处理可能写了一半才失败，
  /// 所以抛错时按「动过库」处理。错误本身照常交给 [srsRunLogged] 记录，不吞。
  void _act(String where, Future<bool> Function() body) {
    if (_acting) return;
    setState(() => _acting = true);
    srsRunLogged(where, () async {
      bool changed = true;
      try {
        changed = await body();
      } finally {
        if (mounted) {
          setState(() => _acting = false);
          if (changed) {
            bumpSrsRevision(ref);
            unawaited(_reload());
          }
        }
      }
    });
  }

  /// 信任（确认框说明扣着的会立即生效）/ 拒绝一台待确认的设备。
  Future<bool> _trustDevice(SrsDeviceView d, {required bool trust}) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null || !mounted) return false;
    final String name = _who(d.id);
    if (trust) {
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.srs_trust_confirm_title(device: name),
        message: t.srs_trust_confirm_body(n: d.heldDeletes + d.heldPurges),
        confirmLabel: t.srs_trust_action_trust,
        icon: FushiIcons.verified,
        destructive: d.heldPurges > 0,
      );
      if (!ok) return false;
    }
    await srsSetDeviceTrust(store, d.id, trust: trust);
    FushiToast.show(
      msg: trust
          ? t.srs_trust_trusted_toast(device: name)
          : t.srs_trust_rejected_toast(device: name),
      severity: ToastSeverity.success,
    );
    return true;
  }

  /// 处理完的条目先从页面上拿掉（不等整页重读：重读要把每条冲突的笔记 / 卡片都读一遍，条目多时很慢），
  /// 重读回来再以库里为准。
  void _dropResolved({
    Set<String> held = const <String>{},
    Set<_Conflict> conflicts = const <_Conflict>{},
    Set<SrsDuplicateGroup> duplicates = const <SrsDuplicateGroup>{},
  }) {
    if (!mounted) return;
    setState(() {
      _held = <_HeldDelete>[
        for (final _HeldDelete h in _held)
          if (!held.contains(h.id)) h,
      ];
      _conflicts = <_Conflict>[
        for (final _Conflict c in _conflicts)
          if (!conflicts.contains(c)) c,
      ];
      _duplicates = <SrsDuplicateGroup>[
        for (final SrsDuplicateGroup g in _duplicates)
          if (!duplicates.contains(g)) g,
      ];
    });
  }

  Future<bool> _resolveHeld(_HeldDelete c, {required bool delete}) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return false;
    final String group = _heldGroup(c);
    final List<_HeldDelete> targets = _applySame.contains(group)
        ? _held.where((_HeldDelete h) => _heldGroup(h) == group).toList()
        : <_HeldDelete>[c];
    for (final _HeldDelete h in targets) {
      await store.sync2Resolve(h.id, delete: delete);
    }
    _applySame.remove(group);
    _toastMany(targets.length);
    _dropResolved(held: <String>{for (final _HeldDelete h in targets) h.id});
    return true;
  }

  Future<bool> _mergeDuplicates(SrsDuplicateGroup g, String keepId) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return false;
    final SrsMergeReport r = await store.mergeNotes(
      keepId: keepId,
      absorbIds: <String>[
        for (final String id in g.noteIds)
          if (id != keepId) id,
      ],
    );
    FushiToast.show(
      msg: t.srs_duplicates_merged(n: r.linkedCards),
      severity: ToastSeverity.success,
    );
    _dropResolved(duplicates: <SrsDuplicateGroup>{g});
    return true;
  }

  Future<bool> _dismissDuplicates(SrsDuplicateGroup g) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return false;
    await store.dismissDuplicates(g.noteIds);
    _dropResolved(duplicates: <SrsDuplicateGroup>{g});
    return true;
  }

  Future<bool> _resolve(_Conflict c, {required bool revert}) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return false;
    final List<_Conflict> targets = _applySame.contains(c.group)
        ? _conflicts.where((_Conflict x) => x.group == c.group).toList()
        : <_Conflict>[c];
    for (final _Conflict x in targets) {
      await store.resolveConflict(
        x.kind,
        x.entityId,
        x.register.key,
        revert ? x.loser.value : x.winner.value,
      );
    }
    _applySame.remove(c.group);
    _toastMany(targets.length);
    _dropResolved(conflicts: targets.toSet());
    return true;
  }

  /// 批量处理：每一节一次按同一个选择处理全部条目（#IBjxAjty39）。只覆盖有明确选项、
  /// 不需要看内容的三节——被替换的设置、扣住的删除、可能重复的笔记；待确认的设备
  /// （信任是安全决定）和等你决定的笔记（要在编辑页看字段内容）仍逐条处理。
  Future<bool> _bulkResolve(_BulkAction action) async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return false;
    final List<_Conflict> conflicts = _conflicts;
    final List<_HeldDelete> held = _held;
    final List<SrsDuplicateGroup> duplicates = _duplicates;
    int done = 0;
    switch (action) {
      case _BulkAction.settingsRecommended:
      case _BulkAction.settingsCurrent:
        for (final _Conflict c in conflicts) {
          final bool revert =
              action == _BulkAction.settingsRecommended && c.recommendRevert;
          await store.resolveConflict(
            c.kind,
            c.entityId,
            c.register.key,
            revert ? c.loser.value : c.winner.value,
          );
          done++;
        }
        _applySame.removeWhere((String g) => !g.startsWith('held/'));
        _dropResolved(conflicts: conflicts.toSet());
      case _BulkAction.heldKeep:
      case _BulkAction.heldDelete:
        for (final _HeldDelete h in held) {
          await store.sync2Resolve(
            h.id,
            delete: action == _BulkAction.heldDelete,
          );
          done++;
        }
        _applySame.removeWhere((String g) => g.startsWith('held/'));
        _dropResolved(held: <String>{for (final _HeldDelete h in held) h.id});
      case _BulkAction.duplicatesMerge:
        // 每组保留排在最前的那条（复习最多的，平手取先创建的；srs_duplicate_notes.dart）。
        for (final SrsDuplicateGroup g in duplicates) {
          await store.mergeNotes(
            keepId: g.noteIds.first,
            absorbIds: g.noteIds.skip(1).toList(),
          );
          done++;
        }
        _dropResolved(duplicates: duplicates.toSet());
      case _BulkAction.duplicatesDismiss:
        for (final SrsDuplicateGroup g in duplicates) {
          await store.dismissDuplicates(g.noteIds);
          done++;
        }
        _dropResolved(duplicates: duplicates.toSet());
    }
    FushiToast.show(
      msg: t.srs_conflict_resolved_many(n: done),
      severity: ToastSeverity.success,
    );
    return true;
  }

  /// 「批量处理」：列出当前有条目的几节各自的批量选项；删除 / 合并这两种不好撤回的再确认一次。
  Future<bool> _openBulk() async {
    final List<FushiChoiceOption<_BulkAction>>
    options = <FushiChoiceOption<_BulkAction>>[
      if (_conflicts.isNotEmpty) ...<FushiChoiceOption<_BulkAction>>[
        FushiChoiceOption<_BulkAction>(
          value: _BulkAction.settingsRecommended,
          label: t.srs_conflicts_bulk_settings_recommended(
            n: _conflicts.length,
          ),
          icon: FushiIcons.lightbulb,
        ),
        FushiChoiceOption<_BulkAction>(
          value: _BulkAction.settingsCurrent,
          label: t.srs_conflicts_bulk_settings_current(n: _conflicts.length),
          icon: FushiIcons.check,
        ),
      ],
      if (_held.isNotEmpty) ...<FushiChoiceOption<_BulkAction>>[
        FushiChoiceOption<_BulkAction>(
          value: _BulkAction.heldKeep,
          label: t.srs_conflicts_bulk_held_keep(n: _held.length),
          icon: FushiIcons.restoreBackup,
        ),
        FushiChoiceOption<_BulkAction>(
          value: _BulkAction.heldDelete,
          label: t.srs_conflicts_bulk_held_delete(n: _held.length),
          icon: FushiIcons.delete,
        ),
      ],
      if (_duplicates.isNotEmpty) ...<FushiChoiceOption<_BulkAction>>[
        FushiChoiceOption<_BulkAction>(
          value: _BulkAction.duplicatesMerge,
          label: t.srs_conflicts_bulk_duplicates_merge(n: _duplicates.length),
          icon: FushiIcons.check,
        ),
        FushiChoiceOption<_BulkAction>(
          value: _BulkAction.duplicatesDismiss,
          label: t.srs_conflicts_bulk_duplicates_dismiss(n: _duplicates.length),
          icon: FushiIcons.close,
        ),
      ],
    ];
    if (options.isEmpty) return false;
    final _BulkAction? action = await showFushiChoiceDialog<_BulkAction>(
      context: context,
      title: t.srs_conflicts_bulk,
      message: t.srs_conflicts_bulk_hint,
      icon: FushiIcons.checklist,
      options: options,
    );
    if (action == null || !mounted) return false;
    if (action.irreversible) {
      final String label = options
          .firstWhere((FushiChoiceOption<_BulkAction> o) => o.value == action)
          .label;
      final bool ok = await showFushiConfirmDialog(
        context: context,
        title: t.srs_conflicts_bulk_confirm_title(n: _bulkCount(action)),
        message: label,
        icon: action == _BulkAction.heldDelete
            ? FushiIcons.delete
            : FushiIcons.checklist,
        destructive: action == _BulkAction.heldDelete,
      );
      if (!ok || !mounted) return false;
    }
    return _bulkResolve(action);
  }

  int _bulkCount(_BulkAction action) => switch (action) {
    _BulkAction.settingsRecommended ||
    _BulkAction.settingsCurrent => _conflicts.length,
    _BulkAction.heldKeep || _BulkAction.heldDelete => _held.length,
    _BulkAction.duplicatesMerge ||
    _BulkAction.duplicatesDismiss => _duplicates.length,
  };

  Future<void> _openNote(SrsNoteCacheRow row) async {
    await srsPushPage<void>(context, (_) => SrsNoteEditorPage(noteId: row.id));
    if (mounted) await _reload();
  }

  /// 「批量处理」：被替换的设置 / 扣住的删除 / 可能重复的笔记任一节有条目就画（#IBjxAjty39：
  /// 早先它只会「全部确认」字段冲突，页上只剩重复笔记时是一颗灰掉的按钮；正确做法是让批量
  /// 覆盖这几节，而不是把按钮删掉）。三节都空时页上只剩逐条处理的项，不画。
  FushiToolbarItem? get _bulkItem =>
      _conflicts.isEmpty && _held.isEmpty && _duplicates.isEmpty
      ? null
      : FushiToolbarItem(
          key: const ValueKey<String>('srs_conflicts_bulk'),
          icon: FushiIcons.checklist,
          label: t.srs_conflicts_bulk,
          onPressed: _acting
              ? null
              : () => _act('SrsConflicts.bulk', _openBulk),
        );

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final bool masthead = shellRedesignActive(context);
    final FushiToolbarItem? bulk = _bulkItem;
    return FushiPageScaffold(
      title: t.srs_conflicts_title,
      masthead: true,
      header: apple ? null : _buildTopBar(context, bulk),
      actions: (apple || masthead) && bulk != null
          ? <Widget>[
              FushiIconButton(
                key: bulk.key,
                icon: bulk.icon,
                tooltip: bulk.label,
                onTap: bulk.onPressed,
              ),
            ]
          : const <Widget>[],
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context, FushiToolbarItem? bulk) {
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
        title: t.srs_conflicts_title,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
        actions: <List<FushiToolbarItem>>[
          if (bulk != null) <FushiToolbarItem>[bulk],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    final Object? loadError = _loadError;
    if (loadError != null) {
      return SrsLoadErrorView(
        error: loadError,
        retryKey: const ValueKey<String>('srs-conflicts-load-retry'),
        onRetry: _retryLoad,
      );
    }
    if (_conflicts.isEmpty &&
        _untrusted.isEmpty &&
        _pending.isEmpty &&
        _held.isEmpty &&
        _duplicates.isEmpty) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.success,
            message: t.srs_conflicts_empty,
            detail: t.srs_conflicts_empty_hint,
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> items = <Widget>[
      if (_untrusted.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_trust_section),
        for (final SrsDeviceView d in _untrusted)
          _TrustCard(
            key: ValueKey<String>('srs-trust-${d.id}'),
            device: d,
            who: _who,
            onTrust: _acting
                ? null
                : () => _act(
                    'SrsConflicts.trustDevice',
                    () => _trustDevice(d, trust: true),
                  ),
            onReject: d.needsTrust && !_acting
                ? () => _act(
                    'SrsConflicts.rejectDevice',
                    () => _trustDevice(d, trust: false),
                  )
                : null,
          ),
      ],
      if (_held.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_conflicts_deletions),
        for (final _HeldDelete c in _held)
          _HeldDeleteCard(
            key: ValueKey<String>('srs-held-${c.id}'),
            conflict: c,
            who: _who,
            sameCount: _sameCount(_heldGroup(c)),
            applySame: _applySame.contains(_heldGroup(c)),
            onApplySameChanged: (bool on) => _toggleSame(_heldGroup(c), on),
            onDelete: _acting
                ? null
                : () => _act(
                    'SrsConflicts.applyDelete',
                    () => _resolveHeld(c, delete: true),
                  ),
            onKeep: _acting
                ? null
                : () => _act(
                    'SrsConflicts.keep',
                    () => _resolveHeld(c, delete: false),
                  ),
          ),
      ],
      if (_duplicates.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_duplicates_title),
        for (final SrsDuplicateGroup g in _duplicates)
          _DuplicateCard(
            key: ValueKey<String>('srs-dup-${g.noteIds.join('-')}'),
            group: g,
            onMerge: _acting
                ? null
                : (String keepId) => _act(
                    'SrsConflicts.merge',
                    () => _mergeDuplicates(g, keepId),
                  ),
            onDismiss: _acting
                ? null
                : () => _act(
                    'SrsConflicts.notDuplicate',
                    () => _dismissDuplicates(g),
                  ),
          ),
      ],
      if (_pending.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_conflicts_pending_notes),
        for (int i = 0; i < _pending.length; i++)
          FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('srs-pending-${_pending[i].id}'),
              index: i,
              count: _pending.length,
              onTap: () => srsRunLogged(
                'SrsConflicts.openNote',
                () => _openNote(_pending[i]),
              ),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(
                  FushiIcons.warning,
                  tone: FushiCardTone.error,
                ),
                title: Text(
                  _pending[i].sortField.isEmpty ? '—' : _pending[i].sortField,
                ),
                subtitle: Text(
                  _pending[i].deletedAt != null
                      ? t.srs_note_delete_conflict
                      : t.srs_note_field_conflict,
                ),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          ),
      ],
      if (_conflicts.isNotEmpty) ...<Widget>[
        FushiSectionTitle(t.srs_conflicts_settings),
        for (final _Conflict c in _conflicts)
          _ConflictCard(
            key: ValueKey<String>('srs-conflict-${c.register.winner!.id}'),
            conflict: c,
            who: _who,
            sameCount: _sameCount(c.group),
            applySame: _applySame.contains(c.group),
            onApplySameChanged: (bool on) => _toggleSame(c.group, on),
            onRevert: _acting
                ? null
                : () => _act(
                    'SrsConflicts.revert',
                    () => _resolve(c, revert: true),
                  ),
            onConfirm: _acting
                ? null
                : () => _act(
                    'SrsConflicts.confirm',
                    () => _resolve(c, revert: false),
                  ),
          ),
      ],
    ];
    return FushiEntranceScope(
      child: ListView.separated(
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
        separatorBuilder: (BuildContext context, int index) =>
            items[index] is FushiPressScale &&
                items[index + 1] is FushiPressScale
            ? const SizedBox.shrink()
            : SizedBox(height: tokens.spacing.gap * 1.5),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int index) => items[index],
        ),
      ),
    );
  }
}

/// 一组疑似重复的笔记：点一行选「保留这条」（默认复习最多的那条），「合并」把其余并进来。
class _DuplicateCard extends StatefulWidget {
  const _DuplicateCard({
    super.key,
    required this.group,
    required this.onMerge,
    required this.onDismiss,
  });

  final SrsDuplicateGroup group;

  /// 页面正在处理别的条目时为 null（按钮禁用）。
  final void Function(String keepId)? onMerge;
  final VoidCallback? onDismiss;

  @override
  State<_DuplicateCard> createState() => _DuplicateCardState();
}

class _DuplicateCardState extends State<_DuplicateCard> {
  late String _keep = widget.group.noteIds.first;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsDuplicateGroup g = widget.group;
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(t.srs_duplicates_hint, style: context.fushiType.bodySmall),
          for (int i = 0; i < g.noteIds.length; i++)
            FushiPressScale(
              child: FushiGroupedListItem(
                key: ValueKey<String>('srs-dup-row-${g.noteIds[i]}'),
                index: i,
                count: g.noteIds.length,
                onTap: () => setState(() => _keep = g.noteIds[i]),
                child: FushiListItem(
                  leading: FushiListLeadingIcon(
                    _keep == g.noteIds[i]
                        ? FushiIcons.check
                        : FushiIcons.ankiCard,
                    tone: _keep == g.noteIds[i]
                        ? FushiCardTone.primary
                        : FushiCardTone.neutral,
                  ),
                  title: Text(
                    (g.sortFields[g.noteIds[i]] ?? '').isEmpty
                        ? '—'
                        : g.sortFields[g.noteIds[i]]!,
                  ),
                  subtitle: Text(
                    <String>[
                      t.srs_duplicates_reviews(n: g.reviews[g.noteIds[i]] ?? 0),
                      if (_keep == g.noteIds[i]) t.srs_duplicates_keep,
                    ].join(' · '),
                  ),
                ),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiOutlinedButton.icon(
                key: const ValueKey<String>('srs-dup-dismiss'),
                onPressed: widget.onDismiss,
                icon: const FushiIcon(FushiIcons.close),
                label: Text(t.srs_duplicates_dismiss),
              ),
              FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('srs-dup-merge'),
                onPressed: widget.onMerge == null
                    ? null
                    : () => widget.onMerge!(_keep),
                icon: const FushiIcon(FushiIcons.check),
                label: Text(t.srs_duplicates_merge),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 推荐一行：「推荐：<选择>」+ 理由。
class _Recommendation extends StatelessWidget {
  const _Recommendation({required this.choice, required this.reason});

  final String choice;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color accent = Theme.of(context).colorScheme.primary;
    return Row(
      key: const ValueKey<String>('srs-conflict-recommendation'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: tokens.spacing.gap / 2,
      children: <Widget>[
        FushiIcon(FushiIcons.lightbulb, size: 18, color: accent),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: t.srs_conflict_recommended(choice: choice),
                  style: context.fushiType.bodyMedium.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text: ' · $reason',
                  style: context.fushiType.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 「同类 n 条冲突都按这个选」（只在同类不止一条时出现）。
class _ApplySame extends StatelessWidget {
  const _ApplySame({
    required this.count,
    required this.value,
    required this.onChanged,
    required this.groupKey,
  });

  final int count;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String groupKey;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return FushiCheckboxListTile(
      key: ValueKey<String>('srs-conflict-apply-same-$groupKey'),
      value: value,
      onChanged: (bool? v) => onChanged(v ?? false),
      contentPadding: EdgeInsets.zero,
      title: Text(
        t.srs_conflict_apply_same(n: count),
        style: context.fushiType.bodyMedium,
      ),
    );
  }
}

/// 冲突一边：标签、值、哪台设备什么时候改的；推荐的一边描边强调。
class _ConflictSide extends StatelessWidget {
  const _ConflictSide({
    required this.label,
    required this.value,
    required this.from,
    required this.recommended,
  });

  final String label;
  final String value;
  final String from;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      padding: EdgeInsets.all(tokens.spacing.gap),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(tokens.spacing.gap),
        border: Border.all(
          color: recommended ? cs.primary : cs.outlineVariant,
          width: recommended ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap / 4,
        children: <Widget>[
          Text(label, style: tokens.type.sectionLabel),
          Text(
            value,
            style: context.fushiType.bodyLarge,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          Text(from, style: context.fushiType.bodySmall),
        ],
      ),
    );
  }
}

/// 一台还没信任的设备：名称 / ID / 首次出现、扣着多少条删除与彻底清除，「信任」与「拒绝」（已拒绝的只剩「信任」）。
class _TrustCard extends StatelessWidget {
  const _TrustCard({
    super.key,
    required this.device,
    required this.who,
    required this.onTrust,
    required this.onReject,
  });

  final SrsDeviceView device;
  final String Function(String writerId) who;

  /// 页面正在处理别的条目时为 null（按钮禁用）。
  final VoidCallback? onTrust;

  /// 已拒绝的设备为 null（只能改为信任）。
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int? since = device.trustSince;
    final String body = device.needsTrust
        ? t.srs_trust_pending_body(
            deletes: device.heldDeletes,
            purges: device.heldPurges,
          )
        : t.srs_trust_rejected_body(
            deletes: device.heldDeletes,
            purges: device.heldPurges,
          );
    final VoidCallback? reject = onReject;
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Row(
            spacing: tokens.spacing.gap,
            children: <Widget>[
              FushiIcon(device.icon),
              Expanded(
                child: Text(
                  who(device.id),
                  style: context.fushiType.titleSmallEmphasized,
                ),
              ),
              FushiTag(
                text: device.needsTrust
                    ? t.srs_device_trust_pending
                    : t.srs_device_trust_rejected,
                tone: device.needsTrust
                    ? FushiTagTone.warning
                    : FushiTagTone.neutral,
                dense: true,
              ),
            ],
          ),
          Text(body, style: context.fushiType.bodyMedium),
          Text(
            SrsMetaLine.join(<String>[
              t.srs_trust_device_id(id: device.id),
              if (since != null)
                t.srs_trust_first_seen(time: srsFormatMoment(since)),
            ]),
            style: context.fushiType.bodySmall,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              if (reject != null)
                FushiPressScale(
                  child: FushiOutlinedButton.icon(
                    key: const ValueKey<String>('srs-trust-reject'),
                    onPressed: reject,
                    icon: const FushiIcon(FushiIcons.block),
                    label: Text(t.srs_trust_action_reject),
                  ),
                ),
              FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('srs-trust-accept'),
                  onPressed: onTrust,
                  icon: const FushiIcon(FushiIcons.verified),
                  label: Text(t.srs_trust_action_trust),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeldDeleteCard extends StatelessWidget {
  const _HeldDeleteCard({
    super.key,
    required this.conflict,
    required this.who,
    required this.sameCount,
    required this.applySame,
    required this.onApplySameChanged,
    required this.onDelete,
    required this.onKeep,
  });

  final _HeldDelete conflict;
  final String Function(String writerId) who;
  final int sameCount;
  final bool applySame;
  final ValueChanged<bool> onApplySameChanged;

  /// 页面正在处理别的条目时为 null（按钮禁用）。
  final VoidCallback? onDelete;
  final VoidCallback? onKeep;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String what = switch (conflict.kind) {
      'delete_review' => t.srs_conflict_deleted_while_reviewed(
        n: conflict.others,
      ),
      'delete_move' => t.srs_conflict_deleted_while_moved,
      _ => t.srs_conflict_deleted_while_edited(n: conflict.others),
    };
    // 推荐保留：另一边还有复习 / 修改，保留不丢；保留之后仍可再删，删了却回不来。
    final String reason = switch (conflict.kind) {
      'delete_review' => t.srs_conflict_reason_keep_reviews(n: conflict.others),
      'delete_move' => t.srs_conflict_reason_keep_move,
      _ => t.srs_conflict_reason_keep_edits(n: conflict.others),
    };
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(conflict.label, style: context.fushiType.titleSmallEmphasized),
          Text(what, style: context.fushiType.bodyMedium),
          Text(
            SrsMetaLine.join(<String>[
              who(conflict.by),
              srsFormatMoment(conflict.at),
            ]),
            style: context.fushiType.bodySmall,
          ),
          _Recommendation(choice: t.srs_conflict_keep, reason: reason),
          _ApplySame(
            count: sameCount,
            value: applySame,
            onChanged: onApplySameChanged,
            groupKey: conflict.kind,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FushiPressScale(
                child: FushiOutlinedButton.icon(
                  key: const ValueKey<String>('srs-held-delete'),
                  onPressed: onDelete,
                  icon: const FushiIcon(FushiIcons.delete),
                  label: Text(t.srs_conflict_apply_delete),
                ),
              ),
              FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('srs-held-keep'),
                  onPressed: onKeep,
                  icon: const FushiIcon(FushiIcons.check),
                  label: Text(t.srs_conflict_keep),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    super.key,
    required this.conflict,
    required this.who,
    required this.sameCount,
    required this.applySame,
    required this.onApplySameChanged,
    required this.onRevert,
    required this.onConfirm,
  });

  final _Conflict conflict;
  final String Function(String writerId) who;
  final int sameCount;
  final bool applySame;
  final ValueChanged<bool> onApplySameChanged;

  /// 页面正在处理别的条目时为 null（按钮禁用）。
  final VoidCallback? onRevert;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldEdit winner = conflict.winner;
    final SrsFieldEdit loser = conflict.loser;
    final bool revert = conflict.recommendRevert;
    final String key = srsFieldKeyLabel(conflict.kind, conflict.register.key);
    final String current = conflict.formatValue(winner.value);
    final String replaced = conflict.formatValue(loser.value);
    String from(SrsFieldEdit e) => SrsMetaLine.join(<String>[
      who(e.dot.writerId),
      srsFormatMoment(e.hlc.physical),
    ]);
    // 推荐的一边是实心按钮，另一边描边。
    Widget button({
      required String id,
      required bool primary,
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
    }) => FushiPressScale(
      child: primary
          ? FushiFilledButton.tonalIcon(
              key: ValueKey<String>(id),
              onPressed: onPressed,
              icon: FushiIcon(icon),
              label: Text(label),
            )
          : FushiOutlinedButton.icon(
              key: ValueKey<String>(id),
              onPressed: onPressed,
              icon: FushiIcon(icon),
              label: Text(label),
            ),
    );
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spacing.gap,
        children: <Widget>[
          Text(
            '${conflict.entityLabel} · $key',
            style: context.fushiType.titleSmallEmphasized,
          ),
          _ConflictSide(
            label: t.srs_conflict_current,
            value: current,
            from: from(winner),
            recommended: !revert,
          ),
          _ConflictSide(
            label: t.srs_conflict_replaced,
            value: replaced,
            from: from(loser),
            recommended: revert,
          ),
          SrsValueDiff(from: replaced, to: current),
          _Recommendation(
            choice: revert ? t.srs_conflict_replaced : t.srs_conflict_current,
            reason: t.srs_conflict_reason_later,
          ),
          _ApplySame(
            count: sameCount,
            value: applySame,
            onChanged: onApplySameChanged,
            groupKey: conflict.group,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              button(
                id: 'srs-conflict-revert',
                primary: revert,
                icon: FushiIcons.undo,
                label: t.srs_conflict_revert,
                onPressed: onRevert,
              ),
              button(
                id: 'srs-conflict-confirm',
                primary: !revert,
                icon: FushiIcons.check,
                label: t.srs_conflict_confirm,
                onPressed: onConfirm,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 冲突里实体的人读名：牌组全名 / 笔记（卡片按所属笔记）的排序字段（第一个字段去标签）/ 笔记类型名。
///
/// 整页的名字由 [load] 一次批量取齐（卡 / 笔记两条批量读 + 笔记类型一次），不按条读（BUG-4948）。
class _EntityLabels {
  _EntityLabels._(this._tree, this._cards, this._notes, this.typeNames);

  final SrsDeckTree _tree;
  final Map<String, String> _cards;
  final Map<String, String> _notes;

  /// 笔记类型 ID → 名称（有笔记类型实体、或「笔记类型」字段冲突时才读，否则空）。
  final Map<String, String> typeNames;

  static Future<_EntityLabels> load(
    SrsDbStore store,
    SrsDeckTree tree,
    List<(SrsEntityKind?, String)> refs, {
    required bool needTypeNames,
  }) async {
    final ({Map<String, String> cards, Map<String, String> notes}) sorted =
        await store.sortLabelsOf(
          cardIds: <String>[
            for (final (SrsEntityKind? k, String id) in refs)
              if (k == SrsEntityKind.card) id,
          ],
          noteIds: <String>[
            for (final (SrsEntityKind? k, String id) in refs)
              if (k == SrsEntityKind.note) id,
          ],
        );
    final bool wantTypes =
        needTypeNames ||
        refs.any(
          ((SrsEntityKind?, String) r) => r.$1 == SrsEntityKind.noteType,
        );
    final Map<String, String> typeNames = wantTypes
        ? <String, String>{
            for (final SrsNoteTypeView v in await store.noteTypes())
              v.id: v.name,
          }
        : const <String, String>{};
    return _EntityLabels._(tree, sorted.cards, sorted.notes, typeNames);
  }

  String of(SrsEntityKind? kind, String id) => switch (kind) {
    SrsEntityKind.deck => _tree[id] == null ? id : _tree.fullName(id),
    SrsEntityKind.card => _cards[id] ?? id,
    SrsEntityKind.note => _notes[id] ?? id,
    SrsEntityKind.noteType => typeNames[id] ?? id,
    SrsEntityKind.profile => t.srs_conflict_profile,
    null => id,
  };
}
