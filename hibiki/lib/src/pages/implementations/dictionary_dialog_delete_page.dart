import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_progress_dialog_content.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for showing dictionary import progress when
/// deleting a dictionary from the dictionary menu. See the
/// [DictionaryDialogPage].
class DictionaryDialogDeletePage extends BasePage {
  /// Create an instance of this page.
  const DictionaryDialogDeletePage({
    this.name,
    super.key,
  });

  /// Name of current dictionary being deleted.
  final String? name;

  @override
  BasePageState createState() => _DictionaryDialogDeletePageState();
}

class _DictionaryDialogDeletePageState
    extends BasePageState<DictionaryDialogDeletePage> {
  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return PopScope(
      canPop: false,
      child: HibikiDialogFrame(
        maxWidth: 420,
        scrollable: false,
        child: HibikiModalSheetFrame(
          bodyPadding: EdgeInsets.all(tokens.spacing.card),
          body: buildProgressMessage(),
        ),
      ),
    );
  }

  Widget buildProgressMessage() {
    return DictionaryProgressDialogContent(
      header: widget.name != null
          ? '${t.delete_in_progress}\n${widget.name}'
          : t.delete_in_progress,
      message: t.dictionaries_deleting_data,
      progressColor: theme.colorScheme.primary,
      headerStyle: TextStyle(
        fontSize: textTheme.bodySmall?.fontSize,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
