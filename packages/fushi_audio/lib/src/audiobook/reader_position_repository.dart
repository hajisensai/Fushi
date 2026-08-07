import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
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
    // TODO-1292 / BUG（退出图1重进图2）：char_offset（精确锚）与 norm_char_offset（分数）
    // 是同一位置的两套坐标，恢复时精确锚优先（reader shell 在 initialCharOffset>=0 时走
    // restoreToCharOffset）。此前同 section 传 null（WebView 当帧算不出精确偏移：竖排/ruby
    // caret 失败、或有声书 cue 派生位置恒无精确偏移）一律 Value.absent 保留旧精确锚，却照常
    // 更新分数——于是滚动/播放推进了 norm_char_offset，精确锚仍停在上次能测到的旧位置。恢复
    // 优先精确锚 → 落到旧位置（图2），而不是退出时的当前位置（图1）。
    //
    // 不变量修正：精确锚绝不能比分数陈旧。同 section 无新精确锚时，仅当位置**未移动**
    // （norm_char_offset 不变，即当帧只是测不到、位置没变的瞬态）才保留旧锚；一旦分数变化
    // 说明位置真的推进了但没有对应的新精确锚 → 旧锚已陈旧，置 -1 失效，恢复回退到（始终最新的）
    // 分数。跨 section 照旧失效。（瞬态 reflow 归零由上游 stableProgressInvocation 的
    // _reanchorPending 门控与 _syncPositionFromWebViewProgress 的 transientZero 守卫拦在落库前，
    // 不会以「分数归零 + 无精确锚」的形式到达这里。）
    final Value<int> charOffsetValue;
    if (charOffset != null) {
      charOffsetValue = Value(charOffset);
    } else if (existing == null || existing.sectionIndex != sectionIndex) {
      charOffsetValue = const Value(-1);
    } else if (existing.normCharOffset != normCharOffset) {
      charOffsetValue = const Value(-1);
    } else {
      charOffsetValue = const Value.absent();
    }
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
