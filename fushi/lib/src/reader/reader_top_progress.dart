import 'package:flutter/widgets.dart';

/// TODO-728: pure mapping helpers for the top reading-progress text position.
///
/// The stored value is one of `'left' | 'center' | 'right'` (already normalized
/// by [ReaderSettings.normalizeTopProgressPosition]); these turn it into the
/// [Alignment] used to place the text inside the progress strip and the
/// [TextAlign] used inside the text box. Kept as standalone top-level functions
/// (not part-of the reader page) so they can be unit-tested directly and reused
/// by both the reader chrome and its tests.
Alignment readerTopProgressAlignment(String position) {
  switch (position) {
    case 'left':
      return Alignment.centerLeft;
    case 'right':
      return Alignment.centerRight;
    case 'center':
    default:
      return Alignment.center;
  }
}

TextAlign readerTopProgressTextAlign(String position) {
  switch (position) {
    case 'left':
      return TextAlign.left;
    case 'right':
      return TextAlign.right;
    case 'center':
    default:
      return TextAlign.center;
  }
}
