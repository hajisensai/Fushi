import 'dart:async';
import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

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
          : _runs.isEmpty && _rejected.isEmpty
          ? Center(child: Text(t.library_organize_history_empty))
          : _buildList(context),
    );
  }

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
      library: domain == null ? run.run.domain : _domainLabel(domain),
      trigger: run.run.trigger == 'auto'
          ? t.library_organize_trigger_auto
          : t.library_organize_trigger_manual,
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
    final int n = switch (c.kind) {
      'tag' => (payload['videos'] as List<Object?>?)?.length ?? 0,
      _ => (payload['members'] as List<Object?>?)?.length ?? 0,
    };
    final String title = switch (c.kind) {
      'create' => t.library_organize_change_create(
        name: c.collectionName,
        n: n,
      ),
      'add' => t.library_organize_change_add(name: c.collectionName, n: n),
      'merge' => t.library_organize_change_merge(name: c.collectionName),
      'evict' => t.library_organize_change_evict(name: c.collectionName, n: n),
      _ => t.library_organize_change_tag(name: c.collectionName, n: n),
    };
    final IconData icon = switch (c.kind) {
      'create' => FushiIcons.add,
      'add' => FushiIcons.libraryAdd,
      'merge' => FushiIcons.merge,
      'evict' => FushiIcons.remove,
      _ => FushiIcons.tag,
    };
    final String source = c.source == 'rule'
        ? t.library_organize_source_rule
        : 'AI · ${c.confidence == 'high' ? t.library_organize_confidence_high : t.library_organize_confidence_medium}';
    final bool undone = c.undoneAt != null;
    return FushiListItem(
      key: ValueKey<String>('library_organize_change_${c.id}'),
      leading: FushiListLeadingIcon(icon),
      title: Text(title),
      titleMaxLines: 2,
      subtitle: Text(
        undone ? '$source · ${t.library_organize_change_undone}' : source,
      ),
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
