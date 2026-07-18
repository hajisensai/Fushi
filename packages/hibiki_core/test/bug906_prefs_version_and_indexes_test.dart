import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-906 regression guards.
///
/// A — prefs_version concurrent increment loss: [HibikiDatabase.setPref] used to
/// write the business preference and bump the cross-process `prefs_version`
/// counter as two independent awaits, with [HibikiDatabase] `_bumpPrefsVersion`
/// doing a non-atomic read-modify-write. Concurrent writers could both read the
/// same version N and both write N+1, silently dropping increments so the
/// separate :popup process kept serving a stale pref cache. The fix wraps
/// insert+bump in one transaction, which drift serializes on the single write
/// connection. This test races many setPref calls and asserts the counter
/// advanced by exactly the number of writes.
///
/// B — missing hot-path indexes: [HibikiDatabase] `_ensureIndexes` gained an
/// audio_cues composite index plus tag_id / source_type indexes. This test opens
/// a fresh DB (onCreate runs createAll + _ensureIndexes) and asserts every new
/// index actually exists in sqlite_master.
void main() {
  group('BUG-906 A: prefs_version concurrency', () {
    test('concurrent setPref never loses a prefs_version increment', () async {
      final HibikiDatabase db = HibikiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);

      // Touch the DB so the lazy open (onCreate) completes before racing.
      final String? beforeRaw =
          await db.getPref(HibikiDatabase.prefsVersionKey);
      final int baseline =
          beforeRaw == null ? 0 : PrefCodec.decode<int>(beforeRaw, 0);

      const int writes = 50;
      await Future.wait(<Future<void>>[
        for (int i = 0; i < writes; i++) db.setPref('bug906_key_$i', 'v$i'),
      ]);

      final String? afterRaw = await db.getPref(HibikiDatabase.prefsVersionKey);
      final int finalVersion =
          afterRaw == null ? 0 : PrefCodec.decode<int>(afterRaw, 0);

      expect(
        finalVersion - baseline,
        writes,
        reason:
            'each non-version setPref must bump prefs_version exactly once; '
            'a smaller delta means concurrent bumps lost increments',
      );

      // Business values must also have landed (the transaction commits both).
      expect(await db.getPref('bug906_key_0'), 'v0');
      expect(await db.getPref('bug906_key_49'), 'v49');
    });

    test('setPref of the version key itself does not double-bump', () async {
      final HibikiDatabase db = HibikiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);

      await db.setPref('bug906_seed', 'x'); // version -> 1
      final String? afterSeed =
          await db.getPref(HibikiDatabase.prefsVersionKey);
      final int seeded =
          afterSeed == null ? 0 : PrefCodec.decode<int>(afterSeed, 0);

      // A direct replay of the version key (sync/backup restore path) must NOT
      // recursively bump on top of its own value.
      await db.setPref(
        HibikiDatabase.prefsVersionKey,
        PrefCodec.encode(seeded),
      );
      final String? afterReplay =
          await db.getPref(HibikiDatabase.prefsVersionKey);
      final int replayed =
          afterReplay == null ? 0 : PrefCodec.decode<int>(afterReplay, 0);

      expect(replayed, seeded,
          reason: 'writing prefs_version directly must be exact, not bumped');
    });
  });

  group('BUG-906 B: hot-path indexes exist after onCreate', () {
    test('_ensureIndexes creates the audio_cues / tag_id / source_type indexes',
        () async {
      final HibikiDatabase db = HibikiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);

      // Force the lazy open so onCreate (createAll + _ensureIndexes) runs.
      await db.getPref('bug906_touch');

      Future<bool> indexExists(String name) async {
        // `name` is a hard-coded test literal, safe to inline.
        final rows = await db
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE type='index' AND name='$name'",
            )
            .get();
        return rows.isNotEmpty;
      }

      const List<String> required = <String>[
        'idx_audio_cues_book_chapter_sentence',
        'idx_book_tag_mappings_tag_id',
        'idx_srt_book_tag_mappings_tag_id',
        'idx_video_book_tag_mappings_tag_id',
        'idx_favorite_words_source_type',
      ];
      for (final String name in required) {
        expect(await indexExists(name), isTrue, reason: 'missing index $name');
      }
    });
  });
}
