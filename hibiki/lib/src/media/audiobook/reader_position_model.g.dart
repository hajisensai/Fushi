// GENERATED CODE - DO NOT MODIFY BY HAND
// Hand-written for hibiki (build_runner 2.4.4 不兼容当前 Flutter/Dart).
// 照 srt_book_model.g.dart 模式精简：字段固定 4 个、索引只有 ttuBookId
// 唯一索引、无 link/embedded；只保留实际用到的 where/filter/sort/property
// 扩展。新增字段时记得 PropertySchema 顺序分配、estimateSize/serialize/
// deserialize/deserializeProp 四处同步加。

part of 'reader_position_model.dart';

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetReaderPositionCollection on Isar {
  IsarCollection<ReaderPosition> get readerPositions => this.collection();
}

const ReaderPositionSchema = CollectionSchema(
  name: r'ReaderPosition',
  id: 2761005929337993061,
  properties: {
    r'normCharOffset': PropertySchema(
      id: 0,
      name: r'normCharOffset',
      type: IsarType.long,
    ),
    r'sectionIndex': PropertySchema(
      id: 1,
      name: r'sectionIndex',
      type: IsarType.long,
    ),
    r'ttuBookId': PropertySchema(
      id: 2,
      name: r'ttuBookId',
      type: IsarType.long,
    ),
    r'updatedAt': PropertySchema(
      id: 3,
      name: r'updatedAt',
      type: IsarType.long,
    ),
  },
  estimateSize: _readerPositionEstimateSize,
  serialize: _readerPositionSerialize,
  deserialize: _readerPositionDeserialize,
  deserializeProp: _readerPositionDeserializeProp,
  idName: r'id',
  indexes: {
    r'ttuBookId': IndexSchema(
      id: -6268073740859223969,
      name: r'ttuBookId',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'ttuBookId',
          type: IndexType.value,
          caseSensitive: false,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _readerPositionGetId,
  getLinks: _readerPositionGetLinks,
  attach: _readerPositionAttach,
  version: '3.1.0+1',
);

int _readerPositionEstimateSize(
  ReaderPosition object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  // 4 个 long 字段，estimator 的 bytesCount 只要 offsets.last 起点就够
  return offsets.last;
}

void _readerPositionSerialize(
  ReaderPosition object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.normCharOffset);
  writer.writeLong(offsets[1], object.sectionIndex);
  writer.writeLong(offsets[2], object.ttuBookId);
  writer.writeLong(offsets[3], object.updatedAt);
}

ReaderPosition _readerPositionDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = ReaderPosition();
  object.id = id;
  object.normCharOffset = reader.readLong(offsets[0]);
  object.sectionIndex = reader.readLong(offsets[1]);
  object.ttuBookId = reader.readLong(offsets[2]);
  object.updatedAt = reader.readLong(offsets[3]);
  return object;
}

P _readerPositionDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readLong(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _readerPositionGetId(ReaderPosition object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _readerPositionGetLinks(ReaderPosition object) {
  return [];
}

void _readerPositionAttach(
    IsarCollection<dynamic> col, Id id, ReaderPosition object) {
  object.id = id;
}

extension ReaderPositionQueryWhereSort
    on QueryBuilder<ReaderPosition, ReaderPosition, QWhere> {
  QueryBuilder<ReaderPosition, ReaderPosition, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<ReaderPosition, ReaderPosition, QAfterWhere> anyTtuBookId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'ttuBookId'),
      );
    });
  }
}

extension ReaderPositionQueryWhere
    on QueryBuilder<ReaderPosition, ReaderPosition, QWhereClause> {
  QueryBuilder<ReaderPosition, ReaderPosition, QAfterWhereClause> idEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<ReaderPosition, ReaderPosition, QAfterWhereClause>
      ttuBookIdEqualTo(int ttuBookId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'ttuBookId',
        value: [ttuBookId],
      ));
    });
  }
}

extension ReaderPositionQueryFilter on QueryBuilder<ReaderPosition,
    ReaderPosition, QFilterCondition> {
  QueryBuilder<ReaderPosition, ReaderPosition, QAfterFilterCondition>
      ttuBookIdEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'ttuBookId',
        value: value,
      ));
    });
  }
}

extension ReaderPositionQueryObject on QueryBuilder<ReaderPosition,
    ReaderPosition, QFilterCondition> {}

extension ReaderPositionQueryLinks on QueryBuilder<ReaderPosition,
    ReaderPosition, QFilterCondition> {}

extension ReaderPositionQuerySortBy
    on QueryBuilder<ReaderPosition, ReaderPosition, QSortBy> {
  QueryBuilder<ReaderPosition, ReaderPosition, QAfterSortBy> sortByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.asc);
    });
  }

  QueryBuilder<ReaderPosition, ReaderPosition, QAfterSortBy>
      sortByUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.desc);
    });
  }
}

extension ReaderPositionQuerySortThenBy
    on QueryBuilder<ReaderPosition, ReaderPosition, QSortThenBy> {
  QueryBuilder<ReaderPosition, ReaderPosition, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<ReaderPosition, ReaderPosition, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }
}

extension ReaderPositionQueryWhereDistinct
    on QueryBuilder<ReaderPosition, ReaderPosition, QDistinct> {}

extension ReaderPositionQueryProperty
    on QueryBuilder<ReaderPosition, ReaderPosition, QQueryProperty> {
  QueryBuilder<ReaderPosition, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<ReaderPosition, int, QQueryOperations> ttuBookIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'ttuBookId');
    });
  }
}
