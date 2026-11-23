/// 在线视频源入库集的重开规格（`VideoBooks.streamSpecJson`）——纯数据模型。
///
/// 从 `anime_source_library.dart`（入库 / 下载服务，依赖下载管理器、封面服务等）拆出：
/// 同步层（`online_library_items.dart`）只要解析规格取封面地址，不该为此 import 整个
/// 入库服务——那会把同步编排层拖进 UI / AppModel 的大 import 环（import_cycle_guard）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 在线视频源入库集的重开规格（落 `VideoBooks.streamSpecJson`）。
@immutable
class AnimeSourceBookSpec {
  const AnimeSourceBookSpec({
    required this.extensionPackage,
    required this.sourceId,
    required this.anime,
    required this.episode,
  });

  /// spec 的类型标记：与 TODO-1157 的直链 spec（`StreamVideoSpec`）同列共存，
  /// 那边的 `fromStorageJson` 读到未知键只会得到空 spec，不会误用。
  static const String kind = 'anime-source';

  final String extensionPackage;
  final String sourceId;
  final MihonAnime anime;
  final MihonEpisode episode;

  String encode() => jsonEncode(<String, Object?>{
    'kind': kind,
    'extensionPackage': extensionPackage,
    'sourceId': sourceId,
    'anime': anime.toJson(),
    'episode': episode.toJson(),
  });

  /// 解析失败（不是本种 spec / 旧数据 / 坏 JSON）返回 null，**绝不抛**。
  static AnimeSourceBookSpec? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> || decoded['kind'] != kind) {
        return null;
      }
      final Object? anime = decoded['anime'];
      final Object? episode = decoded['episode'];
      final String package = decoded['extensionPackage']?.toString() ?? '';
      final String source = decoded['sourceId']?.toString() ?? '';
      if (anime is! Map || episode is! Map || package.isEmpty) return null;
      return AnimeSourceBookSpec(
        extensionPackage: package,
        sourceId: source,
        anime: MihonAnime.fromJson(anime.cast<String, Object?>()),
        episode: MihonEpisode.fromJson(episode.cast<String, Object?>()),
      );
    } on Object {
      // 行上的数据来自扩展 / 备份 / 旧版本：字段类型不对（`status: "ongoing"`）会在
      // `fromJson` 的强转里抛 TypeError，一样按「不是可用的规格」处理。
      return null;
    }
  }

  /// 同一部作品（同扩展、同源、同作品 URL）。
  bool sameWorkAs(AnimeSourceBookSpec other) =>
      extensionPackage == other.extensionPackage &&
      sourceId == other.sourceId &&
      anime.url == other.anime.url;
}
