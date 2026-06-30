import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'audiobook_health.dart';
import 'audiobook_model.dart';
import 'audiobook_storage.dart';

class AudiobookRepository {
  const AudiobookRepository(this._db);

  final HibikiDatabase _db;

  // ── audiobook CRUD ──────────────────────────────────────────────

  Future<Audiobook?> findByBookKey(String bookKey) async {
    final row = await _db.getAudiobookByBookKey(bookKey);
    if (row == null) return null;
    return _rowToAudiobook(row);
  }

  Future<Map<String, Audiobook>> buildBookKeyMap() async {
    final rows = await _db.getAllAudiobooks();
    return {for (final row in rows) row.bookKey: _rowToAudiobook(row)};
  }

  Future<List<AudioCue>> cuesForChapter({
    required String bookKey,
    required String chapterHref,
  }) async {
    final rows = await _db.getCuesForChapter(bookKey, chapterHref);
    return rows.map(AudioCue.fromRow).toList();
  }

  Future<List<AudioCue>> cuesForBook(String bookKey) async {
    final rows = await _db.getCuesForBook(bookKey);
    return rows.map(AudioCue.fromRow).toList();
  }

  Future<AudioCue?> findCue({
    required String bookKey,
    required String chapterHref,
    required int sentenceIndex,
  }) async {
    final row = await _db.findCue(bookKey, chapterHref, sentenceIndex);
    if (row == null) return null;
    return AudioCue.fromRow(row);
  }

  Future<void> saveCues({
    required String bookKey,
    required List<AudioCue> cues,
  }) async {
    await _db.replaceCuesForBook(
        bookKey, cues.map(AudioCue.toCompanion).toList());
  }

  Future<void> saveAudiobook(Audiobook audiobook) async {
    await _db.upsertAudiobook(_audiobookToCompanion(audiobook));
    debugPrint('[hibiki-audiobook] saveAudiobook bookKey=${audiobook.bookKey}');
  }

  Future<void> deleteAudiobook(String bookKey) async {
    // deleteAudiobookByBookKey 内部已先删 audioCues 再删 audiobooks。
    await _db.deleteAudiobookByBookKey(bookKey);
    await AudiobookStorage.deletePersistDir(bookKey);
  }

  // ── playback position (preferences) ────────────────────────────

  static const String _kPositionMsKeyPrefix = 'audiobook_pos_';

  /// 位置最后写入时刻（epoch 毫秒）pref 前缀。与 `audiobook_pos_<bookKey>` 配套，
  /// 供互联（LAN）live 进度同步做「取较新时间戳」LWW（BUG-471）。云后端 SyncManager
  /// 路径不读此键（其时间戳借用阅读进度 `lastBookmarkModified`），互不影响。
  static const String _kPositionAtMsKeyPrefix = 'audiobook_pos_at_';

  Future<int> readPositionMs(String bookKey) async {
    return _db.getPrefTyped('$_kPositionMsKeyPrefix$bookKey', 0);
  }

  /// 读位置最后写入时刻（epoch 毫秒）；无记录（旧数据未写过时间戳）返回 0，让任何
  /// 带时间戳的对端进度在 LWW 中胜出（向后兼容降级，BUG-471）。
  Future<int> readPositionUpdatedAtMs(String bookKey) async {
    return _db.getPrefTyped('$_kPositionAtMsKeyPrefix$bookKey', 0);
  }

  /// 写位置（毫秒）并同时写入当前时刻为更新时间戳（BUG-471）。位置与时间戳是同一
  /// 进度的两个 pref，必须一起写，否则 LWW 无依据。
  Future<void> updatePositionMs({
    required String bookKey,
    required int positionMs,
  }) async {
    await _db.setPrefTyped('$_kPositionMsKeyPrefix$bookKey', positionMs);
    await _db.setPrefTyped('$_kPositionAtMsKeyPrefix$bookKey',
        DateTime.now().millisecondsSinceEpoch);
  }

  // ── follow audio (preferences) ─────────────────────────────────

