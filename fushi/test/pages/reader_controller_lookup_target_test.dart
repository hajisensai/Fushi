import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show
        ReaderControllerLookupRequest,
        ReaderControllerLookupRequests,
        readerControllerCappedQuery,
        readerControllerCompanionLookup;
import 'package:fushi/src/reader/reader_caret_scripts.dart';
import 'package:fushi/src/reader/reader_controller_word_step_scripts.dart';
import 'package:fushi/src/reader/reader_lyrics_caret_scripts.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// Reader adapter of the unified controller lookup mode
/// (docs/specs/2026-11-22-gamepad-lookup-unification-design.md): the query cap
/// of the selection's right end, the companion routing of a capped query, the
/// word-step script contract, and the wiring that keeps the cursor in the text
/// after a lookup (behaviour of the JS caret / popup needs a WebView, so that
/// part is a source guard).
void main() {
  group('readerControllerCappedQuery', () {
    const List<FushiRubySpan> spans = <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 1, reading: 'た'),
      FushiRubySpan(start: 2, end: 3, reading: 'もの'),
    ];

    test('no cap (or a cap past the text) keeps the scanned text', () {
      expect(
        readerControllerCappedQuery('食べ物', spans, maxGraphemes: null).text,
        '食べ物',
      );
      final ({String text, List<FushiRubySpan> rubySpans}) wide =
          readerControllerCappedQuery('食べ物', spans, maxGraphemes: 3);
      expect(wide.text, '食べ物');
      expect(wide.rubySpans, spans);
    });

    test('a cap cuts to that many graphemes and drops ruby past the cut', () {
      final ({String text, List<FushiRubySpan> rubySpans}) cut =
          readerControllerCappedQuery('食べ物', spans, maxGraphemes: 2);
      expect(cut.text, '食べ');
      expect(cut.rubySpans, <FushiRubySpan>[spans.first]);
    });

    test(
      'the cut never splits a grapheme (surrogate pairs, combining marks)',
      () {
        expect(
          readerControllerCappedQuery(
            '𩸽の塩焼き',
            const <FushiRubySpan>[],
            maxGraphemes: 1,
          ).text,
          '𩸽',
        );
        expect(
          readerControllerCappedQuery(
            'がき',
            const <FushiRubySpan>[],
            maxGraphemes: 1,
          ).text,
          'が',
        );
      },
    );
  });

  group('readerControllerCompanionLookup', () {
    test('uncapped: the whole sentence with the word index', () {
      final ({String text, int charIndex, String sentence}) args =
          readerControllerCompanionLookup(
            text: '先生と呼んだ',
            sentence: '私は先生と呼んだ。',
            sentenceOffset: 2,
          );
      expect(args.text, '私は先生と呼んだ。');
      expect(args.charIndex, 2);
      expect(args.sentence, '私は先生と呼んだ。');
    });

    test('capped: the scanned source ends at the cap, the mining sentence '
        'stays whole', () {
      final ({String text, int charIndex, String sentence}) args =
          readerControllerCompanionLookup(
            text: '先生と呼んだ',
            sentence: '私は先生と呼んだ。',
            sentenceOffset: 2,
            query: '先',
          );
      expect(args.text, '私は先');
      expect(args.charIndex, 2);
      expect(args.sentence, '私は先生と呼んだ。');
    });

    test('no usable sentence: the query itself', () {
      final ({String text, int charIndex, String sentence}) args =
          readerControllerCompanionLookup(
            text: '先生と',
            sentence: '  ',
            sentenceOffset: 0,
            query: '先生',
          );
      expect(args.text, '先生');
      expect(args.charIndex, -1);
      expect(args.sentence, '先生');
    });
  });

  group('controller lookup claims go by token, not by arrival order', () {
    test(
      'a tap / hover payload in between is not taken for the controller '
      "lookup; the controller's own payload claims it with its cap",
      () async {
        final ReaderControllerLookupRequests requests =
            ReaderControllerLookupRequests();
        final ({int token, ReaderControllerLookupRequest request}) a = requests
            .start(3);
        // A tap lookup lands between the JS call and the controller's payload.
        expect(requests.take(null), isNull);
        expect(requests.pendingCount, 1);
        // A stale / foreign token is no claim either.
        expect(requests.take(a.token + 1), isNull);
        expect(requests.take('x'), isNull);
        final ReaderControllerLookupRequest? claimed = requests.take(a.token);
        expect(claimed, same(a.request));
        expect(claimed!.maxGraphemes, 3);
        claimed.complete(2);
        expect(await a.request.result, 2);
        // Claimed once only.
        expect(requests.take(a.token), isNull);
      },
    );

    test('each lookup gets its own token; an older payload arriving after a '
        'newer lookup started still finds its own request', () async {
      final ReaderControllerLookupRequests requests =
          ReaderControllerLookupRequests();
      final ({int token, ReaderControllerLookupRequest request}) a = requests
          .start(null);
      final ({int token, ReaderControllerLookupRequest request}) b = requests
          .start(5);
      expect(b.token, isNot(a.token));
      // JSON numbers may decode as num.
      expect(requests.take(b.token.toDouble()), same(b.request));
      expect(requests.take(a.token), same(a.request));
      expect(a.request.maxGraphemes, isNull);
    });

    test('cancel / cancelAll complete with no match', () async {
      final ReaderControllerLookupRequests requests =
          ReaderControllerLookupRequests();
      final ({int token, ReaderControllerLookupRequest request}) a = requests
          .start(null);
      final ({int token, ReaderControllerLookupRequest request}) b = requests
          .start(null);
      final ({int token, ReaderControllerLookupRequest request}) c = requests
          .start(null);
      requests.cancel(a.token);
      expect(await a.request.result, 0);
      expect(requests.take(a.token), isNull);
      requests.cancelAll();
      expect(await b.request.result, 0);
      expect(await c.request.result, 0);
      expect(requests.pendingCount, 0);
    });

    test('the caret lookup invocations carry the token', () {
      expect(
        ReaderCaretScripts.lookupInvocation(),
        'window.fushiCaret.lookup()',
      );
      expect(
        ReaderCaretScripts.lookupInvocation(token: 7),
        'window.fushiCaret.lookup(7)',
      );
      expect(
        ReaderLyricsCaretScripts.lookupInvocation(),
        'window.fushiLyricsCaret.lookup()',
      );
      expect(
        ReaderLyricsCaretScripts.lookupInvocation(token: 7),
        'window.fushiLyricsCaret.lookup(7)',
      );
      // Both carets select through the shared stamping helper.
      for (final String source in <String>[
        ReaderCaretScripts.source(),
        ReaderLyricsCaretScripts.source(),
      ]) {
        expect(source, contains('lookup: function(token)'));
        expect(source, contains(ReaderCaretScripts.controllerLookupSelectJs));
      }
    });

    test('the JS stamps the token on that one payload only (node)', () {
      final Directory temp = Directory.systemTemp.createTempSync(
        'fushi-reader-ctl-token-',
      );
      final File payload = File('${temp.path}/select.json')
        ..writeAsStringSync(
          jsonEncode(<String, String>{
            'select': ReaderCaretScripts.controllerLookupSelectJs,
          }),
        );
      late final ProcessResult result;
      try {
        result = Process.runSync(
          'node',
          <String>['-e', _tokenRunner, payload.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
      expect(
        result.exitCode,
        0,
        reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout.toString().trim(), 'OK');
    });
  });

  group('ReaderControllerWordStepScripts', () {
    test('context targets the book caret or the lyrics caret', () {
      final String book = ReaderControllerWordStepScripts.contextInvocation(
        lyrics: false,
      );
      final String lyrics = ReaderControllerWordStepScripts.contextInvocation(
        lyrics: true,
      );
      expect(book, contains('window.fushiCaret'));
      expect(book, contains('findParagraph'));
      expect(lyrics, contains('window.fushiLyricsCaret'));
      expect(lyrics, contains(".closest('.cue')"));
      // Both skip furigana / whitespace nodes like the lookup scan.
      expect(book, contains('createWalker'));
      expect(lyrics, contains('createWalker'));
    });

    test('a step composes the caret move in the step direction', () {
      final String forward = ReaderControllerWordStepScripts.stepInvocation(
        lyrics: false,
        delta: 3,
      );
      final String back = ReaderControllerWordStepScripts.stepInvocation(
        lyrics: true,
        delta: -2,
      );
      expect(forward, contains("c.move('forward')"));
      expect(forward, isNot(contains("c.move('backward')")));
      expect(back, contains("c.move('backward')"));
      expect(back, contains('window.fushiLyricsCaret'));
    });

    test('parseContext reads {text, index}; anything else is null', () {
      expect(
        ReaderControllerWordStepScripts.parseContext(
          '{"text":"私は先生","index":2}',
        ),
        (text: '私は先生', index: 2),
      );
      expect(
        ReaderControllerWordStepScripts.parseContext(<String, Object>{
          'text': 'あい',
          'index': 1,
        }),
        (text: 'あい', index: 1),
      );
      expect(ReaderControllerWordStepScripts.parseContext(null), isNull);
      expect(ReaderControllerWordStepScripts.parseContext('null'), isNull);
      expect(ReaderControllerWordStepScripts.parseContext('{bad'), isNull);
      expect(
        ReaderControllerWordStepScripts.parseContext('{"text":"あ","index":1}'),
        isNull,
        reason: 'index past the text',
      );
    });
  });

  group('wiring (source guard)', () {
    final String src = maskComments(readReaderPageSource());

    test('a rendered popup leaves the cursor in the text while the mode is '
        'on; other caret users still hand it to the popup', () {
      final String rendered = methodBody(
        src,
        'void onDictionaryPopupRendered(int index) {',
      );
      expect(rendered, contains('holdsCursorInText'));
      expect(rendered, contains('_caret.onDictionaryPopupRendered(index)'));
    });

    test('enter result hands the cursor to the popup caret', () {
      final String enter = methodBody(
        src,
        'Future<void> enterResult() async {',
      );
      expect(enter, contains('_caret.transferToTopPopup('));
      expect(enter, contains('isDictionaryShown'));
    });

    test('the lookup goes through the tap pipeline, capped and measured', () {
      final String lookup = methodBody(
        src,
        'Future<int> lookupAtCursor({int? maxGraphemes}) async {',
      );
      expect(lookup, contains('lookupInvocation(token: started.token)'));
      expect(lookup, contains('_requests.start(maxGraphemes)'));
      final String selected = methodBody(
        src,
        'Future<void> _handleTextSelected(',
      );
      expect(selected, contains('_claim(controllerLookup)'));
      expect(selected, contains('readerControllerCappedQuery('));
      expect(selected, contains('controller?.complete(matched)'));
      // The match length goes back in graphemes, the page lookup's and the
      // companion's (measured locally) alike.
      expect(selected, contains('lookupMatchedGraphemes('));
      expect(selected, contains('await _runLookupAndHighlight('));
      expect(selected, contains('measureLookupMatchGraphemes('));
      // The hot-slot reuse of the tap path (no popup stacking).
      expect(
        methodBody(src, 'Future<int> _runLookupAndHighlight('),
        contains('prunePopupStack(0);'),
      );
    });

    test('both onTextSelected handlers hand the payload token over', () {
      expect(
        "controllerLookup: payload['controllerLookup']".allMatches(src).length,
        2,
      );
    });

    test('word steps are on; the gamepad caret entry is gone', () {
      expect(src, contains('bool get hasWordSteps => true;'));
      expect(src, isNot(contains('_readerEnterCaretButtons')));
      expect(src, isNot(contains('isEnterTriggerGamepad')));
      // The popup caret keeps its gamepad routing after "enter result".
      expect(src, contains('ReaderCaretRouter.decideGamepad(button)'));
    });
  });
}

/// Runs [ReaderCaretScripts.controllerLookupSelectJs] against a stub
/// `fushiSelection` whose `selectFromPosition` fires the payload synchronously
/// (like the real one) and whose payload builder calls itself once for the
/// ruby-snap alternative.
const String _tokenRunner = r'''
const fs = require('fs');
const src = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).select;
const select = eval(src);
function assert(v, m) { if (!v) throw new Error(m); }
const sent = [];
const s = {
  buildSelectionPayload: function(x, y, inner) {
    const p = { text: 'word', x: x, y: y };
    if (!inner) p.rubySnap = { selection: this.buildSelectionPayload(x, y, true) };
    return p;
  },
  selectFromPosition: function(node, offset, max) {
    assert(max === 400, 'scan length');
    const p = this.buildSelectionPayload(1, 2);
    sent.push(p);
    return p.text;
  },
};
const original = s.buildSelectionPayload;
assert(select(s, {}, 0, 9) === 'word', 'returns the text');
assert(sent[0].controllerLookup === 9, 'stamped');
assert(sent[0].rubySnap.selection.controllerLookup === 9, 'snap stamped');
assert(s.buildSelectionPayload === original, 'builder restored');
// A tap lookup afterwards (no token) carries nothing.
s.selectFromPosition({}, 0, 400);
assert(!('controllerLookup' in sent[1]), 'tap not stamped');
// Token 0 = plain lookup.
select(s, {}, 0, 0);
assert(!('controllerLookup' in sent[2]), 'no token, no stamp');
// The builder is restored even when the selection throws.
s.selectFromPosition = function() { throw new Error('boom'); };
try { select(s, {}, 0, 4); } catch (e) {}
assert(s.buildSelectionPayload === original, 'restored after throw');
console.log('OK');
''';
