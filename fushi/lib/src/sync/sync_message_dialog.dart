import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

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
    ..showSnackBar(FushiSnackBar(content: Text(message)));
}

@visibleForTesting
class SyncMessageDialog extends StatelessWidget {
  const SyncMessageDialog({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.82,
      insetPadding: EdgeInsets.all(tokens.spacing.gap),
      scrollable: false,
      child: FushiModalSheetFrame(
        leadingIcon: FushiIcons.info,
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
