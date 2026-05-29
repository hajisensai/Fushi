import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for managing and viewing items in the Stash.
class OpenStashDialogPage extends BasePage {
  /// Create an instance of this page.
  const OpenStashDialogPage({
    required this.onSelect,
    required this.onSearch,
    super.key,
  });

  /// The callback to be called when a selection has been made.
  final Function(String)? onSelect;

  /// The callback to be called for a selection to perform a search on.
  final Function(String)? onSearch;

  @override
  BasePageState createState() => _OpenStashDialogPage();
}

class _OpenStashDialogPage extends BasePageState<OpenStashDialogPage> {
  final ScrollController _scrollController = ScrollController();

  final ValueNotifier<int?> _selectionNotifier = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _scrollController.dispose();
    _selectionNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OpenStashDialogFrame(
      content: buildContent(),
      actions: appModel.getStash().isEmpty ? null : actions,
    );
  }

  Widget buildEmptyMessage() {
    return Padding(
      padding:
          EdgeInsets.only(bottom: HibikiDesignTokens.of(context).spacing.gap),
      child: HibikiPlaceholderMessage(
        icon: Icons.inventory_2_outlined,
        message: t.stash_placeholder,
      ),
    );
  }

  Widget buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thumbVisibility: true,
        thickness: 3,
        controller: _scrollController,
        child: SingleChildScrollView(
          controller: _scrollController,
          child: appModel.getStash().isEmpty
              ? buildEmptyMessage()
              : Wrap(children: getTextWidgets().reversed.toList()),
        ),
      ),
    );
  }

  List<Widget> getTextWidgets() {
    List<Widget> widgets = [];

    appModel.getStash().forEachIndexed((index, segment) {
      Widget widget = GestureDetector(
        onTap: () {
          if (_selectionNotifier.value == index) {
            _selectionNotifier.value = null;
          } else {
            _selectionNotifier.value = index;
          }
        },
        child: ValueListenableBuilder<int?>(
          valueListenable: _selectionNotifier,
          builder: (context, value, child) {
            final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
            return Container(
              padding: EdgeInsets.symmetric(
                vertical: tokens.spacing.gap,
                horizontal: tokens.spacing.gap + 4,
              ),
              margin: EdgeInsets.only(
                top: tokens.spacing.gap,
                right: tokens.spacing.gap,
              ),
              decoration: BoxDecoration(
                color: index == _selectionNotifier.value
                    ? theme.colorScheme.secondaryContainer
                    : tokens.surfaces.card,
                borderRadius: tokens.radii.chipRadius,
              ),
              child: SizedBox(
                child: Text(
                  segment,
                  style: tokens.type.controlLabel.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            );
          },
        ),
      );

      widgets.add(widget);
    });

    return widgets;
  }

  List<Widget> get actions => [
        buildClearButton(),
        buildExportButton(),
        buildSearchButton(),
        buildSelectButton(),
      ];

  Widget buildClearButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeClear,
      child: Text(
        t.dialog_clear,
      ),
    );
  }

  Widget buildExportButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeExport,
      child: Text(t.dialog_share),
    );
  }

  Widget buildSearchButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSearch,
      child: Text(t.dialog_search),
    );
  }

  Widget buildSelectButton() {
    return adaptiveDialogAction(
      context: context,
      onPressed: executeSelect,
      child: Text(t.dialog_select),
    );
  }

  void executeExport() async {
    String exportText = appModel.getStash().reversed.toList().join('\n');
    await Share.share(exportText);
  }

  void executeSelect() {
    if (_selectionNotifier.value != null) {
      String selection = appModel.getStash()[_selectionNotifier.value!];
      widget.onSelect?.call(selection);
      Navigator.pop(context);
    }
  }

  void executeSearch() {
    if (_selectionNotifier.value != null) {
      String selection = appModel.getStash()[_selectionNotifier.value!];
      widget.onSearch?.call(selection);
    }
  }

  void executeClear() async {
    await showAppDialog(
      context: context,
      builder: (context) => OpenStashClearDialog(
        onConfirm: () {
          appModel.clearStash();
          Navigator.pop(context);
          setState(() {});
        },
      ),
    );
  }
}

@visibleForTesting
class OpenStashDialogFrame extends StatelessWidget {
  const OpenStashDialogFrame({
    required this.content,
    this.actions,
    super.key,
  });

  final Widget content;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.82,
      child: HibikiModalSheetFrame(
        title: t.creator_enhancement_open_stash,
        leadingIcon: Icons.inventory_2_outlined,
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
        body: content,
        footer: actions == null
            ? null
            : Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: actions!,
              ),
      ),
    );
  }
}

@visibleForTesting
class OpenStashClearDialog extends StatelessWidget {
  const OpenStashClearDialog({
    required this.onConfirm,
    super.key,
  });

  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: HibikiModalSheetFrame(
        title: t.stash_clear_title,
        leadingIcon: Icons.delete_sweep_outlined,
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
        body: Text(
          t.stash_clear_description,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              child: Text(t.dialog_close),
              onPressed: () => Navigator.pop(context),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              child: Text(t.dialog_clear),
              onPressed: onConfirm,
            ),
          ],
        ),
      ),
    );
  }
}
