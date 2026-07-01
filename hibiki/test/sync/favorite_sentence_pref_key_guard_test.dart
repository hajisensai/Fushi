import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static guard: the favorite-sentence pref key the merge engine reads/writes
/// (`BackupMergeEngine._favoriteSentencesPrefKey`) MUST match the key the
/// repository actually persists under (`FavoriteSentenceRepository._key`).
/// If either drifts, the merge would silently read/write the wrong preferences
/// row and favorite sentences would stop merging again (the exact TODO-1056
/// gap this closed). A source scan keeps the two in lockstep without needing a
/// DB fixture.
void main() {
  test('merge engine favorite-sentences pref key matches the repository key',
      () {
    String literalAfter(String file, String needle) {
      final String src = File(file).readAsStringSync();
      final int idx = src.indexOf(needle);
      expect(idx, isNonNegative, reason: 'anchor "$needle" not found in $file');
      final RegExp re = RegExp(r"'([^']*)'");
      final Match? m = re.firstMatch(src.substring(idx));
      expect(m, isNotNull,
          reason: 'no string literal after "$needle" in $file');
      return m!.group(1)!;
    }

    // Resolve paths relative to the hibiki package root (cwd during tests).
    final String repoKey = literalAfter(
      '../packages/hibiki_audio/lib/src/audiobook/'
          'favorite_sentence_repository.dart',
      'static const String _key =',
    );
    final String engineKey = literalAfter(
      'lib/src/sync/backup_merge_engine.dart',
      'static const String _favoriteSentencesPrefKey =',
    );

    expect(engineKey, repoKey);
    expect(repoKey, 'favorite_sentences'); // pin the actual value too
  });
}
