import 'package:flutter/material.dart';
import 'package:multi_value_listenable_builder/multi_value_listenable_builder.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_progress_dialog_content.dart';
import 'package:hibiki/utils.dart';

/// The content of the dialog used for showing dictionary import progress when
/// importing a dictionary from the dictionary menu. See the
/// [DictionaryDialogPage].
class DictionaryDialogImportPage extends BasePage {
  /// Create an instance of this page.
  const DictionaryDialogImportPage({
    required this.progressNotifier,
    required this.countNotifier,
    required this.totalNotifier,
    super.key,
  });

  /// A notifier for reporting text updates for the current progress text in
  /// the dialog.
  final ValueNotifier<String> progressNotifier;

  /// A notifier for reporting text updates for the current progress text in
  /// the dialog.
  final ValueNotifier<int?> countNotifier;

  /// The number of dictionaries being imported.
  final ValueNotifier<int?> totalNotifier;

  @override
  BasePageState createState() => _DictionaryDialogImportPageState();
}

class _DictionaryDialogImportPageState
    extends BasePageState<DictionaryDialogImportPage> {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: adaptiveAlertDialog(
        context: context,
        contentPadding: Spacing.of(context).insets.all.small,
        content: buildProgressMessage(),
      ),
    );
  }

  Widget buildProgressMessage() {
    return MultiValueListenableBuilder(
      valueListenables: [
        widget.countNotifier,
        widget.totalNotifier,
        widget.progressNotifier,
      ],
      builder: (context, values, _) {
        int? currentCount = values.elementAt(0);
        int? totalCount = values.elementAt(1);
        String progress = values.elementAt(2);

        final String header =
            currentCount != null && totalCount != null && totalCount != 1
                ? '${t.import_in_progress}\n$currentCount / $totalCount'
                : t.import_in_progress;

        return DictionaryProgressDialogContent(
          header: header,
          message: progress,
          progressColor: theme.colorScheme.primary,
          headerStyle: TextStyle(
            fontSize: textTheme.bodySmall?.fontSize,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}