  static const String _kFollowAudioKeyPrefix = 'audiobook_follow_';
  static const String _kDelayMsKeyPrefix = 'audiobook_delay_';
  static const String _kSpeedKeyPrefix = 'audiobook_speed_';
  static const String _kVolumeKeyPrefix = 'audiobook_volume_';
  static const String _kImagePauseSecKeyPrefix = 'audiobook_image_pause_';
  static const String _kHealthOverlayKeyPrefix = 'audiobook_health_overlay_';

  Future<bool> readFollowAudio(String bookKey) async {
    return _db.getPrefTyped('$_kFollowAudioKeyPrefix$bookKey', true);
  }

  Future<void> updateFollowAudio({
    required String bookKey,
    required bool value,
  }) =>
      _db.setPrefTyped('$_kFollowAudioKeyPrefix$bookKey', value);

  Future<int> readDelayMs(String bookKey) async {
    return _db.getPrefTyped('$_kDelayMsKeyPrefix$bookKey', 0);
  }

  Future<void> updateDelayMs({
    required String bookKey,
    required int ms,
  }) =>
      _db.setPrefTyped('$_kDelayMsKeyPrefix$bookKey', ms);

  Future<double> readSpeed(String bookKey) async {
    final raw = await _db.getPref('$_kSpeedKeyPrefix$bookKey');
    if (raw == null) return 1.0;
    return double.tryParse(raw) ?? 1.0;
  }

  Future<void> updateSpeed({
    required String bookKey,
    required double speed,
  }) =>
      _db.setPref('$_kSpeedKeyPrefix$bookKey', speed.toString());

  Future<double> readVolume(String bookKey) async {
    final raw = await _db.getPref('$_kVolumeKeyPrefix$bookKey');
    if (raw == null) return 1.0;
    return double.tryParse(raw) ?? 1.0;
  }

  Future<void> updateVolume({
    required String bookKey,
    required double volume,
  }) =>
      _db.setPref('$_kVolumeKeyPrefix$bookKey', volume.toString());

  // ── image pause ─────────────────────────────────────────────────

  Future<int> readImagePauseSec(String bookKey) async {
    return _db.getPrefTyped('$_kImagePauseSecKeyPrefix$bookKey', 0);
  }

  Future<void> updateImagePauseSec({
    required String bookKey,
    required int sec,
  }) =>
      _db.setPrefTyped('$_kImagePauseSecKeyPrefix$bookKey', sec);

  // ── health overlay ──────────────────────────────────────────────

  Future<AudiobookHealth?> readHealthOverlay(String bookKey) async {
    final raw = await _db.getPref('$_kHealthOverlayKeyPrefix$bookKey');
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
    } catch (e, stack) {
      debugPrint('AudiobookRepository.healthOverlay: $e\n$stack');
      debugPrint('[hibiki-audiobook] readHealthOverlay parse failed: $e');
      return null;
    }
  }

  Future<void> updateHealthOverlay({
    required String bookKey,
    required AudiobookHealth health,
  }) async {
    final m = <String, dynamic>{
      'kind': health.kind.name,
      'pct': health.ratePct,
      'reason': health.reason,
      'at': health.measuredAt.millisecondsSinceEpoch,
    };
    await _db.setPref('$_kHealthOverlayKeyPrefix$bookKey', jsonEncode(m));
  }

  Future<AudiobookHealth> resolveHealth(Audiobook ab) async {
    final overlay = await readHealthOverlay(ab.bookKey);
    if (overlay != null) return overlay;
    return AudiobookHealth.fromAudiobook(ab);
  }

  // ── conversions ─────────────────────────────────────────────────

  static Audiobook _rowToAudiobook(AudiobookRow r) {
    final ab = Audiobook();
    ab.id = r.id;
    ab.bookKey = r.bookKey;
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
      bookKey: Value(ab.bookKey),
      audioRoot: Value(ab.audioRoot),
      audioPathsJson:
          Value(ab.audioPaths != null ? jsonEncode(ab.audioPaths) : null),
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
