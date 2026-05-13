
// ── $ProfilesTable ─────────────────────────────────────────────────
class $ProfilesTable extends Profiles
    with TableInfo<$ProfilesTable, ProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, name, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profiles';
  @override
  VerificationContext validateIntegrity(Insertable<ProfileRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta, createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta, updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {name},
      ];
  @override
  ProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileRow(
      id: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      createdAt: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class ProfileRow extends DataClass implements Insertable<ProfileRow> {
  final int id;
  final String name;
  final int createdAt;
  final int updatedAt;
  const ProfileRow({required this.id, required this.name, required this.createdAt, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(id: Value(id), name: Value(name), createdAt: Value(createdAt), updatedAt: Value(updatedAt));
  }

  factory ProfileRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileRow(id: serializer.fromJson<int>(json['id']), name: serializer.fromJson<String>(json['name']), createdAt: serializer.fromJson<int>(json['createdAt']), updatedAt: serializer.fromJson<int>(json['updatedAt']));
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'id': serializer.toJson<int>(id), 'name': serializer.toJson<String>(name), 'createdAt': serializer.toJson<int>(createdAt), 'updatedAt': serializer.toJson<int>(updatedAt)};
  }

  ProfileRow copyWith({int? id, String? name, int? createdAt, int? updatedAt}) => ProfileRow(id: id ?? this.id, name: name ?? this.name, createdAt: createdAt ?? this.createdAt, updatedAt: updatedAt ?? this.updatedAt);
  ProfileRow copyWithCompanion(ProfilesCompanion data) {
    return ProfileRow(id: data.id.present ? data.id.value : this.id, name: data.name.present ? data.name.value : this.name, createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt, updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt);
  }

  @override
  String toString() { return (StringBuffer('ProfileRow(')..write('id: $id, ')..write('name: $name, ')..write('createdAt: $createdAt, ')..write('updatedAt: $updatedAt')..write(')')).toString(); }
  @override
  int get hashCode => Object.hash(id, name, createdAt, updatedAt);
  @override
  bool operator ==(Object other) => identical(this, other) || (other is ProfileRow && other.id == this.id && other.name == this.name && other.createdAt == this.createdAt && other.updatedAt == this.updatedAt);
}

class ProfilesCompanion extends UpdateCompanion<ProfileRow> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  const ProfilesCompanion({this.id = const Value.absent(), this.name = const Value.absent(), this.createdAt = const Value.absent(), this.updatedAt = const Value.absent()});
  ProfilesCompanion.insert({this.id = const Value.absent(), required String name, required int createdAt, required int updatedAt}) : name = Value(name), createdAt = Value(createdAt), updatedAt = Value(updatedAt);
  static Insertable<ProfileRow> custom({Expression<int>? id, Expression<String>? name, Expression<int>? createdAt, Expression<int>? updatedAt}) {
    return RawValuesInsertable({if (id != null) 'id': id, if (name != null) 'name': name, if (createdAt != null) 'created_at': createdAt, if (updatedAt != null) 'updated_at': updatedAt});
  }
  ProfilesCompanion copyWith({Value<int>? id, Value<String>? name, Value<int>? createdAt, Value<int>? updatedAt}) {
    return ProfilesCompanion(id: id ?? this.id, name: name ?? this.name, createdAt: createdAt ?? this.createdAt, updatedAt: updatedAt ?? this.updatedAt);
  }
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) { map['id'] = Variable<int>(id.value); }
    if (name.present) { map['name'] = Variable<String>(name.value); }
    if (createdAt.present) { map['created_at'] = Variable<int>(createdAt.value); }
    if (updatedAt.present) { map['updated_at'] = Variable<int>(updatedAt.value); }
    return map;
  }
  @override
  String toString() { return (StringBuffer('ProfilesCompanion(')..write('id: $id, ')..write('name: $name, ')..write('createdAt: $createdAt, ')..write('updatedAt: $updatedAt')..write(')')).toString(); }
}

