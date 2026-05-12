// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $MediaItemsTable extends MediaItems
    with TableInfo<$MediaItemsTable, MediaItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _mediaIdentifierMeta =
      const VerificationMeta('mediaIdentifier');
  @override
  late final GeneratedColumn<String> mediaIdentifier = GeneratedColumn<String>(
      'media_identifier', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _mediaTypeIdentifierMeta =
      const VerificationMeta('mediaTypeIdentifier');
  @override
  late final GeneratedColumn<String> mediaTypeIdentifier =
      GeneratedColumn<String>('media_type_identifier', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _mediaSourceIdentifierMeta =
      const VerificationMeta('mediaSourceIdentifier');
  @override
  late final GeneratedColumn<String> mediaSourceIdentifier =
      GeneratedColumn<String>('media_source_identifier', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uniqueKeyMeta =
      const VerificationMeta('uniqueKey');
  @override
  late final GeneratedColumn<String> uniqueKey = GeneratedColumn<String>(
      'unique_key', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _base64ImageMeta =
      const VerificationMeta('base64Image');
  @override
  late final GeneratedColumn<String> base64Image = GeneratedColumn<String>(
      'base64_image', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _imageUrlMeta =
      const VerificationMeta('imageUrl');
  @override
  late final GeneratedColumn<String> imageUrl = GeneratedColumn<String>(
      'image_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _audioUrlMeta =
      const VerificationMeta('audioUrl');
  @override
  late final GeneratedColumn<String> audioUrl = GeneratedColumn<String>(
      'audio_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
      'author', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _authorIdentifierMeta =
      const VerificationMeta('authorIdentifier');
  @override
  late final GeneratedColumn<String> authorIdentifier = GeneratedColumn<String>(
      'author_identifier', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _extraUrlMeta =
      const VerificationMeta('extraUrl');
  @override
  late final GeneratedColumn<String> extraUrl = GeneratedColumn<String>(
      'extra_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _extraMeta = const VerificationMeta('extra');
  @override
  late final GeneratedColumn<String> extra = GeneratedColumn<String>(
      'extra', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sourceMetadataMeta =
      const VerificationMeta('sourceMetadata');
  @override
  late final GeneratedColumn<String> sourceMetadata = GeneratedColumn<String>(
      'source_metadata', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _durationMeta =
      const VerificationMeta('duration');
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
      'duration', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _canDeleteMeta =
      const VerificationMeta('canDelete');
  @override
  late final GeneratedColumn<bool> canDelete = GeneratedColumn<bool>(
      'can_delete', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("can_delete" IN (0, 1))'));
  static const VerificationMeta _canEditMeta =
      const VerificationMeta('canEdit');
  @override
  late final GeneratedColumn<bool> canEdit = GeneratedColumn<bool>(
      'can_edit', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("can_edit" IN (0, 1))'));
  static const VerificationMeta _importedAtMeta =
      const VerificationMeta('importedAt');
  @override
  late final GeneratedColumn<int> importedAt = GeneratedColumn<int>(
      'imported_at', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        mediaIdentifier,
        title,
        mediaTypeIdentifier,
        mediaSourceIdentifier,
        uniqueKey,
        base64Image,
        imageUrl,
        audioUrl,
        author,
        authorIdentifier,
        extraUrl,
        extra,
        sourceMetadata,
        position,
        duration,
        canDelete,
        canEdit,
        importedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_items';
  @override
  VerificationContext validateIntegrity(Insertable<MediaItemRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('media_identifier')) {
      context.handle(
          _mediaIdentifierMeta,
          mediaIdentifier.isAcceptableOrUnknown(
              data['media_identifier']!, _mediaIdentifierMeta));
    } else if (isInserting) {
      context.missing(_mediaIdentifierMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('media_type_identifier')) {
      context.handle(
          _mediaTypeIdentifierMeta,
          mediaTypeIdentifier.isAcceptableOrUnknown(
              data['media_type_identifier']!, _mediaTypeIdentifierMeta));
    } else if (isInserting) {
      context.missing(_mediaTypeIdentifierMeta);
    }
    if (data.containsKey('media_source_identifier')) {
      context.handle(
          _mediaSourceIdentifierMeta,
          mediaSourceIdentifier.isAcceptableOrUnknown(
              data['media_source_identifier']!, _mediaSourceIdentifierMeta));
    } else if (isInserting) {
      context.missing(_mediaSourceIdentifierMeta);
    }
    if (data.containsKey('unique_key')) {
      context.handle(_uniqueKeyMeta,
          uniqueKey.isAcceptableOrUnknown(data['unique_key']!, _uniqueKeyMeta));
    } else if (isInserting) {
      context.missing(_uniqueKeyMeta);
    }
    if (data.containsKey('base64_image')) {
      context.handle(
          _base64ImageMeta,
          base64Image.isAcceptableOrUnknown(
              data['base64_image']!, _base64ImageMeta));
    }
    if (data.containsKey('image_url')) {
      context.handle(_imageUrlMeta,
          imageUrl.isAcceptableOrUnknown(data['image_url']!, _imageUrlMeta));
    }
    if (data.containsKey('audio_url')) {
      context.handle(_audioUrlMeta,
          audioUrl.isAcceptableOrUnknown(data['audio_url']!, _audioUrlMeta));
    }
    if (data.containsKey('author')) {
      context.handle(_authorMeta,
          author.isAcceptableOrUnknown(data['author']!, _authorMeta));
    }
    if (data.containsKey('author_identifier')) {
      context.handle(
          _authorIdentifierMeta,
          authorIdentifier.isAcceptableOrUnknown(
              data['author_identifier']!, _authorIdentifierMeta));
    }
    if (data.containsKey('extra_url')) {
      context.handle(_extraUrlMeta,
          extraUrl.isAcceptableOrUnknown(data['extra_url']!, _extraUrlMeta));
    }
    if (data.containsKey('extra')) {
      context.handle(
          _extraMeta, extra.isAcceptableOrUnknown(data['extra']!, _extraMeta));
    }
    if (data.containsKey('source_metadata')) {
      context.handle(
          _sourceMetadataMeta,
          sourceMetadata.isAcceptableOrUnknown(
              data['source_metadata']!, _sourceMetadataMeta));
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('duration')) {
      context.handle(_durationMeta,
          duration.isAcceptableOrUnknown(data['duration']!, _durationMeta));
    } else if (isInserting) {
      context.missing(_durationMeta);
    }
    if (data.containsKey('can_delete')) {
      context.handle(_canDeleteMeta,
          canDelete.isAcceptableOrUnknown(data['can_delete']!, _canDeleteMeta));
    } else if (isInserting) {
      context.missing(_canDeleteMeta);
    }
    if (data.containsKey('can_edit')) {
      context.handle(_canEditMeta,
          canEdit.isAcceptableOrUnknown(data['can_edit']!, _canEditMeta));
    } else if (isInserting) {
      context.missing(_canEditMeta);
    }
    if (data.containsKey('imported_at')) {
      context.handle(
          _importedAtMeta,
          importedAt.isAcceptableOrUnknown(
              data['imported_at']!, _importedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MediaItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaItemRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      mediaIdentifier: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}media_identifier'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      mediaTypeIdentifier: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}media_type_identifier'])!,
      mediaSourceIdentifier: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}media_source_identifier'])!,
      uniqueKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}unique_key'])!,
      base64Image: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}base64_image']),
      imageUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}image_url']),
      audioUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}audio_url']),
      author: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}author']),
      authorIdentifier: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}author_identifier']),
      extraUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}extra_url']),
      extra: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}extra']),
      sourceMetadata: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_metadata']),
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      duration: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}duration'])!,
      canDelete: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}can_delete'])!,
      canEdit: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}can_edit'])!,
      importedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}imported_at'])!,
    );
  }

  @override
  $MediaItemsTable createAlias(String alias) {
    return $MediaItemsTable(attachedDatabase, alias);
  }
}

class MediaItemRow extends DataClass implements Insertable<MediaItemRow> {
  final int id;
  final String mediaIdentifier;
  final String title;
  final String mediaTypeIdentifier;
  final String mediaSourceIdentifier;
  final String uniqueKey;
  final String? base64Image;
  final String? imageUrl;
  final String? audioUrl;
  final String? author;
  final String? authorIdentifier;
  final String? extraUrl;
  final String? extra;
  final String? sourceMetadata;
  final int position;
  final int duration;
  final bool canDelete;
  final bool canEdit;
  final int importedAt;
  const MediaItemRow(
      {required this.id,
      required this.mediaIdentifier,
      required this.title,
      required this.mediaTypeIdentifier,
      required this.mediaSourceIdentifier,
      required this.uniqueKey,
      this.base64Image,
      this.imageUrl,
      this.audioUrl,
      this.author,
      this.authorIdentifier,
      this.extraUrl,
      this.extra,
      this.sourceMetadata,
      required this.position,
      required this.duration,
      required this.canDelete,
      required this.canEdit,
      required this.importedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['media_identifier'] = Variable<String>(mediaIdentifier);
    map['title'] = Variable<String>(title);
    map['media_type_identifier'] = Variable<String>(mediaTypeIdentifier);
    map['media_source_identifier'] = Variable<String>(mediaSourceIdentifier);
    map['unique_key'] = Variable<String>(uniqueKey);
    if (!nullToAbsent || base64Image != null) {
      map['base64_image'] = Variable<String>(base64Image);
    }
    if (!nullToAbsent || imageUrl != null) {
      map['image_url'] = Variable<String>(imageUrl);
    }
    if (!nullToAbsent || audioUrl != null) {
      map['audio_url'] = Variable<String>(audioUrl);
    }
    if (!nullToAbsent || author != null) {
      map['author'] = Variable<String>(author);
    }
    if (!nullToAbsent || authorIdentifier != null) {
      map['author_identifier'] = Variable<String>(authorIdentifier);
    }
    if (!nullToAbsent || extraUrl != null) {
      map['extra_url'] = Variable<String>(extraUrl);
    }
    if (!nullToAbsent || extra != null) {
      map['extra'] = Variable<String>(extra);
    }
    if (!nullToAbsent || sourceMetadata != null) {
      map['source_metadata'] = Variable<String>(sourceMetadata);
    }
    map['position'] = Variable<int>(position);
    map['duration'] = Variable<int>(duration);
    map['can_delete'] = Variable<bool>(canDelete);
    map['can_edit'] = Variable<bool>(canEdit);
    map['imported_at'] = Variable<int>(importedAt);
    return map;
  }

  MediaItemsCompanion toCompanion(bool nullToAbsent) {
    return MediaItemsCompanion(
      id: Value(id),
      mediaIdentifier: Value(mediaIdentifier),
      title: Value(title),
      mediaTypeIdentifier: Value(mediaTypeIdentifier),
      mediaSourceIdentifier: Value(mediaSourceIdentifier),
      uniqueKey: Value(uniqueKey),
      base64Image: base64Image == null && nullToAbsent
          ? const Value.absent()
          : Value(base64Image),
      imageUrl: imageUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(imageUrl),
      audioUrl: audioUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(audioUrl),
      author:
          author == null && nullToAbsent ? const Value.absent() : Value(author),
      authorIdentifier: authorIdentifier == null && nullToAbsent
          ? const Value.absent()
          : Value(authorIdentifier),
      extraUrl: extraUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(extraUrl),
      extra:
          extra == null && nullToAbsent ? const Value.absent() : Value(extra),
      sourceMetadata: sourceMetadata == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceMetadata),
      position: Value(position),
      duration: Value(duration),
      canDelete: Value(canDelete),
      canEdit: Value(canEdit),
      importedAt: Value(importedAt),
    );
  }

