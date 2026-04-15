// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'audiobook_model.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

// ──────────────────────────────────────────────────────────────────────────────
// Audiobook
// ──────────────────────────────────────────────────────────────────────────────

extension GetAudiobookCollection on Isar {
  IsarCollection<Audiobook> get audiobooks => this.collection();
}

const AudiobookSchema = CollectionSchema(
  name: r'Audiobook',
  id: 7732003324708922976,
  properties: {
    r'alignmentFormat': PropertySchema(
      id: 0,
      name: r'alignmentFormat',
      type: IsarType.string,
    ),
    r'alignmentPath': PropertySchema(
      id: 1,
      name: r'alignmentPath',
      type: IsarType.string,
    ),
    r'audioRoot': PropertySchema(
      id: 2,
      name: r'audioRoot',
      type: IsarType.string,
    ),
    r'bookUid': PropertySchema(
      id: 3,
      name: r'bookUid',
      type: IsarType.string,
    ),
  },
  estimateSize: _audiobookEstimateSize,
  serialize: _audiobookSerialize,
  deserialize: _audiobookDeserialize,
  deserializeProp: _audiobookDeserializeProp,
  idName: r'id',
  indexes: {
    r'bookUid': IndexSchema(
      id: 1847233275350761740,
      name: r'bookUid',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'bookUid',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _audiobookGetId,
  getLinks: _audiobookGetLinks,
  attach: _audiobookAttach,
  version: '3.1.0+1',
);

int _audiobookEstimateSize(
  Audiobook object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.alignmentFormat.length * 3;
  bytesCount += 3 + object.alignmentPath.length * 3;
  bytesCount += 3 + object.audioRoot.length * 3;
  bytesCount += 3 + object.bookUid.length * 3;
  return bytesCount;
}

void _audiobookSerialize(
  Audiobook object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.alignmentFormat);
  writer.writeString(offsets[1], object.alignmentPath);
  writer.writeString(offsets[2], object.audioRoot);
  writer.writeString(offsets[3], object.bookUid);
}

Audiobook _audiobookDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = Audiobook();
  object.id = id;
  object.alignmentFormat = reader.readString(offsets[0]);
  object.alignmentPath = reader.readString(offsets[1]);
  object.audioRoot = reader.readString(offsets[2]);
  object.bookUid = reader.readString(offsets[3]);
  return object;
}

P _audiobookDeserializeProp<P>(
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
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _audiobookGetId(Audiobook object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _audiobookGetLinks(Audiobook object) {
  return [];
}

void _audiobookAttach(
    IsarCollection<dynamic> col, Id id, Audiobook object) {
  object.id = id;
}

extension AudiobookQueryWhereSort
    on QueryBuilder<Audiobook, Audiobook, QWhere> {
  QueryBuilder<Audiobook, Audiobook, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension AudiobookQueryWhere
    on QueryBuilder<Audiobook, Audiobook, QWhereClause> {
  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> idNotEqualTo(Id id) {
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

  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> idGreaterThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> idLessThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> idBetween(
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

  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> bookUidEqualTo(
      String bookUid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'bookUid',
        value: [bookUid],
      ));
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterWhereClause> bookUidNotEqualTo(
      String bookUid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [],
              upper: [bookUid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [bookUid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [bookUid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [],
              upper: [bookUid],
              includeUpper: false,
            ));
      }
    });
  }
}

extension AudiobookQueryFilter
    on QueryBuilder<Audiobook, Audiobook, QFilterCondition> {
  QueryBuilder<Audiobook, Audiobook, QAfterFilterCondition>
      alignmentFormatEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'alignmentFormat',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterFilterCondition>
      alignmentPathEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'alignmentPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterFilterCondition> audioRootEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'audioRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterFilterCondition> bookUidEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'bookUid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterFilterCondition> idEqualTo(
      Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }
}

extension AudiobookQueryObject
    on QueryBuilder<Audiobook, Audiobook, QFilterCondition> {}

extension AudiobookQueryLinks
    on QueryBuilder<Audiobook, Audiobook, QFilterCondition> {}

extension AudiobookQuerySortBy on QueryBuilder<Audiobook, Audiobook, QSortBy> {
  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByAlignmentFormat() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentFormat', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy>
      sortByAlignmentFormatDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentFormat', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByAlignmentPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentPath', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByAlignmentPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentPath', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByAudioRoot() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByAudioRootDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByBookUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> sortByBookUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.desc);
    });
  }
}

extension AudiobookQuerySortThenBy
    on QueryBuilder<Audiobook, Audiobook, QSortThenBy> {
  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByAlignmentFormat() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentFormat', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy>
      thenByAlignmentFormatDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentFormat', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByAlignmentPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentPath', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByAlignmentPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'alignmentPath', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByAudioRoot() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByAudioRootDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioRoot', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByBookUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByBookUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.desc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }
}