// ── $ProfileSettingsTable ──────────────────────────────────────────
class $ProfileSettingsTable extends ProfileSettings with TableInfo<$ProfileSettingsTable, ProfileSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfileSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>('id', aliasedName, false, hasAutoIncrement: true, type: DriftSqlType.int, requiredDuringInsert: false, defaultConstraints: GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _profileIdMeta = const VerificationMeta('profileId');
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>('profile_id', aliasedName, false, type: DriftSqlType.int, requiredDuringInsert: true, defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES profiles (id) ON DELETE CASCADE'));
  static const VerificationMeta _categoryMeta = const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>('category', aliasedName, false, type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>('key', aliasedName, false, type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>('value', aliasedName, false, type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, profileId, category, key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile_settings';
  @override
  VerificationContext validateIntegrity(Insertable<ProfileSettingRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) { context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta)); }
    if (data.containsKey('profile_id')) { context.handle(_profileIdMeta, profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta)); } else if (isInserting) { context.missing(_profileIdMeta); }
    if (data.containsKey('category')) { context.handle(_categoryMeta, category.isAcceptableOrUnknown(data['category']!, _categoryMeta)); } else if (isInserting) { context.missing(_categoryMeta); }
    if (data.containsKey('key')) { context.handle(_keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta)); } else if (isInserting) { context.missing(_keyMeta); }
    if (data.containsKey('value')) { context.handle(_valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta)); } else if (isInserting) { context.missing(_valueMeta); }
    return context;
  }
  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [{profileId, category, key}];
  @override
  ProfileSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileSettingRow(id: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}id'])!, profileId: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}profile_id'])!, category: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}category'])!, key: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}key'])!, value: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}value'])!);
  }
  @override
  $ProfileSettingsTable createAlias(String alias) { return $ProfileSettingsTable(attachedDatabase, alias); }
}

class ProfileSettingRow extends DataClass implements Insertable<ProfileSettingRow> {
  final int id; final int profileId; final String category; final String key; final String value;
  const ProfileSettingRow({required this.id, required this.profileId, required this.category, required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) { final map = <String, Expression>{}; map['id'] = Variable<int>(id); map['profile_id'] = Variable<int>(profileId); map['category'] = Variable<String>(category); map['key'] = Variable<String>(key); map['value'] = Variable<String>(value); return map; }
  ProfileSettingsCompanion toCompanion(bool nullToAbsent) { return ProfileSettingsCompanion(id: Value(id), profileId: Value(profileId), category: Value(category), key: Value(key), value: Value(value)); }
  factory ProfileSettingRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) { serializer ??= driftRuntimeOptions.defaultSerializer; return ProfileSettingRow(id: serializer.fromJson<int>(json['id']), profileId: serializer.fromJson<int>(json['profileId']), category: serializer.fromJson<String>(json['category']), key: serializer.fromJson<String>(json['key']), value: serializer.fromJson<String>(json['value'])); }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) { serializer ??= driftRuntimeOptions.defaultSerializer; return <String, dynamic>{'id': serializer.toJson<int>(id), 'profileId': serializer.toJson<int>(profileId), 'category': serializer.toJson<String>(category), 'key': serializer.toJson<String>(key), 'value': serializer.toJson<String>(value)}; }
  ProfileSettingRow copyWith({int? id, int? profileId, String? category, String? key, String? value}) => ProfileSettingRow(id: id ?? this.id, profileId: profileId ?? this.profileId, category: category ?? this.category, key: key ?? this.key, value: value ?? this.value);
  ProfileSettingRow copyWithCompanion(ProfileSettingsCompanion data) { return ProfileSettingRow(id: data.id.present ? data.id.value : this.id, profileId: data.profileId.present ? data.profileId.value : this.profileId, category: data.category.present ? data.category.value : this.category, key: data.key.present ? data.key.value : this.key, value: data.value.present ? data.value.value : this.value); }
  @override
  String toString() { return (StringBuffer('ProfileSettingRow(')..write('id: $id, ')..write('profileId: $profileId, ')..write('category: $category, ')..write('key: $key, ')..write('value: $value')..write(')')).toString(); }
  @override
  int get hashCode => Object.hash(id, profileId, category, key, value);
  @override
  bool operator ==(Object other) => identical(this, other) || (other is ProfileSettingRow && other.id == this.id && other.profileId == this.profileId && other.category == this.category && other.key == this.key && other.value == this.value);
}

