enum WindowsImeSpaceDispatchAction {
  ignore,
  dismissPopup,
  togglePlayPause,
}

/// Resolves the Dart-side ownership gate for the Windows native IME Space
/// notification. The native runner can identify the physical Space make-code,
/// but page/route focus and IME composing ownership live in Flutter.
WindowsImeSpaceDispatchAction resolveWindowsImeSpaceDispatch({
  required bool mounted,
  required bool hasController,
  required bool isCurrentRoute,
  required bool hasEditableFocus,
  required bool hasVisiblePopup,
  required bool immersiveAllowsShortcuts,
}) {
  if (!mounted || !hasController || !isCurrentRoute || hasEditableFocus) {
    return WindowsImeSpaceDispatchAction.ignore;
  }
  if (hasVisiblePopup) {
    return WindowsImeSpaceDispatchAction.dismissPopup;
  }
  if (!immersiveAllowsShortcuts) {
    return WindowsImeSpaceDispatchAction.ignore;
  }
  return WindowsImeSpaceDispatchAction.togglePlayPause;
}
