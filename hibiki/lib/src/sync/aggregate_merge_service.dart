import 'package:hibiki_audio/hibiki_audio.dart' show FavoriteSentence;

/// Pure, side-effect-free merge semantics for the aggregate families that
/// travel between devices on both offline backup merge-import (TODO-888) and
/// online two-way sync (TODO-1056 phase B/C). "Aggregate" means the families
/// whose merge is a value fold rather than a relational id-remap:
///
/// - per-bucket statistics (reading / video / hourly): MAX-union
/// - per-bucket mining counts: MAX (never SUM)
/// - mined-sentence history: fingerprint dedupe-union
/// - favorite words: uniqueKey dedupe-union
/// - favorite SENTENCES (a preference JSON blob): content dedupe-union
///
/// Every operation obeys the same four invariants, exactly the guarantees
/// online sync needs so a re-sync of the same snapshot is a no-op:
///
/// 1. Only-grows: a merged bucket/collection never loses a key the local side
///    had. Deletions are NOT propagated across the edge (a device that deleted
///    a favorite must not resurrect it on the peer, but a peer's favorite the
///    device never had is added).
/// 2. Never-shrinks-a-value: a numeric bucket only ever moves UP (max), never
///    down. A device that under-counts a bucket cannot pull the peer down.
/// 3. Idempotent: merge(a, a) == a and merge(merge(a, b), b) == merge(a, b).
///    Re-importing / re-syncing the same peer snapshot changes nothing.
/// 4. Commutative on the union set: which side is local vs remote does not
///    change the resulting set of buckets/rows or the per-bucket MAX. (For the
///    collections that keep the "earliest wins" tie-break the retained payload
///    on a content collision is order-independent: it is the row with the
///    smaller createdAt.)
///
/// This class is the SINGLE SOURCE OF TRUTH for these semantics. The offline
/// backup path (BackupMergeEngine) delegates its favorite-sentence pref-blob
/// merge here (there is no other implementation of it), and its SQL MAX-union /
/// dedupe-union statements are the relational projection of the pure folds
/// defined here. The pure functions are what the online sync path (phase B/C)
/// will call directly on materialised snapshots, and the tests pin both paths
/// to the identical contract.
///
/// All members are static; the class holds no state and is never instantiated.
class AggregateMergeService {
  const AggregateMergeService._();

  /// Per-key MAX-union of two counter maps (mining counts keyed by
  /// {sourceType, dateKey}, hourly durations keyed by {dateKey, hour}, ...).
  /// A key present on only one side is kept as-is; a key on both sides takes the
  /// larger value. MAX (not SUM) is what keeps a re-import idempotent: the same
  /// snapshot merged twice yields the same counter (mirrors setMiningCount).
  static Map<K, int> mergeMaxCounters<K>(
    Map<K, int> local,
    Map<K, int> remote,
  ) {
    final Map<K, int> out = Map<K, int>.from(local);
    remote.forEach((K key, int value) {
      final int? existing = out[key];
      out[key] =
          existing == null ? value : (existing > value ? existing : value);
    });
    return out;
  }

  /// Per-bucket MAX-union of multi-field statistic rows. Each bucket key (e.g.
  /// {title, dateKey} for reading/video statistics) maps to a [StatBucket]
  /// whose every numeric field is independently MAX-ed. A bucket on only one
  /// side is kept verbatim; a bucket on both sides is the field-wise MAX of the
  /// two. Never folds two distinct keys together (a dateKey shared by many
  /// titles stays as many rows).
  static Map<K, StatBucket> mergeStatBuckets<K>(
    Map<K, StatBucket> local,
    Map<K, StatBucket> remote,
  ) {
    final Map<K, StatBucket> out = Map<K, StatBucket>.from(local);
    remote.forEach((K key, StatBucket value) {
      final StatBucket? existing = out[key];
      out[key] = existing == null ? value : existing.maxWith(value);
    });
    return out;
  }

  /// Dedupe-union of favorite words. [uniqueKeyOf] projects each row to its
  /// business identity ({expression, reading, sourceType} for favorite_words).
  /// On a collision the [local] row is kept (mirrors the SQL engine's "earlier
  /// device row kept" behaviour); a remote row whose key is not present locally
  /// is appended. Local order is preserved, then the new remote rows follow in
  /// their own order: deterministic and idempotent.
  static List<T> mergeUniqueByKey<T>(
    List<T> local,
    List<T> remote,
    String Function(T row) uniqueKeyOf,
  ) {
    final Set<String> seen = <String>{};
    final List<T> out = <T>[];
    for (final T row in local) {
      if (seen.add(uniqueKeyOf(row))) out.add(row);
    }
    for (final T row in remote) {
      if (seen.add(uniqueKeyOf(row))) out.add(row);
    }
    return out;
  }