class ProfileSettingsCompanion extends UpdateCompanion<ProfileSettingRow> {
  final Value<int> id; final Value<int> profileId; final Value<String> category; final Value<String> key; final Value<String> value;
  const ProfileSettingsCompanion({this.id = const Value.absent(), this.profileId = const Value.absent(), this.category = const Value.absent(), this.key = const Value.absent(), this.value = const Value.absent()});
  ProfileSettingsCompanion.insert({this.id = const Value.absent(), required int profileId, required String category, required String key, required String value}) : profileId = Value(profileId), category = Value(category), key = Value(key), value = Value(value);
  static Insertable<ProfileSettingRow> custom({Expression<int>? id, Expression<int>? profileId, Expression<String>? category, Expression<String>? key, Expression<String>? value}) { return RawValuesInsertable({if (id != null) 'id': id, if (profileId != null) 'profile_id': profileId, if (category != null) 'category': category, if (key != null) 'key': key, if (value != null) 'value': value}); }
  ProfileSettingsCompanion copyWith({Value<int>? id, Value<int>? profileId, Value<String>? category, Value<String>? key, Value<String>? value}) { return ProfileSettingsCompanion(id: id ?? this.id, profileId: profileId ?? this.profileId, category: category ?? this.category, key: key ?? this.key, value: value ?? this.value); }
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) { final map = <String, Expression>{}; if (id.present) { map['id'] = Variable<int>(id.value); } if (profileId.present) { map['profile_id'] = Variable<int>(profileId.value); } if (category.present) { map['category'] = Variable<String>(category.value); } if (key.present) { map['key'] = Variable<String>(key.value); } if (value.present) { map['value'] = Variable<String>(value.value); } return map; }
  @override
  String toString() { return (StringBuffer('ProfileSettingsCompanion(')..write('id: $id, ')..write('profileId: $profileId, ')..write('category: $category, ')..write('key: $key, ')..write('value: $value')..write(')')).toString(); }
}

// ── $MediaTypeProfilesTable ────────────────────────────────────────
class $MediaTypeProfilesTable extends MediaTypeProfiles with TableInfo<$MediaTypeProfilesTable, MediaTypeProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaTypeProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _mediaTypeMeta = const VerificationMeta('mediaType');
  @override
  late final GeneratedColumn<String> mediaType = GeneratedColumn<String>('media_type', aliasedName, false, type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _profileIdMeta = const VerificationMeta('profileId');
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>('profile_id', aliasedName, false, type: DriftSqlType.int, requiredDuringInsert: true, defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES profiles (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [mediaType, profileId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_type_profiles';
  @override
  VerificationContext validateIntegrity(Insertable<MediaTypeProfileRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('media_type')) { context.handle(_mediaTypeMeta, mediaType.isAcceptableOrUnknown(data['media_type']!, _mediaTypeMeta)); } else if (isInserting) { context.missing(_mediaTypeMeta); }
    if (data.containsKey('profile_id')) { context.handle(_profileIdMeta, profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta)); } else if (isInserting) { context.missing(_profileIdMeta); }
    return context;
  }
  @override
  Set<GeneratedColumn> get $primaryKey => {mediaType};
  @override
  MediaTypeProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaTypeProfileRow(mediaType: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}media_type'])!, profileId: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}profile_id'])!);
  }
  @override
  $MediaTypeProfilesTable createAlias(String alias) { return $MediaTypeProfilesTable(attachedDatabase, alias); }
}

