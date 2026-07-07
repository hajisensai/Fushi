import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
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
    // 确认 + DB 移出 + 空系列清理统一走共享 helper（TODO-947 P3：与带框成员重排页复用
    // 同一 UX/原语）。emptied=true 表示移出的是最后一个成员，系列已删，退回上层。
    if (!await showRemoveFromSeriesConfirm(context)) return;
    final bool emptied = await removeEntryFromSeries(
      database: widget.database,
      seriesId: widget.seriesId,
      mediaType: row.mediaType,
      entryKey: row.entryKey,
    );
    if (!mounted) return;
    widget.onChanged();
    HibikiToast.show(msg: t.removed_from_series);
    if (emptied) {
      Navigator.of(context).maybePop();
      return;
    }
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

/// TODO-947 P3 共享：弹「移出系列」确认框（平白话文案，复用既有 [_SeriesConfirmDialog]）。
/// 返回 true = 用户确认移出。抽自 [SeriesDetailPage._removeMember]，供成员视图（带框重排
/// 页）与详情页复用同一确认 UX。
Future<bool> showRemoveFromSeriesConfirm(BuildContext context) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => _SeriesConfirmDialog(
      title: t.remove_from_series,
      message: t.remove_from_series_confirm,
      confirmLabel: t.remove_from_series,
      onConfirm: () => Navigator.pop(ctx, true),
    ),
  );
  return confirmed == true;
}

/// TODO-947 P3 共享：把某条目移出系列（setSeriesForEntry null）；若移出后系列已空则删除
/// 该 Series 行（避免留 0 成员孤儿卡）。返回系列是否已清空（true → 调用方应 pop）。抽自
/// [SeriesDetailPage._removeMember] 的 DB 部分，纯 DB 无 UI，供多入口复用同一清理原语。
Future<bool> removeEntryFromSeries({
  required HibikiDatabase database,
  required int seriesId,
  required String mediaType,
  required String entryKey,
}) async {
  await database.setSeriesForEntry(mediaType, entryKey, null);
  final List<ShelfEntryRow> remaining =
      await database.getShelfEntriesBySeries(seriesId);
  if (remaining.isEmpty) {
    await database.deleteSeries(seriesId);
    return true;
  }
  return false;
}

Future<String?> showSeriesNameDialog({
  required BuildContext context,
  required String title,
  String initialName = '',
  List<Widget> previewCovers = const <Widget>[],
}) {
  return showAppDialog<String>(
    context: context,
    builder: (_) => _SeriesNameDialog(
      title: title,
      initialName: initialName,
      previewCovers: previewCovers,
    ),
  );
}

class _SeriesNameDialog extends StatefulWidget {
  const _SeriesNameDialog({
    required this.title,
    required this.initialName,
    this.previewCovers = const <Widget>[],
  });

  final String title;
  final String initialName;

  /// TODO-947：多选「组合成系列」命名弹窗里，把选中的前 N 本书封面铺成手机文件夹式
  /// 网格缩略预览，让用户在命名/确认时就直观看到「我把哪几本合并进去了」。空则不渲染。
  final List<Widget> previewCovers;

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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.previewCovers.isNotEmpty) ...<Widget>[
              Center(
                child: SizedBox(
                  width: 92,
                  height: 120,
                  child: HibikiCard(
                    padding: EdgeInsets.zero,
                    margin: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: tokens.radii.cardRadius,
                      child: SeriesFolderCover(covers: widget.previewCovers),
                    ),
                  ),
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            HibikiTextField(
              controller: _controller,
              labelText: t.series_name_hint,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
          ],
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