extension AudiobookQueryWhereDistinct
    on QueryBuilder<Audiobook, Audiobook, QDistinct> {
  QueryBuilder<Audiobook, Audiobook, QDistinct> distinctByAlignmentFormat(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'alignmentFormat',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QDistinct> distinctByAlignmentPath(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'alignmentPath',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QDistinct> distinctByAudioRoot(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'audioRoot', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<Audiobook, Audiobook, QDistinct> distinctByBookUid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bookUid', caseSensitive: caseSensitive);
    });
  }
}

extension AudiobookQueryProperty
    on QueryBuilder<Audiobook, Audiobook, QQueryProperty> {
  QueryBuilder<Audiobook, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<Audiobook, String, QQueryOperations>
      alignmentFormatProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'alignmentFormat');
    });
  }

  QueryBuilder<Audiobook, String, QQueryOperations> alignmentPathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'alignmentPath');
    });
  }

  QueryBuilder<Audiobook, String, QQueryOperations> audioRootProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'audioRoot');
    });
  }

  QueryBuilder<Audiobook, String, QQueryOperations> bookUidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bookUid');
    });
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// AudioCue
// ──────────────────────────────────────────────────────────────────────────────

extension GetAudioCueCollection on Isar {
  IsarCollection<AudioCue> get audioCues => this.collection();
}

const AudioCueSchema = CollectionSchema(
  name: r'AudioCue',
  id: -1488682833208165829,
  properties: {
    r'audioFileIndex': PropertySchema(
      id: 0,
      name: r'audioFileIndex',
      type: IsarType.long,
    ),
    r'bookUid': PropertySchema(
      id: 1,
      name: r'bookUid',
      type: IsarType.string,
    ),
    r'chapterHref': PropertySchema(
      id: 2,
      name: r'chapterHref',
      type: IsarType.string,
    ),
    r'endMs': PropertySchema(
      id: 3,
      name: r'endMs',
      type: IsarType.long,
    ),
    r'sentenceIndex': PropertySchema(
      id: 4,
      name: r'sentenceIndex',
      type: IsarType.long,
    ),
    r'startMs': PropertySchema(
      id: 5,
      name: r'startMs',
      type: IsarType.long,
    ),
    r'text': PropertySchema(
      id: 6,
      name: r'text',
      type: IsarType.string,
    ),
    r'textFragmentId': PropertySchema(
      id: 7,
      name: r'textFragmentId',
      type: IsarType.string,
    ),
  },
  estimateSize: _audioCueEstimateSize,
  serialize: _audioCueSerialize,
  deserialize: _audioCueDeserialize,
  deserializeProp: _audioCueDeserializeProp,
  idName: r'id',
  indexes: {
    r'bookUid': IndexSchema(
      id: 1847233275350761740,
      name: r'bookUid',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'bookUid',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'chapterHref': IndexSchema(
      id: -3374474236128072918,
      name: r'chapterHref',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'chapterHref',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},
  getId: _audioCueGetId,
  getLinks: _audioCueGetLinks,
  attach: _audioCueAttach,
  version: '3.1.0+1',
);

int _audioCueEstimateSize(
  AudioCue object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.bookUid.length * 3;
  bytesCount += 3 + object.chapterHref.length * 3;
  bytesCount += 3 + object.text.length * 3;
  bytesCount += 3 + object.textFragmentId.length * 3;
  return bytesCount;
}

void _audioCueSerialize(
  AudioCue object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.audioFileIndex);
  writer.writeString(offsets[1], object.bookUid);
  writer.writeString(offsets[2], object.chapterHref);
  writer.writeLong(offsets[3], object.endMs);
  writer.writeLong(offsets[4], object.sentenceIndex);
  writer.writeLong(offsets[5], object.startMs);
  writer.writeString(offsets[6], object.text);
  writer.writeString(offsets[7], object.textFragmentId);
}

AudioCue _audioCueDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = AudioCue();
  object.id = id;
  object.audioFileIndex = reader.readLong(offsets[0]);
  object.bookUid = reader.readString(offsets[1]);
  object.chapterHref = reader.readString(offsets[2]);
  object.endMs = reader.readLong(offsets[3]);
  object.sentenceIndex = reader.readLong(offsets[4]);
  object.startMs = reader.readLong(offsets[5]);
  object.text = reader.readString(offsets[6]);
  object.textFragmentId = reader.readString(offsets[7]);
  return object;
}