class MediaTypeProfileRow extends DataClass implements Insertable<MediaTypeProfileRow> {
  final String mediaType; final int profileId;
  const MediaTypeProfileRow({required this.mediaType, required this.profileId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) { final map = <String, Expression>{}; map['media_type'] = Variable<String>(mediaType); map['profile_id'] = Variable<int>(profileId); return map; }
  MediaTypeProfilesCompanion toCompanion(bool nullToAbsent) { return MediaTypeProfilesCompanion(mediaType: Value(mediaType), profileId: Value(profileId)); }
  factory MediaTypeProfileRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) { serializer ??= driftRuntimeOptions.defaultSerializer; return MediaTypeProfileRow(mediaType: serializer.fromJson<String>(json['mediaType']), profileId: serializer.fromJson<int>(json['profileId'])); }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) { serializer ??= driftRuntimeOptions.defaultSerializer; return <String, dynamic>{'mediaType': serializer.toJson<String>(mediaType), 'profileId': serializer.toJson<int>(profileId)}; }
  MediaTypeProfileRow copyWith({String? mediaType, int? profileId}) => MediaTypeProfileRow(mediaType: mediaType ?? this.mediaType, profileId: profileId ?? this.profileId);
  MediaTypeProfileRow copyWithCompanion(MediaTypeProfilesCompanion data) { return MediaTypeProfileRow(mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType, profileId: data.profileId.present ? data.profileId.value : this.profileId); }
  @override
  String toString() { return (StringBuffer('MediaTypeProfileRow(')..write('mediaType: $mediaType, ')..write('profileId: $profileId')..write(')')).toString(); }
  @override
  int get hashCode => Object.hash(mediaType, profileId);
  @override
  bool operator ==(Object other) => identical(this, other) || (other is MediaTypeProfileRow && other.mediaType == this.mediaType && other.profileId == this.profileId);
}

class MediaTypeProfilesCompanion extends UpdateCompanion<MediaTypeProfileRow> {
  final Value<String> mediaType; final Value<int> profileId; final Value<int> rowid;
  const MediaTypeProfilesCompanion({this.mediaType = const Value.absent(), this.profileId = const Value.absent(), this.rowid = const Value.absent()});
  MediaTypeProfilesCompanion.insert({required String mediaType, required int profileId, this.rowid = const Value.absent()}) : mediaType = Value(mediaType), profileId = Value(profileId);
  static Insertable<MediaTypeProfileRow> custom({Expression<String>? mediaType, Expression<int>? profileId, Expression<int>? rowid}) { return RawValuesInsertable({if (mediaType != null) 'media_type': mediaType, if (profileId != null) 'profile_id': profileId, if (rowid != null) 'rowid': rowid}); }
  MediaTypeProfilesCompanion copyWith({Value<String>? mediaType, Value<int>? profileId, Value<int>? rowid}) { return MediaTypeProfilesCompanion(mediaType: mediaType ?? this.mediaType, profileId: profileId ?? this.profileId, rowid: rowid ?? this.rowid); }
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) { final map = <String, Expression>{}; if (mediaType.present) { map['media_type'] = Variable<String>(mediaType.value); } if (profileId.present) { map['profile_id'] = Variable<int>(profileId.value); } if (rowid.present) { map['rowid'] = Variable<int>(rowid.value); } return map; }
  @override
  String toString() { return (StringBuffer('MediaTypeProfilesCompanion(')..write('mediaType: $mediaType, ')..write('profileId: $profileId, ')..write('rowid: $rowid')..write(')')).toString(); }
}

// ── $BookProfilesTable ─────────────────────────────────────────────
class $BookProfilesTable extends BookProfiles with TableInfo<$BookProfilesTable, BookProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookUidMeta = const VerificationMeta('bookUid');
  @override
  late final GeneratedColumn<String> bookUid = GeneratedColumn<String>('book_uid', aliasedName, false, type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _profileIdMeta = const VerificationMeta('profileId');
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>('profile_id', aliasedName, false, type: DriftSqlType.int, requiredDuringInsert: true, defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES profiles (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [bookUid, profileId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_profiles';
  @override
  VerificationContext validateIntegrity(Insertable<BookProfileRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_uid')) { context.handle(_bookUidMeta, bookUid.isAcceptableOrUnknown(data['book_uid']!, _bookUidMeta)); } else if (isInserting) { context.missing(_bookUidMeta); }
    if (data.containsKey('profile_id')) { context.handle(_profileIdMeta, profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta)); } else if (isInserting) { context.missing(_profileIdMeta); }
    return context;
  }
  @override
  Set<GeneratedColumn> get $primaryKey => {bookUid};
  @override
  BookProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookProfileRow(bookUid: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}book_uid'])!, profileId: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}profile_id'])!);
  }
  @override
  $BookProfilesTable createAlias(String alias) { return $BookProfilesTable(attachedDatabase, alias); }
}

