// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dictionary_entry.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetDictionaryEntryCollection on Isar {
  IsarCollection<DictionaryEntry> get dictionaryEntrys => this.collection();
}

const DictionaryEntrySchema = CollectionSchema(
  name: r'DictionaryEntry',
  id: 433168435156867289,
  properties: {
    r'dictionaryName': PropertySchema(
      id: 0,
      name: r'dictionaryName',
      type: IsarType.string,
    ),
    r'extra': PropertySchema(
      id: 1,
      name: r'extra',
      type: IsarType.string,
    ),
    r'meaning': PropertySchema(
      id: 2,
      name: r'meaning',
      type: IsarType.string,
    ),
    r'popularity': PropertySchema(
      id: 3,
      name: r'popularity',
      type: IsarType.double,
    ),
    r'reading': PropertySchema(
      id: 4,
      name: r'reading',
      type: IsarType.string,
    ),
    r'word': PropertySchema(
      id: 5,
      name: r'word',
      type: IsarType.string,
    ),
    r'wordLength': PropertySchema(
      id: 6,
      name: r'wordLength',
      type: IsarType.long,
    ),
  },
  estimateSize: _dictionaryEntryEstimateSize,
  serialize: _dictionaryEntrySerialize,
  deserialize: _dictionaryEntryDeserialize,
  deserializeProp: _dictionaryEntryDeserializeProp,
  idName: r'id',
  indexes: {
    r'dictionaryName': IndexSchema(
      id: 6941277455010515489,
      name: r'dictionaryName',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'dictionaryName',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'word': IndexSchema(
      id: -2031626334120420267,
      name: r'word',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'word',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
    r'reading': IndexSchema(
      id: -8872607090340677149,
      name: r'reading',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'reading',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
    r'popularity': IndexSchema(
      id: -817613675826504681,
      name: r'popularity',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'popularity',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
    r'wordLength': IndexSchema(
      id: -3871494524758824824,
      name: r'wordLength',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'wordLength',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _dictionaryEntryGetId,
  getLinks: _dictionaryEntryGetLinks,
  attach: _dictionaryEntryAttach,
  version: '3.1.0+1',
);

int _dictionaryEntryEstimateSize(
  DictionaryEntry object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.dictionaryName.length * 3;
  bytesCount += 3 + object.extra.length * 3;
  bytesCount += 3 + object.meaning.length * 3;
  bytesCount += 3 + object.reading.length * 3;
  bytesCount += 3 + object.word.length * 3;
  return bytesCount;
}

void _dictionaryEntrySerialize(
  DictionaryEntry object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.dictionaryName);
  writer.writeString(offsets[1], object.extra);
  writer.writeString(offsets[2], object.meaning);
  writer.writeDouble(offsets[3], object.popularity);
  writer.writeString(offsets[4], object.reading);
  writer.writeString(offsets[5], object.word);
  writer.writeLong(offsets[6], object.wordLength);
}

DictionaryEntry _dictionaryEntryDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = DictionaryEntry(
    dictionaryName: reader.readString(offsets[0]),
    extra: reader.readString(offsets[1]),
    id: id,
    meaning: reader.readString(offsets[2]),
    popularity: reader.readDouble(offsets[3]),
    reading: reader.readString(offsets[4]),
    word: reader.readString(offsets[5]),
  );
  return object;
}

P _dictionaryEntryDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readDouble(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    case 6:
      return (reader.readLong(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _dictionaryEntryGetId(DictionaryEntry object) {
  return object.id ?? Isar.autoIncrement;
}

List<IsarLinkBase<dynamic>> _dictionaryEntryGetLinks(DictionaryEntry object) {
  return [];
}

void _dictionaryEntryAttach(
    IsarCollection<dynamic> col, Id id, DictionaryEntry object) {
  object.id = id;
}

extension DictionaryEntryQueryWhereSort
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QWhere> {
  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhere> anyWord() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'word'),
      );
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhere> anyReading() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'reading'),
      );
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhere> anyPopularity() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'popularity'),
      );
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhere> anyWordLength() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'wordLength'),
      );
    });
  }
}

