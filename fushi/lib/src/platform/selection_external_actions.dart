import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:share_plus/share_plus.dart';

typedef ShareSelectedText = Future<void> Function(String text);

/// Narrow platform seam for actions that hand a selected text payload to
/// another Android app.
///
/// Sharing intentionally reuses [Share.share]. Web search is not a URL launch:
/// Android receives the original text through `ACTION_WEB_SEARCH` /
/// `SearchManager.QUERY` and lets the system-selected handler decide where it
/// goes.
class SelectionExternalActions {
  SelectionExternalActions({
    MethodChannel? channel,
    ShareSelectedText? shareSelectedText,
  })  : _channel = channel ?? FushiChannels.selectionActions,
        _shareSelectedText = shareSelectedText ??
            ((String text) async {
              await Share.share(text);
            });

  static final SelectionExternalActions instance = SelectionExternalActions();

  final MethodChannel _channel;
  final ShareSelectedText _shareSelectedText;

  /// Opens the system share sheet with [text] unchanged.
  Future<bool> shareText(String text) async {
    if (text.isEmpty) return false;
    try {
      await _shareSelectedText(text);
      return true;
    } on Object {
      return false;
    }
  }

  /// Asks Android's default web-search handler to search [text] unchanged.
  ///
  /// `false` includes both "no handler installed" and a missing/broken native
  /// channel. Callers must surface that outcome to the user.
  Future<bool> searchWeb(String text) async {
    if (text.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'webSearch',
            <String, String>{'query': text},
          ) ??
          false;
    } on Object {
      return false;
    }
  }
}