class BookProfileRow extends DataClass implements Insertable<BookProfileRow> {
  final String bookUid; final int profileId;
  const BookProfileRow({required this.bookUid, required this.profileId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) { final map = <String, Expression>{}; map['book_uid'] = Variable<String>(bookUid); map['profile_id'] = Variable<int>(profileId); return map; }
  BookProfilesCompanion toCompanion(bool nullToAbsent) { return BookProfilesCompanion(bookUid: Value(bookUid), profileId: Value(profileId)); }
  factory BookProfileRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) { serializer ??= driftRuntimeOptions.defaultSerializer; return BookProfileRow(bookUid: serializer.fromJson<String>(json['bookUid']), profileId: serializer.fromJson<int>(json['profileId'])); }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) { serializer ??= driftRuntimeOptions.defaultSerializer; return <String, dynamic>{'bookUid': serializer.toJson<String>(bookUid), 'profileId': serializer.toJson<int>(profileId)}; }
  BookProfileRow copyWith({String? bookUid, int? profileId}) => BookProfileRow(bookUid: bookUid ?? this.bookUid, profileId: profileId ?? this.profileId);
  BookProfileRow copyWithCompanion(BookProfilesCompanion data) { return BookProfileRow(bookUid: data.bookUid.present ? data.bookUid.value : this.bookUid, profileId: data.profileId.present ? data.profileId.value : this.profileId); }
  @override
  String toString() { return (StringBuffer('BookProfileRow(')..write('bookUid: $bookUid, ')..write('profileId: $profileId')..write(')')).toString(); }
  @override
  int get hashCode => Object.hash(bookUid, profileId);
  @override
  bool operator ==(Object other) => identical(this, other) || (other is BookProfileRow && other.bookUid == this.bookUid && other.profileId == this.profileId);
}

class BookProfilesCompanion extends UpdateCompanion<BookProfileRow> {
  final Value<String> bookUid; final Value<int> profileId; final Value<int> rowid;
  const BookProfilesCompanion({this.bookUid = const Value.absent(), this.profileId = const Value.absent(), this.rowid = const Value.absent()});
  BookProfilesCompanion.insert({required String bookUid, required int profileId, this.rowid = const Value.absent()}) : bookUid = Value(bookUid), profileId = Value(profileId);
  static Insertable<BookProfileRow> custom({Expression<String>? bookUid, Expression<int>? profileId, Expression<int>? rowid}) { return RawValuesInsertable({if (bookUid != null) 'book_uid': bookUid, if (profileId != null) 'profile_id': profileId, if (rowid != null) 'rowid': rowid}); }
  BookProfilesCompanion copyWith({Value<String>? bookUid, Value<int>? profileId, Value<int>? rowid}) { return BookProfilesCompanion(bookUid: bookUid ?? this.bookUid, profileId: profileId ?? this.profileId, rowid: rowid ?? this.rowid); }
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) { final map = <String, Expression>{}; if (bookUid.present) { map['book_uid'] = Variable<String>(bookUid.value); } if (profileId.present) { map['profile_id'] = Variable<int>(profileId.value); } if (rowid.present) { map['rowid'] = Variable<int>(rowid.value); } return map; }
  @override
  String toString() { return (StringBuffer('BookProfilesCompanion(')..write('bookUid: $bookUid, ')..write('profileId: $profileId, ')..write('rowid: $rowid')..write(')')).toString(); }
}
