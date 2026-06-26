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

class $AnkiMappingsTable extends AnkiMappings
    with TableInfo<$AnkiMappingsTable, AnkiMappingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AnkiMappingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
      'label', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
      'model', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _exportFieldKeysJsonMeta =
      const VerificationMeta('exportFieldKeysJson');
  @override
  late final GeneratedColumn<String> exportFieldKeysJson =
      GeneratedColumn<String>('export_field_keys_json', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _creatorFieldKeysJsonMeta =
      const VerificationMeta('creatorFieldKeysJson');
  @override
  late final GeneratedColumn<String> creatorFieldKeysJson =
      GeneratedColumn<String>('creator_field_keys_json', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _creatorCollapsedFieldKeysJsonMeta =
      const VerificationMeta('creatorCollapsedFieldKeysJson');
  @override
  late final GeneratedColumn<String> creatorCollapsedFieldKeysJson =
      GeneratedColumn<String>(
          'creator_collapsed_field_keys_json', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumn<int> order = GeneratedColumn<int>(
      'order', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _tagsJsonMeta =
      const VerificationMeta('tagsJson');
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
      'tags_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _enhancementsJsonMeta =
      const VerificationMeta('enhancementsJson');
  @override
  late final GeneratedColumn<String> enhancementsJson = GeneratedColumn<String>(
      'enhancements_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _actionsJsonMeta =
      const VerificationMeta('actionsJson');
  @override
  late final GeneratedColumn<String> actionsJson = GeneratedColumn<String>(
      'actions_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _exportMediaTagsMeta =
      const VerificationMeta('exportMediaTags');
  @override
  late final GeneratedColumn<bool> exportMediaTags = GeneratedColumn<bool>(
      'export_media_tags', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("export_media_tags" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _useBrTagsMeta =
      const VerificationMeta('useBrTags');
  @override
  late final GeneratedColumn<bool> useBrTags = GeneratedColumn<bool>(
      'use_br_tags', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("use_br_tags" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _prependDictionaryNamesMeta =
      const VerificationMeta('prependDictionaryNames');
  @override
  late final GeneratedColumn<bool> prependDictionaryNames =
      GeneratedColumn<bool>('prepend_dictionary_names', aliasedName, false,
          type: DriftSqlType.bool,
          requiredDuringInsert: false,
          defaultConstraints: GeneratedColumn.constraintIsAlways(
              'CHECK ("prepend_dictionary_names" IN (0, 1))'),
          defaultValue: const Constant(true));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        label,
        model,
        exportFieldKeysJson,
        creatorFieldKeysJson,
        creatorCollapsedFieldKeysJson,
        order,
        tagsJson,
        enhancementsJson,
        actionsJson,
        exportMediaTags,
        useBrTags,
        prependDictionaryNames
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'anki_mappings';
  @override
  VerificationContext validateIntegrity(Insertable<AnkiMappingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('label')) {
      context.handle(
          _labelMeta, label.isAcceptableOrUnknown(data['label']!, _labelMeta));
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
          _modelMeta, model.isAcceptableOrUnknown(data['model']!, _modelMeta));
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('export_field_keys_json')) {
      context.handle(
          _exportFieldKeysJsonMeta,
          exportFieldKeysJson.isAcceptableOrUnknown(
              data['export_field_keys_json']!, _exportFieldKeysJsonMeta));
    } else if (isInserting) {
      context.missing(_exportFieldKeysJsonMeta);
    }
    if (data.containsKey('creator_field_keys_json')) {
      context.handle(
          _creatorFieldKeysJsonMeta,
          creatorFieldKeysJson.isAcceptableOrUnknown(
              data['creator_field_keys_json']!, _creatorFieldKeysJsonMeta));
    } else if (isInserting) {
      context.missing(_creatorFieldKeysJsonMeta);
    }
    if (data.containsKey('creator_collapsed_field_keys_json')) {
      context.handle(
          _creatorCollapsedFieldKeysJsonMeta,
          creatorCollapsedFieldKeysJson.isAcceptableOrUnknown(
              data['creator_collapsed_field_keys_json']!,
              _creatorCollapsedFieldKeysJsonMeta));
    } else if (isInserting) {
      context.missing(_creatorCollapsedFieldKeysJsonMeta);
    }
    if (data.containsKey('order')) {
      context.handle(
          _orderMeta, order.isAcceptableOrUnknown(data['order']!, _orderMeta));
    } else if (isInserting) {
      context.missing(_orderMeta);
    }
    if (data.containsKey('tags_json')) {
      context.handle(_tagsJsonMeta,
          tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta));
    } else if (isInserting) {
      context.missing(_tagsJsonMeta);
    }
    if (data.containsKey('enhancements_json')) {
      context.handle(
          _enhancementsJsonMeta,
          enhancementsJson.isAcceptableOrUnknown(
              data['enhancements_json']!, _enhancementsJsonMeta));
    } else if (isInserting) {
      context.missing(_enhancementsJsonMeta);
    }
    if (data.containsKey('actions_json')) {
      context.handle(
          _actionsJsonMeta,
          actionsJson.isAcceptableOrUnknown(
              data['actions_json']!, _actionsJsonMeta));
    } else if (isInserting) {
      context.missing(_actionsJsonMeta);
    }
    if (data.containsKey('export_media_tags')) {
      context.handle(
          _exportMediaTagsMeta,
          exportMediaTags.isAcceptableOrUnknown(
              data['export_media_tags']!, _exportMediaTagsMeta));
    }
    if (data.containsKey('use_br_tags')) {
      context.handle(
          _useBrTagsMeta,
          useBrTags.isAcceptableOrUnknown(
              data['use_br_tags']!, _useBrTagsMeta));
    }
    if (data.containsKey('prepend_dictionary_names')) {
      context.handle(
          _prependDictionaryNamesMeta,
          prependDictionaryNames.isAcceptableOrUnknown(
              data['prepend_dictionary_names']!, _prependDictionaryNamesMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AnkiMappingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AnkiMappingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      label: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}label'])!,
      model: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model'])!,
      exportFieldKeysJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}export_field_keys_json'])!,
      creatorFieldKeysJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}creator_field_keys_json'])!,
      creatorCollapsedFieldKeysJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}creator_collapsed_field_keys_json'])!,
      order: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}order'])!,
      tagsJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tags_json'])!,
      enhancementsJson: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}enhancements_json'])!,
      actionsJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}actions_json'])!,
      exportMediaTags: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}export_media_tags'])!,
      useBrTags: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}use_br_tags'])!,
      prependDictionaryNames: attachedDatabase.typeMapping.read(
          DriftSqlType.bool,
          data['${effectivePrefix}prepend_dictionary_names'])!,
    );
  }

  @override
  $AnkiMappingsTable createAlias(String alias) {
    return $AnkiMappingsTable(attachedDatabase, alias);
  }
}

