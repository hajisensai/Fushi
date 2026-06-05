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

  /// 回写整段播放列表 JSON（各集 positionMs 改变时持久化每集进度）。
  Future<void> updatePlaylistJson(String bookUid, String playlistJson) =>
      _db.updateVideoBookPlaylistJson(bookUid, playlistJson);

  /// 更新音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留。
  Future<void> updateDelayMs(String bookUid, int delayMs) =>
      _db.updateVideoBookDelayMs(bookUid, delayMs);

  /// 更新用户选中的字幕源（外挂存路径；内嵌存 `embedded:<n>`；关闭存 null）。
  Future<void> updateSubtitleSource(String bookUid, String? subtitleSource) =>
      _db.updateVideoBookSubtitleSource(bookUid, subtitleSource);

  /// 更新用户选中的音轨 id（libmpv `AudioTrack.id`；清除存 null）。
  Future<void> updateAudioTrackId(String bookUid, String? audioTrackId) =>
      _db.updateVideoBookAudioTrackId(bookUid, audioTrackId);

  /// 更新视频封面图绝对路径（书架/视频库长按菜单手动设置封面）。
  Future<void> updateCover(String bookUid, String coverPath) =>
      _db.updateVideoBookCover(bookUid, coverPath);

  /// 删除视频书（标签映射经 FK cascade 自动清理）。
  Future<void> deleteVideoBook(String bookUid) => _db.deleteVideoBook(bookUid);

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
