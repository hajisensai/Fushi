import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

/// 合集关系类型。落库 wire 值与 `collection_relations.relation_type` 一一对应。
enum CollectionRelationType {
  prequel('prequel'),
  sequel('sequel'),
  sideStory('side_story'),
  movie('movie'),
  spinOff('spin_off'),
  other('other');

  const CollectionRelationType(this.wire);

  /// 固定的小写下划线落库值。
  final String wire;

  /// 从历史或未来版本的落库值还原；未知值安全归为 [other]。
  static CollectionRelationType fromWire(String wire) {
    for (final CollectionRelationType type in values) {
      if (type.wire == wire) return type;
    }
    return CollectionRelationType.other;
  }
}

/// 构造本地合集关系边，不携带任何外部元数据源身份。
CollectionRelationsCompanion createLocalCollectionRelation({
  required int collectionId,
  required CollectionRelationType type,
  required int targetCollectionId,
  required String title,
  required int sortIndex,
}) {
  return CollectionRelationsCompanion.insert(
    collectionId: collectionId,
    relationType: type.wire,
    sortIndex: Value<int>(sortIndex),
    targetCollectionId: Value<int?>(targetCollectionId),
    source: 'local',
    subjectId: 'collection:$targetCollectionId',
    title: title,
  );
}
