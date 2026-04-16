// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'srt_book_model.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

// ──────────────────────────────────────────────────────────────────────────────
// SrtBook
// ──────────────────────────────────────────────────────────────────────────────

extension GetSrtBookCollection on Isar {
  IsarCollection<SrtBook> get srtBooks => this.collection();
}

const SrtBookSchema = CollectionSchema(
  name: r'SrtBook',
  id: -1096507249270084801,
  properties: {
    r'audioPaths': PropertySchema(
      id: 0,
      name: r'audioPaths',
      type: IsarType.stringList,
    ),
    r'audioRoot': PropertySchema(
      id: 1,
      name: r'audioRoot',
      type: IsarType.string,
    ),
    r'author': PropertySchema(
      id: 2,
      name: r'author',
      type: IsarType.string,
    ),
    r'coverPath': PropertySchema(
      id: 3,
      name: r'coverPath',
      type: IsarType.string,
    ),
    r'importedAt': PropertySchema(
      id: 4,
      name: r'importedAt',
      type: IsarType.long,
    ),
    r'srtPath': PropertySchema(
      id: 5,
      name: r'srtPath',
      type: IsarType.string,
    ),
    r'title': PropertySchema(
      id: 6,
      name: r'title',
      type: IsarType.string,
    ),
    r'ttuBookId': PropertySchema(
      id: 7,
      name: r'ttuBookId',
      type: IsarType.long,
    ),
    r'uid': PropertySchema(
      id: 8,
      name: r'uid',
      type: IsarType.string,
    ),
  },
  estimateSize: _srtBookEstimateSize,
  serialize: _srtBookSerialize,
  deserialize: _srtBookDeserialize,
  deserializeProp: _srtBookDeserializeProp,
  idName: r'id',
  indexes: {
    r'uid': IndexSchema(
      id: 8193695471701937315,
      name: r'uid',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'uid',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _srtBookGetId,
  getLinks: _srtBookGetLinks,
  attach: _srtBookAttach,
  version: '3.1.0+1',
);

int _srtBookEstimateSize(
  SrtBook object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.audioRoot;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.author;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.coverPath;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.srtPath.length * 3;
  bytesCount += 3 + object.title.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  {
    final list = object.audioPaths;
    if (list != null) {
      bytesCount += 3 + list.length * 3;
      for (var i = 0; i < list.length; i++) {
        bytesCount += list[i].length * 3;
      }
    }
  }
  return bytesCount;
}

void _srtBookSerialize(
  SrtBook object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeStringList(offsets[0], object.audioPaths);
  writer.writeString(offsets[1], object.audioRoot);
  writer.writeString(offsets[2], object.author);
  writer.writeString(offsets[3], object.coverPath);
  writer.writeLong(offsets[4], object.importedAt);
  writer.writeString(offsets[5], object.srtPath);
  writer.writeString(offsets[6], object.title);
  writer.writeLong(offsets[7], object.ttuBookId);
  writer.writeString(offsets[8], object.uid);
}

SrtBook _srtBookDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = SrtBook();
  object.id = id;
  object.audioPaths = reader.readStringList(offsets[0]);
  object.audioRoot = reader.readStringOrNull(offsets[1]);
  object.author = reader.readStringOrNull(offsets[2]);
  object.coverPath = reader.readStringOrNull(offsets[3]);
  object.importedAt = reader.readLong(offsets[4]);
  object.srtPath = reader.readString(offsets[5]);
  object.title = reader.readString(offsets[6]);
  object.ttuBookId = reader.readLongOrNull(offsets[7]) ?? 0;
  object.uid = reader.readString(offsets[8]);
  return object;
}

P _srtBookDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readStringList(offset)) as P;
    case 1:
      return (reader.readStringOrNull(offset)) as P;
    case 2:
      return (reader.readStringOrNull(offset)) as P;
    case 3:
      return (reader.readStringOrNull(offset)) as P;
    case 4:
      return (reader.readLong(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readLongOrNull(offset) ?? 0) as P;
    case 8:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _srtBookGetId(SrtBook object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _srtBookGetLinks(SrtBook object) {
  return [];
}

void _srtBookAttach(IsarCollection<dynamic> col, Id id, SrtBook object) {
  object.id = id;
}

extension SrtBookQueryWhereSort
    on QueryBuilder<SrtBook, SrtBook, QWhere> {
  QueryBuilder<SrtBook, SrtBook, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension SrtBookQueryWhere
    on QueryBuilder<SrtBook, SrtBook, QWhereClause> {
  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> idGreaterThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> idLessThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> uidEqualTo(String uid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'uid',
        value: [uid],
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterWhereClause> uidNotEqualTo(
      String uid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uid',
              lower: [],
              upper: [uid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uid',
              lower: [uid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uid',
              lower: [uid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'uid',
              lower: [],
              upper: [uid],
              includeUpper: false,
            ));
      }
    });
  }
}

extension SrtBookQueryFilter
    on QueryBuilder<SrtBook, SrtBook, QFilterCondition> {
  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> audioRootEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'audioRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> authorIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'author',
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> authorIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'author',
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> authorEqualTo(
      String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'author',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> coverPathIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'coverPath',
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> coverPathIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'coverPath',
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> importedAtEqualTo(
      int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'importedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> srtPathEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'srtPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> titleEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'title',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterFilterCondition> uidEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }
}

extension SrtBookQueryObject
    on QueryBuilder<SrtBook, SrtBook, QFilterCondition> {}

extension SrtBookQueryLinks
    on QueryBuilder<SrtBook, SrtBook, QFilterCondition> {}

extension SrtBookQuerySortBy on QueryBuilder<SrtBook, SrtBook, QSortBy> {
  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByAudioRoot() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByAudioRootDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByAuthor() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'author', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByAuthorDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'author', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByCoverPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'coverPath', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByCoverPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'coverPath', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByImportedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'importedAt', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByImportedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'importedAt', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortBySrtPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'srtPath', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortBySrtPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'srtPath', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> sortByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }
}

extension SrtBookQuerySortThenBy
    on QueryBuilder<SrtBook, SrtBook, QSortThenBy> {
  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByAudioRoot() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByAudioRootDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByAuthor() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'author', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByAuthorDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'author', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByCoverPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'coverPath', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByCoverPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'coverPath', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByImportedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'importedAt', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByImportedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'importedAt', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenBySrtPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'srtPath', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenBySrtPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'srtPath', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }
}

extension SrtBookQueryWhereDistinct
    on QueryBuilder<SrtBook, SrtBook, QDistinct> {
  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctByAudioRoot(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'audioRoot', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctByAuthor(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'author', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctByCoverPath(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'coverPath', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctByImportedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'importedAt');
    });
  }

  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctBySrtPath(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'srtPath', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctByTitle(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'title', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SrtBook, SrtBook, QDistinct> distinctByUid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uid', caseSensitive: caseSensitive);
    });
  }
}

extension SrtBookQueryProperty
    on QueryBuilder<SrtBook, SrtBook, QQueryProperty> {
  QueryBuilder<SrtBook, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<SrtBook, String?, QQueryOperations> audioRootProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'audioRoot');
    });
  }

  QueryBuilder<SrtBook, String?, QQueryOperations> authorProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'author');
    });
  }

  QueryBuilder<SrtBook, String?, QQueryOperations> coverPathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'coverPath');
    });
  }

  QueryBuilder<SrtBook, int, QQueryOperations> importedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'importedAt');
    });
  }

  QueryBuilder<SrtBook, String, QQueryOperations> srtPathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'srtPath');
    });
  }

  QueryBuilder<SrtBook, String, QQueryOperations> titleProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'title');
    });
  }

  QueryBuilder<SrtBook, String, QQueryOperations> uidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uid');
    });
  }
}
