import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'audiobook_health.dart';
import 'audiobook_model.dart';
import 'audiobook_storage.dart';

class AudiobookRepository {
  const AudiobookRepository(this._db);

  final FushiDatabase _db;

  /// 暴露底层数据库，供同库其它仓库（如 [SrtBookRepository]）在同一 app 流程内
  /// 复用同一连接（TODO-1288：EPUB-backed 有声书导入后补写配对 srt_books 行）。
  FushiDatabase get database => _db;

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

  // ── 窄写入：一次只改一件事 ───────────────────────────────────────
  //
  // BUG-1678：这里**故意没有**「写一整行 Audiobook」的入口。`upsertAudiobook`
  // 是整行覆盖（companion 每列都是 `Value(...)`，没有 absent），凭空造一个模型
  // 再写就会把本次没碰的列静默清空——「只换字幕」因此清掉了 audioPaths/audioRoot，
  // 用户的音频消失。修法不是「记得先克隆一份基线」（那只是把地雷挪个位置），
  // 而是**不给整行入口**：调用方只能说「换音频」「换字幕」「回写 health」，
  // 每个动作只写自己那几列，想清空别的列都无从下手。

  /// 保证 [bookKey] 有一行；已存在则原样不动。附加音频/字幕前先调它。
  Future<void> ensureAudiobook(String bookKey) async {
    await _db.ensureAudiobookRow(bookKey);
    // 删除传播：重新导入同 bookKey 的有声书 → 清其 sync 删除墓碑，防「删了又加、
    // 墓碑还在」误判（范式仿书/视频的插入清墓碑）。
    await _db.clearSyncDeletionTombstone(
        SyncTombstoneKind.audiobook.dbValue, bookKey);
  }

  /// 换音频（唯一写音频两列的入口）。[audioPaths] 为落地后的绝对路径列表，
  /// 顺序即 `AudioCue.audioFileIndex` 的含义。写入后 `audioRoot` 恒为 null：
  /// 新音频一律文件列表模式，legacy 目录模式不得残留（否则读取端在 audioPaths
  /// 断链时会回退去扫早已作废的旧目录）。
  ///
  /// BUG-1679：音频集合真的变了就把播放进度归零。`audiobook_pos_<bookKey>` 记的
  /// 是**毫秒偏移**，只在它绑定的那一套音频上有意义；换一套后同一个数字指向的是
  /// 另一段声音：
  ///   * 超出新音频总时长 → [AudiobookPlayerController.load] 的恢复 seek 把播放器
  ///     钉在 EOF，按播放立刻结束 —— 用户看到的是「音频不响」；
  ///   * 落在时长内 → 起播点随机，followAudio 立刻把阅读器拽到那条 cue 所在的页
  ///     —— 用户看到的是「乱跳页」。
  /// 判据是数据本身（新旧集合不等），所以重复导入同一组音频不会误伤「听到哪儿了」。
  /// 旧行不存在时也归零：bookKey 是 sanitize 后的书名，删书重导会拿到同一个 key，
  /// 而 preferences 不随书删除，上一世的进度会原样复活。
  Future<void> replaceAudio({
    required String bookKey,
    required List<String> audioPaths,
  }) async {
    await ensureAudiobook(bookKey);
    final AudiobookRow? before = await _db.getAudiobookByBookKey(bookKey);
    final bool audioChanged = before == null ||
        before.audioRoot != null ||
        !AudiobookStorage.sameAudioPathList(
          _audioPathsOf(before),
          audioPaths,
        );

    await _db.patchAudiobook(
      bookKey,
      AudiobooksCompanion(
        audioPathsJson: Value(jsonEncode(audioPaths)),
        audioRoot: const Value<String?>(null),
      ),
    );
    if (audioChanged) {
      await updatePositionMs(bookKey: bookKey, positionMs: 0);
    }
    debugPrint('[hibiki-audiobook] replaceAudio bookKey=$bookKey '
        'files=${audioPaths.length} audioChanged=$audioChanged');
  }