class AnkiMappingRow extends DataClass implements Insertable<AnkiMappingRow> {
  final int id;
  final String label;
  final String model;
  final String exportFieldKeysJson;
  final String creatorFieldKeysJson;
  final String creatorCollapsedFieldKeysJson;
  final int order;
  final String tagsJson;
  final String enhancementsJson;
  final String actionsJson;
  final bool exportMediaTags;
  final bool useBrTags;
  final bool prependDictionaryNames;
  const AnkiMappingRow(
      {required this.id,
      required this.label,
      required this.model,
      required this.exportFieldKeysJson,
      required this.creatorFieldKeysJson,
      required this.creatorCollapsedFieldKeysJson,
      required this.order,
      required this.tagsJson,
      required this.enhancementsJson,
      required this.actionsJson,
      required this.exportMediaTags,
      required this.useBrTags,
      required this.prependDictionaryNames});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['label'] = Variable<String>(label);
    map['model'] = Variable<String>(model);
    map['export_field_keys_json'] = Variable<String>(exportFieldKeysJson);
    map['creator_field_keys_json'] = Variable<String>(creatorFieldKeysJson);
    map['creator_collapsed_field_keys_json'] =
        Variable<String>(creatorCollapsedFieldKeysJson);
    map['order'] = Variable<int>(order);
    map['tags_json'] = Variable<String>(tagsJson);
    map['enhancements_json'] = Variable<String>(enhancementsJson);
    map['actions_json'] = Variable<String>(actionsJson);
    map['export_media_tags'] = Variable<bool>(exportMediaTags);
    map['use_br_tags'] = Variable<bool>(useBrTags);
    map['prepend_dictionary_names'] = Variable<bool>(prependDictionaryNames);
    return map;
  }

  AnkiMappingsCompanion toCompanion(bool nullToAbsent) {
    return AnkiMappingsCompanion(
      id: Value(id),
      label: Value(label),
      model: Value(model),
      exportFieldKeysJson: Value(exportFieldKeysJson),
      creatorFieldKeysJson: Value(creatorFieldKeysJson),
      creatorCollapsedFieldKeysJson: Value(creatorCollapsedFieldKeysJson),
      order: Value(order),
      tagsJson: Value(tagsJson),
      enhancementsJson: Value(enhancementsJson),
      actionsJson: Value(actionsJson),
      exportMediaTags: Value(exportMediaTags),
      useBrTags: Value(useBrTags),
      prependDictionaryNames: Value(prependDictionaryNames),
    );
  }

  factory AnkiMappingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AnkiMappingRow(
      id: serializer.fromJson<int>(json['id']),
      label: serializer.fromJson<String>(json['label']),
      model: serializer.fromJson<String>(json['model']),
      exportFieldKeysJson:
          serializer.fromJson<String>(json['exportFieldKeysJson']),
      creatorFieldKeysJson:
          serializer.fromJson<String>(json['creatorFieldKeysJson']),
      creatorCollapsedFieldKeysJson:
          serializer.fromJson<String>(json['creatorCollapsedFieldKeysJson']),
      order: serializer.fromJson<int>(json['order']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      enhancementsJson: serializer.fromJson<String>(json['enhancementsJson']),
      actionsJson: serializer.fromJson<String>(json['actionsJson']),
      exportMediaTags: serializer.fromJson<bool>(json['exportMediaTags']),
      useBrTags: serializer.fromJson<bool>(json['useBrTags']),
      prependDictionaryNames:
          serializer.fromJson<bool>(json['prependDictionaryNames']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'label': serializer.toJson<String>(label),
      'model': serializer.toJson<String>(model),
      'exportFieldKeysJson': serializer.toJson<String>(exportFieldKeysJson),
      'creatorFieldKeysJson': serializer.toJson<String>(creatorFieldKeysJson),
      'creatorCollapsedFieldKeysJson':
          serializer.toJson<String>(creatorCollapsedFieldKeysJson),
      'order': serializer.toJson<int>(order),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'enhancementsJson': serializer.toJson<String>(enhancementsJson),
      'actionsJson': serializer.toJson<String>(actionsJson),
      'exportMediaTags': serializer.toJson<bool>(exportMediaTags),
      'useBrTags': serializer.toJson<bool>(useBrTags),
      'prependDictionaryNames': serializer.toJson<bool>(prependDictionaryNames),
    };
  }

  AnkiMappingRow copyWith(
          {int? id,
          String? label,
          String? model,
          String? exportFieldKeysJson,
          String? creatorFieldKeysJson,
          String? creatorCollapsedFieldKeysJson,
          int? order,
          String? tagsJson,
          String? enhancementsJson,
          String? actionsJson,
          bool? exportMediaTags,
          bool? useBrTags,
          bool? prependDictionaryNames}) =>
      AnkiMappingRow(
        id: id ?? this.id,
        label: label ?? this.label,
        model: model ?? this.model,
        exportFieldKeysJson: exportFieldKeysJson ?? this.exportFieldKeysJson,
        creatorFieldKeysJson: creatorFieldKeysJson ?? this.creatorFieldKeysJson,
        creatorCollapsedFieldKeysJson:
            creatorCollapsedFieldKeysJson ?? this.creatorCollapsedFieldKeysJson,
        order: order ?? this.order,
        tagsJson: tagsJson ?? this.tagsJson,
        enhancementsJson: enhancementsJson ?? this.enhancementsJson,
        actionsJson: actionsJson ?? this.actionsJson,
        exportMediaTags: exportMediaTags ?? this.exportMediaTags,
        useBrTags: useBrTags ?? this.useBrTags,
        prependDictionaryNames:
            prependDictionaryNames ?? this.prependDictionaryNames,
      );
  AnkiMappingRow copyWithCompanion(AnkiMappingsCompanion data) {
    return AnkiMappingRow(
      id: data.id.present ? data.id.value : this.id,
      label: data.label.present ? data.label.value : this.label,
      model: data.model.present ? data.model.value : this.model,
      exportFieldKeysJson: data.exportFieldKeysJson.present
          ? data.exportFieldKeysJson.value
          : this.exportFieldKeysJson,
      creatorFieldKeysJson: data.creatorFieldKeysJson.present
          ? data.creatorFieldKeysJson.value
          : this.creatorFieldKeysJson,
      creatorCollapsedFieldKeysJson: data.creatorCollapsedFieldKeysJson.present
          ? data.creatorCollapsedFieldKeysJson.value
          : this.creatorCollapsedFieldKeysJson,
      order: data.order.present ? data.order.value : this.order,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      enhancementsJson: data.enhancementsJson.present
          ? data.enhancementsJson.value
          : this.enhancementsJson,
      actionsJson:
          data.actionsJson.present ? data.actionsJson.value : this.actionsJson,
      exportMediaTags: data.exportMediaTags.present
          ? data.exportMediaTags.value
          : this.exportMediaTags,
      useBrTags: data.useBrTags.present ? data.useBrTags.value : this.useBrTags,
      prependDictionaryNames: data.prependDictionaryNames.present
          ? data.prependDictionaryNames.value
          : this.prependDictionaryNames,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AnkiMappingRow(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('model: $model, ')
          ..write('exportFieldKeysJson: $exportFieldKeysJson, ')
          ..write('creatorFieldKeysJson: $creatorFieldKeysJson, ')
          ..write(
              'creatorCollapsedFieldKeysJson: $creatorCollapsedFieldKeysJson, ')
          ..write('order: $order, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('enhancementsJson: $enhancementsJson, ')
          ..write('actionsJson: $actionsJson, ')
          ..write('exportMediaTags: $exportMediaTags, ')
          ..write('useBrTags: $useBrTags, ')
          ..write('prependDictionaryNames: $prependDictionaryNames')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      label,
      model,
      exportFieldKeysJson,
      creatorFieldKeysJson,
      creatorCollapsedFieldKeysJson,
      order,
      tagsJson,
      enhancementsJson,
      actionsJson,
      exportMediaTags,
      useBrTags,
      prependDictionaryNames);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnkiMappingRow &&
          other.id == this.id &&
          other.label == this.label &&
          other.model == this.model &&
          other.exportFieldKeysJson == this.exportFieldKeysJson &&
          other.creatorFieldKeysJson == this.creatorFieldKeysJson &&
          other.creatorCollapsedFieldKeysJson ==
              this.creatorCollapsedFieldKeysJson &&
          other.order == this.order &&
          other.tagsJson == this.tagsJson &&
          other.enhancementsJson == this.enhancementsJson &&
          other.actionsJson == this.actionsJson &&
          other.exportMediaTags == this.exportMediaTags &&
          other.useBrTags == this.useBrTags &&
          other.prependDictionaryNames == this.prependDictionaryNames);
}

class AnkiMappingsCompanion extends UpdateCompanion<AnkiMappingRow> {
  final Value<int> id;
  final Value<String> label;
  final Value<String> model;
  final Value<String> exportFieldKeysJson;
  final Value<String> creatorFieldKeysJson;
  final Value<String> creatorCollapsedFieldKeysJson;
  final Value<int> order;
  final Value<String> tagsJson;
  final Value<String> enhancementsJson;
  final Value<String> actionsJson;
  final Value<bool> exportMediaTags;
  final Value<bool> useBrTags;
  final Value<bool> prependDictionaryNames;
  const AnkiMappingsCompanion({
    this.id = const Value.absent(),
    this.label = const Value.absent(),
    this.model = const Value.absent(),
    this.exportFieldKeysJson = const Value.absent(),
    this.creatorFieldKeysJson = const Value.absent(),
    this.creatorCollapsedFieldKeysJson = const Value.absent(),
    this.order = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.enhancementsJson = const Value.absent(),
    this.actionsJson = const Value.absent(),
    this.exportMediaTags = const Value.absent(),
    this.useBrTags = const Value.absent(),
    this.prependDictionaryNames = const Value.absent(),
  });
  AnkiMappingsCompanion.insert({
    this.id = const Value.absent(),
    required String label,
    required String model,
    required String exportFieldKeysJson,
    required String creatorFieldKeysJson,
    required String creatorCollapsedFieldKeysJson,
    required int order,
    required String tagsJson,
    required String enhancementsJson,
    required String actionsJson,
    this.exportMediaTags = const Value.absent(),
    this.useBrTags = const Value.absent(),
    this.prependDictionaryNames = const Value.absent(),
  })  : label = Value(label),
        model = Value(model),
        exportFieldKeysJson = Value(exportFieldKeysJson),
        creatorFieldKeysJson = Value(creatorFieldKeysJson),
        creatorCollapsedFieldKeysJson = Value(creatorCollapsedFieldKeysJson),
        order = Value(order),
        tagsJson = Value(tagsJson),
        enhancementsJson = Value(enhancementsJson),
        actionsJson = Value(actionsJson);
  static Insertable<AnkiMappingRow> custom({
    Expression<int>? id,
    Expression<String>? label,
    Expression<String>? model,
    Expression<String>? exportFieldKeysJson,
    Expression<String>? creatorFieldKeysJson,
    Expression<String>? creatorCollapsedFieldKeysJson,
    Expression<int>? order,
    Expression<String>? tagsJson,
    Expression<String>? enhancementsJson,
    Expression<String>? actionsJson,
    Expression<bool>? exportMediaTags,
    Expression<bool>? useBrTags,
    Expression<bool>? prependDictionaryNames,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (label != null) 'label': label,
      if (model != null) 'model': model,
      if (exportFieldKeysJson != null)
        'export_field_keys_json': exportFieldKeysJson,
      if (creatorFieldKeysJson != null)
        'creator_field_keys_json': creatorFieldKeysJson,
      if (creatorCollapsedFieldKeysJson != null)
        'creator_collapsed_field_keys_json': creatorCollapsedFieldKeysJson,
      if (order != null) 'order': order,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (enhancementsJson != null) 'enhancements_json': enhancementsJson,
      if (actionsJson != null) 'actions_json': actionsJson,
      if (exportMediaTags != null) 'export_media_tags': exportMediaTags,
      if (useBrTags != null) 'use_br_tags': useBrTags,
      if (prependDictionaryNames != null)
        'prepend_dictionary_names': prependDictionaryNames,
    });
  }

  AnkiMappingsCompanion copyWith(
      {Value<int>? id,
      Value<String>? label,
      Value<String>? model,
      Value<String>? exportFieldKeysJson,
      Value<String>? creatorFieldKeysJson,
      Value<String>? creatorCollapsedFieldKeysJson,
      Value<int>? order,
      Value<String>? tagsJson,
      Value<String>? enhancementsJson,
      Value<String>? actionsJson,
      Value<bool>? exportMediaTags,
      Value<bool>? useBrTags,
      Value<bool>? prependDictionaryNames}) {
    return AnkiMappingsCompanion(
      id: id ?? this.id,
      label: label ?? this.label,
      model: model ?? this.model,
      exportFieldKeysJson: exportFieldKeysJson ?? this.exportFieldKeysJson,
      creatorFieldKeysJson: creatorFieldKeysJson ?? this.creatorFieldKeysJson,
      creatorCollapsedFieldKeysJson:
          creatorCollapsedFieldKeysJson ?? this.creatorCollapsedFieldKeysJson,
      order: order ?? this.order,
      tagsJson: tagsJson ?? this.tagsJson,
      enhancementsJson: enhancementsJson ?? this.enhancementsJson,
      actionsJson: actionsJson ?? this.actionsJson,
      exportMediaTags: exportMediaTags ?? this.exportMediaTags,
      useBrTags: useBrTags ?? this.useBrTags,
      prependDictionaryNames:
          prependDictionaryNames ?? this.prependDictionaryNames,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (exportFieldKeysJson.present) {
      map['export_field_keys_json'] =
          Variable<String>(exportFieldKeysJson.value);
    }
    if (creatorFieldKeysJson.present) {
      map['creator_field_keys_json'] =
          Variable<String>(creatorFieldKeysJson.value);
    }
    if (creatorCollapsedFieldKeysJson.present) {
      map['creator_collapsed_field_keys_json'] =
          Variable<String>(creatorCollapsedFieldKeysJson.value);
    }
    if (order.present) {
      map['order'] = Variable<int>(order.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (enhancementsJson.present) {
      map['enhancements_json'] = Variable<String>(enhancementsJson.value);
    }
    if (actionsJson.present) {
      map['actions_json'] = Variable<String>(actionsJson.value);
    }
    if (exportMediaTags.present) {
      map['export_media_tags'] = Variable<bool>(exportMediaTags.value);
    }
    if (useBrTags.present) {
      map['use_br_tags'] = Variable<bool>(useBrTags.value);
    }
    if (prependDictionaryNames.present) {
      map['prepend_dictionary_names'] =
          Variable<bool>(prependDictionaryNames.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AnkiMappingsCompanion(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('model: $model, ')
          ..write('exportFieldKeysJson: $exportFieldKeysJson, ')
          ..write('creatorFieldKeysJson: $creatorFieldKeysJson, ')
          ..write(
              'creatorCollapsedFieldKeysJson: $creatorCollapsedFieldKeysJson, ')
          ..write('order: $order, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('enhancementsJson: $enhancementsJson, ')
          ..write('actionsJson: $actionsJson, ')
          ..write('exportMediaTags: $exportMediaTags, ')
          ..write('useBrTags: $useBrTags, ')
          ..write('prependDictionaryNames: $prependDictionaryNames')
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
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
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
        bookKey,
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
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
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
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
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
  final String bookKey;
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
      required this.bookKey,
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
    map['book_key'] = Variable<String>(bookKey);
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
      bookKey: Value(bookKey),
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
      bookKey: serializer.fromJson<String>(json['bookKey']),
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
      'bookKey': serializer.toJson<String>(bookKey),
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
          String? bookKey,
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
        bookKey: bookKey ?? this.bookKey,
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
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
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
          ..write('bookKey: $bookKey, ')
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
      bookKey,
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
          other.bookKey == this.bookKey &&
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
  final Value<String> bookKey;
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
    this.bookKey = const Value.absent(),
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
    required String bookKey,
    this.audioRoot = const Value.absent(),
    this.audioPathsJson = const Value.absent(),
    required String alignmentFormat,
    required String alignmentPath,
    this.healthKindRaw = const Value.absent(),
    this.matchRatePct = const Value.absent(),
    this.healthMeasuredAt = const Value.absent(),
    this.healthReason = const Value.absent(),
    this.followAudio = const Value.absent(),
  })  : bookKey = Value(bookKey),
        alignmentFormat = Value(alignmentFormat),
        alignmentPath = Value(alignmentPath);
  static Insertable<AudiobookRow> custom({
    Expression<int>? id,
    Expression<String>? bookKey,
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
      if (bookKey != null) 'book_key': bookKey,
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
      Value<String>? bookKey,
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
      bookKey: bookKey ?? this.bookKey,
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
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
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
          ..write('bookKey: $bookKey, ')
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
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
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
        bookKey,
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
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
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
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
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
  final String bookKey;
  final String chapterHref;
  final int sentenceIndex;
  final String textFragmentId;
  final String cueText;
  final int startMs;
  final int endMs;
  final int audioFileIndex;
  const AudioCueRow(
      {required this.id,
      required this.bookKey,
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
    map['book_key'] = Variable<String>(bookKey);
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
      bookKey: Value(bookKey),
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
      bookKey: serializer.fromJson<String>(json['bookKey']),
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
      'bookKey': serializer.toJson<String>(bookKey),
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
          String? bookKey,
          String? chapterHref,
          int? sentenceIndex,
          String? textFragmentId,
          String? cueText,
          int? startMs,
          int? endMs,
          int? audioFileIndex}) =>
      AudioCueRow(
        id: id ?? this.id,
        bookKey: bookKey ?? this.bookKey,
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
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
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
          ..write('bookKey: $bookKey, ')
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
  int get hashCode => Object.hash(id, bookKey, chapterHref, sentenceIndex,
      textFragmentId, cueText, startMs, endMs, audioFileIndex);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioCueRow &&
          other.id == this.id &&
          other.bookKey == this.bookKey &&
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
  final Value<String> bookKey;
  final Value<String> chapterHref;
  final Value<int> sentenceIndex;
  final Value<String> textFragmentId;
  final Value<String> cueText;
  final Value<int> startMs;
  final Value<int> endMs;
  final Value<int> audioFileIndex;
  const AudioCuesCompanion({
    this.id = const Value.absent(),
    this.bookKey = const Value.absent(),
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
    required String bookKey,
    required String chapterHref,
    required int sentenceIndex,
    required String textFragmentId,
    required String cueText,
    required int startMs,
    required int endMs,
    required int audioFileIndex,
  })  : bookKey = Value(bookKey),
        chapterHref = Value(chapterHref),
        sentenceIndex = Value(sentenceIndex),
        textFragmentId = Value(textFragmentId),
        cueText = Value(cueText),
        startMs = Value(startMs),
        endMs = Value(endMs),
        audioFileIndex = Value(audioFileIndex);
  static Insertable<AudioCueRow> custom({
    Expression<int>? id,
    Expression<String>? bookKey,
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
      if (bookKey != null) 'book_key': bookKey,
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
      Value<String>? bookKey,
      Value<String>? chapterHref,
      Value<int>? sentenceIndex,
      Value<String>? textFragmentId,
      Value<String>? cueText,
      Value<int>? startMs,
      Value<int>? endMs,
      Value<int>? audioFileIndex}) {
    return AudioCuesCompanion(
      id: id ?? this.id,
      bookKey: bookKey ?? this.bookKey,
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
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
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
          ..write('bookKey: $bookKey, ')
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
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
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
        bookKey
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
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
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
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
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
  final String bookKey;
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
      required this.bookKey});
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
    map['book_key'] = Variable<String>(bookKey);
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
      bookKey: Value(bookKey),
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
      bookKey: serializer.fromJson<String>(json['bookKey']),
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
      'bookKey': serializer.toJson<String>(bookKey),
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
          String? bookKey}) =>
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
        bookKey: bookKey ?? this.bookKey,
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
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
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
          ..write('bookKey: $bookKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uid, title, author, audioRoot,
      audioPathsJson, srtPath, coverPath, importedAt, bookKey);
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
          other.bookKey == this.bookKey);
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
  final Value<String> bookKey;
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
    this.bookKey = const Value.absent(),
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
    this.bookKey = const Value.absent(),
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
    Expression<String>? bookKey,
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
      if (bookKey != null) 'book_key': bookKey,
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
      Value<String>? bookKey}) {
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
      bookKey: bookKey ?? this.bookKey,
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
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
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
          ..write('bookKey: $bookKey')
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
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
      type: DriftSqlType.string,
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
  static const VerificationMeta _charOffsetMeta =
      const VerificationMeta('charOffset');
  @override
  late final GeneratedColumn<int> charOffset = GeneratedColumn<int>(
      'char_offset', aliasedName, false,
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
      [id, bookKey, sectionIndex, normCharOffset, charOffset, updatedAt];
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
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
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
    if (data.containsKey('char_offset')) {
      context.handle(
          _charOffsetMeta,
          charOffset.isAcceptableOrUnknown(
              data['char_offset']!, _charOffsetMeta));
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
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
      sectionIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}section_index'])!,
      normCharOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}norm_char_offset'])!,
      charOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}char_offset'])!,
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
  final String bookKey;
  final int sectionIndex;
  final int normCharOffset;
  final int charOffset;
  final int updatedAt;
  const ReaderPositionRow(
      {required this.id,
      required this.bookKey,
      required this.sectionIndex,
      required this.normCharOffset,
      required this.charOffset,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_key'] = Variable<String>(bookKey);
    map['section_index'] = Variable<int>(sectionIndex);
    map['norm_char_offset'] = Variable<int>(normCharOffset);
    map['char_offset'] = Variable<int>(charOffset);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ReaderPositionsCompanion toCompanion(bool nullToAbsent) {
    return ReaderPositionsCompanion(
      id: Value(id),
      bookKey: Value(bookKey),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      charOffset: Value(charOffset),
      updatedAt: Value(updatedAt),
    );
  }

  factory ReaderPositionRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReaderPositionRow(
      id: serializer.fromJson<int>(json['id']),
      bookKey: serializer.fromJson<String>(json['bookKey']),
      sectionIndex: serializer.fromJson<int>(json['sectionIndex']),
      normCharOffset: serializer.fromJson<int>(json['normCharOffset']),
      charOffset: serializer.fromJson<int>(json['charOffset']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookKey': serializer.toJson<String>(bookKey),
      'sectionIndex': serializer.toJson<int>(sectionIndex),
      'normCharOffset': serializer.toJson<int>(normCharOffset),
      'charOffset': serializer.toJson<int>(charOffset),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  ReaderPositionRow copyWith(
          {int? id,
          String? bookKey,
          int? sectionIndex,
          int? normCharOffset,
          int? charOffset,
          int? updatedAt}) =>
      ReaderPositionRow(
        id: id ?? this.id,
        bookKey: bookKey ?? this.bookKey,
        sectionIndex: sectionIndex ?? this.sectionIndex,
        normCharOffset: normCharOffset ?? this.normCharOffset,
        charOffset: charOffset ?? this.charOffset,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  ReaderPositionRow copyWithCompanion(ReaderPositionsCompanion data) {
    return ReaderPositionRow(
      id: data.id.present ? data.id.value : this.id,
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      sectionIndex: data.sectionIndex.present
          ? data.sectionIndex.value
          : this.sectionIndex,
      normCharOffset: data.normCharOffset.present
          ? data.normCharOffset.value
          : this.normCharOffset,
      charOffset:
          data.charOffset.present ? data.charOffset.value : this.charOffset,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReaderPositionRow(')
          ..write('id: $id, ')
          ..write('bookKey: $bookKey, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('charOffset: $charOffset, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, bookKey, sectionIndex, normCharOffset, charOffset, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReaderPositionRow &&
          other.id == this.id &&
          other.bookKey == this.bookKey &&
          other.sectionIndex == this.sectionIndex &&
          other.normCharOffset == this.normCharOffset &&
          other.charOffset == this.charOffset &&
          other.updatedAt == this.updatedAt);
}

class ReaderPositionsCompanion extends UpdateCompanion<ReaderPositionRow> {
  final Value<int> id;
  final Value<String> bookKey;
  final Value<int> sectionIndex;
  final Value<int> normCharOffset;
  final Value<int> charOffset;
  final Value<int> updatedAt;
  const ReaderPositionsCompanion({
    this.id = const Value.absent(),
    this.bookKey = const Value.absent(),
    this.sectionIndex = const Value.absent(),
    this.normCharOffset = const Value.absent(),
    this.charOffset = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ReaderPositionsCompanion.insert({
    this.id = const Value.absent(),
    required String bookKey,
    required int sectionIndex,
    required int normCharOffset,
    this.charOffset = const Value.absent(),
    required int updatedAt,
  })  : bookKey = Value(bookKey),
        sectionIndex = Value(sectionIndex),
        normCharOffset = Value(normCharOffset),
        updatedAt = Value(updatedAt);
  static Insertable<ReaderPositionRow> custom({
    Expression<int>? id,
    Expression<String>? bookKey,
    Expression<int>? sectionIndex,
    Expression<int>? normCharOffset,
    Expression<int>? charOffset,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookKey != null) 'book_key': bookKey,
      if (sectionIndex != null) 'section_index': sectionIndex,
      if (normCharOffset != null) 'norm_char_offset': normCharOffset,
      if (charOffset != null) 'char_offset': charOffset,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ReaderPositionsCompanion copyWith(
      {Value<int>? id,
      Value<String>? bookKey,
      Value<int>? sectionIndex,
      Value<int>? normCharOffset,
      Value<int>? charOffset,
      Value<int>? updatedAt}) {
    return ReaderPositionsCompanion(
      id: id ?? this.id,
      bookKey: bookKey ?? this.bookKey,
      sectionIndex: sectionIndex ?? this.sectionIndex,
      normCharOffset: normCharOffset ?? this.normCharOffset,
      charOffset: charOffset ?? this.charOffset,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
    }
    if (sectionIndex.present) {
      map['section_index'] = Variable<int>(sectionIndex.value);
    }
    if (normCharOffset.present) {
      map['norm_char_offset'] = Variable<int>(normCharOffset.value);
    }
    if (charOffset.present) {
      map['char_offset'] = Variable<int>(charOffset.value);
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
          ..write('bookKey: $bookKey, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('charOffset: $charOffset, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $MediaSourcesTable extends MediaSources
    with TableInfo<$MediaSourcesTable, MediaSourceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaSourcesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
      'label', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _mediaKindMeta =
      const VerificationMeta('mediaKind');
  @override
  late final GeneratedColumn<String> mediaKind = GeneratedColumn<String>(
      'media_kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _transportMeta =
      const VerificationMeta('transport');
  @override
  late final GeneratedColumn<String> transport = GeneratedColumn<String>(
      'transport', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('local'));
  static const VerificationMeta _rootPathMeta =
      const VerificationMeta('rootPath');
  @override
  late final GeneratedColumn<String> rootPath = GeneratedColumn<String>(
      'root_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _configJsonMeta =
      const VerificationMeta('configJson');
  @override
  late final GeneratedColumn<String> configJson = GeneratedColumn<String>(
      'config_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _mediaCountMeta =
      const VerificationMeta('mediaCount');
  @override
  late final GeneratedColumn<int> mediaCount = GeneratedColumn<int>(
      'media_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastScannedAtMeta =
      const VerificationMeta('lastScannedAt');
  @override
  late final GeneratedColumn<DateTime> lastScannedAt =
      GeneratedColumn<DateTime>('last_scanned_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _lastScanErrorMeta =
      const VerificationMeta('lastScanError');
  @override
  late final GeneratedColumn<String> lastScanError = GeneratedColumn<String>(
      'last_scan_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _recursiveMeta =
      const VerificationMeta('recursive');
  @override
  late final GeneratedColumn<bool> recursive = GeneratedColumn<bool>(
      'recursive', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("recursive" IN (0, 1))'),
      defaultValue: const Constant(true));
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
  List<GeneratedColumn> get $columns => [
        id,
        label,
        mediaKind,
        transport,
        rootPath,
        configJson,
        mediaCount,
        lastScannedAt,
        lastScanError,
        recursive,
        sortOrder,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_sources';
  @override
  VerificationContext validateIntegrity(Insertable<MediaSourceRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('label')) {
      context.handle(
          _labelMeta, label.isAcceptableOrUnknown(data['label']!, _labelMeta));
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('media_kind')) {
      context.handle(_mediaKindMeta,
          mediaKind.isAcceptableOrUnknown(data['media_kind']!, _mediaKindMeta));
    } else if (isInserting) {
      context.missing(_mediaKindMeta);
    }
    if (data.containsKey('transport')) {
      context.handle(_transportMeta,
          transport.isAcceptableOrUnknown(data['transport']!, _transportMeta));
    }
    if (data.containsKey('root_path')) {
      context.handle(_rootPathMeta,
          rootPath.isAcceptableOrUnknown(data['root_path']!, _rootPathMeta));
    } else if (isInserting) {
      context.missing(_rootPathMeta);
    }
    if (data.containsKey('config_json')) {
      context.handle(
          _configJsonMeta,
          configJson.isAcceptableOrUnknown(
              data['config_json']!, _configJsonMeta));
    }
    if (data.containsKey('media_count')) {
      context.handle(
          _mediaCountMeta,
          mediaCount.isAcceptableOrUnknown(
              data['media_count']!, _mediaCountMeta));
    }
    if (data.containsKey('last_scanned_at')) {
      context.handle(
          _lastScannedAtMeta,
          lastScannedAt.isAcceptableOrUnknown(
              data['last_scanned_at']!, _lastScannedAtMeta));
    }
    if (data.containsKey('last_scan_error')) {
      context.handle(
          _lastScanErrorMeta,
          lastScanError.isAcceptableOrUnknown(
              data['last_scan_error']!, _lastScanErrorMeta));
    }
    if (data.containsKey('recursive')) {
      context.handle(_recursiveMeta,
          recursive.isAcceptableOrUnknown(data['recursive']!, _recursiveMeta));
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MediaSourceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaSourceRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      label: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}label'])!,
      mediaKind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}media_kind'])!,
      transport: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}transport'])!,
      rootPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}root_path'])!,
      configJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}config_json']),
      mediaCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}media_count'])!,
      lastScannedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}last_scanned_at']),
      lastScanError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_scan_error']),
      recursive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}recursive'])!,
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MediaSourcesTable createAlias(String alias) {
    return $MediaSourcesTable(attachedDatabase, alias);
  }
}

class MediaSourceRow extends DataClass implements Insertable<MediaSourceRow> {
  final int id;

  /// 显示名，默认取 rootPath 末段文件夹名。
  final String label;

  /// 媒体种类：'video' | 'book'。同一文件夹可分别建 video / book 两条来源，
  /// 故不对 rootPath 加 UNIQUE。
  final String mediaKind;

  /// 传输方式：'local' | 'sftp' | 'ftp' | 'http'。M0 只写 'local'，
  /// 网络取值前瞻容纳（M3 才接入）。
  final String transport;

  /// 本地绝对路径或网络根（含 scheme）。
  final String rootPath;

  /// 凭据引用（键）/ 网络配置 JSON。**绝不裸存明文密码**；本地恒 NULL。
  final String? configJson;

  /// 截图「媒体数」：上次扫描产出的条目数。
  final int mediaCount;

  /// 截图「上次扫描时间」。
  final DateTime? lastScannedAt;

  /// 上次扫描失败原因（成功则 NULL）。
  final String? lastScanError;

  /// 是否递归扫描子目录。
  final bool recursive;

  /// 列表排序权重（同 [BookTags].sortOrder 范式）。
  final int sortOrder;

  /// 创建时间（毫秒戳，同 [EpubBooks].importedAt int 范式）。
  final int createdAt;
  const MediaSourceRow(
      {required this.id,
      required this.label,
      required this.mediaKind,
      required this.transport,
      required this.rootPath,
      this.configJson,
      required this.mediaCount,
      this.lastScannedAt,
      this.lastScanError,
      required this.recursive,
      required this.sortOrder,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['label'] = Variable<String>(label);
    map['media_kind'] = Variable<String>(mediaKind);
    map['transport'] = Variable<String>(transport);
    map['root_path'] = Variable<String>(rootPath);
    if (!nullToAbsent || configJson != null) {
      map['config_json'] = Variable<String>(configJson);
    }
    map['media_count'] = Variable<int>(mediaCount);
    if (!nullToAbsent || lastScannedAt != null) {
      map['last_scanned_at'] = Variable<DateTime>(lastScannedAt);
    }
    if (!nullToAbsent || lastScanError != null) {
      map['last_scan_error'] = Variable<String>(lastScanError);
    }
    map['recursive'] = Variable<bool>(recursive);
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MediaSourcesCompanion toCompanion(bool nullToAbsent) {
    return MediaSourcesCompanion(
      id: Value(id),
      label: Value(label),
      mediaKind: Value(mediaKind),
      transport: Value(transport),
      rootPath: Value(rootPath),
      configJson: configJson == null && nullToAbsent
          ? const Value.absent()
          : Value(configJson),
      mediaCount: Value(mediaCount),
      lastScannedAt: lastScannedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastScannedAt),
      lastScanError: lastScanError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastScanError),
      recursive: Value(recursive),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
    );
  }

  factory MediaSourceRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaSourceRow(
      id: serializer.fromJson<int>(json['id']),
      label: serializer.fromJson<String>(json['label']),
      mediaKind: serializer.fromJson<String>(json['mediaKind']),
      transport: serializer.fromJson<String>(json['transport']),
      rootPath: serializer.fromJson<String>(json['rootPath']),
      configJson: serializer.fromJson<String?>(json['configJson']),
      mediaCount: serializer.fromJson<int>(json['mediaCount']),
      lastScannedAt: serializer.fromJson<DateTime?>(json['lastScannedAt']),
      lastScanError: serializer.fromJson<String?>(json['lastScanError']),
      recursive: serializer.fromJson<bool>(json['recursive']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'label': serializer.toJson<String>(label),
      'mediaKind': serializer.toJson<String>(mediaKind),
      'transport': serializer.toJson<String>(transport),
      'rootPath': serializer.toJson<String>(rootPath),
      'configJson': serializer.toJson<String?>(configJson),
      'mediaCount': serializer.toJson<int>(mediaCount),
      'lastScannedAt': serializer.toJson<DateTime?>(lastScannedAt),
      'lastScanError': serializer.toJson<String?>(lastScanError),
      'recursive': serializer.toJson<bool>(recursive),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  MediaSourceRow copyWith(
          {int? id,
          String? label,
          String? mediaKind,
          String? transport,
          String? rootPath,
          Value<String?> configJson = const Value.absent(),
          int? mediaCount,
          Value<DateTime?> lastScannedAt = const Value.absent(),
          Value<String?> lastScanError = const Value.absent(),
          bool? recursive,
          int? sortOrder,
          int? createdAt}) =>
      MediaSourceRow(
        id: id ?? this.id,
        label: label ?? this.label,
        mediaKind: mediaKind ?? this.mediaKind,
        transport: transport ?? this.transport,
        rootPath: rootPath ?? this.rootPath,
        configJson: configJson.present ? configJson.value : this.configJson,
        mediaCount: mediaCount ?? this.mediaCount,
        lastScannedAt:
            lastScannedAt.present ? lastScannedAt.value : this.lastScannedAt,
        lastScanError:
            lastScanError.present ? lastScanError.value : this.lastScanError,
        recursive: recursive ?? this.recursive,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
      );
  MediaSourceRow copyWithCompanion(MediaSourcesCompanion data) {
    return MediaSourceRow(
      id: data.id.present ? data.id.value : this.id,
      label: data.label.present ? data.label.value : this.label,
      mediaKind: data.mediaKind.present ? data.mediaKind.value : this.mediaKind,
      transport: data.transport.present ? data.transport.value : this.transport,
      rootPath: data.rootPath.present ? data.rootPath.value : this.rootPath,
      configJson:
          data.configJson.present ? data.configJson.value : this.configJson,
      mediaCount:
          data.mediaCount.present ? data.mediaCount.value : this.mediaCount,
      lastScannedAt: data.lastScannedAt.present
          ? data.lastScannedAt.value
          : this.lastScannedAt,
      lastScanError: data.lastScanError.present
          ? data.lastScanError.value
          : this.lastScanError,
      recursive: data.recursive.present ? data.recursive.value : this.recursive,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaSourceRow(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('mediaKind: $mediaKind, ')
          ..write('transport: $transport, ')
          ..write('rootPath: $rootPath, ')
          ..write('configJson: $configJson, ')
          ..write('mediaCount: $mediaCount, ')
          ..write('lastScannedAt: $lastScannedAt, ')
          ..write('lastScanError: $lastScanError, ')
          ..write('recursive: $recursive, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      label,
      mediaKind,
      transport,
      rootPath,
      configJson,
      mediaCount,
      lastScannedAt,
      lastScanError,
      recursive,
      sortOrder,
      createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaSourceRow &&
          other.id == this.id &&
          other.label == this.label &&
          other.mediaKind == this.mediaKind &&
          other.transport == this.transport &&
          other.rootPath == this.rootPath &&
          other.configJson == this.configJson &&
          other.mediaCount == this.mediaCount &&
          other.lastScannedAt == this.lastScannedAt &&
          other.lastScanError == this.lastScanError &&
          other.recursive == this.recursive &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt);
}

class MediaSourcesCompanion extends UpdateCompanion<MediaSourceRow> {
  final Value<int> id;
  final Value<String> label;
  final Value<String> mediaKind;
  final Value<String> transport;
  final Value<String> rootPath;
  final Value<String?> configJson;
  final Value<int> mediaCount;
  final Value<DateTime?> lastScannedAt;
  final Value<String?> lastScanError;
  final Value<bool> recursive;
  final Value<int> sortOrder;
  final Value<int> createdAt;
  const MediaSourcesCompanion({
    this.id = const Value.absent(),
    this.label = const Value.absent(),
    this.mediaKind = const Value.absent(),
    this.transport = const Value.absent(),
    this.rootPath = const Value.absent(),
    this.configJson = const Value.absent(),
    this.mediaCount = const Value.absent(),
    this.lastScannedAt = const Value.absent(),
    this.lastScanError = const Value.absent(),
    this.recursive = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  MediaSourcesCompanion.insert({
    this.id = const Value.absent(),
    required String label,
    required String mediaKind,
    this.transport = const Value.absent(),
    required String rootPath,
    this.configJson = const Value.absent(),
    this.mediaCount = const Value.absent(),
    this.lastScannedAt = const Value.absent(),
    this.lastScanError = const Value.absent(),
    this.recursive = const Value.absent(),
    this.sortOrder = const Value.absent(),
    required int createdAt,
  })  : label = Value(label),
        mediaKind = Value(mediaKind),
        rootPath = Value(rootPath),
        createdAt = Value(createdAt);
  static Insertable<MediaSourceRow> custom({
    Expression<int>? id,
    Expression<String>? label,
    Expression<String>? mediaKind,
    Expression<String>? transport,
    Expression<String>? rootPath,
    Expression<String>? configJson,
    Expression<int>? mediaCount,
    Expression<DateTime>? lastScannedAt,
    Expression<String>? lastScanError,
    Expression<bool>? recursive,
    Expression<int>? sortOrder,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (label != null) 'label': label,
      if (mediaKind != null) 'media_kind': mediaKind,
      if (transport != null) 'transport': transport,
      if (rootPath != null) 'root_path': rootPath,
      if (configJson != null) 'config_json': configJson,
      if (mediaCount != null) 'media_count': mediaCount,
      if (lastScannedAt != null) 'last_scanned_at': lastScannedAt,
      if (lastScanError != null) 'last_scan_error': lastScanError,
      if (recursive != null) 'recursive': recursive,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  MediaSourcesCompanion copyWith(
      {Value<int>? id,
      Value<String>? label,
      Value<String>? mediaKind,
      Value<String>? transport,
      Value<String>? rootPath,
      Value<String?>? configJson,
      Value<int>? mediaCount,
      Value<DateTime?>? lastScannedAt,
      Value<String?>? lastScanError,
      Value<bool>? recursive,
      Value<int>? sortOrder,
      Value<int>? createdAt}) {
    return MediaSourcesCompanion(
      id: id ?? this.id,
      label: label ?? this.label,
      mediaKind: mediaKind ?? this.mediaKind,
      transport: transport ?? this.transport,
      rootPath: rootPath ?? this.rootPath,
      configJson: configJson ?? this.configJson,
      mediaCount: mediaCount ?? this.mediaCount,
      lastScannedAt: lastScannedAt ?? this.lastScannedAt,
      lastScanError: lastScanError ?? this.lastScanError,
      recursive: recursive ?? this.recursive,
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
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (mediaKind.present) {
      map['media_kind'] = Variable<String>(mediaKind.value);
    }
    if (transport.present) {
      map['transport'] = Variable<String>(transport.value);
    }
    if (rootPath.present) {
      map['root_path'] = Variable<String>(rootPath.value);
    }
    if (configJson.present) {
      map['config_json'] = Variable<String>(configJson.value);
    }
    if (mediaCount.present) {
      map['media_count'] = Variable<int>(mediaCount.value);
    }
    if (lastScannedAt.present) {
      map['last_scanned_at'] = Variable<DateTime>(lastScannedAt.value);
    }
    if (lastScanError.present) {
      map['last_scan_error'] = Variable<String>(lastScanError.value);
    }
    if (recursive.present) {
      map['recursive'] = Variable<bool>(recursive.value);
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
    return (StringBuffer('MediaSourcesCompanion(')
          ..write('id: $id, ')
          ..write('label: $label, ')
          ..write('mediaKind: $mediaKind, ')
          ..write('transport: $transport, ')
          ..write('rootPath: $rootPath, ')
          ..write('configJson: $configJson, ')
          ..write('mediaCount: $mediaCount, ')
          ..write('lastScannedAt: $lastScannedAt, ')
          ..write('lastScanError: $lastScanError, ')
          ..write('recursive: $recursive, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
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
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
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
  static const VerificationMeta _sourceIdMeta =
      const VerificationMeta('sourceId');
  @override
  late final GeneratedColumn<int> sourceId = GeneratedColumn<int>(
      'source_id', aliasedName, true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES media_sources (id) ON DELETE SET NULL'));
  @override
  List<GeneratedColumn> get $columns => [
        bookKey,
        title,
        author,
        coverPath,
        epubPath,
        extractDir,
        chapterCount,
        chaptersJson,
        tocJson,
        sourceMetadata,
        importedAt,
        sourceId
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
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
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
    if (data.containsKey('source_id')) {
      context.handle(_sourceIdMeta,
          sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookKey};
  @override
  EpubBookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EpubBookRow(
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
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
      sourceId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}source_id']),
    );
  }

  @override
  $EpubBooksTable createAlias(String alias) {
    return $EpubBooksTable(attachedDatabase, alias);
  }
}

class EpubBookRow extends DataClass implements Insertable<EpubBookRow> {
  final String bookKey;
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

  /// TODO-817：归属的网络/本地来源库（[MediaSources].id）。可空 = 手动导入无来源。
  /// onDelete:setNull = 移除来源时保留书目（归 NULL），不连坐删条目。
  final int? sourceId;
  const EpubBookRow(
      {required this.bookKey,
      required this.title,
      this.author,
      this.coverPath,
      required this.epubPath,
      required this.extractDir,
      required this.chapterCount,
      required this.chaptersJson,
      this.tocJson,
      this.sourceMetadata,
      required this.importedAt,
      this.sourceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_key'] = Variable<String>(bookKey);
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
    if (!nullToAbsent || sourceId != null) {
      map['source_id'] = Variable<int>(sourceId);
    }
    return map;
  }

  EpubBooksCompanion toCompanion(bool nullToAbsent) {
    return EpubBooksCompanion(
      bookKey: Value(bookKey),
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
      sourceId: sourceId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceId),
    );
  }

  factory EpubBookRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EpubBookRow(
      bookKey: serializer.fromJson<String>(json['bookKey']),
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
      sourceId: serializer.fromJson<int?>(json['sourceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookKey': serializer.toJson<String>(bookKey),
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
      'sourceId': serializer.toJson<int?>(sourceId),
    };
  }

  EpubBookRow copyWith(
          {String? bookKey,
          String? title,
          Value<String?> author = const Value.absent(),
          Value<String?> coverPath = const Value.absent(),
          String? epubPath,
          String? extractDir,
          int? chapterCount,
          String? chaptersJson,
          Value<String?> tocJson = const Value.absent(),
          Value<String?> sourceMetadata = const Value.absent(),
          int? importedAt,
          Value<int?> sourceId = const Value.absent()}) =>
      EpubBookRow(
        bookKey: bookKey ?? this.bookKey,
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
        sourceId: sourceId.present ? sourceId.value : this.sourceId,
      );
  EpubBookRow copyWithCompanion(EpubBooksCompanion data) {
    return EpubBookRow(
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
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
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EpubBookRow(')
          ..write('bookKey: $bookKey, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('coverPath: $coverPath, ')
          ..write('epubPath: $epubPath, ')
          ..write('extractDir: $extractDir, ')
          ..write('chapterCount: $chapterCount, ')
          ..write('chaptersJson: $chaptersJson, ')
          ..write('tocJson: $tocJson, ')
          ..write('sourceMetadata: $sourceMetadata, ')
          ..write('importedAt: $importedAt, ')
          ..write('sourceId: $sourceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      bookKey,
      title,
      author,
      coverPath,
      epubPath,
      extractDir,
      chapterCount,
      chaptersJson,
      tocJson,
      sourceMetadata,
      importedAt,
      sourceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EpubBookRow &&
          other.bookKey == this.bookKey &&
          other.title == this.title &&
          other.author == this.author &&
          other.coverPath == this.coverPath &&
          other.epubPath == this.epubPath &&
          other.extractDir == this.extractDir &&
          other.chapterCount == this.chapterCount &&
          other.chaptersJson == this.chaptersJson &&
          other.tocJson == this.tocJson &&
          other.sourceMetadata == this.sourceMetadata &&
          other.importedAt == this.importedAt &&
          other.sourceId == this.sourceId);
}

class EpubBooksCompanion extends UpdateCompanion<EpubBookRow> {
  final Value<String> bookKey;
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
  final Value<int?> sourceId;
  final Value<int> rowid;
  const EpubBooksCompanion({
    this.bookKey = const Value.absent(),
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
    this.sourceId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EpubBooksCompanion.insert({
    required String bookKey,
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
    this.sourceId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : bookKey = Value(bookKey),
        title = Value(title),
        epubPath = Value(epubPath),
        extractDir = Value(extractDir),
        chapterCount = Value(chapterCount),
        chaptersJson = Value(chaptersJson),
        importedAt = Value(importedAt);
  static Insertable<EpubBookRow> custom({
    Expression<String>? bookKey,
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
    Expression<int>? sourceId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookKey != null) 'book_key': bookKey,
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
      if (sourceId != null) 'source_id': sourceId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EpubBooksCompanion copyWith(
      {Value<String>? bookKey,
      Value<String>? title,
      Value<String?>? author,
      Value<String?>? coverPath,
      Value<String>? epubPath,
      Value<String>? extractDir,
      Value<int>? chapterCount,
      Value<String>? chaptersJson,
      Value<String?>? tocJson,
      Value<String?>? sourceMetadata,
      Value<int>? importedAt,
      Value<int?>? sourceId,
      Value<int>? rowid}) {
    return EpubBooksCompanion(
      bookKey: bookKey ?? this.bookKey,
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
      sourceId: sourceId ?? this.sourceId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
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
    if (sourceId.present) {
      map['source_id'] = Variable<int>(sourceId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EpubBooksCompanion(')
          ..write('bookKey: $bookKey, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('coverPath: $coverPath, ')
          ..write('epubPath: $epubPath, ')
          ..write('extractDir: $extractDir, ')
          ..write('chapterCount: $chapterCount, ')
          ..write('chaptersJson: $chaptersJson, ')
          ..write('tocJson: $tocJson, ')
          ..write('sourceMetadata: $sourceMetadata, ')
          ..write('importedAt: $importedAt, ')
          ..write('sourceId: $sourceId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BookmarksTable extends Bookmarks
    with TableInfo<$BookmarksTable, BookmarkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookmarksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES epub_books (book_key) ON DELETE CASCADE'));
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
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
      'label', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _bookTitleMeta =
      const VerificationMeta('bookTitle');
  @override
  late final GeneratedColumn<String> bookTitle = GeneratedColumn<String>(
      'book_title', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _pageInChapterMeta =
      const VerificationMeta('pageInChapter');
  @override
  late final GeneratedColumn<int> pageInChapter = GeneratedColumn<int>(
      'page_in_chapter', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _totalPagesInChapterMeta =
      const VerificationMeta('totalPagesInChapter');
  @override
  late final GeneratedColumn<int> totalPagesInChapter = GeneratedColumn<int>(
      'total_pages_in_chapter', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        bookKey,
        sectionIndex,
        normCharOffset,
        label,
        createdAt,
        bookTitle,
        pageInChapter,
        totalPagesInChapter
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bookmarks';
  @override
  VerificationContext validateIntegrity(Insertable<BookmarkRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
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
    if (data.containsKey('label')) {
      context.handle(
          _labelMeta, label.isAcceptableOrUnknown(data['label']!, _labelMeta));
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('book_title')) {
      context.handle(_bookTitleMeta,
          bookTitle.isAcceptableOrUnknown(data['book_title']!, _bookTitleMeta));
    }
    if (data.containsKey('page_in_chapter')) {
      context.handle(
          _pageInChapterMeta,
          pageInChapter.isAcceptableOrUnknown(
              data['page_in_chapter']!, _pageInChapterMeta));
    }
    if (data.containsKey('total_pages_in_chapter')) {
      context.handle(
          _totalPagesInChapterMeta,
          totalPagesInChapter.isAcceptableOrUnknown(
              data['total_pages_in_chapter']!, _totalPagesInChapterMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BookmarkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookmarkRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
      sectionIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}section_index'])!,
      normCharOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}norm_char_offset'])!,
      label: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}label'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      bookTitle: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_title']),
      pageInChapter: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}page_in_chapter']),
      totalPagesInChapter: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}total_pages_in_chapter']),
    );
  }

  @override
  $BookmarksTable createAlias(String alias) {
    return $BookmarksTable(attachedDatabase, alias);
  }
}

class BookmarkRow extends DataClass implements Insertable<BookmarkRow> {
  final int id;
  final String bookKey;
  final int sectionIndex;
  final int normCharOffset;
  final String label;
  final int createdAt;
  final String? bookTitle;
  final int? pageInChapter;
  final int? totalPagesInChapter;
  const BookmarkRow(
      {required this.id,
      required this.bookKey,
      required this.sectionIndex,
      required this.normCharOffset,
      required this.label,
      required this.createdAt,
      this.bookTitle,
      this.pageInChapter,
      this.totalPagesInChapter});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_key'] = Variable<String>(bookKey);
    map['section_index'] = Variable<int>(sectionIndex);
    map['norm_char_offset'] = Variable<int>(normCharOffset);
    map['label'] = Variable<String>(label);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || bookTitle != null) {
      map['book_title'] = Variable<String>(bookTitle);
    }
    if (!nullToAbsent || pageInChapter != null) {
      map['page_in_chapter'] = Variable<int>(pageInChapter);
    }
    if (!nullToAbsent || totalPagesInChapter != null) {
      map['total_pages_in_chapter'] = Variable<int>(totalPagesInChapter);
    }
    return map;
  }

  BookmarksCompanion toCompanion(bool nullToAbsent) {
    return BookmarksCompanion(
      id: Value(id),
      bookKey: Value(bookKey),
      sectionIndex: Value(sectionIndex),
      normCharOffset: Value(normCharOffset),
      label: Value(label),
      createdAt: Value(createdAt),
      bookTitle: bookTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(bookTitle),
      pageInChapter: pageInChapter == null && nullToAbsent
          ? const Value.absent()
          : Value(pageInChapter),
      totalPagesInChapter: totalPagesInChapter == null && nullToAbsent
          ? const Value.absent()
          : Value(totalPagesInChapter),
    );
  }

  factory BookmarkRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookmarkRow(
      id: serializer.fromJson<int>(json['id']),
      bookKey: serializer.fromJson<String>(json['bookKey']),
      sectionIndex: serializer.fromJson<int>(json['sectionIndex']),
      normCharOffset: serializer.fromJson<int>(json['normCharOffset']),
      label: serializer.fromJson<String>(json['label']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      bookTitle: serializer.fromJson<String?>(json['bookTitle']),
      pageInChapter: serializer.fromJson<int?>(json['pageInChapter']),
      totalPagesInChapter:
          serializer.fromJson<int?>(json['totalPagesInChapter']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookKey': serializer.toJson<String>(bookKey),
      'sectionIndex': serializer.toJson<int>(sectionIndex),
      'normCharOffset': serializer.toJson<int>(normCharOffset),
      'label': serializer.toJson<String>(label),
      'createdAt': serializer.toJson<int>(createdAt),
      'bookTitle': serializer.toJson<String?>(bookTitle),
      'pageInChapter': serializer.toJson<int?>(pageInChapter),
      'totalPagesInChapter': serializer.toJson<int?>(totalPagesInChapter),
    };
  }

  BookmarkRow copyWith(
          {int? id,
          String? bookKey,
          int? sectionIndex,
          int? normCharOffset,
          String? label,
          int? createdAt,
          Value<String?> bookTitle = const Value.absent(),
          Value<int?> pageInChapter = const Value.absent(),
          Value<int?> totalPagesInChapter = const Value.absent()}) =>
      BookmarkRow(
        id: id ?? this.id,
        bookKey: bookKey ?? this.bookKey,
        sectionIndex: sectionIndex ?? this.sectionIndex,
        normCharOffset: normCharOffset ?? this.normCharOffset,
        label: label ?? this.label,
        createdAt: createdAt ?? this.createdAt,
        bookTitle: bookTitle.present ? bookTitle.value : this.bookTitle,
        pageInChapter:
            pageInChapter.present ? pageInChapter.value : this.pageInChapter,
        totalPagesInChapter: totalPagesInChapter.present
            ? totalPagesInChapter.value
            : this.totalPagesInChapter,
      );
  BookmarkRow copyWithCompanion(BookmarksCompanion data) {
    return BookmarkRow(
      id: data.id.present ? data.id.value : this.id,
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      sectionIndex: data.sectionIndex.present
          ? data.sectionIndex.value
          : this.sectionIndex,
      normCharOffset: data.normCharOffset.present
          ? data.normCharOffset.value
          : this.normCharOffset,
      label: data.label.present ? data.label.value : this.label,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      bookTitle: data.bookTitle.present ? data.bookTitle.value : this.bookTitle,
      pageInChapter: data.pageInChapter.present
          ? data.pageInChapter.value
          : this.pageInChapter,
      totalPagesInChapter: data.totalPagesInChapter.present
          ? data.totalPagesInChapter.value
          : this.totalPagesInChapter,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookmarkRow(')
          ..write('id: $id, ')
          ..write('bookKey: $bookKey, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('label: $label, ')
          ..write('createdAt: $createdAt, ')
          ..write('bookTitle: $bookTitle, ')
          ..write('pageInChapter: $pageInChapter, ')
          ..write('totalPagesInChapter: $totalPagesInChapter')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, bookKey, sectionIndex, normCharOffset,
      label, createdAt, bookTitle, pageInChapter, totalPagesInChapter);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookmarkRow &&
          other.id == this.id &&
          other.bookKey == this.bookKey &&
          other.sectionIndex == this.sectionIndex &&
          other.normCharOffset == this.normCharOffset &&
          other.label == this.label &&
          other.createdAt == this.createdAt &&
          other.bookTitle == this.bookTitle &&
          other.pageInChapter == this.pageInChapter &&
          other.totalPagesInChapter == this.totalPagesInChapter);
}

class BookmarksCompanion extends UpdateCompanion<BookmarkRow> {
  final Value<int> id;
  final Value<String> bookKey;
  final Value<int> sectionIndex;
  final Value<int> normCharOffset;
  final Value<String> label;
  final Value<int> createdAt;
  final Value<String?> bookTitle;
  final Value<int?> pageInChapter;
  final Value<int?> totalPagesInChapter;
  const BookmarksCompanion({
    this.id = const Value.absent(),
    this.bookKey = const Value.absent(),
    this.sectionIndex = const Value.absent(),
    this.normCharOffset = const Value.absent(),
    this.label = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.bookTitle = const Value.absent(),
    this.pageInChapter = const Value.absent(),
    this.totalPagesInChapter = const Value.absent(),
  });
  BookmarksCompanion.insert({
    this.id = const Value.absent(),
    required String bookKey,
    required int sectionIndex,
    required int normCharOffset,
    required String label,
    required int createdAt,
    this.bookTitle = const Value.absent(),
    this.pageInChapter = const Value.absent(),
    this.totalPagesInChapter = const Value.absent(),
  })  : bookKey = Value(bookKey),
        sectionIndex = Value(sectionIndex),
        normCharOffset = Value(normCharOffset),
        label = Value(label),
        createdAt = Value(createdAt);
  static Insertable<BookmarkRow> custom({
    Expression<int>? id,
    Expression<String>? bookKey,
    Expression<int>? sectionIndex,
    Expression<int>? normCharOffset,
    Expression<String>? label,
    Expression<int>? createdAt,
    Expression<String>? bookTitle,
    Expression<int>? pageInChapter,
    Expression<int>? totalPagesInChapter,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookKey != null) 'book_key': bookKey,
      if (sectionIndex != null) 'section_index': sectionIndex,
      if (normCharOffset != null) 'norm_char_offset': normCharOffset,
      if (label != null) 'label': label,
      if (createdAt != null) 'created_at': createdAt,
      if (bookTitle != null) 'book_title': bookTitle,
      if (pageInChapter != null) 'page_in_chapter': pageInChapter,
      if (totalPagesInChapter != null)
        'total_pages_in_chapter': totalPagesInChapter,
    });
  }

  BookmarksCompanion copyWith(
      {Value<int>? id,
      Value<String>? bookKey,
      Value<int>? sectionIndex,
      Value<int>? normCharOffset,
      Value<String>? label,
      Value<int>? createdAt,
      Value<String?>? bookTitle,
      Value<int?>? pageInChapter,
      Value<int?>? totalPagesInChapter}) {
    return BookmarksCompanion(
      id: id ?? this.id,
      bookKey: bookKey ?? this.bookKey,
      sectionIndex: sectionIndex ?? this.sectionIndex,
      normCharOffset: normCharOffset ?? this.normCharOffset,
      label: label ?? this.label,
      createdAt: createdAt ?? this.createdAt,
      bookTitle: bookTitle ?? this.bookTitle,
      pageInChapter: pageInChapter ?? this.pageInChapter,
      totalPagesInChapter: totalPagesInChapter ?? this.totalPagesInChapter,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
    }
    if (sectionIndex.present) {
      map['section_index'] = Variable<int>(sectionIndex.value);
    }
    if (normCharOffset.present) {
      map['norm_char_offset'] = Variable<int>(normCharOffset.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (bookTitle.present) {
      map['book_title'] = Variable<String>(bookTitle.value);
    }
    if (pageInChapter.present) {
      map['page_in_chapter'] = Variable<int>(pageInChapter.value);
    }
    if (totalPagesInChapter.present) {
      map['total_pages_in_chapter'] = Variable<int>(totalPagesInChapter.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookmarksCompanion(')
          ..write('id: $id, ')
          ..write('bookKey: $bookKey, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('label: $label, ')
          ..write('createdAt: $createdAt, ')
          ..write('bookTitle: $bookTitle, ')
          ..write('pageInChapter: $pageInChapter, ')
          ..write('totalPagesInChapter: $totalPagesInChapter')
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
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
  static const VerificationMeta _colorValueMeta =
      const VerificationMeta('colorValue');
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
      'color_value', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0xFF9E9E9E));
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
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
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
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
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
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES epub_books (book_key) ON DELETE CASCADE'));
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<int> tagId = GeneratedColumn<int>(
      'tag_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES book_tags (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [id, bookKey, tagId];
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
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
    }
    if (data.containsKey('tag_id')) {
      context.handle(
          _tagIdMeta, tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta));
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {bookKey, tagId},
      ];
  @override
  BookTagMappingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookTagMappingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
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
  final String bookKey;
  final int tagId;
  const BookTagMappingRow(
      {required this.id, required this.bookKey, required this.tagId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_key'] = Variable<String>(bookKey);
    map['tag_id'] = Variable<int>(tagId);
    return map;
  }

  BookTagMappingsCompanion toCompanion(bool nullToAbsent) {
    return BookTagMappingsCompanion(
      id: Value(id),
      bookKey: Value(bookKey),
      tagId: Value(tagId),
    );
  }

  factory BookTagMappingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookTagMappingRow(
      id: serializer.fromJson<int>(json['id']),
      bookKey: serializer.fromJson<String>(json['bookKey']),
      tagId: serializer.fromJson<int>(json['tagId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookKey': serializer.toJson<String>(bookKey),
      'tagId': serializer.toJson<int>(tagId),
    };
  }

  BookTagMappingRow copyWith({int? id, String? bookKey, int? tagId}) =>
      BookTagMappingRow(
        id: id ?? this.id,
        bookKey: bookKey ?? this.bookKey,
        tagId: tagId ?? this.tagId,
      );
  BookTagMappingRow copyWithCompanion(BookTagMappingsCompanion data) {
    return BookTagMappingRow(
      id: data.id.present ? data.id.value : this.id,
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookTagMappingRow(')
          ..write('id: $id, ')
          ..write('bookKey: $bookKey, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, bookKey, tagId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookTagMappingRow &&
          other.id == this.id &&
          other.bookKey == this.bookKey &&
          other.tagId == this.tagId);
}

class BookTagMappingsCompanion extends UpdateCompanion<BookTagMappingRow> {
  final Value<int> id;
  final Value<String> bookKey;
  final Value<int> tagId;
  const BookTagMappingsCompanion({
    this.id = const Value.absent(),
    this.bookKey = const Value.absent(),
    this.tagId = const Value.absent(),
  });
  BookTagMappingsCompanion.insert({
    this.id = const Value.absent(),
    required String bookKey,
    required int tagId,
  })  : bookKey = Value(bookKey),
        tagId = Value(tagId);
  static Insertable<BookTagMappingRow> custom({
    Expression<int>? id,
    Expression<String>? bookKey,
    Expression<int>? tagId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookKey != null) 'book_key': bookKey,
      if (tagId != null) 'tag_id': tagId,
    });
  }

  BookTagMappingsCompanion copyWith(
      {Value<int>? id, Value<String>? bookKey, Value<int>? tagId}) {
    return BookTagMappingsCompanion(
      id: id ?? this.id,
      bookKey: bookKey ?? this.bookKey,
      tagId: tagId ?? this.tagId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
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
          ..write('bookKey: $bookKey, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }
}

class $SrtBookTagMappingsTable extends SrtBookTagMappings
    with TableInfo<$SrtBookTagMappingsTable, SrtBookTagMappingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SrtBookTagMappingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _srtBookIdMeta =
      const VerificationMeta('srtBookId');
  @override
  late final GeneratedColumn<int> srtBookId = GeneratedColumn<int>(
      'srt_book_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES srt_books (id) ON DELETE CASCADE'));
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<int> tagId = GeneratedColumn<int>(
      'tag_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES book_tags (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [id, srtBookId, tagId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'srt_book_tag_mappings';
  @override
  VerificationContext validateIntegrity(
      Insertable<SrtBookTagMappingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('srt_book_id')) {
      context.handle(
          _srtBookIdMeta,
          srtBookId.isAcceptableOrUnknown(
              data['srt_book_id']!, _srtBookIdMeta));
    } else if (isInserting) {
      context.missing(_srtBookIdMeta);
    }
    if (data.containsKey('tag_id')) {
      context.handle(
          _tagIdMeta, tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta));
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {srtBookId, tagId},
      ];
  @override
  SrtBookTagMappingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SrtBookTagMappingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      srtBookId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}srt_book_id'])!,
      tagId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tag_id'])!,
    );
  }

  @override
  $SrtBookTagMappingsTable createAlias(String alias) {
    return $SrtBookTagMappingsTable(attachedDatabase, alias);
  }
}

class SrtBookTagMappingRow extends DataClass
    implements Insertable<SrtBookTagMappingRow> {
  final int id;
  final int srtBookId;
  final int tagId;
  const SrtBookTagMappingRow(
      {required this.id, required this.srtBookId, required this.tagId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['srt_book_id'] = Variable<int>(srtBookId);
    map['tag_id'] = Variable<int>(tagId);
    return map;
  }

  SrtBookTagMappingsCompanion toCompanion(bool nullToAbsent) {
    return SrtBookTagMappingsCompanion(
      id: Value(id),
      srtBookId: Value(srtBookId),
      tagId: Value(tagId),
    );
  }

  factory SrtBookTagMappingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SrtBookTagMappingRow(
      id: serializer.fromJson<int>(json['id']),
      srtBookId: serializer.fromJson<int>(json['srtBookId']),
      tagId: serializer.fromJson<int>(json['tagId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'srtBookId': serializer.toJson<int>(srtBookId),
      'tagId': serializer.toJson<int>(tagId),
    };
  }

  SrtBookTagMappingRow copyWith({int? id, int? srtBookId, int? tagId}) =>
      SrtBookTagMappingRow(
        id: id ?? this.id,
        srtBookId: srtBookId ?? this.srtBookId,
        tagId: tagId ?? this.tagId,
      );
  SrtBookTagMappingRow copyWithCompanion(SrtBookTagMappingsCompanion data) {
    return SrtBookTagMappingRow(
      id: data.id.present ? data.id.value : this.id,
      srtBookId: data.srtBookId.present ? data.srtBookId.value : this.srtBookId,
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SrtBookTagMappingRow(')
          ..write('id: $id, ')
          ..write('srtBookId: $srtBookId, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, srtBookId, tagId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SrtBookTagMappingRow &&
          other.id == this.id &&
          other.srtBookId == this.srtBookId &&
          other.tagId == this.tagId);
}

class SrtBookTagMappingsCompanion
    extends UpdateCompanion<SrtBookTagMappingRow> {
  final Value<int> id;
  final Value<int> srtBookId;
  final Value<int> tagId;
  const SrtBookTagMappingsCompanion({
    this.id = const Value.absent(),
    this.srtBookId = const Value.absent(),
    this.tagId = const Value.absent(),
  });
  SrtBookTagMappingsCompanion.insert({
    this.id = const Value.absent(),
    required int srtBookId,
    required int tagId,
  })  : srtBookId = Value(srtBookId),
        tagId = Value(tagId);
  static Insertable<SrtBookTagMappingRow> custom({
    Expression<int>? id,
    Expression<int>? srtBookId,
    Expression<int>? tagId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (srtBookId != null) 'srt_book_id': srtBookId,
      if (tagId != null) 'tag_id': tagId,
    });
  }

  SrtBookTagMappingsCompanion copyWith(
      {Value<int>? id, Value<int>? srtBookId, Value<int>? tagId}) {
    return SrtBookTagMappingsCompanion(
      id: id ?? this.id,
      srtBookId: srtBookId ?? this.srtBookId,
      tagId: tagId ?? this.tagId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (srtBookId.present) {
      map['srt_book_id'] = Variable<int>(srtBookId.value);
    }
    if (tagId.present) {
      map['tag_id'] = Variable<int>(tagId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SrtBookTagMappingsCompanion(')
          ..write('id: $id, ')
          ..write('srtBookId: $srtBookId, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }
}

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
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'));
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
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
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
  ProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
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
  const ProfileRow(
      {required this.id,
      required this.name,
      required this.createdAt,
      required this.updatedAt});
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
    return ProfilesCompanion(
      id: Value(id),
      name: Value(name),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ProfileRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileRow(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  ProfileRow copyWith(
          {int? id, String? name, int? createdAt, int? updatedAt}) =>
      ProfileRow(
        id: id ?? this.id,
        name: name ?? this.name,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  ProfileRow copyWithCompanion(ProfilesCompanion data) {
    return ProfileRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ProfilesCompanion extends UpdateCompanion<ProfileRow> {
  final Value<int> id;
  final Value<String> name;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ProfilesCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required int createdAt,
    required int updatedAt,
  })  : name = Value(name),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<ProfileRow> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ProfilesCompanion copyWith(
      {Value<int>? id,
      Value<String>? name,
      Value<int>? createdAt,
      Value<int>? updatedAt}) {
    return ProfilesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
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
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $ProfileSettingsTable extends ProfileSettings
    with TableInfo<$ProfileSettingsTable, ProfileSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfileSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _profileIdMeta =
      const VerificationMeta('profileId');
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>(
      'profile_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES profiles (id) ON DELETE CASCADE'));
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
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
  List<GeneratedColumn> get $columns => [id, profileId, category, key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile_settings';
  @override
  VerificationContext validateIntegrity(Insertable<ProfileSettingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profile_id')) {
      context.handle(_profileIdMeta,
          profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta));
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
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
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {profileId, category, key},
      ];
  @override
  ProfileSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileSettingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      profileId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}profile_id'])!,
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $ProfileSettingsTable createAlias(String alias) {
    return $ProfileSettingsTable(attachedDatabase, alias);
  }
}

class ProfileSettingRow extends DataClass
    implements Insertable<ProfileSettingRow> {
  final int id;
  final int profileId;
  final String category;
  final String key;
  final String value;
  const ProfileSettingRow(
      {required this.id,
      required this.profileId,
      required this.category,
      required this.key,
      required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['profile_id'] = Variable<int>(profileId);
    map['category'] = Variable<String>(category);
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  ProfileSettingsCompanion toCompanion(bool nullToAbsent) {
    return ProfileSettingsCompanion(
      id: Value(id),
      profileId: Value(profileId),
      category: Value(category),
      key: Value(key),
      value: Value(value),
    );
  }

  factory ProfileSettingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileSettingRow(
      id: serializer.fromJson<int>(json['id']),
      profileId: serializer.fromJson<int>(json['profileId']),
      category: serializer.fromJson<String>(json['category']),
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileId': serializer.toJson<int>(profileId),
      'category': serializer.toJson<String>(category),
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  ProfileSettingRow copyWith(
          {int? id,
          int? profileId,
          String? category,
          String? key,
          String? value}) =>
      ProfileSettingRow(
        id: id ?? this.id,
        profileId: profileId ?? this.profileId,
        category: category ?? this.category,
        key: key ?? this.key,
        value: value ?? this.value,
      );
  ProfileSettingRow copyWithCompanion(ProfileSettingsCompanion data) {
    return ProfileSettingRow(
      id: data.id.present ? data.id.value : this.id,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      category: data.category.present ? data.category.value : this.category,
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileSettingRow(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, profileId, category, key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileSettingRow &&
          other.id == this.id &&
          other.profileId == this.profileId &&
          other.category == this.category &&
          other.key == this.key &&
          other.value == this.value);
}

class ProfileSettingsCompanion extends UpdateCompanion<ProfileSettingRow> {
  final Value<int> id;
  final Value<int> profileId;
  final Value<String> category;
  final Value<String> key;
  final Value<String> value;
  const ProfileSettingsCompanion({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    this.category = const Value.absent(),
    this.key = const Value.absent(),
    this.value = const Value.absent(),
  });
  ProfileSettingsCompanion.insert({
    this.id = const Value.absent(),
    required int profileId,
    required String category,
    required String key,
    required String value,
  })  : profileId = Value(profileId),
        category = Value(category),
        key = Value(key),
        value = Value(value);
  static Insertable<ProfileSettingRow> custom({
    Expression<int>? id,
    Expression<int>? profileId,
    Expression<String>? category,
    Expression<String>? key,
    Expression<String>? value,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileId != null) 'profile_id': profileId,
      if (category != null) 'category': category,
      if (key != null) 'key': key,
      if (value != null) 'value': value,
    });
  }

  ProfileSettingsCompanion copyWith(
      {Value<int>? id,
      Value<int>? profileId,
      Value<String>? category,
      Value<String>? key,
      Value<String>? value}) {
    return ProfileSettingsCompanion(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      category: category ?? this.category,
      key: key ?? this.key,
      value: value ?? this.value,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<int>(profileId.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfileSettingsCompanion(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('category: $category, ')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }
}

class $MediaTypeProfilesTable extends MediaTypeProfiles
    with TableInfo<$MediaTypeProfilesTable, MediaTypeProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaTypeProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _mediaTypeMeta =
      const VerificationMeta('mediaType');
  @override
  late final GeneratedColumn<String> mediaType = GeneratedColumn<String>(
      'media_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _profileIdMeta =
      const VerificationMeta('profileId');
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>(
      'profile_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES profiles (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [mediaType, profileId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_type_profiles';
  @override
  VerificationContext validateIntegrity(
      Insertable<MediaTypeProfileRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('media_type')) {
      context.handle(_mediaTypeMeta,
          mediaType.isAcceptableOrUnknown(data['media_type']!, _mediaTypeMeta));
    } else if (isInserting) {
      context.missing(_mediaTypeMeta);
    }
    if (data.containsKey('profile_id')) {
      context.handle(_profileIdMeta,
          profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta));
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {mediaType};
  @override
  MediaTypeProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaTypeProfileRow(
      mediaType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}media_type'])!,
      profileId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}profile_id'])!,
    );
  }

  @override
  $MediaTypeProfilesTable createAlias(String alias) {
    return $MediaTypeProfilesTable(attachedDatabase, alias);
  }
}

class MediaTypeProfileRow extends DataClass
    implements Insertable<MediaTypeProfileRow> {
  final String mediaType;
  final int profileId;
  const MediaTypeProfileRow({required this.mediaType, required this.profileId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['media_type'] = Variable<String>(mediaType);
    map['profile_id'] = Variable<int>(profileId);
    return map;
  }

  MediaTypeProfilesCompanion toCompanion(bool nullToAbsent) {
    return MediaTypeProfilesCompanion(
      mediaType: Value(mediaType),
      profileId: Value(profileId),
    );
  }

  factory MediaTypeProfileRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaTypeProfileRow(
      mediaType: serializer.fromJson<String>(json['mediaType']),
      profileId: serializer.fromJson<int>(json['profileId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'mediaType': serializer.toJson<String>(mediaType),
      'profileId': serializer.toJson<int>(profileId),
    };
  }

  MediaTypeProfileRow copyWith({String? mediaType, int? profileId}) =>
      MediaTypeProfileRow(
        mediaType: mediaType ?? this.mediaType,
        profileId: profileId ?? this.profileId,
      );
  MediaTypeProfileRow copyWithCompanion(MediaTypeProfilesCompanion data) {
    return MediaTypeProfileRow(
      mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaTypeProfileRow(')
          ..write('mediaType: $mediaType, ')
          ..write('profileId: $profileId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(mediaType, profileId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaTypeProfileRow &&
          other.mediaType == this.mediaType &&
          other.profileId == this.profileId);
}

class MediaTypeProfilesCompanion extends UpdateCompanion<MediaTypeProfileRow> {
  final Value<String> mediaType;
  final Value<int> profileId;
  final Value<int> rowid;
  const MediaTypeProfilesCompanion({
    this.mediaType = const Value.absent(),
    this.profileId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaTypeProfilesCompanion.insert({
    required String mediaType,
    required int profileId,
    this.rowid = const Value.absent(),
  })  : mediaType = Value(mediaType),
        profileId = Value(profileId);
  static Insertable<MediaTypeProfileRow> custom({
    Expression<String>? mediaType,
    Expression<int>? profileId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (mediaType != null) 'media_type': mediaType,
      if (profileId != null) 'profile_id': profileId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaTypeProfilesCompanion copyWith(
      {Value<String>? mediaType, Value<int>? profileId, Value<int>? rowid}) {
    return MediaTypeProfilesCompanion(
      mediaType: mediaType ?? this.mediaType,
      profileId: profileId ?? this.profileId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (mediaType.present) {
      map['media_type'] = Variable<String>(mediaType.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<int>(profileId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaTypeProfilesCompanion(')
          ..write('mediaType: $mediaType, ')
          ..write('profileId: $profileId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BookProfilesTable extends BookProfiles
    with TableInfo<$BookProfilesTable, BookProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _profileIdMeta =
      const VerificationMeta('profileId');
  @override
  late final GeneratedColumn<int> profileId = GeneratedColumn<int>(
      'profile_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES profiles (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [bookKey, profileId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_profiles';
  @override
  VerificationContext validateIntegrity(Insertable<BookProfileRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    } else if (isInserting) {
      context.missing(_bookKeyMeta);
    }
    if (data.containsKey('profile_id')) {
      context.handle(_profileIdMeta,
          profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta));
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookKey};
  @override
  BookProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookProfileRow(
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key'])!,
      profileId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}profile_id'])!,
    );
  }

  @override
  $BookProfilesTable createAlias(String alias) {
    return $BookProfilesTable(attachedDatabase, alias);
  }
}

class BookProfileRow extends DataClass implements Insertable<BookProfileRow> {
  final String bookKey;
  final int profileId;
  const BookProfileRow({required this.bookKey, required this.profileId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_key'] = Variable<String>(bookKey);
    map['profile_id'] = Variable<int>(profileId);
    return map;
  }

  BookProfilesCompanion toCompanion(bool nullToAbsent) {
    return BookProfilesCompanion(
      bookKey: Value(bookKey),
      profileId: Value(profileId),
    );
  }

  factory BookProfileRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookProfileRow(
      bookKey: serializer.fromJson<String>(json['bookKey']),
      profileId: serializer.fromJson<int>(json['profileId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookKey': serializer.toJson<String>(bookKey),
      'profileId': serializer.toJson<int>(profileId),
    };
  }

  BookProfileRow copyWith({String? bookKey, int? profileId}) => BookProfileRow(
        bookKey: bookKey ?? this.bookKey,
        profileId: profileId ?? this.profileId,
      );
  BookProfileRow copyWithCompanion(BookProfilesCompanion data) {
    return BookProfileRow(
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookProfileRow(')
          ..write('bookKey: $bookKey, ')
          ..write('profileId: $profileId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bookKey, profileId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookProfileRow &&
          other.bookKey == this.bookKey &&
          other.profileId == this.profileId);
}

class BookProfilesCompanion extends UpdateCompanion<BookProfileRow> {
  final Value<String> bookKey;
  final Value<int> profileId;
  final Value<int> rowid;
  const BookProfilesCompanion({
    this.bookKey = const Value.absent(),
    this.profileId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BookProfilesCompanion.insert({
    required String bookKey,
    required int profileId,
    this.rowid = const Value.absent(),
  })  : bookKey = Value(bookKey),
        profileId = Value(profileId);
  static Insertable<BookProfileRow> custom({
    Expression<String>? bookKey,
    Expression<int>? profileId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookKey != null) 'book_key': bookKey,
      if (profileId != null) 'profile_id': profileId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BookProfilesCompanion copyWith(
      {Value<String>? bookKey, Value<int>? profileId, Value<int>? rowid}) {
    return BookProfilesCompanion(
      bookKey: bookKey ?? this.bookKey,
      profileId: profileId ?? this.profileId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<int>(profileId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookProfilesCompanion(')
          ..write('bookKey: $bookKey, ')
          ..write('profileId: $profileId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncBaselinesTable extends SyncBaselines
    with TableInfo<$SyncBaselinesTable, SyncBaselineRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncBaselinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _assetKeyMeta =
      const VerificationMeta('assetKey');
  @override
  late final GeneratedColumn<String> assetKey = GeneratedColumn<String>(
      'asset_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _dimensionMeta =
      const VerificationMeta('dimension');
  @override
  late final GeneratedColumn<String> dimension = GeneratedColumn<String>(
      'dimension', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _baseVersionMeta =
      const VerificationMeta('baseVersion');
  @override
  late final GeneratedColumn<int> baseVersion = GeneratedColumn<int>(
      'base_version', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [assetKey, dimension, baseVersion];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_baselines';
  @override
  VerificationContext validateIntegrity(Insertable<SyncBaselineRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('asset_key')) {
      context.handle(_assetKeyMeta,
          assetKey.isAcceptableOrUnknown(data['asset_key']!, _assetKeyMeta));
    } else if (isInserting) {
      context.missing(_assetKeyMeta);
    }
    if (data.containsKey('dimension')) {
      context.handle(_dimensionMeta,
          dimension.isAcceptableOrUnknown(data['dimension']!, _dimensionMeta));
    } else if (isInserting) {
      context.missing(_dimensionMeta);
    }
    if (data.containsKey('base_version')) {
      context.handle(
          _baseVersionMeta,
          baseVersion.isAcceptableOrUnknown(
              data['base_version']!, _baseVersionMeta));
    } else if (isInserting) {
      context.missing(_baseVersionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {assetKey, dimension};
  @override
  SyncBaselineRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncBaselineRow(
      assetKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}asset_key'])!,
      dimension: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}dimension'])!,
      baseVersion: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}base_version'])!,
    );
  }

  @override
  $SyncBaselinesTable createAlias(String alias) {
    return $SyncBaselinesTable(attachedDatabase, alias);
  }
}

class SyncBaselineRow extends DataClass implements Insertable<SyncBaselineRow> {
  final String assetKey;
  final String dimension;
  final int baseVersion;
  const SyncBaselineRow(
      {required this.assetKey,
      required this.dimension,
      required this.baseVersion});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['asset_key'] = Variable<String>(assetKey);
    map['dimension'] = Variable<String>(dimension);
    map['base_version'] = Variable<int>(baseVersion);
    return map;
  }

  SyncBaselinesCompanion toCompanion(bool nullToAbsent) {
    return SyncBaselinesCompanion(
      assetKey: Value(assetKey),
      dimension: Value(dimension),
      baseVersion: Value(baseVersion),
    );
  }

  factory SyncBaselineRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncBaselineRow(
      assetKey: serializer.fromJson<String>(json['assetKey']),
      dimension: serializer.fromJson<String>(json['dimension']),
      baseVersion: serializer.fromJson<int>(json['baseVersion']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'assetKey': serializer.toJson<String>(assetKey),
      'dimension': serializer.toJson<String>(dimension),
      'baseVersion': serializer.toJson<int>(baseVersion),
    };
  }

  SyncBaselineRow copyWith(
          {String? assetKey, String? dimension, int? baseVersion}) =>
      SyncBaselineRow(
        assetKey: assetKey ?? this.assetKey,
        dimension: dimension ?? this.dimension,
        baseVersion: baseVersion ?? this.baseVersion,
      );
  SyncBaselineRow copyWithCompanion(SyncBaselinesCompanion data) {
    return SyncBaselineRow(
      assetKey: data.assetKey.present ? data.assetKey.value : this.assetKey,
      dimension: data.dimension.present ? data.dimension.value : this.dimension,
      baseVersion:
          data.baseVersion.present ? data.baseVersion.value : this.baseVersion,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncBaselineRow(')
          ..write('assetKey: $assetKey, ')
          ..write('dimension: $dimension, ')
          ..write('baseVersion: $baseVersion')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(assetKey, dimension, baseVersion);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncBaselineRow &&
          other.assetKey == this.assetKey &&
          other.dimension == this.dimension &&
          other.baseVersion == this.baseVersion);
}

class SyncBaselinesCompanion extends UpdateCompanion<SyncBaselineRow> {
  final Value<String> assetKey;
  final Value<String> dimension;
  final Value<int> baseVersion;
  final Value<int> rowid;
  const SyncBaselinesCompanion({
    this.assetKey = const Value.absent(),
    this.dimension = const Value.absent(),
    this.baseVersion = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncBaselinesCompanion.insert({
    required String assetKey,
    required String dimension,
    required int baseVersion,
    this.rowid = const Value.absent(),
  })  : assetKey = Value(assetKey),
        dimension = Value(dimension),
        baseVersion = Value(baseVersion);
  static Insertable<SyncBaselineRow> custom({
    Expression<String>? assetKey,
    Expression<String>? dimension,
    Expression<int>? baseVersion,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (assetKey != null) 'asset_key': assetKey,
      if (dimension != null) 'dimension': dimension,
      if (baseVersion != null) 'base_version': baseVersion,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncBaselinesCompanion copyWith(
      {Value<String>? assetKey,
      Value<String>? dimension,
      Value<int>? baseVersion,
      Value<int>? rowid}) {
    return SyncBaselinesCompanion(
      assetKey: assetKey ?? this.assetKey,
      dimension: dimension ?? this.dimension,
      baseVersion: baseVersion ?? this.baseVersion,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (assetKey.present) {
      map['asset_key'] = Variable<String>(assetKey.value);
    }
    if (dimension.present) {
      map['dimension'] = Variable<String>(dimension.value);
    }
    if (baseVersion.present) {
      map['base_version'] = Variable<int>(baseVersion.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncBaselinesCompanion(')
          ..write('assetKey: $assetKey, ')
          ..write('dimension: $dimension, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VideoBooksTable extends VideoBooks
    with TableInfo<$VideoBooksTable, VideoBookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VideoBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookUidMeta =
      const VerificationMeta('bookUid');
  @override
  late final GeneratedColumn<String> bookUid = GeneratedColumn<String>(
      'book_uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _videoPathMeta =
      const VerificationMeta('videoPath');
  @override
  late final GeneratedColumn<String> videoPath = GeneratedColumn<String>(
      'video_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _subtitleSourceMeta =
      const VerificationMeta('subtitleSource');
  @override
  late final GeneratedColumn<String> subtitleSource = GeneratedColumn<String>(
      'subtitle_source', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _subtitleFormatMeta =
      const VerificationMeta('subtitleFormat');
  @override
  late final GeneratedColumn<String> subtitleFormat = GeneratedColumn<String>(
      'subtitle_format', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _embeddedSubtitleTrackMeta =
      const VerificationMeta('embeddedSubtitleTrack');
  @override
  late final GeneratedColumn<int> embeddedSubtitleTrack = GeneratedColumn<int>(
      'embedded_subtitle_track', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _coverPathMeta =
      const VerificationMeta('coverPath');
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
      'cover_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastPositionMsMeta =
      const VerificationMeta('lastPositionMs');
  @override
  late final GeneratedColumn<int> lastPositionMs = GeneratedColumn<int>(
      'last_position_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _importedAtMeta =
      const VerificationMeta('importedAt');
  @override
  late final GeneratedColumn<DateTime> importedAt = GeneratedColumn<DateTime>(
      'imported_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _playlistJsonMeta =
      const VerificationMeta('playlistJson');
  @override
  late final GeneratedColumn<String> playlistJson = GeneratedColumn<String>(
      'playlist_json', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _currentEpisodeMeta =
      const VerificationMeta('currentEpisode');
  @override
  late final GeneratedColumn<int> currentEpisode = GeneratedColumn<int>(
      'current_episode', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _audioTrackIdMeta =
      const VerificationMeta('audioTrackId');
  @override
  late final GeneratedColumn<String> audioTrackId = GeneratedColumn<String>(
      'audio_track_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _delayMsMeta =
      const VerificationMeta('delayMs');
  @override
  late final GeneratedColumn<int> delayMs = GeneratedColumn<int>(
      'delay_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _completedAtMeta =
      const VerificationMeta('completedAt');
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
      'completed_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _sourceIdMeta =
      const VerificationMeta('sourceId');
  @override
  late final GeneratedColumn<int> sourceId = GeneratedColumn<int>(
      'source_id', aliasedName, true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES media_sources (id) ON DELETE SET NULL'));
  @override
  List<GeneratedColumn> get $columns => [
        bookUid,
        title,
        videoPath,
        subtitleSource,
        subtitleFormat,
        embeddedSubtitleTrack,
        coverPath,
        lastPositionMs,
        importedAt,
        playlistJson,
        currentEpisode,
        audioTrackId,
        delayMs,
        completedAt,
        sourceId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'video_books';
  @override
  VerificationContext validateIntegrity(Insertable<VideoBookRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_uid')) {
      context.handle(_bookUidMeta,
          bookUid.isAcceptableOrUnknown(data['book_uid']!, _bookUidMeta));
    } else if (isInserting) {
      context.missing(_bookUidMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('video_path')) {
      context.handle(_videoPathMeta,
          videoPath.isAcceptableOrUnknown(data['video_path']!, _videoPathMeta));
    } else if (isInserting) {
      context.missing(_videoPathMeta);
    }
    if (data.containsKey('subtitle_source')) {
      context.handle(
          _subtitleSourceMeta,
          subtitleSource.isAcceptableOrUnknown(
              data['subtitle_source']!, _subtitleSourceMeta));
    }
    if (data.containsKey('subtitle_format')) {
      context.handle(
          _subtitleFormatMeta,
          subtitleFormat.isAcceptableOrUnknown(
              data['subtitle_format']!, _subtitleFormatMeta));
    }
    if (data.containsKey('embedded_subtitle_track')) {
      context.handle(
          _embeddedSubtitleTrackMeta,
          embeddedSubtitleTrack.isAcceptableOrUnknown(
              data['embedded_subtitle_track']!, _embeddedSubtitleTrackMeta));
    }
    if (data.containsKey('cover_path')) {
      context.handle(_coverPathMeta,
          coverPath.isAcceptableOrUnknown(data['cover_path']!, _coverPathMeta));
    }
    if (data.containsKey('last_position_ms')) {
      context.handle(
          _lastPositionMsMeta,
          lastPositionMs.isAcceptableOrUnknown(
              data['last_position_ms']!, _lastPositionMsMeta));
    }
    if (data.containsKey('imported_at')) {
      context.handle(
          _importedAtMeta,
          importedAt.isAcceptableOrUnknown(
              data['imported_at']!, _importedAtMeta));
    }
    if (data.containsKey('playlist_json')) {
      context.handle(
          _playlistJsonMeta,
          playlistJson.isAcceptableOrUnknown(
              data['playlist_json']!, _playlistJsonMeta));
    }
    if (data.containsKey('current_episode')) {
      context.handle(
          _currentEpisodeMeta,
          currentEpisode.isAcceptableOrUnknown(
              data['current_episode']!, _currentEpisodeMeta));
    }
    if (data.containsKey('audio_track_id')) {
      context.handle(
          _audioTrackIdMeta,
          audioTrackId.isAcceptableOrUnknown(
              data['audio_track_id']!, _audioTrackIdMeta));
    }
    if (data.containsKey('delay_ms')) {
      context.handle(_delayMsMeta,
          delayMs.isAcceptableOrUnknown(data['delay_ms']!, _delayMsMeta));
    }
    if (data.containsKey('completed_at')) {
      context.handle(
          _completedAtMeta,
          completedAt.isAcceptableOrUnknown(
              data['completed_at']!, _completedAtMeta));
    }
    if (data.containsKey('source_id')) {
      context.handle(_sourceIdMeta,
          sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookUid};
  @override
  VideoBookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VideoBookRow(
      bookUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_uid'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      videoPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}video_path'])!,
      subtitleSource: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}subtitle_source']),
      subtitleFormat: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}subtitle_format']),
      embeddedSubtitleTrack: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}embedded_subtitle_track']),
      coverPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cover_path']),
      lastPositionMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_position_ms'])!,
      importedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}imported_at']),
      playlistJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}playlist_json']),
      currentEpisode: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}current_episode'])!,
      audioTrackId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}audio_track_id']),
      delayMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}delay_ms'])!,
      completedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}completed_at']),
      sourceId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}source_id']),
    );
  }

  @override
  $VideoBooksTable createAlias(String alias) {
    return $VideoBooksTable(attachedDatabase, alias);
  }
}

class VideoBookRow extends DataClass implements Insertable<VideoBookRow> {
  final String bookUid;
  final String title;
  final String videoPath;
  final String? subtitleSource;
  final String? subtitleFormat;
  final int? embeddedSubtitleTrack;
  final String? coverPath;
  final int lastPositionMs;
  final DateTime? importedAt;

  /// m3u8 多集播放列表 JSON：`[{title,path}]`（绝对路径）。单视频导入时为 null。
  final String? playlistJson;

  /// 当前播放到的集索引（对应 [playlistJson] 数组下标）；单视频恒 0。
  final int currentEpisode;

  /// 用户选中的音轨（libmpv `AudioTrack.id`）；null=未选过，跟随 libmpv 默认。
  /// 多集播放列表换集时复用同一值（如选了日语音轨，每集都用日语）。
  final String? audioTrackId;

  /// 音画延迟（毫秒）：正值=画面先于文字，查 cue 时把位置往回拨，让字幕与画面对齐。
  /// 跨重启保留；多集播放列表换集时复用同一值（手动校准一次全片受用）。
  final int delayMs;

  /// 视频首次播放进度 ≥ 90% 的时间戳（完成标记）；null = 未完成。统计去重计数用。
  final DateTime? completedAt;

  /// TODO-817：归属的网络/本地来源库（[MediaSources].id）。可空 = 手动导入无来源。
  /// onDelete:setNull = 移除来源时保留视频（归 NULL），不连坐删条目。
  final int? sourceId;
  const VideoBookRow(
      {required this.bookUid,
      required this.title,
      required this.videoPath,
      this.subtitleSource,
      this.subtitleFormat,
      this.embeddedSubtitleTrack,
      this.coverPath,
      required this.lastPositionMs,
      this.importedAt,
      this.playlistJson,
      required this.currentEpisode,
      this.audioTrackId,
      required this.delayMs,
      this.completedAt,
      this.sourceId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_uid'] = Variable<String>(bookUid);
    map['title'] = Variable<String>(title);
    map['video_path'] = Variable<String>(videoPath);
    if (!nullToAbsent || subtitleSource != null) {
      map['subtitle_source'] = Variable<String>(subtitleSource);
    }
    if (!nullToAbsent || subtitleFormat != null) {
      map['subtitle_format'] = Variable<String>(subtitleFormat);
    }
    if (!nullToAbsent || embeddedSubtitleTrack != null) {
      map['embedded_subtitle_track'] = Variable<int>(embeddedSubtitleTrack);
    }
    if (!nullToAbsent || coverPath != null) {
      map['cover_path'] = Variable<String>(coverPath);
    }
    map['last_position_ms'] = Variable<int>(lastPositionMs);
    if (!nullToAbsent || importedAt != null) {
      map['imported_at'] = Variable<DateTime>(importedAt);
    }
    if (!nullToAbsent || playlistJson != null) {
      map['playlist_json'] = Variable<String>(playlistJson);
    }
    map['current_episode'] = Variable<int>(currentEpisode);
    if (!nullToAbsent || audioTrackId != null) {
      map['audio_track_id'] = Variable<String>(audioTrackId);
    }
    map['delay_ms'] = Variable<int>(delayMs);
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<DateTime>(completedAt);
    }
    if (!nullToAbsent || sourceId != null) {
      map['source_id'] = Variable<int>(sourceId);
    }
    return map;
  }

  VideoBooksCompanion toCompanion(bool nullToAbsent) {
    return VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(videoPath),
      subtitleSource: subtitleSource == null && nullToAbsent
          ? const Value.absent()
          : Value(subtitleSource),
      subtitleFormat: subtitleFormat == null && nullToAbsent
          ? const Value.absent()
          : Value(subtitleFormat),
      embeddedSubtitleTrack: embeddedSubtitleTrack == null && nullToAbsent
          ? const Value.absent()
          : Value(embeddedSubtitleTrack),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      lastPositionMs: Value(lastPositionMs),
      importedAt: importedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(importedAt),
      playlistJson: playlistJson == null && nullToAbsent
          ? const Value.absent()
          : Value(playlistJson),
      currentEpisode: Value(currentEpisode),
      audioTrackId: audioTrackId == null && nullToAbsent
          ? const Value.absent()
          : Value(audioTrackId),
      delayMs: Value(delayMs),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      sourceId: sourceId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceId),
    );
  }

  factory VideoBookRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VideoBookRow(
      bookUid: serializer.fromJson<String>(json['bookUid']),
      title: serializer.fromJson<String>(json['title']),
      videoPath: serializer.fromJson<String>(json['videoPath']),
      subtitleSource: serializer.fromJson<String?>(json['subtitleSource']),
      subtitleFormat: serializer.fromJson<String?>(json['subtitleFormat']),
      embeddedSubtitleTrack:
          serializer.fromJson<int?>(json['embeddedSubtitleTrack']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      lastPositionMs: serializer.fromJson<int>(json['lastPositionMs']),
      importedAt: serializer.fromJson<DateTime?>(json['importedAt']),
      playlistJson: serializer.fromJson<String?>(json['playlistJson']),
      currentEpisode: serializer.fromJson<int>(json['currentEpisode']),
      audioTrackId: serializer.fromJson<String?>(json['audioTrackId']),
      delayMs: serializer.fromJson<int>(json['delayMs']),
      completedAt: serializer.fromJson<DateTime?>(json['completedAt']),
      sourceId: serializer.fromJson<int?>(json['sourceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookUid': serializer.toJson<String>(bookUid),
      'title': serializer.toJson<String>(title),
      'videoPath': serializer.toJson<String>(videoPath),
      'subtitleSource': serializer.toJson<String?>(subtitleSource),
      'subtitleFormat': serializer.toJson<String?>(subtitleFormat),
      'embeddedSubtitleTrack': serializer.toJson<int?>(embeddedSubtitleTrack),
      'coverPath': serializer.toJson<String?>(coverPath),
      'lastPositionMs': serializer.toJson<int>(lastPositionMs),
      'importedAt': serializer.toJson<DateTime?>(importedAt),
      'playlistJson': serializer.toJson<String?>(playlistJson),
      'currentEpisode': serializer.toJson<int>(currentEpisode),
      'audioTrackId': serializer.toJson<String?>(audioTrackId),
      'delayMs': serializer.toJson<int>(delayMs),
      'completedAt': serializer.toJson<DateTime?>(completedAt),
      'sourceId': serializer.toJson<int?>(sourceId),
    };
  }

  VideoBookRow copyWith(
          {String? bookUid,
          String? title,
          String? videoPath,
          Value<String?> subtitleSource = const Value.absent(),
          Value<String?> subtitleFormat = const Value.absent(),
          Value<int?> embeddedSubtitleTrack = const Value.absent(),
          Value<String?> coverPath = const Value.absent(),
          int? lastPositionMs,
          Value<DateTime?> importedAt = const Value.absent(),
          Value<String?> playlistJson = const Value.absent(),
          int? currentEpisode,
          Value<String?> audioTrackId = const Value.absent(),
          int? delayMs,
          Value<DateTime?> completedAt = const Value.absent(),
          Value<int?> sourceId = const Value.absent()}) =>
      VideoBookRow(
        bookUid: bookUid ?? this.bookUid,
        title: title ?? this.title,
        videoPath: videoPath ?? this.videoPath,
        subtitleSource:
            subtitleSource.present ? subtitleSource.value : this.subtitleSource,
        subtitleFormat:
            subtitleFormat.present ? subtitleFormat.value : this.subtitleFormat,
        embeddedSubtitleTrack: embeddedSubtitleTrack.present
            ? embeddedSubtitleTrack.value
            : this.embeddedSubtitleTrack,
        coverPath: coverPath.present ? coverPath.value : this.coverPath,
        lastPositionMs: lastPositionMs ?? this.lastPositionMs,
        importedAt: importedAt.present ? importedAt.value : this.importedAt,
        playlistJson:
            playlistJson.present ? playlistJson.value : this.playlistJson,
        currentEpisode: currentEpisode ?? this.currentEpisode,
        audioTrackId:
            audioTrackId.present ? audioTrackId.value : this.audioTrackId,
        delayMs: delayMs ?? this.delayMs,
        completedAt: completedAt.present ? completedAt.value : this.completedAt,
        sourceId: sourceId.present ? sourceId.value : this.sourceId,
      );
  VideoBookRow copyWithCompanion(VideoBooksCompanion data) {
    return VideoBookRow(
      bookUid: data.bookUid.present ? data.bookUid.value : this.bookUid,
      title: data.title.present ? data.title.value : this.title,
      videoPath: data.videoPath.present ? data.videoPath.value : this.videoPath,
      subtitleSource: data.subtitleSource.present
          ? data.subtitleSource.value
          : this.subtitleSource,
      subtitleFormat: data.subtitleFormat.present
          ? data.subtitleFormat.value
          : this.subtitleFormat,
      embeddedSubtitleTrack: data.embeddedSubtitleTrack.present
          ? data.embeddedSubtitleTrack.value
          : this.embeddedSubtitleTrack,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      lastPositionMs: data.lastPositionMs.present
          ? data.lastPositionMs.value
          : this.lastPositionMs,
      importedAt:
          data.importedAt.present ? data.importedAt.value : this.importedAt,
      playlistJson: data.playlistJson.present
          ? data.playlistJson.value
          : this.playlistJson,
      currentEpisode: data.currentEpisode.present
          ? data.currentEpisode.value
          : this.currentEpisode,
      audioTrackId: data.audioTrackId.present
          ? data.audioTrackId.value
          : this.audioTrackId,
      delayMs: data.delayMs.present ? data.delayMs.value : this.delayMs,
      completedAt:
          data.completedAt.present ? data.completedAt.value : this.completedAt,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VideoBookRow(')
          ..write('bookUid: $bookUid, ')
          ..write('title: $title, ')
          ..write('videoPath: $videoPath, ')
          ..write('subtitleSource: $subtitleSource, ')
          ..write('subtitleFormat: $subtitleFormat, ')
          ..write('embeddedSubtitleTrack: $embeddedSubtitleTrack, ')
          ..write('coverPath: $coverPath, ')
          ..write('lastPositionMs: $lastPositionMs, ')
          ..write('importedAt: $importedAt, ')
          ..write('playlistJson: $playlistJson, ')
          ..write('currentEpisode: $currentEpisode, ')
          ..write('audioTrackId: $audioTrackId, ')
          ..write('delayMs: $delayMs, ')
          ..write('completedAt: $completedAt, ')
          ..write('sourceId: $sourceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      bookUid,
      title,
      videoPath,
      subtitleSource,
      subtitleFormat,
      embeddedSubtitleTrack,
      coverPath,
      lastPositionMs,
      importedAt,
      playlistJson,
      currentEpisode,
      audioTrackId,
      delayMs,
      completedAt,
      sourceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoBookRow &&
          other.bookUid == this.bookUid &&
          other.title == this.title &&
          other.videoPath == this.videoPath &&
          other.subtitleSource == this.subtitleSource &&
          other.subtitleFormat == this.subtitleFormat &&
          other.embeddedSubtitleTrack == this.embeddedSubtitleTrack &&
          other.coverPath == this.coverPath &&
          other.lastPositionMs == this.lastPositionMs &&
          other.importedAt == this.importedAt &&
          other.playlistJson == this.playlistJson &&
          other.currentEpisode == this.currentEpisode &&
          other.audioTrackId == this.audioTrackId &&
          other.delayMs == this.delayMs &&
          other.completedAt == this.completedAt &&
          other.sourceId == this.sourceId);
}

class VideoBooksCompanion extends UpdateCompanion<VideoBookRow> {
  final Value<String> bookUid;
  final Value<String> title;
  final Value<String> videoPath;
  final Value<String?> subtitleSource;
  final Value<String?> subtitleFormat;
  final Value<int?> embeddedSubtitleTrack;
  final Value<String?> coverPath;
  final Value<int> lastPositionMs;
  final Value<DateTime?> importedAt;
  final Value<String?> playlistJson;
  final Value<int> currentEpisode;
  final Value<String?> audioTrackId;
  final Value<int> delayMs;
  final Value<DateTime?> completedAt;
  final Value<int?> sourceId;
  final Value<int> rowid;
  const VideoBooksCompanion({
    this.bookUid = const Value.absent(),
    this.title = const Value.absent(),
    this.videoPath = const Value.absent(),
    this.subtitleSource = const Value.absent(),
    this.subtitleFormat = const Value.absent(),
    this.embeddedSubtitleTrack = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.lastPositionMs = const Value.absent(),
    this.importedAt = const Value.absent(),
    this.playlistJson = const Value.absent(),
    this.currentEpisode = const Value.absent(),
    this.audioTrackId = const Value.absent(),
    this.delayMs = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VideoBooksCompanion.insert({
    required String bookUid,
    required String title,
    required String videoPath,
    this.subtitleSource = const Value.absent(),
    this.subtitleFormat = const Value.absent(),
    this.embeddedSubtitleTrack = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.lastPositionMs = const Value.absent(),
    this.importedAt = const Value.absent(),
    this.playlistJson = const Value.absent(),
    this.currentEpisode = const Value.absent(),
    this.audioTrackId = const Value.absent(),
    this.delayMs = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : bookUid = Value(bookUid),
        title = Value(title),
        videoPath = Value(videoPath);
  static Insertable<VideoBookRow> custom({
    Expression<String>? bookUid,
    Expression<String>? title,
    Expression<String>? videoPath,
    Expression<String>? subtitleSource,
    Expression<String>? subtitleFormat,
    Expression<int>? embeddedSubtitleTrack,
    Expression<String>? coverPath,
    Expression<int>? lastPositionMs,
    Expression<DateTime>? importedAt,
    Expression<String>? playlistJson,
    Expression<int>? currentEpisode,
    Expression<String>? audioTrackId,
    Expression<int>? delayMs,
    Expression<DateTime>? completedAt,
    Expression<int>? sourceId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookUid != null) 'book_uid': bookUid,
      if (title != null) 'title': title,
      if (videoPath != null) 'video_path': videoPath,
      if (subtitleSource != null) 'subtitle_source': subtitleSource,
      if (subtitleFormat != null) 'subtitle_format': subtitleFormat,
      if (embeddedSubtitleTrack != null)
        'embedded_subtitle_track': embeddedSubtitleTrack,
      if (coverPath != null) 'cover_path': coverPath,
      if (lastPositionMs != null) 'last_position_ms': lastPositionMs,
      if (importedAt != null) 'imported_at': importedAt,
      if (playlistJson != null) 'playlist_json': playlistJson,
      if (currentEpisode != null) 'current_episode': currentEpisode,
      if (audioTrackId != null) 'audio_track_id': audioTrackId,
      if (delayMs != null) 'delay_ms': delayMs,
      if (completedAt != null) 'completed_at': completedAt,
      if (sourceId != null) 'source_id': sourceId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VideoBooksCompanion copyWith(
      {Value<String>? bookUid,
      Value<String>? title,
      Value<String>? videoPath,
      Value<String?>? subtitleSource,
      Value<String?>? subtitleFormat,
      Value<int?>? embeddedSubtitleTrack,
      Value<String?>? coverPath,
      Value<int>? lastPositionMs,
      Value<DateTime?>? importedAt,
      Value<String?>? playlistJson,
      Value<int>? currentEpisode,
      Value<String?>? audioTrackId,
      Value<int>? delayMs,
      Value<DateTime?>? completedAt,
      Value<int?>? sourceId,
      Value<int>? rowid}) {
    return VideoBooksCompanion(
      bookUid: bookUid ?? this.bookUid,
      title: title ?? this.title,
      videoPath: videoPath ?? this.videoPath,
      subtitleSource: subtitleSource ?? this.subtitleSource,
      subtitleFormat: subtitleFormat ?? this.subtitleFormat,
      embeddedSubtitleTrack:
          embeddedSubtitleTrack ?? this.embeddedSubtitleTrack,
      coverPath: coverPath ?? this.coverPath,
      lastPositionMs: lastPositionMs ?? this.lastPositionMs,
      importedAt: importedAt ?? this.importedAt,
      playlistJson: playlistJson ?? this.playlistJson,
      currentEpisode: currentEpisode ?? this.currentEpisode,
      audioTrackId: audioTrackId ?? this.audioTrackId,
      delayMs: delayMs ?? this.delayMs,
      completedAt: completedAt ?? this.completedAt,
      sourceId: sourceId ?? this.sourceId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookUid.present) {
      map['book_uid'] = Variable<String>(bookUid.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (videoPath.present) {
      map['video_path'] = Variable<String>(videoPath.value);
    }
    if (subtitleSource.present) {
      map['subtitle_source'] = Variable<String>(subtitleSource.value);
    }
    if (subtitleFormat.present) {
      map['subtitle_format'] = Variable<String>(subtitleFormat.value);
    }
    if (embeddedSubtitleTrack.present) {
      map['embedded_subtitle_track'] =
          Variable<int>(embeddedSubtitleTrack.value);
    }
    if (coverPath.present) {
      map['cover_path'] = Variable<String>(coverPath.value);
    }
    if (lastPositionMs.present) {
      map['last_position_ms'] = Variable<int>(lastPositionMs.value);
    }
    if (importedAt.present) {
      map['imported_at'] = Variable<DateTime>(importedAt.value);
    }
    if (playlistJson.present) {
      map['playlist_json'] = Variable<String>(playlistJson.value);
    }
    if (currentEpisode.present) {
      map['current_episode'] = Variable<int>(currentEpisode.value);
    }
    if (audioTrackId.present) {
      map['audio_track_id'] = Variable<String>(audioTrackId.value);
    }
    if (delayMs.present) {
      map['delay_ms'] = Variable<int>(delayMs.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<int>(sourceId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VideoBooksCompanion(')
          ..write('bookUid: $bookUid, ')
          ..write('title: $title, ')
          ..write('videoPath: $videoPath, ')
          ..write('subtitleSource: $subtitleSource, ')
          ..write('subtitleFormat: $subtitleFormat, ')
          ..write('embeddedSubtitleTrack: $embeddedSubtitleTrack, ')
          ..write('coverPath: $coverPath, ')
          ..write('lastPositionMs: $lastPositionMs, ')
          ..write('importedAt: $importedAt, ')
          ..write('playlistJson: $playlistJson, ')
          ..write('currentEpisode: $currentEpisode, ')
          ..write('audioTrackId: $audioTrackId, ')
          ..write('delayMs: $delayMs, ')
          ..write('completedAt: $completedAt, ')
          ..write('sourceId: $sourceId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VideoBookTagMappingsTable extends VideoBookTagMappings
    with TableInfo<$VideoBookTagMappingsTable, VideoBookTagMappingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VideoBookTagMappingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _videoBookUidMeta =
      const VerificationMeta('videoBookUid');
  @override
  late final GeneratedColumn<String> videoBookUid = GeneratedColumn<String>(
      'video_book_uid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES video_books (book_uid) ON DELETE CASCADE'));
  static const VerificationMeta _tagIdMeta = const VerificationMeta('tagId');
  @override
  late final GeneratedColumn<int> tagId = GeneratedColumn<int>(
      'tag_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES book_tags (id) ON DELETE CASCADE'));
  @override
  List<GeneratedColumn> get $columns => [id, videoBookUid, tagId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'video_book_tag_mappings';
  @override
  VerificationContext validateIntegrity(
      Insertable<VideoBookTagMappingRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('video_book_uid')) {
      context.handle(
          _videoBookUidMeta,
          videoBookUid.isAcceptableOrUnknown(
              data['video_book_uid']!, _videoBookUidMeta));
    } else if (isInserting) {
      context.missing(_videoBookUidMeta);
    }
    if (data.containsKey('tag_id')) {
      context.handle(
          _tagIdMeta, tagId.isAcceptableOrUnknown(data['tag_id']!, _tagIdMeta));
    } else if (isInserting) {
      context.missing(_tagIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {videoBookUid, tagId},
      ];
  @override
  VideoBookTagMappingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VideoBookTagMappingRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      videoBookUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}video_book_uid'])!,
      tagId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tag_id'])!,
    );
  }

  @override
  $VideoBookTagMappingsTable createAlias(String alias) {
    return $VideoBookTagMappingsTable(attachedDatabase, alias);
  }
}

class VideoBookTagMappingRow extends DataClass
    implements Insertable<VideoBookTagMappingRow> {
  final int id;
  final String videoBookUid;
  final int tagId;
  const VideoBookTagMappingRow(
      {required this.id, required this.videoBookUid, required this.tagId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['video_book_uid'] = Variable<String>(videoBookUid);
    map['tag_id'] = Variable<int>(tagId);
    return map;
  }

  VideoBookTagMappingsCompanion toCompanion(bool nullToAbsent) {
    return VideoBookTagMappingsCompanion(
      id: Value(id),
      videoBookUid: Value(videoBookUid),
      tagId: Value(tagId),
    );
  }

  factory VideoBookTagMappingRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VideoBookTagMappingRow(
      id: serializer.fromJson<int>(json['id']),
      videoBookUid: serializer.fromJson<String>(json['videoBookUid']),
      tagId: serializer.fromJson<int>(json['tagId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'videoBookUid': serializer.toJson<String>(videoBookUid),
      'tagId': serializer.toJson<int>(tagId),
    };
  }

  VideoBookTagMappingRow copyWith(
          {int? id, String? videoBookUid, int? tagId}) =>
      VideoBookTagMappingRow(
        id: id ?? this.id,
        videoBookUid: videoBookUid ?? this.videoBookUid,
        tagId: tagId ?? this.tagId,
      );
  VideoBookTagMappingRow copyWithCompanion(VideoBookTagMappingsCompanion data) {
    return VideoBookTagMappingRow(
      id: data.id.present ? data.id.value : this.id,
      videoBookUid: data.videoBookUid.present
          ? data.videoBookUid.value
          : this.videoBookUid,
      tagId: data.tagId.present ? data.tagId.value : this.tagId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VideoBookTagMappingRow(')
          ..write('id: $id, ')
          ..write('videoBookUid: $videoBookUid, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, videoBookUid, tagId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoBookTagMappingRow &&
          other.id == this.id &&
          other.videoBookUid == this.videoBookUid &&
          other.tagId == this.tagId);
}

class VideoBookTagMappingsCompanion
    extends UpdateCompanion<VideoBookTagMappingRow> {
  final Value<int> id;
  final Value<String> videoBookUid;
  final Value<int> tagId;
  const VideoBookTagMappingsCompanion({
    this.id = const Value.absent(),
    this.videoBookUid = const Value.absent(),
    this.tagId = const Value.absent(),
  });
  VideoBookTagMappingsCompanion.insert({
    this.id = const Value.absent(),
    required String videoBookUid,
    required int tagId,
  })  : videoBookUid = Value(videoBookUid),
        tagId = Value(tagId);
  static Insertable<VideoBookTagMappingRow> custom({
    Expression<int>? id,
    Expression<String>? videoBookUid,
    Expression<int>? tagId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (videoBookUid != null) 'video_book_uid': videoBookUid,
      if (tagId != null) 'tag_id': tagId,
    });
  }

  VideoBookTagMappingsCompanion copyWith(
      {Value<int>? id, Value<String>? videoBookUid, Value<int>? tagId}) {
    return VideoBookTagMappingsCompanion(
      id: id ?? this.id,
      videoBookUid: videoBookUid ?? this.videoBookUid,
      tagId: tagId ?? this.tagId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (videoBookUid.present) {
      map['video_book_uid'] = Variable<String>(videoBookUid.value);
    }
    if (tagId.present) {
      map['tag_id'] = Variable<int>(tagId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VideoBookTagMappingsCompanion(')
          ..write('id: $id, ')
          ..write('videoBookUid: $videoBookUid, ')
          ..write('tagId: $tagId')
          ..write(')'))
        .toString();
  }
}

class $VideoWatchStatisticsTable extends VideoWatchStatistics
    with TableInfo<$VideoWatchStatisticsTable, VideoWatchStatisticRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VideoWatchStatisticsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _subtitleCharsMeta =
      const VerificationMeta('subtitleChars');
  @override
  late final GeneratedColumn<int> subtitleChars = GeneratedColumn<int>(
      'subtitle_chars', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _watchTimeMsMeta =
      const VerificationMeta('watchTimeMs');
  @override
  late final GeneratedColumn<int> watchTimeMs = GeneratedColumn<int>(
      'watch_time_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _lastModifiedMeta =
      const VerificationMeta('lastModified');
  @override
  late final GeneratedColumn<int> lastModified = GeneratedColumn<int>(
      'last_modified', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, title, dateKey, subtitleChars, watchTimeMs, lastModified];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'video_watch_statistics';
  @override
  VerificationContext validateIntegrity(
      Insertable<VideoWatchStatisticRow> instance,
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
    if (data.containsKey('subtitle_chars')) {
      context.handle(
          _subtitleCharsMeta,
          subtitleChars.isAcceptableOrUnknown(
              data['subtitle_chars']!, _subtitleCharsMeta));
    } else if (isInserting) {
      context.missing(_subtitleCharsMeta);
    }
    if (data.containsKey('watch_time_ms')) {
      context.handle(
          _watchTimeMsMeta,
          watchTimeMs.isAcceptableOrUnknown(
              data['watch_time_ms']!, _watchTimeMsMeta));
    } else if (isInserting) {
      context.missing(_watchTimeMsMeta);
    }
    if (data.containsKey('last_modified')) {
      context.handle(
          _lastModifiedMeta,
          lastModified.isAcceptableOrUnknown(
              data['last_modified']!, _lastModifiedMeta));
    } else if (isInserting) {
      context.missing(_lastModifiedMeta);
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
  VideoWatchStatisticRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VideoWatchStatisticRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      subtitleChars: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}subtitle_chars'])!,
      watchTimeMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}watch_time_ms'])!,
      lastModified: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_modified'])!,
    );
  }

  @override
  $VideoWatchStatisticsTable createAlias(String alias) {
    return $VideoWatchStatisticsTable(attachedDatabase, alias);
  }
}

class VideoWatchStatisticRow extends DataClass
    implements Insertable<VideoWatchStatisticRow> {
  final int id;
  final String title;
  final String dateKey;
  final int subtitleChars;
  final int watchTimeMs;
  final int lastModified;
  const VideoWatchStatisticRow(
      {required this.id,
      required this.title,
      required this.dateKey,
      required this.subtitleChars,
      required this.watchTimeMs,
      required this.lastModified});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['title'] = Variable<String>(title);
    map['date_key'] = Variable<String>(dateKey);
    map['subtitle_chars'] = Variable<int>(subtitleChars);
    map['watch_time_ms'] = Variable<int>(watchTimeMs);
    map['last_modified'] = Variable<int>(lastModified);
    return map;
  }

  VideoWatchStatisticsCompanion toCompanion(bool nullToAbsent) {
    return VideoWatchStatisticsCompanion(
      id: Value(id),
      title: Value(title),
      dateKey: Value(dateKey),
      subtitleChars: Value(subtitleChars),
      watchTimeMs: Value(watchTimeMs),
      lastModified: Value(lastModified),
    );
  }

  factory VideoWatchStatisticRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VideoWatchStatisticRow(
      id: serializer.fromJson<int>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      subtitleChars: serializer.fromJson<int>(json['subtitleChars']),
      watchTimeMs: serializer.fromJson<int>(json['watchTimeMs']),
      lastModified: serializer.fromJson<int>(json['lastModified']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'title': serializer.toJson<String>(title),
      'dateKey': serializer.toJson<String>(dateKey),
      'subtitleChars': serializer.toJson<int>(subtitleChars),
      'watchTimeMs': serializer.toJson<int>(watchTimeMs),
      'lastModified': serializer.toJson<int>(lastModified),
    };
  }

  VideoWatchStatisticRow copyWith(
          {int? id,
          String? title,
          String? dateKey,
          int? subtitleChars,
          int? watchTimeMs,
          int? lastModified}) =>
      VideoWatchStatisticRow(
        id: id ?? this.id,
        title: title ?? this.title,
        dateKey: dateKey ?? this.dateKey,
        subtitleChars: subtitleChars ?? this.subtitleChars,
        watchTimeMs: watchTimeMs ?? this.watchTimeMs,
        lastModified: lastModified ?? this.lastModified,
      );
  VideoWatchStatisticRow copyWithCompanion(VideoWatchStatisticsCompanion data) {
    return VideoWatchStatisticRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      subtitleChars: data.subtitleChars.present
          ? data.subtitleChars.value
          : this.subtitleChars,
      watchTimeMs:
          data.watchTimeMs.present ? data.watchTimeMs.value : this.watchTimeMs,
      lastModified: data.lastModified.present
          ? data.lastModified.value
          : this.lastModified,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VideoWatchStatisticRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('dateKey: $dateKey, ')
          ..write('subtitleChars: $subtitleChars, ')
          ..write('watchTimeMs: $watchTimeMs, ')
          ..write('lastModified: $lastModified')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, title, dateKey, subtitleChars, watchTimeMs, lastModified);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoWatchStatisticRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.dateKey == this.dateKey &&
          other.subtitleChars == this.subtitleChars &&
          other.watchTimeMs == this.watchTimeMs &&
          other.lastModified == this.lastModified);
}

class VideoWatchStatisticsCompanion
    extends UpdateCompanion<VideoWatchStatisticRow> {
  final Value<int> id;
  final Value<String> title;
  final Value<String> dateKey;
  final Value<int> subtitleChars;
  final Value<int> watchTimeMs;
  final Value<int> lastModified;
  const VideoWatchStatisticsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.subtitleChars = const Value.absent(),
    this.watchTimeMs = const Value.absent(),
    this.lastModified = const Value.absent(),
  });
  VideoWatchStatisticsCompanion.insert({
    this.id = const Value.absent(),
    required String title,
    required String dateKey,
    required int subtitleChars,
    required int watchTimeMs,
    required int lastModified,
  })  : title = Value(title),
        dateKey = Value(dateKey),
        subtitleChars = Value(subtitleChars),
        watchTimeMs = Value(watchTimeMs),
        lastModified = Value(lastModified);
  static Insertable<VideoWatchStatisticRow> custom({
    Expression<int>? id,
    Expression<String>? title,
    Expression<String>? dateKey,
    Expression<int>? subtitleChars,
    Expression<int>? watchTimeMs,
    Expression<int>? lastModified,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (dateKey != null) 'date_key': dateKey,
      if (subtitleChars != null) 'subtitle_chars': subtitleChars,
      if (watchTimeMs != null) 'watch_time_ms': watchTimeMs,
      if (lastModified != null) 'last_modified': lastModified,
    });
  }

  VideoWatchStatisticsCompanion copyWith(
      {Value<int>? id,
      Value<String>? title,
      Value<String>? dateKey,
      Value<int>? subtitleChars,
      Value<int>? watchTimeMs,
      Value<int>? lastModified}) {
    return VideoWatchStatisticsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      dateKey: dateKey ?? this.dateKey,
      subtitleChars: subtitleChars ?? this.subtitleChars,
      watchTimeMs: watchTimeMs ?? this.watchTimeMs,
      lastModified: lastModified ?? this.lastModified,
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
    if (subtitleChars.present) {
      map['subtitle_chars'] = Variable<int>(subtitleChars.value);
    }
    if (watchTimeMs.present) {
      map['watch_time_ms'] = Variable<int>(watchTimeMs.value);
    }
    if (lastModified.present) {
      map['last_modified'] = Variable<int>(lastModified.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VideoWatchStatisticsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('dateKey: $dateKey, ')
          ..write('subtitleChars: $subtitleChars, ')
          ..write('watchTimeMs: $watchTimeMs, ')
          ..write('lastModified: $lastModified')
          ..write(')'))
        .toString();
  }
}

class $VideoHourlyLogsTable extends VideoHourlyLogs
    with TableInfo<$VideoHourlyLogsTable, VideoHourlyLogRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VideoHourlyLogsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _watchTimeMsMeta =
      const VerificationMeta('watchTimeMs');
  @override
  late final GeneratedColumn<int> watchTimeMs = GeneratedColumn<int>(
      'watch_time_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, dateKey, hour, watchTimeMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'video_hourly_logs';
  @override
  VerificationContext validateIntegrity(Insertable<VideoHourlyLogRow> instance,
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
    if (data.containsKey('watch_time_ms')) {
      context.handle(
          _watchTimeMsMeta,
          watchTimeMs.isAcceptableOrUnknown(
              data['watch_time_ms']!, _watchTimeMsMeta));
    } else if (isInserting) {
      context.missing(_watchTimeMsMeta);
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
  VideoHourlyLogRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VideoHourlyLogRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      hour: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}hour'])!,
      watchTimeMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}watch_time_ms'])!,
    );
  }

  @override
  $VideoHourlyLogsTable createAlias(String alias) {
    return $VideoHourlyLogsTable(attachedDatabase, alias);
  }
}

class VideoHourlyLogRow extends DataClass
    implements Insertable<VideoHourlyLogRow> {
  final int id;
  final String dateKey;
  final int hour;
  final int watchTimeMs;
  const VideoHourlyLogRow(
      {required this.id,
      required this.dateKey,
      required this.hour,
      required this.watchTimeMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['date_key'] = Variable<String>(dateKey);
    map['hour'] = Variable<int>(hour);
    map['watch_time_ms'] = Variable<int>(watchTimeMs);
    return map;
  }

  VideoHourlyLogsCompanion toCompanion(bool nullToAbsent) {
    return VideoHourlyLogsCompanion(
      id: Value(id),
      dateKey: Value(dateKey),
      hour: Value(hour),
      watchTimeMs: Value(watchTimeMs),
    );
  }

  factory VideoHourlyLogRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VideoHourlyLogRow(
      id: serializer.fromJson<int>(json['id']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      hour: serializer.fromJson<int>(json['hour']),
      watchTimeMs: serializer.fromJson<int>(json['watchTimeMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'dateKey': serializer.toJson<String>(dateKey),
      'hour': serializer.toJson<int>(hour),
      'watchTimeMs': serializer.toJson<int>(watchTimeMs),
    };
  }

  VideoHourlyLogRow copyWith(
          {int? id, String? dateKey, int? hour, int? watchTimeMs}) =>
      VideoHourlyLogRow(
        id: id ?? this.id,
        dateKey: dateKey ?? this.dateKey,
        hour: hour ?? this.hour,
        watchTimeMs: watchTimeMs ?? this.watchTimeMs,
      );
  VideoHourlyLogRow copyWithCompanion(VideoHourlyLogsCompanion data) {
    return VideoHourlyLogRow(
      id: data.id.present ? data.id.value : this.id,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      hour: data.hour.present ? data.hour.value : this.hour,
      watchTimeMs:
          data.watchTimeMs.present ? data.watchTimeMs.value : this.watchTimeMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VideoHourlyLogRow(')
          ..write('id: $id, ')
          ..write('dateKey: $dateKey, ')
          ..write('hour: $hour, ')
          ..write('watchTimeMs: $watchTimeMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, dateKey, hour, watchTimeMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoHourlyLogRow &&
          other.id == this.id &&
          other.dateKey == this.dateKey &&
          other.hour == this.hour &&
          other.watchTimeMs == this.watchTimeMs);
}

class VideoHourlyLogsCompanion extends UpdateCompanion<VideoHourlyLogRow> {
  final Value<int> id;
  final Value<String> dateKey;
  final Value<int> hour;
  final Value<int> watchTimeMs;
  const VideoHourlyLogsCompanion({
    this.id = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.hour = const Value.absent(),
    this.watchTimeMs = const Value.absent(),
  });
  VideoHourlyLogsCompanion.insert({
    this.id = const Value.absent(),
    required String dateKey,
    required int hour,
    required int watchTimeMs,
  })  : dateKey = Value(dateKey),
        hour = Value(hour),
        watchTimeMs = Value(watchTimeMs);
  static Insertable<VideoHourlyLogRow> custom({
    Expression<int>? id,
    Expression<String>? dateKey,
    Expression<int>? hour,
    Expression<int>? watchTimeMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (dateKey != null) 'date_key': dateKey,
      if (hour != null) 'hour': hour,
      if (watchTimeMs != null) 'watch_time_ms': watchTimeMs,
    });
  }

  VideoHourlyLogsCompanion copyWith(
      {Value<int>? id,
      Value<String>? dateKey,
      Value<int>? hour,
      Value<int>? watchTimeMs}) {
    return VideoHourlyLogsCompanion(
      id: id ?? this.id,
      dateKey: dateKey ?? this.dateKey,
      hour: hour ?? this.hour,
      watchTimeMs: watchTimeMs ?? this.watchTimeMs,
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
    if (watchTimeMs.present) {
      map['watch_time_ms'] = Variable<int>(watchTimeMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VideoHourlyLogsCompanion(')
          ..write('id: $id, ')
          ..write('dateKey: $dateKey, ')
          ..write('hour: $hour, ')
          ..write('watchTimeMs: $watchTimeMs')
          ..write(')'))
        .toString();
  }
}

class $FavoriteWordsTable extends FavoriteWords
    with TableInfo<$FavoriteWordsTable, FavoriteWordRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FavoriteWordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _expressionMeta =
      const VerificationMeta('expression');
  @override
  late final GeneratedColumn<String> expression = GeneratedColumn<String>(
      'expression', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _readingMeta =
      const VerificationMeta('reading');
  @override
  late final GeneratedColumn<String> reading = GeneratedColumn<String>(
      'reading', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _glossaryMeta =
      const VerificationMeta('glossary');
  @override
  late final GeneratedColumn<String> glossary = GeneratedColumn<String>(
      'glossary', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _sourceTypeMeta =
      const VerificationMeta('sourceType');
  @override
  late final GeneratedColumn<String> sourceType = GeneratedColumn<String>(
      'source_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, expression, reading, glossary, sourceType, dateKey, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'favorite_words';
  @override
  VerificationContext validateIntegrity(Insertable<FavoriteWordRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('expression')) {
      context.handle(
          _expressionMeta,
          expression.isAcceptableOrUnknown(
              data['expression']!, _expressionMeta));
    } else if (isInserting) {
      context.missing(_expressionMeta);
    }
    if (data.containsKey('reading')) {
      context.handle(_readingMeta,
          reading.isAcceptableOrUnknown(data['reading']!, _readingMeta));
    }
    if (data.containsKey('glossary')) {
      context.handle(_glossaryMeta,
          glossary.isAcceptableOrUnknown(data['glossary']!, _glossaryMeta));
    }
    if (data.containsKey('source_type')) {
      context.handle(
          _sourceTypeMeta,
          sourceType.isAcceptableOrUnknown(
              data['source_type']!, _sourceTypeMeta));
    } else if (isInserting) {
      context.missing(_sourceTypeMeta);
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {expression, reading, sourceType},
      ];
  @override
  FavoriteWordRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FavoriteWordRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      expression: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}expression'])!,
      reading: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reading'])!,
      glossary: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}glossary'])!,
      sourceType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_type'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $FavoriteWordsTable createAlias(String alias) {
    return $FavoriteWordsTable(attachedDatabase, alias);
  }
}

class FavoriteWordRow extends DataClass implements Insertable<FavoriteWordRow> {
  final int id;
  final String expression;
  final String reading;
  final String glossary;
  final String sourceType;
  final String dateKey;
  final int createdAt;
  const FavoriteWordRow(
      {required this.id,
      required this.expression,
      required this.reading,
      required this.glossary,
      required this.sourceType,
      required this.dateKey,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['expression'] = Variable<String>(expression);
    map['reading'] = Variable<String>(reading);
    map['glossary'] = Variable<String>(glossary);
    map['source_type'] = Variable<String>(sourceType);
    map['date_key'] = Variable<String>(dateKey);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  FavoriteWordsCompanion toCompanion(bool nullToAbsent) {
    return FavoriteWordsCompanion(
      id: Value(id),
      expression: Value(expression),
      reading: Value(reading),
      glossary: Value(glossary),
      sourceType: Value(sourceType),
      dateKey: Value(dateKey),
      createdAt: Value(createdAt),
    );
  }

  factory FavoriteWordRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FavoriteWordRow(
      id: serializer.fromJson<int>(json['id']),
      expression: serializer.fromJson<String>(json['expression']),
      reading: serializer.fromJson<String>(json['reading']),
      glossary: serializer.fromJson<String>(json['glossary']),
      sourceType: serializer.fromJson<String>(json['sourceType']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'expression': serializer.toJson<String>(expression),
      'reading': serializer.toJson<String>(reading),
      'glossary': serializer.toJson<String>(glossary),
      'sourceType': serializer.toJson<String>(sourceType),
      'dateKey': serializer.toJson<String>(dateKey),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  FavoriteWordRow copyWith(
          {int? id,
          String? expression,
          String? reading,
          String? glossary,
          String? sourceType,
          String? dateKey,
          int? createdAt}) =>
      FavoriteWordRow(
        id: id ?? this.id,
        expression: expression ?? this.expression,
        reading: reading ?? this.reading,
        glossary: glossary ?? this.glossary,
        sourceType: sourceType ?? this.sourceType,
        dateKey: dateKey ?? this.dateKey,
        createdAt: createdAt ?? this.createdAt,
      );
  FavoriteWordRow copyWithCompanion(FavoriteWordsCompanion data) {
    return FavoriteWordRow(
      id: data.id.present ? data.id.value : this.id,
      expression:
          data.expression.present ? data.expression.value : this.expression,
      reading: data.reading.present ? data.reading.value : this.reading,
      glossary: data.glossary.present ? data.glossary.value : this.glossary,
      sourceType:
          data.sourceType.present ? data.sourceType.value : this.sourceType,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FavoriteWordRow(')
          ..write('id: $id, ')
          ..write('expression: $expression, ')
          ..write('reading: $reading, ')
          ..write('glossary: $glossary, ')
          ..write('sourceType: $sourceType, ')
          ..write('dateKey: $dateKey, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, expression, reading, glossary, sourceType, dateKey, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FavoriteWordRow &&
          other.id == this.id &&
          other.expression == this.expression &&
          other.reading == this.reading &&
          other.glossary == this.glossary &&
          other.sourceType == this.sourceType &&
          other.dateKey == this.dateKey &&
          other.createdAt == this.createdAt);
}

class FavoriteWordsCompanion extends UpdateCompanion<FavoriteWordRow> {
  final Value<int> id;
  final Value<String> expression;
  final Value<String> reading;
  final Value<String> glossary;
  final Value<String> sourceType;
  final Value<String> dateKey;
  final Value<int> createdAt;
  const FavoriteWordsCompanion({
    this.id = const Value.absent(),
    this.expression = const Value.absent(),
    this.reading = const Value.absent(),
    this.glossary = const Value.absent(),
    this.sourceType = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  FavoriteWordsCompanion.insert({
    this.id = const Value.absent(),
    required String expression,
    this.reading = const Value.absent(),
    this.glossary = const Value.absent(),
    required String sourceType,
    required String dateKey,
    required int createdAt,
  })  : expression = Value(expression),
        sourceType = Value(sourceType),
        dateKey = Value(dateKey),
        createdAt = Value(createdAt);
  static Insertable<FavoriteWordRow> custom({
    Expression<int>? id,
    Expression<String>? expression,
    Expression<String>? reading,
    Expression<String>? glossary,
    Expression<String>? sourceType,
    Expression<String>? dateKey,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (expression != null) 'expression': expression,
      if (reading != null) 'reading': reading,
      if (glossary != null) 'glossary': glossary,
      if (sourceType != null) 'source_type': sourceType,
      if (dateKey != null) 'date_key': dateKey,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  FavoriteWordsCompanion copyWith(
      {Value<int>? id,
      Value<String>? expression,
      Value<String>? reading,
      Value<String>? glossary,
      Value<String>? sourceType,
      Value<String>? dateKey,
      Value<int>? createdAt}) {
    return FavoriteWordsCompanion(
      id: id ?? this.id,
      expression: expression ?? this.expression,
      reading: reading ?? this.reading,
      glossary: glossary ?? this.glossary,
      sourceType: sourceType ?? this.sourceType,
      dateKey: dateKey ?? this.dateKey,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (expression.present) {
      map['expression'] = Variable<String>(expression.value);
    }
    if (reading.present) {
      map['reading'] = Variable<String>(reading.value);
    }
    if (glossary.present) {
      map['glossary'] = Variable<String>(glossary.value);
    }
    if (sourceType.present) {
      map['source_type'] = Variable<String>(sourceType.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FavoriteWordsCompanion(')
          ..write('id: $id, ')
          ..write('expression: $expression, ')
          ..write('reading: $reading, ')
          ..write('glossary: $glossary, ')
          ..write('sourceType: $sourceType, ')
          ..write('dateKey: $dateKey, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $MiningStatisticsTable extends MiningStatistics
    with TableInfo<$MiningStatisticsTable, MiningStatisticRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MiningStatisticsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _sourceTypeMeta =
      const VerificationMeta('sourceType');
  @override
  late final GeneratedColumn<String> sourceType = GeneratedColumn<String>(
      'source_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _countMeta = const VerificationMeta('count');
  @override
  late final GeneratedColumn<int> count = GeneratedColumn<int>(
      'count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [id, sourceType, dateKey, count];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mining_statistics';
  @override
  VerificationContext validateIntegrity(Insertable<MiningStatisticRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('source_type')) {
      context.handle(
          _sourceTypeMeta,
          sourceType.isAcceptableOrUnknown(
              data['source_type']!, _sourceTypeMeta));
    } else if (isInserting) {
      context.missing(_sourceTypeMeta);
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('count')) {
      context.handle(
          _countMeta, count.isAcceptableOrUnknown(data['count']!, _countMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {sourceType, dateKey},
      ];
  @override
  MiningStatisticRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MiningStatisticRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      sourceType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_type'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      count: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}count'])!,
    );
  }

  @override
  $MiningStatisticsTable createAlias(String alias) {
    return $MiningStatisticsTable(attachedDatabase, alias);
  }
}

class MiningStatisticRow extends DataClass
    implements Insertable<MiningStatisticRow> {
  final int id;
  final String sourceType;
  final String dateKey;
  final int count;
  const MiningStatisticRow(
      {required this.id,
      required this.sourceType,
      required this.dateKey,
      required this.count});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['source_type'] = Variable<String>(sourceType);
    map['date_key'] = Variable<String>(dateKey);
    map['count'] = Variable<int>(count);
    return map;
  }

  MiningStatisticsCompanion toCompanion(bool nullToAbsent) {
    return MiningStatisticsCompanion(
      id: Value(id),
      sourceType: Value(sourceType),
      dateKey: Value(dateKey),
      count: Value(count),
    );
  }

  factory MiningStatisticRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MiningStatisticRow(
      id: serializer.fromJson<int>(json['id']),
      sourceType: serializer.fromJson<String>(json['sourceType']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      count: serializer.fromJson<int>(json['count']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sourceType': serializer.toJson<String>(sourceType),
      'dateKey': serializer.toJson<String>(dateKey),
      'count': serializer.toJson<int>(count),
    };
  }

  MiningStatisticRow copyWith(
          {int? id, String? sourceType, String? dateKey, int? count}) =>
      MiningStatisticRow(
        id: id ?? this.id,
        sourceType: sourceType ?? this.sourceType,
        dateKey: dateKey ?? this.dateKey,
        count: count ?? this.count,
      );
  MiningStatisticRow copyWithCompanion(MiningStatisticsCompanion data) {
    return MiningStatisticRow(
      id: data.id.present ? data.id.value : this.id,
      sourceType:
          data.sourceType.present ? data.sourceType.value : this.sourceType,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      count: data.count.present ? data.count.value : this.count,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MiningStatisticRow(')
          ..write('id: $id, ')
          ..write('sourceType: $sourceType, ')
          ..write('dateKey: $dateKey, ')
          ..write('count: $count')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, sourceType, dateKey, count);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MiningStatisticRow &&
          other.id == this.id &&
          other.sourceType == this.sourceType &&
          other.dateKey == this.dateKey &&
          other.count == this.count);
}

class MiningStatisticsCompanion extends UpdateCompanion<MiningStatisticRow> {
  final Value<int> id;
  final Value<String> sourceType;
  final Value<String> dateKey;
  final Value<int> count;
  const MiningStatisticsCompanion({
    this.id = const Value.absent(),
    this.sourceType = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.count = const Value.absent(),
  });
  MiningStatisticsCompanion.insert({
    this.id = const Value.absent(),
    required String sourceType,
    required String dateKey,
    this.count = const Value.absent(),
  })  : sourceType = Value(sourceType),
        dateKey = Value(dateKey);
  static Insertable<MiningStatisticRow> custom({
    Expression<int>? id,
    Expression<String>? sourceType,
    Expression<String>? dateKey,
    Expression<int>? count,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceType != null) 'source_type': sourceType,
      if (dateKey != null) 'date_key': dateKey,
      if (count != null) 'count': count,
    });
  }

  MiningStatisticsCompanion copyWith(
      {Value<int>? id,
      Value<String>? sourceType,
      Value<String>? dateKey,
      Value<int>? count}) {
    return MiningStatisticsCompanion(
      id: id ?? this.id,
      sourceType: sourceType ?? this.sourceType,
      dateKey: dateKey ?? this.dateKey,
      count: count ?? this.count,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sourceType.present) {
      map['source_type'] = Variable<String>(sourceType.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (count.present) {
      map['count'] = Variable<int>(count.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MiningStatisticsCompanion(')
          ..write('id: $id, ')
          ..write('sourceType: $sourceType, ')
          ..write('dateKey: $dateKey, ')
          ..write('count: $count')
          ..write(')'))
        .toString();
  }
}

class $MinedSentencesTable extends MinedSentences
    with TableInfo<$MinedSentencesTable, MinedSentenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MinedSentencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _expressionMeta =
      const VerificationMeta('expression');
  @override
  late final GeneratedColumn<String> expression = GeneratedColumn<String>(
      'expression', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _readingMeta =
      const VerificationMeta('reading');
  @override
  late final GeneratedColumn<String> reading = GeneratedColumn<String>(
      'reading', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _glossaryMeta =
      const VerificationMeta('glossary');
  @override
  late final GeneratedColumn<String> glossary = GeneratedColumn<String>(
      'glossary', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _sentenceMeta =
      const VerificationMeta('sentence');
  @override
  late final GeneratedColumn<String> sentence = GeneratedColumn<String>(
      'sentence', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _documentTitleMeta =
      const VerificationMeta('documentTitle');
  @override
  late final GeneratedColumn<String> documentTitle = GeneratedColumn<String>(
      'document_title', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _chapterLabelMeta =
      const VerificationMeta('chapterLabel');
  @override
  late final GeneratedColumn<String> chapterLabel = GeneratedColumn<String>(
      'chapter_label', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _bookKeyMeta =
      const VerificationMeta('bookKey');
  @override
  late final GeneratedColumn<String> bookKey = GeneratedColumn<String>(
      'book_key', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sectionIndexMeta =
      const VerificationMeta('sectionIndex');
  @override
  late final GeneratedColumn<int> sectionIndex = GeneratedColumn<int>(
      'section_index', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _normCharOffsetMeta =
      const VerificationMeta('normCharOffset');
  @override
  late final GeneratedColumn<int> normCharOffset = GeneratedColumn<int>(
      'norm_char_offset', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _normCharLengthMeta =
      const VerificationMeta('normCharLength');
  @override
  late final GeneratedColumn<int> normCharLength = GeneratedColumn<int>(
      'norm_char_length', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _noteIdMeta = const VerificationMeta('noteId');
  @override
  late final GeneratedColumn<int> noteId = GeneratedColumn<int>(
      'note_id', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        expression,
        reading,
        glossary,
        sentence,
        source,
        documentTitle,
        chapterLabel,
        bookKey,
        sectionIndex,
        normCharOffset,
        normCharLength,
        noteId,
        dateKey,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mined_sentences';
  @override
  VerificationContext validateIntegrity(Insertable<MinedSentenceRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('expression')) {
      context.handle(
          _expressionMeta,
          expression.isAcceptableOrUnknown(
              data['expression']!, _expressionMeta));
    }
    if (data.containsKey('reading')) {
      context.handle(_readingMeta,
          reading.isAcceptableOrUnknown(data['reading']!, _readingMeta));
    }
    if (data.containsKey('glossary')) {
      context.handle(_glossaryMeta,
          glossary.isAcceptableOrUnknown(data['glossary']!, _glossaryMeta));
    }
    if (data.containsKey('sentence')) {
      context.handle(_sentenceMeta,
          sentence.isAcceptableOrUnknown(data['sentence']!, _sentenceMeta));
    }
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('document_title')) {
      context.handle(
          _documentTitleMeta,
          documentTitle.isAcceptableOrUnknown(
              data['document_title']!, _documentTitleMeta));
    }
    if (data.containsKey('chapter_label')) {
      context.handle(
          _chapterLabelMeta,
          chapterLabel.isAcceptableOrUnknown(
              data['chapter_label']!, _chapterLabelMeta));
    }
    if (data.containsKey('book_key')) {
      context.handle(_bookKeyMeta,
          bookKey.isAcceptableOrUnknown(data['book_key']!, _bookKeyMeta));
    }
    if (data.containsKey('section_index')) {
      context.handle(
          _sectionIndexMeta,
          sectionIndex.isAcceptableOrUnknown(
              data['section_index']!, _sectionIndexMeta));
    }
    if (data.containsKey('norm_char_offset')) {
      context.handle(
          _normCharOffsetMeta,
          normCharOffset.isAcceptableOrUnknown(
              data['norm_char_offset']!, _normCharOffsetMeta));
    }
    if (data.containsKey('norm_char_length')) {
      context.handle(
          _normCharLengthMeta,
          normCharLength.isAcceptableOrUnknown(
              data['norm_char_length']!, _normCharLengthMeta));
    }
    if (data.containsKey('note_id')) {
      context.handle(_noteIdMeta,
          noteId.isAcceptableOrUnknown(data['note_id']!, _noteIdMeta));
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MinedSentenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MinedSentenceRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      expression: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}expression'])!,
      reading: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reading'])!,
      glossary: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}glossary'])!,
      sentence: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sentence'])!,
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source'])!,
      documentTitle: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}document_title']),
      chapterLabel: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}chapter_label']),
      bookKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}book_key']),
      sectionIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}section_index']),
      normCharOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}norm_char_offset']),
      normCharLength: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}norm_char_length']),
      noteId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}note_id']),
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MinedSentencesTable createAlias(String alias) {
    return $MinedSentencesTable(attachedDatabase, alias);
  }
}

class MinedSentenceRow extends DataClass
    implements Insertable<MinedSentenceRow> {
  final int id;
  final String expression;
  final String reading;
  final String glossary;
  final String sentence;

  /// 跳转/分流来源标识，与 `kFavoriteSentenceSourceBook` / `Video` 等同值（'book' |
  /// 'video' | 'audiobook' | 'lyrics'）。统计语义（book/video 桶）也由它派生。
  final String source;
  final String? documentTitle;
  final String? chapterLabel;

  /// 定位锚点（与收藏句同构）：书内是 bookKey，视频是 bookUid。
  final String? bookKey;
  final int? sectionIndex;

  /// 书内是归一化字符偏移；视频来源里复用为 cue 起点 ms（与收藏句一致）。
  final int? normCharOffset;

  /// 视频来源里复用为 cue 时长 ms（书内为选区长度）。
  final int? normCharLength;

  /// AnkiConnect 成功制卡带回的 note id；AnkiDroid 恒 null。
  final int? noteId;
  final String dateKey;
  final int createdAt;
  const MinedSentenceRow(
      {required this.id,
      required this.expression,
      required this.reading,
      required this.glossary,
      required this.sentence,
      required this.source,
      this.documentTitle,
      this.chapterLabel,
      this.bookKey,
      this.sectionIndex,
      this.normCharOffset,
      this.normCharLength,
      this.noteId,
      required this.dateKey,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['expression'] = Variable<String>(expression);
    map['reading'] = Variable<String>(reading);
    map['glossary'] = Variable<String>(glossary);
    map['sentence'] = Variable<String>(sentence);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || documentTitle != null) {
      map['document_title'] = Variable<String>(documentTitle);
    }
    if (!nullToAbsent || chapterLabel != null) {
      map['chapter_label'] = Variable<String>(chapterLabel);
    }
    if (!nullToAbsent || bookKey != null) {
      map['book_key'] = Variable<String>(bookKey);
    }
    if (!nullToAbsent || sectionIndex != null) {
      map['section_index'] = Variable<int>(sectionIndex);
    }
    if (!nullToAbsent || normCharOffset != null) {
      map['norm_char_offset'] = Variable<int>(normCharOffset);
    }
    if (!nullToAbsent || normCharLength != null) {
      map['norm_char_length'] = Variable<int>(normCharLength);
    }
    if (!nullToAbsent || noteId != null) {
      map['note_id'] = Variable<int>(noteId);
    }
    map['date_key'] = Variable<String>(dateKey);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MinedSentencesCompanion toCompanion(bool nullToAbsent) {
    return MinedSentencesCompanion(
      id: Value(id),
      expression: Value(expression),
      reading: Value(reading),
      glossary: Value(glossary),
      sentence: Value(sentence),
      source: Value(source),
      documentTitle: documentTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(documentTitle),
      chapterLabel: chapterLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(chapterLabel),
      bookKey: bookKey == null && nullToAbsent
          ? const Value.absent()
          : Value(bookKey),
      sectionIndex: sectionIndex == null && nullToAbsent
          ? const Value.absent()
          : Value(sectionIndex),
      normCharOffset: normCharOffset == null && nullToAbsent
          ? const Value.absent()
          : Value(normCharOffset),
      normCharLength: normCharLength == null && nullToAbsent
          ? const Value.absent()
          : Value(normCharLength),
      noteId:
          noteId == null && nullToAbsent ? const Value.absent() : Value(noteId),
      dateKey: Value(dateKey),
      createdAt: Value(createdAt),
    );
  }

  factory MinedSentenceRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MinedSentenceRow(
      id: serializer.fromJson<int>(json['id']),
      expression: serializer.fromJson<String>(json['expression']),
      reading: serializer.fromJson<String>(json['reading']),
      glossary: serializer.fromJson<String>(json['glossary']),
      sentence: serializer.fromJson<String>(json['sentence']),
      source: serializer.fromJson<String>(json['source']),
      documentTitle: serializer.fromJson<String?>(json['documentTitle']),
      chapterLabel: serializer.fromJson<String?>(json['chapterLabel']),
      bookKey: serializer.fromJson<String?>(json['bookKey']),
      sectionIndex: serializer.fromJson<int?>(json['sectionIndex']),
      normCharOffset: serializer.fromJson<int?>(json['normCharOffset']),
      normCharLength: serializer.fromJson<int?>(json['normCharLength']),
      noteId: serializer.fromJson<int?>(json['noteId']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'expression': serializer.toJson<String>(expression),
      'reading': serializer.toJson<String>(reading),
      'glossary': serializer.toJson<String>(glossary),
      'sentence': serializer.toJson<String>(sentence),
      'source': serializer.toJson<String>(source),
      'documentTitle': serializer.toJson<String?>(documentTitle),
      'chapterLabel': serializer.toJson<String?>(chapterLabel),
      'bookKey': serializer.toJson<String?>(bookKey),
      'sectionIndex': serializer.toJson<int?>(sectionIndex),
      'normCharOffset': serializer.toJson<int?>(normCharOffset),
      'normCharLength': serializer.toJson<int?>(normCharLength),
      'noteId': serializer.toJson<int?>(noteId),
      'dateKey': serializer.toJson<String>(dateKey),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  MinedSentenceRow copyWith(
          {int? id,
          String? expression,
          String? reading,
          String? glossary,
          String? sentence,
          String? source,
          Value<String?> documentTitle = const Value.absent(),
          Value<String?> chapterLabel = const Value.absent(),
          Value<String?> bookKey = const Value.absent(),
          Value<int?> sectionIndex = const Value.absent(),
          Value<int?> normCharOffset = const Value.absent(),
          Value<int?> normCharLength = const Value.absent(),
          Value<int?> noteId = const Value.absent(),
          String? dateKey,
          int? createdAt}) =>
      MinedSentenceRow(
        id: id ?? this.id,
        expression: expression ?? this.expression,
        reading: reading ?? this.reading,
        glossary: glossary ?? this.glossary,
        sentence: sentence ?? this.sentence,
        source: source ?? this.source,
        documentTitle:
            documentTitle.present ? documentTitle.value : this.documentTitle,
        chapterLabel:
            chapterLabel.present ? chapterLabel.value : this.chapterLabel,
        bookKey: bookKey.present ? bookKey.value : this.bookKey,
        sectionIndex:
            sectionIndex.present ? sectionIndex.value : this.sectionIndex,
        normCharOffset:
            normCharOffset.present ? normCharOffset.value : this.normCharOffset,
        normCharLength:
            normCharLength.present ? normCharLength.value : this.normCharLength,
        noteId: noteId.present ? noteId.value : this.noteId,
        dateKey: dateKey ?? this.dateKey,
        createdAt: createdAt ?? this.createdAt,
      );
  MinedSentenceRow copyWithCompanion(MinedSentencesCompanion data) {
    return MinedSentenceRow(
      id: data.id.present ? data.id.value : this.id,
      expression:
          data.expression.present ? data.expression.value : this.expression,
      reading: data.reading.present ? data.reading.value : this.reading,
      glossary: data.glossary.present ? data.glossary.value : this.glossary,
      sentence: data.sentence.present ? data.sentence.value : this.sentence,
      source: data.source.present ? data.source.value : this.source,
      documentTitle: data.documentTitle.present
          ? data.documentTitle.value
          : this.documentTitle,
      chapterLabel: data.chapterLabel.present
          ? data.chapterLabel.value
          : this.chapterLabel,
      bookKey: data.bookKey.present ? data.bookKey.value : this.bookKey,
      sectionIndex: data.sectionIndex.present
          ? data.sectionIndex.value
          : this.sectionIndex,
      normCharOffset: data.normCharOffset.present
          ? data.normCharOffset.value
          : this.normCharOffset,
      normCharLength: data.normCharLength.present
          ? data.normCharLength.value
          : this.normCharLength,
      noteId: data.noteId.present ? data.noteId.value : this.noteId,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MinedSentenceRow(')
          ..write('id: $id, ')
          ..write('expression: $expression, ')
          ..write('reading: $reading, ')
          ..write('glossary: $glossary, ')
          ..write('sentence: $sentence, ')
          ..write('source: $source, ')
          ..write('documentTitle: $documentTitle, ')
          ..write('chapterLabel: $chapterLabel, ')
          ..write('bookKey: $bookKey, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('normCharLength: $normCharLength, ')
          ..write('noteId: $noteId, ')
          ..write('dateKey: $dateKey, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      expression,
      reading,
      glossary,
      sentence,
      source,
      documentTitle,
      chapterLabel,
      bookKey,
      sectionIndex,
      normCharOffset,
      normCharLength,
      noteId,
      dateKey,
      createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MinedSentenceRow &&
          other.id == this.id &&
          other.expression == this.expression &&
          other.reading == this.reading &&
          other.glossary == this.glossary &&
          other.sentence == this.sentence &&
          other.source == this.source &&
          other.documentTitle == this.documentTitle &&
          other.chapterLabel == this.chapterLabel &&
          other.bookKey == this.bookKey &&
          other.sectionIndex == this.sectionIndex &&
          other.normCharOffset == this.normCharOffset &&
          other.normCharLength == this.normCharLength &&
          other.noteId == this.noteId &&
          other.dateKey == this.dateKey &&
          other.createdAt == this.createdAt);
}

class MinedSentencesCompanion extends UpdateCompanion<MinedSentenceRow> {
  final Value<int> id;
  final Value<String> expression;
  final Value<String> reading;
  final Value<String> glossary;
  final Value<String> sentence;
  final Value<String> source;
  final Value<String?> documentTitle;
  final Value<String?> chapterLabel;
  final Value<String?> bookKey;
  final Value<int?> sectionIndex;
  final Value<int?> normCharOffset;
  final Value<int?> normCharLength;
  final Value<int?> noteId;
  final Value<String> dateKey;
  final Value<int> createdAt;
  const MinedSentencesCompanion({
    this.id = const Value.absent(),
    this.expression = const Value.absent(),
    this.reading = const Value.absent(),
    this.glossary = const Value.absent(),
    this.sentence = const Value.absent(),
    this.source = const Value.absent(),
    this.documentTitle = const Value.absent(),
    this.chapterLabel = const Value.absent(),
    this.bookKey = const Value.absent(),
    this.sectionIndex = const Value.absent(),
    this.normCharOffset = const Value.absent(),
    this.normCharLength = const Value.absent(),
    this.noteId = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  MinedSentencesCompanion.insert({
    this.id = const Value.absent(),
    this.expression = const Value.absent(),
    this.reading = const Value.absent(),
    this.glossary = const Value.absent(),
    this.sentence = const Value.absent(),
    required String source,
    this.documentTitle = const Value.absent(),
    this.chapterLabel = const Value.absent(),
    this.bookKey = const Value.absent(),
    this.sectionIndex = const Value.absent(),
    this.normCharOffset = const Value.absent(),
    this.normCharLength = const Value.absent(),
    this.noteId = const Value.absent(),
    required String dateKey,
    required int createdAt,
  })  : source = Value(source),
        dateKey = Value(dateKey),
        createdAt = Value(createdAt);
  static Insertable<MinedSentenceRow> custom({
    Expression<int>? id,
    Expression<String>? expression,
    Expression<String>? reading,
    Expression<String>? glossary,
    Expression<String>? sentence,
    Expression<String>? source,
    Expression<String>? documentTitle,
    Expression<String>? chapterLabel,
    Expression<String>? bookKey,
    Expression<int>? sectionIndex,
    Expression<int>? normCharOffset,
    Expression<int>? normCharLength,
    Expression<int>? noteId,
    Expression<String>? dateKey,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (expression != null) 'expression': expression,
      if (reading != null) 'reading': reading,
      if (glossary != null) 'glossary': glossary,
      if (sentence != null) 'sentence': sentence,
      if (source != null) 'source': source,
      if (documentTitle != null) 'document_title': documentTitle,
      if (chapterLabel != null) 'chapter_label': chapterLabel,
      if (bookKey != null) 'book_key': bookKey,
      if (sectionIndex != null) 'section_index': sectionIndex,
      if (normCharOffset != null) 'norm_char_offset': normCharOffset,
      if (normCharLength != null) 'norm_char_length': normCharLength,
      if (noteId != null) 'note_id': noteId,
      if (dateKey != null) 'date_key': dateKey,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  MinedSentencesCompanion copyWith(
      {Value<int>? id,
      Value<String>? expression,
      Value<String>? reading,
      Value<String>? glossary,
      Value<String>? sentence,
      Value<String>? source,
      Value<String?>? documentTitle,
      Value<String?>? chapterLabel,
      Value<String?>? bookKey,
      Value<int?>? sectionIndex,
      Value<int?>? normCharOffset,
      Value<int?>? normCharLength,
      Value<int?>? noteId,
      Value<String>? dateKey,
      Value<int>? createdAt}) {
    return MinedSentencesCompanion(
      id: id ?? this.id,
      expression: expression ?? this.expression,
      reading: reading ?? this.reading,
      glossary: glossary ?? this.glossary,
      sentence: sentence ?? this.sentence,
      source: source ?? this.source,
      documentTitle: documentTitle ?? this.documentTitle,
      chapterLabel: chapterLabel ?? this.chapterLabel,
      bookKey: bookKey ?? this.bookKey,
      sectionIndex: sectionIndex ?? this.sectionIndex,
      normCharOffset: normCharOffset ?? this.normCharOffset,
      normCharLength: normCharLength ?? this.normCharLength,
      noteId: noteId ?? this.noteId,
      dateKey: dateKey ?? this.dateKey,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (expression.present) {
      map['expression'] = Variable<String>(expression.value);
    }
    if (reading.present) {
      map['reading'] = Variable<String>(reading.value);
    }
    if (glossary.present) {
      map['glossary'] = Variable<String>(glossary.value);
    }
    if (sentence.present) {
      map['sentence'] = Variable<String>(sentence.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (documentTitle.present) {
      map['document_title'] = Variable<String>(documentTitle.value);
    }
    if (chapterLabel.present) {
      map['chapter_label'] = Variable<String>(chapterLabel.value);
    }
    if (bookKey.present) {
      map['book_key'] = Variable<String>(bookKey.value);
    }
    if (sectionIndex.present) {
      map['section_index'] = Variable<int>(sectionIndex.value);
    }
    if (normCharOffset.present) {
      map['norm_char_offset'] = Variable<int>(normCharOffset.value);
    }
    if (normCharLength.present) {
      map['norm_char_length'] = Variable<int>(normCharLength.value);
    }
    if (noteId.present) {
      map['note_id'] = Variable<int>(noteId.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MinedSentencesCompanion(')
          ..write('id: $id, ')
          ..write('expression: $expression, ')
          ..write('reading: $reading, ')
          ..write('glossary: $glossary, ')
          ..write('sentence: $sentence, ')
          ..write('source: $source, ')
          ..write('documentTitle: $documentTitle, ')
          ..write('chapterLabel: $chapterLabel, ')
          ..write('bookKey: $bookKey, ')
          ..write('sectionIndex: $sectionIndex, ')
          ..write('normCharOffset: $normCharOffset, ')
          ..write('normCharLength: $normCharLength, ')
          ..write('noteId: $noteId, ')
          ..write('dateKey: $dateKey, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$HibikiDatabase extends GeneratedDatabase {
  _$HibikiDatabase(QueryExecutor e) : super(e);
  $HibikiDatabaseManager get managers => $HibikiDatabaseManager(this);
  late final $MediaItemsTable mediaItems = $MediaItemsTable(this);
  late final $AnkiMappingsTable ankiMappings = $AnkiMappingsTable(this);
  late final $SearchHistoryItemsTable searchHistoryItems =
      $SearchHistoryItemsTable(this);
  late final $AudiobooksTable audiobooks = $AudiobooksTable(this);
  late final $AudioCuesTable audioCues = $AudioCuesTable(this);
  late final $SrtBooksTable srtBooks = $SrtBooksTable(this);
  late final $ReaderPositionsTable readerPositions =
      $ReaderPositionsTable(this);
  late final $MediaSourcesTable mediaSources = $MediaSourcesTable(this);
  late final $EpubBooksTable epubBooks = $EpubBooksTable(this);
  late final $BookmarksTable bookmarks = $BookmarksTable(this);
  late final $ReadingStatisticsTable readingStatistics =
      $ReadingStatisticsTable(this);
  late final $ReadingHourlyLogsTable readingHourlyLogs =
      $ReadingHourlyLogsTable(this);
  late final $PreferencesTable preferences = $PreferencesTable(this);
  late final $DictionaryMetadataTable dictionaryMetadata =
      $DictionaryMetadataTable(this);
  late final $DictionaryHistoryTable dictionaryHistory =
      $DictionaryHistoryTable(this);
  late final $BookTagsTable bookTags = $BookTagsTable(this);
  late final $BookTagMappingsTable bookTagMappings =
      $BookTagMappingsTable(this);
  late final $SrtBookTagMappingsTable srtBookTagMappings =
      $SrtBookTagMappingsTable(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $ProfileSettingsTable profileSettings =
      $ProfileSettingsTable(this);
  late final $MediaTypeProfilesTable mediaTypeProfiles =
      $MediaTypeProfilesTable(this);
  late final $BookProfilesTable bookProfiles = $BookProfilesTable(this);
  late final $SyncBaselinesTable syncBaselines = $SyncBaselinesTable(this);
  late final $VideoBooksTable videoBooks = $VideoBooksTable(this);
  late final $VideoBookTagMappingsTable videoBookTagMappings =
      $VideoBookTagMappingsTable(this);
  late final $VideoWatchStatisticsTable videoWatchStatistics =
      $VideoWatchStatisticsTable(this);
  late final $VideoHourlyLogsTable videoHourlyLogs =
      $VideoHourlyLogsTable(this);
  late final $FavoriteWordsTable favoriteWords = $FavoriteWordsTable(this);
  late final $MiningStatisticsTable miningStatistics =
      $MiningStatisticsTable(this);
  late final $MinedSentencesTable minedSentences = $MinedSentencesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        mediaItems,
        ankiMappings,
        searchHistoryItems,
        audiobooks,
        audioCues,
        srtBooks,
        readerPositions,
        mediaSources,
        epubBooks,
        bookmarks,
        readingStatistics,
        readingHourlyLogs,
        preferences,
        dictionaryMetadata,
        dictionaryHistory,
        bookTags,
        bookTagMappings,
        srtBookTagMappings,
        profiles,
        profileSettings,
        mediaTypeProfiles,
        bookProfiles,
        syncBaselines,
        videoBooks,
        videoBookTagMappings,
        videoWatchStatistics,
        videoHourlyLogs,
        favoriteWords,
        miningStatistics,
        minedSentences
      ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('media_sources',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('epub_books', kind: UpdateKind.update),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('epub_books',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('bookmarks', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('epub_books',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('book_tag_mappings', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('book_tags',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('book_tag_mappings', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('srt_books',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('srt_book_tag_mappings', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('book_tags',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('srt_book_tag_mappings', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('profiles',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('profile_settings', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('profiles',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('media_type_profiles', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('profiles',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('book_profiles', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('media_sources',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('video_books', kind: UpdateKind.update),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('video_books',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('video_book_tag_mappings', kind: UpdateKind.delete),
            ],
          ),
          WritePropagation(
            on: TableUpdateQuery.onTableName('book_tags',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('video_book_tag_mappings', kind: UpdateKind.delete),
            ],
          ),
        ],
      );
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
typedef $$AnkiMappingsTableCreateCompanionBuilder = AnkiMappingsCompanion
    Function({
  Value<int> id,
  required String label,
  required String model,
  required String exportFieldKeysJson,
  required String creatorFieldKeysJson,
  required String creatorCollapsedFieldKeysJson,
  required int order,
  required String tagsJson,
  required String enhancementsJson,
  required String actionsJson,
  Value<bool> exportMediaTags,
  Value<bool> useBrTags,
  Value<bool> prependDictionaryNames,
});
typedef $$AnkiMappingsTableUpdateCompanionBuilder = AnkiMappingsCompanion
    Function({
  Value<int> id,
  Value<String> label,
  Value<String> model,
  Value<String> exportFieldKeysJson,
  Value<String> creatorFieldKeysJson,
  Value<String> creatorCollapsedFieldKeysJson,
  Value<int> order,
  Value<String> tagsJson,
  Value<String> enhancementsJson,
  Value<String> actionsJson,
  Value<bool> exportMediaTags,
  Value<bool> useBrTags,
  Value<bool> prependDictionaryNames,
});

class $$AnkiMappingsTableFilterComposer
    extends Composer<_$HibikiDatabase, $AnkiMappingsTable> {
  $$AnkiMappingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get exportFieldKeysJson => $composableBuilder(
      column: $table.exportFieldKeysJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get creatorFieldKeysJson => $composableBuilder(
      column: $table.creatorFieldKeysJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get creatorCollapsedFieldKeysJson => $composableBuilder(
      column: $table.creatorCollapsedFieldKeysJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get order => $composableBuilder(
      column: $table.order, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tagsJson => $composableBuilder(
      column: $table.tagsJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get enhancementsJson => $composableBuilder(
      column: $table.enhancementsJson,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actionsJson => $composableBuilder(
      column: $table.actionsJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get exportMediaTags => $composableBuilder(
      column: $table.exportMediaTags,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get useBrTags => $composableBuilder(
      column: $table.useBrTags, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get prependDictionaryNames => $composableBuilder(
      column: $table.prependDictionaryNames,
      builder: (column) => ColumnFilters(column));
}

class $$AnkiMappingsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $AnkiMappingsTable> {
  $$AnkiMappingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get model => $composableBuilder(
      column: $table.model, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get exportFieldKeysJson => $composableBuilder(
      column: $table.exportFieldKeysJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get creatorFieldKeysJson => $composableBuilder(
      column: $table.creatorFieldKeysJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get creatorCollapsedFieldKeysJson =>
      $composableBuilder(
          column: $table.creatorCollapsedFieldKeysJson,
          builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get order => $composableBuilder(
      column: $table.order, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tagsJson => $composableBuilder(
      column: $table.tagsJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get enhancementsJson => $composableBuilder(
      column: $table.enhancementsJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actionsJson => $composableBuilder(
      column: $table.actionsJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get exportMediaTags => $composableBuilder(
      column: $table.exportMediaTags,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get useBrTags => $composableBuilder(
      column: $table.useBrTags, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get prependDictionaryNames => $composableBuilder(
      column: $table.prependDictionaryNames,
      builder: (column) => ColumnOrderings(column));
}

class $$AnkiMappingsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $AnkiMappingsTable> {
  $$AnkiMappingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<String> get exportFieldKeysJson => $composableBuilder(
      column: $table.exportFieldKeysJson, builder: (column) => column);

  GeneratedColumn<String> get creatorFieldKeysJson => $composableBuilder(
      column: $table.creatorFieldKeysJson, builder: (column) => column);

  GeneratedColumn<String> get creatorCollapsedFieldKeysJson =>
      $composableBuilder(
          column: $table.creatorCollapsedFieldKeysJson,
          builder: (column) => column);

  GeneratedColumn<int> get order =>
      $composableBuilder(column: $table.order, builder: (column) => column);

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<String> get enhancementsJson => $composableBuilder(
      column: $table.enhancementsJson, builder: (column) => column);

  GeneratedColumn<String> get actionsJson => $composableBuilder(
      column: $table.actionsJson, builder: (column) => column);

  GeneratedColumn<bool> get exportMediaTags => $composableBuilder(
      column: $table.exportMediaTags, builder: (column) => column);

  GeneratedColumn<bool> get useBrTags =>
      $composableBuilder(column: $table.useBrTags, builder: (column) => column);

  GeneratedColumn<bool> get prependDictionaryNames => $composableBuilder(
      column: $table.prependDictionaryNames, builder: (column) => column);
}

class $$AnkiMappingsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $AnkiMappingsTable,
    AnkiMappingRow,
    $$AnkiMappingsTableFilterComposer,
    $$AnkiMappingsTableOrderingComposer,
    $$AnkiMappingsTableAnnotationComposer,
    $$AnkiMappingsTableCreateCompanionBuilder,
    $$AnkiMappingsTableUpdateCompanionBuilder,
    (
      AnkiMappingRow,
      BaseReferences<_$HibikiDatabase, $AnkiMappingsTable, AnkiMappingRow>
    ),
    AnkiMappingRow,
    PrefetchHooks Function()> {
  $$AnkiMappingsTableTableManager(_$HibikiDatabase db, $AnkiMappingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AnkiMappingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AnkiMappingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AnkiMappingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> label = const Value.absent(),
            Value<String> model = const Value.absent(),
            Value<String> exportFieldKeysJson = const Value.absent(),
            Value<String> creatorFieldKeysJson = const Value.absent(),
            Value<String> creatorCollapsedFieldKeysJson = const Value.absent(),
            Value<int> order = const Value.absent(),
            Value<String> tagsJson = const Value.absent(),
            Value<String> enhancementsJson = const Value.absent(),
            Value<String> actionsJson = const Value.absent(),
            Value<bool> exportMediaTags = const Value.absent(),
            Value<bool> useBrTags = const Value.absent(),
            Value<bool> prependDictionaryNames = const Value.absent(),
          }) =>
              AnkiMappingsCompanion(
            id: id,
            label: label,
            model: model,
            exportFieldKeysJson: exportFieldKeysJson,
            creatorFieldKeysJson: creatorFieldKeysJson,
            creatorCollapsedFieldKeysJson: creatorCollapsedFieldKeysJson,
            order: order,
            tagsJson: tagsJson,
            enhancementsJson: enhancementsJson,
            actionsJson: actionsJson,
            exportMediaTags: exportMediaTags,
            useBrTags: useBrTags,
            prependDictionaryNames: prependDictionaryNames,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String label,
            required String model,
            required String exportFieldKeysJson,
            required String creatorFieldKeysJson,
            required String creatorCollapsedFieldKeysJson,
            required int order,
            required String tagsJson,
            required String enhancementsJson,
            required String actionsJson,
            Value<bool> exportMediaTags = const Value.absent(),
            Value<bool> useBrTags = const Value.absent(),
            Value<bool> prependDictionaryNames = const Value.absent(),
          }) =>
              AnkiMappingsCompanion.insert(
            id: id,
            label: label,
            model: model,
            exportFieldKeysJson: exportFieldKeysJson,
            creatorFieldKeysJson: creatorFieldKeysJson,
            creatorCollapsedFieldKeysJson: creatorCollapsedFieldKeysJson,
            order: order,
            tagsJson: tagsJson,
            enhancementsJson: enhancementsJson,
            actionsJson: actionsJson,
            exportMediaTags: exportMediaTags,
            useBrTags: useBrTags,
            prependDictionaryNames: prependDictionaryNames,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AnkiMappingsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $AnkiMappingsTable,
    AnkiMappingRow,
    $$AnkiMappingsTableFilterComposer,
    $$AnkiMappingsTableOrderingComposer,
    $$AnkiMappingsTableAnnotationComposer,
    $$AnkiMappingsTableCreateCompanionBuilder,
    $$AnkiMappingsTableUpdateCompanionBuilder,
    (
      AnkiMappingRow,
      BaseReferences<_$HibikiDatabase, $AnkiMappingsTable, AnkiMappingRow>
    ),
    AnkiMappingRow,
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
  required String bookKey,
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
  Value<String> bookKey,
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

  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

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

  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));

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

  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

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
            Value<String> bookKey = const Value.absent(),
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
            bookKey: bookKey,
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
            required String bookKey,
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
            bookKey: bookKey,
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
  required String bookKey,
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
  Value<String> bookKey,
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

  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

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

  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));

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

  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

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
            Value<String> bookKey = const Value.absent(),
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
            bookKey: bookKey,
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
            required String bookKey,
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
            bookKey: bookKey,
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
  Value<String> bookKey,
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
  Value<String> bookKey,
});

final class $$SrtBooksTableReferences
    extends BaseReferences<_$HibikiDatabase, $SrtBooksTable, SrtBookRow> {
  $$SrtBooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$SrtBookTagMappingsTable,
      List<SrtBookTagMappingRow>> _srtBookTagMappingsRefsTable(
          _$HibikiDatabase db) =>
      MultiTypedResultKey.fromTable(db.srtBookTagMappings,
          aliasName: 'srt_books__id__srt_book_tag_mappings__srt_book_id');

  $$SrtBookTagMappingsTableProcessedTableManager get srtBookTagMappingsRefs {
    final manager =
        $$SrtBookTagMappingsTableTableManager($_db, $_db.srtBookTagMappings)
            .filter((f) => f.srtBookId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_srtBookTagMappingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

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

  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

  Expression<bool> srtBookTagMappingsRefs(
      Expression<bool> Function($$SrtBookTagMappingsTableFilterComposer f) f) {
    final $$SrtBookTagMappingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.srtBookTagMappings,
        getReferencedColumn: (t) => t.srtBookId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SrtBookTagMappingsTableFilterComposer(
              $db: $db,
              $table: $db.srtBookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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

  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));
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

  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

  Expression<T> srtBookTagMappingsRefs<T extends Object>(
      Expression<T> Function($$SrtBookTagMappingsTableAnnotationComposer a) f) {
    final $$SrtBookTagMappingsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.srtBookTagMappings,
            getReferencedColumn: (t) => t.srtBookId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$SrtBookTagMappingsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.srtBookTagMappings,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
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
    (SrtBookRow, $$SrtBooksTableReferences),
    SrtBookRow,
    PrefetchHooks Function({bool srtBookTagMappingsRefs})> {
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
            Value<String> bookKey = const Value.absent(),
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
            bookKey: bookKey,
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
            Value<String> bookKey = const Value.absent(),
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
            bookKey: bookKey,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$SrtBooksTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({srtBookTagMappingsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (srtBookTagMappingsRefs) db.srtBookTagMappings
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (srtBookTagMappingsRefs)
                    await $_getPrefetchedData<SrtBookRow, $SrtBooksTable,
                            SrtBookTagMappingRow>(
                        currentTable: table,
                        referencedTable: $$SrtBooksTableReferences
                            ._srtBookTagMappingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$SrtBooksTableReferences(db, table, p0)
                                .srtBookTagMappingsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.srtBookId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
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
    (SrtBookRow, $$SrtBooksTableReferences),
    SrtBookRow,
    PrefetchHooks Function({bool srtBookTagMappingsRefs})>;
typedef $$ReaderPositionsTableCreateCompanionBuilder = ReaderPositionsCompanion
    Function({
  Value<int> id,
  required String bookKey,
  required int sectionIndex,
  required int normCharOffset,
  Value<int> charOffset,
  required int updatedAt,
});
typedef $$ReaderPositionsTableUpdateCompanionBuilder = ReaderPositionsCompanion
    Function({
  Value<int> id,
  Value<String> bookKey,
  Value<int> sectionIndex,
  Value<int> normCharOffset,
  Value<int> charOffset,
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

  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get charOffset => $composableBuilder(
      column: $table.charOffset, builder: (column) => ColumnFilters(column));

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

  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get charOffset => $composableBuilder(
      column: $table.charOffset, builder: (column) => ColumnOrderings(column));

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

  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

  GeneratedColumn<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => column);

  GeneratedColumn<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset, builder: (column) => column);

  GeneratedColumn<int> get charOffset => $composableBuilder(
      column: $table.charOffset, builder: (column) => column);

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
            Value<String> bookKey = const Value.absent(),
            Value<int> sectionIndex = const Value.absent(),
            Value<int> normCharOffset = const Value.absent(),
            Value<int> charOffset = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
          }) =>
              ReaderPositionsCompanion(
            id: id,
            bookKey: bookKey,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            charOffset: charOffset,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String bookKey,
            required int sectionIndex,
            required int normCharOffset,
            Value<int> charOffset = const Value.absent(),
            required int updatedAt,
          }) =>
              ReaderPositionsCompanion.insert(
            id: id,
            bookKey: bookKey,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            charOffset: charOffset,
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
typedef $$MediaSourcesTableCreateCompanionBuilder = MediaSourcesCompanion
    Function({
  Value<int> id,
  required String label,
  required String mediaKind,
  Value<String> transport,
  required String rootPath,
  Value<String?> configJson,
  Value<int> mediaCount,
  Value<DateTime?> lastScannedAt,
  Value<String?> lastScanError,
  Value<bool> recursive,
  Value<int> sortOrder,
  required int createdAt,
});
typedef $$MediaSourcesTableUpdateCompanionBuilder = MediaSourcesCompanion
    Function({
  Value<int> id,
  Value<String> label,
  Value<String> mediaKind,
  Value<String> transport,
  Value<String> rootPath,
  Value<String?> configJson,
  Value<int> mediaCount,
  Value<DateTime?> lastScannedAt,
  Value<String?> lastScanError,
  Value<bool> recursive,
  Value<int> sortOrder,
  Value<int> createdAt,
});

final class $$MediaSourcesTableReferences extends BaseReferences<
    _$HibikiDatabase, $MediaSourcesTable, MediaSourceRow> {
  $$MediaSourcesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$EpubBooksTable, List<EpubBookRow>>
      _epubBooksRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.epubBooks,
              aliasName: 'media_sources__id__epub_books__source_id');

  $$EpubBooksTableProcessedTableManager get epubBooksRefs {
    final manager = $$EpubBooksTableTableManager($_db, $_db.epubBooks)
        .filter((f) => f.sourceId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_epubBooksRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$VideoBooksTable, List<VideoBookRow>>
      _videoBooksRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.videoBooks,
              aliasName: 'media_sources__id__video_books__source_id');

  $$VideoBooksTableProcessedTableManager get videoBooksRefs {
    final manager = $$VideoBooksTableTableManager($_db, $_db.videoBooks)
        .filter((f) => f.sourceId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_videoBooksRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$MediaSourcesTableFilterComposer
    extends Composer<_$HibikiDatabase, $MediaSourcesTable> {
  $$MediaSourcesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaKind => $composableBuilder(
      column: $table.mediaKind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get transport => $composableBuilder(
      column: $table.transport, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get rootPath => $composableBuilder(
      column: $table.rootPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get configJson => $composableBuilder(
      column: $table.configJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get mediaCount => $composableBuilder(
      column: $table.mediaCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastScannedAt => $composableBuilder(
      column: $table.lastScannedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastScanError => $composableBuilder(
      column: $table.lastScanError, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get recursive => $composableBuilder(
      column: $table.recursive, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  Expression<bool> epubBooksRefs(
      Expression<bool> Function($$EpubBooksTableFilterComposer f) f) {
    final $$EpubBooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.sourceId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableFilterComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> videoBooksRefs(
      Expression<bool> Function($$VideoBooksTableFilterComposer f) f) {
    final $$VideoBooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.videoBooks,
        getReferencedColumn: (t) => t.sourceId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBooksTableFilterComposer(
              $db: $db,
              $table: $db.videoBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MediaSourcesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $MediaSourcesTable> {
  $$MediaSourcesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaKind => $composableBuilder(
      column: $table.mediaKind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get transport => $composableBuilder(
      column: $table.transport, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get rootPath => $composableBuilder(
      column: $table.rootPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get configJson => $composableBuilder(
      column: $table.configJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get mediaCount => $composableBuilder(
      column: $table.mediaCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastScannedAt => $composableBuilder(
      column: $table.lastScannedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastScanError => $composableBuilder(
      column: $table.lastScanError,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get recursive => $composableBuilder(
      column: $table.recursive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$MediaSourcesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $MediaSourcesTable> {
  $$MediaSourcesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get mediaKind =>
      $composableBuilder(column: $table.mediaKind, builder: (column) => column);

  GeneratedColumn<String> get transport =>
      $composableBuilder(column: $table.transport, builder: (column) => column);

  GeneratedColumn<String> get rootPath =>
      $composableBuilder(column: $table.rootPath, builder: (column) => column);

  GeneratedColumn<String> get configJson => $composableBuilder(
      column: $table.configJson, builder: (column) => column);

  GeneratedColumn<int> get mediaCount => $composableBuilder(
      column: $table.mediaCount, builder: (column) => column);

  GeneratedColumn<DateTime> get lastScannedAt => $composableBuilder(
      column: $table.lastScannedAt, builder: (column) => column);

  GeneratedColumn<String> get lastScanError => $composableBuilder(
      column: $table.lastScanError, builder: (column) => column);

  GeneratedColumn<bool> get recursive =>
      $composableBuilder(column: $table.recursive, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> epubBooksRefs<T extends Object>(
      Expression<T> Function($$EpubBooksTableAnnotationComposer a) f) {
    final $$EpubBooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.sourceId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableAnnotationComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> videoBooksRefs<T extends Object>(
      Expression<T> Function($$VideoBooksTableAnnotationComposer a) f) {
    final $$VideoBooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.videoBooks,
        getReferencedColumn: (t) => t.sourceId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBooksTableAnnotationComposer(
              $db: $db,
              $table: $db.videoBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MediaSourcesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $MediaSourcesTable,
    MediaSourceRow,
    $$MediaSourcesTableFilterComposer,
    $$MediaSourcesTableOrderingComposer,
    $$MediaSourcesTableAnnotationComposer,
    $$MediaSourcesTableCreateCompanionBuilder,
    $$MediaSourcesTableUpdateCompanionBuilder,
    (MediaSourceRow, $$MediaSourcesTableReferences),
    MediaSourceRow,
    PrefetchHooks Function({bool epubBooksRefs, bool videoBooksRefs})> {
  $$MediaSourcesTableTableManager(_$HibikiDatabase db, $MediaSourcesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaSourcesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaSourcesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaSourcesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> label = const Value.absent(),
            Value<String> mediaKind = const Value.absent(),
            Value<String> transport = const Value.absent(),
            Value<String> rootPath = const Value.absent(),
            Value<String?> configJson = const Value.absent(),
            Value<int> mediaCount = const Value.absent(),
            Value<DateTime?> lastScannedAt = const Value.absent(),
            Value<String?> lastScanError = const Value.absent(),
            Value<bool> recursive = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              MediaSourcesCompanion(
            id: id,
            label: label,
            mediaKind: mediaKind,
            transport: transport,
            rootPath: rootPath,
            configJson: configJson,
            mediaCount: mediaCount,
            lastScannedAt: lastScannedAt,
            lastScanError: lastScanError,
            recursive: recursive,
            sortOrder: sortOrder,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String label,
            required String mediaKind,
            Value<String> transport = const Value.absent(),
            required String rootPath,
            Value<String?> configJson = const Value.absent(),
            Value<int> mediaCount = const Value.absent(),
            Value<DateTime?> lastScannedAt = const Value.absent(),
            Value<String?> lastScanError = const Value.absent(),
            Value<bool> recursive = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            required int createdAt,
          }) =>
              MediaSourcesCompanion.insert(
            id: id,
            label: label,
            mediaKind: mediaKind,
            transport: transport,
            rootPath: rootPath,
            configJson: configJson,
            mediaCount: mediaCount,
            lastScannedAt: lastScannedAt,
            lastScanError: lastScanError,
            recursive: recursive,
            sortOrder: sortOrder,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$MediaSourcesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {epubBooksRefs = false, videoBooksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (epubBooksRefs) db.epubBooks,
                if (videoBooksRefs) db.videoBooks
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (epubBooksRefs)
                    await $_getPrefetchedData<MediaSourceRow, $MediaSourcesTable,
                            EpubBookRow>(
                        currentTable: table,
                        referencedTable: $$MediaSourcesTableReferences
                            ._epubBooksRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$MediaSourcesTableReferences(db, table, p0)
                                .epubBooksRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.sourceId == item.id),
                        typedResults: items),
                  if (videoBooksRefs)
                    await $_getPrefetchedData<MediaSourceRow, $MediaSourcesTable,
                            VideoBookRow>(
                        currentTable: table,
                        referencedTable: $$MediaSourcesTableReferences
                            ._videoBooksRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$MediaSourcesTableReferences(db, table, p0)
                                .videoBooksRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.sourceId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$MediaSourcesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $MediaSourcesTable,
    MediaSourceRow,
    $$MediaSourcesTableFilterComposer,
    $$MediaSourcesTableOrderingComposer,
    $$MediaSourcesTableAnnotationComposer,
    $$MediaSourcesTableCreateCompanionBuilder,
    $$MediaSourcesTableUpdateCompanionBuilder,
    (MediaSourceRow, $$MediaSourcesTableReferences),
    MediaSourceRow,
    PrefetchHooks Function({bool epubBooksRefs, bool videoBooksRefs})>;
typedef $$EpubBooksTableCreateCompanionBuilder = EpubBooksCompanion Function({
  required String bookKey,
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
  Value<int?> sourceId,
  Value<int> rowid,
});
typedef $$EpubBooksTableUpdateCompanionBuilder = EpubBooksCompanion Function({
  Value<String> bookKey,
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
  Value<int?> sourceId,
  Value<int> rowid,
});

final class $$EpubBooksTableReferences
    extends BaseReferences<_$HibikiDatabase, $EpubBooksTable, EpubBookRow> {
  $$EpubBooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MediaSourcesTable _sourceIdTable(_$HibikiDatabase db) =>
      db.mediaSources.createAlias('epub_books__source_id__media_sources__id');

  $$MediaSourcesTableProcessedTableManager? get sourceId {
    final $_column = $_itemColumn<int>('source_id');
    if ($_column == null) return null;
    final manager = $$MediaSourcesTableTableManager($_db, $_db.mediaSources)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sourceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$BookmarksTable, List<BookmarkRow>>
      _bookmarksRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.bookmarks,
              aliasName: 'epub_books__book_key__bookmarks__book_key');

  $$BookmarksTableProcessedTableManager get bookmarksRefs {
    final manager = $$BookmarksTableTableManager($_db, $_db.bookmarks).filter(
        (f) => f.bookKey.bookKey.sqlEquals($_itemColumn<String>('book_key')!));

    final cache = $_typedResult.readTableOrNull(_bookmarksRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$BookTagMappingsTable, List<BookTagMappingRow>>
      _bookTagMappingsRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.bookTagMappings,
              aliasName: 'epub_books__book_key__book_tag_mappings__book_key');

  $$BookTagMappingsTableProcessedTableManager get bookTagMappingsRefs {
    final manager =
        $$BookTagMappingsTableTableManager($_db, $_db.bookTagMappings).filter(
            (f) =>
                f.bookKey.bookKey.sqlEquals($_itemColumn<String>('book_key')!));

    final cache =
        $_typedResult.readTableOrNull(_bookTagMappingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$EpubBooksTableFilterComposer
    extends Composer<_$HibikiDatabase, $EpubBooksTable> {
  $$EpubBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

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

  $$MediaSourcesTableFilterComposer get sourceId {
    final $$MediaSourcesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.sourceId,
        referencedTable: $db.mediaSources,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaSourcesTableFilterComposer(
              $db: $db,
              $table: $db.mediaSources,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> bookmarksRefs(
      Expression<bool> Function($$BookmarksTableFilterComposer f) f) {
    final $$BookmarksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.bookmarks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookmarksTableFilterComposer(
              $db: $db,
              $table: $db.bookmarks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> bookTagMappingsRefs(
      Expression<bool> Function($$BookTagMappingsTableFilterComposer f) f) {
    final $$BookTagMappingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.bookTagMappings,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagMappingsTableFilterComposer(
              $db: $db,
              $table: $db.bookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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
  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));

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

  $$MediaSourcesTableOrderingComposer get sourceId {
    final $$MediaSourcesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.sourceId,
        referencedTable: $db.mediaSources,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaSourcesTableOrderingComposer(
              $db: $db,
              $table: $db.mediaSources,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

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

  $$MediaSourcesTableAnnotationComposer get sourceId {
    final $$MediaSourcesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.sourceId,
        referencedTable: $db.mediaSources,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaSourcesTableAnnotationComposer(
              $db: $db,
              $table: $db.mediaSources,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> bookmarksRefs<T extends Object>(
      Expression<T> Function($$BookmarksTableAnnotationComposer a) f) {
    final $$BookmarksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.bookmarks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookmarksTableAnnotationComposer(
              $db: $db,
              $table: $db.bookmarks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> bookTagMappingsRefs<T extends Object>(
      Expression<T> Function($$BookTagMappingsTableAnnotationComposer a) f) {
    final $$BookTagMappingsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.bookTagMappings,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagMappingsTableAnnotationComposer(
              $db: $db,
              $table: $db.bookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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
    (EpubBookRow, $$EpubBooksTableReferences),
    EpubBookRow,
    PrefetchHooks Function(
        {bool sourceId, bool bookmarksRefs, bool bookTagMappingsRefs})> {
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
            Value<String> bookKey = const Value.absent(),
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
            Value<int?> sourceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EpubBooksCompanion(
            bookKey: bookKey,
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
            sourceId: sourceId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String bookKey,
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
            Value<int?> sourceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EpubBooksCompanion.insert(
            bookKey: bookKey,
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
            sourceId: sourceId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$EpubBooksTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {sourceId = false,
              bookmarksRefs = false,
              bookTagMappingsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (bookmarksRefs) db.bookmarks,
                if (bookTagMappingsRefs) db.bookTagMappings
              ],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (sourceId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.sourceId,
                    referencedTable:
                        $$EpubBooksTableReferences._sourceIdTable(db),
                    referencedColumn:
                        $$EpubBooksTableReferences._sourceIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (bookmarksRefs)
                    await $_getPrefetchedData<EpubBookRow, $EpubBooksTable,
                            BookmarkRow>(
                        currentTable: table,
                        referencedTable:
                            $$EpubBooksTableReferences._bookmarksRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$EpubBooksTableReferences(db, table, p0)
                                .bookmarksRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.bookKey == item.bookKey),
                        typedResults: items),
                  if (bookTagMappingsRefs)
                    await $_getPrefetchedData<EpubBookRow, $EpubBooksTable,
                            BookTagMappingRow>(
                        currentTable: table,
                        referencedTable: $$EpubBooksTableReferences
                            ._bookTagMappingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$EpubBooksTableReferences(db, table, p0)
                                .bookTagMappingsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.bookKey == item.bookKey),
                        typedResults: items)
                ];
              },
            );
          },
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
    (EpubBookRow, $$EpubBooksTableReferences),
    EpubBookRow,
    PrefetchHooks Function(
        {bool sourceId, bool bookmarksRefs, bool bookTagMappingsRefs})>;
typedef $$BookmarksTableCreateCompanionBuilder = BookmarksCompanion Function({
  Value<int> id,
  required String bookKey,
  required int sectionIndex,
  required int normCharOffset,
  required String label,
  required int createdAt,
  Value<String?> bookTitle,
  Value<int?> pageInChapter,
  Value<int?> totalPagesInChapter,
});
typedef $$BookmarksTableUpdateCompanionBuilder = BookmarksCompanion Function({
  Value<int> id,
  Value<String> bookKey,
  Value<int> sectionIndex,
  Value<int> normCharOffset,
  Value<String> label,
  Value<int> createdAt,
  Value<String?> bookTitle,
  Value<int?> pageInChapter,
  Value<int?> totalPagesInChapter,
});

final class $$BookmarksTableReferences
    extends BaseReferences<_$HibikiDatabase, $BookmarksTable, BookmarkRow> {
  $$BookmarksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $EpubBooksTable _bookKeyTable(_$HibikiDatabase db) =>
      db.epubBooks.createAlias('bookmarks__book_key__epub_books__book_key');

  $$EpubBooksTableProcessedTableManager get bookKey {
    final $_column = $_itemColumn<String>('book_key')!;

    final manager = $$EpubBooksTableTableManager($_db, $_db.epubBooks)
        .filter((f) => f.bookKey.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookKeyTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$BookmarksTableFilterComposer
    extends Composer<_$HibikiDatabase, $BookmarksTable> {
  $$BookmarksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bookTitle => $composableBuilder(
      column: $table.bookTitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pageInChapter => $composableBuilder(
      column: $table.pageInChapter, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalPagesInChapter => $composableBuilder(
      column: $table.totalPagesInChapter,
      builder: (column) => ColumnFilters(column));

  $$EpubBooksTableFilterComposer get bookKey {
    final $$EpubBooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableFilterComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$BookmarksTableOrderingComposer
    extends Composer<_$HibikiDatabase, $BookmarksTable> {
  $$BookmarksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get label => $composableBuilder(
      column: $table.label, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bookTitle => $composableBuilder(
      column: $table.bookTitle, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pageInChapter => $composableBuilder(
      column: $table.pageInChapter,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalPagesInChapter => $composableBuilder(
      column: $table.totalPagesInChapter,
      builder: (column) => ColumnOrderings(column));

  $$EpubBooksTableOrderingComposer get bookKey {
    final $$EpubBooksTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableOrderingComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$BookmarksTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $BookmarksTable> {
  $$BookmarksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => column);

  GeneratedColumn<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get bookTitle =>
      $composableBuilder(column: $table.bookTitle, builder: (column) => column);

  GeneratedColumn<int> get pageInChapter => $composableBuilder(
      column: $table.pageInChapter, builder: (column) => column);

  GeneratedColumn<int> get totalPagesInChapter => $composableBuilder(
      column: $table.totalPagesInChapter, builder: (column) => column);

  $$EpubBooksTableAnnotationComposer get bookKey {
    final $$EpubBooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableAnnotationComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$BookmarksTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $BookmarksTable,
    BookmarkRow,
    $$BookmarksTableFilterComposer,
    $$BookmarksTableOrderingComposer,
    $$BookmarksTableAnnotationComposer,
    $$BookmarksTableCreateCompanionBuilder,
    $$BookmarksTableUpdateCompanionBuilder,
    (BookmarkRow, $$BookmarksTableReferences),
    BookmarkRow,
    PrefetchHooks Function({bool bookKey})> {
  $$BookmarksTableTableManager(_$HibikiDatabase db, $BookmarksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookmarksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookmarksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookmarksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> bookKey = const Value.absent(),
            Value<int> sectionIndex = const Value.absent(),
            Value<int> normCharOffset = const Value.absent(),
            Value<String> label = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<String?> bookTitle = const Value.absent(),
            Value<int?> pageInChapter = const Value.absent(),
            Value<int?> totalPagesInChapter = const Value.absent(),
          }) =>
              BookmarksCompanion(
            id: id,
            bookKey: bookKey,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            label: label,
            createdAt: createdAt,
            bookTitle: bookTitle,
            pageInChapter: pageInChapter,
            totalPagesInChapter: totalPagesInChapter,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String bookKey,
            required int sectionIndex,
            required int normCharOffset,
            required String label,
            required int createdAt,
            Value<String?> bookTitle = const Value.absent(),
            Value<int?> pageInChapter = const Value.absent(),
            Value<int?> totalPagesInChapter = const Value.absent(),
          }) =>
              BookmarksCompanion.insert(
            id: id,
            bookKey: bookKey,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            label: label,
            createdAt: createdAt,
            bookTitle: bookTitle,
            pageInChapter: pageInChapter,
            totalPagesInChapter: totalPagesInChapter,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$BookmarksTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({bookKey = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (bookKey) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.bookKey,
                    referencedTable:
                        $$BookmarksTableReferences._bookKeyTable(db),
                    referencedColumn:
                        $$BookmarksTableReferences._bookKeyTable(db).bookKey,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$BookmarksTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $BookmarksTable,
    BookmarkRow,
    $$BookmarksTableFilterComposer,
    $$BookmarksTableOrderingComposer,
    $$BookmarksTableAnnotationComposer,
    $$BookmarksTableCreateCompanionBuilder,
    $$BookmarksTableUpdateCompanionBuilder,
    (BookmarkRow, $$BookmarksTableReferences),
    BookmarkRow,
    PrefetchHooks Function({bool bookKey})>;
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
typedef $$BookTagsTableCreateCompanionBuilder = BookTagsCompanion Function({
  Value<int> id,
  required String name,
  Value<int> colorValue,
  Value<int> sortOrder,
  required int createdAt,
});
typedef $$BookTagsTableUpdateCompanionBuilder = BookTagsCompanion Function({
  Value<int> id,
  Value<String> name,
  Value<int> colorValue,
  Value<int> sortOrder,
  Value<int> createdAt,
});

final class $$BookTagsTableReferences
    extends BaseReferences<_$HibikiDatabase, $BookTagsTable, BookTagRow> {
  $$BookTagsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$BookTagMappingsTable, List<BookTagMappingRow>>
      _bookTagMappingsRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.bookTagMappings,
              aliasName: 'book_tags__id__book_tag_mappings__tag_id');

  $$BookTagMappingsTableProcessedTableManager get bookTagMappingsRefs {
    final manager =
        $$BookTagMappingsTableTableManager($_db, $_db.bookTagMappings)
            .filter((f) => f.tagId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_bookTagMappingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$SrtBookTagMappingsTable,
      List<SrtBookTagMappingRow>> _srtBookTagMappingsRefsTable(
          _$HibikiDatabase db) =>
      MultiTypedResultKey.fromTable(db.srtBookTagMappings,
          aliasName: 'book_tags__id__srt_book_tag_mappings__tag_id');

  $$SrtBookTagMappingsTableProcessedTableManager get srtBookTagMappingsRefs {
    final manager =
        $$SrtBookTagMappingsTableTableManager($_db, $_db.srtBookTagMappings)
            .filter((f) => f.tagId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_srtBookTagMappingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$VideoBookTagMappingsTable,
      List<VideoBookTagMappingRow>> _videoBookTagMappingsRefsTable(
          _$HibikiDatabase db) =>
      MultiTypedResultKey.fromTable(db.videoBookTagMappings,
          aliasName: 'book_tags__id__video_book_tag_mappings__tag_id');

  $$VideoBookTagMappingsTableProcessedTableManager
      get videoBookTagMappingsRefs {
    final manager =
        $$VideoBookTagMappingsTableTableManager($_db, $_db.videoBookTagMappings)
            .filter((f) => f.tagId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_videoBookTagMappingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

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

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  Expression<bool> bookTagMappingsRefs(
      Expression<bool> Function($$BookTagMappingsTableFilterComposer f) f) {
    final $$BookTagMappingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.bookTagMappings,
        getReferencedColumn: (t) => t.tagId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagMappingsTableFilterComposer(
              $db: $db,
              $table: $db.bookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> srtBookTagMappingsRefs(
      Expression<bool> Function($$SrtBookTagMappingsTableFilterComposer f) f) {
    final $$SrtBookTagMappingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.srtBookTagMappings,
        getReferencedColumn: (t) => t.tagId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SrtBookTagMappingsTableFilterComposer(
              $db: $db,
              $table: $db.srtBookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> videoBookTagMappingsRefs(
      Expression<bool> Function($$VideoBookTagMappingsTableFilterComposer f)
          f) {
    final $$VideoBookTagMappingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.videoBookTagMappings,
        getReferencedColumn: (t) => t.tagId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBookTagMappingsTableFilterComposer(
              $db: $db,
              $table: $db.videoBookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

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

  GeneratedColumn<int> get colorValue => $composableBuilder(
      column: $table.colorValue, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> bookTagMappingsRefs<T extends Object>(
      Expression<T> Function($$BookTagMappingsTableAnnotationComposer a) f) {
    final $$BookTagMappingsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.bookTagMappings,
        getReferencedColumn: (t) => t.tagId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagMappingsTableAnnotationComposer(
              $db: $db,
              $table: $db.bookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> srtBookTagMappingsRefs<T extends Object>(
      Expression<T> Function($$SrtBookTagMappingsTableAnnotationComposer a) f) {
    final $$SrtBookTagMappingsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.srtBookTagMappings,
            getReferencedColumn: (t) => t.tagId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$SrtBookTagMappingsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.srtBookTagMappings,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> videoBookTagMappingsRefs<T extends Object>(
      Expression<T> Function($$VideoBookTagMappingsTableAnnotationComposer a)
          f) {
    final $$VideoBookTagMappingsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.videoBookTagMappings,
            getReferencedColumn: (t) => t.tagId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$VideoBookTagMappingsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.videoBookTagMappings,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
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
    (BookTagRow, $$BookTagsTableReferences),
    BookTagRow,
    PrefetchHooks Function(
        {bool bookTagMappingsRefs,
        bool srtBookTagMappingsRefs,
        bool videoBookTagMappingsRefs})> {
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
            Value<int> sortOrder = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              BookTagsCompanion(
            id: id,
            name: name,
            colorValue: colorValue,
            sortOrder: sortOrder,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String name,
            Value<int> colorValue = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            required int createdAt,
          }) =>
              BookTagsCompanion.insert(
            id: id,
            name: name,
            colorValue: colorValue,
            sortOrder: sortOrder,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$BookTagsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {bookTagMappingsRefs = false,
              srtBookTagMappingsRefs = false,
              videoBookTagMappingsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (bookTagMappingsRefs) db.bookTagMappings,
                if (srtBookTagMappingsRefs) db.srtBookTagMappings,
                if (videoBookTagMappingsRefs) db.videoBookTagMappings
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (bookTagMappingsRefs)
                    await $_getPrefetchedData<BookTagRow, $BookTagsTable,
                            BookTagMappingRow>(
                        currentTable: table,
                        referencedTable: $$BookTagsTableReferences
                            ._bookTagMappingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$BookTagsTableReferences(db, table, p0)
                                .bookTagMappingsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.tagId == item.id),
                        typedResults: items),
                  if (srtBookTagMappingsRefs)
                    await $_getPrefetchedData<BookTagRow, $BookTagsTable,
                            SrtBookTagMappingRow>(
                        currentTable: table,
                        referencedTable: $$BookTagsTableReferences
                            ._srtBookTagMappingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$BookTagsTableReferences(db, table, p0)
                                .srtBookTagMappingsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.tagId == item.id),
                        typedResults: items),
                  if (videoBookTagMappingsRefs)
                    await $_getPrefetchedData<BookTagRow, $BookTagsTable,
                            VideoBookTagMappingRow>(
                        currentTable: table,
                        referencedTable: $$BookTagsTableReferences
                            ._videoBookTagMappingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$BookTagsTableReferences(db, table, p0)
                                .videoBookTagMappingsRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.tagId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
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
    (BookTagRow, $$BookTagsTableReferences),
    BookTagRow,
    PrefetchHooks Function(
        {bool bookTagMappingsRefs,
        bool srtBookTagMappingsRefs,
        bool videoBookTagMappingsRefs})>;
typedef $$BookTagMappingsTableCreateCompanionBuilder = BookTagMappingsCompanion
    Function({
  Value<int> id,
  required String bookKey,
  required int tagId,
});
typedef $$BookTagMappingsTableUpdateCompanionBuilder = BookTagMappingsCompanion
    Function({
  Value<int> id,
  Value<String> bookKey,
  Value<int> tagId,
});

final class $$BookTagMappingsTableReferences extends BaseReferences<
    _$HibikiDatabase, $BookTagMappingsTable, BookTagMappingRow> {
  $$BookTagMappingsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $EpubBooksTable _bookKeyTable(_$HibikiDatabase db) => db.epubBooks
      .createAlias('book_tag_mappings__book_key__epub_books__book_key');

  $$EpubBooksTableProcessedTableManager get bookKey {
    final $_column = $_itemColumn<String>('book_key')!;

    final manager = $$EpubBooksTableTableManager($_db, $_db.epubBooks)
        .filter((f) => f.bookKey.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookKeyTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $BookTagsTable _tagIdTable(_$HibikiDatabase db) =>
      db.bookTags.createAlias('book_tag_mappings__tag_id__book_tags__id');

  $$BookTagsTableProcessedTableManager get tagId {
    final $_column = $_itemColumn<int>('tag_id')!;

    final manager = $$BookTagsTableTableManager($_db, $_db.bookTags)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_tagIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

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

  $$EpubBooksTableFilterComposer get bookKey {
    final $$EpubBooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableFilterComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableFilterComposer get tagId {
    final $$BookTagsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableFilterComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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

  $$EpubBooksTableOrderingComposer get bookKey {
    final $$EpubBooksTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableOrderingComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableOrderingComposer get tagId {
    final $$BookTagsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableOrderingComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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

  $$EpubBooksTableAnnotationComposer get bookKey {
    final $$EpubBooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookKey,
        referencedTable: $db.epubBooks,
        getReferencedColumn: (t) => t.bookKey,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$EpubBooksTableAnnotationComposer(
              $db: $db,
              $table: $db.epubBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableAnnotationComposer get tagId {
    final $$BookTagsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableAnnotationComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
    (BookTagMappingRow, $$BookTagMappingsTableReferences),
    BookTagMappingRow,
    PrefetchHooks Function({bool bookKey, bool tagId})> {
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
            Value<String> bookKey = const Value.absent(),
            Value<int> tagId = const Value.absent(),
          }) =>
              BookTagMappingsCompanion(
            id: id,
            bookKey: bookKey,
            tagId: tagId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String bookKey,
            required int tagId,
          }) =>
              BookTagMappingsCompanion.insert(
            id: id,
            bookKey: bookKey,
            tagId: tagId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$BookTagMappingsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({bookKey = false, tagId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (bookKey) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.bookKey,
                    referencedTable:
                        $$BookTagMappingsTableReferences._bookKeyTable(db),
                    referencedColumn: $$BookTagMappingsTableReferences
                        ._bookKeyTable(db)
                        .bookKey,
                  ) as T;
                }
                if (tagId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.tagId,
                    referencedTable:
                        $$BookTagMappingsTableReferences._tagIdTable(db),
                    referencedColumn:
                        $$BookTagMappingsTableReferences._tagIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
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
    (BookTagMappingRow, $$BookTagMappingsTableReferences),
    BookTagMappingRow,
    PrefetchHooks Function({bool bookKey, bool tagId})>;
typedef $$SrtBookTagMappingsTableCreateCompanionBuilder
    = SrtBookTagMappingsCompanion Function({
  Value<int> id,
  required int srtBookId,
  required int tagId,
});
typedef $$SrtBookTagMappingsTableUpdateCompanionBuilder
    = SrtBookTagMappingsCompanion Function({
  Value<int> id,
  Value<int> srtBookId,
  Value<int> tagId,
});

final class $$SrtBookTagMappingsTableReferences extends BaseReferences<
    _$HibikiDatabase, $SrtBookTagMappingsTable, SrtBookTagMappingRow> {
  $$SrtBookTagMappingsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $SrtBooksTable _srtBookIdTable(_$HibikiDatabase db) => db.srtBooks
      .createAlias('srt_book_tag_mappings__srt_book_id__srt_books__id');

  $$SrtBooksTableProcessedTableManager get srtBookId {
    final $_column = $_itemColumn<int>('srt_book_id')!;

    final manager = $$SrtBooksTableTableManager($_db, $_db.srtBooks)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_srtBookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $BookTagsTable _tagIdTable(_$HibikiDatabase db) =>
      db.bookTags.createAlias('srt_book_tag_mappings__tag_id__book_tags__id');

  $$BookTagsTableProcessedTableManager get tagId {
    final $_column = $_itemColumn<int>('tag_id')!;

    final manager = $$BookTagsTableTableManager($_db, $_db.bookTags)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_tagIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$SrtBookTagMappingsTableFilterComposer
    extends Composer<_$HibikiDatabase, $SrtBookTagMappingsTable> {
  $$SrtBookTagMappingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  $$SrtBooksTableFilterComposer get srtBookId {
    final $$SrtBooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.srtBookId,
        referencedTable: $db.srtBooks,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SrtBooksTableFilterComposer(
              $db: $db,
              $table: $db.srtBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableFilterComposer get tagId {
    final $$BookTagsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableFilterComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SrtBookTagMappingsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $SrtBookTagMappingsTable> {
  $$SrtBookTagMappingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  $$SrtBooksTableOrderingComposer get srtBookId {
    final $$SrtBooksTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.srtBookId,
        referencedTable: $db.srtBooks,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SrtBooksTableOrderingComposer(
              $db: $db,
              $table: $db.srtBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableOrderingComposer get tagId {
    final $$BookTagsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableOrderingComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SrtBookTagMappingsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $SrtBookTagMappingsTable> {
  $$SrtBookTagMappingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  $$SrtBooksTableAnnotationComposer get srtBookId {
    final $$SrtBooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.srtBookId,
        referencedTable: $db.srtBooks,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SrtBooksTableAnnotationComposer(
              $db: $db,
              $table: $db.srtBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableAnnotationComposer get tagId {
    final $$BookTagsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableAnnotationComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SrtBookTagMappingsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $SrtBookTagMappingsTable,
    SrtBookTagMappingRow,
    $$SrtBookTagMappingsTableFilterComposer,
    $$SrtBookTagMappingsTableOrderingComposer,
    $$SrtBookTagMappingsTableAnnotationComposer,
    $$SrtBookTagMappingsTableCreateCompanionBuilder,
    $$SrtBookTagMappingsTableUpdateCompanionBuilder,
    (SrtBookTagMappingRow, $$SrtBookTagMappingsTableReferences),
    SrtBookTagMappingRow,
    PrefetchHooks Function({bool srtBookId, bool tagId})> {
  $$SrtBookTagMappingsTableTableManager(
      _$HibikiDatabase db, $SrtBookTagMappingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SrtBookTagMappingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SrtBookTagMappingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SrtBookTagMappingsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> srtBookId = const Value.absent(),
            Value<int> tagId = const Value.absent(),
          }) =>
              SrtBookTagMappingsCompanion(
            id: id,
            srtBookId: srtBookId,
            tagId: tagId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int srtBookId,
            required int tagId,
          }) =>
              SrtBookTagMappingsCompanion.insert(
            id: id,
            srtBookId: srtBookId,
            tagId: tagId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$SrtBookTagMappingsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({srtBookId = false, tagId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (srtBookId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.srtBookId,
                    referencedTable:
                        $$SrtBookTagMappingsTableReferences._srtBookIdTable(db),
                    referencedColumn: $$SrtBookTagMappingsTableReferences
                        ._srtBookIdTable(db)
                        .id,
                  ) as T;
                }
                if (tagId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.tagId,
                    referencedTable:
                        $$SrtBookTagMappingsTableReferences._tagIdTable(db),
                    referencedColumn:
                        $$SrtBookTagMappingsTableReferences._tagIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$SrtBookTagMappingsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $SrtBookTagMappingsTable,
    SrtBookTagMappingRow,
    $$SrtBookTagMappingsTableFilterComposer,
    $$SrtBookTagMappingsTableOrderingComposer,
    $$SrtBookTagMappingsTableAnnotationComposer,
    $$SrtBookTagMappingsTableCreateCompanionBuilder,
    $$SrtBookTagMappingsTableUpdateCompanionBuilder,
    (SrtBookTagMappingRow, $$SrtBookTagMappingsTableReferences),
    SrtBookTagMappingRow,
    PrefetchHooks Function({bool srtBookId, bool tagId})>;
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

final class $$ProfilesTableReferences
    extends BaseReferences<_$HibikiDatabase, $ProfilesTable, ProfileRow> {
  $$ProfilesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$ProfileSettingsTable, List<ProfileSettingRow>>
      _profileSettingsRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.profileSettings,
              aliasName: 'profiles__id__profile_settings__profile_id');

  $$ProfileSettingsTableProcessedTableManager get profileSettingsRefs {
    final manager =
        $$ProfileSettingsTableTableManager($_db, $_db.profileSettings)
            .filter((f) => f.profileId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_profileSettingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$MediaTypeProfilesTable, List<MediaTypeProfileRow>>
      _mediaTypeProfilesRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.mediaTypeProfiles,
              aliasName: 'profiles__id__media_type_profiles__profile_id');

  $$MediaTypeProfilesTableProcessedTableManager get mediaTypeProfilesRefs {
    final manager =
        $$MediaTypeProfilesTableTableManager($_db, $_db.mediaTypeProfiles)
            .filter((f) => f.profileId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache =
        $_typedResult.readTableOrNull(_mediaTypeProfilesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$BookProfilesTable, List<BookProfileRow>>
      _bookProfilesRefsTable(_$HibikiDatabase db) =>
          MultiTypedResultKey.fromTable(db.bookProfiles,
              aliasName: 'profiles__id__book_profiles__profile_id');

  $$BookProfilesTableProcessedTableManager get bookProfilesRefs {
    final manager = $$BookProfilesTableTableManager($_db, $_db.bookProfiles)
        .filter((f) => f.profileId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_bookProfilesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

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

  Expression<bool> profileSettingsRefs(
      Expression<bool> Function($$ProfileSettingsTableFilterComposer f) f) {
    final $$ProfileSettingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.profileSettings,
        getReferencedColumn: (t) => t.profileId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfileSettingsTableFilterComposer(
              $db: $db,
              $table: $db.profileSettings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> mediaTypeProfilesRefs(
      Expression<bool> Function($$MediaTypeProfilesTableFilterComposer f) f) {
    final $$MediaTypeProfilesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.mediaTypeProfiles,
        getReferencedColumn: (t) => t.profileId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaTypeProfilesTableFilterComposer(
              $db: $db,
              $table: $db.mediaTypeProfiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<bool> bookProfilesRefs(
      Expression<bool> Function($$BookProfilesTableFilterComposer f) f) {
    final $$BookProfilesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.bookProfiles,
        getReferencedColumn: (t) => t.profileId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookProfilesTableFilterComposer(
              $db: $db,
              $table: $db.bookProfiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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

  Expression<T> profileSettingsRefs<T extends Object>(
      Expression<T> Function($$ProfileSettingsTableAnnotationComposer a) f) {
    final $$ProfileSettingsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.profileSettings,
        getReferencedColumn: (t) => t.profileId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfileSettingsTableAnnotationComposer(
              $db: $db,
              $table: $db.profileSettings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }

  Expression<T> mediaTypeProfilesRefs<T extends Object>(
      Expression<T> Function($$MediaTypeProfilesTableAnnotationComposer a) f) {
    final $$MediaTypeProfilesTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $db.mediaTypeProfiles,
            getReferencedColumn: (t) => t.profileId,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$MediaTypeProfilesTableAnnotationComposer(
                  $db: $db,
                  $table: $db.mediaTypeProfiles,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }

  Expression<T> bookProfilesRefs<T extends Object>(
      Expression<T> Function($$BookProfilesTableAnnotationComposer a) f) {
    final $$BookProfilesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.bookProfiles,
        getReferencedColumn: (t) => t.profileId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookProfilesTableAnnotationComposer(
              $db: $db,
              $table: $db.bookProfiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
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
    (ProfileRow, $$ProfilesTableReferences),
    ProfileRow,
    PrefetchHooks Function(
        {bool profileSettingsRefs,
        bool mediaTypeProfilesRefs,
        bool bookProfilesRefs})> {
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
              .map((e) =>
                  (e.readTable(table), $$ProfilesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {profileSettingsRefs = false,
              mediaTypeProfilesRefs = false,
              bookProfilesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (profileSettingsRefs) db.profileSettings,
                if (mediaTypeProfilesRefs) db.mediaTypeProfiles,
                if (bookProfilesRefs) db.bookProfiles
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (profileSettingsRefs)
                    await $_getPrefetchedData<ProfileRow, $ProfilesTable,
                            ProfileSettingRow>(
                        currentTable: table,
                        referencedTable: $$ProfilesTableReferences
                            ._profileSettingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ProfilesTableReferences(db, table, p0)
                                .profileSettingsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.profileId == item.id),
                        typedResults: items),
                  if (mediaTypeProfilesRefs)
                    await $_getPrefetchedData<ProfileRow, $ProfilesTable,
                            MediaTypeProfileRow>(
                        currentTable: table,
                        referencedTable: $$ProfilesTableReferences
                            ._mediaTypeProfilesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ProfilesTableReferences(db, table, p0)
                                .mediaTypeProfilesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.profileId == item.id),
                        typedResults: items),
                  if (bookProfilesRefs)
                    await $_getPrefetchedData<ProfileRow, $ProfilesTable,
                            BookProfileRow>(
                        currentTable: table,
                        referencedTable: $$ProfilesTableReferences
                            ._bookProfilesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ProfilesTableReferences(db, table, p0)
                                .bookProfilesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.profileId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
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
    (ProfileRow, $$ProfilesTableReferences),
    ProfileRow,
    PrefetchHooks Function(
        {bool profileSettingsRefs,
        bool mediaTypeProfilesRefs,
        bool bookProfilesRefs})>;
typedef $$ProfileSettingsTableCreateCompanionBuilder = ProfileSettingsCompanion
    Function({
  Value<int> id,
  required int profileId,
  required String category,
  required String key,
  required String value,
});
typedef $$ProfileSettingsTableUpdateCompanionBuilder = ProfileSettingsCompanion
    Function({
  Value<int> id,
  Value<int> profileId,
  Value<String> category,
  Value<String> key,
  Value<String> value,
});

final class $$ProfileSettingsTableReferences extends BaseReferences<
    _$HibikiDatabase, $ProfileSettingsTable, ProfileSettingRow> {
  $$ProfileSettingsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $ProfilesTable _profileIdTable(_$HibikiDatabase db) =>
      db.profiles.createAlias('profile_settings__profile_id__profiles__id');

  $$ProfilesTableProcessedTableManager get profileId {
    final $_column = $_itemColumn<int>('profile_id')!;

    final manager = $$ProfilesTableTableManager($_db, $_db.profiles)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_profileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

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

  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));

  $$ProfilesTableFilterComposer get profileId {
    final $$ProfilesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableFilterComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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

  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));

  $$ProfilesTableOrderingComposer get profileId {
    final $$ProfilesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableOrderingComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  $$ProfilesTableAnnotationComposer get profileId {
    final $$ProfilesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableAnnotationComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
    (ProfileSettingRow, $$ProfileSettingsTableReferences),
    ProfileSettingRow,
    PrefetchHooks Function({bool profileId})> {
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
              $$ProfileSettingsTableAnnotationComposer($db: db, $table: table),
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
              .map((e) => (
                    e.readTable(table),
                    $$ProfileSettingsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({profileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (profileId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.profileId,
                    referencedTable:
                        $$ProfileSettingsTableReferences._profileIdTable(db),
                    referencedColumn:
                        $$ProfileSettingsTableReferences._profileIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
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
    (ProfileSettingRow, $$ProfileSettingsTableReferences),
    ProfileSettingRow,
    PrefetchHooks Function({bool profileId})>;
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

final class $$MediaTypeProfilesTableReferences extends BaseReferences<
    _$HibikiDatabase, $MediaTypeProfilesTable, MediaTypeProfileRow> {
  $$MediaTypeProfilesTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $ProfilesTable _profileIdTable(_$HibikiDatabase db) =>
      db.profiles.createAlias('media_type_profiles__profile_id__profiles__id');

  $$ProfilesTableProcessedTableManager get profileId {
    final $_column = $_itemColumn<int>('profile_id')!;

    final manager = $$ProfilesTableTableManager($_db, $_db.profiles)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_profileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

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

  $$ProfilesTableFilterComposer get profileId {
    final $$ProfilesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableFilterComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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

  $$ProfilesTableOrderingComposer get profileId {
    final $$ProfilesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableOrderingComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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

  $$ProfilesTableAnnotationComposer get profileId {
    final $$ProfilesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableAnnotationComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
    (MediaTypeProfileRow, $$MediaTypeProfilesTableReferences),
    MediaTypeProfileRow,
    PrefetchHooks Function({bool profileId})> {
  $$MediaTypeProfilesTableTableManager(
      _$HibikiDatabase db, $MediaTypeProfilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaTypeProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaTypeProfilesTableOrderingComposer($db: db, $table: table),
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
              .map((e) => (
                    e.readTable(table),
                    $$MediaTypeProfilesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({profileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (profileId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.profileId,
                    referencedTable:
                        $$MediaTypeProfilesTableReferences._profileIdTable(db),
                    referencedColumn: $$MediaTypeProfilesTableReferences
                        ._profileIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
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
    (MediaTypeProfileRow, $$MediaTypeProfilesTableReferences),
    MediaTypeProfileRow,
    PrefetchHooks Function({bool profileId})>;
typedef $$BookProfilesTableCreateCompanionBuilder = BookProfilesCompanion
    Function({
  required String bookKey,
  required int profileId,
  Value<int> rowid,
});
typedef $$BookProfilesTableUpdateCompanionBuilder = BookProfilesCompanion
    Function({
  Value<String> bookKey,
  Value<int> profileId,
  Value<int> rowid,
});

final class $$BookProfilesTableReferences extends BaseReferences<
    _$HibikiDatabase, $BookProfilesTable, BookProfileRow> {
  $$BookProfilesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ProfilesTable _profileIdTable(_$HibikiDatabase db) =>
      db.profiles.createAlias('book_profiles__profile_id__profiles__id');

  $$ProfilesTableProcessedTableManager get profileId {
    final $_column = $_itemColumn<int>('profile_id')!;

    final manager = $$ProfilesTableTableManager($_db, $_db.profiles)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_profileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$BookProfilesTableFilterComposer
    extends Composer<_$HibikiDatabase, $BookProfilesTable> {
  $$BookProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

  $$ProfilesTableFilterComposer get profileId {
    final $$ProfilesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableFilterComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));

  $$ProfilesTableOrderingComposer get profileId {
    final $$ProfilesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableOrderingComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

  $$ProfilesTableAnnotationComposer get profileId {
    final $$ProfilesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.profileId,
        referencedTable: $db.profiles,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ProfilesTableAnnotationComposer(
              $db: $db,
              $table: $db.profiles,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
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
    (BookProfileRow, $$BookProfilesTableReferences),
    BookProfileRow,
    PrefetchHooks Function({bool profileId})> {
  $$BookProfilesTableTableManager(_$HibikiDatabase db, $BookProfilesTable table)
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
            Value<String> bookKey = const Value.absent(),
            Value<int> profileId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BookProfilesCompanion(
            bookKey: bookKey,
            profileId: profileId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String bookKey,
            required int profileId,
            Value<int> rowid = const Value.absent(),
          }) =>
              BookProfilesCompanion.insert(
            bookKey: bookKey,
            profileId: profileId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$BookProfilesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({profileId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (profileId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.profileId,
                    referencedTable:
                        $$BookProfilesTableReferences._profileIdTable(db),
                    referencedColumn:
                        $$BookProfilesTableReferences._profileIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
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
    (BookProfileRow, $$BookProfilesTableReferences),
    BookProfileRow,
    PrefetchHooks Function({bool profileId})>;
typedef $$SyncBaselinesTableCreateCompanionBuilder = SyncBaselinesCompanion
    Function({
  required String assetKey,
  required String dimension,
  required int baseVersion,
  Value<int> rowid,
});
typedef $$SyncBaselinesTableUpdateCompanionBuilder = SyncBaselinesCompanion
    Function({
  Value<String> assetKey,
  Value<String> dimension,
  Value<int> baseVersion,
  Value<int> rowid,
});

class $$SyncBaselinesTableFilterComposer
    extends Composer<_$HibikiDatabase, $SyncBaselinesTable> {
  $$SyncBaselinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get assetKey => $composableBuilder(
      column: $table.assetKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dimension => $composableBuilder(
      column: $table.dimension, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get baseVersion => $composableBuilder(
      column: $table.baseVersion, builder: (column) => ColumnFilters(column));
}

class $$SyncBaselinesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $SyncBaselinesTable> {
  $$SyncBaselinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get assetKey => $composableBuilder(
      column: $table.assetKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dimension => $composableBuilder(
      column: $table.dimension, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get baseVersion => $composableBuilder(
      column: $table.baseVersion, builder: (column) => ColumnOrderings(column));
}

class $$SyncBaselinesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $SyncBaselinesTable> {
  $$SyncBaselinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get assetKey =>
      $composableBuilder(column: $table.assetKey, builder: (column) => column);

  GeneratedColumn<String> get dimension =>
      $composableBuilder(column: $table.dimension, builder: (column) => column);

  GeneratedColumn<int> get baseVersion => $composableBuilder(
      column: $table.baseVersion, builder: (column) => column);
}

class $$SyncBaselinesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $SyncBaselinesTable,
    SyncBaselineRow,
    $$SyncBaselinesTableFilterComposer,
    $$SyncBaselinesTableOrderingComposer,
    $$SyncBaselinesTableAnnotationComposer,
    $$SyncBaselinesTableCreateCompanionBuilder,
    $$SyncBaselinesTableUpdateCompanionBuilder,
    (
      SyncBaselineRow,
      BaseReferences<_$HibikiDatabase, $SyncBaselinesTable, SyncBaselineRow>
    ),
    SyncBaselineRow,
    PrefetchHooks Function()> {
  $$SyncBaselinesTableTableManager(
      _$HibikiDatabase db, $SyncBaselinesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncBaselinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncBaselinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncBaselinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> assetKey = const Value.absent(),
            Value<String> dimension = const Value.absent(),
            Value<int> baseVersion = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncBaselinesCompanion(
            assetKey: assetKey,
            dimension: dimension,
            baseVersion: baseVersion,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String assetKey,
            required String dimension,
            required int baseVersion,
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncBaselinesCompanion.insert(
            assetKey: assetKey,
            dimension: dimension,
            baseVersion: baseVersion,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncBaselinesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $SyncBaselinesTable,
    SyncBaselineRow,
    $$SyncBaselinesTableFilterComposer,
    $$SyncBaselinesTableOrderingComposer,
    $$SyncBaselinesTableAnnotationComposer,
    $$SyncBaselinesTableCreateCompanionBuilder,
    $$SyncBaselinesTableUpdateCompanionBuilder,
    (
      SyncBaselineRow,
      BaseReferences<_$HibikiDatabase, $SyncBaselinesTable, SyncBaselineRow>
    ),
    SyncBaselineRow,
    PrefetchHooks Function()>;
typedef $$VideoBooksTableCreateCompanionBuilder = VideoBooksCompanion Function({
  required String bookUid,
  required String title,
  required String videoPath,
  Value<String?> subtitleSource,
  Value<String?> subtitleFormat,
  Value<int?> embeddedSubtitleTrack,
  Value<String?> coverPath,
  Value<int> lastPositionMs,
  Value<DateTime?> importedAt,
  Value<String?> playlistJson,
  Value<int> currentEpisode,
  Value<String?> audioTrackId,
  Value<int> delayMs,
  Value<DateTime?> completedAt,
  Value<int?> sourceId,
  Value<int> rowid,
});
typedef $$VideoBooksTableUpdateCompanionBuilder = VideoBooksCompanion Function({
  Value<String> bookUid,
  Value<String> title,
  Value<String> videoPath,
  Value<String?> subtitleSource,
  Value<String?> subtitleFormat,
  Value<int?> embeddedSubtitleTrack,
  Value<String?> coverPath,
  Value<int> lastPositionMs,
  Value<DateTime?> importedAt,
  Value<String?> playlistJson,
  Value<int> currentEpisode,
  Value<String?> audioTrackId,
  Value<int> delayMs,
  Value<DateTime?> completedAt,
  Value<int?> sourceId,
  Value<int> rowid,
});

final class $$VideoBooksTableReferences
    extends BaseReferences<_$HibikiDatabase, $VideoBooksTable, VideoBookRow> {
  $$VideoBooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MediaSourcesTable _sourceIdTable(_$HibikiDatabase db) =>
      db.mediaSources.createAlias('video_books__source_id__media_sources__id');

  $$MediaSourcesTableProcessedTableManager? get sourceId {
    final $_column = $_itemColumn<int>('source_id');
    if ($_column == null) return null;
    final manager = $$MediaSourcesTableTableManager($_db, $_db.mediaSources)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sourceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$VideoBookTagMappingsTable,
      List<VideoBookTagMappingRow>> _videoBookTagMappingsRefsTable(
          _$HibikiDatabase db) =>
      MultiTypedResultKey.fromTable(db.videoBookTagMappings,
          aliasName:
              'video_books__book_uid__video_book_tag_mappings__video_book_uid');

  $$VideoBookTagMappingsTableProcessedTableManager
      get videoBookTagMappingsRefs {
    final manager =
        $$VideoBookTagMappingsTableTableManager($_db, $_db.videoBookTagMappings)
            .filter((f) => f.videoBookUid.bookUid
                .sqlEquals($_itemColumn<String>('book_uid')!));

    final cache =
        $_typedResult.readTableOrNull(_videoBookTagMappingsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$VideoBooksTableFilterComposer
    extends Composer<_$HibikiDatabase, $VideoBooksTable> {
  $$VideoBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get videoPath => $composableBuilder(
      column: $table.videoPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get subtitleSource => $composableBuilder(
      column: $table.subtitleSource,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get subtitleFormat => $composableBuilder(
      column: $table.subtitleFormat,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get embeddedSubtitleTrack => $composableBuilder(
      column: $table.embeddedSubtitleTrack,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastPositionMs => $composableBuilder(
      column: $table.lastPositionMs,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get playlistJson => $composableBuilder(
      column: $table.playlistJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get currentEpisode => $composableBuilder(
      column: $table.currentEpisode,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioTrackId => $composableBuilder(
      column: $table.audioTrackId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get delayMs => $composableBuilder(
      column: $table.delayMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnFilters(column));

  $$MediaSourcesTableFilterComposer get sourceId {
    final $$MediaSourcesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.sourceId,
        referencedTable: $db.mediaSources,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaSourcesTableFilterComposer(
              $db: $db,
              $table: $db.mediaSources,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> videoBookTagMappingsRefs(
      Expression<bool> Function($$VideoBookTagMappingsTableFilterComposer f)
          f) {
    final $$VideoBookTagMappingsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.bookUid,
        referencedTable: $db.videoBookTagMappings,
        getReferencedColumn: (t) => t.videoBookUid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBookTagMappingsTableFilterComposer(
              $db: $db,
              $table: $db.videoBookTagMappings,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$VideoBooksTableOrderingComposer
    extends Composer<_$HibikiDatabase, $VideoBooksTable> {
  $$VideoBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookUid => $composableBuilder(
      column: $table.bookUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get videoPath => $composableBuilder(
      column: $table.videoPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get subtitleSource => $composableBuilder(
      column: $table.subtitleSource,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get subtitleFormat => $composableBuilder(
      column: $table.subtitleFormat,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get embeddedSubtitleTrack => $composableBuilder(
      column: $table.embeddedSubtitleTrack,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverPath => $composableBuilder(
      column: $table.coverPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastPositionMs => $composableBuilder(
      column: $table.lastPositionMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get playlistJson => $composableBuilder(
      column: $table.playlistJson,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get currentEpisode => $composableBuilder(
      column: $table.currentEpisode,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioTrackId => $composableBuilder(
      column: $table.audioTrackId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get delayMs => $composableBuilder(
      column: $table.delayMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnOrderings(column));

  $$MediaSourcesTableOrderingComposer get sourceId {
    final $$MediaSourcesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.sourceId,
        referencedTable: $db.mediaSources,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaSourcesTableOrderingComposer(
              $db: $db,
              $table: $db.mediaSources,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VideoBooksTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $VideoBooksTable> {
  $$VideoBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookUid =>
      $composableBuilder(column: $table.bookUid, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get videoPath =>
      $composableBuilder(column: $table.videoPath, builder: (column) => column);

  GeneratedColumn<String> get subtitleSource => $composableBuilder(
      column: $table.subtitleSource, builder: (column) => column);

  GeneratedColumn<String> get subtitleFormat => $composableBuilder(
      column: $table.subtitleFormat, builder: (column) => column);

  GeneratedColumn<int> get embeddedSubtitleTrack => $composableBuilder(
      column: $table.embeddedSubtitleTrack, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<int> get lastPositionMs => $composableBuilder(
      column: $table.lastPositionMs, builder: (column) => column);

  GeneratedColumn<DateTime> get importedAt => $composableBuilder(
      column: $table.importedAt, builder: (column) => column);

  GeneratedColumn<String> get playlistJson => $composableBuilder(
      column: $table.playlistJson, builder: (column) => column);

  GeneratedColumn<int> get currentEpisode => $composableBuilder(
      column: $table.currentEpisode, builder: (column) => column);

  GeneratedColumn<String> get audioTrackId => $composableBuilder(
      column: $table.audioTrackId, builder: (column) => column);

  GeneratedColumn<int> get delayMs =>
      $composableBuilder(column: $table.delayMs, builder: (column) => column);

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => column);

  $$MediaSourcesTableAnnotationComposer get sourceId {
    final $$MediaSourcesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.sourceId,
        referencedTable: $db.mediaSources,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MediaSourcesTableAnnotationComposer(
              $db: $db,
              $table: $db.mediaSources,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> videoBookTagMappingsRefs<T extends Object>(
      Expression<T> Function($$VideoBookTagMappingsTableAnnotationComposer a)
          f) {
    final $$VideoBookTagMappingsTableAnnotationComposer composer =
        $composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.bookUid,
            referencedTable: $db.videoBookTagMappings,
            getReferencedColumn: (t) => t.videoBookUid,
            builder: (joinBuilder,
                    {$addJoinBuilderToRootComposer,
                    $removeJoinBuilderFromRootComposer}) =>
                $$VideoBookTagMappingsTableAnnotationComposer(
                  $db: $db,
                  $table: $db.videoBookTagMappings,
                  $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                  joinBuilder: joinBuilder,
                  $removeJoinBuilderFromRootComposer:
                      $removeJoinBuilderFromRootComposer,
                ));
    return f(composer);
  }
}

class $$VideoBooksTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $VideoBooksTable,
    VideoBookRow,
    $$VideoBooksTableFilterComposer,
    $$VideoBooksTableOrderingComposer,
    $$VideoBooksTableAnnotationComposer,
    $$VideoBooksTableCreateCompanionBuilder,
    $$VideoBooksTableUpdateCompanionBuilder,
    (VideoBookRow, $$VideoBooksTableReferences),
    VideoBookRow,
    PrefetchHooks Function({bool sourceId, bool videoBookTagMappingsRefs})> {
  $$VideoBooksTableTableManager(_$HibikiDatabase db, $VideoBooksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VideoBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VideoBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VideoBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> bookUid = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> videoPath = const Value.absent(),
            Value<String?> subtitleSource = const Value.absent(),
            Value<String?> subtitleFormat = const Value.absent(),
            Value<int?> embeddedSubtitleTrack = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            Value<int> lastPositionMs = const Value.absent(),
            Value<DateTime?> importedAt = const Value.absent(),
            Value<String?> playlistJson = const Value.absent(),
            Value<int> currentEpisode = const Value.absent(),
            Value<String?> audioTrackId = const Value.absent(),
            Value<int> delayMs = const Value.absent(),
            Value<DateTime?> completedAt = const Value.absent(),
            Value<int?> sourceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              VideoBooksCompanion(
            bookUid: bookUid,
            title: title,
            videoPath: videoPath,
            subtitleSource: subtitleSource,
            subtitleFormat: subtitleFormat,
            embeddedSubtitleTrack: embeddedSubtitleTrack,
            coverPath: coverPath,
            lastPositionMs: lastPositionMs,
            importedAt: importedAt,
            playlistJson: playlistJson,
            currentEpisode: currentEpisode,
            audioTrackId: audioTrackId,
            delayMs: delayMs,
            completedAt: completedAt,
            sourceId: sourceId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String bookUid,
            required String title,
            required String videoPath,
            Value<String?> subtitleSource = const Value.absent(),
            Value<String?> subtitleFormat = const Value.absent(),
            Value<int?> embeddedSubtitleTrack = const Value.absent(),
            Value<String?> coverPath = const Value.absent(),
            Value<int> lastPositionMs = const Value.absent(),
            Value<DateTime?> importedAt = const Value.absent(),
            Value<String?> playlistJson = const Value.absent(),
            Value<int> currentEpisode = const Value.absent(),
            Value<String?> audioTrackId = const Value.absent(),
            Value<int> delayMs = const Value.absent(),
            Value<DateTime?> completedAt = const Value.absent(),
            Value<int?> sourceId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              VideoBooksCompanion.insert(
            bookUid: bookUid,
            title: title,
            videoPath: videoPath,
            subtitleSource: subtitleSource,
            subtitleFormat: subtitleFormat,
            embeddedSubtitleTrack: embeddedSubtitleTrack,
            coverPath: coverPath,
            lastPositionMs: lastPositionMs,
            importedAt: importedAt,
            playlistJson: playlistJson,
            currentEpisode: currentEpisode,
            audioTrackId: audioTrackId,
            delayMs: delayMs,
            completedAt: completedAt,
            sourceId: sourceId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$VideoBooksTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {sourceId = false, videoBookTagMappingsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (videoBookTagMappingsRefs) db.videoBookTagMappings
              ],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (sourceId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.sourceId,
                    referencedTable:
                        $$VideoBooksTableReferences._sourceIdTable(db),
                    referencedColumn:
                        $$VideoBooksTableReferences._sourceIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (videoBookTagMappingsRefs)
                    await $_getPrefetchedData<VideoBookRow, $VideoBooksTable,
                            VideoBookTagMappingRow>(
                        currentTable: table,
                        referencedTable: $$VideoBooksTableReferences
                            ._videoBookTagMappingsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$VideoBooksTableReferences(db, table, p0)
                                .videoBookTagMappingsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.videoBookUid == item.bookUid),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$VideoBooksTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $VideoBooksTable,
    VideoBookRow,
    $$VideoBooksTableFilterComposer,
    $$VideoBooksTableOrderingComposer,
    $$VideoBooksTableAnnotationComposer,
    $$VideoBooksTableCreateCompanionBuilder,
    $$VideoBooksTableUpdateCompanionBuilder,
    (VideoBookRow, $$VideoBooksTableReferences),
    VideoBookRow,
    PrefetchHooks Function({bool sourceId, bool videoBookTagMappingsRefs})>;
typedef $$VideoBookTagMappingsTableCreateCompanionBuilder
    = VideoBookTagMappingsCompanion Function({
  Value<int> id,
  required String videoBookUid,
  required int tagId,
});
typedef $$VideoBookTagMappingsTableUpdateCompanionBuilder
    = VideoBookTagMappingsCompanion Function({
  Value<int> id,
  Value<String> videoBookUid,
  Value<int> tagId,
});

final class $$VideoBookTagMappingsTableReferences extends BaseReferences<
    _$HibikiDatabase, $VideoBookTagMappingsTable, VideoBookTagMappingRow> {
  $$VideoBookTagMappingsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $VideoBooksTable _videoBookUidTable(_$HibikiDatabase db) =>
      db.videoBooks.createAlias(
          'video_book_tag_mappings__video_book_uid__video_books__book_uid');

  $$VideoBooksTableProcessedTableManager get videoBookUid {
    final $_column = $_itemColumn<String>('video_book_uid')!;

    final manager = $$VideoBooksTableTableManager($_db, $_db.videoBooks)
        .filter((f) => f.bookUid.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_videoBookUidTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static $BookTagsTable _tagIdTable(_$HibikiDatabase db) =>
      db.bookTags.createAlias('video_book_tag_mappings__tag_id__book_tags__id');

  $$BookTagsTableProcessedTableManager get tagId {
    final $_column = $_itemColumn<int>('tag_id')!;

    final manager = $$BookTagsTableTableManager($_db, $_db.bookTags)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_tagIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$VideoBookTagMappingsTableFilterComposer
    extends Composer<_$HibikiDatabase, $VideoBookTagMappingsTable> {
  $$VideoBookTagMappingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  $$VideoBooksTableFilterComposer get videoBookUid {
    final $$VideoBooksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.videoBookUid,
        referencedTable: $db.videoBooks,
        getReferencedColumn: (t) => t.bookUid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBooksTableFilterComposer(
              $db: $db,
              $table: $db.videoBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableFilterComposer get tagId {
    final $$BookTagsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableFilterComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VideoBookTagMappingsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $VideoBookTagMappingsTable> {
  $$VideoBookTagMappingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  $$VideoBooksTableOrderingComposer get videoBookUid {
    final $$VideoBooksTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.videoBookUid,
        referencedTable: $db.videoBooks,
        getReferencedColumn: (t) => t.bookUid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBooksTableOrderingComposer(
              $db: $db,
              $table: $db.videoBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableOrderingComposer get tagId {
    final $$BookTagsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableOrderingComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VideoBookTagMappingsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $VideoBookTagMappingsTable> {
  $$VideoBookTagMappingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  $$VideoBooksTableAnnotationComposer get videoBookUid {
    final $$VideoBooksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.videoBookUid,
        referencedTable: $db.videoBooks,
        getReferencedColumn: (t) => t.bookUid,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$VideoBooksTableAnnotationComposer(
              $db: $db,
              $table: $db.videoBooks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  $$BookTagsTableAnnotationComposer get tagId {
    final $$BookTagsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.tagId,
        referencedTable: $db.bookTags,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$BookTagsTableAnnotationComposer(
              $db: $db,
              $table: $db.bookTags,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$VideoBookTagMappingsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $VideoBookTagMappingsTable,
    VideoBookTagMappingRow,
    $$VideoBookTagMappingsTableFilterComposer,
    $$VideoBookTagMappingsTableOrderingComposer,
    $$VideoBookTagMappingsTableAnnotationComposer,
    $$VideoBookTagMappingsTableCreateCompanionBuilder,
    $$VideoBookTagMappingsTableUpdateCompanionBuilder,
    (VideoBookTagMappingRow, $$VideoBookTagMappingsTableReferences),
    VideoBookTagMappingRow,
    PrefetchHooks Function({bool videoBookUid, bool tagId})> {
  $$VideoBookTagMappingsTableTableManager(
      _$HibikiDatabase db, $VideoBookTagMappingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VideoBookTagMappingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VideoBookTagMappingsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VideoBookTagMappingsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> videoBookUid = const Value.absent(),
            Value<int> tagId = const Value.absent(),
          }) =>
              VideoBookTagMappingsCompanion(
            id: id,
            videoBookUid: videoBookUid,
            tagId: tagId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String videoBookUid,
            required int tagId,
          }) =>
              VideoBookTagMappingsCompanion.insert(
            id: id,
            videoBookUid: videoBookUid,
            tagId: tagId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$VideoBookTagMappingsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({videoBookUid = false, tagId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (videoBookUid) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.videoBookUid,
                    referencedTable: $$VideoBookTagMappingsTableReferences
                        ._videoBookUidTable(db),
                    referencedColumn: $$VideoBookTagMappingsTableReferences
                        ._videoBookUidTable(db)
                        .bookUid,
                  ) as T;
                }
                if (tagId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.tagId,
                    referencedTable:
                        $$VideoBookTagMappingsTableReferences._tagIdTable(db),
                    referencedColumn: $$VideoBookTagMappingsTableReferences
                        ._tagIdTable(db)
                        .id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$VideoBookTagMappingsTableProcessedTableManager
    = ProcessedTableManager<
        _$HibikiDatabase,
        $VideoBookTagMappingsTable,
        VideoBookTagMappingRow,
        $$VideoBookTagMappingsTableFilterComposer,
        $$VideoBookTagMappingsTableOrderingComposer,
        $$VideoBookTagMappingsTableAnnotationComposer,
        $$VideoBookTagMappingsTableCreateCompanionBuilder,
        $$VideoBookTagMappingsTableUpdateCompanionBuilder,
        (VideoBookTagMappingRow, $$VideoBookTagMappingsTableReferences),
        VideoBookTagMappingRow,
        PrefetchHooks Function({bool videoBookUid, bool tagId})>;
typedef $$VideoWatchStatisticsTableCreateCompanionBuilder
    = VideoWatchStatisticsCompanion Function({
  Value<int> id,
  required String title,
  required String dateKey,
  required int subtitleChars,
  required int watchTimeMs,
  required int lastModified,
});
typedef $$VideoWatchStatisticsTableUpdateCompanionBuilder
    = VideoWatchStatisticsCompanion Function({
  Value<int> id,
  Value<String> title,
  Value<String> dateKey,
  Value<int> subtitleChars,
  Value<int> watchTimeMs,
  Value<int> lastModified,
});

class $$VideoWatchStatisticsTableFilterComposer
    extends Composer<_$HibikiDatabase, $VideoWatchStatisticsTable> {
  $$VideoWatchStatisticsTableFilterComposer({
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

  ColumnFilters<int> get subtitleChars => $composableBuilder(
      column: $table.subtitleChars, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get watchTimeMs => $composableBuilder(
      column: $table.watchTimeMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastModified => $composableBuilder(
      column: $table.lastModified, builder: (column) => ColumnFilters(column));
}

class $$VideoWatchStatisticsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $VideoWatchStatisticsTable> {
  $$VideoWatchStatisticsTableOrderingComposer({
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

  ColumnOrderings<int> get subtitleChars => $composableBuilder(
      column: $table.subtitleChars,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get watchTimeMs => $composableBuilder(
      column: $table.watchTimeMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastModified => $composableBuilder(
      column: $table.lastModified,
      builder: (column) => ColumnOrderings(column));
}

class $$VideoWatchStatisticsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $VideoWatchStatisticsTable> {
  $$VideoWatchStatisticsTableAnnotationComposer({
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

  GeneratedColumn<int> get subtitleChars => $composableBuilder(
      column: $table.subtitleChars, builder: (column) => column);

  GeneratedColumn<int> get watchTimeMs => $composableBuilder(
      column: $table.watchTimeMs, builder: (column) => column);

  GeneratedColumn<int> get lastModified => $composableBuilder(
      column: $table.lastModified, builder: (column) => column);
}

class $$VideoWatchStatisticsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $VideoWatchStatisticsTable,
    VideoWatchStatisticRow,
    $$VideoWatchStatisticsTableFilterComposer,
    $$VideoWatchStatisticsTableOrderingComposer,
    $$VideoWatchStatisticsTableAnnotationComposer,
    $$VideoWatchStatisticsTableCreateCompanionBuilder,
    $$VideoWatchStatisticsTableUpdateCompanionBuilder,
    (
      VideoWatchStatisticRow,
      BaseReferences<_$HibikiDatabase, $VideoWatchStatisticsTable,
          VideoWatchStatisticRow>
    ),
    VideoWatchStatisticRow,
    PrefetchHooks Function()> {
  $$VideoWatchStatisticsTableTableManager(
      _$HibikiDatabase db, $VideoWatchStatisticsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VideoWatchStatisticsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VideoWatchStatisticsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VideoWatchStatisticsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> subtitleChars = const Value.absent(),
            Value<int> watchTimeMs = const Value.absent(),
            Value<int> lastModified = const Value.absent(),
          }) =>
              VideoWatchStatisticsCompanion(
            id: id,
            title: title,
            dateKey: dateKey,
            subtitleChars: subtitleChars,
            watchTimeMs: watchTimeMs,
            lastModified: lastModified,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String title,
            required String dateKey,
            required int subtitleChars,
            required int watchTimeMs,
            required int lastModified,
          }) =>
              VideoWatchStatisticsCompanion.insert(
            id: id,
            title: title,
            dateKey: dateKey,
            subtitleChars: subtitleChars,
            watchTimeMs: watchTimeMs,
            lastModified: lastModified,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$VideoWatchStatisticsTableProcessedTableManager
    = ProcessedTableManager<
        _$HibikiDatabase,
        $VideoWatchStatisticsTable,
        VideoWatchStatisticRow,
        $$VideoWatchStatisticsTableFilterComposer,
        $$VideoWatchStatisticsTableOrderingComposer,
        $$VideoWatchStatisticsTableAnnotationComposer,
        $$VideoWatchStatisticsTableCreateCompanionBuilder,
        $$VideoWatchStatisticsTableUpdateCompanionBuilder,
        (
          VideoWatchStatisticRow,
          BaseReferences<_$HibikiDatabase, $VideoWatchStatisticsTable,
              VideoWatchStatisticRow>
        ),
        VideoWatchStatisticRow,
        PrefetchHooks Function()>;
typedef $$VideoHourlyLogsTableCreateCompanionBuilder = VideoHourlyLogsCompanion
    Function({
  Value<int> id,
  required String dateKey,
  required int hour,
  required int watchTimeMs,
});
typedef $$VideoHourlyLogsTableUpdateCompanionBuilder = VideoHourlyLogsCompanion
    Function({
  Value<int> id,
  Value<String> dateKey,
  Value<int> hour,
  Value<int> watchTimeMs,
});

class $$VideoHourlyLogsTableFilterComposer
    extends Composer<_$HibikiDatabase, $VideoHourlyLogsTable> {
  $$VideoHourlyLogsTableFilterComposer({
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

  ColumnFilters<int> get watchTimeMs => $composableBuilder(
      column: $table.watchTimeMs, builder: (column) => ColumnFilters(column));
}

class $$VideoHourlyLogsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $VideoHourlyLogsTable> {
  $$VideoHourlyLogsTableOrderingComposer({
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

  ColumnOrderings<int> get watchTimeMs => $composableBuilder(
      column: $table.watchTimeMs, builder: (column) => ColumnOrderings(column));
}

class $$VideoHourlyLogsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $VideoHourlyLogsTable> {
  $$VideoHourlyLogsTableAnnotationComposer({
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

  GeneratedColumn<int> get watchTimeMs => $composableBuilder(
      column: $table.watchTimeMs, builder: (column) => column);
}

class $$VideoHourlyLogsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $VideoHourlyLogsTable,
    VideoHourlyLogRow,
    $$VideoHourlyLogsTableFilterComposer,
    $$VideoHourlyLogsTableOrderingComposer,
    $$VideoHourlyLogsTableAnnotationComposer,
    $$VideoHourlyLogsTableCreateCompanionBuilder,
    $$VideoHourlyLogsTableUpdateCompanionBuilder,
    (
      VideoHourlyLogRow,
      BaseReferences<_$HibikiDatabase, $VideoHourlyLogsTable, VideoHourlyLogRow>
    ),
    VideoHourlyLogRow,
    PrefetchHooks Function()> {
  $$VideoHourlyLogsTableTableManager(
      _$HibikiDatabase db, $VideoHourlyLogsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VideoHourlyLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VideoHourlyLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VideoHourlyLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> hour = const Value.absent(),
            Value<int> watchTimeMs = const Value.absent(),
          }) =>
              VideoHourlyLogsCompanion(
            id: id,
            dateKey: dateKey,
            hour: hour,
            watchTimeMs: watchTimeMs,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String dateKey,
            required int hour,
            required int watchTimeMs,
          }) =>
              VideoHourlyLogsCompanion.insert(
            id: id,
            dateKey: dateKey,
            hour: hour,
            watchTimeMs: watchTimeMs,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$VideoHourlyLogsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $VideoHourlyLogsTable,
    VideoHourlyLogRow,
    $$VideoHourlyLogsTableFilterComposer,
    $$VideoHourlyLogsTableOrderingComposer,
    $$VideoHourlyLogsTableAnnotationComposer,
    $$VideoHourlyLogsTableCreateCompanionBuilder,
    $$VideoHourlyLogsTableUpdateCompanionBuilder,
    (
      VideoHourlyLogRow,
      BaseReferences<_$HibikiDatabase, $VideoHourlyLogsTable, VideoHourlyLogRow>
    ),
    VideoHourlyLogRow,
    PrefetchHooks Function()>;
typedef $$FavoriteWordsTableCreateCompanionBuilder = FavoriteWordsCompanion
    Function({
  Value<int> id,
  required String expression,
  Value<String> reading,
  Value<String> glossary,
  required String sourceType,
  required String dateKey,
  required int createdAt,
});
typedef $$FavoriteWordsTableUpdateCompanionBuilder = FavoriteWordsCompanion
    Function({
  Value<int> id,
  Value<String> expression,
  Value<String> reading,
  Value<String> glossary,
  Value<String> sourceType,
  Value<String> dateKey,
  Value<int> createdAt,
});

class $$FavoriteWordsTableFilterComposer
    extends Composer<_$HibikiDatabase, $FavoriteWordsTable> {
  $$FavoriteWordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reading => $composableBuilder(
      column: $table.reading, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get glossary => $composableBuilder(
      column: $table.glossary, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$FavoriteWordsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $FavoriteWordsTable> {
  $$FavoriteWordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reading => $composableBuilder(
      column: $table.reading, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get glossary => $composableBuilder(
      column: $table.glossary, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$FavoriteWordsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $FavoriteWordsTable> {
  $$FavoriteWordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => column);

  GeneratedColumn<String> get reading =>
      $composableBuilder(column: $table.reading, builder: (column) => column);

  GeneratedColumn<String> get glossary =>
      $composableBuilder(column: $table.glossary, builder: (column) => column);

  GeneratedColumn<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$FavoriteWordsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $FavoriteWordsTable,
    FavoriteWordRow,
    $$FavoriteWordsTableFilterComposer,
    $$FavoriteWordsTableOrderingComposer,
    $$FavoriteWordsTableAnnotationComposer,
    $$FavoriteWordsTableCreateCompanionBuilder,
    $$FavoriteWordsTableUpdateCompanionBuilder,
    (
      FavoriteWordRow,
      BaseReferences<_$HibikiDatabase, $FavoriteWordsTable, FavoriteWordRow>
    ),
    FavoriteWordRow,
    PrefetchHooks Function()> {
  $$FavoriteWordsTableTableManager(
      _$HibikiDatabase db, $FavoriteWordsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FavoriteWordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FavoriteWordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FavoriteWordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> expression = const Value.absent(),
            Value<String> reading = const Value.absent(),
            Value<String> glossary = const Value.absent(),
            Value<String> sourceType = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              FavoriteWordsCompanion(
            id: id,
            expression: expression,
            reading: reading,
            glossary: glossary,
            sourceType: sourceType,
            dateKey: dateKey,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String expression,
            Value<String> reading = const Value.absent(),
            Value<String> glossary = const Value.absent(),
            required String sourceType,
            required String dateKey,
            required int createdAt,
          }) =>
              FavoriteWordsCompanion.insert(
            id: id,
            expression: expression,
            reading: reading,
            glossary: glossary,
            sourceType: sourceType,
            dateKey: dateKey,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$FavoriteWordsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $FavoriteWordsTable,
    FavoriteWordRow,
    $$FavoriteWordsTableFilterComposer,
    $$FavoriteWordsTableOrderingComposer,
    $$FavoriteWordsTableAnnotationComposer,
    $$FavoriteWordsTableCreateCompanionBuilder,
    $$FavoriteWordsTableUpdateCompanionBuilder,
    (
      FavoriteWordRow,
      BaseReferences<_$HibikiDatabase, $FavoriteWordsTable, FavoriteWordRow>
    ),
    FavoriteWordRow,
    PrefetchHooks Function()>;
typedef $$MiningStatisticsTableCreateCompanionBuilder
    = MiningStatisticsCompanion Function({
  Value<int> id,
  required String sourceType,
  required String dateKey,
  Value<int> count,
});
typedef $$MiningStatisticsTableUpdateCompanionBuilder
    = MiningStatisticsCompanion Function({
  Value<int> id,
  Value<String> sourceType,
  Value<String> dateKey,
  Value<int> count,
});

class $$MiningStatisticsTableFilterComposer
    extends Composer<_$HibikiDatabase, $MiningStatisticsTable> {
  $$MiningStatisticsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get count => $composableBuilder(
      column: $table.count, builder: (column) => ColumnFilters(column));
}

class $$MiningStatisticsTableOrderingComposer
    extends Composer<_$HibikiDatabase, $MiningStatisticsTable> {
  $$MiningStatisticsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get count => $composableBuilder(
      column: $table.count, builder: (column) => ColumnOrderings(column));
}

class $$MiningStatisticsTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $MiningStatisticsTable> {
  $$MiningStatisticsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sourceType => $composableBuilder(
      column: $table.sourceType, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<int> get count =>
      $composableBuilder(column: $table.count, builder: (column) => column);
}

class $$MiningStatisticsTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $MiningStatisticsTable,
    MiningStatisticRow,
    $$MiningStatisticsTableFilterComposer,
    $$MiningStatisticsTableOrderingComposer,
    $$MiningStatisticsTableAnnotationComposer,
    $$MiningStatisticsTableCreateCompanionBuilder,
    $$MiningStatisticsTableUpdateCompanionBuilder,
    (
      MiningStatisticRow,
      BaseReferences<_$HibikiDatabase, $MiningStatisticsTable,
          MiningStatisticRow>
    ),
    MiningStatisticRow,
    PrefetchHooks Function()> {
  $$MiningStatisticsTableTableManager(
      _$HibikiDatabase db, $MiningStatisticsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MiningStatisticsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MiningStatisticsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MiningStatisticsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> sourceType = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> count = const Value.absent(),
          }) =>
              MiningStatisticsCompanion(
            id: id,
            sourceType: sourceType,
            dateKey: dateKey,
            count: count,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String sourceType,
            required String dateKey,
            Value<int> count = const Value.absent(),
          }) =>
              MiningStatisticsCompanion.insert(
            id: id,
            sourceType: sourceType,
            dateKey: dateKey,
            count: count,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MiningStatisticsTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $MiningStatisticsTable,
    MiningStatisticRow,
    $$MiningStatisticsTableFilterComposer,
    $$MiningStatisticsTableOrderingComposer,
    $$MiningStatisticsTableAnnotationComposer,
    $$MiningStatisticsTableCreateCompanionBuilder,
    $$MiningStatisticsTableUpdateCompanionBuilder,
    (
      MiningStatisticRow,
      BaseReferences<_$HibikiDatabase, $MiningStatisticsTable,
          MiningStatisticRow>
    ),
    MiningStatisticRow,
    PrefetchHooks Function()>;
typedef $$MinedSentencesTableCreateCompanionBuilder = MinedSentencesCompanion
    Function({
  Value<int> id,
  Value<String> expression,
  Value<String> reading,
  Value<String> glossary,
  Value<String> sentence,
  required String source,
  Value<String?> documentTitle,
  Value<String?> chapterLabel,
  Value<String?> bookKey,
  Value<int?> sectionIndex,
  Value<int?> normCharOffset,
  Value<int?> normCharLength,
  Value<int?> noteId,
  required String dateKey,
  required int createdAt,
});
typedef $$MinedSentencesTableUpdateCompanionBuilder = MinedSentencesCompanion
    Function({
  Value<int> id,
  Value<String> expression,
  Value<String> reading,
  Value<String> glossary,
  Value<String> sentence,
  Value<String> source,
  Value<String?> documentTitle,
  Value<String?> chapterLabel,
  Value<String?> bookKey,
  Value<int?> sectionIndex,
  Value<int?> normCharOffset,
  Value<int?> normCharLength,
  Value<int?> noteId,
  Value<String> dateKey,
  Value<int> createdAt,
});

class $$MinedSentencesTableFilterComposer
    extends Composer<_$HibikiDatabase, $MinedSentencesTable> {
  $$MinedSentencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reading => $composableBuilder(
      column: $table.reading, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get glossary => $composableBuilder(
      column: $table.glossary, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sentence => $composableBuilder(
      column: $table.sentence, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get documentTitle => $composableBuilder(
      column: $table.documentTitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get chapterLabel => $composableBuilder(
      column: $table.chapterLabel, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get normCharLength => $composableBuilder(
      column: $table.normCharLength,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get noteId => $composableBuilder(
      column: $table.noteId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$MinedSentencesTableOrderingComposer
    extends Composer<_$HibikiDatabase, $MinedSentencesTable> {
  $$MinedSentencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reading => $composableBuilder(
      column: $table.reading, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get glossary => $composableBuilder(
      column: $table.glossary, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sentence => $composableBuilder(
      column: $table.sentence, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get documentTitle => $composableBuilder(
      column: $table.documentTitle,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get chapterLabel => $composableBuilder(
      column: $table.chapterLabel,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get bookKey => $composableBuilder(
      column: $table.bookKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get normCharLength => $composableBuilder(
      column: $table.normCharLength,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get noteId => $composableBuilder(
      column: $table.noteId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$MinedSentencesTableAnnotationComposer
    extends Composer<_$HibikiDatabase, $MinedSentencesTable> {
  $$MinedSentencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get expression => $composableBuilder(
      column: $table.expression, builder: (column) => column);

  GeneratedColumn<String> get reading =>
      $composableBuilder(column: $table.reading, builder: (column) => column);

  GeneratedColumn<String> get glossary =>
      $composableBuilder(column: $table.glossary, builder: (column) => column);

  GeneratedColumn<String> get sentence =>
      $composableBuilder(column: $table.sentence, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get documentTitle => $composableBuilder(
      column: $table.documentTitle, builder: (column) => column);

  GeneratedColumn<String> get chapterLabel => $composableBuilder(
      column: $table.chapterLabel, builder: (column) => column);

  GeneratedColumn<String> get bookKey =>
      $composableBuilder(column: $table.bookKey, builder: (column) => column);

  GeneratedColumn<int> get sectionIndex => $composableBuilder(
      column: $table.sectionIndex, builder: (column) => column);

  GeneratedColumn<int> get normCharOffset => $composableBuilder(
      column: $table.normCharOffset, builder: (column) => column);

  GeneratedColumn<int> get normCharLength => $composableBuilder(
      column: $table.normCharLength, builder: (column) => column);

  GeneratedColumn<int> get noteId =>
      $composableBuilder(column: $table.noteId, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$MinedSentencesTableTableManager extends RootTableManager<
    _$HibikiDatabase,
    $MinedSentencesTable,
    MinedSentenceRow,
    $$MinedSentencesTableFilterComposer,
    $$MinedSentencesTableOrderingComposer,
    $$MinedSentencesTableAnnotationComposer,
    $$MinedSentencesTableCreateCompanionBuilder,
    $$MinedSentencesTableUpdateCompanionBuilder,
    (
      MinedSentenceRow,
      BaseReferences<_$HibikiDatabase, $MinedSentencesTable, MinedSentenceRow>
    ),
    MinedSentenceRow,
    PrefetchHooks Function()> {
  $$MinedSentencesTableTableManager(
      _$HibikiDatabase db, $MinedSentencesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MinedSentencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MinedSentencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MinedSentencesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> expression = const Value.absent(),
            Value<String> reading = const Value.absent(),
            Value<String> glossary = const Value.absent(),
            Value<String> sentence = const Value.absent(),
            Value<String> source = const Value.absent(),
            Value<String?> documentTitle = const Value.absent(),
            Value<String?> chapterLabel = const Value.absent(),
            Value<String?> bookKey = const Value.absent(),
            Value<int?> sectionIndex = const Value.absent(),
            Value<int?> normCharOffset = const Value.absent(),
            Value<int?> normCharLength = const Value.absent(),
            Value<int?> noteId = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              MinedSentencesCompanion(
            id: id,
            expression: expression,
            reading: reading,
            glossary: glossary,
            sentence: sentence,
            source: source,
            documentTitle: documentTitle,
            chapterLabel: chapterLabel,
            bookKey: bookKey,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            normCharLength: normCharLength,
            noteId: noteId,
            dateKey: dateKey,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> expression = const Value.absent(),
            Value<String> reading = const Value.absent(),
            Value<String> glossary = const Value.absent(),
            Value<String> sentence = const Value.absent(),
            required String source,
            Value<String?> documentTitle = const Value.absent(),
            Value<String?> chapterLabel = const Value.absent(),
            Value<String?> bookKey = const Value.absent(),
            Value<int?> sectionIndex = const Value.absent(),
            Value<int?> normCharOffset = const Value.absent(),
            Value<int?> normCharLength = const Value.absent(),
            Value<int?> noteId = const Value.absent(),
            required String dateKey,
            required int createdAt,
          }) =>
              MinedSentencesCompanion.insert(
            id: id,
            expression: expression,
            reading: reading,
            glossary: glossary,
            sentence: sentence,
            source: source,
            documentTitle: documentTitle,
            chapterLabel: chapterLabel,
            bookKey: bookKey,
            sectionIndex: sectionIndex,
            normCharOffset: normCharOffset,
            normCharLength: normCharLength,
            noteId: noteId,
            dateKey: dateKey,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MinedSentencesTableProcessedTableManager = ProcessedTableManager<
    _$HibikiDatabase,
    $MinedSentencesTable,
    MinedSentenceRow,
    $$MinedSentencesTableFilterComposer,
    $$MinedSentencesTableOrderingComposer,
    $$MinedSentencesTableAnnotationComposer,
    $$MinedSentencesTableCreateCompanionBuilder,
    $$MinedSentencesTableUpdateCompanionBuilder,
    (
      MinedSentenceRow,
      BaseReferences<_$HibikiDatabase, $MinedSentencesTable, MinedSentenceRow>
    ),
    MinedSentenceRow,
    PrefetchHooks Function()>;

class $HibikiDatabaseManager {
  final _$HibikiDatabase _db;
  $HibikiDatabaseManager(this._db);
  $$MediaItemsTableTableManager get mediaItems =>
      $$MediaItemsTableTableManager(_db, _db.mediaItems);
  $$AnkiMappingsTableTableManager get ankiMappings =>
      $$AnkiMappingsTableTableManager(_db, _db.ankiMappings);
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
  $$MediaSourcesTableTableManager get mediaSources =>
      $$MediaSourcesTableTableManager(_db, _db.mediaSources);
  $$EpubBooksTableTableManager get epubBooks =>
      $$EpubBooksTableTableManager(_db, _db.epubBooks);
  $$BookmarksTableTableManager get bookmarks =>
      $$BookmarksTableTableManager(_db, _db.bookmarks);
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
  $$BookTagsTableTableManager get bookTags =>
      $$BookTagsTableTableManager(_db, _db.bookTags);
  $$BookTagMappingsTableTableManager get bookTagMappings =>
      $$BookTagMappingsTableTableManager(_db, _db.bookTagMappings);
  $$SrtBookTagMappingsTableTableManager get srtBookTagMappings =>
      $$SrtBookTagMappingsTableTableManager(_db, _db.srtBookTagMappings);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$ProfileSettingsTableTableManager get profileSettings =>
      $$ProfileSettingsTableTableManager(_db, _db.profileSettings);
  $$MediaTypeProfilesTableTableManager get mediaTypeProfiles =>
      $$MediaTypeProfilesTableTableManager(_db, _db.mediaTypeProfiles);
  $$BookProfilesTableTableManager get bookProfiles =>
      $$BookProfilesTableTableManager(_db, _db.bookProfiles);
  $$SyncBaselinesTableTableManager get syncBaselines =>
      $$SyncBaselinesTableTableManager(_db, _db.syncBaselines);
  $$VideoBooksTableTableManager get videoBooks =>
      $$VideoBooksTableTableManager(_db, _db.videoBooks);
  $$VideoBookTagMappingsTableTableManager get videoBookTagMappings =>
      $$VideoBookTagMappingsTableTableManager(_db, _db.videoBookTagMappings);
  $$VideoWatchStatisticsTableTableManager get videoWatchStatistics =>
      $$VideoWatchStatisticsTableTableManager(_db, _db.videoWatchStatistics);
  $$VideoHourlyLogsTableTableManager get videoHourlyLogs =>
      $$VideoHourlyLogsTableTableManager(_db, _db.videoHourlyLogs);
  $$FavoriteWordsTableTableManager get favoriteWords =>
      $$FavoriteWordsTableTableManager(_db, _db.favoriteWords);
  $$MiningStatisticsTableTableManager get miningStatistics =>
      $$MiningStatisticsTableTableManager(_db, _db.miningStatistics);
  $$MinedSentencesTableTableManager get minedSentences =>
      $$MinedSentencesTableTableManager(_db, _db.minedSentences);
}
