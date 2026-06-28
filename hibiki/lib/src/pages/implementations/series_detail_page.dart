import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

class SeriesMember {
  const SeriesMember({required this.row, required this.card});
  final ShelfEntryRow row;
  final Widget card;
}

typedef SeriesMemberCardBuilder = Widget? Function(ShelfEntryRow row);

class SeriesDetailPage extends StatefulWidget {
  const SeriesDetailPage({
    required this.database,
    required this.seriesId,
    required this.initialName,
    required this.memberCardBuilder,
    required this.onChanged,
    super.key,
  });

  final HibikiDatabase database;
  final int seriesId;
  final String initialName;
  final SeriesMemberCardBuilder memberCardBuilder;
  final VoidCallback onChanged;

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  late String _name;
  List<ShelfEntryRow> _rows = const <ShelfEntryRow>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _name = widget.initialName;
    _reload();
  }

  Future<void> _reload() async {
    final List<ShelfEntryRow> rows =
        await widget.database.getShelfEntriesBySeries(widget.seriesId);
    rows.sort((ShelfEntryRow a, ShelfEntryRow b) {
      final int c = a.sortOrder.compareTo(b.sortOrder);
      return c != 0 ? c : a.entryKey.compareTo(b.entryKey);
    });
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  List<SeriesMember> get _members {
    final List<SeriesMember> out = <SeriesMember>[];
    for (final ShelfEntryRow row in _rows) {
      final Widget? card = widget.memberCardBuilder(row);
      if (card != null) out.add(SeriesMember(row: row, card: card));
    }
    return out;
  }

  Future<void> _rename() async {
    final String? newName = await showSeriesNameDialog(
      context: context,
      title: t.rename_series,
      initialName: _name,
    );
    if (newName == null || newName == _name) return;
    await widget.database.updateSeriesName(widget.seriesId, newName);
    if (!mounted) return;
    setState(() => _name = newName);
    widget.onChanged();
  }

  Future<void> _deleteSeries() async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => _SeriesConfirmDialog(
        title: t.delete_series,
        message: t.delete_series_confirm,
        confirmLabel: t.delete_series,
        destructive: true,
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true) return;
    await widget.database.deleteSeries(widget.seriesId);
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  Future<void> _removeMember(ShelfEntryRow row) async {
    await widget.database.setSeriesForEntry(row.mediaType, row.entryKey, null);
    widget.onChanged();
    await _reload();
  }

  Future<void> _reorderMembers() async {
    final List<SeriesMember> members = _members;
    if (members.length < 2) {
      HibikiToast.show(msg: t.shelf_sort_saved);
      return;
    }
    final List<ShelfReorderItem> items = <ShelfReorderItem>[
      for (final SeriesMember m in members)
        ShelfReorderItem(
          mediaType: m.row.mediaType,
          entryKey: m.row.entryKey,
          card: m.card,
        ),
    ];
    await Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        builder: (_) => ShelfReorderPage(
          title: t.shelf_edit_order,
          initialItems: items,
          cellExtent: 180,
          childAspectRatio: 160 / 260,
          feedbackBorderRadius: const BorderRadius.all(Radius.circular(12)),
          onPersist: _persistMemberOrder,
        ),
      ),
    );
    widget.onChanged();
    await _reload();
  }

  Future<void> _persistMemberOrder(List<ShelfReorderItem> ordered) async {
    final List<({String mediaType, String entryKey, int sortOrder})> orders =
        <({String mediaType, String entryKey, int sortOrder})>[
      for (int i = 0; i < ordered.length; i++)
        (
          mediaType: ordered[i].mediaType,
          entryKey: ordered[i].entryKey,
          sortOrder: i,
        ),
    ];
    await widget.database.batchUpsertShelfOrder(orders);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<SeriesMember> members = _members;
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: <Widget>[
          HibikiIconButton(
            tooltip: t.shelf_edit_order,
            icon: Icons.swap_vert,
            onTap: _reorderMembers,
          ),
          HibikiIconButton(
            tooltip: t.rename_series,
            icon: Icons.drive_file_rename_outline,
            onTap: _rename,
          ),
          HibikiIconButton(
            tooltip: t.delete_series,
            icon: Icons.delete_outline,
            onTap: _deleteSeries,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : members.isEmpty
                ? Center(
                    child: HibikiPlaceholderMessage(
                      icon: Icons.collections_bookmark_outlined,
                      message: t.series_empty,
                    ),
                  )
                : GridView.builder(
                    padding: EdgeInsets.all(tokens.spacing.card),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      childAspectRatio: 160 / 260,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: members.length,
                    itemBuilder: (BuildContext context, int i) {
                      final SeriesMember m = members[i];
                      return Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          m.card,
                          PositionedDirectional(
                            top: 2,
                            end: 2,
                            child: Material(
                              color: Colors.transparent,
                              child: IconButton(
                                tooltip: t.remove_from_series,
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => _removeMember(m.row),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}

Future<String?> showSeriesNameDialog({
  required BuildContext context,
  required String title,
  String initialName = '',
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _SeriesNameDialog(title: title, initialName: initialName),
  );
}

class _SeriesNameDialog extends StatefulWidget {
  const _SeriesNameDialog({required this.title, required this.initialName});

  final String title;
  final String initialName;

  @override
  State<_SeriesNameDialog> createState() => _SeriesNameDialogState();
}

class _SeriesNameDialogState extends State<_SeriesNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: widget.title,
        leadingIcon: Icons.collections_bookmark_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: HibikiTextField(
          controller: _controller,
          labelText: t.series_name_hint,
          autofocus: true,
          onSubmitted: (_) => _submit(),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: _submit,
              child: Text(t.dialog_ok),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesConfirmDialog extends StatelessWidget {
  const _SeriesConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onConfirm,
    this.destructive = false,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: destructive ? Icons.delete_outline : Icons.help_outline,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(message, style: tokens.type.listSubtitle),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: destructive,
              isDefaultAction: !destructive,
              onPressed: onConfirm,
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
  }
}
