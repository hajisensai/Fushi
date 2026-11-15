import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Trailing paste button of a tracking token field (Bangumi, AniList,
/// MangaBaka, tracking plugin sign-in): replaces the whole field with the
/// clipboard text, trimmed. Tokens are long and copied from a site, so
/// "insert at the cursor" (the generic input assist) is the wrong action.
///
/// An empty clipboard leaves the field as it is and says so in a snackbar.
class TrackingTokenPasteButton extends StatelessWidget {
  const TrackingTokenPasteButton({
    required this.controller,
    this.enabled = true,
    this.onPasted,
    super.key,
  });

  final TextEditingController controller;
  final bool enabled;

  /// Called with the new text after a paste (programmatic edits do not fire
  /// a field's `onChanged`).
  final ValueChanged<String>? onPasted;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: t.media_tracking_token_paste,
    excludeSemantics: true,
    child: FushiIconButtonControl(
      tooltip: t.media_tracking_token_paste,
      icon: const FushiIcon(FushiIcons.paste),
      onPressed: enabled ? () => _paste(context) : null,
    ),
  );

  Future<void> _paste(BuildContext context) async {
    final String text = await readTrackingTokenFromClipboard();
    if (!context.mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          FushiSnackBar(content: Text(t.media_tracking_token_paste_empty)),
        );
      return;
    }
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onPasted?.call(text);
  }
}

/// The clipboard's plain text, trimmed; empty when there is none or the
/// platform refuses to read it.
Future<String> readTrackingTokenFromClipboard() async {
  try {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text?.trim() ?? '';
  } on PlatformException {
    return '';
  } on MissingPluginException {
    return '';
  }
}