  /// Dedupe-union of favorite SENTENCES (the favorite_sentences preference JSON
  /// blob). This is the one aggregate family the SQL merge engine could not
  /// reach: favorite sentences are not a table but a JSON list in the
  /// preferences row favorite_sentences, so the SQL ATTACH merge silently
  /// dropped the backup's sentences (they were never merged). This closes that
  /// gap. The union deduplicates on the SAME content tuple the repository's own
  /// add / isFavorited / removeByContent use:
  /// {text, bookKey, sectionIndex, normCharOffset}, so a sentence the device
  /// already has (by content) is never duplicated even though its opaque
  /// timestamp id differs across devices.
  ///
  /// On a content collision the row with the EARLIER createdAt is retained
  /// (mirrors favorite-word "earlier createdAt kept"), making the result
  /// independent of which side is passed as [local]. Deletions do not propagate:
  /// a sentence removed locally is not re-added just because [remote] still has
  /// it; but a remote-only sentence IS added. The output is sorted newest-first
  /// (by createdAt descending) so it matches FavoriteSentenceRepository.getAll's
  /// ordering when written back.
  static List<FavoriteSentence> mergeFavoriteSentences(
    List<FavoriteSentence> local,
    List<FavoriteSentence> remote,
  ) {
    final Map<String, FavoriteSentence> byContent =
        <String, FavoriteSentence>{};
    void absorb(FavoriteSentence s) {
      final String key = _favoriteSentenceContentKey(s);
      final FavoriteSentence? existing = byContent[key];
      if (existing == null) {
        byContent[key] = s;
        return;
      }
      // Keep the earlier createdAt on a content collision (order-independent).
      if (s.createdAt.isBefore(existing.createdAt)) byContent[key] = s;
    }

    for (final FavoriteSentence s in local) {
      absorb(s);
    }
    for (final FavoriteSentence s in remote) {
      absorb(s);
    }
    final List<FavoriteSentence> out = byContent.values.toList()
      ..sort((FavoriteSentence a, FavoriteSentence b) =>
          b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// Content identity of a favorite sentence, matching
  /// FavoriteSentenceRepository._contentMatch
  /// ({text, bookKey, sectionIndex, normCharOffset}). Each nullable field uses
  /// an explicit null sentinel so a missing bookKey never collides with an empty
  /// string, nor a null sectionIndex with 0; text is length-prefixed so a
  /// separator inside text cannot forge a field boundary.
  static String _favoriteSentenceContentKey(FavoriteSentence s) {
    const String nul = '<null>';
    final String bookKey = s.bookKey ?? nul;
    final String section =
        s.sectionIndex == null ? nul : s.sectionIndex.toString();
    final String offset =
        s.normCharOffset == null ? nul : s.normCharOffset.toString();
    return '${s.text.length}:${s.text}|$bookKey|$section|$offset';
  }
}

/// A single statistics bucket's numeric payload, MAX-merged field-by-field.
/// Reading statistics carry charactersRead + readingTimeMs; video carry
/// subtitleChars + watchTimeMs; both also carry a lastModified watermark.
/// Rather than one class per table we model the shared shape: a set of named
/// numeric fields, each independently MAX-ed. Two buckets are only ever merged
/// when they share the SAME field names (same table), so a mismatch is a
/// programming error and throws rather than silently corrupting.
class StatBucket {
  const StatBucket(this.fields);

  /// Field name to value. Insertion order is irrelevant to equality/merge.
  final Map<String, int> fields;

  /// Field-wise MAX of this bucket and [other]. Requires identical field sets
  /// (same source table); a divergent field set is a caller bug.
  StatBucket maxWith(StatBucket other) {
    if (fields.length != other.fields.length ||
        !fields.keys.every(other.fields.containsKey)) {
      throw ArgumentError(
        'StatBucket.maxWith: field sets differ '
        '(${fields.keys.toList()} vs ${other.fields.keys.toList()})',
      );
    }
    final Map<String, int> merged = <String, int>{};
    fields.forEach((String name, int value) {
      final int otherValue = other.fields[name]!;
      merged[name] = value > otherValue ? value : otherValue;
    });
    return StatBucket(merged);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! StatBucket) return false;
    if (fields.length != other.fields.length) return false;
    for (final MapEntry<String, int> e in fields.entries) {
      if (other.fields[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    int h = 0;
    // Order-independent hash (XOR of per-entry hashes) so equal maps built in a
    // different insertion order hash the same.
    for (final MapEntry<String, int> e in fields.entries) {
      h ^= Object.hash(e.key, e.value);
    }
    return h;
  }

  @override
  String toString() => 'StatBucket($fields)';
}
