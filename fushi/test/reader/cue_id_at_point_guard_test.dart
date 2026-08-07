import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guard: the shared reader JS must expose a `cueIdAtPoint`
/// reverse-lookup that reuses the existing cue↔DOM maps (cueRangesMap /
/// cueWrappers / [data-cue-id]) rather than re-deriving normChar offsets.
void main() {
  test('shared reader JS exposes cueIdAtPoint reverse-lookup primitive', () {
    final src = File('lib/src/reader/reader_pagination_scripts.dart')
        .readAsStringSync();
    expect(src.contains('cueIdAtPoint:'), isTrue);
    expect(src.contains('cueRangesMap'), isTrue);
    expect(src.contains('cueWrappers'), isTrue);
    expect(src.contains('data-cue-id'), isTrue);
    expect(src.contains('comparePoint'), isTrue);
  });
}
