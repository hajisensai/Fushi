// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MediaItem _$MediaItemFromJson(Map<String, dynamic> json) => MediaItem(
      mediaIdentifier: json['mediaIdentifier'] as String,
      title: json['title'] as String,
      mediaTypeIdentifier: json['mediaTypeIdentifier'] as String,
      mediaSourceIdentifier: json['mediaSourceIdentifier'] as String,
      position: (json['position'] as num).toInt(),
      duration: (json['duration'] as num).toInt(),
      canDelete: json['canDelete'] as bool,
      canEdit: json['canEdit'] as bool,
      id: (json['id'] as num?)?.toInt(),
      extraUrl: json['extraUrl'] as String?,
      extra: json['extra'] as String?,
      base64Image: json['base64Image'] as String?,
      imageUrl: json['imageUrl'] as String?,
      audioUrl: json['audioUrl'] as String?,
      author: json['author'] as String?,
      authorIdentifier: json['authorIdentifier'] as String?,
      sourceMetadata: json['sourceMetadata'] as String?,
    );

Map<String, dynamic> _$MediaItemToJson(MediaItem instance) => <String, dynamic>{
      'id': instance.id,
      'mediaIdentifier': instance.mediaIdentifier,
      'title': instance.title,
      'mediaTypeIdentifier': instance.mediaTypeIdentifier,
      'mediaSourceIdentifier': instance.mediaSourceIdentifier,
      'base64Image': instance.base64Image,
      'imageUrl': instance.imageUrl,
      'audioUrl': instance.audioUrl,
      'author': instance.author,
      'extraUrl': instance.extraUrl,
      'extra': instance.extra,
      'authorIdentifier': instance.authorIdentifier,
      'sourceMetadata': instance.sourceMetadata,
      'position': instance.position,
      'duration': instance.duration,
      'canDelete': instance.canDelete,
      'canEdit': instance.canEdit,
    };
