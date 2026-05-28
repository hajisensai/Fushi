import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_edge_matcher.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// Analyzes adjacent image-only EPUB chapters for spread pairing.
///
/// Runs edge-pixel comparison in an isolate and caches results in the
/// Drift preferences table so subsequent opens are instant.
class EpubSpreadAnalyzer {
  EpubSpreadAnalyzer._();

  static String _cacheKey(String bookId) => 'spread_match:$bookId';

  /// Load cached results. Returns `null` if no cache exists.
  static Future<Map<int, bool>?> loadCached(
    HibikiDatabase db,
    String bookId,
  ) async {
    final String? raw = await db.getPref(_cacheKey(bookId));
    if (raw == null) return null;
    try {
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((String k, dynamic v) =>
          MapEntry<int, bool>(int.parse(k), v as bool));
    } catch (_) {
      return null;
    }
  }

  /// Analyze all adjacent image-only chapter pairs and return a map of
  /// `{chapterIndex: matchesNext}`.
  ///
  /// The heavy image decoding runs in a background isolate via [compute].
  static Future<Map<int, bool>> analyze(EpubBook book) async {
    final List<_EdgePair> pairs = <_EdgePair>[];

    for (int i = 0; i < book.chapters.length - 1; i++) {
      if (!book.isImageOnlyChapter(i) || !book.isImageOnlyChapter(i + 1)) {
        continue;
      }
      // Already paired by OPF metadata — skip.
      if (book.chapters[i].spreadProperty != null &&
          book.chapters[i + 1].spreadProperty != null) {
        continue;
      }

      final String? leftPath = _resolveImagePath(book, i);
      final String? rightPath = _resolveImagePath(book, i + 1);
      if (leftPath == null || rightPath == null) continue;

      pairs.add(
          _EdgePair(chapterIndex: i, leftPath: leftPath, rightPath: rightPath));
    }

    if (pairs.isEmpty) return <int, bool>{};

    return compute(_analyzeInIsolate, pairs);
  }

  /// Save results to Drift preferences.
  static Future<void> saveCache(
    HibikiDatabase db,
    String bookId,
    Map<int, bool> results,
  ) async {
    final Map<String, bool> stringKeyed =
        results.map((int k, bool v) => MapEntry<String, bool>(k.toString(), v));
    await db.setPref(_cacheKey(bookId), jsonEncode(stringKeyed));
  }

  static String? _resolveImagePath(EpubBook book, int index) {
    final String? imgSrc = book.chapterImageSrc(index);
    if (imgSrc == null || book.rootDirectory == null) return null;
    final String chapterHref = book.chapters[index].href;
    final String chapterDir = p.dirname(chapterHref);
    final String resolved = p.normalize(p.join(chapterDir, imgSrc));
    final String absPath = p.join(book.rootDirectory!, resolved);
    return File(absPath).existsSync() ? absPath : null;
  }
}

class _EdgePair {
  const _EdgePair({
    required this.chapterIndex,
    required this.leftPath,
    required this.rightPath,
  });

  final int chapterIndex;
  final String leftPath;
  final String rightPath;
}

Map<int, bool> _analyzeInIsolate(List<_EdgePair> pairs) {
  final Map<int, bool> results = <int, bool>{};
  for (final _EdgePair pair in pairs) {
    try {
      final Uint8List leftBytes = File(pair.leftPath).readAsBytesSync();
      final Uint8List rightBytes = File(pair.rightPath).readAsBytesSync();
      final double score = EpubEdgeMatcher.compareEdges(leftBytes, rightBytes);
      results[pair.chapterIndex] = score >= EpubEdgeMatcher.spreadThreshold;
    } catch (_) {
      results[pair.chapterIndex] = false;
    }
  }
  return results;
}
