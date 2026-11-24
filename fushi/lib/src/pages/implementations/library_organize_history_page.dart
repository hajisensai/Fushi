import 'dart:async';
import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart'
    show
        OrganizeProposalKind,
        kMemberRemovalReasonDiscExtra,
        kMemberRemovalReasonDiscStale,
        kMemberRemovalReasonDiscSuperseded;
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart'
    show kOrganizeConvergenceTrigger;
import 'package:fushi_engine/media/video/disc/disc_library_import.dart'
    show kDiscImportOrganizeTrigger;
import 'package:fushi_engine/media/library_agent/library_changeset.dart'
    show kLibraryChangesetTrigger;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;

/// AI 整理记录（spec `docs/specs/2026-10-20-ai-library-organize-design.md` §12）：本机
/// 每一次整理做了什么，按次 / 按处撤销；以及被拒绝的分组（「允许再次建议」）。
///
/// 记录是设备本地的：别的设备的整理不在这里，但它们的结果（合集）照常同步过来。
Future<void> openLibraryOrganizeHistoryPage(
  BuildContext context,
  AppModel appModel,
) => Navigator.push<void>(
  context,
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => LibraryOrganizeHistoryPage(
      db: appModel.database,
      prefs: appModel.prefsRepo,
    ),
  ),
);

/// 一次运行最多列多少次（更早的仍在库里，只是不展示）。
const int kLibraryOrganizeHistoryRuns = 50;

class LibraryOrganizeHistoryPage extends StatefulWidget {
  const LibraryOrganizeHistoryPage({
    required this.db,
    required this.prefs,
    super.key,
  });

  final FushiDatabase db;
  final PreferencesRepository prefs;

  @override
  State<LibraryOrganizeHistoryPage> createState() =>
      _LibraryOrganizeHistoryPageState();
}

class _RunView {
  _RunView(this.run, this.changes);

  final LibraryOrganizeRunRow run;
  final List<LibraryOrganizeChangeRow> changes;
}

