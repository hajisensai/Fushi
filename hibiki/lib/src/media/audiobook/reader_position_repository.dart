import 'package:drift/drift.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';

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
    await _db.upsertReaderPosition(ReaderPositionsCompanion(
      ttuBookId: Value(ttuBookId),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      ttuCharOffset:
          ttuCharOffset != null ? Value(ttuCharOffset) : const Value.absent(),
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
