import 'package:flutter/widgets.dart';

/// Removes an [OverlayEntry] still owned by a State before disposing it.
///
/// [OverlayEntry.mounted] only reports whether the entry's widget subtree is
/// mounted. An opaque entry or teardown of the whole Overlay can make it false
/// while the entry is still registered with its [OverlayState]. An owner that
/// retains the entry until teardown must therefore remove it unconditionally.
void removeAndDisposeOwnedOverlayEntry(OverlayEntry entry) {
  entry.remove();
  entry.dispose();
}