class _LibraryOrganizeHistoryPageState
    extends State<LibraryOrganizeHistoryPage> {
  List<_RunView> _runs = const <_RunView>[];
  List<({String key, String name})> _rejected =
      const <({String key, String name})>[];
  List<LibraryOrganizeProposalView> _proposals =
      const <LibraryOrganizeProposalView>[];
  bool _loading = true;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final FushiDatabase db = widget.db;
    final List<
      ({LibraryOrganizeRunRow run, List<LibraryOrganizeChangeRow> changes})
    >
    history = await loadLibraryOrganizeHistory(
      db,
      limit: kLibraryOrganizeHistoryRuns,
    );
    final List<LibraryOrganizeProposalView> proposals =
        await loadLibraryOrganizeProposals(db);
    final Set<String> allowed = widget.prefs.libraryOrganizeAllowedKeys;
    final List<({String key, String name})> rejected =
        <({String key, String name})>[
          for (final MapEntry<String, String> e
              in (await db.getRejectedOrganizeGroups()).entries)
            if (!allowed.contains(e.key)) (key: e.key, name: e.value),
        ];
    if (!mounted) return;
    setState(() {
      _runs = <_RunView>[
        for (final ({
              LibraryOrganizeRunRow run,
              List<LibraryOrganizeChangeRow> changes,
            })
            h
            in history)
          if (h.changes.isNotEmpty || h.run.error != null)
            _RunView(h.run, h.changes),
      ];
      _proposals = proposals;
      _rejected = rejected
        ..sort(
          (({String key, String name}) a, ({String key, String name}) b) =>
              a.name.compareTo(b.name),
        );
      _loading = false;
      _generation++;
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.library_organize_history_title,
      body: _loading
          ? const Center(child: FushiCircularProgressIndicator())
          : _runs.isEmpty && _rejected.isEmpty && _proposals.isEmpty
          ? Center(child: Text(t.library_organize_history_empty))
          // Builder：列表顶部留白要读脚手架注入正文子树的 MediaQuery（含页头大字
          // 高度）；State 自己的 context 在脚手架之上，量不到页头（BUG-5171）。
          : Builder(builder: _buildList),
    );
  }

  /// [context] 必须在 [FushiPageScaffold] 正文子树之内（见 build 里的 Builder）。
  Widget _buildList(BuildContext context) {
    const EdgeInsets groupPadding = EdgeInsets.symmetric(horizontal: 16);
    int order = 0;
    return FushiEntranceScope(
      replayKey: _generation,
      child: ListView(
        key: const ValueKey<String>('library_organize_history_list'),
        padding: EdgeInsets.only(
          top: 8 + MediaQuery.paddingOf(context).top,
          bottom: 24 + bottomSafeInsetOf(context),
        ),
        children: <Widget>[
          if (_proposals.isNotEmpty) ...<Widget>[
            FushiSectionTitle.group(
              t.library_organize_proposal_title,
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 6),
            ),
            for (final LibraryOrganizeProposalView p in _proposals)
              FushiStaggeredEntrance(index: order++, child: _proposalCard(p)),
          ],
          for (final _RunView run in _runs) ...<Widget>[
            _runHeader(run),
            FushiStaggeredEntrance(
              index: order++,
              child: FushiGroupedList(
                padding: groupPadding,
                children: <Widget>[
                  for (final LibraryOrganizeChangeRow c in run.changes)
                    _changeTile(c),
                  if (run.changes.isEmpty && run.run.error != null)
                    FushiListItem(
                      leading: const FushiListLeadingIcon(FushiIcons.warning),
                      title: Text(run.run.error!),
                    ),
                ],
              ),
            ),
          ],
          if (_rejected.isNotEmpty) ...<Widget>[
            FushiSectionTitle.group(
              t.library_organize_history_rejected_title,
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 6),
            ),
            FushiStaggeredEntrance(
              index: order++,
              child: FushiGroupedList(
                padding: groupPadding,
                children: <Widget>[
                  for (final ({String key, String name}) r in _rejected)
                    FushiListItem(
                      key: ValueKey<String>(
                        'library_organize_rejected_${r.key}',
                      ),
                      leading: const FushiListLeadingIcon(FushiIcons.block),
                      title: Text(r.name),
                      trailing: FushiTextButton(
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _guard(
                                  () => widget.prefs
                                      .addLibraryOrganizeAllowedKey(r.key),
                                ),
                              ),
                        child: Text(t.library_organize_history_allow_again),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _runHeader(_RunView run) {
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(run.run.startedAt);
    final CollectionShelfDomain? domain = CollectionShelfDomain.values
        .where((CollectionShelfDomain d) => d.name == run.run.domain)
        .firstOrNull;
    final String summary = t.library_organize_run_summary(
      // 'all'：AI 助手的一份变更集跨了几个库页（library.changes.apply）。
      library: domain != null
          ? _domainLabel(domain)
          : run.run.domain == 'all'
          ? t.library_organize_domain_all
          : run.run.domain,
      trigger: switch (run.run.trigger) {
        'auto' => t.library_organize_trigger_auto,
        kLibraryChangesetTrigger => t.library_organize_trigger_agent,
        kOrganizeConvergenceTrigger => t.library_organize_trigger_convergence,
        kDiscImportOrganizeTrigger => t.library_organize_trigger_disc_import,
        _ => t.library_organize_trigger_manual,
      },
      n: run.changes.length,
    );
    final bool anyLive = run.changes.any(
      (LibraryOrganizeChangeRow c) => c.undoneAt == null,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 24, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${MaterialLocalizations.of(context).formatShortDate(at)} '
              '${TimeOfDay.fromDateTime(at).format(context)} · $summary',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          if (anyLive)
            FushiTextButton(
              key: ValueKey<String>('library_organize_undo_run_${run.run.id}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _guard(() async {
                        await undoLibraryOrganizeChanges(widget.db, <int>[
                          for (final LibraryOrganizeChangeRow c in run.changes)
                            if (c.undoneAt == null) c.id,
                        ]);
                      }),
                    ),
              child: Text(t.library_organize_history_undo_run),
            ),
        ],
      ),
    );
  }

  Widget _changeTile(LibraryOrganizeChangeRow c) {
    final Map<String, Object?> payload = _payload(c.payloadJson);
    final String title = libraryOrganizeChangeTitle(c, payload);
    final IconData icon = libraryOrganizeChangeIcon(c.kind);
    final String source = c.source == 'rule'
        ? t.library_organize_source_rule
        : 'AI · ${c.confidence == 'high' ? t.library_organize_confidence_high : t.library_organize_confidence_medium}';
    final bool undone = c.undoneAt != null;
    // 移出 / 挪走带了 AI 给的理由：照原文显示（用户据此判断要不要撤销）。
    final Object? reason = payload['reason'];
    final List<String> subtitle = <String>[
      source,
      if (undone) t.library_organize_change_undone,
    ];
    return FushiListItem(
      key: ValueKey<String>('library_organize_change_${c.id}'),
      leading: FushiListLeadingIcon(icon),
      title: Text(title),
      titleMaxLines: 2,
      subtitle: Text(
        reason is String && reason.trim().isNotEmpty
            ? '${subtitle.join(' · ')}\n'
                  '${t.library_organize_change_reason(reason: reason.trim())}'
            : subtitle.join(' · '),
      ),
      subtitleMaxLines: 4,
      trailing: undone
          ? null
          : FushiTextButton(
              key: ValueKey<String>('library_organize_undo_${c.id}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _guard(() async {
                        await undoLibraryOrganizeChanges(widget.db, <int>[
                          c.id,
                        ]);
                      }),
                    ),
              child: Text(t.library_organize_undo),
            ),
    );
  }

  /// 待确认建议的确认卡（AI 库管家设计稿 §8）：动用户自己合集的合并 / 改名 / 移出
  /// 成员不直接生效，等用户在这里同意（以用户身份执行，可撤销）、这次不（本机暂缓）
  /// 或永远不（钉住相关成员，各设备都不再提）。用户 2026-11-24 拍板。
  Widget _proposalCard(LibraryOrganizeProposalView p) {
    final ThemeData theme = Theme.of(context);
    final String? reason = p.reason?.trim();
    final String? reasonCodeText = libraryOrganizeProposalReasonText(
      p.reasonCode,
    );
    final bool removal = p.kind == OrganizeProposalKind.removeMembers;
    return FushiCard(
      key: ValueKey<String>('library_organize_proposal_${p.id}'),
      variant: FushiCardVariant.outlined,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 12, top: 2),
                child: Icon(
                  switch (p.kind) {
                    OrganizeProposalKind.merge => FushiIcons.merge,
                    OrganizeProposalKind.rename => FushiIcons.edit,
                    OrganizeProposalKind.removeMembers => FushiIcons.remove,
                  },
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      libraryOrganizeProposalTitle(p),
                      style: theme.textTheme.titleSmall,
                    ),
                    if (removal && p.members.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        key: ValueKey<String>(
                          'library_organize_proposal_members_${p.id}',
                        ),
                        p.members
                            .map(
                              (OrganizeProposalMember m) =>
                                  t.library_organize_proposal_quoted(
                                    name: m.title,
                                  ),
                            )
                            .join(t.library_organize_proposal_separator),
                        style: theme.textTheme.bodyMedium,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (reasonCodeText != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        reasonCodeText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (reason != null && reason.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        t.library_organize_change_reason(reason: reason),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: <Widget>[
              // 「永远不」：记为拒绝并钉住相关成员（跨端生效）。
              FushiTextButton(
                key: ValueKey<String>(
                  'library_organize_proposal_decline_${p.id}',
                ),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _resolveProposal(
                          p,
                          OrganizeProposalDecision.rejectForever,
                        ),
                      ),
                child: Text(t.library_organize_proposal_never),
              ),
              // 「这次不」：本机暂缓 [kOrganizeProposalDeferDuration]。
              FushiTextButton(
                key: ValueKey<String>(
                  'library_organize_proposal_defer_${p.id}',
                ),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _resolveProposal(p, OrganizeProposalDecision.defer),
                      ),
                child: Text(t.library_organize_proposal_defer),
              ),
              FushiFilledButton(
                key: ValueKey<String>(
                  'library_organize_proposal_accept_${p.id}',
                ),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _resolveProposal(p, OrganizeProposalDecision.accept),
                      ),
                child: Text(
                  removal
                      ? t.library_organize_proposal_remove
                      : t.library_organize_proposal_accept,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _resolveProposal(
    LibraryOrganizeProposalView p,
    OrganizeProposalDecision decision,
  ) => _guard(() async {
    final OrganizeProposalState? state = await resolveLibraryOrganizeProposal(
      widget.db,
      p.id,
      decision: decision,
    );
    if (!mounted) return;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    // stale 的建议已被引擎标成非待确认，重新加载后卡片自然消失；这里只说明为什么
    // 没执行。
    // 新结果顶掉上一条提示（例如刚同意的「撤销」条），不排在它后面等。
    if (state == OrganizeProposalState.stale ||
        state == OrganizeProposalState.accepted) {
      messenger?.removeCurrentSnackBar();
    }
    if (state == OrganizeProposalState.stale) {
      messenger?.showSnackBar(
        FushiSnackBar(content: Text(t.library_organize_proposal_stale)),
      );
    } else if (state == OrganizeProposalState.accepted) {
      // 同意后给「撤销」：成员放回原位 / 拆回合并 / 改回原名，建议回到待确认。
      messenger?.showSnackBar(
        FushiSnackBar(
          key: ValueKey<String>('library_organize_proposal_applied_${p.id}'),
          content: Text(t.library_organize_proposal_applied),
          persist: false,
          action: SnackBarAction(
            label: t.library_organize_undo,
            onPressed: () => unawaited(_undoProposal(p.id)),
          ),
        ),
      );
    }
  });

  Future<void> _undoProposal(int id) => _guard(() async {
    final bool undone = await undoLibraryOrganizeProposal(widget.db, id);
    if (!undone && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        FushiSnackBar(content: Text(t.library_organize_proposal_undo_failed)),
      );
    }
  });

  static String _domainLabel(CollectionShelfDomain d) => switch (d) {
    CollectionShelfDomain.books => t.library_organize_domain_books,
    CollectionShelfDomain.manga => t.library_organize_domain_manga,
    CollectionShelfDomain.video => t.library_organize_domain_video,
    CollectionShelfDomain.games => t.library_organize_domain_games,
  };

  static Map<String, Object?> _payload(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // 坏记录只是展示不出计数。
    }
    return const <String, Object?>{};
  }
}

/// 整理记录里一处改动的标题（按 [LibraryOrganizeChangeRow.kind] 出文案）。
String libraryOrganizeChangeTitle(
  LibraryOrganizeChangeRow c,
  Map<String, Object?> payload,
) {
  final int n = switch (c.kind) {
    'tag' => (payload['videos'] as List<Object?>?)?.length ?? 0,
    _ => (payload['members'] as List<Object?>?)?.length ?? 0,
  };
  return switch (c.kind) {
    'create' => t.library_organize_change_create(name: c.collectionName, n: n),
    'add' => t.library_organize_change_add(name: c.collectionName, n: n),
    'merge' => t.library_organize_change_merge(name: c.collectionName),
    'evict' => t.library_organize_change_evict(name: c.collectionName, n: n),
    // 挪走：记录挂在去处合集上，来处在 payload.from 里。
    'move' => t.library_organize_change_move(
      from: switch (payload['from']) {
        final Map<Object?, Object?> from when from['name'] is String =>
          from['name']! as String,
        _ => '?',
      },
      name: c.collectionName,
      n: n,
    ),
    // 改名：记录挂在新名字上，原名在 payload.from（复用建议卡的「把 X 改名为 Y」）。
    'rename' => t.library_organize_proposal_rename(
      name: switch (payload['from']) {
        final String from => from,
        _ => '?',
      },
      newName: c.collectionName,
    ),
    _ => t.library_organize_change_tag(name: c.collectionName, n: n),
  };
}

/// 整理记录里一处改动的图标。
IconData libraryOrganizeChangeIcon(String kind) => switch (kind) {
  'create' => FushiIcons.add,
  'add' => FushiIcons.libraryAdd,
  'merge' => FushiIcons.merge,
  'evict' => FushiIcons.remove,
  'move' => FushiIcons.move,
  'rename' => FushiIcons.rename,
  _ => FushiIcons.tag,
};

/// removeMembers 建议的原因码 → 本地化说明；认不出的码返回 null（不显示）。
String? libraryOrganizeProposalReasonText(String? reasonCode) =>
    switch (reasonCode) {
      kMemberRemovalReasonDiscExtra =>
        t.library_organize_proposal_reason_disc_extra,
      kMemberRemovalReasonDiscStale =>
        t.library_organize_proposal_reason_disc_stale,
      kMemberRemovalReasonDiscSuperseded =>
        t.library_organize_proposal_reason_disc_superseded,
      _ => null,
    };

/// 一条待确认建议的标题：「把 X、Y 并进 Z」/「把 X 改名为 Y」/「从 X 移出 N 项」。
String libraryOrganizeProposalTitle(LibraryOrganizeProposalView p) =>
    switch (p.kind) {
      OrganizeProposalKind.removeMembers =>
        t.library_organize_proposal_remove_members(
          name: p.targetName,
          n: p.members.length,
        ),
      OrganizeProposalKind.merge => t.library_organize_proposal_merge(
        sources: p.sourceNames
            .map((String s) => t.library_organize_proposal_quoted(name: s))
            .join(t.library_organize_proposal_separator),
        name: p.targetName,
      ),
      OrganizeProposalKind.rename => t.library_organize_proposal_rename(
        name: p.targetName,
        newName: p.newName ?? '',
      ),
    };