P _audioCueDeserializeProp<P>(
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
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readLong(offset)) as P;
    case 5:
      return (reader.readLong(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _audioCueGetId(AudioCue object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _audioCueGetLinks(AudioCue object) {
  return [];
}

void _audioCueAttach(IsarCollection<dynamic> col, Id id, AudioCue object) {
  object.id = id;
}

extension AudioCueQueryWhereSort
    on QueryBuilder<AudioCue, AudioCue, QWhere> {
  QueryBuilder<AudioCue, AudioCue, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension AudioCueQueryWhere
    on QueryBuilder<AudioCue, AudioCue, QWhereClause> {
  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> idNotEqualTo(Id id) {
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

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> idGreaterThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> idLessThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> idBetween(
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

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> bookUidEqualTo(
      String bookUid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'bookUid',
        value: [bookUid],
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> bookUidNotEqualTo(
      String bookUid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [],
              upper: [bookUid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [bookUid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [bookUid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'bookUid',
              lower: [],
              upper: [bookUid],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> chapterHrefEqualTo(
      String chapterHref) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'chapterHref',
        value: [chapterHref],
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterWhereClause> chapterHrefNotEqualTo(
      String chapterHref) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'chapterHref',
              lower: [],
              upper: [chapterHref],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'chapterHref',
              lower: [chapterHref],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'chapterHref',
              lower: [chapterHref],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'chapterHref',
              lower: [],
              upper: [chapterHref],
              includeUpper: false,
            ));
      }
    });
  }
}

extension AudioCueQueryFilter
    on QueryBuilder<AudioCue, AudioCue, QFilterCondition> {
  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition>
      audioFileIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'audioFileIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition>
      audioFileIndexGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'audioFileIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition>
      audioFileIndexLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'audioFileIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition>
      audioFileIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'audioFileIndex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition> bookUidEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'bookUid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition> chapterHrefEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'chapterHref',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition> endMsEqualTo(
      int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'endMs',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition> idEqualTo(
      Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition>
      sentenceIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'sentenceIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition> startMsEqualTo(
      int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'startMs',
        value: value,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition> textEqualTo(
      String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'text',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterFilterCondition>
      textFragmentIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'textFragmentId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }
}

extension AudioCueQueryObject
    on QueryBuilder<AudioCue, AudioCue, QFilterCondition> {}

extension AudioCueQueryLinks
    on QueryBuilder<AudioCue, AudioCue, QFilterCondition> {}

extension AudioCueQuerySortBy on QueryBuilder<AudioCue, AudioCue, QSortBy> {
  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByAudioFileIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioFileIndex', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByAudioFileIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioFileIndex', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByBookUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByBookUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByChapterHref() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterHref', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByChapterHrefDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterHref', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByEndMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'endMs', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByEndMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'endMs', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortBySentenceIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sentenceIndex', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortBySentenceIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sentenceIndex', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByStartMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'startMs', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByStartMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'startMs', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByText() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'text', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByTextDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'text', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByTextFragmentId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'textFragmentId', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> sortByTextFragmentIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'textFragmentId', Sort.desc);
    });
  }
}

extension AudioCueQuerySortThenBy
    on QueryBuilder<AudioCue, AudioCue, QSortThenBy> {
  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByAudioFileIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioFileIndex', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByAudioFileIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'audioFileIndex', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByBookUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByBookUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookUid', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByChapterHref() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterHref', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByChapterHrefDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterHref', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByEndMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'endMs', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByEndMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'endMs', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenBySentenceIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sentenceIndex', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenBySentenceIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sentenceIndex', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByStartMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'startMs', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByStartMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'startMs', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByText() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'text', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByTextDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'text', Sort.desc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByTextFragmentId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'textFragmentId', Sort.asc);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QAfterSortBy> thenByTextFragmentIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'textFragmentId', Sort.desc);
    });
  }
}

extension AudioCueQueryWhereDistinct
    on QueryBuilder<AudioCue, AudioCue, QDistinct> {
  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByAudioFileIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'audioFileIndex');
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByBookUid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bookUid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByChapterHref(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chapterHref', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByEndMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'endMs');
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctBySentenceIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'sentenceIndex');
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByStartMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'startMs');
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByText(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'text', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AudioCue, AudioCue, QDistinct> distinctByTextFragmentId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'textFragmentId',
          caseSensitive: caseSensitive);
    });
  }
}

extension AudioCueQueryProperty
    on QueryBuilder<AudioCue, AudioCue, QQueryProperty> {
  QueryBuilder<AudioCue, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<AudioCue, int, QQueryOperations> audioFileIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'audioFileIndex');
    });
  }

  QueryBuilder<AudioCue, String, QQueryOperations> bookUidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bookUid');
    });
  }

  QueryBuilder<AudioCue, String, QQueryOperations> chapterHrefProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chapterHref');
    });
  }

  QueryBuilder<AudioCue, int, QQueryOperations> endMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'endMs');
    });
  }

  QueryBuilder<AudioCue, int, QQueryOperations> sentenceIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'sentenceIndex');
    });
  }

  QueryBuilder<AudioCue, int, QQueryOperations> startMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'startMs');
    });
  }

  QueryBuilder<AudioCue, String, QQueryOperations> textProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'text');
    });
  }

  QueryBuilder<AudioCue, String, QQueryOperations> textFragmentIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'textFragmentId');
    });
  }
}
