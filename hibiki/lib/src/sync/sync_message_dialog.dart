import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

void showSyncMessage(BuildContext context, String message) {
  if (isCupertinoPlatform(context)) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return SyncMessageDialog(message: message);
      },
    );
    return;
  }

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

@visibleForTesting
class SyncMessageDialog extends StatelessWidget {
  const SyncMessageDialog({
    required this.message,
    super.key,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.82,
      insetPadding: EdgeInsets.all(tokens.spacing.gap),
      scrollable: false,
      child: HibikiModalSheetFrame(
        leadingIcon: Icons.info_outline,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.card,
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
        footer: Align(
          alignment: Alignment.centerRight,
          child: adaptiveDialogAction(
            context: context,
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context),
            child: Text(t.dialog_done),
          ),
        ),
      ),
    );
  }
}
