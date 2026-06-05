// BUG-051 source-scan guard.
//
// Root cause: `Index::title` (yomitan_parser.hpp) is a `std::string_view` that
// glaze parses zero-copy — it only points into the JSON source buffer while
// that buffer is alive. `DictionaryQuery::add_dict` (query.cpp) used to read
// `index.title` AFTER the `index_buf` block had closed, i.e. after the buffer
// was freed. That use-after-free left the copied `dict.name` with its leading
// bytes overwritten by recycled heap data, so dictionary labels in the popup
// rendered as U+FFFD garble (heap-layout dependent → intermittent).
//
// This guard fails if anyone reintroduces the bug by reading `index.title`
// outside the `index_buf` scope. It works on the relative brace depth between
// the `index_buf` declaration and every `index.title` usage: a usage that has
// left the buffer's block (net depth < 0) is a use-after-free.
//
// Layer rationale: the fix lives in native C++ that flutter_test cannot link,
// so the strongest *landable* automated guard is a source-scan over the C++ —
// same approach the repo uses for other invariants. A manual end-to-end check
// also exists at native/hoshidicts/tests/dict_name_lifetime_test.cpp.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('add_dict copies index.title while index_buf is still in scope', () {
    final File src =
        File('../native/hoshidicts/hoshidicts_src/query.cpp');
    expect(src.existsSync(), isTrue,
        reason: 'query.cpp not found at ${src.absolute.path}');
    final String code = src.readAsStringSync();

    // Isolate the add_dict function body so unrelated code can't skew the scan.
    final int addDictStart = code.indexOf('void DictionaryQuery::add_dict(');
    expect(addDictStart, greaterThanOrEqualTo(0),
        reason: 'add_dict() not found in query.cpp');
    final String body = code.substring(addDictStart);

    final int bufDecl = body.indexOf('index_buf');
    expect(bufDecl, greaterThanOrEqualTo(0),
        reason: 'index_buf declaration not found in add_dict()');

    final RegExp titleUse = RegExp(r'index\.title');
    final Iterable<Match> uses = titleUse.allMatches(body);
    expect(uses, isNotEmpty,
        reason: 'expected add_dict() to read index.title');

    for (final Match m in uses) {
      expect(m.start, greaterThan(bufDecl),
          reason: 'index.title used before index_buf is declared');
      // Relative brace depth from the index_buf declaration to this usage.
      // Each unmatched "}" that closes the buffer's block drops below 0.
      final String between = body.substring(bufDecl, m.start);
      final int opens = '{'.allMatches(between).length;
      final int closes = '}'.allMatches(between).length;
      expect(opens - closes, greaterThanOrEqualTo(0),
          reason: 'index.title is read after the index_buf block closed — '
              'that is a use-after-free of a glaze string_view (BUG-051). '
              'Copy index.title into dict.name *inside* the index_buf scope.');
    }

    // Positive marker: the title must be taken as an owned copy.
    expect(body.contains('std::string(index.title)'), isTrue,
        reason: 'expected dict.name to take an owned std::string copy of '
            'index.title (the glaze view must not outlive index_buf).');
  });
}
