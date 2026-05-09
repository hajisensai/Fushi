import 'package:drift/drift.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';

/// 阅读位置持久化。
///
/// 参数名 `ttuBookId` 沿用旧列名保持数据库兼容，
/// 语义上等同于 `EpubBooks.id`（书的主键）。
class ReaderPositionRepository {
  const ReaderPositionRepository(this._db);

  final HibikiDatabase _db;

  Future<ReaderPosition?> findByTtuBookId(int ttuBookId) async {
    final row = await _db.getReaderPosition(ttuBookId);
    if (row == null) return null;
    return _rowToModel(row);
  }

  Future<void> save({
    required int ttuBookId,
    required int sectionIndex,
    required int normCharOffset,
    int? ttuCharOffset,
  }) async {
    final ReaderPositionRow? existing =
        ttuCharOffset == null ? await _db.getReaderPosition(ttuBookId) : null;
    final Value<int> ttuCharOffsetValue = ttuCharOffset != null
        ? Value(ttuCharOffset)
        : existing == null || existing.sectionIndex == sectionIndex
            ? const Value.absent()
            : const Value(-1);
    await _db.upsertReaderPosition(ReaderPositionsCompanion(
      ttuBookId: Value(ttuBookId),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      ttuCharOffset: ttuCharOffsetValue,
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
  }

  Future<void> delete(int ttuBookId) => _db.deleteReaderPosition(ttuBookId);

  static ReaderPosition _rowToModel(ReaderPositionRow r) {
    final pos = ReaderPosition();
    pos.id = r.id;
    pos.ttuBookId = r.ttuBookId;
    pos.sectionIndex = r.sectionIndex;
    pos.normCharOffset = r.normCharOffset;
    pos.ttuCharOffset = r.ttuCharOffset >= 0 ? r.ttuCharOffset : null;
    pos.updatedAt = r.updatedAt;
    return pos;
  }
}
