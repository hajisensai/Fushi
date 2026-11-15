import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:material_ui/material_ui.dart';

/// Pushes [builder]'s page on the companion tab navigator that owns
/// [context], after [releaseCompanionTextFocus].
///
/// A covered route keeps its last focused child: when the page above pops,
/// `ModalRoute` makes the revealed route's focus scope the first focus again
/// and the scope focuses that child. A search field that still held focus
/// when a result (or a choice page) was opened therefore took focus back on
/// every return and opened the panel's on-screen keyboard.
Future<T?> pushCompanionPage<T>(BuildContext context, WidgetBuilder builder) {
  releaseCompanionTextFocus();
  return Navigator.of(
    context,
  ).push<T>(adaptivePageRoute<T>(context: context, builder: builder));
}

/// Drops the focus of a text field that holds the primary focus, clearing
/// it from its scope's focus history too ([UnfocusDisposition.scope]) so a
/// later route reveal cannot restore it. Any other focus (a row the
/// controller drives) is kept, so returning lands on the row that opened
/// the page.
void releaseCompanionTextFocus() {
  final FocusNode? focus = FocusManager.instance.primaryFocus;
  final BuildContext? focused = focus?.context;
  if (focus == null || focused == null) return;
  final bool isText =
      focused.widget is EditableText ||
      focused.findAncestorWidgetOfExactType<EditableText>() != null;
  if (isText) focus.unfocus();
}
