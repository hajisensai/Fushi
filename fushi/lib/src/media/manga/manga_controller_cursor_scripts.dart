import 'dart:convert';

/// JavaScript of the manga controller lookup cursor (S6 of the dual-screen
/// companion), evaluated in the manga window document
/// (`mangaWindowDocument`).
///
/// The cursor is a logical position in the page's OCR blocks (page, block
/// index in reading order, UTF-16 offset into `block.lines.join()`), kept on
/// the Dart side. The document already renders each block as one
/// `.ocr-box` paragraph (in payload order, inside `.manga-page[data-page]`)
/// whose characters are `.ocr-char` spans tagged with `data-utf16-start`;
/// region-less blocks hold the plain line text. Each call is a self-contained
/// expression (no global state is injected): it clears the previous cursor
/// mark, outlines the target character (or the whole box for region-less
/// blocks) and, for a lookup, selects from that character through the
/// document's own `fushiSelection.selectFromPosition` — exactly the tap path
/// (`_selectOcrCharDetail`), so `onTextSelected` carries the real rect,
/// sentence group and page and the page's normal lookup / highlight /
/// companion routing runs unchanged.
///
/// Every call returns a status string: `moved`, `lookup`, `cleared` or
/// `miss` (page / block / character not in the document).
class MangaControllerCursorScripts {
  MangaControllerCursorScripts._();

  /// Marks the character at [utf16] of block [block] on page [page] with a
  /// [color] (CSS colour) outline. With [lookup] it also starts a lookup
  /// there.
  static String place({
    required int page,
    required int block,
    required int utf16,
    required String color,
    bool lookup = false,
  }) => '$_function($page,$block,$utf16,${jsonEncode(color)},$lookup)';

  /// Removes the cursor mark.
  static String clear() => '$_function(-1,0,0,"",false)';

  static const String _function = r'''
(function(page, block, at, color, lookup){
  var marked = document.querySelectorAll('[data-fushi-ctl-cursor]');
  for (var i = 0; i < marked.length; i++) {
    marked[i].style.outline = '';
    marked[i].style.outlineOffset = '';
    marked[i].removeAttribute('data-fushi-ctl-cursor');
  }
  if (page < 0) return 'cleared';
  var pageEl = document.querySelector('.manga-page[data-page="' + page + '"]');
  if (!pageEl) return 'miss';
  var box = pageEl.querySelectorAll('.ocr-box')[block];
  if (!box) return 'miss';
  var mark = null, node = null, offset = 0, rect = null;
  var chars = box.querySelectorAll('.ocr-char');
  if (chars.length) {
    for (var j = 0; j < chars.length; j++) {
      var start = Number(chars[j].getAttribute('data-utf16-start') || 0);
      if (start > at && mark) break;
      mark = chars[j];
      offset = Math.max(0, at - start);
    }
    node = mark.firstChild;
    if (!node || node.nodeType !== Node.TEXT_NODE) return 'miss';
    offset = Math.min(offset, Math.max(0, node.textContent.length - 1));
    rect = mark.getBoundingClientRect();
  } else {
    var walker = document.createTreeWalker(box, NodeFilter.SHOW_TEXT, null);
    var acc = 0, n;
    while ((n = walker.nextNode())) {
      var len = n.textContent.length;
      if (!len) continue;
      node = n;
      if (at < acc + len) { offset = at - acc; break; }
      offset = len - 1;
      acc += len;
    }
    if (!node) return 'miss';
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, Math.min(node.textContent.length, offset + 1));
    rect = range.getBoundingClientRect();
    mark = box;
  }
  mark.setAttribute('data-fushi-ctl-cursor', '1');
  mark.style.outline = '2px solid ' + color;
  mark.style.outlineOffset = '1px';
  if (!lookup) return 'moved';
  var selection = window.fushiSelection;
  if (!selection) return 'miss';
  selection.clearSelection();
  selection.selectFromPosition(node, offset, 40,
    rect.left + rect.width / 2, rect.top + rect.height / 2, false);
  return 'lookup';
})''';
}