  factory MediaItemRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaItemRow(
      id: serializer.fromJson<int>(json['id']),
      mediaIdentifier: serializer.fromJson<String>(json['mediaIdentifier']),
      title: serializer.fromJson<String>(json['title']),
      mediaTypeIdentifier:
          serializer.fromJson<String>(json['mediaTypeIdentifier']),
      mediaSourceIdentifier:
          serializer.fromJson<String>(json['mediaSourceIdentifier']),
      uniqueKey: serializer.fromJson<String>(json['uniqueKey']),
      base64Image: serializer.fromJson<String?>(json['base64Image']),
      imageUrl: serializer.fromJson<String?>(json['imageUrl']),
      audioUrl: serializer.fromJson<String?>(json['audioUrl']),
      author: serializer.fromJson<String?>(json['author']),
      authorIdentifier: serializer.fromJson<String?>(json['authorIdentifier']),
      extraUrl: serializer.fromJson<String?>(json['extraUrl']),
      extra: serializer.fromJson<String?>(json['extra']),
      sourceMetadata: serializer.fromJson<String?>(json['sourceMetadata']),
      position: serializer.fromJson<int>(json['position']),
      duration: serializer.fromJson<int>(json['duration']),
      canDelete: serializer.fromJson<bool>(json['canDelete']),
      canEdit: serializer.fromJson<bool>(json['canEdit']),
      importedAt: serializer.fromJson<int>(json['importedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'mediaIdentifier': serializer.toJson<String>(mediaIdentifier),
      'title': serializer.toJson<String>(title),
      'mediaTypeIdentifier': serializer.toJson<String>(mediaTypeIdentifier),
      'mediaSourceIdentifier': serializer.toJson<String>(mediaSourceIdentifier),
      'uniqueKey': serializer.toJson<String>(uniqueKey),
      'base64Image': serializer.toJson<String?>(base64Image),
      'imageUrl': serializer.toJson<String?>(imageUrl),
      'audioUrl': serializer.toJson<String?>(audioUrl),
      'author': serializer.toJson<String?>(author),
      'authorIdentifier': serializer.toJson<String?>(authorIdentifier),
      'extraUrl': serializer.toJson<String?>(extraUrl),
      'extra': serializer.toJson<String?>(extra),
      'sourceMetadata': serializer.toJson<String?>(sourceMetadata),
      'position': serializer.toJson<int>(position),
      'duration': serializer.toJson<int>(duration),
      'canDelete': serializer.toJson<bool>(canDelete),
      'canEdit': serializer.toJson<bool>(canEdit),
      'importedAt': serializer.toJson<int>(importedAt),
    };
  }

  MediaItemRow copyWith(
          {int? id,
          String? mediaIdentifier,
          String? title,
          String? mediaTypeIdentifier,
          String? mediaSourceIdentifier,
          String? uniqueKey,
          Value<String?> base64Image = const Value.absent(),
          Value<String?> imageUrl = const Value.absent(),
          Value<String?> audioUrl = const Value.absent(),
          Value<String?> author = const Value.absent(),
          Value<String?> authorIdentifier = const Value.absent(),
          Value<String?> extraUrl = const Value.absent(),
          Value<String?> extra = const Value.absent(),
          Value<String?> sourceMetadata = const Value.absent(),
          int? position,
          int? duration,
          bool? canDelete,
          bool? canEdit,
          int? importedAt}) =>
      MediaItemRow(
        id: id ?? this.id,
        mediaIdentifier: mediaIdentifier ?? this.mediaIdentifier,
        title: title ?? this.title,
        mediaTypeIdentifier: mediaTypeIdentifier ?? this.mediaTypeIdentifier,
        mediaSourceIdentifier:
            mediaSourceIdentifier ?? this.mediaSourceIdentifier,
        uniqueKey: uniqueKey ?? this.uniqueKey,
        base64Image: base64Image.present ? base64Image.value : this.base64Image,
        imageUrl: imageUrl.present ? imageUrl.value : this.imageUrl,
        audioUrl: audioUrl.present ? audioUrl.value : this.audioUrl,
        author: author.present ? author.value : this.author,
        authorIdentifier: authorIdentifier.present
            ? authorIdentifier.value
            : this.authorIdentifier,
        extraUrl: extraUrl.present ? extraUrl.value : this.extraUrl,
        extra: extra.present ? extra.value : this.extra,
        sourceMetadata:
            sourceMetadata.present ? sourceMetadata.value : this.sourceMetadata,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        canDelete: canDelete ?? this.canDelete,
        canEdit: canEdit ?? this.canEdit,
        importedAt: importedAt ?? this.importedAt,
      );
  MediaItemRow copyWithCompanion(MediaItemsCompanion data) {
    return MediaItemRow(
      id: data.id.present ? data.id.value : this.id,
      mediaIdentifier: data.mediaIdentifier.present
          ? data.mediaIdentifier.value
          : this.mediaIdentifier,
      title: data.title.present ? data.title.value : this.title,
      mediaTypeIdentifier: data.mediaTypeIdentifier.present
          ? data.mediaTypeIdentifier.value
          : this.mediaTypeIdentifier,
      mediaSourceIdentifier: data.mediaSourceIdentifier.present
          ? data.mediaSourceIdentifier.value
          : this.mediaSourceIdentifier,
      uniqueKey: data.uniqueKey.present ? data.uniqueKey.value : this.uniqueKey,
      base64Image:
          data.base64Image.present ? data.base64Image.value : this.base64Image,
      imageUrl: data.imageUrl.present ? data.imageUrl.value : this.imageUrl,
      audioUrl: data.audioUrl.present ? data.audioUrl.value : this.audioUrl,
      author: data.author.present ? data.author.value : this.author,
      authorIdentifier: data.authorIdentifier.present
          ? data.authorIdentifier.value
          : this.authorIdentifier,
      extraUrl: data.extraUrl.present ? data.extraUrl.value : this.extraUrl,
      extra: data.extra.present ? data.extra.value : this.extra,
      sourceMetadata: data.sourceMetadata.present
          ? data.sourceMetadata.value
          : this.sourceMetadata,
      position: data.position.present ? data.position.value : this.position,
      duration: data.duration.present ? data.duration.value : this.duration,
      canDelete: data.canDelete.present ? data.canDelete.value : this.canDelete,
      canEdit: data.canEdit.present ? data.canEdit.value : this.canEdit,
      importedAt:
          data.importedAt.present ? data.importedAt.value : this.importedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaItemRow(')
          ..write('id: $id, ')
          ..write('mediaIdentifier: $mediaIdentifier, ')
          ..write('title: $title, ')
          ..write('mediaTypeIdentifier: $mediaTypeIdentifier, ')
          ..write('mediaSourceIdentifier: $mediaSourceIdentifier, ')
          ..write('uniqueKey: $uniqueKey, ')
          ..write('base64Image: $base64Image, ')
          ..write('imageUrl: $imageUrl, ')
          ..write('audioUrl: $audioUrl, ')
          ..write('author: $author, ')
          ..write('authorIdentifier: $authorIdentifier, ')
          ..write('extraUrl: $extraUrl, ')
          ..write('extra: $extra, ')
          ..write('sourceMetadata: $sourceMetadata, ')
          ..write('position: $position, ')
          ..write('duration: $duration, ')
          ..write('canDelete: $canDelete, ')
          ..write('canEdit: $canEdit, ')
          ..write('importedAt: $importedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      mediaIdentifier,
      title,
      mediaTypeIdentifier,
      mediaSourceIdentifier,
      uniqueKey,
      base64Image,
      imageUrl,
      audioUrl,
      author,
      authorIdentifier,
      extraUrl,
      extra,
      sourceMetadata,
      position,
      duration,
      canDelete,
      canEdit,
      importedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaItemRow &&
          other.id == this.id &&
          other.mediaIdentifier == this.mediaIdentifier &&
          other.title == this.title &&
          other.mediaTypeIdentifier == this.mediaTypeIdentifier &&
          other.mediaSourceIdentifier == this.mediaSourceIdentifier &&
          other.uniqueKey == this.uniqueKey &&
          other.base64Image == this.base64Image &&
          other.imageUrl == this.imageUrl &&
          other.audioUrl == this.audioUrl &&
          other.author == this.author &&
          other.authorIdentifier == this.authorIdentifier &&
          other.extraUrl == this.extraUrl &&
          other.extra == this.extra &&
          other.sourceMetadata == this.sourceMetadata &&
          other.position == this.position &&
          other.duration == this.duration &&
          other.canDelete == this.canDelete &&
          other.canEdit == this.canEdit &&
          other.importedAt == this.importedAt);
}

class MediaItemsCompanion extends UpdateCompanion<MediaItemRow> {
  final Value<int> id;
  final Value<String> mediaIdentifier;
  final Value<String> title;
  final Value<String> mediaTypeIdentifier;
  final Value<String> mediaSourceIdentifier;
  final Value<String> uniqueKey;
  final Value<String?> base64Image;
  final Value<String?> imageUrl;
  final Value<String?> audioUrl;
  final Value<String?> author;
  final Value<String?> authorIdentifier;
  final Value<String?> extraUrl;
  final Value<String?> extra;
  final Value<String?> sourceMetadata;
  final Value<int> position;
  final Value<int> duration;
  final Value<bool> canDelete;
  final Value<bool> canEdit;
  final Value<int> importedAt;
  const MediaItemsCompanion({
    this.id = const Value.absent(),
    this.mediaIdentifier = const Value.absent(),
    this.title = const Value.absent(),
    this.mediaTypeIdentifier = const Value.absent(),
    this.mediaSourceIdentifier = const Value.absent(),
    this.uniqueKey = const Value.absent(),
    this.base64Image = const Value.absent(),
    this.imageUrl = const Value.absent(),
    this.audioUrl = const Value.absent(),
    this.author = const Value.absent(),
    this.authorIdentifier = const Value.absent(),
    this.extraUrl = const Value.absent(),
    this.extra = const Value.absent(),
    this.sourceMetadata = const Value.absent(),
    this.position = const Value.absent(),
    this.duration = const Value.absent(),
    this.canDelete = const Value.absent(),
    this.canEdit = const Value.absent(),
    this.importedAt = const Value.absent(),
  });
  MediaItemsCompanion.insert({
    this.id = const Value.absent(),
    required String mediaIdentifier,
    required String title,
    required String mediaTypeIdentifier,
    required String mediaSourceIdentifier,
    required String uniqueKey,
    this.base64Image = const Value.absent(),
    this.imageUrl = const Value.absent(),
    this.audioUrl = const Value.absent(),
    this.author = const Value.absent(),
    this.authorIdentifier = const Value.absent(),
    this.extraUrl = const Value.absent(),
    this.extra = const Value.absent(),
    this.sourceMetadata = const Value.absent(),
    required int position,
    required int duration,
    required bool canDelete,
    required bool canEdit,
    this.importedAt = const Value.absent(),
  })  : mediaIdentifier = Value(mediaIdentifier),
        title = Value(title),
        mediaTypeIdentifier = Value(mediaTypeIdentifier),
        mediaSourceIdentifier = Value(mediaSourceIdentifier),
        uniqueKey = Value(uniqueKey),
        position = Value(position),
        duration = Value(duration),
        canDelete = Value(canDelete),
        canEdit = Value(canEdit);
  static Insertable<MediaItemRow> custom({
    Expression<int>? id,
    Expression<String>? mediaIdentifier,
    Expression<String>? title,
    Expression<String>? mediaTypeIdentifier,
    Expression<String>? mediaSourceIdentifier,
    Expression<String>? uniqueKey,
    Expression<String>? base64Image,
    Expression<String>? imageUrl,
    Expression<String>? audioUrl,
    Expression<String>? author,
    Expression<String>? authorIdentifier,
    Expression<String>? extraUrl,
    Expression<String>? extra,
    Expression<String>? sourceMetadata,
    Expression<int>? position,
    Expression<int>? duration,
    Expression<bool>? canDelete,
    Expression<bool>? canEdit,
    Expression<int>? importedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (mediaIdentifier != null) 'media_identifier': mediaIdentifier,
      if (title != null) 'title': title,
      if (mediaTypeIdentifier != null)
        'media_type_identifier': mediaTypeIdentifier,
      if (mediaSourceIdentifier != null)
        'media_source_identifier': mediaSourceIdentifier,
      if (uniqueKey != null) 'unique_key': uniqueKey,
      if (base64Image != null) 'base64_image': base64Image,
      if (imageUrl != null) 'image_url': imageUrl,
      if (audioUrl != null) 'audio_url': audioUrl,
      if (author != null) 'author': author,
      if (authorIdentifier != null) 'author_identifier': authorIdentifier,
      if (extraUrl != null) 'extra_url': extraUrl,
      if (extra != null) 'extra': extra,
      if (sourceMetadata != null) 'source_metadata': sourceMetadata,
      if (position != null) 'position': position,
      if (duration != null) 'duration': duration,
      if (canDelete != null) 'can_delete': canDelete,
      if (canEdit != null) 'can_edit': canEdit,
      if (importedAt != null) 'imported_at': importedAt,
    });
  }

  MediaItemsCompanion copyWith(
      {Value<int>? id,
      Value<String>? mediaIdentifier,
      Value<String>? title,
      Value<String>? mediaTypeIdentifier,
      Value<String>? mediaSourceIdentifier,
      Value<String>? uniqueKey,
      Value<String?>? base64Image,
      Value<String?>? imageUrl,
      Value<String?>? audioUrl,
      Value<String?>? author,
      Value<String?>? authorIdentifier,
      Value<String?>? extraUrl,
      Value<String?>? extra,
      Value<String?>? sourceMetadata,
      Value<int>? position,
      Value<int>? duration,
      Value<bool>? canDelete,
      Value<bool>? canEdit,
      Value<int>? importedAt}) {
    return MediaItemsCompanion(
      id: id ?? this.id,
      mediaIdentifier: mediaIdentifier ?? this.mediaIdentifier,
      title: title ?? this.title,
      mediaTypeIdentifier: mediaTypeIdentifier ?? this.mediaTypeIdentifier,
      mediaSourceIdentifier:
          mediaSourceIdentifier ?? this.mediaSourceIdentifier,
      uniqueKey: uniqueKey ?? this.uniqueKey,
      base64Image: base64Image ?? this.base64Image,
      imageUrl: imageUrl ?? this.imageUrl,
      audioUrl: audioUrl ?? this.audioUrl,
      author: author ?? this.author,
      authorIdentifier: authorIdentifier ?? this.authorIdentifier,
      extraUrl: extraUrl ?? this.extraUrl,
      extra: extra ?? this.extra,
      sourceMetadata: sourceMetadata ?? this.sourceMetadata,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      canDelete: canDelete ?? this.canDelete,
      canEdit: canEdit ?? this.canEdit,
      importedAt: importedAt ?? this.importedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (mediaIdentifier.present) {
      map['media_identifier'] = Variable<String>(mediaIdentifier.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (mediaTypeIdentifier.present) {
      map['media_type_identifier'] =
          Variable<String>(mediaTypeIdentifier.value);
    }
    if (mediaSourceIdentifier.present) {
      map['media_source_identifier'] =
          Variable<String>(mediaSourceIdentifier.value);
    }
    if (uniqueKey.present) {
      map['unique_key'] = Variable<String>(uniqueKey.value);
    }
    if (base64Image.present) {
      map['base64_image'] = Variable<String>(base64Image.value);
    }
    if (imageUrl.present) {
      map['image_url'] = Variable<String>(imageUrl.value);
    }
    if (audioUrl.present) {
      map['audio_url'] = Variable<String>(audioUrl.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (authorIdentifier.present) {
      map['author_identifier'] = Variable<String>(authorIdentifier.value);
    }
    if (extraUrl.present) {
      map['extra_url'] = Variable<String>(extraUrl.value);
    }
    if (extra.present) {
      map['extra'] = Variable<String>(extra.value);
    }
    if (sourceMetadata.present) {
      map['source_metadata'] = Variable<String>(sourceMetadata.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (canDelete.present) {
      map['can_delete'] = Variable<bool>(canDelete.value);
    }
    if (canEdit.present) {
      map['can_edit'] = Variable<bool>(canEdit.value);
    }
    if (importedAt.present) {
      map['imported_at'] = Variable<int>(importedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaItemsCompanion(')
          ..write('id: $id, ')
          ..write('mediaIdentifier: $mediaIdentifier, ')
          ..write('title: $title, ')
          ..write('mediaTypeIdentifier: $mediaTypeIdentifier, ')
          ..write('mediaSourceIdentifier: $mediaSourceIdentifier, ')
          ..write('uniqueKey: $uniqueKey, ')
          ..write('base64Image: $base64Image, ')
          ..write('imageUrl: $imageUrl, ')
          ..write('audioUrl: $audioUrl, ')
          ..write('author: $author, ')
          ..write('authorIdentifier: $authorIdentifier, ')
          ..write('extraUrl: $extraUrl, ')
          ..write('extra: $extra, ')
          ..write('sourceMetadata: $sourceMetadata, ')
          ..write('position: $position, ')
          ..write('duration: $duration, ')
          ..write('canDelete: $canDelete, ')
          ..write('canEdit: $canEdit, ')
          ..write('importedAt: $importedAt')
          ..write(')'))
        .toString();
  }
}

class $SearchHistoryItemsTable extends SearchHistoryItems
    with TableInfo<$SearchHistoryItemsTable, SearchHistoryItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SearchHistoryItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _historyKeyMeta =
      const VerificationMeta('historyKey');
  @override
  late final GeneratedColumn<String> historyKey = GeneratedColumn<String>(
      'history_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _searchTermMeta =
      const VerificationMeta('searchTerm');
  @override
  late final GeneratedColumn<String> searchTerm = GeneratedColumn<String>(
      'search_term', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uniqueKeyMeta =
      const VerificationMeta('uniqueKey');
  @override
  late final GeneratedColumn<String> uniqueKey = GeneratedColumn<String>(
      'unique_key', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  @override
  List<GeneratedColumn> get $columns => [id, historyKey, searchTerm, uniqueKey];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'search_history_items';
  @override
  VerificationContext validateIntegrity(
      Insertable<SearchHistoryItemRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('history_key')) {
      context.handle(
          _historyKeyMeta,
          historyKey.isAcceptableOrUnknown(
              data['history_key']!, _historyKeyMeta));
    } else if (isInserting) {
      context.missing(_historyKeyMeta);
    }
    if (data.containsKey('search_term')) {
      context.handle(
          _searchTermMeta,
          searchTerm.isAcceptableOrUnknown(
              data['search_term']!, _searchTermMeta));
    } else if (isInserting) {
      context.missing(_searchTermMeta);
    }
    if (data.containsKey('unique_key')) {
      context.handle(_uniqueKeyMeta,
          uniqueKey.isAcceptableOrUnknown(data['unique_key']!, _uniqueKeyMeta));
    } else if (isInserting) {
      context.missing(_uniqueKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SearchHistoryItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SearchHistoryItemRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      historyKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}history_key'])!,
      searchTerm: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}search_term'])!,
      uniqueKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}unique_key'])!,
    );
  }

  @override
  $SearchHistoryItemsTable createAlias(String alias) {
    return $SearchHistoryItemsTable(attachedDatabase, alias);
  }
}

class SearchHistoryItemRow extends DataClass
    implements Insertable<SearchHistoryItemRow> {
  final int id;
  final String historyKey;
  final String searchTerm;
  final String uniqueKey;
  const SearchHistoryItemRow(
      {required this.id,
      required this.historyKey,
      required this.searchTerm,
      required this.uniqueKey});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['history_key'] = Variable<String>(historyKey);
    map['search_term'] = Variable<String>(searchTerm);
    map['unique_key'] = Variable<String>(uniqueKey);
    return map;
  }

  SearchHistoryItemsCompanion toCompanion(bool nullToAbsent) {
    return SearchHistoryItemsCompanion(
      id: Value(id),
      historyKey: Value(historyKey),
      searchTerm: Value(searchTerm),
      uniqueKey: Value(uniqueKey),
    );
  }

  factory SearchHistoryItemRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SearchHistoryItemRow(
      id: serializer.fromJson<int>(json['id']),
      historyKey: serializer.fromJson<String>(json['historyKey']),
      searchTerm: serializer.fromJson<String>(json['searchTerm']),
      uniqueKey: serializer.fromJson<String>(json['uniqueKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'historyKey': serializer.toJson<String>(historyKey),
      'searchTerm': serializer.toJson<String>(searchTerm),
      'uniqueKey': serializer.toJson<String>(uniqueKey),
    };
  }

  SearchHistoryItemRow copyWith(
          {int? id,
          String? historyKey,
          String? searchTerm,
          String? uniqueKey}) =>
      SearchHistoryItemRow(
        id: id ?? this.id,
        historyKey: historyKey ?? this.historyKey,
        searchTerm: searchTerm ?? this.searchTerm,
        uniqueKey: uniqueKey ?? this.uniqueKey,
      );
  SearchHistoryItemRow copyWithCompanion(SearchHistoryItemsCompanion data) {
    return SearchHistoryItemRow(
      id: data.id.present ? data.id.value : this.id,
      historyKey:
          data.historyKey.present ? data.historyKey.value : this.historyKey,
      searchTerm:
          data.searchTerm.present ? data.searchTerm.value : this.searchTerm,
      uniqueKey: data.uniqueKey.present ? data.uniqueKey.value : this.uniqueKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SearchHistoryItemRow(')
          ..write('id: $id, ')
          ..write('historyKey: $historyKey, ')
          ..write('searchTerm: $searchTerm, ')
          ..write('uniqueKey: $uniqueKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, historyKey, searchTerm, uniqueKey);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SearchHistoryItemRow &&
          other.id == this.id &&
          other.historyKey == this.historyKey &&
          other.searchTerm == this.searchTerm &&
          other.uniqueKey == this.uniqueKey);
}

class SearchHistoryItemsCompanion
    extends UpdateCompanion<SearchHistoryItemRow> {
  final Value<int> id;
  final Value<String> historyKey;
  final Value<String> searchTerm;
  final Value<String> uniqueKey;
  const SearchHistoryItemsCompanion({
    this.id = const Value.absent(),
    this.historyKey = const Value.absent(),
    this.searchTerm = const Value.absent(),
    this.uniqueKey = const Value.absent(),
  });
  SearchHistoryItemsCompanion.insert({
    this.id = const Value.absent(),
    required String historyKey,
    required String searchTerm,
    required String uniqueKey,
  })  : historyKey = Value(historyKey),
        searchTerm = Value(searchTerm),
        uniqueKey = Value(uniqueKey);
  static Insertable<SearchHistoryItemRow> custom({
    Expression<int>? id,
    Expression<String>? historyKey,
    Expression<String>? searchTerm,
    Expression<String>? uniqueKey,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (historyKey != null) 'history_key': historyKey,
      if (searchTerm != null) 'search_term': searchTerm,
      if (uniqueKey != null) 'unique_key': uniqueKey,
    });
  }

  SearchHistoryItemsCompanion copyWith(
      {Value<int>? id,
      Value<String>? historyKey,
      Value<String>? searchTerm,
      Value<String>? uniqueKey}) {
    return SearchHistoryItemsCompanion(
      id: id ?? this.id,
      historyKey: historyKey ?? this.historyKey,
      searchTerm: searchTerm ?? this.searchTerm,
      uniqueKey: uniqueKey ?? this.uniqueKey,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (historyKey.present) {
      map['history_key'] = Variable<String>(historyKey.value);
    }
    if (searchTerm.present) {
      map['search_term'] = Variable<String>(searchTerm.value);
    }
    if (uniqueKey.present) {
      map['unique_key'] = Variable<String>(uniqueKey.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SearchHistoryItemsCompanion(')
          ..write('id: $id, ')
          ..write('historyKey: $historyKey, ')
          ..write('searchTerm: $searchTerm, ')
          ..write('uniqueKey: $uniqueKey')
          ..write(')'))
        .toString();
  }
}

class $AudiobooksTable extends Audiobooks
    with TableInfo<$AudiobooksTable, AudiobookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AudiobooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _bookUidMeta =
      const VerificationMeta('bookUid');
  @override
  late final GeneratedColumn<String> bookUid = GeneratedColumn<String>(
      'book_uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _audioRootMeta =
      const VerificationMeta('audioRoot');
  @override
  late final GeneratedColumn<String> audioRoot = GeneratedColumn<String>(
      'audio_root', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _audioPathsJsonMeta =
      const VerificationMeta('audioPathsJson');
  @override
  late final GeneratedColumn<String> audioPathsJson = GeneratedColumn<String>(
      'audio_paths_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _alignmentFormatMeta =
      const VerificationMeta('alignmentFormat');
  @override
  late final GeneratedColumn<String> alignmentFormat = GeneratedColumn<String>(
      'alignment_format', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _alignmentPathMeta =
      const VerificationMeta('alignmentPath');
  @override
  late final GeneratedColumn<String> alignmentPath = GeneratedColumn<String>(
      'alignment_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _healthKindRawMeta =
      const VerificationMeta('healthKindRaw');
  @override
  late final GeneratedColumn<String> healthKindRaw = GeneratedColumn<String>(
      'health_kind_raw', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _matchRatePctMeta =
      const VerificationMeta('matchRatePct');
  @override
  late final GeneratedColumn<int> matchRatePct = GeneratedColumn<int>(
      'match_rate_pct', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _healthMeasuredAtMeta =
      const VerificationMeta('healthMeasuredAt');
  @override
  late final GeneratedColumn<DateTime> healthMeasuredAt =
      GeneratedColumn<DateTime>('health_measured_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _healthReasonMeta =
      const VerificationMeta('healthReason');
  @override
  late final GeneratedColumn<String> healthReason = GeneratedColumn<String>(
      'health_reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _followAudioMeta =
      const VerificationMeta('followAudio');
  @override
  late final GeneratedColumn<bool> followAudio = GeneratedColumn<bool>(
      'follow_audio', aliasedName, true,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("follow_audio" IN (0, 1))'));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        bookUid,
        audioRoot,
        audioPathsJson,
        alignmentFormat,
        alignmentPath,
        healthKindRaw,
        matchRatePct,
        healthMeasuredAt,
        healthReason,
        followAudio
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'audiobooks';
  @override
  VerificationContext validateIntegrity(Insertable<AudiobookRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('book_uid')) {
      context.handle(_bookUidMeta,
          bookUid.isAcceptableOrUnknown(data['book_uid']!, _bookUidMeta));
    } else if (isInserting) {
      context.missing(_bookUidMeta);
    }
    if (data.containsKey('audio_root')) {
      context.handle(_audioRootMeta,
          audioRoot.isAcceptableOrUnknown(data['audio_root']!, _audioRootMeta));
    }
    if (data.containsKey('audio_paths_json')) {
      context.handle(
          _audioPathsJsonMeta,
          audioPathsJson.isAcceptableOrUnknown(
              data['audio_paths_json']!, _audioPathsJsonMeta));
    }
    if (data.containsKey('alignment_format')) {
      context.handle(
          _alignmentFormatMeta,
          alignmentFormat.isAcceptableOrUnknown(
              data['alignment_format']!, _alignmentFormatMeta));
    } else if (isInserting) {
      context.missing(_alignmentFormatMeta);
    }
    if (data.containsKey('alignment_path')) {
      context.handle(
          _alignmentPathMeta,
          alignmentPath.isAcceptableOrUnknown(
              data['alignment_path']!, _alignmentPathMeta));
    } else if (isInserting) {
      context.missing(_alignmentPathMeta);
    }
    if (data.containsKey('health_kind_raw')) {
      context.handle(
          _healthKindRawMeta,
          healthKindRaw.isAcceptableOrUnknown(
              data['health_kind_raw']!, _healthKindRawMeta));
    }
    if (data.containsKey('match_rate_pct')) {
      context.handle(
          _matchRatePctMeta,
          matchRatePct.isAcceptableOrUnknown(
              data['match_rate_pct']!, _matchRatePctMeta));
    }
    if (data.containsKey('health_measured_at')) {
      context.handle(
          _healthMeasuredAtMeta,
          healthMeasuredAt.isAcceptableOrUnknown(
              data['health_measured_at']!, _healthMeasuredAtMeta));
    }
    if (data.containsKey('health_reason')) {
      context.handle(
          _healthReasonMeta,
          healthReason.isAcceptableOrUnknown(
              data['health_reason']!, _healthReasonMeta));
    }
    if (data.containsKey('follow_audio')) {
      context.handle(
          _followAudioMeta,
          followAudio.isAcceptableOrUnknown(
              data['follow_audio']!, _followAudioMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AudiobookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AudiobookRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      bookUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_uid'])!,
      audioRoot: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}audio_root']),
      audioPathsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}audio_paths_json']),
      alignmentFormat: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}alignment_format'])!,
      alignmentPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}alignment_path'])!,
      healthKindRaw: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}health_kind_raw']),
      matchRatePct: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}match_rate_pct']),
      healthMeasuredAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}health_measured_at']),
      healthReason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}health_reason']),
      followAudio: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}follow_audio']),
    );
  }

  @override
  $AudiobooksTable createAlias(String alias) {
    return $AudiobooksTable(attachedDatabase, alias);
  }
}

class AudiobookRow extends DataClass implements Insertable<AudiobookRow> {
  final int id;
  final String bookUid;
  final String? audioRoot;
  final String? audioPathsJson;
  final String alignmentFormat;
  final String alignmentPath;
  final String? healthKindRaw;
  final int? matchRatePct;
  final DateTime? healthMeasuredAt;
  final String? healthReason;
  final bool? followAudio;
  const AudiobookRow(
      {required this.id,
      required this.bookUid,
      this.audioRoot,
      this.audioPathsJson,
      required this.alignmentFormat,
      required this.alignmentPath,
      this.healthKindRaw,
      this.matchRatePct,
      this.healthMeasuredAt,
      this.healthReason,
      this.followAudio});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_uid'] = Variable<String>(bookUid);
    if (!nullToAbsent || audioRoot != null) {
      map['audio_root'] = Variable<String>(audioRoot);
    }
    if (!nullToAbsent || audioPathsJson != null) {
      map['audio_paths_json'] = Variable<String>(audioPathsJson);
    }
    map['alignment_format'] = Variable<String>(alignmentFormat);
    map['alignment_path'] = Variable<String>(alignmentPath);
    if (!nullToAbsent || healthKindRaw != null) {
      map['health_kind_raw'] = Variable<String>(healthKindRaw);
    }
    if (!nullToAbsent || matchRatePct != null) {
      map['match_rate_pct'] = Variable<int>(matchRatePct);
    }
    if (!nullToAbsent || healthMeasuredAt != null) {
      map['health_measured_at'] = Variable<DateTime>(healthMeasuredAt);
    }
    if (!nullToAbsent || healthReason != null) {
      map['health_reason'] = Variable<String>(healthReason);
    }
    if (!nullToAbsent || followAudio != null) {
      map['follow_audio'] = Variable<bool>(followAudio);
    }
    return map;
  }

  AudiobooksCompanion toCompanion(bool nullToAbsent) {
    return AudiobooksCompanion(
      id: Value(id),
      bookUid: Value(bookUid),
      audioRoot: audioRoot == null && nullToAbsent
          ? const Value.absent()
          : Value(audioRoot),
      audioPathsJson: audioPathsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(audioPathsJson),
      alignmentFormat: Value(alignmentFormat),
      alignmentPath: Value(alignmentPath),
      healthKindRaw: healthKindRaw == null && nullToAbsent
          ? const Value.absent()
          : Value(healthKindRaw),
      matchRatePct: matchRatePct == null && nullToAbsent
          ? const Value.absent()
          : Value(matchRatePct),
      healthMeasuredAt: healthMeasuredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(healthMeasuredAt),
      healthReason: healthReason == null && nullToAbsent
          ? const Value.absent()
          : Value(healthReason),
      followAudio: followAudio == null && nullToAbsent
          ? const Value.absent()
          : Value(followAudio),
    );
  }

  factory AudiobookRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AudiobookRow(
      id: serializer.fromJson<int>(json['id']),
      bookUid: serializer.fromJson<String>(json['bookUid']),
      audioRoot: serializer.fromJson<String?>(json['audioRoot']),
      audioPathsJson: serializer.fromJson<String?>(json['audioPathsJson']),
      alignmentFormat: serializer.fromJson<String>(json['alignmentFormat']),
      alignmentPath: serializer.fromJson<String>(json['alignmentPath']),
      healthKindRaw: serializer.fromJson<String?>(json['healthKindRaw']),
      matchRatePct: serializer.fromJson<int?>(json['matchRatePct']),
      healthMeasuredAt:
          serializer.fromJson<DateTime?>(json['healthMeasuredAt']),
      healthReason: serializer.fromJson<String?>(json['healthReason']),
      followAudio: serializer.fromJson<bool?>(json['followAudio']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookUid': serializer.toJson<String>(bookUid),
      'audioRoot': serializer.toJson<String?>(audioRoot),
      'audioPathsJson': serializer.toJson<String?>(audioPathsJson),
      'alignmentFormat': serializer.toJson<String>(alignmentFormat),
      'alignmentPath': serializer.toJson<String>(alignmentPath),
      'healthKindRaw': serializer.toJson<String?>(healthKindRaw),
      'matchRatePct': serializer.toJson<int?>(matchRatePct),
      'healthMeasuredAt': serializer.toJson<DateTime?>(healthMeasuredAt),
      'healthReason': serializer.toJson<String?>(healthReason),
      'followAudio': serializer.toJson<bool?>(followAudio),
    };
  }

  AudiobookRow copyWith(
          {int? id,
          String? bookUid,
          Value<String?> audioRoot = const Value.absent(),
          Value<String?> audioPathsJson = const Value.absent(),
          String? alignmentFormat,
          String? alignmentPath,
          Value<String?> healthKindRaw = const Value.absent(),
          Value<int?> matchRatePct = const Value.absent(),
          Value<DateTime?> healthMeasuredAt = const Value.absent(),
          Value<String?> healthReason = const Value.absent(),
          Value<bool?> followAudio = const Value.absent()}) =>
      AudiobookRow(
        id: id ?? this.id,
        bookUid: bookUid ?? this.bookUid,
        audioRoot: audioRoot.present ? audioRoot.value : this.audioRoot,
        audioPathsJson:
            audioPathsJson.present ? audioPathsJson.value : this.audioPathsJson,
        alignmentFormat: alignmentFormat ?? this.alignmentFormat,
        alignmentPath: alignmentPath ?? this.alignmentPath,
        healthKindRaw:
            healthKindRaw.present ? healthKindRaw.value : this.healthKindRaw,
        matchRatePct:
            matchRatePct.present ? matchRatePct.value : this.matchRatePct,
        healthMeasuredAt: healthMeasuredAt.present
            ? healthMeasuredAt.value
            : this.healthMeasuredAt,
        healthReason:
            healthReason.present ? healthReason.value : this.healthReason,
        followAudio: followAudio.present ? followAudio.value : this.followAudio,
      );
  AudiobookRow copyWithCompanion(AudiobooksCompanion data) {
    return AudiobookRow(
      id: data.id.present ? data.id.value : this.id,
      bookUid: data.bookUid.present ? data.bookUid.value : this.bookUid,
      audioRoot: data.audioRoot.present ? data.audioRoot.value : this.audioRoot,
      audioPathsJson: data.audioPathsJson.present
          ? data.audioPathsJson.value
          : this.audioPathsJson,
      alignmentFormat: data.alignmentFormat.present
          ? data.alignmentFormat.value
          : this.alignmentFormat,
      alignmentPath: data.alignmentPath.present
          ? data.alignmentPath.value
          : this.alignmentPath,
      healthKindRaw: data.healthKindRaw.present
          ? data.healthKindRaw.value
          : this.healthKindRaw,
      matchRatePct: data.matchRatePct.present
          ? data.matchRatePct.value
          : this.matchRatePct,
      healthMeasuredAt: data.healthMeasuredAt.present
          ? data.healthMeasuredAt.value
          : this.healthMeasuredAt,
      healthReason: data.healthReason.present
          ? data.healthReason.value
          : this.healthReason,
      followAudio:
          data.followAudio.present ? data.followAudio.value : this.followAudio,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AudiobookRow(')
          ..write('id: $id, ')
          ..write('bookUid: $bookUid, ')
          ..write('audioRoot: $audioRoot, ')
          ..write('audioPathsJson: $audioPathsJson, ')
          ..write('alignmentFormat: $alignmentFormat, ')
          ..write('alignmentPath: $alignmentPath, ')
          ..write('healthKindRaw: $healthKindRaw, ')
          ..write('matchRatePct: $matchRatePct, ')
          ..write('healthMeasuredAt: $healthMeasuredAt, ')
          ..write('healthReason: $healthReason, ')
          ..write('followAudio: $followAudio')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      bookUid,
      audioRoot,
      audioPathsJson,
      alignmentFormat,
      alignmentPath,
      healthKindRaw,
      matchRatePct,
      healthMeasuredAt,
      healthReason,
      followAudio);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudiobookRow &&
          other.id == this.id &&
          other.bookUid == this.bookUid &&
          other.audioRoot == this.audioRoot &&
          other.audioPathsJson == this.audioPathsJson &&
          other.alignmentFormat == this.alignmentFormat &&
          other.alignmentPath == this.alignmentPath &&
          other.healthKindRaw == this.healthKindRaw &&
          other.matchRatePct == this.matchRatePct &&
          other.healthMeasuredAt == this.healthMeasuredAt &&
          other.healthReason == this.healthReason &&
          other.followAudio == this.followAudio);
}

class AudiobooksCompanion extends UpdateCompanion<AudiobookRow> {
  final Value<int> id;
  final Value<String> bookUid;
  final Value<String?> audioRoot;
  final Value<String?> audioPathsJson;
  final Value<String> alignmentFormat;
  final Value<String> alignmentPath;
  final Value<String?> healthKindRaw;
  final Value<int?> matchRatePct;
  final Value<DateTime?> healthMeasuredAt;
  final Value<String?> healthReason;
  final Value<bool?> followAudio;
  const AudiobooksCompanion({
    this.id = const Value.absent(),
    this.bookUid = const Value.absent(),
    this.audioRoot = const Value.absent(),
    this.audioPathsJson = const Value.absent(),
    this.alignmentFormat = const Value.absent(),
    this.alignmentPath = const Value.absent(),
    this.healthKindRaw = const Value.absent(),
    this.matchRatePct = const Value.absent(),
    this.healthMeasuredAt = const Value.absent(),
    this.healthReason = const Value.absent(),
    this.followAudio = const Value.absent(),
  });
  AudiobooksCompanion.insert({
    this.id = const Value.absent(),
    required String bookUid,
    this.audioRoot = const Value.absent(),
    this.audioPathsJson = const Value.absent(),
    required String alignmentFormat,
    required String alignmentPath,
    this.healthKindRaw = const Value.absent(),
    this.matchRatePct = const Value.absent(),
    this.healthMeasuredAt = const Value.absent(),
    this.healthReason = const Value.absent(),
    this.followAudio = const Value.absent(),
  })  : bookUid = Value(bookUid),
        alignmentFormat = Value(alignmentFormat),
        alignmentPath = Value(alignmentPath);
  static Insertable<AudiobookRow> custom({
    Expression<int>? id,
    Expression<String>? bookUid,
    Expression<String>? audioRoot,
    Expression<String>? audioPathsJson,
    Expression<String>? alignmentFormat,
    Expression<String>? alignmentPath,
    Expression<String>? healthKindRaw,
    Expression<int>? matchRatePct,
    Expression<DateTime>? healthMeasuredAt,
    Expression<String>? healthReason,
    Expression<bool>? followAudio,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookUid != null) 'book_uid': bookUid,
      if (audioRoot != null) 'audio_root': audioRoot,
      if (audioPathsJson != null) 'audio_paths_json': audioPathsJson,
      if (alignmentFormat != null) 'alignment_format': alignmentFormat,
      if (alignmentPath != null) 'alignment_path': alignmentPath,
      if (healthKindRaw != null) 'health_kind_raw': healthKindRaw,
      if (matchRatePct != null) 'match_rate_pct': matchRatePct,
      if (healthMeasuredAt != null) 'health_measured_at': healthMeasuredAt,
      if (healthReason != null) 'health_reason': healthReason,
      if (followAudio != null) 'follow_audio': followAudio,
    });
  }

  AudiobooksCompanion copyWith(
      {Value<int>? id,
      Value<String>? bookUid,
      Value<String?>? audioRoot,
      Value<String?>? audioPathsJson,
      Value<String>? alignmentFormat,
      Value<String>? alignmentPath,
      Value<String?>? healthKindRaw,
      Value<int?>? matchRatePct,
      Value<DateTime?>? healthMeasuredAt,
      Value<String?>? healthReason,
      Value<bool?>? followAudio}) {
    return AudiobooksCompanion(
      id: id ?? this.id,
      bookUid: bookUid ?? this.bookUid,
      audioRoot: audioRoot ?? this.audioRoot,
      audioPathsJson: audioPathsJson ?? this.audioPathsJson,
      alignmentFormat: alignmentFormat ?? this.alignmentFormat,
      alignmentPath: alignmentPath ?? this.alignmentPath,
      healthKindRaw: healthKindRaw ?? this.healthKindRaw,
      matchRatePct: matchRatePct ?? this.matchRatePct,
      healthMeasuredAt: healthMeasuredAt ?? this.healthMeasuredAt,
      healthReason: healthReason ?? this.healthReason,
      followAudio: followAudio ?? this.followAudio,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookUid.present) {
      map['book_uid'] = Variable<String>(bookUid.value);
    }
    if (audioRoot.present) {
      map['audio_root'] = Variable<String>(audioRoot.value);
    }
    if (audioPathsJson.present) {
      map['audio_paths_json'] = Variable<String>(audioPathsJson.value);
    }
    if (alignmentFormat.present) {
      map['alignment_format'] = Variable<String>(alignmentFormat.value);
    }
    if (alignmentPath.present) {
      map['alignment_path'] = Variable<String>(alignmentPath.value);
    }
    if (healthKindRaw.present) {
      map['health_kind_raw'] = Variable<String>(healthKindRaw.value);
    }
    if (matchRatePct.present) {
      map['match_rate_pct'] = Variable<int>(matchRatePct.value);
    }
    if (healthMeasuredAt.present) {
      map['health_measured_at'] = Variable<DateTime>(healthMeasuredAt.value);
    }
    if (healthReason.present) {
      map['health_reason'] = Variable<String>(healthReason.value);
    }
    if (followAudio.present) {
      map['follow_audio'] = Variable<bool>(followAudio.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AudiobooksCompanion(')
          ..write('id: $id, ')
          ..write('bookUid: $bookUid, ')
          ..write('audioRoot: $audioRoot, ')
          ..write('audioPathsJson: $audioPathsJson, ')
          ..write('alignmentFormat: $alignmentFormat, ')
          ..write('alignmentPath: $alignmentPath, ')
          ..write('healthKindRaw: $healthKindRaw, ')
          ..write('matchRatePct: $matchRatePct, ')
          ..write('healthMeasuredAt: $healthMeasuredAt, ')
          ..write('healthReason: $healthReason, ')
          ..write('followAudio: $followAudio')
          ..write(')'))
        .toString();
  }
}

class $AudioCuesTable extends AudioCues
    with TableInfo<$AudioCuesTable, AudioCueRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AudioCuesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _bookUidMeta =
      const VerificationMeta('bookUid');
  @override
  late final GeneratedColumn<String> bookUid = GeneratedColumn<String>(
      'book_uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _chapterHrefMeta =
      const VerificationMeta('chapterHref');
  @override
  late final GeneratedColumn<String> chapterHref = GeneratedColumn<String>(
      'chapter_href', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sentenceIndexMeta =
      const VerificationMeta('sentenceIndex');
  @override
  late final GeneratedColumn<int> sentenceIndex = GeneratedColumn<int>(
      'sentence_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _textFragmentIdMeta =
      const VerificationMeta('textFragmentId');
  @override
  late final GeneratedColumn<String> textFragmentId = GeneratedColumn<String>(
      'text_fragment_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _cueTextMeta =
      const VerificationMeta('cueText');
  @override
  late final GeneratedColumn<String> cueText = GeneratedColumn<String>(
      'cue_text', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _startMsMeta =
      const VerificationMeta('startMs');
  @override
  late final GeneratedColumn<int> startMs = GeneratedColumn<int>(
      'start_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _endMsMeta = const VerificationMeta('endMs');
  @override
  late final GeneratedColumn<int> endMs = GeneratedColumn<int>(
      'end_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _audioFileIndexMeta =
      const VerificationMeta('audioFileIndex');
  @override
  late final GeneratedColumn<int> audioFileIndex = GeneratedColumn<int>(
      'audio_file_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        bookUid,
        chapterHref,
        sentenceIndex,
        textFragmentId,
        cueText,
        startMs,
        endMs,
        audioFileIndex
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'audio_cues';
  @override
  VerificationContext validateIntegrity(Insertable<AudioCueRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('book_uid')) {
      context.handle(_bookUidMeta,
          bookUid.isAcceptableOrUnknown(data['book_uid']!, _bookUidMeta));
    } else if (isInserting) {
      context.missing(_bookUidMeta);
    }
    if (data.containsKey('chapter_href')) {
      context.handle(
          _chapterHrefMeta,
          chapterHref.isAcceptableOrUnknown(
              data['chapter_href']!, _chapterHrefMeta));
    } else if (isInserting) {
      context.missing(_chapterHrefMeta);
    }
    if (data.containsKey('sentence_index')) {
      context.handle(
          _sentenceIndexMeta,
          sentenceIndex.isAcceptableOrUnknown(
              data['sentence_index']!, _sentenceIndexMeta));
    } else if (isInserting) {
      context.missing(_sentenceIndexMeta);
    }
    if (data.containsKey('text_fragment_id')) {
      context.handle(
          _textFragmentIdMeta,
          textFragmentId.isAcceptableOrUnknown(
              data['text_fragment_id']!, _textFragmentIdMeta));
    } else if (isInserting) {
      context.missing(_textFragmentIdMeta);
    }
    if (data.containsKey('cue_text')) {
      context.handle(_cueTextMeta,
          cueText.isAcceptableOrUnknown(data['cue_text']!, _cueTextMeta));
    } else if (isInserting) {
      context.missing(_cueTextMeta);
    }
    if (data.containsKey('start_ms')) {
      context.handle(_startMsMeta,
          startMs.isAcceptableOrUnknown(data['start_ms']!, _startMsMeta));
    } else if (isInserting) {
      context.missing(_startMsMeta);
    }
    if (data.containsKey('end_ms')) {
      context.handle(
          _endMsMeta, endMs.isAcceptableOrUnknown(data['end_ms']!, _endMsMeta));
    } else if (isInserting) {
      context.missing(_endMsMeta);
    }
    if (data.containsKey('audio_file_index')) {
      context.handle(
          _audioFileIndexMeta,
          audioFileIndex.isAcceptableOrUnknown(
              data['audio_file_index']!, _audioFileIndexMeta));
    } else if (isInserting) {
      context.missing(_audioFileIndexMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AudioCueRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AudioCueRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      bookUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_uid'])!,
      chapterHref: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}chapter_href'])!,
      sentenceIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sentence_index'])!,
      textFragmentId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}text_fragment_id'])!,
      cueText: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cue_text'])!,
      startMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}start_ms'])!,
      endMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}end_ms'])!,
      audioFileIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}audio_file_index'])!,
    );
  }

  @override
  $AudioCuesTable createAlias(String alias) {
    return $AudioCuesTable(attachedDatabase, alias);
  }
}

class AudioCueRow extends DataClass implements Insertable<AudioCueRow> {
  final int id;
  final String bookUid;
  final String chapterHref;
  final int sentenceIndex;
  final String textFragmentId;
  final String cueText;
  final int startMs;
  final int endMs;
  final int audioFileIndex;
  const AudioCueRow(
      {required this.id,
      required this.bookUid,
      required this.chapterHref,
      required this.sentenceIndex,
      required this.textFragmentId,
      required this.cueText,
      required this.startMs,
      required this.endMs,
      required this.audioFileIndex});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_uid'] = Variable<String>(bookUid);
    map['chapter_href'] = Variable<String>(chapterHref);
    map['sentence_index'] = Variable<int>(sentenceIndex);
    map['text_fragment_id'] = Variable<String>(textFragmentId);
    map['cue_text'] = Variable<String>(cueText);
    map['start_ms'] = Variable<int>(startMs);
    map['end_ms'] = Variable<int>(endMs);
    map['audio_file_index'] = Variable<int>(audioFileIndex);
    return map;
  }

  AudioCuesCompanion toCompanion(bool nullToAbsent) {
    return AudioCuesCompanion(
      id: Value(id),
      bookUid: Value(bookUid),
      chapterHref: Value(chapterHref),
      sentenceIndex: Value(sentenceIndex),
      textFragmentId: Value(textFragmentId),
      cueText: Value(cueText),
      startMs: Value(startMs),
      endMs: Value(endMs),
      audioFileIndex: Value(audioFileIndex),
    );
  }

  factory AudioCueRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AudioCueRow(
      id: serializer.fromJson<int>(json['id']),
      bookUid: serializer.fromJson<String>(json['bookUid']),
      chapterHref: serializer.fromJson<String>(json['chapterHref']),
      sentenceIndex: serializer.fromJson<int>(json['sentenceIndex']),
      textFragmentId: serializer.fromJson<String>(json['textFragmentId']),
      cueText: serializer.fromJson<String>(json['cueText']),
      startMs: serializer.fromJson<int>(json['startMs']),
      endMs: serializer.fromJson<int>(json['endMs']),
      audioFileIndex: serializer.fromJson<int>(json['audioFileIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookUid': serializer.toJson<String>(bookUid),
      'chapterHref': serializer.toJson<String>(chapterHref),
      'sentenceIndex': serializer.toJson<int>(sentenceIndex),
      'textFragmentId': serializer.toJson<String>(textFragmentId),
      'cueText': serializer.toJson<String>(cueText),
      'startMs': serializer.toJson<int>(startMs),
      'endMs': serializer.toJson<int>(endMs),
      'audioFileIndex': serializer.toJson<int>(audioFileIndex),
    };
  }

  AudioCueRow copyWith(
          {int? id,
          String? bookUid,
          String? chapterHref,
          int? sentenceIndex,
          String? textFragmentId,
          String? cueText,
          int? startMs,
          int? endMs,
          int? audioFileIndex}) =>
      AudioCueRow(
        id: id ?? this.id,
        bookUid: bookUid ?? this.bookUid,
        chapterHref: chapterHref ?? this.chapterHref,
        sentenceIndex: sentenceIndex ?? this.sentenceIndex,
        textFragmentId: textFragmentId ?? this.textFragmentId,
        cueText: cueText ?? this.cueText,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        audioFileIndex: audioFileIndex ?? this.audioFileIndex,
      );
  AudioCueRow copyWithCompanion(AudioCuesCompanion data) {
    return AudioCueRow(
      id: data.id.present ? data.id.value : this.id,
      bookUid: data.bookUid.present ? data.bookUid.value : this.bookUid,
      chapterHref:
          data.chapterHref.present ? data.chapterHref.value : this.chapterHref,
      sentenceIndex: data.sentenceIndex.present
          ? data.sentenceIndex.value
          : this.sentenceIndex,
      textFragmentId: data.textFragmentId.present
          ? data.textFragmentId.value
          : this.textFragmentId,
      cueText: data.cueText.present ? data.cueText.value : this.cueText,
      startMs: data.startMs.present ? data.startMs.value : this.startMs,
      endMs: data.endMs.present ? data.endMs.value : this.endMs,
      audioFileIndex: data.audioFileIndex.present
          ? data.audioFileIndex.value
          : this.audioFileIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AudioCueRow(')
          ..write('id: $id, ')
          ..write('bookUid: $bookUid, ')
          ..write('chapterHref: $chapterHref, ')
          ..write('sentenceIndex: $sentenceIndex, ')
          ..write('textFragmentId: $textFragmentId, ')
          ..write('cueText: $cueText, ')
          ..write('startMs: $startMs, ')
          ..write('endMs: $endMs, ')
          ..write('audioFileIndex: $audioFileIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, bookUid, chapterHref, sentenceIndex,
      textFragmentId, cueText, startMs, endMs, audioFileIndex);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioCueRow &&
          other.id == this.id &&
          other.bookUid == this.bookUid &&
          other.chapterHref == this.chapterHref &&
          other.sentenceIndex == this.sentenceIndex &&
          other.textFragmentId == this.textFragmentId &&
          other.cueText == this.cueText &&
          other.startMs == this.startMs &&
          other.endMs == this.endMs &&
          other.audioFileIndex == this.audioFileIndex);
}

class AudioCuesCompanion extends UpdateCompanion<AudioCueRow> {
  final Value<int> id;
  final Value<String> bookUid;
  final Value<String> chapterHref;
  final Value<int> sentenceIndex;
  final Value<String> textFragmentId;
  final Value<String> cueText;
  final Value<int> startMs;
  final Value<int> endMs;
  final Value<int> audioFileIndex;
  const AudioCuesCompanion({
    this.id = const Value.absent(),
    this.bookUid = const Value.absent(),
    this.chapterHref = const Value.absent(),
    this.sentenceIndex = const Value.absent(),
    this.textFragmentId = const Value.absent(),
    this.cueText = const Value.absent(),
    this.startMs = const Value.absent(),
    this.endMs = const Value.absent(),
    this.audioFileIndex = const Value.absent(),
  });
  AudioCuesCompanion.insert({
    this.id = const Value.absent(),
    required String bookUid,
    required String chapterHref,
    required int sentenceIndex,
    required String textFragmentId,
    required String cueText,
    required int startMs,
    required int endMs,
    required int audioFileIndex,
  })  : bookUid = Value(bookUid),
        chapterHref = Value(chapterHref),
        sentenceIndex = Value(sentenceIndex),
        textFragmentId = Value(textFragmentId),
        cueText = Value(cueText),
        startMs = Value(startMs),
        endMs = Value(endMs),
        audioFileIndex = Value(audioFileIndex);
  static Insertable<AudioCueRow> custom({
    Expression<int>? id,
    Expression<String>? bookUid,
    Expression<String>? chapterHref,
    Expression<int>? sentenceIndex,
    Expression<String>? textFragmentId,
    Expression<String>? cueText,
    Expression<int>? startMs,
    Expression<int>? endMs,
    Expression<int>? audioFileIndex,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookUid != null) 'book_uid': bookUid,
      if (chapterHref != null) 'chapter_href': chapterHref,
      if (sentenceIndex != null) 'sentence_index': sentenceIndex,
      if (textFragmentId != null) 'text_fragment_id': textFragmentId,
      if (cueText != null) 'cue_text': cueText,
      if (startMs != null) 'start_ms': startMs,
      if (endMs != null) 'end_ms': endMs,
      if (audioFileIndex != null) 'audio_file_index': audioFileIndex,
    });
  }

  AudioCuesCompanion copyWith(
      {Value<int>? id,
      Value<String>? bookUid,
      Value<String>? chapterHref,
      Value<int>? sentenceIndex,
      Value<String>? textFragmentId,
      Value<String>? cueText,
      Value<int>? startMs,
      Value<int>? endMs,
      Value<int>? audioFileIndex}) {
    return AudioCuesCompanion(
      id: id ?? this.id,
      bookUid: bookUid ?? this.bookUid,
      chapterHref: chapterHref ?? this.chapterHref,
      sentenceIndex: sentenceIndex ?? this.sentenceIndex,
      textFragmentId: textFragmentId ?? this.textFragmentId,
      cueText: cueText ?? this.cueText,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      audioFileIndex: audioFileIndex ?? this.audioFileIndex,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookUid.present) {
      map['book_uid'] = Variable<String>(bookUid.value);
    }
    if (chapterHref.present) {
      map['chapter_href'] = Variable<String>(chapterHref.value);
    }
    if (sentenceIndex.present) {
      map['sentence_index'] = Variable<int>(sentenceIndex.value);
    }
    if (textFragmentId.present) {
      map['text_fragment_id'] = Variable<String>(textFragmentId.value);
    }
    if (cueText.present) {
      map['cue_text'] = Variable<String>(cueText.value);
    }
    if (startMs.present) {
      map['start_ms'] = Variable<int>(startMs.value);
    }
    if (endMs.present) {
      map['end_ms'] = Variable<int>(endMs.value);
    }
    if (audioFileIndex.present) {
      map['audio_file_index'] = Variable<int>(audioFileIndex.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AudioCuesCompanion(')
          ..write('id: $id, ')
          ..write('bookUid: $bookUid, ')
          ..write('chapterHref: $chapterHref, ')
          ..write('sentenceIndex: $sentenceIndex, ')
          ..write('textFragmentId: $textFragmentId, ')
          ..write('cueText: $cueText, ')
          ..write('startMs: $startMs, ')
          ..write('endMs: $endMs, ')
          ..write('audioFileIndex: $audioFileIndex')
          ..write(')'))
        .toString();
  }
}

class $SrtBooksTable extends SrtBooks
    with TableInfo<$SrtBooksTable, SrtBookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrtBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uidMeta = const VerificationMeta('uid');
  @override
  late final GeneratedColumn<String> uid = GeneratedColumn<String>(
      'uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
      'author', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _audioRootMeta =
      const VerificationMeta('audioRoot');
  @override
  late final GeneratedColumn<String> audioRoot = GeneratedColumn<String>(
      'audio_root', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _audioPathsJsonMeta =
      const VerificationMeta('audioPathsJson');
  @override
  late final GeneratedColumn<String> audioPathsJson = GeneratedColumn<String>(
      'audio_paths_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _srtPathMeta =
      const VerificationMeta('srtPath');
  @override
  late final GeneratedColumn<String> srtPath = GeneratedColumn<String>(
      'srt_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _coverPathMeta =
      const VerificationMeta('coverPath');
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
      'cover_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _importedAtMeta =
      const VerificationMeta('importedAt');
  @override
  late final GeneratedColumn<int> importedAt = GeneratedColumn<int>(
      'imported_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _ttuBookIdMeta =
      const VerificationMeta('ttuBookId');
  @override
  late final GeneratedColumn<int> ttuBookId = GeneratedColumn<int>(
      'ttu_book_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uid,
        title,
        author,
        audioRoot,
        audioPathsJson,
        srtPath,
        coverPath,
        importedAt,
        ttuBookId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srt_books';
  @override
  VerificationContext validateIntegrity(Insertable<SrtBookRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uid')) {
      context.handle(
          _uidMeta, uid.isAcceptableOrUnknown(data['uid']!, _uidMeta));
    } else if (isInserting) {
      context.missing(_uidMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('author')) {
      context.handle(_authorMeta,
          author.isAcceptableOrUnknown(data['author']!, _authorMeta));
    }
    if (data.containsKey('audio_root')) {
      context.handle(_audioRootMeta,
          audioRoot.isAcceptableOrUnknown(data['audio_root']!, _audioRootMeta));
    }
    if (data.containsKey('audio_paths_json')) {
      context.handle(
          _audioPathsJsonMeta,
          audioPathsJson.isAcceptableOrUnknown(
              data['audio_paths_json']!, _audioPathsJsonMeta));
    }
    if (data.containsKey('srt_path')) {
      context.handle(_srtPathMeta,
          srtPath.isAcceptableOrUnknown(data['srt_path']!, _srtPathMeta));
    } else if (isInserting) {
      context.missing(_srtPathMeta);
    }
    if (data.containsKey('cover_path')) {
      context.handle(_coverPathMeta,
          coverPath.isAcceptableOrUnknown(data['cover_path']!, _coverPathMeta));
    }
    if (data.containsKey('imported_at')) {
      context.handle(
          _importedAtMeta,
          importedAt.isAcceptableOrUnknown(
              data['imported_at']!, _importedAtMeta));
    } else if (isInserting) {
      context.missing(_importedAtMeta);
    }
    if (data.containsKey('ttu_book_id')) {
      context.handle(
          _ttuBookIdMeta,
          ttuBookId.isAcceptableOrUnknown(
              data['ttu_book_id']!, _ttuBookIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SrtBookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrtBookRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uid'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      author: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}author']),
      audioRoot: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}audio_root']),
      audioPathsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}audio_paths_json']),
      srtPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}srt_path'])!,
      coverPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cover_path']),
      importedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}imported_at'])!,
      ttuBookId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ttu_book_id'])!,
    );
  }

  @override
  $SrtBooksTable createAlias(String alias) {
    return $SrtBooksTable(attachedDatabase, alias);
  }
}

class SrtBookRow extends DataClass implements Insertable<SrtBookRow> {
  final int id;
  final String uid;
  final String title;
  final String? author;
  final String? audioRoot;
  final String? audioPathsJson;
  final String srtPath;
  final String? coverPath;
  final int importedAt;
  final int ttuBookId;
  const SrtBookRow(
      {required this.id,
      required this.uid,
      required this.title,
      this.author,
      this.audioRoot,
      this.audioPathsJson,
      required this.srtPath,
      this.coverPath,
      required this.importedAt,
      required this.ttuBookId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uid'] = Variable<String>(uid);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || author != null) {
      map['author'] = Variable<String>(author);
    }
    if (!nullToAbsent || audioRoot != null) {
      map['audio_root'] = Variable<String>(audioRoot);
    }
    if (!nullToAbsent || audioPathsJson != null) {
      map['audio_paths_json'] = Variable<String>(audioPathsJson);
    }
    map['srt_path'] = Variable<String>(srtPath);
    if (!nullToAbsent || coverPath != null) {
      map['cover_path'] = Variable<String>(coverPath);
    }
    map['imported_at'] = Variable<int>(importedAt);
    map['ttu_book_id'] = Variable<int>(ttuBookId);
    return map;
  }

  SrtBooksCompanion toCompanion(bool nullToAbsent) {
    return SrtBooksCompanion(
      id: Value(id),
      uid: Value(uid),
      title: Value(title),
      author:
          author == null && nullToAbsent ? const Value.absent() : Value(author),
      audioRoot: audioRoot == null && nullToAbsent
          ? const Value.absent()
          : Value(audioRoot),
      audioPathsJson: audioPathsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(audioPathsJson),
      srtPath: Value(srtPath),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      importedAt: Value(importedAt),
      ttuBookId: Value(ttuBookId),
    );
  }

  factory SrtBookRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrtBookRow(
      id: serializer.fromJson<int>(json['id']),
      uid: serializer.fromJson<String>(json['uid']),
      title: serializer.fromJson<String>(json['title']),
      author: serializer.fromJson<String?>(json['author']),
      audioRoot: serializer.fromJson<String?>(json['audioRoot']),
      audioPathsJson: serializer.fromJson<String?>(json['audioPathsJson']),
      srtPath: serializer.fromJson<String>(json['srtPath']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      importedAt: serializer.fromJson<int>(json['importedAt']),
      ttuBookId: serializer.fromJson<int>(json['ttuBookId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uid': serializer.toJson<String>(uid),
      'title': serializer.toJson<String>(title),
      'author': serializer.toJson<String?>(author),
      'audioRoot': serializer.toJson<String?>(audioRoot),
      'audioPathsJson': serializer.toJson<String?>(audioPathsJson),
      'srtPath': serializer.toJson<String>(srtPath),
      'coverPath': serializer.toJson<String?>(coverPath),
      'importedAt': serializer.toJson<int>(importedAt),
      'ttuBookId': serializer.toJson<int>(ttuBookId),
    };
  }

  SrtBookRow copyWith(
          {int? id,
          String? uid,
          String? title,
          Value<String?> author = const Value.absent(),
          Value<String?> audioRoot = const Value.absent(),
          Value<String?> audioPathsJson = const Value.absent(),
          String? srtPath,
          Value<String?> coverPath = const Value.absent(),
          int? importedAt,
          int? ttuBookId}) =>
      SrtBookRow(
        id: id ?? this.id,
        uid: uid ?? this.uid,
        title: title ?? this.title,
        author: author.present ? author.value : this.author,
        audioRoot: audioRoot.present ? audioRoot.value : this.audioRoot,
        audioPathsJson:
            audioPathsJson.present ? audioPathsJson.value : this.audioPathsJson,
        srtPath: srtPath ?? this.srtPath,
        coverPath: coverPath.present ? coverPath.value : this.coverPath,
        importedAt: importedAt ?? this.importedAt,
        ttuBookId: ttuBookId ?? this.ttuBookId,
      );
  SrtBookRow copyWithCompanion(SrtBooksCompanion data) {
    return SrtBookRow(
      id: data.id.present ? data.id.value : this.id,
      uid: data.uid.present ? data.uid.value : this.uid,
      title: data.title.present ? data.title.value : this.title,
      author: data.author.present ? data.author.value : this.author,
      audioRoot: data.audioRoot.present ? data.audioRoot.value : this.audioRoot,
      audioPathsJson: data.audioPathsJson.present
          ? data.audioPathsJson.value
          : this.audioPathsJson,
      srtPath: data.srtPath.present ? data.srtPath.value : this.srtPath,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      importedAt:
          data.importedAt.present ? data.importedAt.value : this.importedAt,
      ttuBookId: data.ttuBookId.present ? data.ttuBookId.value : this.ttuBookId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrtBookRow(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('audioRoot: $audioRoot, ')
          ..write('audioPathsJson: $audioPathsJson, ')
          ..write('srtPath: $srtPath, ')
          ..write('coverPath: $coverPath, ')
          ..write('importedAt: $importedAt, ')
          ..write('ttuBookId: $ttuBookId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uid, title, author, audioRoot,
      audioPathsJson, srtPath, coverPath, importedAt, ttuBookId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrtBookRow &&
          other.id == this.id &&
          other.uid == this.uid &&
          other.title == this.title &&
          other.author == this.author &&
          other.audioRoot == this.audioRoot &&
          other.audioPathsJson == this.audioPathsJson &&
          other.srtPath == this.srtPath &&
          other.coverPath == this.coverPath &&
          other.importedAt == this.importedAt &&
          other.ttuBookId == this.ttuBookId);
}

class SrtBooksCompanion extends UpdateCompanion<SrtBookRow> {
  final Value<int> id;
  final Value<String> uid;
  final Value<String> title;
  final Value<String?> author;
  final Value<String?> audioRoot;
  final Value<String?> audioPathsJson;
  final Value<String> srtPath;
  final Value<String?> coverPath;
  final Value<int> importedAt;
  final Value<int> ttuBookId;
  const SrtBooksCompanion({
    this.id = const Value.absent(),
    this.uid = const Value.absent(),
    this.title = const Value.absent(),
    this.author = const Value.absent(),
    this.audioRoot = const Value.absent(),
    this.audioPathsJson = const Value.absent(),
    this.srtPath = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.importedAt = const Value.absent(),
    this.ttuBookId = const Value.absent(),
  });
  SrtBooksCompanion.insert({
    this.id = const Value.absent(),
    required String uid,
    required String title,
    this.author = const Value.absent(),
    this.audioRoot = const Value.absent(),
    this.audioPathsJson = const Value.absent(),
    required String srtPath,
    this.coverPath = const Value.absent(),
    required int importedAt,
    this.ttuBookId = const Value.absent(),
  })  : uid = Value(uid),
        title = Value(title),
        srtPath = Value(srtPath),
        importedAt = Value(importedAt);
  static Insertable<SrtBookRow> custom({
    Expression<int>? id,
    Expression<String>? uid,
    Expression<String>? title,
    Expression<String>? author,
    Expression<String>? audioRoot,
    Expression<String>? audioPathsJson,
    Expression<String>? srtPath,
    Expression<String>? coverPath,
    Expression<int>? importedAt,
    Expression<int>? ttuBookId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uid != null) 'uid': uid,
      if (title != null) 'title': title,
      if (author != null) 'author': author,
      if (audioRoot != null) 'audio_root': audioRoot,
      if (audioPathsJson != null) 'audio_paths_json': audioPathsJson,
      if (srtPath != null) 'srt_path': srtPath,
      if (coverPath != null) 'cover_path': coverPath,
      if (importedAt != null) 'imported_at': importedAt,
      if (ttuBookId != null) 'ttu_book_id': ttuBookId,
    });
  }

  SrtBooksCompanion copyWith(
      {Value<int>? id,
      Value<String>? uid,
      Value<String>? title,
      Value<String?>? author,
      Value<String?>? audioRoot,
      Value<String?>? audioPathsJson,
      Value<String>? srtPath,
      Value<String?>? coverPath,
      Value<int>? importedAt,
      Value<int>? ttuBookId}) {
    return SrtBooksCompanion(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      title: title ?? this.title,
      author: author ?? this.author,
      audioRoot: audioRoot ?? this.audioRoot,
      audioPathsJson: audioPathsJson ?? this.audioPathsJson,
      srtPath: srtPath ?? this.srtPath,
      coverPath: coverPath ?? this.coverPath,
      importedAt: importedAt ?? this.importedAt,
      ttuBookId: ttuBookId ?? this.ttuBookId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uid.present) {
      map['uid'] = Variable<String>(uid.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (audioRoot.present) {
      map['audio_root'] = Variable<String>(audioRoot.value);
    }
    if (audioPathsJson.present) {
      map['audio_paths_json'] = Variable<String>(audioPathsJson.value);
    }
    if (srtPath.present) {
      map['srt_path'] = Variable<String>(srtPath.value);
    }
    if (coverPath.present) {
      map['cover_path'] = Variable<String>(coverPath.value);
    }
    if (importedAt.present) {
      map['imported_at'] = Variable<int>(importedAt.value);
    }
    if (ttuBookId.present) {
      map['ttu_book_id'] = Variable<int>(ttuBookId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrtBooksCompanion(')
          ..write('id: $id, ')
          ..write('uid: $uid, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('audioRoot: $audioRoot, ')
          ..write('audioPathsJson: $audioPathsJson, ')
          ..write('srtPath: $srtPath, ')
          ..write('coverPath: $coverPath, ')
          ..write('importedAt: $importedAt, ')
          ..write('ttuBookId: $ttuBookId')
          ..write(')'))
        .toString();
  }
}

class $ReaderPositionsTable extends ReaderPositions
    with TableInfo<$ReaderPositionsTable, ReaderPositionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReaderPositionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _ttuBookIdMeta =
      const VerificationMeta('ttuBookId');
  @override
  late final GeneratedColumn<int> ttuBookId = GeneratedColumn<int>(
      'ttu_book_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _sectionIndexMeta =
      const VerificationMeta('sectionIndex');
  @override
  late final GeneratedColumn<int> sectionIndex = GeneratedColumn<int>(
      'section_index', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _normCharOffsetMeta =
      const VerificationMeta('normCharOffset');
  @override
  late final GeneratedColumn<int> normCharOffset = GeneratedColumn<int>(
      'norm_char_offset', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _ttuCharOffsetMeta =
      const VerificationMeta('ttuCharOffset');
  @override
  late final GeneratedColumn<int> ttuCharOffset = GeneratedColumn<int>(
      'ttu_char_offset', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(-1));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, ttuBookId, sectionIndex, normCharOffset, ttuCharOffset, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reader_positions';
  @override
  VerificationContext validateIntegrity(Insertable<ReaderPositionRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('ttu_book_id')) {
      context.handle(
          _ttuBookIdMeta,
          ttuBookId.isAcceptableOrUnknown(
              data['ttu_book_id']!, _ttuBookIdMeta));
    } else if (isInserting) {
      context.missing(_ttuBookIdMeta);
    }
    if (data.containsKey('section_index')) {
      context.handle(
          _sectionIndexMeta,
          sectionIndex.isAcceptableOrUnknown(
              data['section_index']!, _sectionIndexMeta));
    } else if (isInserting) {
      context.missing(_sectionIndexMeta);
    }
    if (data.containsKey('norm_char_offset')) {
      context.handle(
          _normCharOffsetMeta,
          normCharOffset.isAcceptableOrUnknown(
              data['norm_char_offset']!, _normCharOffsetMeta));
    } else if (isInserting) {
      context.missing(_normCharOffsetMeta);
    }
    if (data.containsKey('ttu_char_offset')) {
      context.handle(
          _ttuCharOffsetMeta,
          ttuCharOffset.isAcceptableOrUnknown(
              data['ttu_char_offset']!, _ttuCharOffsetMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ReaderPositionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReaderPositionRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      ttuBookId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ttu_book_id'])!,
      sectionIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}section_index'])!,
      normCharOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}norm_char_offset'])!,
      ttuCharOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}ttu_char_offset'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ReaderPositionsTable createAlias(String alias) {
    return $ReaderPositionsTable(attachedDatabase, alias);
  }
}

class ReaderPositionRow extends DataClass
    implements Insertable<ReaderPositionRow> {
  final int id;
  final int ttuBookId;
  final int sectionIndex;
  final int normCharOffset;
  final int ttuCharOffset;
  final int updatedAt;
  const ReaderPositionRow(
      {required this.id,
      required this.ttuBookId,
      required this.sectionIndex,
      required this.normCharOffset,
      required this.ttuCharOffset,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['ttu_book_id'] = Variable<int>(ttuBookId);
    map['section_index'] = Variable<int>(sectionIndex);
    map['norm_char_offset'] = Variable<int>(normCharOffset);
    map['ttu_char_offset'] = Variable<int>(ttuCharOffset);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ReaderPositionsCompanion toCompanion(bool nullToAbsent) {
    return ReaderPositionsCompanion(
      id: Value(id),
      ttuBookId: Value(ttuBookId),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      ttuCharOffset: Value(ttuCharOffset),
      updatedAt: Value(updatedAt),
    );
  }

  factory ReaderPositionRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReaderPositionRow(
      id: serializer.fromJson<int>(json['id']),
      ttuBookId: serializer.fromJson<int>(json['ttuBookId']),
      sectionIndex: serializer.fromJson<int>(json['sectionIndex']),
      normCharOffset: serializer.fromJson<int>(json['normCharOffset']),
      ttuCharOffset: serializer.fromJson<int>(json['ttuCharOffset']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'ttuBookId': serializer.toJson<int>(ttuBookId),
      'sectionIndex': serializer.toJson<int>(sectionIndex),
      'normCharOffset': serializer.toJson<int>(normCharOffset),
      'ttuCharOffset': serializer.toJson<int>(ttuCharOffset),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  ReaderPositionRow copyWith(
          {int? id,
          int? ttuBookId,
          int? sectionIndex,
          int? normCharOffset,
          int? ttuCharOffset,
          int? updatedAt}) =>
      ReaderPositionRow(
        id: id ?? this.id,
        ttuBookId: ttuBookId ?? this.ttuBookId,
        sectionIndex: sectionIndex ?? this.sectionIndex,
        normCharOffset: normCharOffset ?? this.normCharOffset,
        ttuCharOffset: ttuCharOffset ?? this.ttuCharOffset,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  ReaderPositionRow copyWithCompanion(ReaderPositionsCompanion data) {
    return ReaderPositionRow(
      id: data.id.present ? data.id.value : this.id,
      ttuBookId: data.ttuBookId.present ? data.ttuBookId.value : this.ttuBookId,
      sectionIndex: data.sectionIndex.present
          ? data.sectionIndex.value
          : this.sectionIndex,
      normCharOffset: data.normCharOffset.present
          ? data.normCharOffset.value
          : this.normCharOffset,
      ttuCharOffset: data.ttuCharOffset.present
          ? data.ttuCharOffset.value
          : this.ttuCharOffset,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReaderPositionRow(')
          ..write('id: $id, ')
          ..write('ttuBookId: $ttuBookId, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('ttuCharOffset: $ttuCharOffset, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, ttuBookId, sectionIndex, normCharOffset, ttuCharOffset, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReaderPositionRow &&
          other.id == this.id &&
          other.ttuBookId == this.ttuBookId &&
          other.sectionIndex == this.sectionIndex &&
          other.normCharOffset == this.normCharOffset &&
          other.ttuCharOffset == this.ttuCharOffset &&
          other.updatedAt == this.updatedAt);
}

class ReaderPositionsCompanion extends UpdateCompanion<ReaderPositionRow> {
  final Value<int> id;
  final Value<int> ttuBookId;
  final Value<int> sectionIndex;
  final Value<int> normCharOffset;
  final Value<int> ttuCharOffset;
  final Value<int> updatedAt;
  const ReaderPositionsCompanion({
    this.id = const Value.absent(),
    this.ttuBookId = const Value.absent(),
    this.sectionIndex = const Value.absent(),
    this.normCharOffset = const Value.absent(),
    this.ttuCharOffset = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ReaderPositionsCompanion.insert({
    this.id = const Value.absent(),
    required int ttuBookId,
    required int sectionIndex,
    required int normCharOffset,
    this.ttuCharOffset = const Value.absent(),
    required int updatedAt,
  })  : ttuBookId = Value(ttuBookId),
        sectionIndex = Value(sectionIndex),
        normCharOffset = Value(normCharOffset),
        updatedAt = Value(updatedAt);
  static Insertable<ReaderPositionRow> custom({
    Expression<int>? id,
    Expression<int>? ttuBookId,
    Expression<int>? sectionIndex,
    Expression<int>? normCharOffset,
    Expression<int>? ttuCharOffset,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ttuBookId != null) 'ttu_book_id': ttuBookId,
      if (sectionIndex != null) 'section_index': sectionIndex,
      if (normCharOffset != null) 'norm_char_offset': normCharOffset,
      if (ttuCharOffset != null) 'ttu_char_offset': ttuCharOffset,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ReaderPositionsCompanion copyWith(
      {Value<int>? id,
      Value<int>? ttuBookId,
      Value<int>? sectionIndex,
      Value<int>? normCharOffset,
      Value<int>? ttuCharOffset,
      Value<int>? updatedAt}) {
    return ReaderPositionsCompanion(
      id: id ?? this.id,
      ttuBookId: ttuBookId ?? this.ttuBookId,
      sectionIndex: sectionIndex ?? this.sectionIndex,
      normCharOffset: normCharOffset ?? this.normCharOffset,
      ttuCharOffset: ttuCharOffset ?? this.ttuCharOffset,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (ttuBookId.present) {
      map['ttu_book_id'] = Variable<int>(ttuBookId.value);
    }
    if (sectionIndex.present) {
      map['section_index'] = Variable<int>(sectionIndex.value);
    }
    if (normCharOffset.present) {
      map['norm_char_offset'] = Variable<int>(normCharOffset.value);
    }
    if (ttuCharOffset.present) {
      map['ttu_char_offset'] = Variable<int>(ttuCharOffset.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReaderPositionsCompanion(')
          ..write('id: $id, ')
          ..write('ttuBookId: $ttuBookId, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('ttuCharOffset: $ttuCharOffset, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $ReadingStatisticsTable extends ReadingStatistics
    with TableInfo<$ReadingStatisticsTable, ReadingStatisticRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReadingStatisticsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _charactersReadMeta =
      const VerificationMeta('charactersRead');
  @override
  late final GeneratedColumn<int> charactersRead = GeneratedColumn<int>(
      'characters_read', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _readingTimeMsMeta =
      const VerificationMeta('readingTimeMs');
  @override
  late final GeneratedColumn<int> readingTimeMs = GeneratedColumn<int>(
      'reading_time_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _lastStatisticModifiedMeta =
      const VerificationMeta('lastStatisticModified');
  @override
  late final GeneratedColumn<int> lastStatisticModified = GeneratedColumn<int>(
      'last_statistic_modified', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        title,
        dateKey,
        charactersRead,
        readingTimeMs,
        lastStatisticModified
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reading_statistics';
  @override
  VerificationContext validateIntegrity(
      Insertable<ReadingStatisticRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('characters_read')) {
      context.handle(
          _charactersReadMeta,
          charactersRead.isAcceptableOrUnknown(
              data['characters_read']!, _charactersReadMeta));
    } else if (isInserting) {
      context.missing(_charactersReadMeta);
    }
    if (data.containsKey('reading_time_ms')) {
      context.handle(
          _readingTimeMsMeta,
          readingTimeMs.isAcceptableOrUnknown(
              data['reading_time_ms']!, _readingTimeMsMeta));
    } else if (isInserting) {
      context.missing(_readingTimeMsMeta);
    }
    if (data.containsKey('last_statistic_modified')) {
      context.handle(
          _lastStatisticModifiedMeta,
          lastStatisticModified.isAcceptableOrUnknown(
              data['last_statistic_modified']!, _lastStatisticModifiedMeta));
    } else if (isInserting) {
      context.missing(_lastStatisticModifiedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {title, dateKey},
      ];
  @override
  ReadingStatisticRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReadingStatisticRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      charactersRead: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}characters_read'])!,
      readingTimeMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}reading_time_ms'])!,
      lastStatisticModified: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}last_statistic_modified'])!,
    );
  }

  @override
  $ReadingStatisticsTable createAlias(String alias) {
    return $ReadingStatisticsTable(attachedDatabase, alias);
  }
}

class ReadingStatisticRow extends DataClass
    implements Insertable<ReadingStatisticRow> {
  final int id;
  final String title;
  final String dateKey;
  final int charactersRead;
  final int readingTimeMs;
  final int lastStatisticModified;
  const ReadingStatisticRow(
      {required this.id,
      required this.title,
      required this.dateKey,
      required this.charactersRead,
      required this.readingTimeMs,
      required this.lastStatisticModified});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['title'] = Variable<String>(title);
    map['date_key'] = Variable<String>(dateKey);
    map['characters_read'] = Variable<int>(charactersRead);
    map['reading_time_ms'] = Variable<int>(readingTimeMs);
    map['last_statistic_modified'] = Variable<int>(lastStatisticModified);
    return map;
  }

  ReadingStatisticsCompanion toCompanion(bool nullToAbsent) {
    return ReadingStatisticsCompanion(
      id: Value(id),
      title: Value(title),
      dateKey: Value(dateKey),
      charactersRead: Value(charactersRead),
      readingTimeMs: Value(readingTimeMs),
      lastStatisticModified: Value(lastStatisticModified),
    );
  }

  factory ReadingStatisticRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReadingStatisticRow(
      id: serializer.fromJson<int>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      charactersRead: serializer.fromJson<int>(json['charactersRead']),
      readingTimeMs: serializer.fromJson<int>(json['readingTimeMs']),
      lastStatisticModified:
          serializer.fromJson<int>(json['lastStatisticModified']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'title': serializer.toJson<String>(title),
      'dateKey': serializer.toJson<String>(dateKey),
      'charactersRead': serializer.toJson<int>(charactersRead),
      'readingTimeMs': serializer.toJson<int>(readingTimeMs),
      'lastStatisticModified': serializer.toJson<int>(lastStatisticModified),
    };
  }

  ReadingStatisticRow copyWith(
          {int? id,
          String? title,
          String? dateKey,
          int? charactersRead,
          int? readingTimeMs,
          int? lastStatisticModified}) =>
      ReadingStatisticRow(
        id: id ?? this.id,
        title: title ?? this.title,
        dateKey: dateKey ?? this.dateKey,
        charactersRead: charactersRead ?? this.charactersRead,
        readingTimeMs: readingTimeMs ?? this.readingTimeMs,
        lastStatisticModified:
            lastStatisticModified ?? this.lastStatisticModified,
      );
  ReadingStatisticRow copyWithCompanion(ReadingStatisticsCompanion data) {
    return ReadingStatisticRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      charactersRead: data.charactersRead.present
          ? data.charactersRead.value
          : this.charactersRead,
      readingTimeMs: data.readingTimeMs.present
          ? data.readingTimeMs.value
          : this.readingTimeMs,
      lastStatisticModified: data.lastStatisticModified.present
          ? data.lastStatisticModified.value
          : this.lastStatisticModified,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReadingStatisticRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('dateKey: $dateKey, ')
          ..write('charactersRead: $charactersRead, ')
          ..write('readingTimeMs: $readingTimeMs, ')
          ..write('lastStatisticModified: $lastStatisticModified')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, title, dateKey, charactersRead, readingTimeMs, lastStatisticModified);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReadingStatisticRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.dateKey == this.dateKey &&
          other.charactersRead == this.charactersRead &&
          other.readingTimeMs == this.readingTimeMs &&
          other.lastStatisticModified == this.lastStatisticModified);
}

class ReadingStatisticsCompanion extends UpdateCompanion<ReadingStatisticRow> {
  final Value<int> id;
  final Value<String> title;
  final Value<String> dateKey;
  final Value<int> charactersRead;
  final Value<int> readingTimeMs;
  final Value<int> lastStatisticModified;
  const ReadingStatisticsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.charactersRead = const Value.absent(),
    this.readingTimeMs = const Value.absent(),
    this.lastStatisticModified = const Value.absent(),
  });
  ReadingStatisticsCompanion.insert({
    this.id = const Value.absent(),
    required String title,
    required String dateKey,
    required int charactersRead,
    required int readingTimeMs,
    required int lastStatisticModified,
  })  : title = Value(title),
        dateKey = Value(dateKey),
        charactersRead = Value(charactersRead),
        readingTimeMs = Value(readingTimeMs),
        lastStatisticModified = Value(lastStatisticModified);
  static Insertable<ReadingStatisticRow> custom({
    Expression<int>? id,
    Expression<String>? title,
    Expression<String>? dateKey,
    Expression<int>? charactersRead,
    Expression<int>? readingTimeMs,
    Expression<int>? lastStatisticModified,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (dateKey != null) 'date_key': dateKey,
      if (charactersRead != null) 'characters_read': charactersRead,
      if (readingTimeMs != null) 'reading_time_ms': readingTimeMs,
      if (lastStatisticModified != null)
        'last_statistic_modified': lastStatisticModified,
    });
  }

  ReadingStatisticsCompanion copyWith(
      {Value<int>? id,
      Value<String>? title,
      Value<String>? dateKey,
      Value<int>? charactersRead,
      Value<int>? readingTimeMs,
      Value<int>? lastStatisticModified}) {
    return ReadingStatisticsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      dateKey: dateKey ?? this.dateKey,
      charactersRead: charactersRead ?? this.charactersRead,
      readingTimeMs: readingTimeMs ?? this.readingTimeMs,
      lastStatisticModified:
          lastStatisticModified ?? this.lastStatisticModified,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (charactersRead.present) {
      map['characters_read'] = Variable<int>(charactersRead.value);
    }
    if (readingTimeMs.present) {
      map['reading_time_ms'] = Variable<int>(readingTimeMs.value);
    }
    if (lastStatisticModified.present) {
      map['last_statistic_modified'] =
          Variable<int>(lastStatisticModified.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReadingStatisticsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('dateKey: $dateKey, ')
          ..write('charactersRead: $charactersRead, ')
          ..write('readingTimeMs: $readingTimeMs, ')
          ..write('lastStatisticModified: $lastStatisticModified')
          ..write(')'))
        .toString();
  }
}

class $ReadingHourlyLogsTable extends ReadingHourlyLogs
    with TableInfo<$ReadingHourlyLogsTable, ReadingHourlyLogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReadingHourlyLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _hourMeta = const VerificationMeta('hour');
  @override
  late final GeneratedColumn<int> hour = GeneratedColumn<int>(
      'hour', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _readingTimeMsMeta =
      const VerificationMeta('readingTimeMs');
  @override
  late final GeneratedColumn<int> readingTimeMs = GeneratedColumn<int>(
      'reading_time_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, dateKey, hour, readingTimeMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reading_hourly_logs';
  @override
  VerificationContext validateIntegrity(
      Insertable<ReadingHourlyLogRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('hour')) {
      context.handle(
          _hourMeta, hour.isAcceptableOrUnknown(data['hour']!, _hourMeta));
    } else if (isInserting) {
      context.missing(_hourMeta);
    }
    if (data.containsKey('reading_time_ms')) {
      context.handle(
          _readingTimeMsMeta,
          readingTimeMs.isAcceptableOrUnknown(
              data['reading_time_ms']!, _readingTimeMsMeta));
    } else if (isInserting) {
      context.missing(_readingTimeMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {dateKey, hour},
      ];
  @override
  ReadingHourlyLogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReadingHourlyLogRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      hour: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}hour'])!,
      readingTimeMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}reading_time_ms'])!,
    );
  }

  @override
  $ReadingHourlyLogsTable createAlias(String alias) {
    return $ReadingHourlyLogsTable(attachedDatabase, alias);
  }
}

class ReadingHourlyLogRow extends DataClass
    implements Insertable<ReadingHourlyLogRow> {
  final int id;
  final String dateKey;
  final int hour;
  final int readingTimeMs;
  const ReadingHourlyLogRow(
      {required this.id,
      required this.dateKey,
      required this.hour,
      required this.readingTimeMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['date_key'] = Variable<String>(dateKey);
    map['hour'] = Variable<int>(hour);
    map['reading_time_ms'] = Variable<int>(readingTimeMs);
    return map;
  }

  ReadingHourlyLogsCompanion toCompanion(bool nullToAbsent) {
    return ReadingHourlyLogsCompanion(
      id: Value(id),
      dateKey: Value(dateKey),
      hour: Value(hour),
      readingTimeMs: Value(readingTimeMs),
    );
  }

  factory ReadingHourlyLogRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReadingHourlyLogRow(
      id: serializer.fromJson<int>(json['id']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      hour: serializer.fromJson<int>(json['hour']),
      readingTimeMs: serializer.fromJson<int>(json['readingTimeMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'dateKey': serializer.toJson<String>(dateKey),
      'hour': serializer.toJson<int>(hour),
      'readingTimeMs': serializer.toJson<int>(readingTimeMs),
    };
  }

  ReadingHourlyLogRow copyWith(
          {int? id, String? dateKey, int? hour, int? readingTimeMs}) =>
      ReadingHourlyLogRow(
        id: id ?? this.id,
        dateKey: dateKey ?? this.dateKey,
        hour: hour ?? this.hour,
        readingTimeMs: readingTimeMs ?? this.readingTimeMs,
      );
  ReadingHourlyLogRow copyWithCompanion(ReadingHourlyLogsCompanion data) {
    return ReadingHourlyLogRow(
      id: data.id.present ? data.id.value : this.id,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      hour: data.hour.present ? data.hour.value : this.hour,
      readingTimeMs: data.readingTimeMs.present
          ? data.readingTimeMs.value
          : this.readingTimeMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReadingHourlyLogRow(')
          ..write('id: $id, ')
          ..write('dateKey: $dateKey, ')
          ..write('hour: $hour, ')
          ..write('readingTimeMs: $readingTimeMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, dateKey, hour, readingTimeMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReadingHourlyLogRow &&
          other.id == this.id &&
          other.dateKey == this.dateKey &&
          other.hour == this.hour &&
          other.readingTimeMs == this.readingTimeMs);
}

class ReadingHourlyLogsCompanion extends UpdateCompanion<ReadingHourlyLogRow> {
  final Value<int> id;
  final Value<String> dateKey;
  final Value<int> hour;
  final Value<int> readingTimeMs;
  const ReadingHourlyLogsCompanion({
    this.id = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.hour = const Value.absent(),
    this.readingTimeMs = const Value.absent(),
  });
  ReadingHourlyLogsCompanion.insert({
    this.id = const Value.absent(),
    required String dateKey,
    required int hour,
    required int readingTimeMs,
  })  : dateKey = Value(dateKey),
        hour = Value(hour),
        readingTimeMs = Value(readingTimeMs);
  static Insertable<ReadingHourlyLogRow> custom({
    Expression<int>? id,
    Expression<String>? dateKey,
    Expression<int>? hour,
    Expression<int>? readingTimeMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (dateKey != null) 'date_key': dateKey,
      if (hour != null) 'hour': hour,
      if (readingTimeMs != null) 'reading_time_ms': readingTimeMs,
    });
  }

  ReadingHourlyLogsCompanion copyWith(
      {Value<int>? id,
      Value<String>? dateKey,
      Value<int>? hour,
      Value<int>? readingTimeMs}) {
    return ReadingHourlyLogsCompanion(
      id: id ?? this.id,
      dateKey: dateKey ?? this.dateKey,
      hour: hour ?? this.hour,
      readingTimeMs: readingTimeMs ?? this.readingTimeMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (hour.present) {
      map['hour'] = Variable<int>(hour.value);
    }
    if (readingTimeMs.present) {
      map['reading_time_ms'] = Variable<int>(readingTimeMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReadingHourlyLogsCompanion(')
          ..write('id: $id, ')
          ..write('dateKey: $dateKey, ')
          ..write('hour: $hour, ')
          ..write('readingTimeMs: $readingTimeMs')
          ..write(')'))
        .toString();
  }
}

class $PreferencesTable extends Preferences
    with TableInfo<$PreferencesTable, PreferenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PreferencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'preferences';
  @override
  VerificationContext validateIntegrity(Insertable<PreferenceRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  PreferenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PreferenceRow(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $PreferencesTable createAlias(String alias) {
    return $PreferencesTable(attachedDatabase, alias);
  }
}

class PreferenceRow extends DataClass implements Insertable<PreferenceRow> {
  final String key;
  final String value;
  const PreferenceRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  PreferencesCompanion toCompanion(bool nullToAbsent) {
    return PreferencesCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory PreferenceRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PreferenceRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  PreferenceRow copyWith({String? key, String? value}) => PreferenceRow(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  PreferenceRow copyWithCompanion(PreferencesCompanion data) {
    return PreferenceRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PreferenceRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PreferenceRow &&
          other.key == this.key &&
          other.value == this.value);
}

class PreferencesCompanion extends UpdateCompanion<PreferenceRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const PreferencesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PreferencesCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<PreferenceRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PreferencesCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return PreferencesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PreferencesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DictionaryMetadataTable extends DictionaryMetadata
    with TableInfo<$DictionaryMetadataTable, DictionaryMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DictionaryMetadataTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _formatKeyMeta =
      const VerificationMeta('formatKey');
  @override
  late final GeneratedColumn<String> formatKey = GeneratedColumn<String>(
      'format_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumn<int> order = GeneratedColumn<int>(
      'order', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('term'));
  static const VerificationMeta _metadataJsonMeta =
      const VerificationMeta('metadataJson');
  @override
  late final GeneratedColumn<String> metadataJson = GeneratedColumn<String>(
      'metadata_json', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _hiddenLanguagesJsonMeta =
      const VerificationMeta('hiddenLanguagesJson');
  @override
  late final GeneratedColumn<String> hiddenLanguagesJson =
      GeneratedColumn<String>('hidden_languages_json', aliasedName, false,
          type: DriftSqlType.string,
          requiredDuringInsert: false,
          defaultValue: const Constant('[]'));
  static const VerificationMeta _collapsedLanguagesJsonMeta =
      const VerificationMeta('collapsedLanguagesJson');
  @override
  late final GeneratedColumn<String> collapsedLanguagesJson =
      GeneratedColumn<String>('collapsed_languages_json', aliasedName, false,
          type: DriftSqlType.string,
          requiredDuringInsert: false,
          defaultValue: const Constant('[]'));
  @override
  List<GeneratedColumn> get $columns => [
        name,
        formatKey,
        order,
        type,
        metadataJson,
        hiddenLanguagesJson,
        collapsedLanguagesJson
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'dictionary_metadata';
  @override
  VerificationContext validateIntegrity(Insertable<DictionaryMetaRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('format_key')) {
      context.handle(_formatKeyMeta,
          formatKey.isAcceptableOrUnknown(data['format_key']!, _formatKeyMeta));
    } else if (isInserting) {
      context.missing(_formatKeyMeta);
    }
    if (data.containsKey('order')) {
      context.handle(
          _orderMeta, order.isAcceptableOrUnknown(data['order']!, _orderMeta));
    } else if (isInserting) {
      context.missing(_orderMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    }
    if (data.containsKey('metadata_json')) {
      context.handle(
          _metadataJsonMeta,
          metadataJson.isAcceptableOrUnknown(
              data['metadata_json']!, _metadataJsonMeta));
    }
    if (data.containsKey('hidden_languages_json')) {
      context.handle(
          _hiddenLanguagesJsonMeta,
          hiddenLanguagesJson.isAcceptableOrUnknown(
              data['hidden_languages_json']!, _hiddenLanguagesJsonMeta));
    }
    if (data.containsKey('collapsed_languages_json')) {
      context.handle(
          _collapsedLanguagesJsonMeta,
          collapsedLanguagesJson.isAcceptableOrUnknown(
              data['collapsed_languages_json']!, _collapsedLanguagesJsonMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  DictionaryMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DictionaryMetaRow(
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      formatKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}format_key'])!,
      order: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}order'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      metadataJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}metadata_json'])!,
      hiddenLanguagesJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}hidden_languages_json'])!,
      collapsedLanguagesJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}collapsed_languages_json'])!,
    );
  }

  @override
  $DictionaryMetadataTable createAlias(String alias) {
    return $DictionaryMetadataTable(attachedDatabase, alias);
  }
}

class DictionaryMetaRow extends DataClass
    implements Insertable<DictionaryMetaRow> {
  final String name;
  final String formatKey;
  final int order;
  final String type;
  final String metadataJson;
  final String hiddenLanguagesJson;
  final String collapsedLanguagesJson;
  const DictionaryMetaRow(
      {required this.name,
      required this.formatKey,
      required this.order,
      required this.type,
      required this.metadataJson,
      required this.hiddenLanguagesJson,
      required this.collapsedLanguagesJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    map['format_key'] = Variable<String>(formatKey);
    map['order'] = Variable<int>(order);
    map['type'] = Variable<String>(type);
    map['metadata_json'] = Variable<String>(metadataJson);
    map['hidden_languages_json'] = Variable<String>(hiddenLanguagesJson);
    map['collapsed_languages_json'] = Variable<String>(collapsedLanguagesJson);
    return map;
  }

  DictionaryMetadataCompanion toCompanion(bool nullToAbsent) {
    return DictionaryMetadataCompanion(
      name: Value(name),
      formatKey: Value(formatKey),
      order: Value(order),
      type: Value(type),
      metadataJson: Value(metadataJson),
      hiddenLanguagesJson: Value(hiddenLanguagesJson),
      collapsedLanguagesJson: Value(collapsedLanguagesJson),
    );
  }

  factory DictionaryMetaRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DictionaryMetaRow(
      name: serializer.fromJson<String>(json['name']),
      formatKey: serializer.fromJson<String>(json['formatKey']),
      order: serializer.fromJson<int>(json['order']),
      type: serializer.fromJson<String>(json['type']),
      metadataJson: serializer.fromJson<String>(json['metadataJson']),
      hiddenLanguagesJson:
          serializer.fromJson<String>(json['hiddenLanguagesJson']),
      collapsedLanguagesJson:
          serializer.fromJson<String>(json['collapsedLanguagesJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'formatKey': serializer.toJson<String>(formatKey),
      'order': serializer.toJson<int>(order),
      'type': serializer.toJson<String>(type),
      'metadataJson': serializer.toJson<String>(metadataJson),
      'hiddenLanguagesJson': serializer.toJson<String>(hiddenLanguagesJson),
      'collapsedLanguagesJson':
          serializer.toJson<String>(collapsedLanguagesJson),
    };
  }

  DictionaryMetaRow copyWith(
          {String? name,
          String? formatKey,
          int? order,
          String? type,
          String? metadataJson,
          String? hiddenLanguagesJson,
          String? collapsedLanguagesJson}) =>
      DictionaryMetaRow(
        name: name ?? this.name,
        formatKey: formatKey ?? this.formatKey,
        order: order ?? this.order,
        type: type ?? this.type,
        metadataJson: metadataJson ?? this.metadataJson,
        hiddenLanguagesJson: hiddenLanguagesJson ?? this.hiddenLanguagesJson,
        collapsedLanguagesJson:
            collapsedLanguagesJson ?? this.collapsedLanguagesJson,
      );
  DictionaryMetaRow copyWithCompanion(DictionaryMetadataCompanion data) {
    return DictionaryMetaRow(
      name: data.name.present ? data.name.value : this.name,
      formatKey: data.formatKey.present ? data.formatKey.value : this.formatKey,
      order: data.order.present ? data.order.value : this.order,
      type: data.type.present ? data.type.value : this.type,
      metadataJson: data.metadataJson.present
          ? data.metadataJson.value
          : this.metadataJson,
      hiddenLanguagesJson: data.hiddenLanguagesJson.present
          ? data.hiddenLanguagesJson.value
          : this.hiddenLanguagesJson,
      collapsedLanguagesJson: data.collapsedLanguagesJson.present
          ? data.collapsedLanguagesJson.value
          : this.collapsedLanguagesJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DictionaryMetaRow(')
          ..write('name: $name, ')
          ..write('formatKey: $formatKey, ')
          ..write('order: $order, ')
          ..write('type: $type, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('hiddenLanguagesJson: $hiddenLanguagesJson, ')
          ..write('collapsedLanguagesJson: $collapsedLanguagesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, formatKey, order, type, metadataJson,
      hiddenLanguagesJson, collapsedLanguagesJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DictionaryMetaRow &&
          other.name == this.name &&
          other.formatKey == this.formatKey &&
          other.order == this.order &&
          other.type == this.type &&
          other.metadataJson == this.metadataJson &&
          other.hiddenLanguagesJson == this.hiddenLanguagesJson &&
          other.collapsedLanguagesJson == this.collapsedLanguagesJson);
}

class DictionaryMetadataCompanion extends UpdateCompanion<DictionaryMetaRow> {
  final Value<String> name;
  final Value<String> formatKey;
  final Value<int> order;
  final Value<String> type;
  final Value<String> metadataJson;
  final Value<String> hiddenLanguagesJson;
  final Value<String> collapsedLanguagesJson;
  final Value<int> rowid;
  const DictionaryMetadataCompanion({
    this.name = const Value.absent(),
    this.formatKey = const Value.absent(),
    this.order = const Value.absent(),
    this.type = const Value.absent(),
    this.metadataJson = const Value.absent(),
    this.hiddenLanguagesJson = const Value.absent(),
    this.collapsedLanguagesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DictionaryMetadataCompanion.insert({
    required String name,
    required String formatKey,
    required int order,
    this.type = const Value.absent(),
    this.metadataJson = const Value.absent(),
    this.hiddenLanguagesJson = const Value.absent(),
    this.collapsedLanguagesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : name = Value(name),
        formatKey = Value(formatKey),
        order = Value(order);
  static Insertable<DictionaryMetaRow> custom({
    Expression<String>? name,
    Expression<String>? formatKey,
    Expression<int>? order,
    Expression<String>? type,
    Expression<String>? metadataJson,
    Expression<String>? hiddenLanguagesJson,
    Expression<String>? collapsedLanguagesJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (formatKey != null) 'format_key': formatKey,
      if (order != null) 'order': order,
      if (type != null) 'type': type,
      if (metadataJson != null) 'metadata_json': metadataJson,
      if (hiddenLanguagesJson != null)
        'hidden_languages_json': hiddenLanguagesJson,
      if (collapsedLanguagesJson != null)
        'collapsed_languages_json': collapsedLanguagesJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DictionaryMetadataCompanion copyWith(
      {Value<String>? name,
      Value<String>? formatKey,
      Value<int>? order,
      Value<String>? type,
      Value<String>? metadataJson,
      Value<String>? hiddenLanguagesJson,
      Value<String>? collapsedLanguagesJson,
      Value<int>? rowid}) {
    return DictionaryMetadataCompanion(
      name: name ?? this.name,
      formatKey: formatKey ?? this.formatKey,
      order: order ?? this.order,
      type: type ?? this.type,
      metadataJson: metadataJson ?? this.metadataJson,
      hiddenLanguagesJson: hiddenLanguagesJson ?? this.hiddenLanguagesJson,
      collapsedLanguagesJson:
          collapsedLanguagesJson ?? this.collapsedLanguagesJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (formatKey.present) {
      map['format_key'] = Variable<String>(formatKey.value);
    }
    if (order.present) {
      map['order'] = Variable<int>(order.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (metadataJson.present) {
      map['metadata_json'] = Variable<String>(metadataJson.value);
    }
    if (hiddenLanguagesJson.present) {
      map['hidden_languages_json'] =
          Variable<String>(hiddenLanguagesJson.value);
    }
    if (collapsedLanguagesJson.present) {
      map['collapsed_languages_json'] =
          Variable<String>(collapsedLanguagesJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DictionaryMetadataCompanion(')
          ..write('name: $name, ')
          ..write('formatKey: $formatKey, ')
          ..write('order: $order, ')
          ..write('type: $type, ')
          ..write('metadataJson: $metadataJson, ')
          ..write('hiddenLanguagesJson: $hiddenLanguagesJson, ')
          ..write('collapsedLanguagesJson: $collapsedLanguagesJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DictionaryHistoryTable extends DictionaryHistory
    with TableInfo<$DictionaryHistoryTable, DictionaryHistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DictionaryHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _resultJsonMeta =
      const VerificationMeta('resultJson');
  @override
  late final GeneratedColumn<String> resultJson = GeneratedColumn<String>(
      'result_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, position, resultJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'dictionary_history';
  @override
  VerificationContext validateIntegrity(
      Insertable<DictionaryHistoryRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('result_json')) {
      context.handle(
          _resultJsonMeta,
          resultJson.isAcceptableOrUnknown(
              data['result_json']!, _resultJsonMeta));
    } else if (isInserting) {
      context.missing(_resultJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DictionaryHistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DictionaryHistoryRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      resultJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}result_json'])!,
    );
  }

  @override
  $DictionaryHistoryTable createAlias(String alias) {
    return $DictionaryHistoryTable(attachedDatabase, alias);
  }
}

class DictionaryHistoryRow extends DataClass
    implements Insertable<DictionaryHistoryRow> {
  final int id;
  final int position;
  final String resultJson;
  const DictionaryHistoryRow(
      {required this.id, required this.position, required this.resultJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['position'] = Variable<int>(position);
    map['result_json'] = Variable<String>(resultJson);
    return map;
  }

  DictionaryHistoryCompanion toCompanion(bool nullToAbsent) {
    return DictionaryHistoryCompanion(
      id: Value(id),
      position: Value(position),
      resultJson: Value(resultJson),
    );
  }

  factory DictionaryHistoryRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DictionaryHistoryRow(
      id: serializer.fromJson<int>(json['id']),
      position: serializer.fromJson<int>(json['position']),
      resultJson: serializer.fromJson<String>(json['resultJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'position': serializer.toJson<int>(position),
      'resultJson': serializer.toJson<String>(resultJson),
    };
  }

  DictionaryHistoryRow copyWith({int? id, int? position, String? resultJson}) =>
      DictionaryHistoryRow(
        id: id ?? this.id,
        position: position ?? this.position,
        resultJson: resultJson ?? this.resultJson,
      );
  DictionaryHistoryRow copyWithCompanion(DictionaryHistoryCompanion data) {
    return DictionaryHistoryRow(
      id: data.id.present ? data.id.value : this.id,
      position: data.position.present ? data.position.value : this.position,
      resultJson:
          data.resultJson.present ? data.resultJson.value : this.resultJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DictionaryHistoryRow(')
          ..write('id: $id, ')
          ..write('position: $position, ')
          ..write('resultJson: $resultJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, position, resultJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DictionaryHistoryRow &&
          other.id == this.id &&
          other.position == this.position &&
          other.resultJson == this.resultJson);
}

class DictionaryHistoryCompanion extends UpdateCompanion<DictionaryHistoryRow> {
  final Value<int> id;
  final Value<int> position;
  final Value<String> resultJson;
  const DictionaryHistoryCompanion({
    this.id = const Value.absent(),
    this.position = const Value.absent(),
    this.resultJson = const Value.absent(),
  });
  DictionaryHistoryCompanion.insert({
    this.id = const Value.absent(),
    required int position,
    required String resultJson,
  })  : position = Value(position),
        resultJson = Value(resultJson);
  static Insertable<DictionaryHistoryRow> custom({
    Expression<int>? id,
    Expression<int>? position,
    Expression<String>? resultJson,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (position != null) 'position': position,
      if (resultJson != null) 'result_json': resultJson,
    });
  }

  DictionaryHistoryCompanion copyWith(
      {Value<int>? id, Value<int>? position, Value<String>? resultJson}) {
    return DictionaryHistoryCompanion(
      id: id ?? this.id,
      position: position ?? this.position,
      resultJson: resultJson ?? this.resultJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (resultJson.present) {
      map['result_json'] = Variable<String>(resultJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DictionaryHistoryCompanion(')
          ..write('id: $id, ')
          ..write('position: $position, ')
          ..write('resultJson: $resultJson')
          ..write(')'))
        .toString();
  }
}

class $EpubBooksTable extends EpubBooks
    with TableInfo<$EpubBooksTable, EpubBookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EpubBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
      'author', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _coverPathMeta =
      const VerificationMeta('coverPath');
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
      'cover_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _epubPathMeta =
      const VerificationMeta('epubPath');
  @override
  late final GeneratedColumn<String> epubPath = GeneratedColumn<String>(
      'epub_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _extractDirMeta =
      const VerificationMeta('extractDir');
  @override
  late final GeneratedColumn<String> extractDir = GeneratedColumn<String>(
      'extract_dir', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _chapterCountMeta =
      const VerificationMeta('chapterCount');
  @override
  late final GeneratedColumn<int> chapterCount = GeneratedColumn<int>(
      'chapter_count', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _chaptersJsonMeta =
      const VerificationMeta('chaptersJson');
  @override
  late final GeneratedColumn<String> chaptersJson = GeneratedColumn<String>(
      'chapters_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _tocJsonMeta =
      const VerificationMeta('tocJson');
  @override
  late final GeneratedColumn<String> tocJson = GeneratedColumn<String>(
      'toc_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sourceMetadataMeta =
      const VerificationMeta('sourceMetadata');
  @override
  late final GeneratedColumn<String> sourceMetadata = GeneratedColumn<String>(
      'source_metadata', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _importedAtMeta =
      const VerificationMeta('importedAt');
  @override
  late final GeneratedColumn<int> importedAt = GeneratedColumn<int>(
      'imported_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        title,
        author,
        coverPath,
        epubPath,
        extractDir,
        chapterCount,
        chaptersJson,
        tocJson,
        sourceMetadata,
        importedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'epub_books';
  @override
  VerificationContext validateIntegrity(Insertable<EpubBookRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('author')) {
      context.handle(_authorMeta,
          author.isAcceptableOrUnknown(data['author']!, _authorMeta));
    }
    if (data.containsKey('cover_path')) {
      context.handle(_coverPathMeta,
          coverPath.isAcceptableOrUnknown(data['cover_path']!, _coverPathMeta));
    }
    if (data.containsKey('epub_path')) {
      context.handle(_epubPathMeta,
          epubPath.isAcceptableOrUnknown(data['epub_path']!, _epubPathMeta));
    } else if (isInserting) {
      context.missing(_epubPathMeta);
    }
    if (data.containsKey('extract_dir')) {
      context.handle(
          _extractDirMeta,
          extractDir.isAcceptableOrUnknown(
              data['extract_dir']!, _extractDirMeta));
    } else if (isInserting) {
      context.missing(_extractDirMeta);
    }
    if (data.containsKey('chapter_count')) {
      context.handle(
          _chapterCountMeta,
          chapterCount.isAcceptableOrUnknown(
              data['chapter_count']!, _chapterCountMeta));
    } else if (isInserting) {
      context.missing(_chapterCountMeta);
    }
    if (data.containsKey('chapters_json')) {
      context.handle(
          _chaptersJsonMeta,
          chaptersJson.isAcceptableOrUnknown(
              data['chapters_json']!, _chaptersJsonMeta));
    } else if (isInserting) {
      context.missing(_chaptersJsonMeta);
    }
    if (data.containsKey('toc_json')) {
      context.handle(_tocJsonMeta,
          tocJson.isAcceptableOrUnknown(data['toc_json']!, _tocJsonMeta));
    }
    if (data.containsKey('source_metadata')) {
      context.handle(
          _sourceMetadataMeta,
          sourceMetadata.isAcceptableOrUnknown(
              data['source_metadata']!, _sourceMetadataMeta));
    }
    if (data.containsKey('imported_at')) {
      context.handle(
          _importedAtMeta,
          importedAt.isAcceptableOrUnknown(
              data['imported_at']!, _importedAtMeta));
    } else if (isInserting) {
      context.missing(_importedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EpubBookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EpubBookRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      author: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}author']),
      coverPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cover_path']),
      epubPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}epub_path'])!,
      extractDir: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}extract_dir'])!,
      chapterCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}chapter_count'])!,
      chaptersJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}chapters_json'])!,
      tocJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}toc_json']),
      sourceMetadata: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_metadata']),
      importedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}imported_at'])!,
    );
  }

  @override
  $EpubBooksTable createAlias(String alias) {
    return $EpubBooksTable(attachedDatabase, alias);
  }
}

class EpubBookRow extends DataClass implements Insertable<EpubBookRow> {
  final int id;
  final String title;
  final String? author;
  final String? coverPath;
  final String epubPath;
  final String extractDir;
  final int chapterCount;
  final String chaptersJson;
  final String? tocJson;
  final String? sourceMetadata;
  final int importedAt;
  const EpubBookRow(
      {required this.id,
      required this.title,
      this.author,
      this.coverPath,
      required this.epubPath,
      required this.extractDir,
      required this.chapterCount,
      required this.chaptersJson,
      this.tocJson,
      this.sourceMetadata,
      required this.importedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || author != null) {
      map['author'] = Variable<String>(author);
    }
    if (!nullToAbsent || coverPath != null) {
      map['cover_path'] = Variable<String>(coverPath);
    }
    map['epub_path'] = Variable<String>(epubPath);
    map['extract_dir'] = Variable<String>(extractDir);
    map['chapter_count'] = Variable<int>(chapterCount);
    map['chapters_json'] = Variable<String>(chaptersJson);
    if (!nullToAbsent || tocJson != null) {
      map['toc_json'] = Variable<String>(tocJson);
    }
    if (!nullToAbsent || sourceMetadata != null) {
      map['source_metadata'] = Variable<String>(sourceMetadata);
    }
    map['imported_at'] = Variable<int>(importedAt);
    return map;
  }

  EpubBooksCompanion toCompanion(bool nullToAbsent) {
    return EpubBooksCompanion(
      id: Value(id),
      title: Value(title),
      author:
          author == null && nullToAbsent ? const Value.absent() : Value(author),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      epubPath: Value(epubPath),
      extractDir: Value(extractDir),
      chapterCount: Value(chapterCount),
      chaptersJson: Value(chaptersJson),
      tocJson: tocJson == null && nullToAbsent
          ? const Value.absent()
          : Value(tocJson),
      sourceMetadata: sourceMetadata == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceMetadata),
      importedAt: Value(importedAt),
    );
  }

  factory EpubBookRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EpubBookRow(
      id: serializer.fromJson<int>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      author: serializer.fromJson<String?>(json['author']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      epubPath: serializer.fromJson<String>(json['epubPath']),
      extractDir: serializer.fromJson<String>(json['extractDir']),
      chapterCount: serializer.fromJson<int>(json['chapterCount']),
      chaptersJson: serializer.fromJson<String>(json['chaptersJson']),
      tocJson: serializer.fromJson<String?>(json['tocJson']),
      sourceMetadata: serializer.fromJson<String?>(json['sourceMetadata']),
      importedAt: serializer.fromJson<int>(json['importedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'title': serializer.toJson<String>(title),
      'author': serializer.toJson<String?>(author),
      'coverPath': serializer.toJson<String?>(coverPath),
      'epubPath': serializer.toJson<String>(epubPath),
      'extractDir': serializer.toJson<String>(extractDir),
      'chapterCount': serializer.toJson<int>(chapterCount),
      'chaptersJson': serializer.toJson<String>(chaptersJson),
      'tocJson': serializer.toJson<String?>(tocJson),
      'sourceMetadata': serializer.toJson<String?>(sourceMetadata),
      'importedAt': serializer.toJson<int>(importedAt),
    };
  }

  EpubBookRow copyWith(
          {int? id,
          String? title,
          Value<String?> author = const Value.absent(),
          Value<String?> coverPath = const Value.absent(),
          String? epubPath,
          String? extractDir,
          int? chapterCount,
          String? chaptersJson,
          Value<String?> tocJson = const Value.absent(),
          Value<String?> sourceMetadata = const Value.absent(),
          int? importedAt}) =>
      EpubBookRow(
        id: id ?? this.id,
        title: title ?? this.title,
        author: author.present ? author.value : this.author,
        coverPath: coverPath.present ? coverPath.value : this.coverPath,
        epubPath: epubPath ?? this.epubPath,
        extractDir: extractDir ?? this.extractDir,
        chapterCount: chapterCount ?? this.chapterCount,
        chaptersJson: chaptersJson ?? this.chaptersJson,
        tocJson: tocJson.present ? tocJson.value : this.tocJson,
        sourceMetadata:
            sourceMetadata.present ? sourceMetadata.value : this.sourceMetadata,
        importedAt: importedAt ?? this.importedAt,
      );
  EpubBookRow copyWithCompanion(EpubBooksCompanion data) {
    return EpubBookRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      author: data.author.present ? data.author.value : this.author,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      epubPath: data.epubPath.present ? data.epubPath.value : this.epubPath,
      extractDir:
          data.extractDir.present ? data.extractDir.value : this.extractDir,
      chapterCount: data.chapterCount.present
          ? data.chapterCount.value
          : this.chapterCount,
      chaptersJson: data.chaptersJson.present
          ? data.chaptersJson.value
          : this.chaptersJson,
      tocJson: data.tocJson.present ? data.tocJson.value : this.tocJson,
      sourceMetadata: data.sourceMetadata.present
          ? data.sourceMetadata.value
          : this.sourceMetadata,
      importedAt:
          data.importedAt.present ? data.importedAt.value : this.importedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EpubBookRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('coverPath: $coverPath, ')
          ..write('epubPath: $epubPath, ')
          ..write('extractDir: $extractDir, ')
          ..write('chapterCount: $chapterCount, ')
          ..write('chaptersJson: $chaptersJson, ')
          ..write('tocJson: $tocJson, ')
          ..write('sourceMetadata: $sourceMetadata, ')
          ..write('importedAt: $importedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      title,
      author,
      coverPath,
      epubPath,
      extractDir,
      chapterCount,
      chaptersJson,
      tocJson,
      sourceMetadata,
      importedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EpubBookRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.author == this.author &&
          other.coverPath == this.coverPath &&
          other.epubPath == this.epubPath &&
          other.extractDir == this.extractDir &&
          other.chapterCount == this.chapterCount &&
          other.chaptersJson == this.chaptersJson &&
          other.tocJson == this.tocJson &&
          other.sourceMetadata == this.sourceMetadata &&
          other.importedAt == this.importedAt);
}

class EpubBooksCompanion extends UpdateCompanion<EpubBookRow> {
  final Value<int> id;
  final Value<String> title;
  final Value<String?> author;
  final Value<String?> coverPath;
  final Value<String> epubPath;
  final Value<String> extractDir;
  final Value<int> chapterCount;
  final Value<String> chaptersJson;
  final Value<String?> tocJson;
  final Value<String?> sourceMetadata;
  final Value<int> importedAt;
  const EpubBooksCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.author = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.epubPath = const Value.absent(),
    this.extractDir = const Value.absent(),
    this.chapterCount = const Value.absent(),
    this.chaptersJson = const Value.absent(),
    this.tocJson = const Value.absent(),
    this.sourceMetadata = const Value.absent(),
    this.importedAt = const Value.absent(),
  });
  EpubBooksCompanion.insert({
    this.id = const Value.absent(),
    required String title,
    this.author = const Value.absent(),
    this.coverPath = const Value.absent(),
    required String epubPath,
    required String extractDir,
    required int chapterCount,
    required String chaptersJson,
    this.tocJson = const Value.absent(),
    this.sourceMetadata = const Value.absent(),
    required int importedAt,
  })  : title = Value(title),
        epubPath = Value(epubPath),
        extractDir = Value(extractDir),
        chapterCount = Value(chapterCount),
        chaptersJson = Value(chaptersJson),
        importedAt = Value(importedAt);
  static Insertable<EpubBookRow> custom({
    Expression<int>? id,
    Expression<String>? title,
    Expression<String>? author,
    Expression<String>? coverPath,
    Expression<String>? epubPath,
    Expression<String>? extractDir,
    Expression<int>? chapterCount,
    Expression<String>? chaptersJson,
    Expression<String>? tocJson,
    Expression<String>? sourceMetadata,
    Expression<int>? importedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (author != null) 'author': author,
      if (coverPath != null) 'cover_path': coverPath,
      if (epubPath != null) 'epub_path': epubPath,
      if (extractDir != null) 'extract_dir': extractDir,
      if (chapterCount != null) 'chapter_count': chapterCount,
      if (chaptersJson != null) 'chapters_json': chaptersJson,
      if (tocJson != null) 'toc_json': tocJson,
      if (sourceMetadata != null) 'source_metadata': sourceMetadata,
      if (importedAt != null) 'imported_at': importedAt,
    });
  }

  EpubBooksCompanion copyWith(
      {Value<int>? id,
      Value<String>? title,
      Value<String?>? author,
      Value<String?>? coverPath,
      Value<String>? epubPath,
      Value<String>? extractDir,
      Value<int>? chapterCount,
      Value<String>? chaptersJson,
      Value<String?>? tocJson,
      Value<String?>? sourceMetadata,
      Value<int>? importedAt}) {
    return EpubBooksCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      coverPath: coverPath ?? this.coverPath,
      epubPath: epubPath ?? this.epubPath,
      extractDir: extractDir ?? this.extractDir,
      chapterCount: chapterCount ?? this.chapterCount,
      chaptersJson: chaptersJson ?? this.chaptersJson,
      tocJson: tocJson ?? this.tocJson,
      sourceMetadata: sourceMetadata ?? this.sourceMetadata,
      importedAt: importedAt ?? this.importedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (coverPath.present) {
      map['cover_path'] = Variable<String>(coverPath.value);
    }
    if (epubPath.present) {
      map['epub_path'] = Variable<String>(epubPath.value);
    }
    if (extractDir.present) {
      map['extract_dir'] = Variable<String>(extractDir.value);
    }
    if (chapterCount.present) {
      map['chapter_count'] = Variable<int>(chapterCount.value);
    }
    if (chaptersJson.present) {
      map['chapters_json'] = Variable<String>(chaptersJson.value);
    }
    if (tocJson.present) {
      map['toc_json'] = Variable<String>(tocJson.value);
    }
    if (sourceMetadata.present) {
      map['source_metadata'] = Variable<String>(sourceMetadata.value);
    }
    if (importedAt.present) {
      map['imported_at'] = Variable<int>(importedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EpubBooksCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('coverPath: $coverPath, ')
          ..write('epubPath: $epubPath, ')
          ..write('extractDir: $extractDir, ')
          ..write('chapterCount: $chapterCount, ')
          ..write('chaptersJson: $chaptersJson, ')
          ..write('tocJson: $tocJson, ')
          ..write('sourceMetadata: $sourceMetadata, ')
          ..write('importedAt: $importedAt')
          ..write(')'))
        .toString();
  }
}

class $BookTagsTable extends BookTags
    with TableInfo<$BookTagsTable, BookTagRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookTagsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _colorValueMeta =
      const VerificationMeta('colorValue');
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
      'color_value', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const CustomExpression('2155905151'));
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, name, colorValue, sortOrder, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_tags';
  @override
  VerificationContext validateIntegrity(Insertable<BookTagRow> instance,
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
    if (data.containsKey('color_value')) {
      context.handle(
          _colorValueMeta,
          colorValue.isAcceptableOrUnknown(
              data['color_value']!, _colorValueMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(
          _sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(
              data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(
          _createdAtMeta,
          createdAt.isAcceptableOrUnknown(
              data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
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
  BookTagRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookTagRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      colorValue: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}color_value'])!,
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $BookTagsTable createAlias(String alias) {
    return $BookTagsTable(attachedDatabase, alias);
  }
}

class BookTagRow extends DataClass implements Insertable<BookTagRow> {
  final int id;
  final String name;
  final int colorValue;
  final int sortOrder;
  final int createdAt;
  const BookTagRow(
      {required this.id,
      required this.name,
      required this.colorValue,
      required this.sortOrder,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['color_value'] = Variable<int>(colorValue);
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  BookTagsCompanion toCompanion(bool nullToAbsent) {
    return BookTagsCompanion(
      id: Value(id),
      name: Value(name),
      colorValue: Value(colorValue),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
    );
  }

  factory BookTagRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookTagRow(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'colorValue': serializer.toJson<int>(colorValue),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  BookTagRow copyWith(
          {int? id,
          String? name,
          int? colorValue,
          int? sortOrder,
          int? createdAt}) =>
      BookTagRow(
        id: id ?? this.id,
        name: name ?? this.name,
        colorValue: colorValue ?? this.colorValue,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
      );
  BookTagRow copyWithCompanion(BookTagsCompanion data) {
    return BookTagRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      colorValue:
          data.colorValue.present ? data.colorValue.value : this.colorValue,
      sortOrder:
          data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt:
          data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookTagRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, colorValue, sortOrder, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookTagRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.colorValue == this.colorValue &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt);
}

class BookTagsCompanion extends UpdateCompanion<BookTagRow> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> colorValue;
  final Value<int> sortOrder;
  final Value<int> createdAt;
  const BookTagsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  BookTagsCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.colorValue = const Value.absent(),
    this.sortOrder = const Value.absent(),
    required int createdAt,
  })  : name = Value(name),
        createdAt = Value(createdAt);
  static Insertable<BookTagRow> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? colorValue,
    Expression<int>? sortOrder,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (colorValue != null) 'color_value': colorValue,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  BookTagsCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<int>? colorValue,
      Value<int>? sortOrder,
      Value<int>? createdAt}) {
    return BookTagsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookTagsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $BookTagMappingsTable extends BookTagMappings
    with TableInfo<$BookTagMappingsTable, BookTagMappingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookTagMappingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<int> bookId = GeneratedColumn<int>(
      'book_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES epub_books (id) ON DELETE CASCADE'));
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<int> tagId = GeneratedColumn<int>(
      'tag_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES book_tags (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [id, bookId, tagId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_tag_mappings';
  @override
  VerificationContext validateIntegrity(Insertable<BookTagMappingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('book_id')) {
      context.handle(
          _bookIdMeta,
          bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta));
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('tag_id')) {
      context.handle(
          _tagIdMeta,
          tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta));
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {bookId, tagId},
      ];
  @override
  BookTagMappingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookTagMappingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      bookId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}book_id'])!,
      tagId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tag_id'])!,
    );
  }

  @override
  $BookTagMappingsTable createAlias(String alias) {
    return $BookTagMappingsTable(attachedDatabase, alias);
  }
}

class BookTagMappingRow extends DataClass
    implements Insertable<BookTagMappingRow> {
  final int id;
  final int bookId;
  final int tagId;
  const BookTagMappingRow(
      {required this.id, required this.bookId, required this.tagId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_id'] = Variable<int>(bookId);
    map['tag_id'] = Variable<int>(tagId);
    return map;
  }

  BookTagMappingsCompanion toCompanion(bool nullToAbsent) {
    return BookTagMappingsCompanion(
      id: Value(id),
      bookId: Value(bookId),
      tagId: Value(tagId),
    );
  }

  factory BookTagMappingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookTagMappingRow(
      id: serializer.fromJson<int>(json['id']),
      bookId: serializer.fromJson<int>(json['bookId']),
      tagId: serializer.fromJson<int>(json['tagId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookId': serializer.toJson<int>(bookId),
      'tagId': serializer.toJson<int>(tagId),
    };
  }

  BookTagMappingRow copyWith({int? id, int? bookId, int? tagId}) =>
      BookTagMappingRow(
        id: id ?? this.id,
        bookId: bookId ?? this.bookId,
        tagId: tagId ?? this.tagId,
      );
  BookTagMappingRow copyWithCompanion(BookTagMappingsCompanion data) {
    return BookTagMappingRow(
      id: data.id.present ? data.id.value : this.id,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookTagMappingRow(')
          ..write('id: $id, ')
          ..write('bookId: $bookId, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, bookId, tagId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookTagMappingRow &&
          other.id == this.id &&
          other.bookId == this.bookId &&
          other.tagId == this.tagId);
}

class BookTagMappingsCompanion extends UpdateCompanion<BookTagMappingRow> {
  final Value<int> id;
  final Value<int> bookId;
  final Value<int> tagId;
  const BookTagMappingsCompanion({
    this.id = const Value.absent(),
    this.bookId = const Value.absent(),
    this.tagId = const Value.absent(),
  });
  BookTagMappingsCompanion.insert({
    this.id = const Value.absent(),
    required int bookId,
    required int tagId,
  })  : bookId = Value(bookId),
        tagId = Value(tagId);
  static Insertable<BookTagMappingRow> custom({
    Expression<int>? id,
    Expression<int>? bookId,
    Expression<int>? tagId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookId != null) 'book_id': bookId,
      if (tagId != null) 'tag_id': tagId,
    });
  }

  BookTagMappingsCompanion copyWith(
      {Value<int>? id, Value<int>? bookId, Value<int>? tagId}) {
    return BookTagMappingsCompanion(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      tagId: tagId ?? this.tagId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<int>(bookId.value);
    }
    if (tagId.present) {
      map['tag_id'] = Variable<int>(tagId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookTagMappingsCompanion(')
          ..write('id: $id, ')
          ..write('bookId: $bookId, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }
}


// 鈹€鈹€ $ProfilesTable 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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

// 鈹€鈹€ $ProfileSettingsTable 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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

// 鈹€鈹€ $MediaTypeProfilesTable 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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

// 鈹€鈹€ $BookProfilesTable 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
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
abstract class _$HibikiDatabase extends GeneratedDatabase {
  _$HibikiDatabase(QueryExecutor e) : super(e);
  $HibikiDatabaseManager get managers => $HibikiDatabaseManager(this);
  late final $MediaItemsTable mediaItems = $MediaItemsTable(this);
  late final $SearchHistoryItemsTable searchHistoryItems =
      $SearchHistoryItemsTable(this);
  late final $AudiobooksTable audiobooks = $AudiobooksTable(this);
  late final $AudioCuesTable audioCues = $AudioCuesTable(this);
  late final $SrtBooksTable srtBooks = $SrtBooksTable(this);
  late final $ReaderPositionsTable readerPositions =
      $ReaderPositionsTable(this);
  late final $ReadingStatisticsTable readingStatistics =
      $ReadingStatisticsTable(this);
  late final $ReadingHourlyLogsTable readingHourlyLogs =
      $ReadingHourlyLogsTable(this);
  late final $PreferencesTable preferences = $PreferencesTable(this);
  late final $DictionaryMetadataTable dictionaryMetadata =
      $DictionaryMetadataTable(this);
  late final $DictionaryHistoryTable dictionaryHistory =
      $DictionaryHistoryTable(this);
  late final $EpubBooksTable epubBooks = $EpubBooksTable(this);
  late final $BookTagsTable bookTags = $BookTagsTable(this);
  late final $BookTagMappingsTable bookTagMappings = $BookTagMappingsTable(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $ProfileSettingsTable profileSettings = $ProfileSettingsTable(this);
  late final $MediaTypeProfilesTable mediaTypeProfiles =
      $MediaTypeProfilesTable(this);
  late final $BookProfilesTable bookProfiles = $BookProfilesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        mediaItems,
        searchHistoryItems,
        audiobooks,
        audioCues,
        srtBooks,
        readerPositions,
        readingStatistics,
        readingHourlyLogs,
        preferences,
        dictionaryMetadata,
        dictionaryHistory,
        epubBooks,
        bookTags,
        bookTagMappings,
        profiles,
        profileSettings,
        mediaTypeProfiles,
        bookProfiles
      ];
}

typedef $$MediaItemsTableCreateCompanionBuilder = MediaItemsCompanion Function({
  Value<int> id,
  required String mediaIdentifier,
  required String title,
  required String mediaTypeIdentifier,
  required String mediaSourceIdentifier,
  required String uniqueKey,
  Value<String?> base64Image,
  Value<String?> imageUrl,
  Value<String?> audioUrl,
  Value<String?> author,
  Value<String?> authorIdentifier,
  Value<String?> extraUrl,
  Value<String?> extra,
  Value<String?> sourceMetadata,
  required int position,
  required int duration,
  required bool canDelete,
  required bool canEdit,
  Value<int> importedAt,
});
typedef $$MediaItemsTableUpdateCompanionBuilder = MediaItemsCompanion Function({
  Value<int> id,
  Value<String> mediaIdentifier,
  Value<String> title,
  Value<String> mediaTypeIdentifier,
  Value<String> mediaSourceIdentifier,
  Value<String> uniqueKey,
  Value<String?> base64Image,
  Value<String?> imageUrl,
  Value<String?> audioUrl,
  Value<String?> author,
  Value<String?> authorIdentifier,
  Value<String?> extraUrl,
  Value<String?> extra,
  Value<String?> sourceMetadata,
  Value<int> position,
  Value<int> duration,
  Value<bool> canDelete,
  Value<bool> canEdit,
  Value<int> importedAt,
});

class $$MediaItemsTableFilterComposer
    extends Composer<_$HibikiDatabase, $MediaItemsTable> {
  $$MediaItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaIdentifier => $composableBuilder(
      column: $table.mediaIdentifier,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaTypeIdentifier => $composableBuilder(
      column: $table.mediaTypeIdentifier,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaSourceIdentifier => $composableBuilder(
      column: $table.mediaSourceIdentifier,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uniqueKey => $composableBuilder(
      column: $table.uniqueKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get base64Image => $composableBuilder(
      column: $table.base64Image, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get imageUrl => $composableBuilder(
      column: $table.imageUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioUrl => $composableBuilder(
      column: $table.audioUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get authorIdentifier => $composableBuilder(
      column: $table.authorIdentifier,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get extraUrl => $composableBuilder(
      column: $table.extraUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get extra => $composableBuilder(
      column: $table.extra, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceMetadata => $composableBuilder(
      column: $table.sourceMetadata,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get duration => $composableBuilder(
      column: $table.duration, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get canDelete => $composableBuilder(
      column: $table.canDelete, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get canEdit => $composableBuilder(
      column: $table.canEdit, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnFilters(column));
}

class $$MediaItemsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $MediaItemsTable> {
  $$MediaItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaIdentifier => $composableBuilder(
      column: $table.mediaIdentifier,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaTypeIdentifier => $composableBuilder(
      column: $table.mediaTypeIdentifier,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaSourceIdentifier => $composableBuilder(
      column: $table.mediaSourceIdentifier,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uniqueKey => $composableBuilder(
      column: $table.uniqueKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get base64Image => $composableBuilder(
      column: $table.base64Image, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get imageUrl => $composableBuilder(
      column: $table.imageUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioUrl => $composableBuilder(
      column: $table.audioUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get authorIdentifier => $composableBuilder(
      column: $table.authorIdentifier,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get extraUrl => $composableBuilder(
      column: $table.extraUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get extra => $composableBuilder(
      column: $table.extra, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceMetadata => $composableBuilder(
      column: $table.sourceMetadata,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get duration => $composableBuilder(
      column: $table.duration, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get canDelete => $composableBuilder(
      column: $table.canDelete, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get canEdit => $composableBuilder(
      column: $table.canEdit, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnOrderings(column));
}

class $$MediaItemsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $MediaItemsTable> {
  $$MediaItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get mediaIdentifier => $composableBuilder(
      column: $table.mediaIdentifier, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get mediaTypeIdentifier => $composableBuilder(
      column: $table.mediaTypeIdentifier, builder: (column) => column);

  GeneratedColumn<String> get mediaSourceIdentifier => $composableBuilder(
      column: $table.mediaSourceIdentifier, builder: (column) => column);

  GeneratedColumn<String> get uniqueKey =>
      $composableBuilder(column: $table.uniqueKey, builder: (column) => column);

  GeneratedColumn<String> get base64Image => $composableBuilder(
      column: $table.base64Image, builder: (column) => column);

  GeneratedColumn<String> get imageUrl =>
      $composableBuilder(column: $table.imageUrl, builder: (column) => column);

  GeneratedColumn<String> get audioUrl =>
      $composableBuilder(column: $table.audioUrl, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get authorIdentifier => $composableBuilder(
      column: $table.authorIdentifier, builder: (column) => column);

  GeneratedColumn<String> get extraUrl =>
      $composableBuilder(column: $table.extraUrl, builder: (column) => column);

  GeneratedColumn<String> get extra =>
      $composableBuilder(column: $table.extra, builder: (column) => column);

  GeneratedColumn<String> get sourceMetadata => $composableBuilder(
      column: $table.sourceMetadata, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<bool> get canDelete =>
      $composableBuilder(column: $table.canDelete, builder: (column) => column);

  GeneratedColumn<bool> get canEdit =>
      $composableBuilder(column: $table.canEdit, builder: (column) => column);

  GeneratedColumn<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => column);
}

class $$MediaItemsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $MediaItemsTable,
    MediaItemRow,
    $$MediaItemsTableFilterComposer,
    $$MediaItemsTableOrderingComposer,
    $$MediaItemsTableAnnotationComposer,
    $$MediaItemsTableCreateCompanionBuilder,
    $$MediaItemsTableUpdateCompanionBuilder,
    (
      MediaItemRow,
      BaseReferences<_$HibikiDatabase, $MediaItemsTable, MediaItemRow>
    ),
    MediaItemRow,
    PrefetchHooks Function()> {
  $$MediaItemsTableTableManager(_$HibikiDatabase db, $MediaItemsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> mediaIdentifier = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> mediaTypeIdentifier = const Value.absent(),
            Value<String> mediaSourceIdentifier = const Value.absent(),
            Value<String> uniqueKey = const Value.absent(),
            Value<String?> base64Image = const Value.absent(),
            Value<String?> imageUrl = const Value.absent(),
            Value<String?> audioUrl = const Value.absent(),
            Value<String?> author = const Value.absent(),
            Value<String?> authorIdentifier = const Value.absent(),
            Value<String?> extraUrl = const Value.absent(),
            Value<String?> extra = const Value.absent(),
            Value<String?> sourceMetadata = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<int> duration = const Value.absent(),
            Value<bool> canDelete = const Value.absent(),
            Value<bool> canEdit = const Value.absent(),
            Value<int> importedAt = const Value.absent(),
          }) =>
              MediaItemsCompanion(
            id: id,
            mediaIdentifier: mediaIdentifier,
            title: title,
            mediaTypeIdentifier: mediaTypeIdentifier,
            mediaSourceIdentifier: mediaSourceIdentifier,
            uniqueKey: uniqueKey,
            base64Image: base64Image,
            imageUrl: imageUrl,
            audioUrl: audioUrl,
            author: author,
            authorIdentifier: authorIdentifier,
            extraUrl: extraUrl,
            extra: extra,
            sourceMetadata: sourceMetadata,
            position: position,
            duration: duration,
            canDelete: canDelete,
            canEdit: canEdit,
            importedAt: importedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String mediaIdentifier,
            required String title,
            required String mediaTypeIdentifier,
            required String mediaSourceIdentifier,
            required String uniqueKey,
            Value<String?> base64Image = const Value.absent(),
            Value<String?> imageUrl = const Value.absent(),
            Value<String?> audioUrl = const Value.absent(),
            Value<String?> author = const Value.absent(),
            Value<String?> authorIdentifier = const Value.absent(),
            Value<String?> extraUrl = const Value.absent(),
            Value<String?> extra = const Value.absent(),
            Value<String?> sourceMetadata = const Value.absent(),
            required int position,
            required int duration,
            required bool canDelete,
            required bool canEdit,
            Value<int> importedAt = const Value.absent(),
          }) =>
              MediaItemsCompanion.insert(
            id: id,
            mediaIdentifier: mediaIdentifier,
            title: title,
            mediaTypeIdentifier: mediaTypeIdentifier,
            mediaSourceIdentifier: mediaSourceIdentifier,
            uniqueKey: uniqueKey,
            base64Image: base64Image,
            imageUrl: imageUrl,
            audioUrl: audioUrl,
            author: author,
            authorIdentifier: authorIdentifier,
            extraUrl: extraUrl,
            extra: extra,
            sourceMetadata: sourceMetadata,
            position: position,
            duration: duration,
            canDelete: canDelete,
            canEdit: canEdit,
            importedAt: importedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MediaItemsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $MediaItemsTable,
    MediaItemRow,
    $$MediaItemsTableFilterComposer,
    $$MediaItemsTableOrderingComposer,
    $$MediaItemsTableAnnotationComposer,
    $$MediaItemsTableCreateCompanionBuilder,
    $$MediaItemsTableUpdateCompanionBuilder,
    (
      MediaItemRow,
      BaseReferences<_$HibikiDatabase, $MediaItemsTable, MediaItemRow>
    ),
    MediaItemRow,
    PrefetchHooks Function()>;
typedef $$SearchHistoryItemsTableCreateCompanionBuilder
    = SearchHistoryItemsCompanion Function({
  Value<int> id,
  required String historyKey,
  required String searchTerm,
  required String uniqueKey,
});
typedef $$SearchHistoryItemsTableUpdateCompanionBuilder
    = SearchHistoryItemsCompanion Function({
  Value<int> id,
  Value<String> historyKey,
  Value<String> searchTerm,
  Value<String> uniqueKey,
});

class $$SearchHistoryItemsTableFilterComposer
    extends Composer<_$HibikiDatabase, $SearchHistoryItemsTable> {
  $$SearchHistoryItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get historyKey => $composableBuilder(
      column: $table.historyKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get searchTerm => $composableBuilder(
      column: $table.searchTerm, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uniqueKey => $composableBuilder(
      column: $table.uniqueKey, builder: (column) => ColumnFilters(column));
}

class $$SearchHistoryItemsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $SearchHistoryItemsTable> {
  $$SearchHistoryItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get historyKey => $composableBuilder(
      column: $table.historyKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get searchTerm => $composableBuilder(
      column: $table.searchTerm, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uniqueKey => $composableBuilder(
      column: $table.uniqueKey, builder: (column) => ColumnOrderings(column));
}

class $$SearchHistoryItemsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $SearchHistoryItemsTable> {
  $$SearchHistoryItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get historyKey => $composableBuilder(
      column: $table.historyKey, builder: (column) => column);

  GeneratedColumn<String> get searchTerm => $composableBuilder(
      column: $table.searchTerm, builder: (column) => column);

  GeneratedColumn<String> get uniqueKey =>
      $composableBuilder(column: $table.uniqueKey, builder: (column) => column);
}

class $$SearchHistoryItemsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $SearchHistoryItemsTable,
    SearchHistoryItemRow,
    $$SearchHistoryItemsTableFilterComposer,
    $$SearchHistoryItemsTableOrderingComposer,
    $$SearchHistoryItemsTableAnnotationComposer,
    $$SearchHistoryItemsTableCreateCompanionBuilder,
    $$SearchHistoryItemsTableUpdateCompanionBuilder,
    (
      SearchHistoryItemRow,
      BaseReferences<_$HibikiDatabase, $SearchHistoryItemsTable,
          SearchHistoryItemRow>
    ),
    SearchHistoryItemRow,
    PrefetchHooks Function()> {
  $$SearchHistoryItemsTableTableManager(
      _$HibikiDatabase db, $SearchHistoryItemsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SearchHistoryItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SearchHistoryItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SearchHistoryItemsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> historyKey = const Value.absent(),
            Value<String> searchTerm = const Value.absent(),
            Value<String> uniqueKey = const Value.absent(),
          }) =>
              SearchHistoryItemsCompanion(
            id: id,
            historyKey: historyKey,
            searchTerm: searchTerm,
            uniqueKey: uniqueKey,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String historyKey,
            required String searchTerm,
            required String uniqueKey,
          }) =>
              SearchHistoryItemsCompanion.insert(
            id: id,
            historyKey: historyKey,
            searchTerm: searchTerm,
            uniqueKey: uniqueKey,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SearchHistoryItemsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $SearchHistoryItemsTable,
    SearchHistoryItemRow,
    $$SearchHistoryItemsTableFilterComposer,
    $$SearchHistoryItemsTableOrderingComposer,
    $$SearchHistoryItemsTableAnnotationComposer,
    $$SearchHistoryItemsTableCreateCompanionBuilder,
    $$SearchHistoryItemsTableUpdateCompanionBuilder,
    (
      SearchHistoryItemRow,
      BaseReferences<_$HibikiDatabase, $SearchHistoryItemsTable,
          SearchHistoryItemRow>
    ),
    SearchHistoryItemRow,
    PrefetchHooks Function()>;
typedef $$AudiobooksTableCreateCompanionBuilder = AudiobooksCompanion Function({
  Value<int> id,
  required String bookUid,
  Value<String?> audioRoot,
  Value<String?> audioPathsJson,
  required String alignmentFormat,
  required String alignmentPath,
  Value<String?> healthKindRaw,
  Value<int?> matchRatePct,
  Value<DateTime?> healthMeasuredAt,
  Value<String?> healthReason,
  Value<bool?> followAudio,
});
typedef $$AudiobooksTableUpdateCompanionBuilder = AudiobooksCompanion Function({
  Value<int> id,
  Value<String> bookUid,
  Value<String?> audioRoot,
  Value<String?> audioPathsJson,
  Value<String> alignmentFormat,
  Value<String> alignmentPath,
  Value<String?> healthKindRaw,
  Value<int?> matchRatePct,
  Value<DateTime?> healthMeasuredAt,
  Value<String?> healthReason,
  Value<bool?> followAudio,
});

class $$AudiobooksTableFilterComposer
    extends Composer<_$HibikiDatabase, $AudiobooksTable> {
  $$AudiobooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioRoot => $composableBuilder(
      column: $table.audioRoot, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioPathsJson => $composableBuilder(
      column: $table.audioPathsJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alignmentFormat => $composableBuilder(
      column: $table.alignmentFormat,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get alignmentPath => $composableBuilder(
      column: $table.alignmentPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get healthKindRaw => $composableBuilder(
      column: $table.healthKindRaw, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get matchRatePct => $composableBuilder(
      column: $table.matchRatePct, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get healthMeasuredAt => $composableBuilder(
      column: $table.healthMeasuredAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get healthReason => $composableBuilder(
      column: $table.healthReason, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get followAudio => $composableBuilder(
      column: $table.followAudio, builder: (column) => ColumnFilters(column));
}

class $$AudiobooksTableOrderingComposer
    extends Composer<_$HibikiDatabase, $AudiobooksTable> {
  $$AudiobooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioRoot => $composableBuilder(
      column: $table.audioRoot, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioPathsJson => $composableBuilder(
      column: $table.audioPathsJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alignmentFormat => $composableBuilder(
      column: $table.alignmentFormat,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get alignmentPath => $composableBuilder(
      column: $table.alignmentPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get healthKindRaw => $composableBuilder(
      column: $table.healthKindRaw,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get matchRatePct => $composableBuilder(
      column: $table.matchRatePct,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get healthMeasuredAt => $composableBuilder(
      column: $table.healthMeasuredAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get healthReason => $composableBuilder(
      column: $table.healthReason,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get followAudio => $composableBuilder(
      column: $table.followAudio, builder: (column) => ColumnOrderings(column));
}

class $$AudiobooksTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $AudiobooksTable> {
  $$AudiobooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bookUid =>
      $composableBuilder(column: $table.bookUid, builder: (column) => column);

  GeneratedColumn<String> get audioRoot =>
      $composableBuilder(column: $table.audioRoot, builder: (column) => column);

  GeneratedColumn<String> get audioPathsJson => $composableBuilder(
      column: $table.audioPathsJson, builder: (column) => column);

  GeneratedColumn<String> get alignmentFormat => $composableBuilder(
      column: $table.alignmentFormat, builder: (column) => column);

  GeneratedColumn<String> get alignmentPath => $composableBuilder(
      column: $table.alignmentPath, builder: (column) => column);

  GeneratedColumn<String> get healthKindRaw => $composableBuilder(
      column: $table.healthKindRaw, builder: (column) => column);

  GeneratedColumn<int> get matchRatePct => $composableBuilder(
      column: $table.matchRatePct, builder: (column) => column);

  GeneratedColumn<DateTime> get healthMeasuredAt => $composableBuilder(
      column: $table.healthMeasuredAt, builder: (column) => column);

  GeneratedColumn<String> get healthReason => $composableBuilder(
      column: $table.healthReason, builder: (column) => column);

  GeneratedColumn<bool> get followAudio => $composableBuilder(
      column: $table.followAudio, builder: (column) => column);
}

class $$AudiobooksTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $AudiobooksTable,
    AudiobookRow,
    $$AudiobooksTableFilterComposer,
    $$AudiobooksTableOrderingComposer,
    $$AudiobooksTableAnnotationComposer,
    $$AudiobooksTableCreateCompanionBuilder,
    $$AudiobooksTableUpdateCompanionBuilder,
    (
      AudiobookRow,
      BaseReferences<_$HibikiDatabase, $AudiobooksTable, AudiobookRow>
    ),
    AudiobookRow,
    PrefetchHooks Function()> {
  $$AudiobooksTableTableManager(_$HibikiDatabase db, $AudiobooksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AudiobooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AudiobooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AudiobooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> bookUid = const Value.absent(),
            Value<String?> audioRoot = const Value.absent(),
            Value<String?> audioPathsJson = const Value.absent(),
            Value<String> alignmentFormat = const Value.absent(),
            Value<String> alignmentPath = const Value.absent(),
            Value<String?> healthKindRaw = const Value.absent(),
            Value<int?> matchRatePct = const Value.absent(),
            Value<DateTime?> healthMeasuredAt = const Value.absent(),
            Value<String?> healthReason = const Value.absent(),
            Value<bool?> followAudio = const Value.absent(),
          }) =>
              AudiobooksCompanion(
            id: id,
            bookUid: bookUid,
            audioRoot: audioRoot,
            audioPathsJson: audioPathsJson,
            alignmentFormat: alignmentFormat,
            alignmentPath: alignmentPath,
            healthKindRaw: healthKindRaw,
            matchRatePct: matchRatePct,
            healthMeasuredAt: healthMeasuredAt,
            healthReason: healthReason,
            followAudio: followAudio,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String bookUid,
            Value<String?> audioRoot = const Value.absent(),
            Value<String?> audioPathsJson = const Value.absent(),
            required String alignmentFormat,
            required String alignmentPath,
            Value<String?> healthKindRaw = const Value.absent(),
            Value<int?> matchRatePct = const Value.absent(),
            Value<DateTime?> healthMeasuredAt = const Value.absent(),
            Value<String?> healthReason = const Value.absent(),
            Value<bool?> followAudio = const Value.absent(),
          }) =>
              AudiobooksCompanion.insert(
            id: id,
            bookUid: bookUid,
            audioRoot: audioRoot,
            audioPathsJson: audioPathsJson,
            alignmentFormat: alignmentFormat,
            alignmentPath: alignmentPath,
            healthKindRaw: healthKindRaw,
            matchRatePct: matchRatePct,
            healthMeasuredAt: healthMeasuredAt,
            healthReason: healthReason,
            followAudio: followAudio,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AudiobooksTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $AudiobooksTable,
    AudiobookRow,
    $$AudiobooksTableFilterComposer,
    $$AudiobooksTableOrderingComposer,
    $$AudiobooksTableAnnotationComposer,
    $$AudiobooksTableCreateCompanionBuilder,
    $$AudiobooksTableUpdateCompanionBuilder,
    (
      AudiobookRow,
      BaseReferences<_$HibikiDatabase, $AudiobooksTable, AudiobookRow>
    ),
    AudiobookRow,
    PrefetchHooks Function()>;
typedef $$AudioCuesTableCreateCompanionBuilder = AudioCuesCompanion Function({
  Value<int> id,
  required String bookUid,
  required String chapterHref,
  required int sentenceIndex,
  required String textFragmentId,
  required String cueText,
  required int startMs,
  required int endMs,
  required int audioFileIndex,
});
typedef $$AudioCuesTableUpdateCompanionBuilder = AudioCuesCompanion Function({
  Value<int> id,
  Value<String> bookUid,
  Value<String> chapterHref,
  Value<int> sentenceIndex,
  Value<String> textFragmentId,
  Value<String> cueText,
  Value<int> startMs,
  Value<int> endMs,
  Value<int> audioFileIndex,
});

class $$AudioCuesTableFilterComposer
    extends Composer<_$HibikiDatabase, $AudioCuesTable> {
  $$AudioCuesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get chapterHref => $composableBuilder(
      column: $table.chapterHref, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sentenceIndex => $composableBuilder(
      column: $table.sentenceIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get textFragmentId => $composableBuilder(
      column: $table.textFragmentId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get cueText => $composableBuilder(
      column: $table.cueText, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get startMs => $composableBuilder(
      column: $table.startMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get endMs => $composableBuilder(
      column: $table.endMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get audioFileIndex => $composableBuilder(
      column: $table.audioFileIndex,
      builder: (column) => ColumnFilters(column));
}

class $$AudioCuesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $AudioCuesTable> {
  $$AudioCuesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get chapterHref => $composableBuilder(
      column: $table.chapterHref, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sentenceIndex => $composableBuilder(
      column: $table.sentenceIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get textFragmentId => $composableBuilder(
      column: $table.textFragmentId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get cueText => $composableBuilder(
      column: $table.cueText, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get startMs => $composableBuilder(
      column: $table.startMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get endMs => $composableBuilder(
      column: $table.endMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get audioFileIndex => $composableBuilder(
      column: $table.audioFileIndex,
      builder: (column) => ColumnOrderings(column));
}

class $$AudioCuesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $AudioCuesTable> {
  $$AudioCuesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bookUid =>
      $composableBuilder(column: $table.bookUid, builder: (column) => column);

  GeneratedColumn<String> get chapterHref => $composableBuilder(
      column: $table.chapterHref, builder: (column) => column);

  GeneratedColumn<int> get sentenceIndex => $composableBuilder(
      column: $table.sentenceIndex, builder: (column) => column);

  GeneratedColumn<String> get textFragmentId => $composableBuilder(
      column: $table.textFragmentId, builder: (column) => column);

  GeneratedColumn<String> get cueText =>
      $composableBuilder(column: $table.cueText, builder: (column) => column);

  GeneratedColumn<int> get startMs =>
      $composableBuilder(column: $table.startMs, builder: (column) => column);

  GeneratedColumn<int> get endMs =>
      $composableBuilder(column: $table.endMs, builder: (column) => column);

  GeneratedColumn<int> get audioFileIndex => $composableBuilder(
      column: $table.audioFileIndex, builder: (column) => column);
}

class $$AudioCuesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $AudioCuesTable,
    AudioCueRow,
    $$AudioCuesTableFilterComposer,
    $$AudioCuesTableOrderingComposer,
    $$AudioCuesTableAnnotationComposer,
    $$AudioCuesTableCreateCompanionBuilder,
    $$AudioCuesTableUpdateCompanionBuilder,
    (
      AudioCueRow,
      BaseReferences<_$HibikiDatabase, $AudioCuesTable, AudioCueRow>
    ),
    AudioCueRow,
    PrefetchHooks Function()> {
  $$AudioCuesTableTableManager(_$HibikiDatabase db, $AudioCuesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AudioCuesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AudioCuesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AudioCuesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> bookUid = const Value.absent(),
            Value<String> chapterHref = const Value.absent(),
            Value<int> sentenceIndex = const Value.absent(),
            Value<String> textFragmentId = const Value.absent(),
            Value<String> cueText = const Value.absent(),
            Value<int> startMs = const Value.absent(),
            Value<int> endMs = const Value.absent(),
            Value<int> audioFileIndex = const Value.absent(),
          }) =>
              AudioCuesCompanion(
            id: id,
            bookUid: bookUid,
            chapterHref: chapterHref,
            sentenceIndex: sentenceIndex,
            textFragmentId: textFragmentId,
            cueText: cueText,
            startMs: startMs,
            endMs: endMs,
            audioFileIndex: audioFileIndex,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String bookUid,
            required String chapterHref,
            required int sentenceIndex,
            required String textFragmentId,
            required String cueText,
            required int startMs,
            required int endMs,
            required int audioFileIndex,
          }) =>
              AudioCuesCompanion.insert(
            id: id,
            bookUid: bookUid,
            chapterHref: chapterHref,
            sentenceIndex: sentenceIndex,
            textFragmentId: textFragmentId,
            cueText: cueText,
            startMs: startMs,
            endMs: endMs,
            audioFileIndex: audioFileIndex,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AudioCuesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $AudioCuesTable,
    AudioCueRow,
    $$AudioCuesTableFilterComposer,
    $$AudioCuesTableOrderingComposer,
    $$AudioCuesTableAnnotationComposer,
    $$AudioCuesTableCreateCompanionBuilder,
    $$AudioCuesTableUpdateCompanionBuilder,
    (
      AudioCueRow,
      BaseReferences<_$HibikiDatabase, $AudioCuesTable, AudioCueRow>
    ),
    AudioCueRow,
    PrefetchHooks Function()>;
typedef $$SrtBooksTableCreateCompanionBuilder = SrtBooksCompanion Function({
  Value<int> id,
  required String uid,
  required String title,
  Value<String?> author,
  Value<String?> audioRoot,
  Value<String?> audioPathsJson,
  required String srtPath,
  Value<String?> coverPath,
  required int importedAt,
  Value<int> ttuBookId,
});
typedef $$SrtBooksTableUpdateCompanionBuilder = SrtBooksCompanion Function({
  Value<int> id,
  Value<String> uid,
  Value<String> title,
  Value<String?> author,
  Value<String?> audioRoot,
  Value<String?> audioPathsJson,
  Value<String> srtPath,
  Value<String?> coverPath,
  Value<int> importedAt,
  Value<int> ttuBookId,
});

class $$SrtBooksTableFilterComposer
    extends Composer<_$HibikiDatabase, $SrtBooksTable> {
  $$SrtBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioRoot => $composableBuilder(
      column: $table.audioRoot, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioPathsJson => $composableBuilder(
      column: $table.audioPathsJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get srtPath => $composableBuilder(
      column: $table.srtPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ttuBookId => $composableBuilder(
      column: $table.ttuBookId, builder: (column) => ColumnFilters(column));
}

class $$SrtBooksTableOrderingComposer
    extends Composer<_$HibikiDatabase, $SrtBooksTable> {
  $$SrtBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uid => $composableBuilder(
      column: $table.uid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioRoot => $composableBuilder(
      column: $table.audioRoot, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioPathsJson => $composableBuilder(
      column: $table.audioPathsJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get srtPath => $composableBuilder(
      column: $table.srtPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ttuBookId => $composableBuilder(
      column: $table.ttuBookId, builder: (column) => ColumnOrderings(column));
}

class $$SrtBooksTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $SrtBooksTable> {
  $$SrtBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uid =>
      $composableBuilder(column: $table.uid, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get audioRoot =>
      $composableBuilder(column: $table.audioRoot, builder: (column) => column);

  GeneratedColumn<String> get audioPathsJson => $composableBuilder(
      column: $table.audioPathsJson, builder: (column) => column);

  GeneratedColumn<String> get srtPath =>
      $composableBuilder(column: $table.srtPath, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => column);

  GeneratedColumn<int> get ttuBookId =>
      $composableBuilder(column: $table.ttuBookId, builder: (column) => column);
}

class $$SrtBooksTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $SrtBooksTable,
    SrtBookRow,
    $$SrtBooksTableFilterComposer,
    $$SrtBooksTableOrderingComposer,
    $$SrtBooksTableAnnotationComposer,
    $$SrtBooksTableCreateCompanionBuilder,
    $$SrtBooksTableUpdateCompanionBuilder,
    (SrtBookRow, BaseReferences<_$HibikiDatabase, $SrtBooksTable, SrtBookRow>),
    SrtBookRow,
    PrefetchHooks Function()> {
  $$SrtBooksTableTableManager(_$HibikiDatabase db, $SrtBooksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrtBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrtBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrtBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uid = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String?> author = const Value.absent(),
            Value<String?> audioRoot = const Value.absent(),
            Value<String?> audioPathsJson = const Value.absent(),
            Value<String> srtPath = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            Value<int> importedAt = const Value.absent(),
            Value<int> ttuBookId = const Value.absent(),
          }) =>
              SrtBooksCompanion(
            id: id,
            uid: uid,
            title: title,
            author: author,
            audioRoot: audioRoot,
            audioPathsJson: audioPathsJson,
            srtPath: srtPath,
            coverPath: coverPath,
            importedAt: importedAt,
            ttuBookId: ttuBookId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String uid,
            required String title,
            Value<String?> author = const Value.absent(),
            Value<String?> audioRoot = const Value.absent(),
            Value<String?> audioPathsJson = const Value.absent(),
            required String srtPath,
            Value<String?> coverPath = const Value.absent(),
            required int importedAt,
            Value<int> ttuBookId = const Value.absent(),
          }) =>
              SrtBooksCompanion.insert(
            id: id,
            uid: uid,
            title: title,
            author: author,
            audioRoot: audioRoot,
            audioPathsJson: audioPathsJson,
            srtPath: srtPath,
            coverPath: coverPath,
            importedAt: importedAt,
            ttuBookId: ttuBookId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SrtBooksTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $SrtBooksTable,
    SrtBookRow,
    $$SrtBooksTableFilterComposer,
    $$SrtBooksTableOrderingComposer,
    $$SrtBooksTableAnnotationComposer,
    $$SrtBooksTableCreateCompanionBuilder,
    $$SrtBooksTableUpdateCompanionBuilder,
    (SrtBookRow, BaseReferences<_$HibikiDatabase, $SrtBooksTable, SrtBookRow>),
    SrtBookRow,
    PrefetchHooks Function()>;
typedef $$ReaderPositionsTableCreateCompanionBuilder = ReaderPositionsCompanion
    Function({
  Value<int> id,
  required int ttuBookId,
  required int sectionIndex,
  required int normCharOffset,
  Value<int> ttuCharOffset,
  required int updatedAt,
});
typedef $$ReaderPositionsTableUpdateCompanionBuilder = ReaderPositionsCompanion
    Function({
  Value<int> id,
  Value<int> ttuBookId,
  Value<int> sectionIndex,
  Value<int> normCharOffset,
  Value<int> ttuCharOffset,
  Value<int> updatedAt,
});

class $$ReaderPositionsTableFilterComposer
    extends Composer<_$HibikiDatabase, $ReaderPositionsTable> {
  $$ReaderPositionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ttuBookId => $composableBuilder(
      column: $table.ttuBookId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ttuCharOffset => $composableBuilder(
      column: $table.ttuCharOffset, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ReaderPositionsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $ReaderPositionsTable> {
  $$ReaderPositionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ttuBookId => $composableBuilder(
      column: $table.ttuBookId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ttuCharOffset => $composableBuilder(
      column: $table.ttuCharOffset,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ReaderPositionsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $ReaderPositionsTable> {
  $$ReaderPositionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get ttuBookId =>
      $composableBuilder(column: $table.ttuBookId, builder: (column) => column);

  GeneratedColumn<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => column);

  GeneratedColumn<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset, builder: (column) => column);

  GeneratedColumn<int> get ttuCharOffset => $composableBuilder(
      column: $table.ttuCharOffset, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ReaderPositionsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $ReaderPositionsTable,
    ReaderPositionRow,
    $$ReaderPositionsTableFilterComposer,
    $$ReaderPositionsTableOrderingComposer,
    $$ReaderPositionsTableAnnotationComposer,
    $$ReaderPositionsTableCreateCompanionBuilder,
    $$ReaderPositionsTableUpdateCompanionBuilder,
    (
      ReaderPositionRow,
      BaseReferences<_$HibikiDatabase, $ReaderPositionsTable, ReaderPositionRow>
    ),
    ReaderPositionRow,
    PrefetchHooks Function()> {
  $$ReaderPositionsTableTableManager(
      _$HibikiDatabase db, $ReaderPositionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReaderPositionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReaderPositionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReaderPositionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> ttuBookId = const Value.absent(),
            Value<int> sectionIndex = const Value.absent(),
            Value<int> normCharOffset = const Value.absent(),
            Value<int> ttuCharOffset = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
          }) =>
              ReaderPositionsCompanion(
            id: id,
            ttuBookId: ttuBookId,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            ttuCharOffset: ttuCharOffset,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int ttuBookId,
            required int sectionIndex,
            required int normCharOffset,
            Value<int> ttuCharOffset = const Value.absent(),
            required int updatedAt,
          }) =>
              ReaderPositionsCompanion.insert(
            id: id,
            ttuBookId: ttuBookId,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            ttuCharOffset: ttuCharOffset,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ReaderPositionsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $ReaderPositionsTable,
    ReaderPositionRow,
    $$ReaderPositionsTableFilterComposer,
    $$ReaderPositionsTableOrderingComposer,
    $$ReaderPositionsTableAnnotationComposer,
    $$ReaderPositionsTableCreateCompanionBuilder,
    $$ReaderPositionsTableUpdateCompanionBuilder,
    (
      ReaderPositionRow,
      BaseReferences<_$HibikiDatabase, $ReaderPositionsTable, ReaderPositionRow>
    ),
    ReaderPositionRow,
    PrefetchHooks Function()>;
typedef $$ReadingStatisticsTableCreateCompanionBuilder
    = ReadingStatisticsCompanion Function({
  Value<int> id,
  required String title,
  required String dateKey,
  required int charactersRead,
  required int readingTimeMs,
  required int lastStatisticModified,
});
typedef $$ReadingStatisticsTableUpdateCompanionBuilder
    = ReadingStatisticsCompanion Function({
  Value<int> id,
  Value<String> title,
  Value<String> dateKey,
  Value<int> charactersRead,
  Value<int> readingTimeMs,
  Value<int> lastStatisticModified,
});

class $$ReadingStatisticsTableFilterComposer
    extends Composer<_$HibikiDatabase, $ReadingStatisticsTable> {
  $$ReadingStatisticsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get charactersRead => $composableBuilder(
      column: $table.charactersRead,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get readingTimeMs => $composableBuilder(
      column: $table.readingTimeMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastStatisticModified => $composableBuilder(
      column: $table.lastStatisticModified,
      builder: (column) => ColumnFilters(column));
}

class $$ReadingStatisticsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $ReadingStatisticsTable> {
  $$ReadingStatisticsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get charactersRead => $composableBuilder(
      column: $table.charactersRead,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get readingTimeMs => $composableBuilder(
      column: $table.readingTimeMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastStatisticModified => $composableBuilder(
      column: $table.lastStatisticModified,
      builder: (column) => ColumnOrderings(column));
}

class $$ReadingStatisticsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $ReadingStatisticsTable> {
  $$ReadingStatisticsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<int> get charactersRead => $composableBuilder(
      column: $table.charactersRead, builder: (column) => column);

  GeneratedColumn<int> get readingTimeMs => $composableBuilder(
      column: $table.readingTimeMs, builder: (column) => column);

  GeneratedColumn<int> get lastStatisticModified => $composableBuilder(
      column: $table.lastStatisticModified, builder: (column) => column);
}

class $$ReadingStatisticsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $ReadingStatisticsTable,
    ReadingStatisticRow,
    $$ReadingStatisticsTableFilterComposer,
    $$ReadingStatisticsTableOrderingComposer,
    $$ReadingStatisticsTableAnnotationComposer,
    $$ReadingStatisticsTableCreateCompanionBuilder,
    $$ReadingStatisticsTableUpdateCompanionBuilder,
    (
      ReadingStatisticRow,
      BaseReferences<_$HibikiDatabase, $ReadingStatisticsTable,
          ReadingStatisticRow>
    ),
    ReadingStatisticRow,
    PrefetchHooks Function()> {
  $$ReadingStatisticsTableTableManager(
      _$HibikiDatabase db, $ReadingStatisticsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReadingStatisticsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReadingStatisticsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReadingStatisticsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> charactersRead = const Value.absent(),
            Value<int> readingTimeMs = const Value.absent(),
            Value<int> lastStatisticModified = const Value.absent(),
          }) =>
              ReadingStatisticsCompanion(
            id: id,
            title: title,
            dateKey: dateKey,
            charactersRead: charactersRead,
            readingTimeMs: readingTimeMs,
            lastStatisticModified: lastStatisticModified,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String title,
            required String dateKey,
            required int charactersRead,
            required int readingTimeMs,
            required int lastStatisticModified,
          }) =>
              ReadingStatisticsCompanion.insert(
            id: id,
            title: title,
            dateKey: dateKey,
            charactersRead: charactersRead,
            readingTimeMs: readingTimeMs,
            lastStatisticModified: lastStatisticModified,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ReadingStatisticsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $ReadingStatisticsTable,
    ReadingStatisticRow,
    $$ReadingStatisticsTableFilterComposer,
    $$ReadingStatisticsTableOrderingComposer,
    $$ReadingStatisticsTableAnnotationComposer,
    $$ReadingStatisticsTableCreateCompanionBuilder,
    $$ReadingStatisticsTableUpdateCompanionBuilder,
    (
      ReadingStatisticRow,
      BaseReferences<_$HibikiDatabase, $ReadingStatisticsTable,
          ReadingStatisticRow>
    ),
    ReadingStatisticRow,
    PrefetchHooks Function()>;
typedef $$ReadingHourlyLogsTableCreateCompanionBuilder
    = ReadingHourlyLogsCompanion Function({
  Value<int> id,
  required String dateKey,
  required int hour,
  required int readingTimeMs,
});
typedef $$ReadingHourlyLogsTableUpdateCompanionBuilder
    = ReadingHourlyLogsCompanion Function({
  Value<int> id,
  Value<String> dateKey,
  Value<int> hour,
  Value<int> readingTimeMs,
});

class $$ReadingHourlyLogsTableFilterComposer
    extends Composer<_$HibikiDatabase, $ReadingHourlyLogsTable> {
  $$ReadingHourlyLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get hour => $composableBuilder(
      column: $table.hour, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get readingTimeMs => $composableBuilder(
      column: $table.readingTimeMs, builder: (column) => ColumnFilters(column));
}

class $$ReadingHourlyLogsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $ReadingHourlyLogsTable> {
  $$ReadingHourlyLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get hour => $composableBuilder(
      column: $table.hour, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get readingTimeMs => $composableBuilder(
      column: $table.readingTimeMs,
      builder: (column) => ColumnOrderings(column));
}

class $$ReadingHourlyLogsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $ReadingHourlyLogsTable> {
  $$ReadingHourlyLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<int> get hour =>
      $composableBuilder(column: $table.hour, builder: (column) => column);

  GeneratedColumn<int> get readingTimeMs => $composableBuilder(
      column: $table.readingTimeMs, builder: (column) => column);
}

class $$ReadingHourlyLogsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $ReadingHourlyLogsTable,
    ReadingHourlyLogRow,
    $$ReadingHourlyLogsTableFilterComposer,
    $$ReadingHourlyLogsTableOrderingComposer,
    $$ReadingHourlyLogsTableAnnotationComposer,
    $$ReadingHourlyLogsTableCreateCompanionBuilder,
    $$ReadingHourlyLogsTableUpdateCompanionBuilder,
    (
      ReadingHourlyLogRow,
      BaseReferences<_$HibikiDatabase, $ReadingHourlyLogsTable,
          ReadingHourlyLogRow>
    ),
    ReadingHourlyLogRow,
    PrefetchHooks Function()> {
  $$ReadingHourlyLogsTableTableManager(
      _$HibikiDatabase db, $ReadingHourlyLogsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReadingHourlyLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReadingHourlyLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReadingHourlyLogsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> hour = const Value.absent(),
            Value<int> readingTimeMs = const Value.absent(),
          }) =>
              ReadingHourlyLogsCompanion(
            id: id,
            dateKey: dateKey,
            hour: hour,
            readingTimeMs: readingTimeMs,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String dateKey,
            required int hour,
            required int readingTimeMs,
          }) =>
              ReadingHourlyLogsCompanion.insert(
            id: id,
            dateKey: dateKey,
            hour: hour,
            readingTimeMs: readingTimeMs,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ReadingHourlyLogsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $ReadingHourlyLogsTable,
    ReadingHourlyLogRow,
    $$ReadingHourlyLogsTableFilterComposer,
    $$ReadingHourlyLogsTableOrderingComposer,
    $$ReadingHourlyLogsTableAnnotationComposer,
    $$ReadingHourlyLogsTableCreateCompanionBuilder,
    $$ReadingHourlyLogsTableUpdateCompanionBuilder,
    (
      ReadingHourlyLogRow,
      BaseReferences<_$HibikiDatabase, $ReadingHourlyLogsTable,
          ReadingHourlyLogRow>
    ),
    ReadingHourlyLogRow,
    PrefetchHooks Function()>;
typedef $$PreferencesTableCreateCompanionBuilder = PreferencesCompanion
    Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$PreferencesTableUpdateCompanionBuilder = PreferencesCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$PreferencesTableFilterComposer
    extends Composer<_$HibikiDatabase, $PreferencesTable> {
  $$PreferencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$PreferencesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $PreferencesTable> {
  $$PreferencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$PreferencesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $PreferencesTable> {
  $$PreferencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$PreferencesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $PreferencesTable,
    PreferenceRow,
    $$PreferencesTableFilterComposer,
    $$PreferencesTableOrderingComposer,
    $$PreferencesTableAnnotationComposer,
    $$PreferencesTableCreateCompanionBuilder,
    $$PreferencesTableUpdateCompanionBuilder,
    (
      PreferenceRow,
      BaseReferences<_$HibikiDatabase, $PreferencesTable, PreferenceRow>
    ),
    PreferenceRow,
    PrefetchHooks Function()> {
  $$PreferencesTableTableManager(_$HibikiDatabase db, $PreferencesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PreferencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PreferencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PreferencesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PreferencesCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              PreferencesCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PreferencesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $PreferencesTable,
    PreferenceRow,
    $$PreferencesTableFilterComposer,
    $$PreferencesTableOrderingComposer,
    $$PreferencesTableAnnotationComposer,
    $$PreferencesTableCreateCompanionBuilder,
    $$PreferencesTableUpdateCompanionBuilder,
    (
      PreferenceRow,
      BaseReferences<_$HibikiDatabase, $PreferencesTable, PreferenceRow>
    ),
    PreferenceRow,
    PrefetchHooks Function()>;
typedef $$DictionaryMetadataTableCreateCompanionBuilder
    = DictionaryMetadataCompanion Function({
  required String name,
  required String formatKey,
  required int order,
  Value<String> type,
  Value<String> metadataJson,
  Value<String> hiddenLanguagesJson,
  Value<String> collapsedLanguagesJson,
  Value<int> rowid,
});
typedef $$DictionaryMetadataTableUpdateCompanionBuilder
    = DictionaryMetadataCompanion Function({
  Value<String> name,
  Value<String> formatKey,
  Value<int> order,
  Value<String> type,
  Value<String> metadataJson,
  Value<String> hiddenLanguagesJson,
  Value<String> collapsedLanguagesJson,
  Value<int> rowid,
});

class $$DictionaryMetadataTableFilterComposer
    extends Composer<_$HibikiDatabase, $DictionaryMetadataTable> {
  $$DictionaryMetadataTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get formatKey => $composableBuilder(
      column: $table.formatKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get order => $composableBuilder(
      column: $table.order, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get metadataJson => $composableBuilder(
      column: $table.metadataJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get hiddenLanguagesJson => $composableBuilder(
      column: $table.hiddenLanguagesJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get collapsedLanguagesJson => $composableBuilder(
      column: $table.collapsedLanguagesJson,
      builder: (column) => ColumnFilters(column));
}

class $$DictionaryMetadataTableOrderingComposer
    extends Composer<_$HibikiDatabase, $DictionaryMetadataTable> {
  $$DictionaryMetadataTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get formatKey => $composableBuilder(
      column: $table.formatKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get order => $composableBuilder(
      column: $table.order, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get metadataJson => $composableBuilder(
      column: $table.metadataJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get hiddenLanguagesJson => $composableBuilder(
      column: $table.hiddenLanguagesJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get collapsedLanguagesJson => $composableBuilder(
      column: $table.collapsedLanguagesJson,
      builder: (column) => ColumnOrderings(column));
}

class $$DictionaryMetadataTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $DictionaryMetadataTable> {
  $$DictionaryMetadataTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get formatKey =>
      $composableBuilder(column: $table.formatKey, builder: (column) => column);

  GeneratedColumn<int> get order =>
      $composableBuilder(column: $table.order, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get metadataJson => $composableBuilder(
      column: $table.metadataJson, builder: (column) => column);

  GeneratedColumn<String> get hiddenLanguagesJson => $composableBuilder(
      column: $table.hiddenLanguagesJson, builder: (column) => column);

  GeneratedColumn<String> get collapsedLanguagesJson => $composableBuilder(
      column: $table.collapsedLanguagesJson, builder: (column) => column);
}

class $$DictionaryMetadataTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $DictionaryMetadataTable,
    DictionaryMetaRow,
    $$DictionaryMetadataTableFilterComposer,
    $$DictionaryMetadataTableOrderingComposer,
    $$DictionaryMetadataTableAnnotationComposer,
    $$DictionaryMetadataTableCreateCompanionBuilder,
    $$DictionaryMetadataTableUpdateCompanionBuilder,
    (
      DictionaryMetaRow,
      BaseReferences<_$HibikiDatabase, $DictionaryMetadataTable,
          DictionaryMetaRow>
    ),
    DictionaryMetaRow,
    PrefetchHooks Function()> {
  $$DictionaryMetadataTableTableManager(
      _$HibikiDatabase db, $DictionaryMetadataTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DictionaryMetadataTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DictionaryMetadataTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DictionaryMetadataTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> name = const Value.absent(),
            Value<String> formatKey = const Value.absent(),
            Value<int> order = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<String> metadataJson = const Value.absent(),
            Value<String> hiddenLanguagesJson = const Value.absent(),
            Value<String> collapsedLanguagesJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DictionaryMetadataCompanion(
            name: name,
            formatKey: formatKey,
            order: order,
            type: type,
            metadataJson: metadataJson,
            hiddenLanguagesJson: hiddenLanguagesJson,
            collapsedLanguagesJson: collapsedLanguagesJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String name,
            required String formatKey,
            required int order,
            Value<String> type = const Value.absent(),
            Value<String> metadataJson = const Value.absent(),
            Value<String> hiddenLanguagesJson = const Value.absent(),
            Value<String> collapsedLanguagesJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DictionaryMetadataCompanion.insert(
            name: name,
            formatKey: formatKey,
            order: order,
            type: type,
            metadataJson: metadataJson,
            hiddenLanguagesJson: hiddenLanguagesJson,
            collapsedLanguagesJson: collapsedLanguagesJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DictionaryMetadataTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $DictionaryMetadataTable,
    DictionaryMetaRow,
    $$DictionaryMetadataTableFilterComposer,
    $$DictionaryMetadataTableOrderingComposer,
    $$DictionaryMetadataTableAnnotationComposer,
    $$DictionaryMetadataTableCreateCompanionBuilder,
    $$DictionaryMetadataTableUpdateCompanionBuilder,
    (
      DictionaryMetaRow,
      BaseReferences<_$HibikiDatabase, $DictionaryMetadataTable,
          DictionaryMetaRow>
    ),
    DictionaryMetaRow,
    PrefetchHooks Function()>;
typedef $$DictionaryHistoryTableCreateCompanionBuilder
    = DictionaryHistoryCompanion Function({
  Value<int> id,
  required int position,
  required String resultJson,
});
typedef $$DictionaryHistoryTableUpdateCompanionBuilder
    = DictionaryHistoryCompanion Function({
  Value<int> id,
  Value<int> position,
  Value<String> resultJson,
});

class $$DictionaryHistoryTableFilterComposer
    extends Composer<_$HibikiDatabase, $DictionaryHistoryTable> {
  $$DictionaryHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get resultJson => $composableBuilder(
      column: $table.resultJson, builder: (column) => ColumnFilters(column));
}

class $$DictionaryHistoryTableOrderingComposer
    extends Composer<_$HibikiDatabase, $DictionaryHistoryTable> {
  $$DictionaryHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get resultJson => $composableBuilder(
      column: $table.resultJson, builder: (column) => ColumnOrderings(column));
}

class $$DictionaryHistoryTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $DictionaryHistoryTable> {
  $$DictionaryHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get resultJson => $composableBuilder(
      column: $table.resultJson, builder: (column) => column);
}

class $$DictionaryHistoryTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $DictionaryHistoryTable,
    DictionaryHistoryRow,
    $$DictionaryHistoryTableFilterComposer,
    $$DictionaryHistoryTableOrderingComposer,
    $$DictionaryHistoryTableAnnotationComposer,
    $$DictionaryHistoryTableCreateCompanionBuilder,
    $$DictionaryHistoryTableUpdateCompanionBuilder,
    (
      DictionaryHistoryRow,
      BaseReferences<_$HibikiDatabase, $DictionaryHistoryTable,
          DictionaryHistoryRow>
    ),
    DictionaryHistoryRow,
    PrefetchHooks Function()> {
  $$DictionaryHistoryTableTableManager(
      _$HibikiDatabase db, $DictionaryHistoryTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DictionaryHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DictionaryHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DictionaryHistoryTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<String> resultJson = const Value.absent(),
          }) =>
              DictionaryHistoryCompanion(
            id: id,
            position: position,
            resultJson: resultJson,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int position,
            required String resultJson,
          }) =>
              DictionaryHistoryCompanion.insert(
            id: id,
            position: position,
            resultJson: resultJson,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DictionaryHistoryTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $DictionaryHistoryTable,
    DictionaryHistoryRow,
    $$DictionaryHistoryTableFilterComposer,
    $$DictionaryHistoryTableOrderingComposer,
    $$DictionaryHistoryTableAnnotationComposer,
    $$DictionaryHistoryTableCreateCompanionBuilder,
    $$DictionaryHistoryTableUpdateCompanionBuilder,
    (
      DictionaryHistoryRow,
      BaseReferences<_$HibikiDatabase, $DictionaryHistoryTable,
          DictionaryHistoryRow>
    ),
    DictionaryHistoryRow,
    PrefetchHooks Function()>;
typedef $$EpubBooksTableCreateCompanionBuilder = EpubBooksCompanion Function({
  Value<int> id,
  required String title,
  Value<String?> author,
  Value<String?> coverPath,
  required String epubPath,
  required String extractDir,
  required int chapterCount,
  required String chaptersJson,
  Value<String?> tocJson,
  Value<String?> sourceMetadata,
  required int importedAt,
});
typedef $$EpubBooksTableUpdateCompanionBuilder = EpubBooksCompanion Function({
  Value<int> id,
  Value<String> title,
  Value<String?> author,
  Value<String?> coverPath,
  Value<String> epubPath,
  Value<String> extractDir,
  Value<int> chapterCount,
  Value<String> chaptersJson,
  Value<String?> tocJson,
  Value<String?> sourceMetadata,
  Value<int> importedAt,
});

class $$EpubBooksTableFilterComposer
    extends Composer<_$HibikiDatabase, $EpubBooksTable> {
  $$EpubBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get epubPath => $composableBuilder(
      column: $table.epubPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get extractDir => $composableBuilder(
      column: $table.extractDir, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get chapterCount => $composableBuilder(
      column: $table.chapterCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get chaptersJson => $composableBuilder(
      column: $table.chaptersJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tocJson => $composableBuilder(
      column: $table.tocJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceMetadata => $composableBuilder(
      column: $table.sourceMetadata,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnFilters(column));
}

class $$EpubBooksTableOrderingComposer
    extends Composer<_$HibikiDatabase, $EpubBooksTable> {
  $$EpubBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get epubPath => $composableBuilder(
      column: $table.epubPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get extractDir => $composableBuilder(
      column: $table.extractDir, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get chapterCount => $composableBuilder(
      column: $table.chapterCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get chaptersJson => $composableBuilder(
      column: $table.chaptersJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tocJson => $composableBuilder(
      column: $table.tocJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceMetadata => $composableBuilder(
      column: $table.sourceMetadata,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnOrderings(column));
}

class $$EpubBooksTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $EpubBooksTable> {
  $$EpubBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<String> get epubPath =>
      $composableBuilder(column: $table.epubPath, builder: (column) => column);

  GeneratedColumn<String> get extractDir => $composableBuilder(
      column: $table.extractDir, builder: (column) => column);

  GeneratedColumn<int> get chapterCount => $composableBuilder(
      column: $table.chapterCount, builder: (column) => column);

  GeneratedColumn<String> get chaptersJson => $composableBuilder(
      column: $table.chaptersJson, builder: (column) => column);

  GeneratedColumn<String> get tocJson =>
      $composableBuilder(column: $table.tocJson, builder: (column) => column);

  GeneratedColumn<String> get sourceMetadata => $composableBuilder(
      column: $table.sourceMetadata, builder: (column) => column);

  GeneratedColumn<int> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => column);
}

class $$EpubBooksTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $EpubBooksTable,
    EpubBookRow,
    $$EpubBooksTableFilterComposer,
    $$EpubBooksTableOrderingComposer,
    $$EpubBooksTableAnnotationComposer,
    $$EpubBooksTableCreateCompanionBuilder,
    $$EpubBooksTableUpdateCompanionBuilder,
    (
      EpubBookRow,
      BaseReferences<_$HibikiDatabase, $EpubBooksTable, EpubBookRow>
    ),
    EpubBookRow,
    PrefetchHooks Function()> {
  $$EpubBooksTableTableManager(_$HibikiDatabase db, $EpubBooksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EpubBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EpubBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EpubBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String?> author = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            Value<String> epubPath = const Value.absent(),
            Value<String> extractDir = const Value.absent(),
            Value<int> chapterCount = const Value.absent(),
            Value<String> chaptersJson = const Value.absent(),
            Value<String?> tocJson = const Value.absent(),
            Value<String?> sourceMetadata = const Value.absent(),
            Value<int> importedAt = const Value.absent(),
          }) =>
              EpubBooksCompanion(
            id: id,
            title: title,
            author: author,
            coverPath: coverPath,
            epubPath: epubPath,
            extractDir: extractDir,
            chapterCount: chapterCount,
            chaptersJson: chaptersJson,
            tocJson: tocJson,
            sourceMetadata: sourceMetadata,
            importedAt: importedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String title,
            Value<String?> author = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            required String epubPath,
            required String extractDir,
            required int chapterCount,
            required String chaptersJson,
            Value<String?> tocJson = const Value.absent(),
            Value<String?> sourceMetadata = const Value.absent(),
            required int importedAt,
          }) =>
              EpubBooksCompanion.insert(
            id: id,
            title: title,
            author: author,
            coverPath: coverPath,
            epubPath: epubPath,
            extractDir: extractDir,
            chapterCount: chapterCount,
            chaptersJson: chaptersJson,
            tocJson: tocJson,
            sourceMetadata: sourceMetadata,
            importedAt: importedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$EpubBooksTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $EpubBooksTable,
    EpubBookRow,
    $$EpubBooksTableFilterComposer,
    $$EpubBooksTableOrderingComposer,
    $$EpubBooksTableAnnotationComposer,
    $$EpubBooksTableCreateCompanionBuilder,
    $$EpubBooksTableUpdateCompanionBuilder,
    (
      EpubBookRow,
      BaseReferences<_$HibikiDatabase, $EpubBooksTable, EpubBookRow>
    ),
    EpubBookRow,
    PrefetchHooks Function()>;

typedef $$BookTagsTableCreateCompanionBuilder = BookTagsCompanion Function({
  Value<int> id,
  required String name,
  Value<int> colorValue,
  required int createdAt,
});
typedef $$BookTagsTableUpdateCompanionBuilder = BookTagsCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<int> colorValue,
  Value<int> createdAt,
});

class $$BookTagsTableFilterComposer
    extends Composer<_$HibikiDatabase, $BookTagsTable> {
  $$BookTagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get colorValue => $composableBuilder(
      column: $table.colorValue, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$BookTagsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $BookTagsTable> {
  $$BookTagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get colorValue => $composableBuilder(
      column: $table.colorValue, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$BookTagsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $BookTagsTable> {
  $$BookTagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get colorValue =>
      $composableBuilder(column: $table.colorValue, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$BookTagsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $BookTagsTable,
    BookTagRow,
    $$BookTagsTableFilterComposer,
    $$BookTagsTableOrderingComposer,
    $$BookTagsTableAnnotationComposer,
    $$BookTagsTableCreateCompanionBuilder,
    $$BookTagsTableUpdateCompanionBuilder,
    (
      BookTagRow,
      BaseReferences<_$HibikiDatabase, $BookTagsTable, BookTagRow>
    ),
    BookTagRow,
    PrefetchHooks Function()> {
  $$BookTagsTableTableManager(_$HibikiDatabase db, $BookTagsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookTagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookTagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookTagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> colorValue = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              BookTagsCompanion(
            id: id,
            name: name,
            colorValue: colorValue,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            Value<int> colorValue = const Value.absent(),
            required int createdAt,
          }) =>
              BookTagsCompanion.insert(
            id: id,
            name: name,
            colorValue: colorValue,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BookTagsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $BookTagsTable,
    BookTagRow,
    $$BookTagsTableFilterComposer,
    $$BookTagsTableOrderingComposer,
    $$BookTagsTableAnnotationComposer,
    $$BookTagsTableCreateCompanionBuilder,
    $$BookTagsTableUpdateCompanionBuilder,
    (
      BookTagRow,
      BaseReferences<_$HibikiDatabase, $BookTagsTable, BookTagRow>
    ),
    BookTagRow,
    PrefetchHooks Function()>;

typedef $$BookTagMappingsTableCreateCompanionBuilder =
    BookTagMappingsCompanion Function({
  Value<int> id,
  required int bookId,
  required int tagId,
});
typedef $$BookTagMappingsTableUpdateCompanionBuilder =
    BookTagMappingsCompanion Function({
  Value<int> id,
  Value<int> bookId,
  Value<int> tagId,
});

class $$BookTagMappingsTableFilterComposer
    extends Composer<_$HibikiDatabase, $BookTagMappingsTable> {
  $$BookTagMappingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get bookId => $composableBuilder(
      column: $table.bookId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get tagId => $composableBuilder(
      column: $table.tagId, builder: (column) => ColumnFilters(column));
}

class $$BookTagMappingsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $BookTagMappingsTable> {
  $$BookTagMappingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get bookId => $composableBuilder(
      column: $table.bookId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get tagId => $composableBuilder(
      column: $table.tagId, builder: (column) => ColumnOrderings(column));
}

class $$BookTagMappingsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $BookTagMappingsTable> {
  $$BookTagMappingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<int> get tagId =>
      $composableBuilder(column: $table.tagId, builder: (column) => column);
}

class $$BookTagMappingsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $BookTagMappingsTable,
    BookTagMappingRow,
    $$BookTagMappingsTableFilterComposer,
    $$BookTagMappingsTableOrderingComposer,
    $$BookTagMappingsTableAnnotationComposer,
    $$BookTagMappingsTableCreateCompanionBuilder,
    $$BookTagMappingsTableUpdateCompanionBuilder,
    (
      BookTagMappingRow,
      BaseReferences<_$HibikiDatabase, $BookTagMappingsTable, BookTagMappingRow>
    ),
    BookTagMappingRow,
    PrefetchHooks Function()> {
  $$BookTagMappingsTableTableManager(
      _$HibikiDatabase db, $BookTagMappingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookTagMappingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookTagMappingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookTagMappingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> bookId = const Value.absent(),
            Value<int> tagId = const Value.absent(),
          }) =>
              BookTagMappingsCompanion(
            id: id,
            bookId: bookId,
            tagId: tagId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int bookId,
            required int tagId,
          }) =>
              BookTagMappingsCompanion.insert(
            id: id,
            bookId: bookId,
            tagId: tagId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BookTagMappingsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $BookTagMappingsTable,
    BookTagMappingRow,
    $$BookTagMappingsTableFilterComposer,
    $$BookTagMappingsTableOrderingComposer,
    $$BookTagMappingsTableAnnotationComposer,
    $$BookTagMappingsTableCreateCompanionBuilder,
    $$BookTagMappingsTableUpdateCompanionBuilder,
    (
      BookTagMappingRow,
      BaseReferences<_$HibikiDatabase, $BookTagMappingsTable, BookTagMappingRow>
    ),
    BookTagMappingRow,
    PrefetchHooks Function()>;

// 鈹€鈹€ Profiles manager 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
typedef $$ProfilesTableCreateCompanionBuilder = ProfilesCompanion Function({
  Value<int> id,
  required String name,
  required int createdAt,
  required int updatedAt,
});
typedef $$ProfilesTableUpdateCompanionBuilder = ProfilesCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<int> createdAt,
  Value<int> updatedAt,
});

class $$ProfilesTableFilterComposer
    extends Composer<_$HibikiDatabase, $ProfilesTable> {
  $$ProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));
  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));
  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ProfilesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $ProfilesTable> {
  $$ProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ProfilesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $ProfilesTable> {
  $$ProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);
  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ProfilesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $ProfilesTable,
    ProfileRow,
    $$ProfilesTableFilterComposer,
    $$ProfilesTableOrderingComposer,
    $$ProfilesTableAnnotationComposer,
    $$ProfilesTableCreateCompanionBuilder,
    $$ProfilesTableUpdateCompanionBuilder,
    (ProfileRow, BaseReferences<_$HibikiDatabase, $ProfilesTable, ProfileRow>),
    ProfileRow,
    PrefetchHooks Function()> {
  $$ProfilesTableTableManager(_$HibikiDatabase db, $ProfilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
          }) =>
              ProfilesCompanion(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            required int createdAt,
            required int updatedAt,
          }) =>
              ProfilesCompanion.insert(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ProfilesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $ProfilesTable,
    ProfileRow,
    $$ProfilesTableFilterComposer,
    $$ProfilesTableOrderingComposer,
    $$ProfilesTableAnnotationComposer,
    $$ProfilesTableCreateCompanionBuilder,
    $$ProfilesTableUpdateCompanionBuilder,
    (ProfileRow, BaseReferences<_$HibikiDatabase, $ProfilesTable, ProfileRow>),
    ProfileRow,
    PrefetchHooks Function()>;

// 鈹€鈹€ ProfileSettings manager 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
typedef $$ProfileSettingsTableCreateCompanionBuilder
    = ProfileSettingsCompanion Function({
  Value<int> id,
  required int profileId,
  required String category,
  required String key,
  required String value,
});
typedef $$ProfileSettingsTableUpdateCompanionBuilder
    = ProfileSettingsCompanion Function({
  Value<int> id,
  Value<int> profileId,
  Value<String> category,
  Value<String> key,
  Value<String> value,
});

class $$ProfileSettingsTableFilterComposer
    extends Composer<_$HibikiDatabase, $ProfileSettingsTable> {
  $$ProfileSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));
  ColumnFilters<int> get profileId => $composableBuilder(
      column: $table.profileId, builder: (column) => ColumnFilters(column));
  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));
  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$ProfileSettingsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $ProfileSettingsTable> {
  $$ProfileSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<int> get profileId => $composableBuilder(
      column: $table.profileId, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$ProfileSettingsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $ProfileSettingsTable> {
  $$ProfileSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);
  GeneratedColumn<int> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);
  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);
  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$ProfileSettingsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $ProfileSettingsTable,
    ProfileSettingRow,
    $$ProfileSettingsTableFilterComposer,
    $$ProfileSettingsTableOrderingComposer,
    $$ProfileSettingsTableAnnotationComposer,
    $$ProfileSettingsTableCreateCompanionBuilder,
    $$ProfileSettingsTableUpdateCompanionBuilder,
    (
      ProfileSettingRow,
      BaseReferences<_$HibikiDatabase, $ProfileSettingsTable, ProfileSettingRow>
    ),
    ProfileSettingRow,
    PrefetchHooks Function()> {
  $$ProfileSettingsTableTableManager(
      _$HibikiDatabase db, $ProfileSettingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfileSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfileSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfileSettingsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> profileId = const Value.absent(),
            Value<String> category = const Value.absent(),
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
          }) =>
              ProfileSettingsCompanion(
            id: id,
            profileId: profileId,
            category: category,
            key: key,
            value: value,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int profileId,
            required String category,
            required String key,
            required String value,
          }) =>
              ProfileSettingsCompanion.insert(
            id: id,
            profileId: profileId,
            category: category,
            key: key,
            value: value,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ProfileSettingsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $ProfileSettingsTable,
    ProfileSettingRow,
    $$ProfileSettingsTableFilterComposer,
    $$ProfileSettingsTableOrderingComposer,
    $$ProfileSettingsTableAnnotationComposer,
    $$ProfileSettingsTableCreateCompanionBuilder,
    $$ProfileSettingsTableUpdateCompanionBuilder,
    (
      ProfileSettingRow,
      BaseReferences<_$HibikiDatabase, $ProfileSettingsTable, ProfileSettingRow>
    ),
    ProfileSettingRow,
    PrefetchHooks Function()>;

// 鈹€鈹€ MediaTypeProfiles manager 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
typedef $$MediaTypeProfilesTableCreateCompanionBuilder
    = MediaTypeProfilesCompanion Function({
  required String mediaType,
  required int profileId,
  Value<int> rowid,
});
typedef $$MediaTypeProfilesTableUpdateCompanionBuilder
    = MediaTypeProfilesCompanion Function({
  Value<String> mediaType,
  Value<int> profileId,
  Value<int> rowid,
});

class $$MediaTypeProfilesTableFilterComposer
    extends Composer<_$HibikiDatabase, $MediaTypeProfilesTable> {
  $$MediaTypeProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get mediaType => $composableBuilder(
      column: $table.mediaType, builder: (column) => ColumnFilters(column));
  ColumnFilters<int> get profileId => $composableBuilder(
      column: $table.profileId, builder: (column) => ColumnFilters(column));
}

class $$MediaTypeProfilesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $MediaTypeProfilesTable> {
  $$MediaTypeProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get mediaType => $composableBuilder(
      column: $table.mediaType, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<int> get profileId => $composableBuilder(
      column: $table.profileId, builder: (column) => ColumnOrderings(column));
}

class $$MediaTypeProfilesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $MediaTypeProfilesTable> {
  $$MediaTypeProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get mediaType =>
      $composableBuilder(column: $table.mediaType, builder: (column) => column);
  GeneratedColumn<int> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);
}

class $$MediaTypeProfilesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $MediaTypeProfilesTable,
    MediaTypeProfileRow,
    $$MediaTypeProfilesTableFilterComposer,
    $$MediaTypeProfilesTableOrderingComposer,
    $$MediaTypeProfilesTableAnnotationComposer,
    $$MediaTypeProfilesTableCreateCompanionBuilder,
    $$MediaTypeProfilesTableUpdateCompanionBuilder,
    (
      MediaTypeProfileRow,
      BaseReferences<_$HibikiDatabase, $MediaTypeProfilesTable,
          MediaTypeProfileRow>
    ),
    MediaTypeProfileRow,
    PrefetchHooks Function()> {
  $$MediaTypeProfilesTableTableManager(
      _$HibikiDatabase db, $MediaTypeProfilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaTypeProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaTypeProfilesTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaTypeProfilesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> mediaType = const Value.absent(),
            Value<int> profileId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MediaTypeProfilesCompanion(
            mediaType: mediaType,
            profileId: profileId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String mediaType,
            required int profileId,
            Value<int> rowid = const Value.absent(),
          }) =>
              MediaTypeProfilesCompanion.insert(
            mediaType: mediaType,
            profileId: profileId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MediaTypeProfilesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $MediaTypeProfilesTable,
    MediaTypeProfileRow,
    $$MediaTypeProfilesTableFilterComposer,
    $$MediaTypeProfilesTableOrderingComposer,
    $$MediaTypeProfilesTableAnnotationComposer,
    $$MediaTypeProfilesTableCreateCompanionBuilder,
    $$MediaTypeProfilesTableUpdateCompanionBuilder,
    (
      MediaTypeProfileRow,
      BaseReferences<_$HibikiDatabase, $MediaTypeProfilesTable,
          MediaTypeProfileRow>
    ),
    MediaTypeProfileRow,
    PrefetchHooks Function()>;

// 鈹€鈹€ BookProfiles manager 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
typedef $$BookProfilesTableCreateCompanionBuilder = BookProfilesCompanion
    Function({
  required String bookUid,
  required int profileId,
  Value<int> rowid,
});
typedef $$BookProfilesTableUpdateCompanionBuilder = BookProfilesCompanion
    Function({
  Value<String> bookUid,
  Value<int> profileId,
  Value<int> rowid,
});

class $$BookProfilesTableFilterComposer
    extends Composer<_$HibikiDatabase, $BookProfilesTable> {
  $$BookProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnFilters(column));
  ColumnFilters<int> get profileId => $composableBuilder(
      column: $table.profileId, builder: (column) => ColumnFilters(column));
}

class $$BookProfilesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $BookProfilesTable> {
  $$BookProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnOrderings(column));
  ColumnOrderings<int> get profileId => $composableBuilder(
      column: $table.profileId, builder: (column) => ColumnOrderings(column));
}

class $$BookProfilesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $BookProfilesTable> {
  $$BookProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookUid =>
      $composableBuilder(column: $table.bookUid, builder: (column) => column);
  GeneratedColumn<int> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);
}

class $$BookProfilesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $BookProfilesTable,
    BookProfileRow,
    $$BookProfilesTableFilterComposer,
    $$BookProfilesTableOrderingComposer,
    $$BookProfilesTableAnnotationComposer,
    $$BookProfilesTableCreateCompanionBuilder,
    $$BookProfilesTableUpdateCompanionBuilder,
    (
      BookProfileRow,
      BaseReferences<_$HibikiDatabase, $BookProfilesTable, BookProfileRow>
    ),
    BookProfileRow,
    PrefetchHooks Function()> {
  $$BookProfilesTableTableManager(
      _$HibikiDatabase db, $BookProfilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> bookUid = const Value.absent(),
            Value<int> profileId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BookProfilesCompanion(
            bookUid: bookUid,
            profileId: profileId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String bookUid,
            required int profileId,
            Value<int> rowid = const Value.absent(),
          }) =>
              BookProfilesCompanion.insert(
            bookUid: bookUid,
            profileId: profileId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BookProfilesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $BookProfilesTable,
    BookProfileRow,
    $$BookProfilesTableFilterComposer,
    $$BookProfilesTableOrderingComposer,
    $$BookProfilesTableAnnotationComposer,
    $$BookProfilesTableCreateCompanionBuilder,
    $$BookProfilesTableUpdateCompanionBuilder,
    (
      BookProfileRow,
      BaseReferences<_$HibikiDatabase, $BookProfilesTable, BookProfileRow>
    ),
    BookProfileRow,
    PrefetchHooks Function()>;


class $HibikiDatabaseManager {
  final _$HibikiDatabase _db;
  $HibikiDatabaseManager(this._db);
  $$MediaItemsTableTableManager get mediaItems =>
      $$MediaItemsTableTableManager(_db, _db.mediaItems);
  $$SearchHistoryItemsTableTableManager get searchHistoryItems =>
      $$SearchHistoryItemsTableTableManager(_db, _db.searchHistoryItems);
  $$AudiobooksTableTableManager get audiobooks =>
      $$AudiobooksTableTableManager(_db, _db.audiobooks);
  $$AudioCuesTableTableManager get audioCues =>
      $$AudioCuesTableTableManager(_db, _db.audioCues);
  $$SrtBooksTableTableManager get srtBooks =>
      $$SrtBooksTableTableManager(_db, _db.srtBooks);
  $$ReaderPositionsTableTableManager get readerPositions =>
      $$ReaderPositionsTableTableManager(_db, _db.readerPositions);
  $$ReadingStatisticsTableTableManager get readingStatistics =>
      $$ReadingStatisticsTableTableManager(_db, _db.readingStatistics);
  $$ReadingHourlyLogsTableTableManager get readingHourlyLogs =>
      $$ReadingHourlyLogsTableTableManager(_db, _db.readingHourlyLogs);
  $$PreferencesTableTableManager get preferences =>
      $$PreferencesTableTableManager(_db, _db.preferences);
  $$DictionaryMetadataTableTableManager get dictionaryMetadata =>
      $$DictionaryMetadataTableTableManager(_db, _db.dictionaryMetadata);
  $$DictionaryHistoryTableTableManager get dictionaryHistory =>
      $$DictionaryHistoryTableTableManager(_db, _db.dictionaryHistory);
  $$EpubBooksTableTableManager get epubBooks =>
      $$EpubBooksTableTableManager(_db, _db.epubBooks);
  $$BookTagsTableTableManager get bookTags =>
      $$BookTagsTableTableManager(_db, _db.bookTags);
  $$BookTagMappingsTableTableManager get bookTagMappings =>
      $$BookTagMappingsTableTableManager(_db, _db.bookTagMappings);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$ProfileSettingsTableTableManager get profileSettings =>
      $$ProfileSettingsTableTableManager(_db, _db.profileSettings);
  $$MediaTypeProfilesTableTableManager get mediaTypeProfiles =>
      $$MediaTypeProfilesTableTableManager(_db, _db.mediaTypeProfiles);
  $$BookProfilesTableTableManager get bookProfiles =>
      $$BookProfilesTableTableManager(_db, _db.bookProfiles);
}
