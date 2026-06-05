import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// VideoBooks 仓库：视频元数据 + 进度；字幕 cue 复用 audioCues 表。
class VideoBookRepository {
  const VideoBookRepository(this._db);

  final HibikiDatabase _db;

  Future<void> saveVideoBook(VideoBooksCompanion book) =>
      _db.upsertVideoBook(book);

  Future<VideoBookRow?> getByBookUid(String bookUid) =>
      _db.getVideoBookByBookUid(bookUid);

  Future<List<VideoBookRow>> listAll() => _db.allVideoBooks();

  Future<void> updatePosition(String bookUid, int positionMs) =>
      _db.updateVideoBookPosition(bookUid, positionMs);

  /// 更新播放列表当前集索引（多集导航切集后持久化）。
  Future<void> updateCurrentEpisode(String bookUid, int episodeIndex) =>
      _db.updateVideoBookEpisode(bookUid, episodeIndex);

  /// 更新用户选中的字幕源（外挂存路径；内嵌存 `embedded:<n>`；关闭存 null）。
  Future<void> updateSubtitleSource(String bookUid, String? subtitleSource) =>
      _db.updateVideoBookSubtitleSource(bookUid, subtitleSource);

  Future<void> saveCues({
    required String bookUid,
    required List<AudioCue> cues,
  }) =>
      _db.replaceCuesForBook(bookUid, cues.map(AudioCue.toCompanion).toList());

  Future<List<AudioCue>> loadCues(String bookUid) async {
    final List<AudioCueRow> rows = await _db.getCuesForBook(bookUid);
    return rows.map(AudioCue.fromRow).toList();
  }
}
