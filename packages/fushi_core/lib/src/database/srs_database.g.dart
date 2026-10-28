// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'srs_database.dart';

// ignore_for_file: type=lint
class $SrsEntitiesTable extends SrsEntities
    with TableInfo<$SrsEntitiesTable, SrsEntityRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsEntitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileUid,
    kind,
    payloadJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_entities';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsEntityRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrsEntityRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsEntityRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SrsEntitiesTable createAlias(String alias) {
    return $SrsEntitiesTable(attachedDatabase, alias);
  }
}

class SrsEntityRow extends DataClass implements Insertable<SrsEntityRow> {
  final String id;
  final String profileUid;

  /// deck / notetype / note（SrsEntityKind.wire）。
  final String kind;

  /// 规范 JSON（SrsEntityRecord.payload）。
  final String payloadJson;
  final int createdAt;
  const SrsEntityRow({
    required this.id,
    required this.profileUid,
    required this.kind,
    required this.payloadJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['profile_uid'] = Variable<String>(profileUid);
    map['kind'] = Variable<String>(kind);
    map['payload_json'] = Variable<String>(payloadJson);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  SrsEntitiesCompanion toCompanion(bool nullToAbsent) {
    return SrsEntitiesCompanion(
      id: Value(id),
      profileUid: Value(profileUid),
      kind: Value(kind),
      payloadJson: Value(payloadJson),
      createdAt: Value(createdAt),
    );
  }

  factory SrsEntityRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsEntityRow(
      id: serializer.fromJson<String>(json['id']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      kind: serializer.fromJson<String>(json['kind']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'profileUid': serializer.toJson<String>(profileUid),
      'kind': serializer.toJson<String>(kind),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  SrsEntityRow copyWith({
    String? id,
    String? profileUid,
    String? kind,
    String? payloadJson,
    int? createdAt,
  }) => SrsEntityRow(
    id: id ?? this.id,
    profileUid: profileUid ?? this.profileUid,
    kind: kind ?? this.kind,
    payloadJson: payloadJson ?? this.payloadJson,
    createdAt: createdAt ?? this.createdAt,
  );
  SrsEntityRow copyWithCompanion(SrsEntitiesCompanion data) {
    return SrsEntityRow(
      id: data.id.present ? data.id.value : this.id,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      kind: data.kind.present ? data.kind.value : this.kind,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsEntityRow(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('kind: $kind, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, profileUid, kind, payloadJson, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsEntityRow &&
          other.id == this.id &&
          other.profileUid == this.profileUid &&
          other.kind == this.kind &&
          other.payloadJson == this.payloadJson &&
          other.createdAt == this.createdAt);
}

class SrsEntitiesCompanion extends UpdateCompanion<SrsEntityRow> {
  final Value<String> id;
  final Value<String> profileUid;
  final Value<String> kind;
  final Value<String> payloadJson;
  final Value<int> createdAt;
  final Value<int> rowid;
  const SrsEntitiesCompanion({
    this.id = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.kind = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsEntitiesCompanion.insert({
    required String id,
    required String profileUid,
    required String kind,
    required String payloadJson,
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       profileUid = Value(profileUid),
       kind = Value(kind),
       payloadJson = Value(payloadJson);
  static Insertable<SrsEntityRow> custom({
    Expression<String>? id,
    Expression<String>? profileUid,
    Expression<String>? kind,
    Expression<String>? payloadJson,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileUid != null) 'profile_uid': profileUid,
      if (kind != null) 'kind': kind,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsEntitiesCompanion copyWith({
    Value<String>? id,
    Value<String>? profileUid,
    Value<String>? kind,
    Value<String>? payloadJson,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return SrsEntitiesCompanion(
      id: id ?? this.id,
      profileUid: profileUid ?? this.profileUid,
      kind: kind ?? this.kind,
      payloadJson: payloadJson ?? this.payloadJson,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsEntitiesCompanion(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('kind: $kind, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsFieldEditsTable extends SrsFieldEdits
    with TableInfo<$SrsFieldEditsTable, SrsFieldEditRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsFieldEditsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityKindMeta = const VerificationMeta(
    'entityKind',
  );
  @override
  late final GeneratedColumn<String> entityKind = GeneratedColumn<String>(
    'entity_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fieldKeyMeta = const VerificationMeta(
    'fieldKey',
  );
  @override
  late final GeneratedColumn<String> fieldKey = GeneratedColumn<String>(
    'field_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _writerIdMeta = const VerificationMeta(
    'writerId',
  );
  @override
  late final GeneratedColumn<String> writerId = GeneratedColumn<String>(
    'writer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _jsonMeta = const VerificationMeta('json');
  @override
  late final GeneratedColumn<String> json = GeneratedColumn<String>(
    'json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileUid,
    entityKind,
    entityId,
    fieldKey,
    writerId,
    seq,
    json,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_field_edits';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsFieldEditRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('entity_kind')) {
      context.handle(
        _entityKindMeta,
        entityKind.isAcceptableOrUnknown(data['entity_kind']!, _entityKindMeta),
      );
    } else if (isInserting) {
      context.missing(_entityKindMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('field_key')) {
      context.handle(
        _fieldKeyMeta,
        fieldKey.isAcceptableOrUnknown(data['field_key']!, _fieldKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_fieldKeyMeta);
    }
    if (data.containsKey('writer_id')) {
      context.handle(
        _writerIdMeta,
        writerId.isAcceptableOrUnknown(data['writer_id']!, _writerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_writerIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('json')) {
      context.handle(
        _jsonMeta,
        json.isAcceptableOrUnknown(data['json']!, _jsonMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrsFieldEditRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsFieldEditRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      entityKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_kind'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      fieldKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}field_key'],
      )!,
      writerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}writer_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      json: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}json'],
      )!,
    );
  }

  @override
  $SrsFieldEditsTable createAlias(String alias) {
    return $SrsFieldEditsTable(attachedDatabase, alias);
  }
}

class SrsFieldEditRow extends DataClass implements Insertable<SrsFieldEditRow> {
  final String id;
  final String profileUid;
  final String entityKind;
  final String entityId;
  final String fieldKey;
  final String writerId;
  final int seq;

  /// 完整事件的规范 JSON（含 ctx / 值 / hlc），读回时整条解析，不靠列拼装。
  final String json;
  const SrsFieldEditRow({
    required this.id,
    required this.profileUid,
    required this.entityKind,
    required this.entityId,
    required this.fieldKey,
    required this.writerId,
    required this.seq,
    required this.json,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['profile_uid'] = Variable<String>(profileUid);
    map['entity_kind'] = Variable<String>(entityKind);
    map['entity_id'] = Variable<String>(entityId);
    map['field_key'] = Variable<String>(fieldKey);
    map['writer_id'] = Variable<String>(writerId);
    map['seq'] = Variable<int>(seq);
    map['json'] = Variable<String>(json);
    return map;
  }

  SrsFieldEditsCompanion toCompanion(bool nullToAbsent) {
    return SrsFieldEditsCompanion(
      id: Value(id),
      profileUid: Value(profileUid),
      entityKind: Value(entityKind),
      entityId: Value(entityId),
      fieldKey: Value(fieldKey),
      writerId: Value(writerId),
      seq: Value(seq),
      json: Value(json),
    );
  }

  factory SrsFieldEditRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsFieldEditRow(
      id: serializer.fromJson<String>(json['id']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      entityKind: serializer.fromJson<String>(json['entityKind']),
      entityId: serializer.fromJson<String>(json['entityId']),
      fieldKey: serializer.fromJson<String>(json['fieldKey']),
      writerId: serializer.fromJson<String>(json['writerId']),
      seq: serializer.fromJson<int>(json['seq']),
      json: serializer.fromJson<String>(json['json']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'profileUid': serializer.toJson<String>(profileUid),
      'entityKind': serializer.toJson<String>(entityKind),
      'entityId': serializer.toJson<String>(entityId),
      'fieldKey': serializer.toJson<String>(fieldKey),
      'writerId': serializer.toJson<String>(writerId),
      'seq': serializer.toJson<int>(seq),
      'json': serializer.toJson<String>(json),
    };
  }

  SrsFieldEditRow copyWith({
    String? id,
    String? profileUid,
    String? entityKind,
    String? entityId,
    String? fieldKey,
    String? writerId,
    int? seq,
    String? json,
  }) => SrsFieldEditRow(
    id: id ?? this.id,
    profileUid: profileUid ?? this.profileUid,
    entityKind: entityKind ?? this.entityKind,
    entityId: entityId ?? this.entityId,
    fieldKey: fieldKey ?? this.fieldKey,
    writerId: writerId ?? this.writerId,
    seq: seq ?? this.seq,
    json: json ?? this.json,
  );
  SrsFieldEditRow copyWithCompanion(SrsFieldEditsCompanion data) {
    return SrsFieldEditRow(
      id: data.id.present ? data.id.value : this.id,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      entityKind: data.entityKind.present
          ? data.entityKind.value
          : this.entityKind,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      fieldKey: data.fieldKey.present ? data.fieldKey.value : this.fieldKey,
      writerId: data.writerId.present ? data.writerId.value : this.writerId,
      seq: data.seq.present ? data.seq.value : this.seq,
      json: data.json.present ? data.json.value : this.json,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsFieldEditRow(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('entityKind: $entityKind, ')
          ..write('entityId: $entityId, ')
          ..write('fieldKey: $fieldKey, ')
          ..write('writerId: $writerId, ')
          ..write('seq: $seq, ')
          ..write('json: $json')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileUid,
    entityKind,
    entityId,
    fieldKey,
    writerId,
    seq,
    json,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsFieldEditRow &&
          other.id == this.id &&
          other.profileUid == this.profileUid &&
          other.entityKind == this.entityKind &&
          other.entityId == this.entityId &&
          other.fieldKey == this.fieldKey &&
          other.writerId == this.writerId &&
          other.seq == this.seq &&
          other.json == this.json);
}

class SrsFieldEditsCompanion extends UpdateCompanion<SrsFieldEditRow> {
  final Value<String> id;
  final Value<String> profileUid;
  final Value<String> entityKind;
  final Value<String> entityId;
  final Value<String> fieldKey;
  final Value<String> writerId;
  final Value<int> seq;
  final Value<String> json;
  final Value<int> rowid;
  const SrsFieldEditsCompanion({
    this.id = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.entityKind = const Value.absent(),
    this.entityId = const Value.absent(),
    this.fieldKey = const Value.absent(),
    this.writerId = const Value.absent(),
    this.seq = const Value.absent(),
    this.json = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsFieldEditsCompanion.insert({
    required String id,
    required String profileUid,
    required String entityKind,
    required String entityId,
    required String fieldKey,
    required String writerId,
    required int seq,
    required String json,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       profileUid = Value(profileUid),
       entityKind = Value(entityKind),
       entityId = Value(entityId),
       fieldKey = Value(fieldKey),
       writerId = Value(writerId),
       seq = Value(seq),
       json = Value(json);
  static Insertable<SrsFieldEditRow> custom({
    Expression<String>? id,
    Expression<String>? profileUid,
    Expression<String>? entityKind,
    Expression<String>? entityId,
    Expression<String>? fieldKey,
    Expression<String>? writerId,
    Expression<int>? seq,
    Expression<String>? json,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileUid != null) 'profile_uid': profileUid,
      if (entityKind != null) 'entity_kind': entityKind,
      if (entityId != null) 'entity_id': entityId,
      if (fieldKey != null) 'field_key': fieldKey,
      if (writerId != null) 'writer_id': writerId,
      if (seq != null) 'seq': seq,
      if (json != null) 'json': json,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsFieldEditsCompanion copyWith({
    Value<String>? id,
    Value<String>? profileUid,
    Value<String>? entityKind,
    Value<String>? entityId,
    Value<String>? fieldKey,
    Value<String>? writerId,
    Value<int>? seq,
    Value<String>? json,
    Value<int>? rowid,
  }) {
    return SrsFieldEditsCompanion(
      id: id ?? this.id,
      profileUid: profileUid ?? this.profileUid,
      entityKind: entityKind ?? this.entityKind,
      entityId: entityId ?? this.entityId,
      fieldKey: fieldKey ?? this.fieldKey,
      writerId: writerId ?? this.writerId,
      seq: seq ?? this.seq,
      json: json ?? this.json,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (entityKind.present) {
      map['entity_kind'] = Variable<String>(entityKind.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (fieldKey.present) {
      map['field_key'] = Variable<String>(fieldKey.value);
    }
    if (writerId.present) {
      map['writer_id'] = Variable<String>(writerId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (json.present) {
      map['json'] = Variable<String>(json.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsFieldEditsCompanion(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('entityKind: $entityKind, ')
          ..write('entityId: $entityId, ')
          ..write('fieldKey: $fieldKey, ')
          ..write('writerId: $writerId, ')
          ..write('seq: $seq, ')
          ..write('json: $json, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsReviewLogsTable extends SrsReviewLogs
    with TableInfo<$SrsReviewLogsTable, SrsReviewLogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsReviewLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardIdMeta = const VerificationMeta('cardId');
  @override
  late final GeneratedColumn<String> cardId = GeneratedColumn<String>(
    'card_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<int> rating = GeneratedColumn<int>(
    'rating',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _occurredAtMeta = const VerificationMeta(
    'occurredAt',
  );
  @override
  late final GeneratedColumn<int> occurredAt = GeneratedColumn<int>(
    'occurred_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reviewTypeMeta = const VerificationMeta(
    'reviewType',
  );
  @override
  late final GeneratedColumn<String> reviewType = GeneratedColumn<String>(
    'review_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
    'origin',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _jsonMeta = const VerificationMeta('json');
  @override
  late final GeneratedColumn<String> json = GeneratedColumn<String>(
    'json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileUid,
    cardId,
    kind,
    rating,
    occurredAt,
    reviewType,
    origin,
    durationMs,
    json,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_review_logs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsReviewLogRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('card_id')) {
      context.handle(
        _cardIdMeta,
        cardId.isAcceptableOrUnknown(data['card_id']!, _cardIdMeta),
      );
    } else if (isInserting) {
      context.missing(_cardIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('rating')) {
      context.handle(
        _ratingMeta,
        rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta),
      );
    }
    if (data.containsKey('occurred_at')) {
      context.handle(
        _occurredAtMeta,
        occurredAt.isAcceptableOrUnknown(data['occurred_at']!, _occurredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_occurredAtMeta);
    }
    if (data.containsKey('review_type')) {
      context.handle(
        _reviewTypeMeta,
        reviewType.isAcceptableOrUnknown(data['review_type']!, _reviewTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_reviewTypeMeta);
    }
    if (data.containsKey('origin')) {
      context.handle(
        _originMeta,
        origin.isAcceptableOrUnknown(data['origin']!, _originMeta),
      );
    } else if (isInserting) {
      context.missing(_originMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('json')) {
      context.handle(
        _jsonMeta,
        json.isAcceptableOrUnknown(data['json']!, _jsonMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrsReviewLogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsReviewLogRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      cardId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      rating: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rating'],
      ),
      occurredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}occurred_at'],
      )!,
      reviewType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}review_type'],
      )!,
      origin: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      json: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}json'],
      )!,
    );
  }

  @override
  $SrsReviewLogsTable createAlias(String alias) {
    return $SrsReviewLogsTable(attachedDatabase, alias);
  }
}

class SrsReviewLogRow extends DataClass implements Insertable<SrsReviewLogRow> {
  final String id;
  final String profileUid;
  final String cardId;
  final String kind;
  final int? rating;
  final int occurredAt;
  final String reviewType;
  final String origin;
  final int durationMs;
  final String json;
  const SrsReviewLogRow({
    required this.id,
    required this.profileUid,
    required this.cardId,
    required this.kind,
    this.rating,
    required this.occurredAt,
    required this.reviewType,
    required this.origin,
    required this.durationMs,
    required this.json,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['profile_uid'] = Variable<String>(profileUid);
    map['card_id'] = Variable<String>(cardId);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || rating != null) {
      map['rating'] = Variable<int>(rating);
    }
    map['occurred_at'] = Variable<int>(occurredAt);
    map['review_type'] = Variable<String>(reviewType);
    map['origin'] = Variable<String>(origin);
    map['duration_ms'] = Variable<int>(durationMs);
    map['json'] = Variable<String>(json);
    return map;
  }

  SrsReviewLogsCompanion toCompanion(bool nullToAbsent) {
    return SrsReviewLogsCompanion(
      id: Value(id),
      profileUid: Value(profileUid),
      cardId: Value(cardId),
      kind: Value(kind),
      rating: rating == null && nullToAbsent
          ? const Value.absent()
          : Value(rating),
      occurredAt: Value(occurredAt),
      reviewType: Value(reviewType),
      origin: Value(origin),
      durationMs: Value(durationMs),
      json: Value(json),
    );
  }

  factory SrsReviewLogRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsReviewLogRow(
      id: serializer.fromJson<String>(json['id']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      cardId: serializer.fromJson<String>(json['cardId']),
      kind: serializer.fromJson<String>(json['kind']),
      rating: serializer.fromJson<int?>(json['rating']),
      occurredAt: serializer.fromJson<int>(json['occurredAt']),
      reviewType: serializer.fromJson<String>(json['reviewType']),
      origin: serializer.fromJson<String>(json['origin']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      json: serializer.fromJson<String>(json['json']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'profileUid': serializer.toJson<String>(profileUid),
      'cardId': serializer.toJson<String>(cardId),
      'kind': serializer.toJson<String>(kind),
      'rating': serializer.toJson<int?>(rating),
      'occurredAt': serializer.toJson<int>(occurredAt),
      'reviewType': serializer.toJson<String>(reviewType),
      'origin': serializer.toJson<String>(origin),
      'durationMs': serializer.toJson<int>(durationMs),
      'json': serializer.toJson<String>(json),
    };
  }

  SrsReviewLogRow copyWith({
    String? id,
    String? profileUid,
    String? cardId,
    String? kind,
    Value<int?> rating = const Value.absent(),
    int? occurredAt,
    String? reviewType,
    String? origin,
    int? durationMs,
    String? json,
  }) => SrsReviewLogRow(
    id: id ?? this.id,
    profileUid: profileUid ?? this.profileUid,
    cardId: cardId ?? this.cardId,
    kind: kind ?? this.kind,
    rating: rating.present ? rating.value : this.rating,
    occurredAt: occurredAt ?? this.occurredAt,
    reviewType: reviewType ?? this.reviewType,
    origin: origin ?? this.origin,
    durationMs: durationMs ?? this.durationMs,
    json: json ?? this.json,
  );
  SrsReviewLogRow copyWithCompanion(SrsReviewLogsCompanion data) {
    return SrsReviewLogRow(
      id: data.id.present ? data.id.value : this.id,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      cardId: data.cardId.present ? data.cardId.value : this.cardId,
      kind: data.kind.present ? data.kind.value : this.kind,
      rating: data.rating.present ? data.rating.value : this.rating,
      occurredAt: data.occurredAt.present
          ? data.occurredAt.value
          : this.occurredAt,
      reviewType: data.reviewType.present
          ? data.reviewType.value
          : this.reviewType,
      origin: data.origin.present ? data.origin.value : this.origin,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      json: data.json.present ? data.json.value : this.json,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsReviewLogRow(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('cardId: $cardId, ')
          ..write('kind: $kind, ')
          ..write('rating: $rating, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('reviewType: $reviewType, ')
          ..write('origin: $origin, ')
          ..write('durationMs: $durationMs, ')
          ..write('json: $json')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileUid,
    cardId,
    kind,
    rating,
    occurredAt,
    reviewType,
    origin,
    durationMs,
    json,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsReviewLogRow &&
          other.id == this.id &&
          other.profileUid == this.profileUid &&
          other.cardId == this.cardId &&
          other.kind == this.kind &&
          other.rating == this.rating &&
          other.occurredAt == this.occurredAt &&
          other.reviewType == this.reviewType &&
          other.origin == this.origin &&
          other.durationMs == this.durationMs &&
          other.json == this.json);
}

class SrsReviewLogsCompanion extends UpdateCompanion<SrsReviewLogRow> {
  final Value<String> id;
  final Value<String> profileUid;
  final Value<String> cardId;
  final Value<String> kind;
  final Value<int?> rating;
  final Value<int> occurredAt;
  final Value<String> reviewType;
  final Value<String> origin;
  final Value<int> durationMs;
  final Value<String> json;
  final Value<int> rowid;
  const SrsReviewLogsCompanion({
    this.id = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.cardId = const Value.absent(),
    this.kind = const Value.absent(),
    this.rating = const Value.absent(),
    this.occurredAt = const Value.absent(),
    this.reviewType = const Value.absent(),
    this.origin = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.json = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsReviewLogsCompanion.insert({
    required String id,
    required String profileUid,
    required String cardId,
    required String kind,
    this.rating = const Value.absent(),
    required int occurredAt,
    required String reviewType,
    required String origin,
    this.durationMs = const Value.absent(),
    required String json,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       profileUid = Value(profileUid),
       cardId = Value(cardId),
       kind = Value(kind),
       occurredAt = Value(occurredAt),
       reviewType = Value(reviewType),
       origin = Value(origin),
       json = Value(json);
  static Insertable<SrsReviewLogRow> custom({
    Expression<String>? id,
    Expression<String>? profileUid,
    Expression<String>? cardId,
    Expression<String>? kind,
    Expression<int>? rating,
    Expression<int>? occurredAt,
    Expression<String>? reviewType,
    Expression<String>? origin,
    Expression<int>? durationMs,
    Expression<String>? json,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileUid != null) 'profile_uid': profileUid,
      if (cardId != null) 'card_id': cardId,
      if (kind != null) 'kind': kind,
      if (rating != null) 'rating': rating,
      if (occurredAt != null) 'occurred_at': occurredAt,
      if (reviewType != null) 'review_type': reviewType,
      if (origin != null) 'origin': origin,
      if (durationMs != null) 'duration_ms': durationMs,
      if (json != null) 'json': json,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsReviewLogsCompanion copyWith({
    Value<String>? id,
    Value<String>? profileUid,
    Value<String>? cardId,
    Value<String>? kind,
    Value<int?>? rating,
    Value<int>? occurredAt,
    Value<String>? reviewType,
    Value<String>? origin,
    Value<int>? durationMs,
    Value<String>? json,
    Value<int>? rowid,
  }) {
    return SrsReviewLogsCompanion(
      id: id ?? this.id,
      profileUid: profileUid ?? this.profileUid,
      cardId: cardId ?? this.cardId,
      kind: kind ?? this.kind,
      rating: rating ?? this.rating,
      occurredAt: occurredAt ?? this.occurredAt,
      reviewType: reviewType ?? this.reviewType,
      origin: origin ?? this.origin,
      durationMs: durationMs ?? this.durationMs,
      json: json ?? this.json,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (cardId.present) {
      map['card_id'] = Variable<String>(cardId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (rating.present) {
      map['rating'] = Variable<int>(rating.value);
    }
    if (occurredAt.present) {
      map['occurred_at'] = Variable<int>(occurredAt.value);
    }
    if (reviewType.present) {
      map['review_type'] = Variable<String>(reviewType.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (json.present) {
      map['json'] = Variable<String>(json.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsReviewLogsCompanion(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('cardId: $cardId, ')
          ..write('kind: $kind, ')
          ..write('rating: $rating, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('reviewType: $reviewType, ')
          ..write('origin: $origin, ')
          ..write('durationMs: $durationMs, ')
          ..write('json: $json, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsUnknownEventsTable extends SrsUnknownEvents
    with TableInfo<$SrsUnknownEventsTable, SrsUnknownEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsUnknownEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _jsonMeta = const VerificationMeta('json');
  @override
  late final GeneratedColumn<String> json = GeneratedColumn<String>(
    'json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, profileUid, json];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_unknown_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsUnknownEventRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('json')) {
      context.handle(
        _jsonMeta,
        json.isAcceptableOrUnknown(data['json']!, _jsonMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrsUnknownEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsUnknownEventRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      json: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}json'],
      )!,
    );
  }

  @override
  $SrsUnknownEventsTable createAlias(String alias) {
    return $SrsUnknownEventsTable(attachedDatabase, alias);
  }
}

class SrsUnknownEventRow extends DataClass
    implements Insertable<SrsUnknownEventRow> {
  final String id;
  final String profileUid;
  final String json;
  const SrsUnknownEventRow({
    required this.id,
    required this.profileUid,
    required this.json,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['profile_uid'] = Variable<String>(profileUid);
    map['json'] = Variable<String>(json);
    return map;
  }

  SrsUnknownEventsCompanion toCompanion(bool nullToAbsent) {
    return SrsUnknownEventsCompanion(
      id: Value(id),
      profileUid: Value(profileUid),
      json: Value(json),
    );
  }

  factory SrsUnknownEventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsUnknownEventRow(
      id: serializer.fromJson<String>(json['id']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      json: serializer.fromJson<String>(json['json']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'profileUid': serializer.toJson<String>(profileUid),
      'json': serializer.toJson<String>(json),
    };
  }

  SrsUnknownEventRow copyWith({String? id, String? profileUid, String? json}) =>
      SrsUnknownEventRow(
        id: id ?? this.id,
        profileUid: profileUid ?? this.profileUid,
        json: json ?? this.json,
      );
  SrsUnknownEventRow copyWithCompanion(SrsUnknownEventsCompanion data) {
    return SrsUnknownEventRow(
      id: data.id.present ? data.id.value : this.id,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      json: data.json.present ? data.json.value : this.json,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsUnknownEventRow(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('json: $json')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, profileUid, json);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsUnknownEventRow &&
          other.id == this.id &&
          other.profileUid == this.profileUid &&
          other.json == this.json);
}

class SrsUnknownEventsCompanion extends UpdateCompanion<SrsUnknownEventRow> {
  final Value<String> id;
  final Value<String> profileUid;
  final Value<String> json;
  final Value<int> rowid;
  const SrsUnknownEventsCompanion({
    this.id = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.json = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsUnknownEventsCompanion.insert({
    required String id,
    required String profileUid,
    required String json,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       profileUid = Value(profileUid),
       json = Value(json);
  static Insertable<SrsUnknownEventRow> custom({
    Expression<String>? id,
    Expression<String>? profileUid,
    Expression<String>? json,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileUid != null) 'profile_uid': profileUid,
      if (json != null) 'json': json,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsUnknownEventsCompanion copyWith({
    Value<String>? id,
    Value<String>? profileUid,
    Value<String>? json,
    Value<int>? rowid,
  }) {
    return SrsUnknownEventsCompanion(
      id: id ?? this.id,
      profileUid: profileUid ?? this.profileUid,
      json: json ?? this.json,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (json.present) {
      map['json'] = Variable<String>(json.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsUnknownEventsCompanion(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('json: $json, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsEventLocalTable extends SrsEventLocal
    with TableInfo<$SrsEventLocalTable, SrsEventLocalRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsEventLocalTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _eventIdMeta = const VerificationMeta(
    'eventId',
  );
  @override
  late final GeneratedColumn<String> eventId = GeneratedColumn<String>(
    'event_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _outboxSeqMeta = const VerificationMeta(
    'outboxSeq',
  );
  @override
  late final GeneratedColumn<int> outboxSeq = GeneratedColumn<int>(
    'outbox_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverTimeMeta = const VerificationMeta(
    'serverTime',
  );
  @override
  late final GeneratedColumn<int> serverTime = GeneratedColumn<int>(
    'server_time',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _receivedAtMeta = const VerificationMeta(
    'receivedAt',
  );
  @override
  late final GeneratedColumn<int> receivedAt = GeneratedColumn<int>(
    'received_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    eventId,
    profileUid,
    outboxSeq,
    serverTime,
    receivedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_event_local';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsEventLocalRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('event_id')) {
      context.handle(
        _eventIdMeta,
        eventId.isAcceptableOrUnknown(data['event_id']!, _eventIdMeta),
      );
    } else if (isInserting) {
      context.missing(_eventIdMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('outbox_seq')) {
      context.handle(
        _outboxSeqMeta,
        outboxSeq.isAcceptableOrUnknown(data['outbox_seq']!, _outboxSeqMeta),
      );
    }
    if (data.containsKey('server_time')) {
      context.handle(
        _serverTimeMeta,
        serverTime.isAcceptableOrUnknown(data['server_time']!, _serverTimeMeta),
      );
    }
    if (data.containsKey('received_at')) {
      context.handle(
        _receivedAtMeta,
        receivedAt.isAcceptableOrUnknown(data['received_at']!, _receivedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {eventId};
  @override
  SrsEventLocalRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsEventLocalRow(
      eventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      outboxSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}outbox_seq'],
      ),
      serverTime: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_time'],
      ),
      receivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received_at'],
      )!,
    );
  }

  @override
  $SrsEventLocalTable createAlias(String alias) {
    return $SrsEventLocalTable(attachedDatabase, alias);
  }
}

class SrsEventLocalRow extends DataClass
    implements Insertable<SrsEventLocalRow> {
  final String eventId;
  final String profileUid;

  /// 本机产生的事件在发件箱里的顺序；null = 对端来的或已发布。
  final int? outboxSeq;

  /// S(e)：所有已见到的、包含该事件的批次的 S 的最小值。
  final int? serverTime;
  final int receivedAt;
  const SrsEventLocalRow({
    required this.eventId,
    required this.profileUid,
    this.outboxSeq,
    this.serverTime,
    required this.receivedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['event_id'] = Variable<String>(eventId);
    map['profile_uid'] = Variable<String>(profileUid);
    if (!nullToAbsent || outboxSeq != null) {
      map['outbox_seq'] = Variable<int>(outboxSeq);
    }
    if (!nullToAbsent || serverTime != null) {
      map['server_time'] = Variable<int>(serverTime);
    }
    map['received_at'] = Variable<int>(receivedAt);
    return map;
  }

  SrsEventLocalCompanion toCompanion(bool nullToAbsent) {
    return SrsEventLocalCompanion(
      eventId: Value(eventId),
      profileUid: Value(profileUid),
      outboxSeq: outboxSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(outboxSeq),
      serverTime: serverTime == null && nullToAbsent
          ? const Value.absent()
          : Value(serverTime),
      receivedAt: Value(receivedAt),
    );
  }

  factory SrsEventLocalRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsEventLocalRow(
      eventId: serializer.fromJson<String>(json['eventId']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      outboxSeq: serializer.fromJson<int?>(json['outboxSeq']),
      serverTime: serializer.fromJson<int?>(json['serverTime']),
      receivedAt: serializer.fromJson<int>(json['receivedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'eventId': serializer.toJson<String>(eventId),
      'profileUid': serializer.toJson<String>(profileUid),
      'outboxSeq': serializer.toJson<int?>(outboxSeq),
      'serverTime': serializer.toJson<int?>(serverTime),
      'receivedAt': serializer.toJson<int>(receivedAt),
    };
  }

  SrsEventLocalRow copyWith({
    String? eventId,
    String? profileUid,
    Value<int?> outboxSeq = const Value.absent(),
    Value<int?> serverTime = const Value.absent(),
    int? receivedAt,
  }) => SrsEventLocalRow(
    eventId: eventId ?? this.eventId,
    profileUid: profileUid ?? this.profileUid,
    outboxSeq: outboxSeq.present ? outboxSeq.value : this.outboxSeq,
    serverTime: serverTime.present ? serverTime.value : this.serverTime,
    receivedAt: receivedAt ?? this.receivedAt,
  );
  SrsEventLocalRow copyWithCompanion(SrsEventLocalCompanion data) {
    return SrsEventLocalRow(
      eventId: data.eventId.present ? data.eventId.value : this.eventId,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      outboxSeq: data.outboxSeq.present ? data.outboxSeq.value : this.outboxSeq,
      serverTime: data.serverTime.present
          ? data.serverTime.value
          : this.serverTime,
      receivedAt: data.receivedAt.present
          ? data.receivedAt.value
          : this.receivedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsEventLocalRow(')
          ..write('eventId: $eventId, ')
          ..write('profileUid: $profileUid, ')
          ..write('outboxSeq: $outboxSeq, ')
          ..write('serverTime: $serverTime, ')
          ..write('receivedAt: $receivedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(eventId, profileUid, outboxSeq, serverTime, receivedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsEventLocalRow &&
          other.eventId == this.eventId &&
          other.profileUid == this.profileUid &&
          other.outboxSeq == this.outboxSeq &&
          other.serverTime == this.serverTime &&
          other.receivedAt == this.receivedAt);
}

class SrsEventLocalCompanion extends UpdateCompanion<SrsEventLocalRow> {
  final Value<String> eventId;
  final Value<String> profileUid;
  final Value<int?> outboxSeq;
  final Value<int?> serverTime;
  final Value<int> receivedAt;
  final Value<int> rowid;
  const SrsEventLocalCompanion({
    this.eventId = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.outboxSeq = const Value.absent(),
    this.serverTime = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsEventLocalCompanion.insert({
    required String eventId,
    required String profileUid,
    this.outboxSeq = const Value.absent(),
    this.serverTime = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : eventId = Value(eventId),
       profileUid = Value(profileUid);
  static Insertable<SrsEventLocalRow> custom({
    Expression<String>? eventId,
    Expression<String>? profileUid,
    Expression<int>? outboxSeq,
    Expression<int>? serverTime,
    Expression<int>? receivedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (eventId != null) 'event_id': eventId,
      if (profileUid != null) 'profile_uid': profileUid,
      if (outboxSeq != null) 'outbox_seq': outboxSeq,
      if (serverTime != null) 'server_time': serverTime,
      if (receivedAt != null) 'received_at': receivedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsEventLocalCompanion copyWith({
    Value<String>? eventId,
    Value<String>? profileUid,
    Value<int?>? outboxSeq,
    Value<int?>? serverTime,
    Value<int>? receivedAt,
    Value<int>? rowid,
  }) {
    return SrsEventLocalCompanion(
      eventId: eventId ?? this.eventId,
      profileUid: profileUid ?? this.profileUid,
      outboxSeq: outboxSeq ?? this.outboxSeq,
      serverTime: serverTime ?? this.serverTime,
      receivedAt: receivedAt ?? this.receivedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (eventId.present) {
      map['event_id'] = Variable<String>(eventId.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (outboxSeq.present) {
      map['outbox_seq'] = Variable<int>(outboxSeq.value);
    }
    if (serverTime.present) {
      map['server_time'] = Variable<int>(serverTime.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<int>(receivedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsEventLocalCompanion(')
          ..write('eventId: $eventId, ')
          ..write('profileUid: $profileUid, ')
          ..write('outboxSeq: $outboxSeq, ')
          ..write('serverTime: $serverTime, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsLocalStateTable extends SrsLocalState
    with TableInfo<$SrsLocalStateTable, SrsLocalStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsLocalStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _jsonMeta = const VerificationMeta('json');
  @override
  late final GeneratedColumn<String> json = GeneratedColumn<String>(
    'json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [profileUid, json];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_local_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsLocalStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('json')) {
      context.handle(
        _jsonMeta,
        json.isAcceptableOrUnknown(data['json']!, _jsonMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileUid};
  @override
  SrsLocalStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsLocalStateRow(
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      json: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}json'],
      )!,
    );
  }

  @override
  $SrsLocalStateTable createAlias(String alias) {
    return $SrsLocalStateTable(attachedDatabase, alias);
  }
}

class SrsLocalStateRow extends DataClass
    implements Insertable<SrsLocalStateRow> {
  final String profileUid;
  final String json;
  const SrsLocalStateRow({required this.profileUid, required this.json});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_uid'] = Variable<String>(profileUid);
    map['json'] = Variable<String>(json);
    return map;
  }

  SrsLocalStateCompanion toCompanion(bool nullToAbsent) {
    return SrsLocalStateCompanion(
      profileUid: Value(profileUid),
      json: Value(json),
    );
  }

  factory SrsLocalStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsLocalStateRow(
      profileUid: serializer.fromJson<String>(json['profileUid']),
      json: serializer.fromJson<String>(json['json']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileUid': serializer.toJson<String>(profileUid),
      'json': serializer.toJson<String>(json),
    };
  }

  SrsLocalStateRow copyWith({String? profileUid, String? json}) =>
      SrsLocalStateRow(
        profileUid: profileUid ?? this.profileUid,
        json: json ?? this.json,
      );
  SrsLocalStateRow copyWithCompanion(SrsLocalStateCompanion data) {
    return SrsLocalStateRow(
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      json: data.json.present ? data.json.value : this.json,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsLocalStateRow(')
          ..write('profileUid: $profileUid, ')
          ..write('json: $json')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(profileUid, json);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsLocalStateRow &&
          other.profileUid == this.profileUid &&
          other.json == this.json);
}

class SrsLocalStateCompanion extends UpdateCompanion<SrsLocalStateRow> {
  final Value<String> profileUid;
  final Value<String> json;
  final Value<int> rowid;
  const SrsLocalStateCompanion({
    this.profileUid = const Value.absent(),
    this.json = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsLocalStateCompanion.insert({
    required String profileUid,
    required String json,
    this.rowid = const Value.absent(),
  }) : profileUid = Value(profileUid),
       json = Value(json);
  static Insertable<SrsLocalStateRow> custom({
    Expression<String>? profileUid,
    Expression<String>? json,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileUid != null) 'profile_uid': profileUid,
      if (json != null) 'json': json,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsLocalStateCompanion copyWith({
    Value<String>? profileUid,
    Value<String>? json,
    Value<int>? rowid,
  }) {
    return SrsLocalStateCompanion(
      profileUid: profileUid ?? this.profileUid,
      json: json ?? this.json,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (json.present) {
      map['json'] = Variable<String>(json.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsLocalStateCompanion(')
          ..write('profileUid: $profileUid, ')
          ..write('json: $json, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsSentBatchesTable extends SrsSentBatches
    with TableInfo<$SrsSentBatchesTable, SrsSentBatchRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsSentBatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _writerIdMeta = const VerificationMeta(
    'writerId',
  );
  @override
  late final GeneratedColumn<String> writerId = GeneratedColumn<String>(
    'writer_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _batchNoMeta = const VerificationMeta(
    'batchNo',
  );
  @override
  late final GeneratedColumn<int> batchNo = GeneratedColumn<int>(
    'batch_no',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [profileUid, writerId, batchNo, bytes];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_sent_batches';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsSentBatchRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('writer_id')) {
      context.handle(
        _writerIdMeta,
        writerId.isAcceptableOrUnknown(data['writer_id']!, _writerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_writerIdMeta);
    }
    if (data.containsKey('batch_no')) {
      context.handle(
        _batchNoMeta,
        batchNo.isAcceptableOrUnknown(data['batch_no']!, _batchNoMeta),
      );
    } else if (isInserting) {
      context.missing(_batchNoMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileUid, writerId, batchNo};
  @override
  SrsSentBatchRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsSentBatchRow(
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      writerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}writer_id'],
      )!,
      batchNo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}batch_no'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      )!,
    );
  }

  @override
  $SrsSentBatchesTable createAlias(String alias) {
    return $SrsSentBatchesTable(attachedDatabase, alias);
  }
}

class SrsSentBatchRow extends DataClass implements Insertable<SrsSentBatchRow> {
  final String profileUid;
  final String writerId;

  /// 批次号（写入者内从 1 起连续）。
  final int batchNo;

  /// 冻结后的批次文件字节（自校验格式，见 fushi_srs `SrsBatch`）。
  final Uint8List bytes;
  const SrsSentBatchRow({
    required this.profileUid,
    required this.writerId,
    required this.batchNo,
    required this.bytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_uid'] = Variable<String>(profileUid);
    map['writer_id'] = Variable<String>(writerId);
    map['batch_no'] = Variable<int>(batchNo);
    map['bytes'] = Variable<Uint8List>(bytes);
    return map;
  }

  SrsSentBatchesCompanion toCompanion(bool nullToAbsent) {
    return SrsSentBatchesCompanion(
      profileUid: Value(profileUid),
      writerId: Value(writerId),
      batchNo: Value(batchNo),
      bytes: Value(bytes),
    );
  }

  factory SrsSentBatchRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsSentBatchRow(
      profileUid: serializer.fromJson<String>(json['profileUid']),
      writerId: serializer.fromJson<String>(json['writerId']),
      batchNo: serializer.fromJson<int>(json['batchNo']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileUid': serializer.toJson<String>(profileUid),
      'writerId': serializer.toJson<String>(writerId),
      'batchNo': serializer.toJson<int>(batchNo),
      'bytes': serializer.toJson<Uint8List>(bytes),
    };
  }

  SrsSentBatchRow copyWith({
    String? profileUid,
    String? writerId,
    int? batchNo,
    Uint8List? bytes,
  }) => SrsSentBatchRow(
    profileUid: profileUid ?? this.profileUid,
    writerId: writerId ?? this.writerId,
    batchNo: batchNo ?? this.batchNo,
    bytes: bytes ?? this.bytes,
  );
  SrsSentBatchRow copyWithCompanion(SrsSentBatchesCompanion data) {
    return SrsSentBatchRow(
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      writerId: data.writerId.present ? data.writerId.value : this.writerId,
      batchNo: data.batchNo.present ? data.batchNo.value : this.batchNo,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsSentBatchRow(')
          ..write('profileUid: $profileUid, ')
          ..write('writerId: $writerId, ')
          ..write('batchNo: $batchNo, ')
          ..write('bytes: $bytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    profileUid,
    writerId,
    batchNo,
    $driftBlobEquality.hash(bytes),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsSentBatchRow &&
          other.profileUid == this.profileUid &&
          other.writerId == this.writerId &&
          other.batchNo == this.batchNo &&
          $driftBlobEquality.equals(other.bytes, this.bytes));
}

class SrsSentBatchesCompanion extends UpdateCompanion<SrsSentBatchRow> {
  final Value<String> profileUid;
  final Value<String> writerId;
  final Value<int> batchNo;
  final Value<Uint8List> bytes;
  final Value<int> rowid;
  const SrsSentBatchesCompanion({
    this.profileUid = const Value.absent(),
    this.writerId = const Value.absent(),
    this.batchNo = const Value.absent(),
    this.bytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsSentBatchesCompanion.insert({
    required String profileUid,
    required String writerId,
    required int batchNo,
    required Uint8List bytes,
    this.rowid = const Value.absent(),
  }) : profileUid = Value(profileUid),
       writerId = Value(writerId),
       batchNo = Value(batchNo),
       bytes = Value(bytes);
  static Insertable<SrsSentBatchRow> custom({
    Expression<String>? profileUid,
    Expression<String>? writerId,
    Expression<int>? batchNo,
    Expression<Uint8List>? bytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileUid != null) 'profile_uid': profileUid,
      if (writerId != null) 'writer_id': writerId,
      if (batchNo != null) 'batch_no': batchNo,
      if (bytes != null) 'bytes': bytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsSentBatchesCompanion copyWith({
    Value<String>? profileUid,
    Value<String>? writerId,
    Value<int>? batchNo,
    Value<Uint8List>? bytes,
    Value<int>? rowid,
  }) {
    return SrsSentBatchesCompanion(
      profileUid: profileUid ?? this.profileUid,
      writerId: writerId ?? this.writerId,
      batchNo: batchNo ?? this.batchNo,
      bytes: bytes ?? this.bytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (writerId.present) {
      map['writer_id'] = Variable<String>(writerId.value);
    }
    if (batchNo.present) {
      map['batch_no'] = Variable<int>(batchNo.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsSentBatchesCompanion(')
          ..write('profileUid: $profileUid, ')
          ..write('writerId: $writerId, ')
          ..write('batchNo: $batchNo, ')
          ..write('bytes: $bytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsNotesCacheTable extends SrsNotesCache
    with TableInfo<$SrsNotesCacheTable, SrsNoteCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsNotesCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteTypeIdMeta = const VerificationMeta(
    'noteTypeId',
  );
  @override
  late final GeneratedColumn<String> noteTypeId = GeneratedColumn<String>(
    'note_type_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _guidMeta = const VerificationMeta('guid');
  @override
  late final GeneratedColumn<String> guid = GeneratedColumn<String>(
    'guid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deckIdMeta = const VerificationMeta('deckId');
  @override
  late final GeneratedColumn<String> deckId = GeneratedColumn<String>(
    'deck_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _termKeyMeta = const VerificationMeta(
    'termKey',
  );
  @override
  late final GeneratedColumn<String> termKey = GeneratedColumn<String>(
    'term_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _readingKeyMeta = const VerificationMeta(
    'readingKey',
  );
  @override
  late final GeneratedColumn<String> readingKey = GeneratedColumn<String>(
    'reading_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _sortFieldMeta = const VerificationMeta(
    'sortField',
  );
  @override
  late final GeneratedColumn<String> sortField = GeneratedColumn<String>(
    'sort_field',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _pendingDecisionMeta = const VerificationMeta(
    'pendingDecision',
  );
  @override
  late final GeneratedColumn<bool> pendingDecision = GeneratedColumn<bool>(
    'pending_decision',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pending_decision" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _mediaRefsMeta = const VerificationMeta(
    'mediaRefs',
  );
  @override
  late final GeneratedColumn<String> mediaRefs = GeneratedColumn<String>(
    'media_refs',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileUid,
    noteTypeId,
    guid,
    createdAt,
    deckId,
    deletedAt,
    termKey,
    readingKey,
    sortField,
    tagsJson,
    pendingDecision,
    updatedAt,
    mediaRefs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_notes_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsNoteCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('note_type_id')) {
      context.handle(
        _noteTypeIdMeta,
        noteTypeId.isAcceptableOrUnknown(
          data['note_type_id']!,
          _noteTypeIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_noteTypeIdMeta);
    }
    if (data.containsKey('guid')) {
      context.handle(
        _guidMeta,
        guid.isAcceptableOrUnknown(data['guid']!, _guidMeta),
      );
    } else if (isInserting) {
      context.missing(_guidMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('deck_id')) {
      context.handle(
        _deckIdMeta,
        deckId.isAcceptableOrUnknown(data['deck_id']!, _deckIdMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('term_key')) {
      context.handle(
        _termKeyMeta,
        termKey.isAcceptableOrUnknown(data['term_key']!, _termKeyMeta),
      );
    }
    if (data.containsKey('reading_key')) {
      context.handle(
        _readingKeyMeta,
        readingKey.isAcceptableOrUnknown(data['reading_key']!, _readingKeyMeta),
      );
    }
    if (data.containsKey('sort_field')) {
      context.handle(
        _sortFieldMeta,
        sortField.isAcceptableOrUnknown(data['sort_field']!, _sortFieldMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    }
    if (data.containsKey('pending_decision')) {
      context.handle(
        _pendingDecisionMeta,
        pendingDecision.isAcceptableOrUnknown(
          data['pending_decision']!,
          _pendingDecisionMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('media_refs')) {
      context.handle(
        _mediaRefsMeta,
        mediaRefs.isAcceptableOrUnknown(data['media_refs']!, _mediaRefsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrsNoteCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsNoteCacheRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      noteTypeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note_type_id'],
      )!,
      guid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}guid'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      deckId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deck_id'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      termKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}term_key'],
      )!,
      readingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reading_key'],
      )!,
      sortField: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_field'],
      )!,
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      pendingDecision: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pending_decision'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      mediaRefs: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_refs'],
      )!,
    );
  }

  @override
  $SrsNotesCacheTable createAlias(String alias) {
    return $SrsNotesCacheTable(attachedDatabase, alias);
  }
}

class SrsNoteCacheRow extends DataClass implements Insertable<SrsNoteCacheRow> {
  final String id;
  final String profileUid;
  final String noteTypeId;
  final String guid;
  final int createdAt;
  final String? deckId;
  final int? deletedAt;

  /// 词状态索引：词形 / 读音归一化（第六轮审查第 20 条）。
  final String termKey;
  final String readingKey;

  /// 排序 / 列表显示用的第一个字段（去 HTML）。
  final String sortField;
  final String tagsJson;
  final bool pendingDecision;
  final int updatedAt;

  /// srs.db schema v4：这条笔记当前字段值引用的媒体文件名（`<img src>` / `[sound:]` / 共享样式文件，
  /// 换行分隔，去重排序），随笔记缓存同一次刷新算出。媒体同步每轮只读这一列，不再逐页读全部修改记录
  /// 解析字段值（审计 D）。已删笔记写空。
  final String mediaRefs;
  const SrsNoteCacheRow({
    required this.id,
    required this.profileUid,
    required this.noteTypeId,
    required this.guid,
    required this.createdAt,
    this.deckId,
    this.deletedAt,
    required this.termKey,
    required this.readingKey,
    required this.sortField,
    required this.tagsJson,
    required this.pendingDecision,
    required this.updatedAt,
    required this.mediaRefs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['profile_uid'] = Variable<String>(profileUid);
    map['note_type_id'] = Variable<String>(noteTypeId);
    map['guid'] = Variable<String>(guid);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || deckId != null) {
      map['deck_id'] = Variable<String>(deckId);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    map['term_key'] = Variable<String>(termKey);
    map['reading_key'] = Variable<String>(readingKey);
    map['sort_field'] = Variable<String>(sortField);
    map['tags_json'] = Variable<String>(tagsJson);
    map['pending_decision'] = Variable<bool>(pendingDecision);
    map['updated_at'] = Variable<int>(updatedAt);
    map['media_refs'] = Variable<String>(mediaRefs);
    return map;
  }

  SrsNotesCacheCompanion toCompanion(bool nullToAbsent) {
    return SrsNotesCacheCompanion(
      id: Value(id),
      profileUid: Value(profileUid),
      noteTypeId: Value(noteTypeId),
      guid: Value(guid),
      createdAt: Value(createdAt),
      deckId: deckId == null && nullToAbsent
          ? const Value.absent()
          : Value(deckId),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      termKey: Value(termKey),
      readingKey: Value(readingKey),
      sortField: Value(sortField),
      tagsJson: Value(tagsJson),
      pendingDecision: Value(pendingDecision),
      updatedAt: Value(updatedAt),
      mediaRefs: Value(mediaRefs),
    );
  }

  factory SrsNoteCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsNoteCacheRow(
      id: serializer.fromJson<String>(json['id']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      noteTypeId: serializer.fromJson<String>(json['noteTypeId']),
      guid: serializer.fromJson<String>(json['guid']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      deckId: serializer.fromJson<String?>(json['deckId']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      termKey: serializer.fromJson<String>(json['termKey']),
      readingKey: serializer.fromJson<String>(json['readingKey']),
      sortField: serializer.fromJson<String>(json['sortField']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      pendingDecision: serializer.fromJson<bool>(json['pendingDecision']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      mediaRefs: serializer.fromJson<String>(json['mediaRefs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'profileUid': serializer.toJson<String>(profileUid),
      'noteTypeId': serializer.toJson<String>(noteTypeId),
      'guid': serializer.toJson<String>(guid),
      'createdAt': serializer.toJson<int>(createdAt),
      'deckId': serializer.toJson<String?>(deckId),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'termKey': serializer.toJson<String>(termKey),
      'readingKey': serializer.toJson<String>(readingKey),
      'sortField': serializer.toJson<String>(sortField),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'pendingDecision': serializer.toJson<bool>(pendingDecision),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'mediaRefs': serializer.toJson<String>(mediaRefs),
    };
  }

  SrsNoteCacheRow copyWith({
    String? id,
    String? profileUid,
    String? noteTypeId,
    String? guid,
    int? createdAt,
    Value<String?> deckId = const Value.absent(),
    Value<int?> deletedAt = const Value.absent(),
    String? termKey,
    String? readingKey,
    String? sortField,
    String? tagsJson,
    bool? pendingDecision,
    int? updatedAt,
    String? mediaRefs,
  }) => SrsNoteCacheRow(
    id: id ?? this.id,
    profileUid: profileUid ?? this.profileUid,
    noteTypeId: noteTypeId ?? this.noteTypeId,
    guid: guid ?? this.guid,
    createdAt: createdAt ?? this.createdAt,
    deckId: deckId.present ? deckId.value : this.deckId,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    termKey: termKey ?? this.termKey,
    readingKey: readingKey ?? this.readingKey,
    sortField: sortField ?? this.sortField,
    tagsJson: tagsJson ?? this.tagsJson,
    pendingDecision: pendingDecision ?? this.pendingDecision,
    updatedAt: updatedAt ?? this.updatedAt,
    mediaRefs: mediaRefs ?? this.mediaRefs,
  );
  SrsNoteCacheRow copyWithCompanion(SrsNotesCacheCompanion data) {
    return SrsNoteCacheRow(
      id: data.id.present ? data.id.value : this.id,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      noteTypeId: data.noteTypeId.present
          ? data.noteTypeId.value
          : this.noteTypeId,
      guid: data.guid.present ? data.guid.value : this.guid,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      deckId: data.deckId.present ? data.deckId.value : this.deckId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      termKey: data.termKey.present ? data.termKey.value : this.termKey,
      readingKey: data.readingKey.present
          ? data.readingKey.value
          : this.readingKey,
      sortField: data.sortField.present ? data.sortField.value : this.sortField,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      pendingDecision: data.pendingDecision.present
          ? data.pendingDecision.value
          : this.pendingDecision,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      mediaRefs: data.mediaRefs.present ? data.mediaRefs.value : this.mediaRefs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsNoteCacheRow(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('noteTypeId: $noteTypeId, ')
          ..write('guid: $guid, ')
          ..write('createdAt: $createdAt, ')
          ..write('deckId: $deckId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('termKey: $termKey, ')
          ..write('readingKey: $readingKey, ')
          ..write('sortField: $sortField, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('pendingDecision: $pendingDecision, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('mediaRefs: $mediaRefs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileUid,
    noteTypeId,
    guid,
    createdAt,
    deckId,
    deletedAt,
    termKey,
    readingKey,
    sortField,
    tagsJson,
    pendingDecision,
    updatedAt,
    mediaRefs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsNoteCacheRow &&
          other.id == this.id &&
          other.profileUid == this.profileUid &&
          other.noteTypeId == this.noteTypeId &&
          other.guid == this.guid &&
          other.createdAt == this.createdAt &&
          other.deckId == this.deckId &&
          other.deletedAt == this.deletedAt &&
          other.termKey == this.termKey &&
          other.readingKey == this.readingKey &&
          other.sortField == this.sortField &&
          other.tagsJson == this.tagsJson &&
          other.pendingDecision == this.pendingDecision &&
          other.updatedAt == this.updatedAt &&
          other.mediaRefs == this.mediaRefs);
}

class SrsNotesCacheCompanion extends UpdateCompanion<SrsNoteCacheRow> {
  final Value<String> id;
  final Value<String> profileUid;
  final Value<String> noteTypeId;
  final Value<String> guid;
  final Value<int> createdAt;
  final Value<String?> deckId;
  final Value<int?> deletedAt;
  final Value<String> termKey;
  final Value<String> readingKey;
  final Value<String> sortField;
  final Value<String> tagsJson;
  final Value<bool> pendingDecision;
  final Value<int> updatedAt;
  final Value<String> mediaRefs;
  final Value<int> rowid;
  const SrsNotesCacheCompanion({
    this.id = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.noteTypeId = const Value.absent(),
    this.guid = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.deckId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.termKey = const Value.absent(),
    this.readingKey = const Value.absent(),
    this.sortField = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.pendingDecision = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.mediaRefs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsNotesCacheCompanion.insert({
    required String id,
    required String profileUid,
    required String noteTypeId,
    required String guid,
    required int createdAt,
    this.deckId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.termKey = const Value.absent(),
    this.readingKey = const Value.absent(),
    this.sortField = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.pendingDecision = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.mediaRefs = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       profileUid = Value(profileUid),
       noteTypeId = Value(noteTypeId),
       guid = Value(guid),
       createdAt = Value(createdAt);
  static Insertable<SrsNoteCacheRow> custom({
    Expression<String>? id,
    Expression<String>? profileUid,
    Expression<String>? noteTypeId,
    Expression<String>? guid,
    Expression<int>? createdAt,
    Expression<String>? deckId,
    Expression<int>? deletedAt,
    Expression<String>? termKey,
    Expression<String>? readingKey,
    Expression<String>? sortField,
    Expression<String>? tagsJson,
    Expression<bool>? pendingDecision,
    Expression<int>? updatedAt,
    Expression<String>? mediaRefs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileUid != null) 'profile_uid': profileUid,
      if (noteTypeId != null) 'note_type_id': noteTypeId,
      if (guid != null) 'guid': guid,
      if (createdAt != null) 'created_at': createdAt,
      if (deckId != null) 'deck_id': deckId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (termKey != null) 'term_key': termKey,
      if (readingKey != null) 'reading_key': readingKey,
      if (sortField != null) 'sort_field': sortField,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (pendingDecision != null) 'pending_decision': pendingDecision,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (mediaRefs != null) 'media_refs': mediaRefs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsNotesCacheCompanion copyWith({
    Value<String>? id,
    Value<String>? profileUid,
    Value<String>? noteTypeId,
    Value<String>? guid,
    Value<int>? createdAt,
    Value<String?>? deckId,
    Value<int?>? deletedAt,
    Value<String>? termKey,
    Value<String>? readingKey,
    Value<String>? sortField,
    Value<String>? tagsJson,
    Value<bool>? pendingDecision,
    Value<int>? updatedAt,
    Value<String>? mediaRefs,
    Value<int>? rowid,
  }) {
    return SrsNotesCacheCompanion(
      id: id ?? this.id,
      profileUid: profileUid ?? this.profileUid,
      noteTypeId: noteTypeId ?? this.noteTypeId,
      guid: guid ?? this.guid,
      createdAt: createdAt ?? this.createdAt,
      deckId: deckId ?? this.deckId,
      deletedAt: deletedAt ?? this.deletedAt,
      termKey: termKey ?? this.termKey,
      readingKey: readingKey ?? this.readingKey,
      sortField: sortField ?? this.sortField,
      tagsJson: tagsJson ?? this.tagsJson,
      pendingDecision: pendingDecision ?? this.pendingDecision,
      updatedAt: updatedAt ?? this.updatedAt,
      mediaRefs: mediaRefs ?? this.mediaRefs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (noteTypeId.present) {
      map['note_type_id'] = Variable<String>(noteTypeId.value);
    }
    if (guid.present) {
      map['guid'] = Variable<String>(guid.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (deckId.present) {
      map['deck_id'] = Variable<String>(deckId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (termKey.present) {
      map['term_key'] = Variable<String>(termKey.value);
    }
    if (readingKey.present) {
      map['reading_key'] = Variable<String>(readingKey.value);
    }
    if (sortField.present) {
      map['sort_field'] = Variable<String>(sortField.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (pendingDecision.present) {
      map['pending_decision'] = Variable<bool>(pendingDecision.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (mediaRefs.present) {
      map['media_refs'] = Variable<String>(mediaRefs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsNotesCacheCompanion(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('noteTypeId: $noteTypeId, ')
          ..write('guid: $guid, ')
          ..write('createdAt: $createdAt, ')
          ..write('deckId: $deckId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('termKey: $termKey, ')
          ..write('readingKey: $readingKey, ')
          ..write('sortField: $sortField, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('pendingDecision: $pendingDecision, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('mediaRefs: $mediaRefs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsCardsCacheTable extends SrsCardsCache
    with TableInfo<$SrsCardsCacheTable, SrsCardCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsCardsCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _noteIdMeta = const VerificationMeta('noteId');
  @override
  late final GeneratedColumn<String> noteId = GeneratedColumn<String>(
    'note_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _templateIdMeta = const VerificationMeta(
    'templateId',
  );
  @override
  late final GeneratedColumn<String> templateId = GeneratedColumn<String>(
    'template_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clozeOrdMeta = const VerificationMeta(
    'clozeOrd',
  );
  @override
  late final GeneratedColumn<int> clozeOrd = GeneratedColumn<int>(
    'cloze_ord',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _deckIdMeta = const VerificationMeta('deckId');
  @override
  late final GeneratedColumn<String> deckId = GeneratedColumn<String>(
    'deck_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _suspendedMeta = const VerificationMeta(
    'suspended',
  );
  @override
  late final GeneratedColumn<bool> suspended = GeneratedColumn<bool>(
    'suspended',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("suspended" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _buriedUntilDayMeta = const VerificationMeta(
    'buriedUntilDay',
  );
  @override
  late final GeneratedColumn<int> buriedUntilDay = GeneratedColumn<int>(
    'buried_until_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _flagMeta = const VerificationMeta('flag');
  @override
  late final GeneratedColumn<int> flag = GeneratedColumn<int>(
    'flag',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
    'hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _queueMeta = const VerificationMeta('queue');
  @override
  late final GeneratedColumn<String> queue = GeneratedColumn<String>(
    'queue',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('new'),
  );
  static const VerificationMeta _dueDayMeta = const VerificationMeta('dueDay');
  @override
  late final GeneratedColumn<int> dueDay = GeneratedColumn<int>(
    'due_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueAtMeta = const VerificationMeta('dueAt');
  @override
  late final GeneratedColumn<int> dueAt = GeneratedColumn<int>(
    'due_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scheduledDaysMeta = const VerificationMeta(
    'scheduledDays',
  );
  @override
  late final GeneratedColumn<int> scheduledDays = GeneratedColumn<int>(
    'scheduled_days',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _repsMeta = const VerificationMeta('reps');
  @override
  late final GeneratedColumn<int> reps = GeneratedColumn<int>(
    'reps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lapsesMeta = const VerificationMeta('lapses');
  @override
  late final GeneratedColumn<int> lapses = GeneratedColumn<int>(
    'lapses',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _stabilityMeta = const VerificationMeta(
    'stability',
  );
  @override
  late final GeneratedColumn<double> stability = GeneratedColumn<double>(
    'stability',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _difficultyMeta = const VerificationMeta(
    'difficulty',
  );
  @override
  late final GeneratedColumn<double> difficulty = GeneratedColumn<double>(
    'difficulty',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastReviewedAtMeta = const VerificationMeta(
    'lastReviewedAt',
  );
  @override
  late final GeneratedColumn<int> lastReviewedAt = GeneratedColumn<int>(
    'last_reviewed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastLogIdMeta = const VerificationMeta(
    'lastLogId',
  );
  @override
  late final GeneratedColumn<String> lastLogId = GeneratedColumn<String>(
    'last_log_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _schedulerMeta = const VerificationMeta(
    'scheduler',
  );
  @override
  late final GeneratedColumn<String> scheduler = GeneratedColumn<String>(
    'scheduler',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('fushi'),
  );
  static const VerificationMeta _noteCreatedAtMeta = const VerificationMeta(
    'noteCreatedAt',
  );
  @override
  late final GeneratedColumn<int> noteCreatedAt = GeneratedColumn<int>(
    'note_created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _newPositionMeta = const VerificationMeta(
    'newPosition',
  );
  @override
  late final GeneratedColumn<int> newPosition = GeneratedColumn<int>(
    'new_position',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _freqRankMeta = const VerificationMeta(
    'freqRank',
  );
  @override
  late final GeneratedColumn<int> freqRank = GeneratedColumn<int>(
    'freq_rank',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileUid,
    noteId,
    templateId,
    clozeOrd,
    deckId,
    suspended,
    buriedUntilDay,
    flag,
    hidden,
    queue,
    dueDay,
    dueAt,
    scheduledDays,
    reps,
    lapses,
    stability,
    difficulty,
    lastReviewedAt,
    lastLogId,
    scheduler,
    noteCreatedAt,
    newPosition,
    freqRank,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_cards_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsCardCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('note_id')) {
      context.handle(
        _noteIdMeta,
        noteId.isAcceptableOrUnknown(data['note_id']!, _noteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_noteIdMeta);
    }
    if (data.containsKey('template_id')) {
      context.handle(
        _templateIdMeta,
        templateId.isAcceptableOrUnknown(data['template_id']!, _templateIdMeta),
      );
    } else if (isInserting) {
      context.missing(_templateIdMeta);
    }
    if (data.containsKey('cloze_ord')) {
      context.handle(
        _clozeOrdMeta,
        clozeOrd.isAcceptableOrUnknown(data['cloze_ord']!, _clozeOrdMeta),
      );
    }
    if (data.containsKey('deck_id')) {
      context.handle(
        _deckIdMeta,
        deckId.isAcceptableOrUnknown(data['deck_id']!, _deckIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deckIdMeta);
    }
    if (data.containsKey('suspended')) {
      context.handle(
        _suspendedMeta,
        suspended.isAcceptableOrUnknown(data['suspended']!, _suspendedMeta),
      );
    }
    if (data.containsKey('buried_until_day')) {
      context.handle(
        _buriedUntilDayMeta,
        buriedUntilDay.isAcceptableOrUnknown(
          data['buried_until_day']!,
          _buriedUntilDayMeta,
        ),
      );
    }
    if (data.containsKey('flag')) {
      context.handle(
        _flagMeta,
        flag.isAcceptableOrUnknown(data['flag']!, _flagMeta),
      );
    }
    if (data.containsKey('hidden')) {
      context.handle(
        _hiddenMeta,
        hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta),
      );
    }
    if (data.containsKey('queue')) {
      context.handle(
        _queueMeta,
        queue.isAcceptableOrUnknown(data['queue']!, _queueMeta),
      );
    }
    if (data.containsKey('due_day')) {
      context.handle(
        _dueDayMeta,
        dueDay.isAcceptableOrUnknown(data['due_day']!, _dueDayMeta),
      );
    }
    if (data.containsKey('due_at')) {
      context.handle(
        _dueAtMeta,
        dueAt.isAcceptableOrUnknown(data['due_at']!, _dueAtMeta),
      );
    }
    if (data.containsKey('scheduled_days')) {
      context.handle(
        _scheduledDaysMeta,
        scheduledDays.isAcceptableOrUnknown(
          data['scheduled_days']!,
          _scheduledDaysMeta,
        ),
      );
    }
    if (data.containsKey('reps')) {
      context.handle(
        _repsMeta,
        reps.isAcceptableOrUnknown(data['reps']!, _repsMeta),
      );
    }
    if (data.containsKey('lapses')) {
      context.handle(
        _lapsesMeta,
        lapses.isAcceptableOrUnknown(data['lapses']!, _lapsesMeta),
      );
    }
    if (data.containsKey('stability')) {
      context.handle(
        _stabilityMeta,
        stability.isAcceptableOrUnknown(data['stability']!, _stabilityMeta),
      );
    }
    if (data.containsKey('difficulty')) {
      context.handle(
        _difficultyMeta,
        difficulty.isAcceptableOrUnknown(data['difficulty']!, _difficultyMeta),
      );
    }
    if (data.containsKey('last_reviewed_at')) {
      context.handle(
        _lastReviewedAtMeta,
        lastReviewedAt.isAcceptableOrUnknown(
          data['last_reviewed_at']!,
          _lastReviewedAtMeta,
        ),
      );
    }
    if (data.containsKey('last_log_id')) {
      context.handle(
        _lastLogIdMeta,
        lastLogId.isAcceptableOrUnknown(data['last_log_id']!, _lastLogIdMeta),
      );
    }
    if (data.containsKey('scheduler')) {
      context.handle(
        _schedulerMeta,
        scheduler.isAcceptableOrUnknown(data['scheduler']!, _schedulerMeta),
      );
    }
    if (data.containsKey('note_created_at')) {
      context.handle(
        _noteCreatedAtMeta,
        noteCreatedAt.isAcceptableOrUnknown(
          data['note_created_at']!,
          _noteCreatedAtMeta,
        ),
      );
    }
    if (data.containsKey('new_position')) {
      context.handle(
        _newPositionMeta,
        newPosition.isAcceptableOrUnknown(
          data['new_position']!,
          _newPositionMeta,
        ),
      );
    }
    if (data.containsKey('freq_rank')) {
      context.handle(
        _freqRankMeta,
        freqRank.isAcceptableOrUnknown(data['freq_rank']!, _freqRankMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrsCardCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsCardCacheRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      noteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note_id'],
      )!,
      templateId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}template_id'],
      )!,
      clozeOrd: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cloze_ord'],
      )!,
      deckId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deck_id'],
      )!,
      suspended: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}suspended'],
      )!,
      buriedUntilDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}buried_until_day'],
      ),
      flag: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}flag'],
      )!,
      hidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden'],
      )!,
      queue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}queue'],
      )!,
      dueDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_day'],
      ),
      dueAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_at'],
      ),
      scheduledDays: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scheduled_days'],
      )!,
      reps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reps'],
      )!,
      lapses: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}lapses'],
      )!,
      stability: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}stability'],
      ),
      difficulty: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}difficulty'],
      ),
      lastReviewedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_reviewed_at'],
      ),
      lastLogId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_log_id'],
      ),
      scheduler: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scheduler'],
      )!,
      noteCreatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}note_created_at'],
      )!,
      newPosition: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}new_position'],
      ),
      freqRank: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}freq_rank'],
      ),
    );
  }

  @override
  $SrsCardsCacheTable createAlias(String alias) {
    return $SrsCardsCacheTable(attachedDatabase, alias);
  }
}

class SrsCardCacheRow extends DataClass implements Insertable<SrsCardCacheRow> {
  final String id;
  final String profileUid;
  final String noteId;
  final String templateId;
  final int clozeOrd;
  final String deckId;
  final bool suspended;
  final int? buriedUntilDay;
  final int flag;

  /// 生成门（铁律 D，第六轮审查第 13 条）：笔记已删 / 模板已删 / 条件模板为空 / cN 已删时为真，
  /// 查询层据此不显示、不进队列，不写任何同步行。
  final bool hidden;
  final String queue;
  final int? dueDay;
  final int? dueAt;
  final int scheduledDays;
  final int reps;
  final int lapses;
  final double? stability;
  final double? difficulty;
  final int? lastReviewedAt;
  final String? lastLogId;
  final String scheduler;

  /// 新卡出卡顺序的兜底键（笔记 createdAt, cardId）：没有 [newPosition] 的新卡按它排。
  final int noteCreatedAt;

  /// v123：新卡在出卡队列里的位置（卡片修改记录 `newPos` 的生效值，「按词频重排新卡」
  /// 写它）。NULL = 从没排过：有位置的新卡先出（位置升序），没位置的排在后面并保持
  /// 原有的（笔记 createdAt, cardId）顺序——老数据出卡顺序不变。
  final int? newPosition;

  /// srs.db schema v8：笔记词频序字段（`SrsNoteTypeView.frequencyField`）解析出的名次，越小越常见；
  /// NULL = 没有。牌组「新卡顺序 = 按词频」时出卡按它升序，排在 [newPosition] 之前。由笔记派生、
  /// 随笔记刷新，不同步。
  final int? freqRank;
  const SrsCardCacheRow({
    required this.id,
    required this.profileUid,
    required this.noteId,
    required this.templateId,
    required this.clozeOrd,
    required this.deckId,
    required this.suspended,
    this.buriedUntilDay,
    required this.flag,
    required this.hidden,
    required this.queue,
    this.dueDay,
    this.dueAt,
    required this.scheduledDays,
    required this.reps,
    required this.lapses,
    this.stability,
    this.difficulty,
    this.lastReviewedAt,
    this.lastLogId,
    required this.scheduler,
    required this.noteCreatedAt,
    this.newPosition,
    this.freqRank,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['profile_uid'] = Variable<String>(profileUid);
    map['note_id'] = Variable<String>(noteId);
    map['template_id'] = Variable<String>(templateId);
    map['cloze_ord'] = Variable<int>(clozeOrd);
    map['deck_id'] = Variable<String>(deckId);
    map['suspended'] = Variable<bool>(suspended);
    if (!nullToAbsent || buriedUntilDay != null) {
      map['buried_until_day'] = Variable<int>(buriedUntilDay);
    }
    map['flag'] = Variable<int>(flag);
    map['hidden'] = Variable<bool>(hidden);
    map['queue'] = Variable<String>(queue);
    if (!nullToAbsent || dueDay != null) {
      map['due_day'] = Variable<int>(dueDay);
    }
    if (!nullToAbsent || dueAt != null) {
      map['due_at'] = Variable<int>(dueAt);
    }
    map['scheduled_days'] = Variable<int>(scheduledDays);
    map['reps'] = Variable<int>(reps);
    map['lapses'] = Variable<int>(lapses);
    if (!nullToAbsent || stability != null) {
      map['stability'] = Variable<double>(stability);
    }
    if (!nullToAbsent || difficulty != null) {
      map['difficulty'] = Variable<double>(difficulty);
    }
    if (!nullToAbsent || lastReviewedAt != null) {
      map['last_reviewed_at'] = Variable<int>(lastReviewedAt);
    }
    if (!nullToAbsent || lastLogId != null) {
      map['last_log_id'] = Variable<String>(lastLogId);
    }
    map['scheduler'] = Variable<String>(scheduler);
    map['note_created_at'] = Variable<int>(noteCreatedAt);
    if (!nullToAbsent || newPosition != null) {
      map['new_position'] = Variable<int>(newPosition);
    }
    if (!nullToAbsent || freqRank != null) {
      map['freq_rank'] = Variable<int>(freqRank);
    }
    return map;
  }

  SrsCardsCacheCompanion toCompanion(bool nullToAbsent) {
    return SrsCardsCacheCompanion(
      id: Value(id),
      profileUid: Value(profileUid),
      noteId: Value(noteId),
      templateId: Value(templateId),
      clozeOrd: Value(clozeOrd),
      deckId: Value(deckId),
      suspended: Value(suspended),
      buriedUntilDay: buriedUntilDay == null && nullToAbsent
          ? const Value.absent()
          : Value(buriedUntilDay),
      flag: Value(flag),
      hidden: Value(hidden),
      queue: Value(queue),
      dueDay: dueDay == null && nullToAbsent
          ? const Value.absent()
          : Value(dueDay),
      dueAt: dueAt == null && nullToAbsent
          ? const Value.absent()
          : Value(dueAt),
      scheduledDays: Value(scheduledDays),
      reps: Value(reps),
      lapses: Value(lapses),
      stability: stability == null && nullToAbsent
          ? const Value.absent()
          : Value(stability),
      difficulty: difficulty == null && nullToAbsent
          ? const Value.absent()
          : Value(difficulty),
      lastReviewedAt: lastReviewedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastReviewedAt),
      lastLogId: lastLogId == null && nullToAbsent
          ? const Value.absent()
          : Value(lastLogId),
      scheduler: Value(scheduler),
      noteCreatedAt: Value(noteCreatedAt),
      newPosition: newPosition == null && nullToAbsent
          ? const Value.absent()
          : Value(newPosition),
      freqRank: freqRank == null && nullToAbsent
          ? const Value.absent()
          : Value(freqRank),
    );
  }

  factory SrsCardCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsCardCacheRow(
      id: serializer.fromJson<String>(json['id']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      noteId: serializer.fromJson<String>(json['noteId']),
      templateId: serializer.fromJson<String>(json['templateId']),
      clozeOrd: serializer.fromJson<int>(json['clozeOrd']),
      deckId: serializer.fromJson<String>(json['deckId']),
      suspended: serializer.fromJson<bool>(json['suspended']),
      buriedUntilDay: serializer.fromJson<int?>(json['buriedUntilDay']),
      flag: serializer.fromJson<int>(json['flag']),
      hidden: serializer.fromJson<bool>(json['hidden']),
      queue: serializer.fromJson<String>(json['queue']),
      dueDay: serializer.fromJson<int?>(json['dueDay']),
      dueAt: serializer.fromJson<int?>(json['dueAt']),
      scheduledDays: serializer.fromJson<int>(json['scheduledDays']),
      reps: serializer.fromJson<int>(json['reps']),
      lapses: serializer.fromJson<int>(json['lapses']),
      stability: serializer.fromJson<double?>(json['stability']),
      difficulty: serializer.fromJson<double?>(json['difficulty']),
      lastReviewedAt: serializer.fromJson<int?>(json['lastReviewedAt']),
      lastLogId: serializer.fromJson<String?>(json['lastLogId']),
      scheduler: serializer.fromJson<String>(json['scheduler']),
      noteCreatedAt: serializer.fromJson<int>(json['noteCreatedAt']),
      newPosition: serializer.fromJson<int?>(json['newPosition']),
      freqRank: serializer.fromJson<int?>(json['freqRank']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'profileUid': serializer.toJson<String>(profileUid),
      'noteId': serializer.toJson<String>(noteId),
      'templateId': serializer.toJson<String>(templateId),
      'clozeOrd': serializer.toJson<int>(clozeOrd),
      'deckId': serializer.toJson<String>(deckId),
      'suspended': serializer.toJson<bool>(suspended),
      'buriedUntilDay': serializer.toJson<int?>(buriedUntilDay),
      'flag': serializer.toJson<int>(flag),
      'hidden': serializer.toJson<bool>(hidden),
      'queue': serializer.toJson<String>(queue),
      'dueDay': serializer.toJson<int?>(dueDay),
      'dueAt': serializer.toJson<int?>(dueAt),
      'scheduledDays': serializer.toJson<int>(scheduledDays),
      'reps': serializer.toJson<int>(reps),
      'lapses': serializer.toJson<int>(lapses),
      'stability': serializer.toJson<double?>(stability),
      'difficulty': serializer.toJson<double?>(difficulty),
      'lastReviewedAt': serializer.toJson<int?>(lastReviewedAt),
      'lastLogId': serializer.toJson<String?>(lastLogId),
      'scheduler': serializer.toJson<String>(scheduler),
      'noteCreatedAt': serializer.toJson<int>(noteCreatedAt),
      'newPosition': serializer.toJson<int?>(newPosition),
      'freqRank': serializer.toJson<int?>(freqRank),
    };
  }

  SrsCardCacheRow copyWith({
    String? id,
    String? profileUid,
    String? noteId,
    String? templateId,
    int? clozeOrd,
    String? deckId,
    bool? suspended,
    Value<int?> buriedUntilDay = const Value.absent(),
    int? flag,
    bool? hidden,
    String? queue,
    Value<int?> dueDay = const Value.absent(),
    Value<int?> dueAt = const Value.absent(),
    int? scheduledDays,
    int? reps,
    int? lapses,
    Value<double?> stability = const Value.absent(),
    Value<double?> difficulty = const Value.absent(),
    Value<int?> lastReviewedAt = const Value.absent(),
    Value<String?> lastLogId = const Value.absent(),
    String? scheduler,
    int? noteCreatedAt,
    Value<int?> newPosition = const Value.absent(),
    Value<int?> freqRank = const Value.absent(),
  }) => SrsCardCacheRow(
    id: id ?? this.id,
    profileUid: profileUid ?? this.profileUid,
    noteId: noteId ?? this.noteId,
    templateId: templateId ?? this.templateId,
    clozeOrd: clozeOrd ?? this.clozeOrd,
    deckId: deckId ?? this.deckId,
    suspended: suspended ?? this.suspended,
    buriedUntilDay: buriedUntilDay.present
        ? buriedUntilDay.value
        : this.buriedUntilDay,
    flag: flag ?? this.flag,
    hidden: hidden ?? this.hidden,
    queue: queue ?? this.queue,
    dueDay: dueDay.present ? dueDay.value : this.dueDay,
    dueAt: dueAt.present ? dueAt.value : this.dueAt,
    scheduledDays: scheduledDays ?? this.scheduledDays,
    reps: reps ?? this.reps,
    lapses: lapses ?? this.lapses,
    stability: stability.present ? stability.value : this.stability,
    difficulty: difficulty.present ? difficulty.value : this.difficulty,
    lastReviewedAt: lastReviewedAt.present
        ? lastReviewedAt.value
        : this.lastReviewedAt,
    lastLogId: lastLogId.present ? lastLogId.value : this.lastLogId,
    scheduler: scheduler ?? this.scheduler,
    noteCreatedAt: noteCreatedAt ?? this.noteCreatedAt,
    newPosition: newPosition.present ? newPosition.value : this.newPosition,
    freqRank: freqRank.present ? freqRank.value : this.freqRank,
  );
  SrsCardCacheRow copyWithCompanion(SrsCardsCacheCompanion data) {
    return SrsCardCacheRow(
      id: data.id.present ? data.id.value : this.id,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      noteId: data.noteId.present ? data.noteId.value : this.noteId,
      templateId: data.templateId.present
          ? data.templateId.value
          : this.templateId,
      clozeOrd: data.clozeOrd.present ? data.clozeOrd.value : this.clozeOrd,
      deckId: data.deckId.present ? data.deckId.value : this.deckId,
      suspended: data.suspended.present ? data.suspended.value : this.suspended,
      buriedUntilDay: data.buriedUntilDay.present
          ? data.buriedUntilDay.value
          : this.buriedUntilDay,
      flag: data.flag.present ? data.flag.value : this.flag,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
      queue: data.queue.present ? data.queue.value : this.queue,
      dueDay: data.dueDay.present ? data.dueDay.value : this.dueDay,
      dueAt: data.dueAt.present ? data.dueAt.value : this.dueAt,
      scheduledDays: data.scheduledDays.present
          ? data.scheduledDays.value
          : this.scheduledDays,
      reps: data.reps.present ? data.reps.value : this.reps,
      lapses: data.lapses.present ? data.lapses.value : this.lapses,
      stability: data.stability.present ? data.stability.value : this.stability,
      difficulty: data.difficulty.present
          ? data.difficulty.value
          : this.difficulty,
      lastReviewedAt: data.lastReviewedAt.present
          ? data.lastReviewedAt.value
          : this.lastReviewedAt,
      lastLogId: data.lastLogId.present ? data.lastLogId.value : this.lastLogId,
      scheduler: data.scheduler.present ? data.scheduler.value : this.scheduler,
      noteCreatedAt: data.noteCreatedAt.present
          ? data.noteCreatedAt.value
          : this.noteCreatedAt,
      newPosition: data.newPosition.present
          ? data.newPosition.value
          : this.newPosition,
      freqRank: data.freqRank.present ? data.freqRank.value : this.freqRank,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsCardCacheRow(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('noteId: $noteId, ')
          ..write('templateId: $templateId, ')
          ..write('clozeOrd: $clozeOrd, ')
          ..write('deckId: $deckId, ')
          ..write('suspended: $suspended, ')
          ..write('buriedUntilDay: $buriedUntilDay, ')
          ..write('flag: $flag, ')
          ..write('hidden: $hidden, ')
          ..write('queue: $queue, ')
          ..write('dueDay: $dueDay, ')
          ..write('dueAt: $dueAt, ')
          ..write('scheduledDays: $scheduledDays, ')
          ..write('reps: $reps, ')
          ..write('lapses: $lapses, ')
          ..write('stability: $stability, ')
          ..write('difficulty: $difficulty, ')
          ..write('lastReviewedAt: $lastReviewedAt, ')
          ..write('lastLogId: $lastLogId, ')
          ..write('scheduler: $scheduler, ')
          ..write('noteCreatedAt: $noteCreatedAt, ')
          ..write('newPosition: $newPosition, ')
          ..write('freqRank: $freqRank')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    profileUid,
    noteId,
    templateId,
    clozeOrd,
    deckId,
    suspended,
    buriedUntilDay,
    flag,
    hidden,
    queue,
    dueDay,
    dueAt,
    scheduledDays,
    reps,
    lapses,
    stability,
    difficulty,
    lastReviewedAt,
    lastLogId,
    scheduler,
    noteCreatedAt,
    newPosition,
    freqRank,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsCardCacheRow &&
          other.id == this.id &&
          other.profileUid == this.profileUid &&
          other.noteId == this.noteId &&
          other.templateId == this.templateId &&
          other.clozeOrd == this.clozeOrd &&
          other.deckId == this.deckId &&
          other.suspended == this.suspended &&
          other.buriedUntilDay == this.buriedUntilDay &&
          other.flag == this.flag &&
          other.hidden == this.hidden &&
          other.queue == this.queue &&
          other.dueDay == this.dueDay &&
          other.dueAt == this.dueAt &&
          other.scheduledDays == this.scheduledDays &&
          other.reps == this.reps &&
          other.lapses == this.lapses &&
          other.stability == this.stability &&
          other.difficulty == this.difficulty &&
          other.lastReviewedAt == this.lastReviewedAt &&
          other.lastLogId == this.lastLogId &&
          other.scheduler == this.scheduler &&
          other.noteCreatedAt == this.noteCreatedAt &&
          other.newPosition == this.newPosition &&
          other.freqRank == this.freqRank);
}

class SrsCardsCacheCompanion extends UpdateCompanion<SrsCardCacheRow> {
  final Value<String> id;
  final Value<String> profileUid;
  final Value<String> noteId;
  final Value<String> templateId;
  final Value<int> clozeOrd;
  final Value<String> deckId;
  final Value<bool> suspended;
  final Value<int?> buriedUntilDay;
  final Value<int> flag;
  final Value<bool> hidden;
  final Value<String> queue;
  final Value<int?> dueDay;
  final Value<int?> dueAt;
  final Value<int> scheduledDays;
  final Value<int> reps;
  final Value<int> lapses;
  final Value<double?> stability;
  final Value<double?> difficulty;
  final Value<int?> lastReviewedAt;
  final Value<String?> lastLogId;
  final Value<String> scheduler;
  final Value<int> noteCreatedAt;
  final Value<int?> newPosition;
  final Value<int?> freqRank;
  final Value<int> rowid;
  const SrsCardsCacheCompanion({
    this.id = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.noteId = const Value.absent(),
    this.templateId = const Value.absent(),
    this.clozeOrd = const Value.absent(),
    this.deckId = const Value.absent(),
    this.suspended = const Value.absent(),
    this.buriedUntilDay = const Value.absent(),
    this.flag = const Value.absent(),
    this.hidden = const Value.absent(),
    this.queue = const Value.absent(),
    this.dueDay = const Value.absent(),
    this.dueAt = const Value.absent(),
    this.scheduledDays = const Value.absent(),
    this.reps = const Value.absent(),
    this.lapses = const Value.absent(),
    this.stability = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.lastReviewedAt = const Value.absent(),
    this.lastLogId = const Value.absent(),
    this.scheduler = const Value.absent(),
    this.noteCreatedAt = const Value.absent(),
    this.newPosition = const Value.absent(),
    this.freqRank = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsCardsCacheCompanion.insert({
    required String id,
    required String profileUid,
    required String noteId,
    required String templateId,
    this.clozeOrd = const Value.absent(),
    required String deckId,
    this.suspended = const Value.absent(),
    this.buriedUntilDay = const Value.absent(),
    this.flag = const Value.absent(),
    this.hidden = const Value.absent(),
    this.queue = const Value.absent(),
    this.dueDay = const Value.absent(),
    this.dueAt = const Value.absent(),
    this.scheduledDays = const Value.absent(),
    this.reps = const Value.absent(),
    this.lapses = const Value.absent(),
    this.stability = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.lastReviewedAt = const Value.absent(),
    this.lastLogId = const Value.absent(),
    this.scheduler = const Value.absent(),
    this.noteCreatedAt = const Value.absent(),
    this.newPosition = const Value.absent(),
    this.freqRank = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       profileUid = Value(profileUid),
       noteId = Value(noteId),
       templateId = Value(templateId),
       deckId = Value(deckId);
  static Insertable<SrsCardCacheRow> custom({
    Expression<String>? id,
    Expression<String>? profileUid,
    Expression<String>? noteId,
    Expression<String>? templateId,
    Expression<int>? clozeOrd,
    Expression<String>? deckId,
    Expression<bool>? suspended,
    Expression<int>? buriedUntilDay,
    Expression<int>? flag,
    Expression<bool>? hidden,
    Expression<String>? queue,
    Expression<int>? dueDay,
    Expression<int>? dueAt,
    Expression<int>? scheduledDays,
    Expression<int>? reps,
    Expression<int>? lapses,
    Expression<double>? stability,
    Expression<double>? difficulty,
    Expression<int>? lastReviewedAt,
    Expression<String>? lastLogId,
    Expression<String>? scheduler,
    Expression<int>? noteCreatedAt,
    Expression<int>? newPosition,
    Expression<int>? freqRank,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileUid != null) 'profile_uid': profileUid,
      if (noteId != null) 'note_id': noteId,
      if (templateId != null) 'template_id': templateId,
      if (clozeOrd != null) 'cloze_ord': clozeOrd,
      if (deckId != null) 'deck_id': deckId,
      if (suspended != null) 'suspended': suspended,
      if (buriedUntilDay != null) 'buried_until_day': buriedUntilDay,
      if (flag != null) 'flag': flag,
      if (hidden != null) 'hidden': hidden,
      if (queue != null) 'queue': queue,
      if (dueDay != null) 'due_day': dueDay,
      if (dueAt != null) 'due_at': dueAt,
      if (scheduledDays != null) 'scheduled_days': scheduledDays,
      if (reps != null) 'reps': reps,
      if (lapses != null) 'lapses': lapses,
      if (stability != null) 'stability': stability,
      if (difficulty != null) 'difficulty': difficulty,
      if (lastReviewedAt != null) 'last_reviewed_at': lastReviewedAt,
      if (lastLogId != null) 'last_log_id': lastLogId,
      if (scheduler != null) 'scheduler': scheduler,
      if (noteCreatedAt != null) 'note_created_at': noteCreatedAt,
      if (newPosition != null) 'new_position': newPosition,
      if (freqRank != null) 'freq_rank': freqRank,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsCardsCacheCompanion copyWith({
    Value<String>? id,
    Value<String>? profileUid,
    Value<String>? noteId,
    Value<String>? templateId,
    Value<int>? clozeOrd,
    Value<String>? deckId,
    Value<bool>? suspended,
    Value<int?>? buriedUntilDay,
    Value<int>? flag,
    Value<bool>? hidden,
    Value<String>? queue,
    Value<int?>? dueDay,
    Value<int?>? dueAt,
    Value<int>? scheduledDays,
    Value<int>? reps,
    Value<int>? lapses,
    Value<double?>? stability,
    Value<double?>? difficulty,
    Value<int?>? lastReviewedAt,
    Value<String?>? lastLogId,
    Value<String>? scheduler,
    Value<int>? noteCreatedAt,
    Value<int?>? newPosition,
    Value<int?>? freqRank,
    Value<int>? rowid,
  }) {
    return SrsCardsCacheCompanion(
      id: id ?? this.id,
      profileUid: profileUid ?? this.profileUid,
      noteId: noteId ?? this.noteId,
      templateId: templateId ?? this.templateId,
      clozeOrd: clozeOrd ?? this.clozeOrd,
      deckId: deckId ?? this.deckId,
      suspended: suspended ?? this.suspended,
      buriedUntilDay: buriedUntilDay ?? this.buriedUntilDay,
      flag: flag ?? this.flag,
      hidden: hidden ?? this.hidden,
      queue: queue ?? this.queue,
      dueDay: dueDay ?? this.dueDay,
      dueAt: dueAt ?? this.dueAt,
      scheduledDays: scheduledDays ?? this.scheduledDays,
      reps: reps ?? this.reps,
      lapses: lapses ?? this.lapses,
      stability: stability ?? this.stability,
      difficulty: difficulty ?? this.difficulty,
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
      lastLogId: lastLogId ?? this.lastLogId,
      scheduler: scheduler ?? this.scheduler,
      noteCreatedAt: noteCreatedAt ?? this.noteCreatedAt,
      newPosition: newPosition ?? this.newPosition,
      freqRank: freqRank ?? this.freqRank,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (noteId.present) {
      map['note_id'] = Variable<String>(noteId.value);
    }
    if (templateId.present) {
      map['template_id'] = Variable<String>(templateId.value);
    }
    if (clozeOrd.present) {
      map['cloze_ord'] = Variable<int>(clozeOrd.value);
    }
    if (deckId.present) {
      map['deck_id'] = Variable<String>(deckId.value);
    }
    if (suspended.present) {
      map['suspended'] = Variable<bool>(suspended.value);
    }
    if (buriedUntilDay.present) {
      map['buried_until_day'] = Variable<int>(buriedUntilDay.value);
    }
    if (flag.present) {
      map['flag'] = Variable<int>(flag.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    if (queue.present) {
      map['queue'] = Variable<String>(queue.value);
    }
    if (dueDay.present) {
      map['due_day'] = Variable<int>(dueDay.value);
    }
    if (dueAt.present) {
      map['due_at'] = Variable<int>(dueAt.value);
    }
    if (scheduledDays.present) {
      map['scheduled_days'] = Variable<int>(scheduledDays.value);
    }
    if (reps.present) {
      map['reps'] = Variable<int>(reps.value);
    }
    if (lapses.present) {
      map['lapses'] = Variable<int>(lapses.value);
    }
    if (stability.present) {
      map['stability'] = Variable<double>(stability.value);
    }
    if (difficulty.present) {
      map['difficulty'] = Variable<double>(difficulty.value);
    }
    if (lastReviewedAt.present) {
      map['last_reviewed_at'] = Variable<int>(lastReviewedAt.value);
    }
    if (lastLogId.present) {
      map['last_log_id'] = Variable<String>(lastLogId.value);
    }
    if (scheduler.present) {
      map['scheduler'] = Variable<String>(scheduler.value);
    }
    if (noteCreatedAt.present) {
      map['note_created_at'] = Variable<int>(noteCreatedAt.value);
    }
    if (newPosition.present) {
      map['new_position'] = Variable<int>(newPosition.value);
    }
    if (freqRank.present) {
      map['freq_rank'] = Variable<int>(freqRank.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsCardsCacheCompanion(')
          ..write('id: $id, ')
          ..write('profileUid: $profileUid, ')
          ..write('noteId: $noteId, ')
          ..write('templateId: $templateId, ')
          ..write('clozeOrd: $clozeOrd, ')
          ..write('deckId: $deckId, ')
          ..write('suspended: $suspended, ')
          ..write('buriedUntilDay: $buriedUntilDay, ')
          ..write('flag: $flag, ')
          ..write('hidden: $hidden, ')
          ..write('queue: $queue, ')
          ..write('dueDay: $dueDay, ')
          ..write('dueAt: $dueAt, ')
          ..write('scheduledDays: $scheduledDays, ')
          ..write('reps: $reps, ')
          ..write('lapses: $lapses, ')
          ..write('stability: $stability, ')
          ..write('difficulty: $difficulty, ')
          ..write('lastReviewedAt: $lastReviewedAt, ')
          ..write('lastLogId: $lastLogId, ')
          ..write('scheduler: $scheduler, ')
          ..write('noteCreatedAt: $noteCreatedAt, ')
          ..write('newPosition: $newPosition, ')
          ..write('freqRank: $freqRank, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SrsStatReviewsTable extends SrsStatReviews
    with TableInfo<$SrsStatReviewsTable, SrsStatReviewRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrsStatReviewsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _logIdMeta = const VerificationMeta('logId');
  @override
  late final GeneratedColumn<String> logId = GeneratedColumn<String>(
    'log_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _profileUidMeta = const VerificationMeta(
    'profileUid',
  );
  @override
  late final GeneratedColumn<String> profileUid = GeneratedColumn<String>(
    'profile_uid',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cardIdMeta = const VerificationMeta('cardId');
  @override
  late final GeneratedColumn<String> cardId = GeneratedColumn<String>(
    'card_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _occurredAtMeta = const VerificationMeta(
    'occurredAt',
  );
  @override
  late final GeneratedColumn<int> occurredAt = GeneratedColumn<int>(
    'occurred_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _utcOffsetMinMeta = const VerificationMeta(
    'utcOffsetMin',
  );
  @override
  late final GeneratedColumn<int> utcOffsetMin = GeneratedColumn<int>(
    'utc_offset_min',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<int> rating = GeneratedColumn<int>(
    'rating',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<int> kind = GeneratedColumn<int>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _prevDueDayMeta = const VerificationMeta(
    'prevDueDay',
  );
  @override
  late final GeneratedColumn<int> prevDueDay = GeneratedColumn<int>(
    'prev_due_day',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _maturityDeltaMeta = const VerificationMeta(
    'maturityDelta',
  );
  @override
  late final GeneratedColumn<int> maturityDelta = GeneratedColumn<int>(
    'maturity_delta',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    logId,
    profileUid,
    cardId,
    occurredAt,
    utcOffsetMin,
    rating,
    kind,
    durationMs,
    prevDueDay,
    maturityDelta,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srs_stat_reviews';
  @override
  VerificationContext validateIntegrity(
    Insertable<SrsStatReviewRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('log_id')) {
      context.handle(
        _logIdMeta,
        logId.isAcceptableOrUnknown(data['log_id']!, _logIdMeta),
      );
    } else if (isInserting) {
      context.missing(_logIdMeta);
    }
    if (data.containsKey('profile_uid')) {
      context.handle(
        _profileUidMeta,
        profileUid.isAcceptableOrUnknown(data['profile_uid']!, _profileUidMeta),
      );
    } else if (isInserting) {
      context.missing(_profileUidMeta);
    }
    if (data.containsKey('card_id')) {
      context.handle(
        _cardIdMeta,
        cardId.isAcceptableOrUnknown(data['card_id']!, _cardIdMeta),
      );
    } else if (isInserting) {
      context.missing(_cardIdMeta);
    }
    if (data.containsKey('occurred_at')) {
      context.handle(
        _occurredAtMeta,
        occurredAt.isAcceptableOrUnknown(data['occurred_at']!, _occurredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_occurredAtMeta);
    }
    if (data.containsKey('utc_offset_min')) {
      context.handle(
        _utcOffsetMinMeta,
        utcOffsetMin.isAcceptableOrUnknown(
          data['utc_offset_min']!,
          _utcOffsetMinMeta,
        ),
      );
    }
    if (data.containsKey('rating')) {
      context.handle(
        _ratingMeta,
        rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('prev_due_day')) {
      context.handle(
        _prevDueDayMeta,
        prevDueDay.isAcceptableOrUnknown(
          data['prev_due_day']!,
          _prevDueDayMeta,
        ),
      );
    }
    if (data.containsKey('maturity_delta')) {
      context.handle(
        _maturityDeltaMeta,
        maturityDelta.isAcceptableOrUnknown(
          data['maturity_delta']!,
          _maturityDeltaMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {logId};
  @override
  SrsStatReviewRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrsStatReviewRow(
      logId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}log_id'],
      )!,
      profileUid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_uid'],
      )!,
      cardId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_id'],
      )!,
      occurredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}occurred_at'],
      )!,
      utcOffsetMin: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}utc_offset_min'],
      )!,
      rating: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rating'],
      ),
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}kind'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      prevDueDay: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prev_due_day'],
      ),
      maturityDelta: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}maturity_delta'],
      )!,
    );
  }

  @override
  $SrsStatReviewsTable createAlias(String alias) {
    return $SrsStatReviewsTable(attachedDatabase, alias);
  }
}

class SrsStatReviewRow extends DataClass
    implements Insertable<SrsStatReviewRow> {
  final String logId;
  final String profileUid;
  final String cardId;
  final int occurredAt;
  final int utcOffsetMin;
  final int? rating;
  final int kind;
  final int durationMs;

  /// 复习卡按到期日排的评分复习：上一条有效结果的到期日（读时与当天比得出「提前复习」）；
  /// 其余 null。
  final int? prevDueDay;

  /// +1 = 这条日志后变成熟，−1 = 掉出成熟，0 = 不变。
  final int maturityDelta;
  const SrsStatReviewRow({
    required this.logId,
    required this.profileUid,
    required this.cardId,
    required this.occurredAt,
    required this.utcOffsetMin,
    this.rating,
    required this.kind,
    required this.durationMs,
    this.prevDueDay,
    required this.maturityDelta,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['log_id'] = Variable<String>(logId);
    map['profile_uid'] = Variable<String>(profileUid);
    map['card_id'] = Variable<String>(cardId);
    map['occurred_at'] = Variable<int>(occurredAt);
    map['utc_offset_min'] = Variable<int>(utcOffsetMin);
    if (!nullToAbsent || rating != null) {
      map['rating'] = Variable<int>(rating);
    }
    map['kind'] = Variable<int>(kind);
    map['duration_ms'] = Variable<int>(durationMs);
    if (!nullToAbsent || prevDueDay != null) {
      map['prev_due_day'] = Variable<int>(prevDueDay);
    }
    map['maturity_delta'] = Variable<int>(maturityDelta);
    return map;
  }

  SrsStatReviewsCompanion toCompanion(bool nullToAbsent) {
    return SrsStatReviewsCompanion(
      logId: Value(logId),
      profileUid: Value(profileUid),
      cardId: Value(cardId),
      occurredAt: Value(occurredAt),
      utcOffsetMin: Value(utcOffsetMin),
      rating: rating == null && nullToAbsent
          ? const Value.absent()
          : Value(rating),
      kind: Value(kind),
      durationMs: Value(durationMs),
      prevDueDay: prevDueDay == null && nullToAbsent
          ? const Value.absent()
          : Value(prevDueDay),
      maturityDelta: Value(maturityDelta),
    );
  }

  factory SrsStatReviewRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrsStatReviewRow(
      logId: serializer.fromJson<String>(json['logId']),
      profileUid: serializer.fromJson<String>(json['profileUid']),
      cardId: serializer.fromJson<String>(json['cardId']),
      occurredAt: serializer.fromJson<int>(json['occurredAt']),
      utcOffsetMin: serializer.fromJson<int>(json['utcOffsetMin']),
      rating: serializer.fromJson<int?>(json['rating']),
      kind: serializer.fromJson<int>(json['kind']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      prevDueDay: serializer.fromJson<int?>(json['prevDueDay']),
      maturityDelta: serializer.fromJson<int>(json['maturityDelta']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'logId': serializer.toJson<String>(logId),
      'profileUid': serializer.toJson<String>(profileUid),
      'cardId': serializer.toJson<String>(cardId),
      'occurredAt': serializer.toJson<int>(occurredAt),
      'utcOffsetMin': serializer.toJson<int>(utcOffsetMin),
      'rating': serializer.toJson<int?>(rating),
      'kind': serializer.toJson<int>(kind),
      'durationMs': serializer.toJson<int>(durationMs),
      'prevDueDay': serializer.toJson<int?>(prevDueDay),
      'maturityDelta': serializer.toJson<int>(maturityDelta),
    };
  }

  SrsStatReviewRow copyWith({
    String? logId,
    String? profileUid,
    String? cardId,
    int? occurredAt,
    int? utcOffsetMin,
    Value<int?> rating = const Value.absent(),
    int? kind,
    int? durationMs,
    Value<int?> prevDueDay = const Value.absent(),
    int? maturityDelta,
  }) => SrsStatReviewRow(
    logId: logId ?? this.logId,
    profileUid: profileUid ?? this.profileUid,
    cardId: cardId ?? this.cardId,
    occurredAt: occurredAt ?? this.occurredAt,
    utcOffsetMin: utcOffsetMin ?? this.utcOffsetMin,
    rating: rating.present ? rating.value : this.rating,
    kind: kind ?? this.kind,
    durationMs: durationMs ?? this.durationMs,
    prevDueDay: prevDueDay.present ? prevDueDay.value : this.prevDueDay,
    maturityDelta: maturityDelta ?? this.maturityDelta,
  );
  SrsStatReviewRow copyWithCompanion(SrsStatReviewsCompanion data) {
    return SrsStatReviewRow(
      logId: data.logId.present ? data.logId.value : this.logId,
      profileUid: data.profileUid.present
          ? data.profileUid.value
          : this.profileUid,
      cardId: data.cardId.present ? data.cardId.value : this.cardId,
      occurredAt: data.occurredAt.present
          ? data.occurredAt.value
          : this.occurredAt,
      utcOffsetMin: data.utcOffsetMin.present
          ? data.utcOffsetMin.value
          : this.utcOffsetMin,
      rating: data.rating.present ? data.rating.value : this.rating,
      kind: data.kind.present ? data.kind.value : this.kind,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      prevDueDay: data.prevDueDay.present
          ? data.prevDueDay.value
          : this.prevDueDay,
      maturityDelta: data.maturityDelta.present
          ? data.maturityDelta.value
          : this.maturityDelta,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrsStatReviewRow(')
          ..write('logId: $logId, ')
          ..write('profileUid: $profileUid, ')
          ..write('cardId: $cardId, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('utcOffsetMin: $utcOffsetMin, ')
          ..write('rating: $rating, ')
          ..write('kind: $kind, ')
          ..write('durationMs: $durationMs, ')
          ..write('prevDueDay: $prevDueDay, ')
          ..write('maturityDelta: $maturityDelta')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    logId,
    profileUid,
    cardId,
    occurredAt,
    utcOffsetMin,
    rating,
    kind,
    durationMs,
    prevDueDay,
    maturityDelta,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrsStatReviewRow &&
          other.logId == this.logId &&
          other.profileUid == this.profileUid &&
          other.cardId == this.cardId &&
          other.occurredAt == this.occurredAt &&
          other.utcOffsetMin == this.utcOffsetMin &&
          other.rating == this.rating &&
          other.kind == this.kind &&
          other.durationMs == this.durationMs &&
          other.prevDueDay == this.prevDueDay &&
          other.maturityDelta == this.maturityDelta);
}

class SrsStatReviewsCompanion extends UpdateCompanion<SrsStatReviewRow> {
  final Value<String> logId;
  final Value<String> profileUid;
  final Value<String> cardId;
  final Value<int> occurredAt;
  final Value<int> utcOffsetMin;
  final Value<int?> rating;
  final Value<int> kind;
  final Value<int> durationMs;
  final Value<int?> prevDueDay;
  final Value<int> maturityDelta;
  final Value<int> rowid;
  const SrsStatReviewsCompanion({
    this.logId = const Value.absent(),
    this.profileUid = const Value.absent(),
    this.cardId = const Value.absent(),
    this.occurredAt = const Value.absent(),
    this.utcOffsetMin = const Value.absent(),
    this.rating = const Value.absent(),
    this.kind = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.prevDueDay = const Value.absent(),
    this.maturityDelta = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SrsStatReviewsCompanion.insert({
    required String logId,
    required String profileUid,
    required String cardId,
    required int occurredAt,
    this.utcOffsetMin = const Value.absent(),
    this.rating = const Value.absent(),
    this.kind = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.prevDueDay = const Value.absent(),
    this.maturityDelta = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : logId = Value(logId),
       profileUid = Value(profileUid),
       cardId = Value(cardId),
       occurredAt = Value(occurredAt);
  static Insertable<SrsStatReviewRow> custom({
    Expression<String>? logId,
    Expression<String>? profileUid,
    Expression<String>? cardId,
    Expression<int>? occurredAt,
    Expression<int>? utcOffsetMin,
    Expression<int>? rating,
    Expression<int>? kind,
    Expression<int>? durationMs,
    Expression<int>? prevDueDay,
    Expression<int>? maturityDelta,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (logId != null) 'log_id': logId,
      if (profileUid != null) 'profile_uid': profileUid,
      if (cardId != null) 'card_id': cardId,
      if (occurredAt != null) 'occurred_at': occurredAt,
      if (utcOffsetMin != null) 'utc_offset_min': utcOffsetMin,
      if (rating != null) 'rating': rating,
      if (kind != null) 'kind': kind,
      if (durationMs != null) 'duration_ms': durationMs,
      if (prevDueDay != null) 'prev_due_day': prevDueDay,
      if (maturityDelta != null) 'maturity_delta': maturityDelta,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SrsStatReviewsCompanion copyWith({
    Value<String>? logId,
    Value<String>? profileUid,
    Value<String>? cardId,
    Value<int>? occurredAt,
    Value<int>? utcOffsetMin,
    Value<int?>? rating,
    Value<int>? kind,
    Value<int>? durationMs,
    Value<int?>? prevDueDay,
    Value<int>? maturityDelta,
    Value<int>? rowid,
  }) {
    return SrsStatReviewsCompanion(
      logId: logId ?? this.logId,
      profileUid: profileUid ?? this.profileUid,
      cardId: cardId ?? this.cardId,
      occurredAt: occurredAt ?? this.occurredAt,
      utcOffsetMin: utcOffsetMin ?? this.utcOffsetMin,
      rating: rating ?? this.rating,
      kind: kind ?? this.kind,
      durationMs: durationMs ?? this.durationMs,
      prevDueDay: prevDueDay ?? this.prevDueDay,
      maturityDelta: maturityDelta ?? this.maturityDelta,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (logId.present) {
      map['log_id'] = Variable<String>(logId.value);
    }
    if (profileUid.present) {
      map['profile_uid'] = Variable<String>(profileUid.value);
    }
    if (cardId.present) {
      map['card_id'] = Variable<String>(cardId.value);
    }
    if (occurredAt.present) {
      map['occurred_at'] = Variable<int>(occurredAt.value);
    }
    if (utcOffsetMin.present) {
      map['utc_offset_min'] = Variable<int>(utcOffsetMin.value);
    }
    if (rating.present) {
      map['rating'] = Variable<int>(rating.value);
    }
    if (kind.present) {
      map['kind'] = Variable<int>(kind.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (prevDueDay.present) {
      map['prev_due_day'] = Variable<int>(prevDueDay.value);
    }
    if (maturityDelta.present) {
      map['maturity_delta'] = Variable<int>(maturityDelta.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrsStatReviewsCompanion(')
          ..write('logId: $logId, ')
          ..write('profileUid: $profileUid, ')
          ..write('cardId: $cardId, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('utcOffsetMin: $utcOffsetMin, ')
          ..write('rating: $rating, ')
          ..write('kind: $kind, ')
          ..write('durationMs: $durationMs, ')
          ..write('prevDueDay: $prevDueDay, ')
          ..write('maturityDelta: $maturityDelta, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$SrsDatabase extends GeneratedDatabase {
  _$SrsDatabase(QueryExecutor e) : super(e);
  $SrsDatabaseManager get managers => $SrsDatabaseManager(this);
  late final $SrsEntitiesTable srsEntities = $SrsEntitiesTable(this);
  late final $SrsFieldEditsTable srsFieldEdits = $SrsFieldEditsTable(this);
  late final $SrsReviewLogsTable srsReviewLogs = $SrsReviewLogsTable(this);
  late final $SrsUnknownEventsTable srsUnknownEvents = $SrsUnknownEventsTable(
    this,
  );
  late final $SrsEventLocalTable srsEventLocal = $SrsEventLocalTable(this);
  late final $SrsLocalStateTable srsLocalState = $SrsLocalStateTable(this);
  late final $SrsSentBatchesTable srsSentBatches = $SrsSentBatchesTable(this);
  late final $SrsNotesCacheTable srsNotesCache = $SrsNotesCacheTable(this);
  late final $SrsCardsCacheTable srsCardsCache = $SrsCardsCacheTable(this);
  late final $SrsStatReviewsTable srsStatReviews = $SrsStatReviewsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    srsEntities,
    srsFieldEdits,
    srsReviewLogs,
    srsUnknownEvents,
    srsEventLocal,
    srsLocalState,
    srsSentBatches,
    srsNotesCache,
    srsCardsCache,
    srsStatReviews,
  ];
}

typedef $$SrsEntitiesTableCreateCompanionBuilder =
    SrsEntitiesCompanion Function({
      required String id,
      required String profileUid,
      required String kind,
      required String payloadJson,
      Value<int> createdAt,
      Value<int> rowid,
    });
typedef $$SrsEntitiesTableUpdateCompanionBuilder =
    SrsEntitiesCompanion Function({
      Value<String> id,
      Value<String> profileUid,
      Value<String> kind,
      Value<String> payloadJson,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$SrsEntitiesTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsEntitiesTable> {
  $$SrsEntitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsEntitiesTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsEntitiesTable> {
  $$SrsEntitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsEntitiesTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsEntitiesTable> {
  $$SrsEntitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$SrsEntitiesTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsEntitiesTable,
          SrsEntityRow,
          $$SrsEntitiesTableFilterComposer,
          $$SrsEntitiesTableOrderingComposer,
          $$SrsEntitiesTableAnnotationComposer,
          $$SrsEntitiesTableCreateCompanionBuilder,
          $$SrsEntitiesTableUpdateCompanionBuilder,
          (
            SrsEntityRow,
            BaseReferences<_$SrsDatabase, $SrsEntitiesTable, SrsEntityRow>,
          ),
          SrsEntityRow,
          PrefetchHooks Function()
        > {
  $$SrsEntitiesTableTableManager(_$SrsDatabase db, $SrsEntitiesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsEntitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsEntitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsEntitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsEntitiesCompanion(
                id: id,
                profileUid: profileUid,
                kind: kind,
                payloadJson: payloadJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String profileUid,
                required String kind,
                required String payloadJson,
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsEntitiesCompanion.insert(
                id: id,
                profileUid: profileUid,
                kind: kind,
                payloadJson: payloadJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsEntitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsEntitiesTable,
      SrsEntityRow,
      $$SrsEntitiesTableFilterComposer,
      $$SrsEntitiesTableOrderingComposer,
      $$SrsEntitiesTableAnnotationComposer,
      $$SrsEntitiesTableCreateCompanionBuilder,
      $$SrsEntitiesTableUpdateCompanionBuilder,
      (
        SrsEntityRow,
        BaseReferences<_$SrsDatabase, $SrsEntitiesTable, SrsEntityRow>,
      ),
      SrsEntityRow,
      PrefetchHooks Function()
    >;
typedef $$SrsFieldEditsTableCreateCompanionBuilder =
    SrsFieldEditsCompanion Function({
      required String id,
      required String profileUid,
      required String entityKind,
      required String entityId,
      required String fieldKey,
      required String writerId,
      required int seq,
      required String json,
      Value<int> rowid,
    });
typedef $$SrsFieldEditsTableUpdateCompanionBuilder =
    SrsFieldEditsCompanion Function({
      Value<String> id,
      Value<String> profileUid,
      Value<String> entityKind,
      Value<String> entityId,
      Value<String> fieldKey,
      Value<String> writerId,
      Value<int> seq,
      Value<String> json,
      Value<int> rowid,
    });

class $$SrsFieldEditsTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsFieldEditsTable> {
  $$SrsFieldEditsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityKind => $composableBuilder(
    column: $table.entityKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fieldKey => $composableBuilder(
    column: $table.fieldKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get writerId => $composableBuilder(
    column: $table.writerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsFieldEditsTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsFieldEditsTable> {
  $$SrsFieldEditsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityKind => $composableBuilder(
    column: $table.entityKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fieldKey => $composableBuilder(
    column: $table.fieldKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get writerId => $composableBuilder(
    column: $table.writerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsFieldEditsTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsFieldEditsTable> {
  $$SrsFieldEditsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityKind => $composableBuilder(
    column: $table.entityKind,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get fieldKey =>
      $composableBuilder(column: $table.fieldKey, builder: (column) => column);

  GeneratedColumn<String> get writerId =>
      $composableBuilder(column: $table.writerId, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get json =>
      $composableBuilder(column: $table.json, builder: (column) => column);
}

class $$SrsFieldEditsTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsFieldEditsTable,
          SrsFieldEditRow,
          $$SrsFieldEditsTableFilterComposer,
          $$SrsFieldEditsTableOrderingComposer,
          $$SrsFieldEditsTableAnnotationComposer,
          $$SrsFieldEditsTableCreateCompanionBuilder,
          $$SrsFieldEditsTableUpdateCompanionBuilder,
          (
            SrsFieldEditRow,
            BaseReferences<_$SrsDatabase, $SrsFieldEditsTable, SrsFieldEditRow>,
          ),
          SrsFieldEditRow,
          PrefetchHooks Function()
        > {
  $$SrsFieldEditsTableTableManager(_$SrsDatabase db, $SrsFieldEditsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsFieldEditsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsFieldEditsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsFieldEditsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> entityKind = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> fieldKey = const Value.absent(),
                Value<String> writerId = const Value.absent(),
                Value<int> seq = const Value.absent(),
                Value<String> json = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsFieldEditsCompanion(
                id: id,
                profileUid: profileUid,
                entityKind: entityKind,
                entityId: entityId,
                fieldKey: fieldKey,
                writerId: writerId,
                seq: seq,
                json: json,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String profileUid,
                required String entityKind,
                required String entityId,
                required String fieldKey,
                required String writerId,
                required int seq,
                required String json,
                Value<int> rowid = const Value.absent(),
              }) => SrsFieldEditsCompanion.insert(
                id: id,
                profileUid: profileUid,
                entityKind: entityKind,
                entityId: entityId,
                fieldKey: fieldKey,
                writerId: writerId,
                seq: seq,
                json: json,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsFieldEditsTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsFieldEditsTable,
      SrsFieldEditRow,
      $$SrsFieldEditsTableFilterComposer,
      $$SrsFieldEditsTableOrderingComposer,
      $$SrsFieldEditsTableAnnotationComposer,
      $$SrsFieldEditsTableCreateCompanionBuilder,
      $$SrsFieldEditsTableUpdateCompanionBuilder,
      (
        SrsFieldEditRow,
        BaseReferences<_$SrsDatabase, $SrsFieldEditsTable, SrsFieldEditRow>,
      ),
      SrsFieldEditRow,
      PrefetchHooks Function()
    >;
typedef $$SrsReviewLogsTableCreateCompanionBuilder =
    SrsReviewLogsCompanion Function({
      required String id,
      required String profileUid,
      required String cardId,
      required String kind,
      Value<int?> rating,
      required int occurredAt,
      required String reviewType,
      required String origin,
      Value<int> durationMs,
      required String json,
      Value<int> rowid,
    });
typedef $$SrsReviewLogsTableUpdateCompanionBuilder =
    SrsReviewLogsCompanion Function({
      Value<String> id,
      Value<String> profileUid,
      Value<String> cardId,
      Value<String> kind,
      Value<int?> rating,
      Value<int> occurredAt,
      Value<String> reviewType,
      Value<String> origin,
      Value<int> durationMs,
      Value<String> json,
      Value<int> rowid,
    });

class $$SrsReviewLogsTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsReviewLogsTable> {
  $$SrsReviewLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardId => $composableBuilder(
    column: $table.cardId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reviewType => $composableBuilder(
    column: $table.reviewType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsReviewLogsTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsReviewLogsTable> {
  $$SrsReviewLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardId => $composableBuilder(
    column: $table.cardId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reviewType => $composableBuilder(
    column: $table.reviewType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get origin => $composableBuilder(
    column: $table.origin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsReviewLogsTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsReviewLogsTable> {
  $$SrsReviewLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cardId =>
      $composableBuilder(column: $table.cardId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reviewType => $composableBuilder(
    column: $table.reviewType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get json =>
      $composableBuilder(column: $table.json, builder: (column) => column);
}

class $$SrsReviewLogsTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsReviewLogsTable,
          SrsReviewLogRow,
          $$SrsReviewLogsTableFilterComposer,
          $$SrsReviewLogsTableOrderingComposer,
          $$SrsReviewLogsTableAnnotationComposer,
          $$SrsReviewLogsTableCreateCompanionBuilder,
          $$SrsReviewLogsTableUpdateCompanionBuilder,
          (
            SrsReviewLogRow,
            BaseReferences<_$SrsDatabase, $SrsReviewLogsTable, SrsReviewLogRow>,
          ),
          SrsReviewLogRow,
          PrefetchHooks Function()
        > {
  $$SrsReviewLogsTableTableManager(_$SrsDatabase db, $SrsReviewLogsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsReviewLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsReviewLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsReviewLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> cardId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int?> rating = const Value.absent(),
                Value<int> occurredAt = const Value.absent(),
                Value<String> reviewType = const Value.absent(),
                Value<String> origin = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<String> json = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsReviewLogsCompanion(
                id: id,
                profileUid: profileUid,
                cardId: cardId,
                kind: kind,
                rating: rating,
                occurredAt: occurredAt,
                reviewType: reviewType,
                origin: origin,
                durationMs: durationMs,
                json: json,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String profileUid,
                required String cardId,
                required String kind,
                Value<int?> rating = const Value.absent(),
                required int occurredAt,
                required String reviewType,
                required String origin,
                Value<int> durationMs = const Value.absent(),
                required String json,
                Value<int> rowid = const Value.absent(),
              }) => SrsReviewLogsCompanion.insert(
                id: id,
                profileUid: profileUid,
                cardId: cardId,
                kind: kind,
                rating: rating,
                occurredAt: occurredAt,
                reviewType: reviewType,
                origin: origin,
                durationMs: durationMs,
                json: json,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsReviewLogsTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsReviewLogsTable,
      SrsReviewLogRow,
      $$SrsReviewLogsTableFilterComposer,
      $$SrsReviewLogsTableOrderingComposer,
      $$SrsReviewLogsTableAnnotationComposer,
      $$SrsReviewLogsTableCreateCompanionBuilder,
      $$SrsReviewLogsTableUpdateCompanionBuilder,
      (
        SrsReviewLogRow,
        BaseReferences<_$SrsDatabase, $SrsReviewLogsTable, SrsReviewLogRow>,
      ),
      SrsReviewLogRow,
      PrefetchHooks Function()
    >;
typedef $$SrsUnknownEventsTableCreateCompanionBuilder =
    SrsUnknownEventsCompanion Function({
      required String id,
      required String profileUid,
      required String json,
      Value<int> rowid,
    });
typedef $$SrsUnknownEventsTableUpdateCompanionBuilder =
    SrsUnknownEventsCompanion Function({
      Value<String> id,
      Value<String> profileUid,
      Value<String> json,
      Value<int> rowid,
    });

class $$SrsUnknownEventsTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsUnknownEventsTable> {
  $$SrsUnknownEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsUnknownEventsTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsUnknownEventsTable> {
  $$SrsUnknownEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsUnknownEventsTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsUnknownEventsTable> {
  $$SrsUnknownEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get json =>
      $composableBuilder(column: $table.json, builder: (column) => column);
}

class $$SrsUnknownEventsTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsUnknownEventsTable,
          SrsUnknownEventRow,
          $$SrsUnknownEventsTableFilterComposer,
          $$SrsUnknownEventsTableOrderingComposer,
          $$SrsUnknownEventsTableAnnotationComposer,
          $$SrsUnknownEventsTableCreateCompanionBuilder,
          $$SrsUnknownEventsTableUpdateCompanionBuilder,
          (
            SrsUnknownEventRow,
            BaseReferences<
              _$SrsDatabase,
              $SrsUnknownEventsTable,
              SrsUnknownEventRow
            >,
          ),
          SrsUnknownEventRow,
          PrefetchHooks Function()
        > {
  $$SrsUnknownEventsTableTableManager(
    _$SrsDatabase db,
    $SrsUnknownEventsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsUnknownEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsUnknownEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsUnknownEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> json = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsUnknownEventsCompanion(
                id: id,
                profileUid: profileUid,
                json: json,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String profileUid,
                required String json,
                Value<int> rowid = const Value.absent(),
              }) => SrsUnknownEventsCompanion.insert(
                id: id,
                profileUid: profileUid,
                json: json,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsUnknownEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsUnknownEventsTable,
      SrsUnknownEventRow,
      $$SrsUnknownEventsTableFilterComposer,
      $$SrsUnknownEventsTableOrderingComposer,
      $$SrsUnknownEventsTableAnnotationComposer,
      $$SrsUnknownEventsTableCreateCompanionBuilder,
      $$SrsUnknownEventsTableUpdateCompanionBuilder,
      (
        SrsUnknownEventRow,
        BaseReferences<
          _$SrsDatabase,
          $SrsUnknownEventsTable,
          SrsUnknownEventRow
        >,
      ),
      SrsUnknownEventRow,
      PrefetchHooks Function()
    >;
typedef $$SrsEventLocalTableCreateCompanionBuilder =
    SrsEventLocalCompanion Function({
      required String eventId,
      required String profileUid,
      Value<int?> outboxSeq,
      Value<int?> serverTime,
      Value<int> receivedAt,
      Value<int> rowid,
    });
typedef $$SrsEventLocalTableUpdateCompanionBuilder =
    SrsEventLocalCompanion Function({
      Value<String> eventId,
      Value<String> profileUid,
      Value<int?> outboxSeq,
      Value<int?> serverTime,
      Value<int> receivedAt,
      Value<int> rowid,
    });

class $$SrsEventLocalTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsEventLocalTable> {
  $$SrsEventLocalTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get outboxSeq => $composableBuilder(
    column: $table.outboxSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverTime => $composableBuilder(
    column: $table.serverTime,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsEventLocalTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsEventLocalTable> {
  $$SrsEventLocalTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get eventId => $composableBuilder(
    column: $table.eventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get outboxSeq => $composableBuilder(
    column: $table.outboxSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverTime => $composableBuilder(
    column: $table.serverTime,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsEventLocalTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsEventLocalTable> {
  $$SrsEventLocalTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get eventId =>
      $composableBuilder(column: $table.eventId, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<int> get outboxSeq =>
      $composableBuilder(column: $table.outboxSeq, builder: (column) => column);

  GeneratedColumn<int> get serverTime => $composableBuilder(
    column: $table.serverTime,
    builder: (column) => column,
  );

  GeneratedColumn<int> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => column,
  );
}

class $$SrsEventLocalTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsEventLocalTable,
          SrsEventLocalRow,
          $$SrsEventLocalTableFilterComposer,
          $$SrsEventLocalTableOrderingComposer,
          $$SrsEventLocalTableAnnotationComposer,
          $$SrsEventLocalTableCreateCompanionBuilder,
          $$SrsEventLocalTableUpdateCompanionBuilder,
          (
            SrsEventLocalRow,
            BaseReferences<
              _$SrsDatabase,
              $SrsEventLocalTable,
              SrsEventLocalRow
            >,
          ),
          SrsEventLocalRow,
          PrefetchHooks Function()
        > {
  $$SrsEventLocalTableTableManager(_$SrsDatabase db, $SrsEventLocalTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsEventLocalTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsEventLocalTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsEventLocalTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> eventId = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<int?> outboxSeq = const Value.absent(),
                Value<int?> serverTime = const Value.absent(),
                Value<int> receivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsEventLocalCompanion(
                eventId: eventId,
                profileUid: profileUid,
                outboxSeq: outboxSeq,
                serverTime: serverTime,
                receivedAt: receivedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String eventId,
                required String profileUid,
                Value<int?> outboxSeq = const Value.absent(),
                Value<int?> serverTime = const Value.absent(),
                Value<int> receivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsEventLocalCompanion.insert(
                eventId: eventId,
                profileUid: profileUid,
                outboxSeq: outboxSeq,
                serverTime: serverTime,
                receivedAt: receivedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsEventLocalTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsEventLocalTable,
      SrsEventLocalRow,
      $$SrsEventLocalTableFilterComposer,
      $$SrsEventLocalTableOrderingComposer,
      $$SrsEventLocalTableAnnotationComposer,
      $$SrsEventLocalTableCreateCompanionBuilder,
      $$SrsEventLocalTableUpdateCompanionBuilder,
      (
        SrsEventLocalRow,
        BaseReferences<_$SrsDatabase, $SrsEventLocalTable, SrsEventLocalRow>,
      ),
      SrsEventLocalRow,
      PrefetchHooks Function()
    >;
typedef $$SrsLocalStateTableCreateCompanionBuilder =
    SrsLocalStateCompanion Function({
      required String profileUid,
      required String json,
      Value<int> rowid,
    });
typedef $$SrsLocalStateTableUpdateCompanionBuilder =
    SrsLocalStateCompanion Function({
      Value<String> profileUid,
      Value<String> json,
      Value<int> rowid,
    });

class $$SrsLocalStateTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsLocalStateTable> {
  $$SrsLocalStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsLocalStateTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsLocalStateTable> {
  $$SrsLocalStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsLocalStateTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsLocalStateTable> {
  $$SrsLocalStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get json =>
      $composableBuilder(column: $table.json, builder: (column) => column);
}

class $$SrsLocalStateTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsLocalStateTable,
          SrsLocalStateRow,
          $$SrsLocalStateTableFilterComposer,
          $$SrsLocalStateTableOrderingComposer,
          $$SrsLocalStateTableAnnotationComposer,
          $$SrsLocalStateTableCreateCompanionBuilder,
          $$SrsLocalStateTableUpdateCompanionBuilder,
          (
            SrsLocalStateRow,
            BaseReferences<
              _$SrsDatabase,
              $SrsLocalStateTable,
              SrsLocalStateRow
            >,
          ),
          SrsLocalStateRow,
          PrefetchHooks Function()
        > {
  $$SrsLocalStateTableTableManager(_$SrsDatabase db, $SrsLocalStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsLocalStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsLocalStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsLocalStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileUid = const Value.absent(),
                Value<String> json = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsLocalStateCompanion(
                profileUid: profileUid,
                json: json,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileUid,
                required String json,
                Value<int> rowid = const Value.absent(),
              }) => SrsLocalStateCompanion.insert(
                profileUid: profileUid,
                json: json,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsLocalStateTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsLocalStateTable,
      SrsLocalStateRow,
      $$SrsLocalStateTableFilterComposer,
      $$SrsLocalStateTableOrderingComposer,
      $$SrsLocalStateTableAnnotationComposer,
      $$SrsLocalStateTableCreateCompanionBuilder,
      $$SrsLocalStateTableUpdateCompanionBuilder,
      (
        SrsLocalStateRow,
        BaseReferences<_$SrsDatabase, $SrsLocalStateTable, SrsLocalStateRow>,
      ),
      SrsLocalStateRow,
      PrefetchHooks Function()
    >;
typedef $$SrsSentBatchesTableCreateCompanionBuilder =
    SrsSentBatchesCompanion Function({
      required String profileUid,
      required String writerId,
      required int batchNo,
      required Uint8List bytes,
      Value<int> rowid,
    });
typedef $$SrsSentBatchesTableUpdateCompanionBuilder =
    SrsSentBatchesCompanion Function({
      Value<String> profileUid,
      Value<String> writerId,
      Value<int> batchNo,
      Value<Uint8List> bytes,
      Value<int> rowid,
    });

class $$SrsSentBatchesTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsSentBatchesTable> {
  $$SrsSentBatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get writerId => $composableBuilder(
    column: $table.writerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get batchNo => $composableBuilder(
    column: $table.batchNo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsSentBatchesTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsSentBatchesTable> {
  $$SrsSentBatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get writerId => $composableBuilder(
    column: $table.writerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get batchNo => $composableBuilder(
    column: $table.batchNo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsSentBatchesTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsSentBatchesTable> {
  $$SrsSentBatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get writerId =>
      $composableBuilder(column: $table.writerId, builder: (column) => column);

  GeneratedColumn<int> get batchNo =>
      $composableBuilder(column: $table.batchNo, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);
}

class $$SrsSentBatchesTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsSentBatchesTable,
          SrsSentBatchRow,
          $$SrsSentBatchesTableFilterComposer,
          $$SrsSentBatchesTableOrderingComposer,
          $$SrsSentBatchesTableAnnotationComposer,
          $$SrsSentBatchesTableCreateCompanionBuilder,
          $$SrsSentBatchesTableUpdateCompanionBuilder,
          (
            SrsSentBatchRow,
            BaseReferences<
              _$SrsDatabase,
              $SrsSentBatchesTable,
              SrsSentBatchRow
            >,
          ),
          SrsSentBatchRow,
          PrefetchHooks Function()
        > {
  $$SrsSentBatchesTableTableManager(
    _$SrsDatabase db,
    $SrsSentBatchesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsSentBatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsSentBatchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsSentBatchesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileUid = const Value.absent(),
                Value<String> writerId = const Value.absent(),
                Value<int> batchNo = const Value.absent(),
                Value<Uint8List> bytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsSentBatchesCompanion(
                profileUid: profileUid,
                writerId: writerId,
                batchNo: batchNo,
                bytes: bytes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileUid,
                required String writerId,
                required int batchNo,
                required Uint8List bytes,
                Value<int> rowid = const Value.absent(),
              }) => SrsSentBatchesCompanion.insert(
                profileUid: profileUid,
                writerId: writerId,
                batchNo: batchNo,
                bytes: bytes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsSentBatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsSentBatchesTable,
      SrsSentBatchRow,
      $$SrsSentBatchesTableFilterComposer,
      $$SrsSentBatchesTableOrderingComposer,
      $$SrsSentBatchesTableAnnotationComposer,
      $$SrsSentBatchesTableCreateCompanionBuilder,
      $$SrsSentBatchesTableUpdateCompanionBuilder,
      (
        SrsSentBatchRow,
        BaseReferences<_$SrsDatabase, $SrsSentBatchesTable, SrsSentBatchRow>,
      ),
      SrsSentBatchRow,
      PrefetchHooks Function()
    >;
typedef $$SrsNotesCacheTableCreateCompanionBuilder =
    SrsNotesCacheCompanion Function({
      required String id,
      required String profileUid,
      required String noteTypeId,
      required String guid,
      required int createdAt,
      Value<String?> deckId,
      Value<int?> deletedAt,
      Value<String> termKey,
      Value<String> readingKey,
      Value<String> sortField,
      Value<String> tagsJson,
      Value<bool> pendingDecision,
      Value<int> updatedAt,
      Value<String> mediaRefs,
      Value<int> rowid,
    });
typedef $$SrsNotesCacheTableUpdateCompanionBuilder =
    SrsNotesCacheCompanion Function({
      Value<String> id,
      Value<String> profileUid,
      Value<String> noteTypeId,
      Value<String> guid,
      Value<int> createdAt,
      Value<String?> deckId,
      Value<int?> deletedAt,
      Value<String> termKey,
      Value<String> readingKey,
      Value<String> sortField,
      Value<String> tagsJson,
      Value<bool> pendingDecision,
      Value<int> updatedAt,
      Value<String> mediaRefs,
      Value<int> rowid,
    });

class $$SrsNotesCacheTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsNotesCacheTable> {
  $$SrsNotesCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get noteTypeId => $composableBuilder(
    column: $table.noteTypeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get guid => $composableBuilder(
    column: $table.guid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deckId => $composableBuilder(
    column: $table.deckId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get termKey => $composableBuilder(
    column: $table.termKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get readingKey => $composableBuilder(
    column: $table.readingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sortField => $composableBuilder(
    column: $table.sortField,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pendingDecision => $composableBuilder(
    column: $table.pendingDecision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaRefs => $composableBuilder(
    column: $table.mediaRefs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsNotesCacheTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsNotesCacheTable> {
  $$SrsNotesCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get noteTypeId => $composableBuilder(
    column: $table.noteTypeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get guid => $composableBuilder(
    column: $table.guid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deckId => $composableBuilder(
    column: $table.deckId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get termKey => $composableBuilder(
    column: $table.termKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get readingKey => $composableBuilder(
    column: $table.readingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sortField => $composableBuilder(
    column: $table.sortField,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pendingDecision => $composableBuilder(
    column: $table.pendingDecision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaRefs => $composableBuilder(
    column: $table.mediaRefs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsNotesCacheTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsNotesCacheTable> {
  $$SrsNotesCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get noteTypeId => $composableBuilder(
    column: $table.noteTypeId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get guid =>
      $composableBuilder(column: $table.guid, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get deckId =>
      $composableBuilder(column: $table.deckId, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get termKey =>
      $composableBuilder(column: $table.termKey, builder: (column) => column);

  GeneratedColumn<String> get readingKey => $composableBuilder(
    column: $table.readingKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sortField =>
      $composableBuilder(column: $table.sortField, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<bool> get pendingDecision => $composableBuilder(
    column: $table.pendingDecision,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get mediaRefs =>
      $composableBuilder(column: $table.mediaRefs, builder: (column) => column);
}

class $$SrsNotesCacheTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsNotesCacheTable,
          SrsNoteCacheRow,
          $$SrsNotesCacheTableFilterComposer,
          $$SrsNotesCacheTableOrderingComposer,
          $$SrsNotesCacheTableAnnotationComposer,
          $$SrsNotesCacheTableCreateCompanionBuilder,
          $$SrsNotesCacheTableUpdateCompanionBuilder,
          (
            SrsNoteCacheRow,
            BaseReferences<_$SrsDatabase, $SrsNotesCacheTable, SrsNoteCacheRow>,
          ),
          SrsNoteCacheRow,
          PrefetchHooks Function()
        > {
  $$SrsNotesCacheTableTableManager(_$SrsDatabase db, $SrsNotesCacheTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsNotesCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsNotesCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsNotesCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> noteTypeId = const Value.absent(),
                Value<String> guid = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String?> deckId = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String> termKey = const Value.absent(),
                Value<String> readingKey = const Value.absent(),
                Value<String> sortField = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<bool> pendingDecision = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<String> mediaRefs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsNotesCacheCompanion(
                id: id,
                profileUid: profileUid,
                noteTypeId: noteTypeId,
                guid: guid,
                createdAt: createdAt,
                deckId: deckId,
                deletedAt: deletedAt,
                termKey: termKey,
                readingKey: readingKey,
                sortField: sortField,
                tagsJson: tagsJson,
                pendingDecision: pendingDecision,
                updatedAt: updatedAt,
                mediaRefs: mediaRefs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String profileUid,
                required String noteTypeId,
                required String guid,
                required int createdAt,
                Value<String?> deckId = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<String> termKey = const Value.absent(),
                Value<String> readingKey = const Value.absent(),
                Value<String> sortField = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<bool> pendingDecision = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<String> mediaRefs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsNotesCacheCompanion.insert(
                id: id,
                profileUid: profileUid,
                noteTypeId: noteTypeId,
                guid: guid,
                createdAt: createdAt,
                deckId: deckId,
                deletedAt: deletedAt,
                termKey: termKey,
                readingKey: readingKey,
                sortField: sortField,
                tagsJson: tagsJson,
                pendingDecision: pendingDecision,
                updatedAt: updatedAt,
                mediaRefs: mediaRefs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsNotesCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsNotesCacheTable,
      SrsNoteCacheRow,
      $$SrsNotesCacheTableFilterComposer,
      $$SrsNotesCacheTableOrderingComposer,
      $$SrsNotesCacheTableAnnotationComposer,
      $$SrsNotesCacheTableCreateCompanionBuilder,
      $$SrsNotesCacheTableUpdateCompanionBuilder,
      (
        SrsNoteCacheRow,
        BaseReferences<_$SrsDatabase, $SrsNotesCacheTable, SrsNoteCacheRow>,
      ),
      SrsNoteCacheRow,
      PrefetchHooks Function()
    >;
typedef $$SrsCardsCacheTableCreateCompanionBuilder =
    SrsCardsCacheCompanion Function({
      required String id,
      required String profileUid,
      required String noteId,
      required String templateId,
      Value<int> clozeOrd,
      required String deckId,
      Value<bool> suspended,
      Value<int?> buriedUntilDay,
      Value<int> flag,
      Value<bool> hidden,
      Value<String> queue,
      Value<int?> dueDay,
      Value<int?> dueAt,
      Value<int> scheduledDays,
      Value<int> reps,
      Value<int> lapses,
      Value<double?> stability,
      Value<double?> difficulty,
      Value<int?> lastReviewedAt,
      Value<String?> lastLogId,
      Value<String> scheduler,
      Value<int> noteCreatedAt,
      Value<int?> newPosition,
      Value<int?> freqRank,
      Value<int> rowid,
    });
typedef $$SrsCardsCacheTableUpdateCompanionBuilder =
    SrsCardsCacheCompanion Function({
      Value<String> id,
      Value<String> profileUid,
      Value<String> noteId,
      Value<String> templateId,
      Value<int> clozeOrd,
      Value<String> deckId,
      Value<bool> suspended,
      Value<int?> buriedUntilDay,
      Value<int> flag,
      Value<bool> hidden,
      Value<String> queue,
      Value<int?> dueDay,
      Value<int?> dueAt,
      Value<int> scheduledDays,
      Value<int> reps,
      Value<int> lapses,
      Value<double?> stability,
      Value<double?> difficulty,
      Value<int?> lastReviewedAt,
      Value<String?> lastLogId,
      Value<String> scheduler,
      Value<int> noteCreatedAt,
      Value<int?> newPosition,
      Value<int?> freqRank,
      Value<int> rowid,
    });

class $$SrsCardsCacheTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsCardsCacheTable> {
  $$SrsCardsCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get templateId => $composableBuilder(
    column: $table.templateId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get clozeOrd => $composableBuilder(
    column: $table.clozeOrd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deckId => $composableBuilder(
    column: $table.deckId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get suspended => $composableBuilder(
    column: $table.suspended,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get buriedUntilDay => $composableBuilder(
    column: $table.buriedUntilDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get flag => $composableBuilder(
    column: $table.flag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get queue => $composableBuilder(
    column: $table.queue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dueDay => $composableBuilder(
    column: $table.dueDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dueAt => $composableBuilder(
    column: $table.dueAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scheduledDays => $composableBuilder(
    column: $table.scheduledDays,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reps => $composableBuilder(
    column: $table.reps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lapses => $composableBuilder(
    column: $table.lapses,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get stability => $composableBuilder(
    column: $table.stability,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReviewedAt => $composableBuilder(
    column: $table.lastReviewedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastLogId => $composableBuilder(
    column: $table.lastLogId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scheduler => $composableBuilder(
    column: $table.scheduler,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get noteCreatedAt => $composableBuilder(
    column: $table.noteCreatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get newPosition => $composableBuilder(
    column: $table.newPosition,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get freqRank => $composableBuilder(
    column: $table.freqRank,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsCardsCacheTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsCardsCacheTable> {
  $$SrsCardsCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get noteId => $composableBuilder(
    column: $table.noteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get templateId => $composableBuilder(
    column: $table.templateId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get clozeOrd => $composableBuilder(
    column: $table.clozeOrd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deckId => $composableBuilder(
    column: $table.deckId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get suspended => $composableBuilder(
    column: $table.suspended,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get buriedUntilDay => $composableBuilder(
    column: $table.buriedUntilDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get flag => $composableBuilder(
    column: $table.flag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get queue => $composableBuilder(
    column: $table.queue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dueDay => $composableBuilder(
    column: $table.dueDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dueAt => $composableBuilder(
    column: $table.dueAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scheduledDays => $composableBuilder(
    column: $table.scheduledDays,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reps => $composableBuilder(
    column: $table.reps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lapses => $composableBuilder(
    column: $table.lapses,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get stability => $composableBuilder(
    column: $table.stability,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReviewedAt => $composableBuilder(
    column: $table.lastReviewedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastLogId => $composableBuilder(
    column: $table.lastLogId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scheduler => $composableBuilder(
    column: $table.scheduler,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get noteCreatedAt => $composableBuilder(
    column: $table.noteCreatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get newPosition => $composableBuilder(
    column: $table.newPosition,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get freqRank => $composableBuilder(
    column: $table.freqRank,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsCardsCacheTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsCardsCacheTable> {
  $$SrsCardsCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get noteId =>
      $composableBuilder(column: $table.noteId, builder: (column) => column);

  GeneratedColumn<String> get templateId => $composableBuilder(
    column: $table.templateId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get clozeOrd =>
      $composableBuilder(column: $table.clozeOrd, builder: (column) => column);

  GeneratedColumn<String> get deckId =>
      $composableBuilder(column: $table.deckId, builder: (column) => column);

  GeneratedColumn<bool> get suspended =>
      $composableBuilder(column: $table.suspended, builder: (column) => column);

  GeneratedColumn<int> get buriedUntilDay => $composableBuilder(
    column: $table.buriedUntilDay,
    builder: (column) => column,
  );

  GeneratedColumn<int> get flag =>
      $composableBuilder(column: $table.flag, builder: (column) => column);

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);

  GeneratedColumn<String> get queue =>
      $composableBuilder(column: $table.queue, builder: (column) => column);

  GeneratedColumn<int> get dueDay =>
      $composableBuilder(column: $table.dueDay, builder: (column) => column);

  GeneratedColumn<int> get dueAt =>
      $composableBuilder(column: $table.dueAt, builder: (column) => column);

  GeneratedColumn<int> get scheduledDays => $composableBuilder(
    column: $table.scheduledDays,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reps =>
      $composableBuilder(column: $table.reps, builder: (column) => column);

  GeneratedColumn<int> get lapses =>
      $composableBuilder(column: $table.lapses, builder: (column) => column);

  GeneratedColumn<double> get stability =>
      $composableBuilder(column: $table.stability, builder: (column) => column);

  GeneratedColumn<double> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastReviewedAt => $composableBuilder(
    column: $table.lastReviewedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastLogId =>
      $composableBuilder(column: $table.lastLogId, builder: (column) => column);

  GeneratedColumn<String> get scheduler =>
      $composableBuilder(column: $table.scheduler, builder: (column) => column);

  GeneratedColumn<int> get noteCreatedAt => $composableBuilder(
    column: $table.noteCreatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get newPosition => $composableBuilder(
    column: $table.newPosition,
    builder: (column) => column,
  );

  GeneratedColumn<int> get freqRank =>
      $composableBuilder(column: $table.freqRank, builder: (column) => column);
}

class $$SrsCardsCacheTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsCardsCacheTable,
          SrsCardCacheRow,
          $$SrsCardsCacheTableFilterComposer,
          $$SrsCardsCacheTableOrderingComposer,
          $$SrsCardsCacheTableAnnotationComposer,
          $$SrsCardsCacheTableCreateCompanionBuilder,
          $$SrsCardsCacheTableUpdateCompanionBuilder,
          (
            SrsCardCacheRow,
            BaseReferences<_$SrsDatabase, $SrsCardsCacheTable, SrsCardCacheRow>,
          ),
          SrsCardCacheRow,
          PrefetchHooks Function()
        > {
  $$SrsCardsCacheTableTableManager(_$SrsDatabase db, $SrsCardsCacheTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsCardsCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsCardsCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsCardsCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> noteId = const Value.absent(),
                Value<String> templateId = const Value.absent(),
                Value<int> clozeOrd = const Value.absent(),
                Value<String> deckId = const Value.absent(),
                Value<bool> suspended = const Value.absent(),
                Value<int?> buriedUntilDay = const Value.absent(),
                Value<int> flag = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<String> queue = const Value.absent(),
                Value<int?> dueDay = const Value.absent(),
                Value<int?> dueAt = const Value.absent(),
                Value<int> scheduledDays = const Value.absent(),
                Value<int> reps = const Value.absent(),
                Value<int> lapses = const Value.absent(),
                Value<double?> stability = const Value.absent(),
                Value<double?> difficulty = const Value.absent(),
                Value<int?> lastReviewedAt = const Value.absent(),
                Value<String?> lastLogId = const Value.absent(),
                Value<String> scheduler = const Value.absent(),
                Value<int> noteCreatedAt = const Value.absent(),
                Value<int?> newPosition = const Value.absent(),
                Value<int?> freqRank = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsCardsCacheCompanion(
                id: id,
                profileUid: profileUid,
                noteId: noteId,
                templateId: templateId,
                clozeOrd: clozeOrd,
                deckId: deckId,
                suspended: suspended,
                buriedUntilDay: buriedUntilDay,
                flag: flag,
                hidden: hidden,
                queue: queue,
                dueDay: dueDay,
                dueAt: dueAt,
                scheduledDays: scheduledDays,
                reps: reps,
                lapses: lapses,
                stability: stability,
                difficulty: difficulty,
                lastReviewedAt: lastReviewedAt,
                lastLogId: lastLogId,
                scheduler: scheduler,
                noteCreatedAt: noteCreatedAt,
                newPosition: newPosition,
                freqRank: freqRank,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String profileUid,
                required String noteId,
                required String templateId,
                Value<int> clozeOrd = const Value.absent(),
                required String deckId,
                Value<bool> suspended = const Value.absent(),
                Value<int?> buriedUntilDay = const Value.absent(),
                Value<int> flag = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<String> queue = const Value.absent(),
                Value<int?> dueDay = const Value.absent(),
                Value<int?> dueAt = const Value.absent(),
                Value<int> scheduledDays = const Value.absent(),
                Value<int> reps = const Value.absent(),
                Value<int> lapses = const Value.absent(),
                Value<double?> stability = const Value.absent(),
                Value<double?> difficulty = const Value.absent(),
                Value<int?> lastReviewedAt = const Value.absent(),
                Value<String?> lastLogId = const Value.absent(),
                Value<String> scheduler = const Value.absent(),
                Value<int> noteCreatedAt = const Value.absent(),
                Value<int?> newPosition = const Value.absent(),
                Value<int?> freqRank = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsCardsCacheCompanion.insert(
                id: id,
                profileUid: profileUid,
                noteId: noteId,
                templateId: templateId,
                clozeOrd: clozeOrd,
                deckId: deckId,
                suspended: suspended,
                buriedUntilDay: buriedUntilDay,
                flag: flag,
                hidden: hidden,
                queue: queue,
                dueDay: dueDay,
                dueAt: dueAt,
                scheduledDays: scheduledDays,
                reps: reps,
                lapses: lapses,
                stability: stability,
                difficulty: difficulty,
                lastReviewedAt: lastReviewedAt,
                lastLogId: lastLogId,
                scheduler: scheduler,
                noteCreatedAt: noteCreatedAt,
                newPosition: newPosition,
                freqRank: freqRank,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsCardsCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsCardsCacheTable,
      SrsCardCacheRow,
      $$SrsCardsCacheTableFilterComposer,
      $$SrsCardsCacheTableOrderingComposer,
      $$SrsCardsCacheTableAnnotationComposer,
      $$SrsCardsCacheTableCreateCompanionBuilder,
      $$SrsCardsCacheTableUpdateCompanionBuilder,
      (
        SrsCardCacheRow,
        BaseReferences<_$SrsDatabase, $SrsCardsCacheTable, SrsCardCacheRow>,
      ),
      SrsCardCacheRow,
      PrefetchHooks Function()
    >;
typedef $$SrsStatReviewsTableCreateCompanionBuilder =
    SrsStatReviewsCompanion Function({
      required String logId,
      required String profileUid,
      required String cardId,
      required int occurredAt,
      Value<int> utcOffsetMin,
      Value<int?> rating,
      Value<int> kind,
      Value<int> durationMs,
      Value<int?> prevDueDay,
      Value<int> maturityDelta,
      Value<int> rowid,
    });
typedef $$SrsStatReviewsTableUpdateCompanionBuilder =
    SrsStatReviewsCompanion Function({
      Value<String> logId,
      Value<String> profileUid,
      Value<String> cardId,
      Value<int> occurredAt,
      Value<int> utcOffsetMin,
      Value<int?> rating,
      Value<int> kind,
      Value<int> durationMs,
      Value<int?> prevDueDay,
      Value<int> maturityDelta,
      Value<int> rowid,
    });

class $$SrsStatReviewsTableFilterComposer
    extends Composer<_$SrsDatabase, $SrsStatReviewsTable> {
  $$SrsStatReviewsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get logId => $composableBuilder(
    column: $table.logId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardId => $composableBuilder(
    column: $table.cardId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get utcOffsetMin => $composableBuilder(
    column: $table.utcOffsetMin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get prevDueDay => $composableBuilder(
    column: $table.prevDueDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get maturityDelta => $composableBuilder(
    column: $table.maturityDelta,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SrsStatReviewsTableOrderingComposer
    extends Composer<_$SrsDatabase, $SrsStatReviewsTable> {
  $$SrsStatReviewsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get logId => $composableBuilder(
    column: $table.logId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardId => $composableBuilder(
    column: $table.cardId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get utcOffsetMin => $composableBuilder(
    column: $table.utcOffsetMin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get prevDueDay => $composableBuilder(
    column: $table.prevDueDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get maturityDelta => $composableBuilder(
    column: $table.maturityDelta,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SrsStatReviewsTableAnnotationComposer
    extends Composer<_$SrsDatabase, $SrsStatReviewsTable> {
  $$SrsStatReviewsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get logId =>
      $composableBuilder(column: $table.logId, builder: (column) => column);

  GeneratedColumn<String> get profileUid => $composableBuilder(
    column: $table.profileUid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cardId =>
      $composableBuilder(column: $table.cardId, builder: (column) => column);

  GeneratedColumn<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get utcOffsetMin => $composableBuilder(
    column: $table.utcOffsetMin,
    builder: (column) => column,
  );

  GeneratedColumn<int> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<int> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get prevDueDay => $composableBuilder(
    column: $table.prevDueDay,
    builder: (column) => column,
  );

  GeneratedColumn<int> get maturityDelta => $composableBuilder(
    column: $table.maturityDelta,
    builder: (column) => column,
  );
}

class $$SrsStatReviewsTableTableManager
    extends
        RootTableManager<
          _$SrsDatabase,
          $SrsStatReviewsTable,
          SrsStatReviewRow,
          $$SrsStatReviewsTableFilterComposer,
          $$SrsStatReviewsTableOrderingComposer,
          $$SrsStatReviewsTableAnnotationComposer,
          $$SrsStatReviewsTableCreateCompanionBuilder,
          $$SrsStatReviewsTableUpdateCompanionBuilder,
          (
            SrsStatReviewRow,
            BaseReferences<
              _$SrsDatabase,
              $SrsStatReviewsTable,
              SrsStatReviewRow
            >,
          ),
          SrsStatReviewRow,
          PrefetchHooks Function()
        > {
  $$SrsStatReviewsTableTableManager(
    _$SrsDatabase db,
    $SrsStatReviewsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrsStatReviewsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrsStatReviewsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrsStatReviewsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> logId = const Value.absent(),
                Value<String> profileUid = const Value.absent(),
                Value<String> cardId = const Value.absent(),
                Value<int> occurredAt = const Value.absent(),
                Value<int> utcOffsetMin = const Value.absent(),
                Value<int?> rating = const Value.absent(),
                Value<int> kind = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<int?> prevDueDay = const Value.absent(),
                Value<int> maturityDelta = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsStatReviewsCompanion(
                logId: logId,
                profileUid: profileUid,
                cardId: cardId,
                occurredAt: occurredAt,
                utcOffsetMin: utcOffsetMin,
                rating: rating,
                kind: kind,
                durationMs: durationMs,
                prevDueDay: prevDueDay,
                maturityDelta: maturityDelta,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String logId,
                required String profileUid,
                required String cardId,
                required int occurredAt,
                Value<int> utcOffsetMin = const Value.absent(),
                Value<int?> rating = const Value.absent(),
                Value<int> kind = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<int?> prevDueDay = const Value.absent(),
                Value<int> maturityDelta = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SrsStatReviewsCompanion.insert(
                logId: logId,
                profileUid: profileUid,
                cardId: cardId,
                occurredAt: occurredAt,
                utcOffsetMin: utcOffsetMin,
                rating: rating,
                kind: kind,
                durationMs: durationMs,
                prevDueDay: prevDueDay,
                maturityDelta: maturityDelta,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SrsStatReviewsTableProcessedTableManager =
    ProcessedTableManager<
      _$SrsDatabase,
      $SrsStatReviewsTable,
      SrsStatReviewRow,
      $$SrsStatReviewsTableFilterComposer,
      $$SrsStatReviewsTableOrderingComposer,
      $$SrsStatReviewsTableAnnotationComposer,
      $$SrsStatReviewsTableCreateCompanionBuilder,
      $$SrsStatReviewsTableUpdateCompanionBuilder,
      (
        SrsStatReviewRow,
        BaseReferences<_$SrsDatabase, $SrsStatReviewsTable, SrsStatReviewRow>,
      ),
      SrsStatReviewRow,
      PrefetchHooks Function()
    >;

class $SrsDatabaseManager {
  final _$SrsDatabase _db;
  $SrsDatabaseManager(this._db);
  $$SrsEntitiesTableTableManager get srsEntities =>
      $$SrsEntitiesTableTableManager(_db, _db.srsEntities);
  $$SrsFieldEditsTableTableManager get srsFieldEdits =>
      $$SrsFieldEditsTableTableManager(_db, _db.srsFieldEdits);
  $$SrsReviewLogsTableTableManager get srsReviewLogs =>
      $$SrsReviewLogsTableTableManager(_db, _db.srsReviewLogs);
  $$SrsUnknownEventsTableTableManager get srsUnknownEvents =>
      $$SrsUnknownEventsTableTableManager(_db, _db.srsUnknownEvents);
  $$SrsEventLocalTableTableManager get srsEventLocal =>
      $$SrsEventLocalTableTableManager(_db, _db.srsEventLocal);
  $$SrsLocalStateTableTableManager get srsLocalState =>
      $$SrsLocalStateTableTableManager(_db, _db.srsLocalState);
  $$SrsSentBatchesTableTableManager get srsSentBatches =>
      $$SrsSentBatchesTableTableManager(_db, _db.srsSentBatches);
  $$SrsNotesCacheTableTableManager get srsNotesCache =>
      $$SrsNotesCacheTableTableManager(_db, _db.srsNotesCache);
  $$SrsCardsCacheTableTableManager get srsCardsCache =>
      $$SrsCardsCacheTableTableManager(_db, _db.srsCardsCache);
  $$SrsStatReviewsTableTableManager get srsStatReviews =>
      $$SrsStatReviewsTableTableManager(_db, _db.srsStatReviews);
}
