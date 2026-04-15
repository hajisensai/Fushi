import 'package:isar/isar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';

/// 独立 SRT 有声书数据访问层。
///
/// [SrtBook] 元数据和对应 [AudioCue] 均存放在同一 Isar 实例。
class SrtBookRepository {
  const SrtBookRepository(this._isar);

  final Isar _isar;

  /// 列出所有 SRT 书籍（按导入时间倒序）。
  List<SrtBook> listAll() {
    return _isar.srtBooks
        .where()
        .sortByImportedAtDesc()
        .findAllSync();
  }

  /// 按 [uid] 查找书籍，未找到返回 null。
  SrtBook? findByUid(String uid) {
    return _isar.srtBooks.filter().uidEqualTo(uid).findFirstSync();
  }

  /// 保存（插入或更新）一本 SRT 书籍。
  Future<void> save(SrtBook book) async {
    await _isar.writeTxn(() async {
      await _isar.srtBooks.put(book);
    });
  }

  /// 删除指定书籍及其所有 [AudioCue]。
  Future<void> delete(String uid) async {
    // Query outside writeTxn to avoid using sync reads inside async transactions.
    final SrtBook? existing =
        _isar.srtBooks.filter().uidEqualTo(uid).findFirstSync();
    await _isar.writeTxn(() async {
      if (existing != null) {
        await _isar.srtBooks.delete(existing.id);
      }
      final List<int> cueIds = await _isar.audioCues
          .filter()
          .bookUidEqualTo(uid)
          .idProperty()
          .findAll();
      await _isar.audioCues.deleteAll(cueIds);
    });
  }

  /// 查询指定书籍的所有 [AudioCue]（已按 sentenceIndex 排序）。
  List<AudioCue> cuesFor(String uid) {
    return _isar.audioCues
        .filter()
        .bookUidEqualTo(uid)
        .and()
        .chapterHrefEqualTo(SrtParser.defaultChapter)
        .sortBySentenceIndex()
        .findAllSync();
  }

  /// 批量写入 [AudioCue]（先清除同书旧数据）。
  Future<void> saveCues({
    required String uid,
    required List<AudioCue> cues,
  }) async {
    await _isar.writeTxn(() async {
      final List<int> oldIds = await _isar.audioCues
          .filter()
          .bookUidEqualTo(uid)
          .idProperty()
          .findAll();
      await _isar.audioCues.deleteAll(oldIds);
      await _isar.audioCues.putAll(cues);
    });
  }
}
