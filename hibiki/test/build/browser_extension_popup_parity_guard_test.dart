import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1267 guard: keep the browser-extension dictionary popup byte-for-byte in
/// step with the in-app popup renderer.
///
/// Root cause of "扩展弹窗完全不一样、丑死了、按钮位置也不一样": the extension loads its
/// OWN vendored copy of popup.js and a hand-ported scoped stylesheet (content.css).
/// Neither was covered by any app↔extension parity guard, so as the in-app
/// popup.js / popup.css grew ~59 new selectors (favorite / clear-draft /
/// sentence-context / inline-action / kanji-card / pitch-transcription /
/// scrollbar / overlay-close SVG), the vendored copies silently fell 57 KB / 22 KB
/// behind → the extension rendered an old DOM with unstyled new buttons.
///
/// This locks in:
///  1. popup.js / popup.html / popup.css are byte-identical across the in-app
///     renderer and BOTH extension mirrors (assets/ + tools/).
///  2. vendor/content.css is the generated (scoped) mirror of popup.css: every
///     class-rooted selector in popup.css must appear in content.css, and no
///     document-level rule may leak to the host page.
///  3. The two extension content.css mirrors stay byte-identical.
///
/// flutter test cwd is the hibiki package root.
void main() {
  const String appPopup = 'assets/popup';
  const String extAssets = 'assets/browser_extension';
  const String extTools = '../tools/browser-extension';

  String read(String p) => File(p).readAsStringSync();
  List<int> bytes(String p) => File(p).readAsBytesSync();

  group('extension popup byte-identical to the in-app renderer (TODO-1267)',
      () {
    for (final String rel in const <String>[
      'popup.js',
      'popup.html',
      'popup.css',
    ]) {
      test('$rel matches app renderer in both extension mirrors', () {
        final List<int> app = bytes('$appPopup/$rel');
        expect(bytes('$extTools/vendor/$rel'), app,
            reason:
                'tools/browser-extension/vendor/$rel drifted from assets/popup/$rel — '
                're-run: cp hibiki/assets/popup/$rel into both extension vendor dirs '
                '(and content.css via generate-content-css.mjs).');
        expect(bytes('$extAssets/vendor/$rel'), app,
            reason:
                'assets/browser_extension/vendor/$rel drifted from assets/popup/$rel.');
      });
    }
  });

  group('vendor/content.css stays complete vs popup.css (TODO-1267)', () {
    // Strip /* ... */ comments so we only look at real rules.
    String stripComments(String css) =>
        css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

    /// Every top-level, class-rooted (`.foo`) selector part in popup.css — these
    /// are kept verbatim by generate-content-css.mjs, so they must all be present.
    Set<String> classSelectors(String css) {
      final String s = stripComments(css);
      final Set<String> out = <String>{};
      final RegExp rule = RegExp(r'([^{}]+)\{');
      for (final Match m in rule.allMatches(s)) {
        for (final String part in m.group(1)!.split(',')) {
          final String sel = part.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (sel.startsWith('.')) out.add(sel);
        }
      }
      return out;
    }

    final String popupCss = read('$appPopup/popup.css');
    final Set<String> wanted = classSelectors(popupCss);

    for (final String root in const <String>[extAssets, extTools]) {
      test('[$root] content.css contains every popup.css class selector', () {
        final String content = stripComments(read('$root/vendor/content.css'));
        final List<String> missing =
            wanted.where((String sel) => !content.contains(sel)).toList();
        expect(missing, isEmpty,
            reason:
                '$root/vendor/content.css is missing ${missing.length} popup.css '
                'class selectors (stale hand-port). Re-run '
                'node tools/browser-extension/scripts/generate-content-css.mjs.\n'
                'First missing: ${missing.take(8).join(', ')}');
      });

      test('[$root] content.css re-roots document-level rules (no host leak)',
          () {
        final String content = stripComments(read('$root/vendor/content.css'));
        // A rule whose selector starts a line with a bare universal / element /
        // pseudo would restyle the whole host page (TODO-1090). After scoping,
        // none of these may appear at the start of a rule.
        final RegExp leak = RegExp(
          r'(^|\n)\s*(\*|html|body|hr|a|::selection|::-webkit-scrollbar[a-z-]*|html\.global-lookup|html\.mobile-external)\s*[,{]',
        );
        final Match? m = leak.firstMatch(content);
        expect(m, isNull,
            reason:
                '$root/vendor/content.css has an un-scoped document-level selector '
                'that would leak to the host page: ${m?.group(2)}');
      });

      test('[$root] content.css keeps the extension-only overlay', () {
        final String content = read('$root/vendor/content.css');
        expect(content.contains('#hibiki-subtitle-panel'), isTrue,
            reason: '$root/vendor/content.css lost the Netflix subtitle panel');
        expect(content.contains('--hibiki-popup-max-width'), isTrue,
            reason:
                '$root/vendor/content.css lost the floating-popup sizing overlay');
        // Scoped forms of the document-level popup.css rules must be present.
        // BUG-752: the scope must be the specificity-neutral `:where(...)` form.
        for (final String scoped in const <String>[
          ':where(#entries-container) ::selection',
          ':where(#entries-container) ::-webkit-scrollbar',
          ':where(#entries-container)[data-theme="dark"]',
        ]) {
          expect(content.contains(scoped), isTrue,
              reason: '$root/vendor/content.css missing scoped rule: $scoped');
        }
      });

      test('[$root] content.css re-roots stay specificity-neutral (BUG-752)',
          () {
        // A bare `#entries-container` re-root prefix lifts a document-level
        // popup.css rule from (0,0,x) to (1,0,x) so it out-ranks every class
        // rule and the extension cascade inverts vs the in-app popup. The `*`
        // reset re-rooted as `#entries-container *` killed
        // `.ruby-unit { padding-top }` and glossary furigana printed on top of
        // its base text. The generator must emit `:where(#entries-container...)`
        // scopes instead; only the extension-only overlay may address the
        // container element itself by bare ID (its rules target ONLY the
        // container, never descendants).
        final String content = stripComments(read('$root/vendor/content.css'));
        // The zero-specificity universal reset must exist...
        expect(
            content.contains(':where(#entries-container, #entries-container *)'),
            isTrue,
            reason: '$root/vendor/content.css lost the :where() universal '
                'reset (BUG-752)');
        // ...and no selector may re-introduce a bare-ID descendant re-root
        // (`#entries-container *`, `#entries-container hr`, `#entries-container
        // ::selection`, `#entries-container[data-theme]`...). `#entries-container
        // {` / `#entries-container,` (container-only rules, e.g. the overlay
        // sizing block) stay allowed.
        final RegExp bareIdReroot =
            RegExp(r'(^|\n)\s*#entries-container(\s+[^{\s]|\[)[^{}]*\{');
        final Match? m = bareIdReroot.firstMatch(content);
        expect(m, isNull,
            reason: '$root/vendor/content.css re-introduced a bare-ID re-root '
                'selector (cascade-inverting, BUG-752): '
                '${m?.group(0)?.trim()}');
      });
    }

    test('the two extension content.css mirrors are byte-identical', () {
      expect(bytes('$extAssets/vendor/content.css'),
          bytes('$extTools/vendor/content.css'),
          reason:
              'assets/ and tools/ content.css diverged — regenerate both with '
              'generate-content-css.mjs.');
    });
  });
}
