/// 反馈 0PZAhFd1RO：按系列记住的「字幕文件夹」。
///
/// 用户把一整季字幕放在单独一个文件夹里，第一次手选（或在字幕面板里指定文件夹）后，
/// 这个系列之后每一集都去这个文件夹里按集号认领字幕（匹配规则见引擎
/// `matchEpisodeSubtitleInDirectory`）。持久化在偏好 `video_subtitle_series_dirs`
/// （JSON map：系列键 → `{dir, template?}`），读写入口在 `PreferencesRepository`。
///
/// 本文件只放纯数据与编解码，无 IO、无 Flutter，便于单测。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

/// 一个系列记住的字幕文件夹。
class VideoSubtitleFolder {
  const VideoSubtitleFolder({required this.directory, this.templateFileName});

  /// 字幕文件夹的绝对路径（用户自己的外部目录，不在 Fushi 数据根下）。
  final String directory;

  /// 用户在这个文件夹里亲手选过的那份字幕的文件名（basename）。同一集有多份字幕
  /// （不同字幕组 / 语言）时按它的命名挑；只指定了文件夹、没选过具体文件时为 null。
  final String? templateFileName;

  Map<String, Object?> toJson() => <String, Object?>{
    'dir': directory,
    if (templateFileName != null) 'template': templateFileName,
  };

  /// 解析一条记录；形状不对返回 null（一条坏值不该拖垮整张表）。
  static VideoSubtitleFolder? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? dir = json['dir'];
    if (dir is! String || dir.trim().isEmpty) return null;
    final Object? template = json['template'];
    return VideoSubtitleFolder(
      directory: dir,
      templateFileName: template is String && template.trim().isNotEmpty
          ? template
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoSubtitleFolder &&
      other.directory == directory &&
      other.templateFileName == templateFileName;

  @override
  int get hashCode => Object.hash(directory, templateFileName);
}

/// 「系列」的记忆键。视频在合集里时以合集为系列（`collection:<id>`，合集就是用户
/// 认定的一部作品，各集可能散在不同下载目录里）；不在合集里时以视频所在目录为系列
/// （`dir:<目录>`，同一目录下的散装剧集共用一个字幕文件夹）。
String videoSubtitleFolderSeriesKey({
  required int? collectionId,
  required String videoPath,
}) {
  if (collectionId != null) return 'collection:$collectionId';
  return 'dir:${p.normalize(p.dirname(videoPath))}';
}

/// 解码偏好里的整张表；不是 JSON map 时抛 [FormatException]（由调用方记诊断后当空表）。
/// 单条形状不对的记录跳过。
Map<String, VideoSubtitleFolder> decodeVideoSubtitleFolders(String raw) {
  if (raw.isEmpty) return <String, VideoSubtitleFolder>{};
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('video_subtitle_series_dirs is not a map');
  }
  return <String, VideoSubtitleFolder>{
    for (final MapEntry<Object?, Object?> e in decoded.entries)
      if (VideoSubtitleFolder.fromJson(e.value)
          case final VideoSubtitleFolder folder)
        e.key.toString(): folder,
  };
}

/// 编码整张表。
String encodeVideoSubtitleFolders(Map<String, VideoSubtitleFolder> folders) =>
    jsonEncode(<String, Object?>{
      for (final MapEntry<String, VideoSubtitleFolder> e in folders.entries)
        e.key: e.value.toJson(),
    });
