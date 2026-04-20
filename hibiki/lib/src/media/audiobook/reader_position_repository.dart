import 'package:isar/isar.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';

/// [ReaderPosition] 的 Isar 访问层。
///
/// `ttuBookId` 是 `@Index(unique: true, replace: true)`，int value 索引
/// 不走 hash（跟 AudiobookRepository 里的 bookUid hash 索引 bug 无关），
/// 所以直接 `where().ttuBookIdEqualTo(...)` + put 就能 upsert，不用兜底。
class ReaderPositionRepository {
  const ReaderPositionRepository(this._isar);

  final Isar _isar;

  /// 同步读上次位置，没记录返回 null（交调用方决定用默认行为）。
  ReaderPosition? findByTtuBookId(int ttuBookId) {
    return _isar.readerPositions
        .where()
        .ttuBookIdEqualTo(ttuBookId)
        .findFirstSync();
  }

  /// 写位置。唯一索引 `replace: true` 保证按 ttuBookId 覆盖——同一本书只会
  /// 有一条记录。
  Future<void> save({
    required int ttuBookId,
    required int sectionIndex,
    required int normCharOffset,
  }) async {
    final ReaderPosition pos = ReaderPosition()
      ..ttuBookId = ttuBookId
      ..sectionIndex = sectionIndex
      ..normCharOffset = normCharOffset
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _isar.writeTxn(() async {
      await _isar.readerPositions.put(pos);
    });
  }

  /// 删位置（用不上的兜底 API —— 重装 / 清数据都走系统级，不走这里）。
  Future<void> delete(int ttuBookId) async {
    await _isar.writeTxn(() async {
      final List<int> ids = await _isar.readerPositions
          .where()
          .ttuBookIdEqualTo(ttuBookId)
          .idProperty()
          .findAll();
      await _isar.readerPositions.deleteAll(ids);
    });
  }
}
