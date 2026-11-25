import 'package:fushi/src/second_screen/companion/companion_context.dart';

/// Sends a lookup made on the main screen to the companion's Lookup tab.
/// False when the companion is not in use (or did not take it): the page
/// shows its in-page popup exactly as on a single screen. The inactive path
/// is one synchronous check. [charIndex] is the tapped UTF-16 index in
/// [text] (-1 = [text] is the query); [sentence] the mining sentence.
///
/// Goes through [companionContexts] (the bridge binds its sink there), so
/// pages do not import the bridge / AppModel layer.
Future<bool> routeCompanionLookup({
  required String text,
  int charIndex = -1,
  String? sentence,
}) => companionContexts.routeLookup(
  text: text,
  charIndex: charIndex,
  sentence: sentence,
);