extension DictionaryEntryQueryWhere
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QWhereClause> {
  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause> idEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      idNotEqualTo(Id id) {
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

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause> idLessThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause> idBetween(
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

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      dictionaryNameEqualTo(String dictionaryName) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'dictionaryName',
        value: [dictionaryName],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      dictionaryNameNotEqualTo(String dictionaryName) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dictionaryName',
              lower: [],
              upper: [dictionaryName],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dictionaryName',
              lower: [dictionaryName],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dictionaryName',
              lower: [dictionaryName],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dictionaryName',
              lower: [],
              upper: [dictionaryName],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordEqualTo(String word) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'word',
        value: [word],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordNotEqualTo(String word) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'word',
              lower: [],
              upper: [word],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'word',
              lower: [word],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'word',
              lower: [word],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'word',
              lower: [],
              upper: [word],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordGreaterThan(
    String word, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'word',
        lower: [word],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordLessThan(
    String word, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'word',
        lower: [],
        upper: [word],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordBetween(
    String lowerWord,
    String upperWord, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'word',
        lower: [lowerWord],
        includeLower: includeLower,
        upper: [upperWord],
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordStartsWith(String wordPrefix) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'word',
        lower: [wordPrefix],
        upper: ['$wordPrefix\u{FFFFF}'],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      readingEqualTo(String reading) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'reading',
        value: [reading],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      readingNotEqualTo(String reading) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'reading',
              lower: [],
              upper: [reading],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'reading',
              lower: [reading],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'reading',
              lower: [reading],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'reading',
              lower: [],
              upper: [reading],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      readingGreaterThan(
    String reading, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'reading',
        lower: [reading],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      readingLessThan(
    String reading, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'reading',
        lower: [],
        upper: [reading],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      readingBetween(
    String lowerReading,
    String upperReading, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'reading',
        lower: [lowerReading],
        includeLower: includeLower,
        upper: [upperReading],
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      readingStartsWith(String readingPrefix) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'reading',
        lower: [readingPrefix],
        upper: ['$readingPrefix\u{FFFFF}'],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      popularityEqualTo(double popularity) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'popularity',
        value: [popularity],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      popularityGreaterThan(
    double popularity, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'popularity',
        lower: [popularity],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      popularityLessThan(
    double popularity, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'popularity',
        lower: [],
        upper: [popularity],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      popularityBetween(
    double lowerPopularity,
    double upperPopularity, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'popularity',
        lower: [lowerPopularity],
        includeLower: includeLower,
        upper: [upperPopularity],
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordLengthEqualTo(int wordLength) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'wordLength',
        value: [wordLength],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordLengthGreaterThan(
    int wordLength, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'wordLength',
        lower: [wordLength],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterWhereClause>
      wordLengthLessThan(
    int wordLength, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'wordLength',
        lower: [],
        upper: [wordLength],
        includeUpper: include,
      ));
    });
  }
}

extension DictionaryEntryQueryFilter
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QFilterCondition> {
  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      dictionaryNameEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'dictionaryName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      dictionaryNameStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'dictionaryName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      extraEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'extra',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      meaningEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'meaning',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      meaningContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'meaning',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      popularityEqualTo(
    double value, {
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'popularity',
        value: value,
        epsilon: epsilon,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      popularityGreaterThan(
    double value, {
    bool include = false,
    double epsilon = Query.epsilon,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'popularity',
        value: value,
        epsilon: epsilon,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      readingEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'reading',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      readingStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'reading',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      readingMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'reading',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      wordEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'word',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      wordStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'word',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      wordMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'word',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      wordLengthEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'wordLength',
        value: value,
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      idIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'id',
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      idIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'id',
      ));
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterFilterCondition>
      idEqualTo(Id? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }
}

extension DictionaryEntryQueryObject
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QFilterCondition> {}

extension DictionaryEntryQueryLinks
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QFilterCondition> {}

extension DictionaryEntryQuerySortBy
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QSortBy> {
  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      sortByDictionaryName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dictionaryName', Sort.asc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy> sortByWord() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'word', Sort.asc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      sortByReading() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'reading', Sort.asc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      sortByPopularity() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'popularity', Sort.asc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      sortByPopularityDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'popularity', Sort.desc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      sortByWordLength() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'wordLength', Sort.asc);
    });
  }
}

extension DictionaryEntryQuerySortThenBy
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QSortThenBy> {
  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      thenByPopularity() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'popularity', Sort.asc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      thenByPopularityDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'popularity', Sort.desc);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QAfterSortBy>
      thenByWordLength() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'wordLength', Sort.asc);
    });
  }
}

extension DictionaryEntryQueryWhereDistinct
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QDistinct> {
  QueryBuilder<DictionaryEntry, DictionaryEntry, QDistinct>
      distinctByDictionaryName({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dictionaryName',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QDistinct> distinctByWord(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'word', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QDistinct> distinctByReading(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'reading', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<DictionaryEntry, DictionaryEntry, QDistinct>
      distinctByPopularity() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'popularity');
    });
  }
}

extension DictionaryEntryQueryProperty
    on QueryBuilder<DictionaryEntry, DictionaryEntry, QQueryProperty> {
  QueryBuilder<DictionaryEntry, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<DictionaryEntry, String, QQueryOperations>
      dictionaryNameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dictionaryName');
    });
  }

  QueryBuilder<DictionaryEntry, String, QQueryOperations> wordProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'word');
    });
  }

  QueryBuilder<DictionaryEntry, String, QQueryOperations> readingProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'reading');
    });
  }

  QueryBuilder<DictionaryEntry, String, QQueryOperations> meaningProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'meaning');
    });
  }

  QueryBuilder<DictionaryEntry, String, QQueryOperations> extraProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'extra');
    });
  }

  QueryBuilder<DictionaryEntry, double, QQueryOperations> popularityProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'popularity');
    });
  }

  QueryBuilder<DictionaryEntry, int, QQueryOperations> wordLengthProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'wordLength');
    });
  }
}
