/// 一条笔记的修改历史（docs/specs/2026-10-25-srs-sync-v2-design.md §10.2）：笔记与它每张卡的每一次修改——
/// 改了哪一项、改成什么、哪台设备、什么时候，含早已被后来的修改覆盖掉的。只读；要回到过去用「同步与历史」的时间线。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show ankiStripHtml;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_load_error.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

class SrsEditHistoryPage extends ConsumerStatefulWidget {
  const SrsEditHistoryPage({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<SrsEditHistoryPage> createState() => _SrsEditHistoryPageState();
}

/// 页面上的一行：哪个实体（笔记 / 第几张卡）+ 一条历史。
class _Row {
  const _Row(this.kind, this.cardIndex, this.entry);

  final SrsEntityKind kind;

  /// 卡片的序号（从 1 起；笔记为 null）。
  final int? cardIndex;
  final SrsHistoryEntry entry;
}

class _SrsEditHistoryPageState extends ConsumerState<SrsEditHistoryPage> {
  bool _loading = true;
  Object? _error;
  List<_Row> _rows = const <_Row>[];
  Map<String, String> _fieldNames = const <String, String>{};
  Map<String, String> _deviceNames = const <String, String>{};
  String? _self;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _retryLoad() {
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(_load());
  }

  /// 读笔记、它每张卡的修改历史与设备名。远程库连不上 / 回包不合契约时抛出的错误落成可重试的错误态，
  /// 不让页面停在转圈。
  Future<void> _load() async {
    try {
      await _loadRows();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsEditHistory.load', e, stack);
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadRows() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) throw StateError('srs store unavailable');
    final SrsNoteView? note = await store.note(widget.noteId);
    final SrsNoteTypeView? type = note == null
        ? null
        : await store.noteType(note.noteTypeId);
    final List<_Row> rows = <_Row>[
      for (final SrsHistoryEntry e in await store.editHistory(
        SrsEntityKind.note,
        widget.noteId,
      ))
        _Row(SrsEntityKind.note, null, e),
    ];
    final List<SrsCardCacheRow> cards = await store.cardsOfNote(widget.noteId);
    for (int i = 0; i < cards.length; i++) {
      for (final SrsHistoryEntry e in await store.editHistory(
        SrsEntityKind.card,
        cards[i].id,
      )) {
        rows.add(_Row(SrsEntityKind.card, i + 1, e));
      }
    }
    rows.sort((_Row a, _Row b) => b.entry.at.compareTo(a.entry.at));
    final Map<String, String> devices = await store.sync2DeviceNames();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _fieldNames = <String, String>{
        for (final SrsFieldDef f in type?.fields ?? const <SrsFieldDef>[])
          SrsFieldKeys.noteField(f.id): f.name,
      };
      _deviceNames = devices;
      _self = store.sync2Device;
      _error = null;
      _loading = false;
    });
  }

  String _what(_Row r) {
    final SrsHistoryEntry e = r.entry;
    final String label = e.key == SrsFieldKeys.noteTags
        ? t.srs_note_tags
        : (_fieldNames[e.key] ?? srsFieldKeyLabel(r.kind, e.key));
    return r.cardIndex == null
        ? label
        : '${t.srs_note_history_card(n: r.cardIndex!)} · $label';
  }

  String _value(SrsHistoryEntry e) {
    if (e.purged) return t.srs_note_history_purged;
    if (e.tagAdded != null) {
      return t.srs_note_history_tag_added(tag: e.tagAdded!);
    }
    if (e.tagRemoved != null) {
      return t.srs_note_history_tag_removed(tag: e.tagRemoved!);
    }
    if (e.key == SrsFieldKeys.deleted) {
      return e.value == null
          ? t.srs_note_history_restored
          : t.srs_note_history_deleted;
    }
    final Object? v = e.value;
    return v is String ? ankiStripHtml(v).trim() : srsFormatValue(v);
  }

  String _who(SrsHistoryEntry e) {
    if (e.writer == _self) {
      return t.srs_timeline_this_device;
    }
    return _deviceNames[e.writer] ?? srsShortDevice(e.writer);
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_note_history,
      header: apple ? null : _buildTopBar(context),
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
        title: t.srs_note_history,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SafeArea(bottom: false, child: FushiLoadingView());
    }
    if (_error != null) {
      return SrsLoadErrorView(
        error: _error,
        retryKey: const ValueKey<String>('srs-edit-history-load-retry'),
        onRetry: _retryLoad,
      );
    }
    if (_rows.isEmpty) {
      return SafeArea(
        bottom: false,
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.history,
            message: t.srs_note_history_empty,
          ),
        ),
      );
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
        itemCount: _rows.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final _Row r = _rows[i];
          final String value = _value(r.entry);
          return FushiGroupedListItem(
            key: ValueKey<String>('srs-history-$i'),
            index: i,
            count: _rows.length,
            child: FushiListItem(
              density: srsListDensityOf(context),
              leading: FushiListLeadingIcon(
                r.entry.purged
                    ? FushiIcons.delete
                    : (r.kind == SrsEntityKind.card
                          ? FushiIcons.ankiCard
                          : FushiIcons.edit),
                tone: r.entry.machine
                    ? FushiCardTone.neutral
                    : FushiCardTone.primary,
              ),
              title: Text(_what(r)),
              subtitle: SrsMetaLine(<String>[
                if (value.isNotEmpty) value,
                _who(r.entry),
                srsFormatMoment(r.entry.at),
              ]),
            ),
          );
        }),
      ),
    );
  }
}
