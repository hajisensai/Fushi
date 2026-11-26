import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';

AiSrsFieldSuggestion _plain(String reply) =>
    parseAiSrsFieldReply(reply, AiSrsFieldResponseMode.plain);

AiSrsFieldSuggestion _structured(String reply) =>
    parseAiSrsFieldReply(reply, AiSrsFieldResponseMode.structured);

Matcher _replyError(AiSrsFieldReplyErrorKind kind, String raw) =>
    isA<AiSrsFieldReplyError>()
        .having((AiSrsFieldReplyError e) => e.kind, 'kind', kind)
        .having((AiSrsFieldReplyError e) => e.raw, 'raw', raw);

String _s(String raw, {int max = kAiSrsFieldValueMax}) =>
    aiSrsFieldSanitizeHtml(raw, max: max);

void main() {
  group('response mode wire', () {
    test('frozen wire values round-trip', () {
      expect(aiSrsFieldResponseModeWire(AiSrsFieldResponseMode.plain), 'plain');
      expect(
        aiSrsFieldResponseModeWire(AiSrsFieldResponseMode.structured),
        'structured',
      );
      for (final AiSrsFieldResponseMode m in AiSrsFieldResponseMode.values) {
        expect(
          aiSrsFieldResponseModeFromWire(aiSrsFieldResponseModeWire(m)),
          m,
        );
      }
      expect(aiSrsFieldResponseModeFromWire(null), isNull);
      expect(aiSrsFieldResponseModeFromWire('json'), isNull);
    });
  });

  group('plain mode', () {
    test('simple text is the value, no explanation', () {
      final AiSrsFieldSuggestion s = _plain('  to notice; to realize  ');
      expect(s.value, 'to notice; to realize');
      expect(s.explanation, '');
    });

    test('whole reply in a fence with a language tag', () {
      expect(
        _plain('```html\n<b>気づく</b> to notice\n```').value,
        '<b>気づく</b> to notice',
      );
    });

    test('whole reply in a fence without a language tag', () {
      expect(_plain('```\nto notice\n```').value, 'to notice');
    });

    test('a fence that is only part of the reply is not unwrapped', () {
      final String v = _plain('Here:\n```\nx\n```').value;
      expect(v, contains('Here:'));
    });

    test('multi-line text becomes <br>, 3+ newlines collapse to two', () {
      expect(
        _plain('line one\r\nline two\rline three').value,
        'line one<br>line two<br>line three',
      );
      expect(_plain('a\n\n\n\n\nb').value, 'a<br><br>b');
    });

    test('HTML lists are kept and newlines inside them are not doubled', () {
      expect(
        _plain('<ul>\n<li>a</li>\n<li>b</li>\n</ul>').value,
        '<ul>\n<li>a</li>\n<li>b</li>\n</ul>',
      );
    });

    test('Markdown **bold** becomes <b> (local model replies, 2026-11-25)', () {
      expect(
        _plain('And when I **realized** it, I completely hated it.').value,
        'And when I <b>realized</b> it, I completely hated it.',
      );
      expect(_plain('**Oops, I guess.**').value, '<b>Oops, I guess.</b>');
      expect(
        _structured(
          '```json\n{\n  "value": "When I **noticed** that, I disliked it.",\n'
          '  "explanation": "The translation is direct."\n}\n```',
        ).value,
        'When I <b>noticed</b> that, I disliked it.',
      );
      // Not bold: single stars, spaced stars, a pair split across lines.
      expect(_plain('2 * 3 = 6, a *b* c').value, '2 * 3 = 6, a *b* c');
      expect(_plain('a ** b ** c').value, 'a ** b ** c');
      expect(_plain('**a\nb**').value, '**a<br>b**');
    });

    test('empty / whitespace / only-tags reply is an empty error with raw', () {
      for (final String raw in <String>[
        '',
        '   \n\t ',
        '<b></b><br><script>x</script>',
        '```\n\n```',
      ]) {
        expect(
          () => _plain(raw),
          throwsA(_replyError(AiSrsFieldReplyErrorKind.empty, raw)),
          reason: raw,
        );
      }
    });
  });

  group('structured mode', () {
    test('valid reply', () {
      final AiSrsFieldSuggestion s = _structured(
        '{"value": "<b>気づく</b>: to notice", "explanation": "Dictionary <i>sense</i> 1."}',
      );
      expect(s.value, '<b>気づく</b>: to notice');
      expect(s.explanation, 'Dictionary sense 1.');
    });

    test('empty or missing explanation is empty string', () {
      expect(_structured('{"value": "x", "explanation": ""}').explanation, '');
      expect(_structured('{"value": "x"}').explanation, '');
    });

    test('non-string explanation is ignored', () {
      expect(_structured('{"value": "x", "explanation": 3}').explanation, '');
      expect(
        _structured('{"value": "x", "explanation": ["a"]}').explanation,
        '',
      );
    });

    test('explanation is clipped to 300 characters', () {
      final String long = 'a' * 500;
      expect(
        _structured(
          '{"value": "x", "explanation": "$long"}',
        ).explanation.length,
        300,
      );
    });

    test('missing value is malformed with raw', () {
      const String raw = '{"explanation": "no value"}';
      expect(
        () => _structured(raw),
        throwsA(_replyError(AiSrsFieldReplyErrorKind.malformed, raw)),
      );
    });

    test('non-string value is malformed', () {
      for (final String raw in <String>[
        '{"value": 42}',
        '{"value": ["a", "b"]}',
        '{"value": {"text": "a"}}',
        '{"value": null}',
      ]) {
        expect(
          () => _structured(raw),
          throwsA(_replyError(AiSrsFieldReplyErrorKind.malformed, raw)),
          reason: raw,
        );
      }
    });

    test('malformed JSON / non-object / prose never falls back to text', () {
      for (final String raw in <String>[
        '{"value": "x"',
        '{value: x}',
        '["x"]',
        'to notice; to realize',
      ]) {
        expect(
          () => _structured(raw),
          throwsA(_replyError(AiSrsFieldReplyErrorKind.malformed, raw)),
          reason: raw,
        );
      }
    });

    test('chatter and fences around valid JSON are accepted', () {
      final AiSrsFieldSuggestion s = _structured(
        'Sure! Here you go:\n```json\n{"value": "to notice", "explanation": "ok"}\n```\nHope it helps.',
      );
      expect(s.value, 'to notice');
      expect(s.explanation, 'ok');
    });

    test('unexpected extra properties are ignored', () {
      final AiSrsFieldSuggestion s = _structured(
        '{"value": "x", "confidence": 0.9, "field": "Meaning", "explanation": "e"}',
      );
      expect(s.value, 'x');
      expect(s.explanation, 'e');
    });

    test('blank value after sanitizing is an empty error', () {
      for (final String raw in <String>[
        '{"value": ""}',
        '{"value": "   "}',
        '{"value": "<b></b><script>alert(1)</script>"}',
      ]) {
        expect(
          () => _structured(raw),
          throwsA(_replyError(AiSrsFieldReplyErrorKind.empty, raw)),
          reason: raw,
        );
      }
    });

    test('newlines in value become <br>', () {
      expect(_structured(r'{"value": "a\nb"}').value, 'a<br>b');
    });
  });

  group('aiSrsFieldSanitizeHtml', () {
    test('attributes and on* handlers are stripped', () {
      expect(
        _s('<b class="x" onclick="evil()" style="color:red">hi</b>'),
        '<b>hi</b>',
      );
      expect(_s('<span onmouseover="x()">a</span>'), '<span>a</span>');
    });

    test('strong / em map to b / i', () {
      expect(_s('<strong>a</strong><em>b</em>'), '<b>a</b><i>b</i>');
    });

    test('<a href> is unwrapped, text kept', () {
      expect(_s('see <a href="javascript:alert(1)">here</a>'), 'see here');
    });

    test('script / style / iframe / svg removed with content', () {
      expect(_s('a<script>alert(1)</script>b'), 'ab');
      expect(_s('a<style>b{color:red}</style>b'), 'ab');
      expect(_s('a<iframe src="x">inner</iframe>b'), 'ab');
      expect(_s('a<svg><text>t</text><script>x</script></svg>b'), 'ab');
      expect(_s('a<math><mi>x</mi></math>b'), 'ab');
    });

    test('<img onerror> is removed', () {
      expect(_s('a<img src=x onerror="alert(1)">b'), 'ab');
    });

    test('comments are dropped', () {
      expect(_s('a<!-- secret -->b'), 'ab');
    });

    test('unbalanced, misnested and stray tags come out balanced', () {
      expect(_s('<b>foo'), '<b>foo</b>');
      expect(_s('<b><i>x</b></i>'), '<b><i>x</i></b>');
      expect(_s('a</b>b'), 'ab');
      expect(_s('<i>a<b>b</i>c</b>'), '<i>a<b>b</b></i><b>c</b>');
    });

    test('nested lists are kept', () {
      const String html = '<ul><li>a<ol><li>b</li><li>c</li></ol></li></ul>';
      expect(_s(html), html);
    });

    test('ruby with and without rt', () {
      expect(_s('<ruby>漢字<rt>かんじ</rt></ruby>'), '<ruby>漢字<rt>かんじ</rt></ruby>');
      expect(
        _s('<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>'),
        '<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>',
      );
      expect(_s('<ruby>漢字</ruby>'), '<ruby>漢字</ruby>');
    });

    test('javascript: text stays inert text', () {
      expect(_s('javascript:alert(1)'), 'javascript:alert(1)');
    });

    test('entities: literal markup stays literal, & is escaped', () {
      expect(_s('&lt;b&gt;'), '&lt;b&gt;');
      expect(_s('a & b < c > d'), 'a &amp; b &lt; c &gt; d');
      expect(_s('&amp;'), '&amp;');
      expect(_s('&quot;x&quot;'), '"x"');
    });

    test('legitimate content is untouched', () {
      for (final String html in <String>[
        '漢字<b>気づいた</b>時',
        'それに<b>気づいた</b>時',
        '<ul><li>a</li><li>b</li></ul>',
        'a<br>b',
        '<div>a</div><div><br></div><div>b</div>',
        '<p>x<sub>2</sub>y<sup>3</sup><mark>m</mark><u>u</u></p>',
      ]) {
        expect(_s(html), html, reason: html);
      }
    });

    test('br forms normalise to <br>, empty wrappers are dropped', () {
      expect(_s('a<br/>b<BR >c</br>d'), 'a<br>b<br>c<br>d');
      expect(_s('a<b></b><i><span></span></i>b'), 'ab');
    });

    test('truncation keeps tags balanced and length <= max', () {
      final String long = '<b>${'あ' * 3000}</b>';
      final String out = _s(long);
      expect(out.length, lessThanOrEqualTo(kAiSrsFieldValueMax));
      expect(out, startsWith('<b>'));
      expect(out, endsWith('</b>'));
      expect(_s('<b>abcdefgh</b>tail', max: 10), '<b>abc</b>');
      expect(_s('<ul><li>abcdef</li></ul>', max: 21), '<ul><li>abc</li></ul>');
    });

    test('truncation never splits an entity or emits an empty wrapper', () {
      expect(_s('a&b', max: 3), 'a');
      expect(_s('a&b', max: 6), 'a&amp;');
      expect(_s('ab<b>cd</b>', max: 8), 'ab');
      expect(_s('ab<br>cd', max: 5), 'ab');
    });

    test('truncation does not split a surrogate pair', () {
      expect(_s('a😀b', max: 2), 'a');
      expect(_s('a😀b', max: 3), 'a😀');
    });

    test('idempotent', () {
      for (final String html in <String>[
        '<b>foo',
        '<b><i>x</b></i>',
        '<i>a<b>b</i>c</b>',
        '<p>a<table><tr><td><div>b</div></td></tr></table>c</p>',
        '<ul><li>a<table><tr><td><li>b</li></td></tr></table></li></ul>',
        '<ruby>漢<table><tr><td><rt>a<table><tr><td><rt>b',
        '<ruby><ul><li>x<table><tr><td><rt>y</rt></td></tr></table></li></ul></ruby>',
        '<p>a<li>b</li>c</p>',
        '<b><b><b><b>deep</b></b></b></b>',
        '  <b> spaced </b>  ',
        'x<noembed><script>alert(1)</script></noembed>',
        '<plaintext><b>x</b>',
        '<select><option>o</option></select>t',
        '<b>${'漢' * 2500}</b>',
      ]) {
        final String once = _s(html);
        expect(_s(once), once, reason: html);
      }
    });
  });
}
