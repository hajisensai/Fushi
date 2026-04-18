import 'package:isar/isar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

/// 有声书数据访问层，封装所有 Isar 查询。
class AudiobookRepository {
  const AudiobookRepository(this._isar);

  final Isar _isar;

  /// 按书的 uniqueKey 查找挂载的 [Audiobook]，未找到返回 null。
  Audiobook? findByBookUid(String bookUid) {
    return _isar.audiobooks.filter().bookUidEqualTo(bookUid).findFirstSync();
  }

  /// 查询指定书+章节的所有 [AudioCue]（已按 sentenceIndex 排序）。
  List<AudioCue> cuesForChapter({
    required String bookUid,
    required String chapterHref,
  }) {
    return _isar.audioCues
        .filter()
        .bookUidEqualTo(bookUid)
        .and()
        .chapterHrefEqualTo(chapterHref)
        .sortBySentenceIndex()
        .findAllSync();
  }

  /// 查询指定书的所有 [AudioCue]，跨章节汇总。
  ///
  /// Sasayaki 路径下 cue 的位置信息编码在 textFragmentId 上（sectionIndex +
  /// normChar 偏移），与原始 chapterHref 无关，需要不分章节地取全部 cue 供
  /// 音频控制器跨章节追踪。
  List<AudioCue> cuesForBook(String bookUid) {
    return _isar.audioCues
        .filter()
        .bookUidEqualTo(bookUid)
        .sortBySentenceIndex()
        .findAllSync();
  }

  /// 查找指定书+章节+句序对应的 [AudioCue]，未找到返回 null。
  AudioCue? findCue({
    required String bookUid,
    required String chapterHref,
    required int sentenceIndex,
  }) {
    return _isar.audioCues
        .filter()
        .bookUidEqualTo(bookUid)
        .and()
        .chapterHrefEqualTo(chapterHref)
        .and()
        .sentenceIndexEqualTo(sentenceIndex)
        .findFirstSync();
  }

  /// 批量写入 [AudioCue] 列表（先清除同书同章节的旧数据）。
  Future<void> saveCues({
    required String bookUid,
    required String chapterHref,
    required List<AudioCue> cues,
  }) async {
    await _isar.writeTxn(() async {
      // 删除旧数据
      final List<int> oldIds = await _isar.audioCues
          .filter()
          .bookUidEqualTo(bookUid)
          .and()
          .chapterHrefEqualTo(chapterHref)
          .idProperty()
          .findAll();
      await _isar.audioCues.deleteAll(oldIds);
      // 写入新数据
      await _isar.audioCues.putAll(cues);
    });
  }

  /// 保存 [Audiobook] 元数据。
  Future<void> saveAudiobook(Audiobook audiobook) async {
    await _isar.writeTxn(() async {
      await _isar.audiobooks.put(audiobook);
    });
  }

  /// 删除指定书的所有有声书数据（元数据 + 所有 cue）。
  Future<void> deleteAudiobook(String bookUid) async {
    await _isar.writeTxn(() async {
      final Audiobook? existing = await _isar.audiobooks
          .filter()
          .bookUidEqualTo(bookUid)
          .findFirst();
      if (existing != null) {
        await _isar.audiobooks.delete(existing.id);
      }
      final List<int> cueIds = await _isar.audioCues
          .filter()
          .bookUidEqualTo(bookUid)
          .idProperty()
          .findAll();
      await _isar.audioCues.deleteAll(cueIds);
    });
  }
}
