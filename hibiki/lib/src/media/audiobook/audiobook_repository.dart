import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/media/audiobook/audiobook_health.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

class AudiobookRepository {
  const AudiobookRepository(this._db);

  final HibikiDatabase _db;

  // ── audiobook CRUD ──────────────────────────────────────────────

  Future<Audiobook?> findByBookUid(String bookUid) async {
    final row = await _db.getAudiobookByBookUid(bookUid);
    if (row == null) return null;
    return _rowToAudiobook(row);
  }

  Future<List<AudioCue>> cuesForChapter({
    required String bookUid,
    required String chapterHref,
  }) async {
    final rows = await _db.getCuesForChapter(bookUid, chapterHref);
    return rows.map(AudioCue.fromRow).toList();
  }

  Future<List<AudioCue>> cuesForBook(String bookUid) async {
    final rows = await _db.getCuesForBook(bookUid);
    return rows.map(AudioCue.fromRow).toList();
  }

  Future<AudioCue?> findCue({
    required String bookUid,
    required String chapterHref,
    required int sentenceIndex,
  }) async {
    final row = await _db.findCue(bookUid, chapterHref, sentenceIndex);
    if (row == null) return null;
    return AudioCue.fromRow(row);
  }

  Future<void> saveCues({
    required String bookUid,
    required String chapterHref,
    required List<AudioCue> cues,
  }) async {
    await _db.replaceCuesForBook(
        bookUid, cues.map(AudioCue.toCompanion).toList());
  }

  Future<void> saveAudiobook(Audiobook audiobook) async {
    await _db.upsertAudiobook(_audiobookToCompanion(audiobook));
    debugPrint('[hibiki-audiobook] saveAudiobook bookUid=${audiobook.bookUid}');
  }

  Future<void> deleteAudiobook(String bookUid) async {
    await _db.transaction(() async {
      await _db.deleteAudiobookByBookUid(bookUid);
      await ((_db.delete(_db.audioCues))
            ..where((t) => t.bookUid.equals(bookUid)))
          .go();
    });
  }

  // ── follow audio (preferences) ─────────────────────────────────

  static const String _kFollowAudioKeyPrefix = 'audiobook_follow_';
  static const String _kDelayMsKeyPrefix = 'audiobook_delay_';
  static const String _kSpeedKeyPrefix = 'audiobook_speed_';
  static const String _kHealthOverlayKeyPrefix = 'audiobook_health_overlay_';

  Future<bool> readFollowAudio(String bookUid) async {
    return await _db.getPrefTyped(
        '$_kFollowAudioKeyPrefix$bookUid', true);
  }

  Future<void> updateFollowAudio({
    required String bookUid,
    required bool value,
  }) =>
      _db.setPrefTyped('$_kFollowAudioKeyPrefix$bookUid', value);

  Future<int> readDelayMs(String bookUid) async {
    return await _db.getPrefTyped('$_kDelayMsKeyPrefix$bookUid', 0);
  }

  Future<void> updateDelayMs({
    required String bookUid,
    required int ms,
  }) =>
      _db.setPrefTyped('$_kDelayMsKeyPrefix$bookUid', ms);

  Future<double> readSpeed(String bookUid) async {
    final raw = await _db.getPref('$_kSpeedKeyPrefix$bookUid');
    if (raw == null) return 1.0;
    return double.tryParse(raw) ?? 1.0;
  }

  Future<void> updateSpeed({
    required String bookUid,
    required double speed,
  }) =>
      _db.setPref('$_kSpeedKeyPrefix$bookUid', speed.toString());

  // ── health overlay ──────────────────────────────────────────────

  Future<AudiobookHealth?> readHealthOverlay(String bookUid) async {
    final raw = await _db.getPref('$_kHealthOverlayKeyPrefix$bookUid');
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final kindRaw = (m['kind'] as String?) ?? 'unrun';
      final kind = HealthKind.values.firstWhere(
        (k) => k.name == kindRaw,
        orElse: () => HealthKind.unrun,
      );
      final pct = (m['pct'] as num?)?.toInt();
      final pctSafe = (pct == null || pct < 0 || pct > 100) ? null : pct;
      final atMs = (m['at'] as num?)?.toInt();
      return AudiobookHealth(
        kind: kind,
        ratePct: pctSafe,
        reason: m['reason'] as String?,
        measuredAt: atMs != null
            ? DateTime.fromMillisecondsSinceEpoch(atMs)
            : DateTime.now(),
      );
    } catch (e) {
      debugPrint('[hibiki-audiobook] readHealthOverlay parse failed: $e');
      return null;
    }
  }

  Future<void> updateHealthOverlay({
    required String bookUid,
    required AudiobookHealth health,
  }) async {
    final m = <String, dynamic>{
      'kind': health.kind.name,
      'pct': health.ratePct,
      'reason': health.reason,
      'at': health.measuredAt.millisecondsSinceEpoch,
    };
    await _db.setPref('$_kHealthOverlayKeyPrefix$bookUid', jsonEncode(m));
  }

  Future<AudiobookHealth> resolveHealth(Audiobook ab) async {
    final overlay = await readHealthOverlay(ab.bookUid);
    if (overlay != null) return overlay;
    return AudiobookHealth.fromAudiobook(ab);
  }

  // ── conversions ─────────────────────────────────────────────────

  static Audiobook _rowToAudiobook(AudiobookRow r) {
    final ab = Audiobook();
    ab.id = r.id;
    ab.bookUid = r.bookUid;
    ab.audioRoot = r.audioRoot;
    ab.audioPaths = r.audioPathsJson != null
        ? (jsonDecode(r.audioPathsJson!) as List).cast<String>()
        : null;
    ab.alignmentFormat = r.alignmentFormat;
    ab.alignmentPath = r.alignmentPath;
    ab.healthKindRaw = r.healthKindRaw;
    ab.matchRatePct = r.matchRatePct;
    ab.healthMeasuredAt = r.healthMeasuredAt;
    ab.healthReason = r.healthReason;
    ab.followAudio = r.followAudio;
    return ab;
  }

  static AudiobooksCompanion _audiobookToCompanion(Audiobook ab) {
    return AudiobooksCompanion(
      bookUid: Value(ab.bookUid),
      audioRoot: Value(ab.audioRoot),
      audioPathsJson: Value(
          ab.audioPaths != null ? jsonEncode(ab.audioPaths) : null),
      alignmentFormat: Value(ab.alignmentFormat),
      alignmentPath: Value(ab.alignmentPath),
      healthKindRaw: Value(ab.healthKindRaw),
      matchRatePct: Value(ab.matchRatePct),
      healthMeasuredAt: Value(ab.healthMeasuredAt),
      healthReason: Value(ab.healthReason),
      followAudio: Value(ab.followAudio),
    );
  }

}
