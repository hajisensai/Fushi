// GENERATED CODE - DO NOT MODIFY BY HAND
// Hand-written for hibiki (build_runner 不兼容当前 Flutter/Dart).
// 照 srt_book_model.g.dart / reader_position_model.g.dart 模式精简。

part of 'reading_statistic_model.dart';

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetReadingStatisticCollection on Isar {
  IsarCollection<ReadingStatistic> get readingStatistics => this.collection();
}

const ReadingStatisticSchema = CollectionSchema(
  name: r'ReadingStatistic',
  id: -85499983958001763,
  properties: {
    r'charactersRead': PropertySchema(
      id: 0,
      name: r'charactersRead',
      type: IsarType.long,
    ),
    r'dateKey': PropertySchema(
      id: 1,
      name: r'dateKey',
      type: IsarType.string,
    ),
    r'lastStatisticModified': PropertySchema(
      id: 2,
      name: r'lastStatisticModified',
      type: IsarType.long,
    ),
    r'readingTimeMs': PropertySchema(
      id: 3,
      name: r'readingTimeMs',
      type: IsarType.long,
    ),
    r'title': PropertySchema(
      id: 4,
      name: r'title',
      type: IsarType.string,
    ),
  },
  estimateSize: _readingStatisticEstimateSize,
  serialize: _readingStatisticSerialize,
  deserialize: _readingStatisticDeserialize,
  deserializeProp: _readingStatisticDeserializeProp,
  idName: r'id',
  indexes: {
    r'title_dateKey': IndexSchema(
      id: -4563906960120859923,
      name: r'title_dateKey',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'title',
          type: IndexType.hash,
          caseSensitive: true,
        ),
        IndexPropertySchema(
          name: r'dateKey',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _readingStatisticGetId,
  getLinks: _readingStatisticGetLinks,
  attach: _readingStatisticAttach,
  version: '3.1.0+1',
);

int _readingStatisticEstimateSize(
  ReadingStatistic object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.dateKey.length * 3;
  bytesCount += 3 + object.title.length * 3;
  return bytesCount;
}

void _readingStatisticSerialize(
  ReadingStatistic object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.charactersRead);
  writer.writeString(offsets[1], object.dateKey);
  writer.writeLong(offsets[2], object.lastStatisticModified);
  writer.writeLong(offsets[3], object.readingTimeMs);
  writer.writeString(offsets[4], object.title);
}

ReadingStatistic _readingStatisticDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = ReadingStatistic();
  object.id = id;
  object.charactersRead = reader.readLong(offsets[0]);
  object.dateKey = reader.readString(offsets[1]);
  object.lastStatisticModified = reader.readLong(offsets[2]);
  object.readingTimeMs = reader.readLong(offsets[3]);
  object.title = reader.readString(offsets[4]);
  return object;
}

P _readingStatisticDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readLong(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _readingStatisticGetId(ReadingStatistic object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _readingStatisticGetLinks(
    ReadingStatistic object) {
  return [];
}

void _readingStatisticAttach(
    IsarCollection<dynamic> col, Id id, ReadingStatistic object) {
  object.id = id;
}

extension ReadingStatisticQueryWhereSort
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QWhere> {
  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension ReadingStatisticQueryWhere
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QWhereClause> {
  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterWhereClause>
      titleEqualToAnyDateKey(String title) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'title_dateKey',
        value: [title],
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterWhereClause>
      titleDateKeyEqualTo(String title, String dateKey) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'title_dateKey',
        value: [title, dateKey],
      ));
    });
  }
}

extension ReadingStatisticQueryFilter
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QFilterCondition> {
  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      titleEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'title',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      dateKeyEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'dateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      dateKeyGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'dateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      dateKeyLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'dateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      dateKeyBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'dateKey',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterFilterCondition>
      charactersReadGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'charactersRead',
        value: value,
      ));
    });
  }
}

extension ReadingStatisticQueryObject
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QFilterCondition> {}

extension ReadingStatisticQueryLinks
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QFilterCondition> {}

extension ReadingStatisticQuerySortBy
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QSortBy> {
  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      sortByDateKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateKey', Sort.asc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      sortByDateKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateKey', Sort.desc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      sortByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      sortByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      sortByCharactersRead() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'charactersRead', Sort.asc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      sortByCharactersReadDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'charactersRead', Sort.desc);
    });
  }
}

extension ReadingStatisticQuerySortThenBy
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QSortThenBy> {
  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      thenByDateKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateKey', Sort.asc);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QAfterSortBy>
      thenByDateKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateKey', Sort.desc);
    });
  }
}

extension ReadingStatisticQueryWhereDistinct
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QDistinct> {
  QueryBuilder<ReadingStatistic, ReadingStatistic, QDistinct> distinctByTitle(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'title', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ReadingStatistic, ReadingStatistic, QDistinct>
      distinctByDateKey({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dateKey', caseSensitive: caseSensitive);
    });
  }
}

extension ReadingStatisticQueryProperty
    on QueryBuilder<ReadingStatistic, ReadingStatistic, QQueryProperty> {
  QueryBuilder<ReadingStatistic, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<ReadingStatistic, String, QQueryOperations> titleProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'title');
    });
  }

  QueryBuilder<ReadingStatistic, String, QQueryOperations> dateKeyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dateKey');
    });
  }

  QueryBuilder<ReadingStatistic, int, QQueryOperations>
      charactersReadProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'charactersRead');
    });
  }

  QueryBuilder<ReadingStatistic, int, QQueryOperations>
      readingTimeMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'readingTimeMs');
    });
  }
}
