import 'package:drift/drift.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'reader_position_model.dart';

/// 阅读位置持久化。键为书的 `bookKey`（EpubBooks 主键 = sanitize 后的标题）。
class ReaderPositionRepository {
  const ReaderPositionRepository(this._db);

  final HibikiDatabase _db;

  Future<ReaderPosition?> findByBookKey(String bookKey) async {
    final row = await _db.getReaderPosition(bookKey);
    if (row == null) return null;
    return _rowToModel(row);
  }

  Future<void> save({
    required String bookKey,
    required int sectionIndex,
    required int normCharOffset,
    int? charOffset,
  }) async {
    final ReaderPositionRow? existing =
        charOffset == null ? await _db.getReaderPosition(bookKey) : null;
    final Value<int> charOffsetValue = charOffset != null
        ? Value(charOffset)
        : existing == null || existing.sectionIndex == sectionIndex
            ? const Value.absent()
            : const Value(-1);
    await _db.upsertReaderPosition(ReaderPositionsCompanion(
      bookKey: Value(bookKey),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      charOffset: charOffsetValue,
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
  }

  Future<void> delete(String bookKey) => _db.deleteReaderPosition(bookKey);

  static ReaderPosition _rowToModel(ReaderPositionRow r) {
    final pos = ReaderPosition();
    pos.id = r.id;
    pos.bookKey = r.bookKey;
    pos.sectionIndex = r.sectionIndex;
    pos.normCharOffset = r.normCharOffset;
    pos.charOffset = r.charOffset >= 0 ? r.charOffset : null;
    pos.updatedAt = r.updatedAt;
    return pos;
  }
}
