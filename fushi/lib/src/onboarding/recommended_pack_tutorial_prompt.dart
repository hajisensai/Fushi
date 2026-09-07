import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_state.dart';
import 'package:fushi/utils.dart' show showAppDialog;

/// Returns whether an eligible follow-up was offered, so startup can avoid
/// replaying the initial wizard after restoring a pack's database.
Future<bool> showRecommendedPackTutorialPrompt({
  required BuildContext context,
  required RecommendedPackTutorialState state,
  required Future<void> Function() onStart,
}) async {
  if (!await state.shouldPrompt || !context.mounted) return false;
  final bool? start = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(t.onboarding_pack_tutorial_ready),
      content: Text(t.onboarding_pack_tutorial_desc),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('pack_tutorial_skip'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t.onboarding_pack_tutorial_skip),
        ),
        FilledButton(
          key: const ValueKey<String>('pack_tutorial_start'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t.onboarding_pack_tutorial_start),
        ),
      ],
    ),
  );
  // Back/barrier dismissal is not an explicit Skip decision.
  if (start == null) return true;
  await state.dismissPrompt();
  if (start && context.mounted) await onStart();
  return true;
}
