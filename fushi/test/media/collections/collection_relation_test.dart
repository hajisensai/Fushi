import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_relation.dart';

void main() {
  test('合集关系 wire 值可稳定往返且未知值向前兼容', () {
    for (final CollectionRelationType type in CollectionRelationType.values) {
      expect(CollectionRelationType.fromWire(type.wire), type);
    }
    expect(CollectionRelationType.sideStory.wire, 'side_story');
    expect(
      CollectionRelationType.fromWire('future_kind'),
      CollectionRelationType.other,
    );
  });

  test('本地关系边不携带外部源身份', () {
    final relation = createLocalCollectionRelation(
      collectionId: 1,
      type: CollectionRelationType.sequel,
      targetCollectionId: 2,
      title: '第二季',
      sortIndex: 0,
    );

    expect(relation.relationType.value, 'sequel');
    expect(relation.source.value, 'local');
    expect(relation.subjectId.value, 'collection:2');
    expect(relation.targetCollectionId.value, 2);
  });
}
