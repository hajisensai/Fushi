import 'dart:convert';

/// Word steps of the controller lookup mode on the reader's JS carets
/// (`window.fushiCaret` on the book, `window.fushiLyricsCaret` on the audiobook
/// lyrics overlay).
///
/// The carets only know characters; the tokenizer lives in Dart
/// (`controllerLookupWordStep` → `buildSubtitleSweepTokens`, the same word
/// split every controller lookup page uses). A word step is therefore two
/// round trips:
///
/// 1. [contextInvocation] reads the text around the caret: the caret's block
///    (the selection script's `findParagraph` on the book, the `.cue` row on
///    the lyrics overlay) walked with the selection script's `createWalker`,
///    so furigana (`<rt>`) and whitespace-only nodes are skipped exactly like
///    the lookup scan and the caret's own stops. Only a window of
///    [contextRadius] UTF-16 units on each side is returned: subtitle books put
///    a whole transcript into one paragraph, and a step only ever needs the
///    word under the caret and its neighbours.
/// 2. [stepInvocation] moves the caret with its own `move('forward' |
///    'backward')` until it reaches (or passes) the target `delta` UTF-16 units
///    away. Composing the caret's character move keeps every edge rule of the
///    three view modes (paginated / continuous / vn) and the lyrics rows: a
///    step that runs off the page returns the same `pageForward` /
///    `pageBackward` status as a character move and the host turns the page.
class ReaderControllerWordStepScripts {
  ReaderControllerWordStepScripts._();

  /// UTF-16 units of context returned on each side of the caret.
  static const int contextRadius = 200;

  /// The JS global of the caret: the book caret, or the lyrics caret.
  static String _caret({required bool lyrics}) =>
      lyrics ? 'window.fushiLyricsCaret' : 'window.fushiCaret';

  /// Returns `{text, index}` (JSON) — the text around the caret and the
  /// caret's UTF-16 index in it — or `null` when the caret is not on a text
  /// character (inactive, on an element stop, detached).
  static String contextInvocation({required bool lyrics}) =>
      '''
(function() {
  var c = ${_caret(lyrics: lyrics)};
  var s = window.fushiSelection;
  if (!c || !c.active || !c.node || !s || typeof s.createWalker !== 'function') return null;
  if (!document.contains(c.node)) return null;
  var root = ${lyrics ? "(c.node.parentElement && c.node.parentElement.closest('.cue'))" : '(typeof s.findParagraph === "function" ? s.findParagraph(c.node) : null)'};
  if (!root) return null;
  var walker = s.createWalker(root);
  var text = '';
  var index = -1;
  var n;
  while ((n = walker.nextNode())) {
    if (n === c.node) index = text.length + c.offset;
    text += n.textContent;
    if (index >= 0 && text.length > index + $contextRadius) break;
  }
  if (index < 0) return null;
  var start = Math.max(0, index - $contextRadius);
  return JSON.stringify({
    text: text.substring(start, Math.min(text.length, index + $contextRadius)),
    index: index - start
  });
})()''';

  /// Moves the caret toward the position [delta] UTF-16 units away (positive =
  /// forward) in the walker's text order. Returns the caret's `{status, rect}`
  /// of the last character move (`moved` once the target is reached or
  /// passed; `pageForward` / `pageBackward` / `blocked` from the move that
  /// could not continue).
  static String stepInvocation({required bool lyrics, required int delta}) {
    final bool forward = delta > 0;
    return '''
(function() {
  var c = ${_caret(lyrics: lyrics)};
  var s = window.fushiSelection;
  if (!c || !c.active || !c.node || !s) return JSON.stringify({status: 'blocked'});
  var walker = s.createWalker(document.body);
  var node = c.node;
  var offset = c.offset + ($delta);
  walker.currentNode = node;
  ${forward ? '''
  while (node && offset >= node.textContent.length) {
    offset -= node.textContent.length;
    node = walker.nextNode();
  }''' : '''
  while (node && offset < 0) {
    node = walker.previousNode();
    if (node) offset += node.textContent.length;
  }'''}
  if (!node) return JSON.stringify(c.move('${forward ? 'forward' : 'backward'}'));
  var cmp = function(aNode, aOffset) {
    if (aNode === node) return aOffset - offset;
    return (aNode.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1;
  };
  var result = {status: 'blocked'};
  for (var i = 0; i < 64; i++) {
    result = c.move('${forward ? 'forward' : 'backward'}');
    if (!result || result.status !== 'moved' || !c.node) break;
    var d = cmp(c.node, c.offset);
    if (${forward ? 'd >= 0' : 'd <= 0'}) break;
  }
  return JSON.stringify(result || {status: 'blocked'});
})()''';
  }

  /// Parses a [contextInvocation] result; null when the caret has no text.
  static ({String text, int index})? parseContext(Object? raw) {
    Object? decoded = raw;
    if (decoded is String) {
      final String trimmed = decoded.trim();
      if (trimmed.isEmpty || trimmed == 'null') return null;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    final Object? text = decoded['text'];
    final Object? index = decoded['index'];
    if (text is! String || index is! num) return null;
    final int at = index.toInt();
    if (at < 0 || at >= text.length) return null;
    return (text: text, index: at);
  }
}