  /// 换对齐字幕（唯一写 alignment 两列的入口）。
  Future<void> replaceAlignment({
    required String bookKey,
    required String format,
    required String path,
  }) async {
    await ensureAudiobook(bookKey);
    await _db.patchAudiobook(
      bookKey,
      AudiobooksCompanion(
        alignmentFormat: Value(format),
        alignmentPath: Value(path),
      ),
    );
  }

  /// 回写 health 四列（唯一写 health 列的入口）。与 [updateHealthOverlay]
  /// 的 pref overlay 是两回事：这里落的是 audiobooks 行上的持久值。
  Future<void> writeHealth({
    required String bookKey,
    required AudiobookHealth health,
  }) async {
    await ensureAudiobook(bookKey);
    final Audiobook carrier = Audiobook()..bookKey = bookKey;
    health.packInto(carrier);
    await _db.patchAudiobook(
      bookKey,
      AudiobooksCompanion(
        healthKindRaw: Value(carrier.healthKindRaw),
        matchRatePct: Value(carrier.matchRatePct),
        healthMeasuredAt: Value(carrier.healthMeasuredAt),
        healthReason: Value(carrier.healthReason),
      ),
    );
  }

  static List<String> _audioPathsOf(AudiobookRow row) {
    final String? raw = row.audioPathsJson;
    if (raw == null) return const <String>[];
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  /// [propagateDeletion]（默认 false）：true 时记一条 `audiobook` sync 删除墓碑，供同步
  /// 发布到远端标记、其他设备逐条确认后也删（对应删除弹窗「同步删除」）。false（含消费
  /// 远端删除标记路径）只删本机，绝不回写墓碑造成循环。app 层按 DeleteScope 传入。
  Future<void> deleteAudiobook(
    String bookKey, {
    bool propagateDeletion = false,
  }) async {
    // deleteAudiobookByBookKey 内部已先删 audioCues 再删 audiobooks。
    await _db.deleteAudiobookByBookKey(bookKey);
    await AudiobookStorage.deletePersistDir(bookKey);
    if (propagateDeletion) {
      try {
        await _db.writeSyncDeletionTombstone(
            SyncTombstoneKind.audiobook.dbValue,
            bookKey,
            DateTime.now().millisecondsSinceEpoch);
      } catch (_) {
        // best-effort：记账失败不影响有声书已删。
      }
    }
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

  /// 调轴最后写入时刻（epoch 毫秒）pref 前缀。与 `audiobook_delay_<bookKey>` 配套，
  /// 供互联（LAN）调轴同步做「严格较新时间戳者胜」LWW（互联完整支持批次；与
  /// [_kPositionAtMsKeyPrefix] 同范式，键公式与 sync 侧 audiobookDelayAtPrefKey
  /// 逐字节一致）。无戳（旧数据）在 LWW 中输给任何带戳对端值。
  static const String _kDelayAtMsKeyPrefix = 'audiobook_delay_at_';
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

  /// 写调轴（毫秒）并同时盖更新时间戳（互联 LWW 用，与 [updatePositionMs] 同
  /// 纪律：值与时间戳是同一调轴的两个 pref，必须一起写，否则 LWW 无依据——本机
  /// 调整无戳恒 0，会永远输给对端旧戳、再也传不出去）。
  Future<void> updateDelayMs({
    required String bookKey,
    required int ms,
  }) async {
    await _db.setPrefTyped('$_kDelayMsKeyPrefix$bookKey', ms);
    await _db.setPrefTyped(
        '$_kDelayAtMsKeyPrefix$bookKey', DateTime.now().millisecondsSinceEpoch);
  }

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

  // 这里曾有一个 `_audiobookToCompanion(Audiobook)`：把整个模型摊成每列都是
  // `Value(...)` 的 companion 去做整行覆盖。它随 `saveAudiobook` 一起删除——
  // 只要这个函数还在，就总有人凭空造模型再写全行，把没碰的列清空（BUG-1678）。
}
