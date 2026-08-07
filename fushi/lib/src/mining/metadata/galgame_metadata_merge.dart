/// mixed 模式的逐字段合并（契约 §2.4）+ 用户自定义覆盖层（§1.3）。
///
/// 整个文件是**纯函数**：不碰网络、不碰 DB、不看时钟，输入一样输出必然一样。
library;

import 'dart:convert';

import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// `galgames.customDataJson` 的结构（契约 §1.3）。
///
/// 覆盖语义**分两种**，别混：
/// - [name] / [summary] / [developer] / [nsfw] / [coverSource] 是**覆盖**（有就顶掉源值）；
/// - [aliases] / [tags] 是**并集合并**（追加到源值后面，去重保序）。
///
/// [userRating] / [userReview] 不参与 draft 合并——它们是「我的评价」，与站点元数据是两回事，
/// 由详情页单独展示。
class GalgameCustomData {
  const GalgameCustomData({
    this.name,
    this.coverSource,
    this.aliases = const <String>[],
    this.summary,
    this.tags = const <String>[],
    this.developer,
    this.nsfw,
    this.userRating,
    this.userReview,
  });

  /// 用户改的显示名。
  final String? name;

  /// mixed 模式下手选的封面来源；null = 按默认优先级取。
  final GalgameMetadataSource? coverSource;

  /// 用户加的别名（与源别名求并集）。
  final List<String> aliases;

  /// 用户改的简介。
  final String? summary;

  /// 用户加的标签（与源标签求并集）。
  final List<String> tags;

  /// 用户改的开发商。
  final String? developer;

  /// 用户设定的成人向标记。
  final bool? nsfw;

  /// 我的评分（0-10），null = 未评分。
  final double? userRating;

  /// 我的评价。
  final String? userReview;

  /// 是否完全没有覆盖内容（全空时上层可以直接不写 `customDataJson` 列）。
  bool get isEmpty =>
      name == null &&
      coverSource == null &&
      aliases.isEmpty &&
      summary == null &&
      tags.isEmpty &&
      developer == null &&
      nsfw == null &&
      userRating == null &&
      userReview == null;

  GalgameCustomData copyWith({
    String? name,
    GalgameMetadataSource? coverSource,
    List<String>? aliases,
    String? summary,
    List<String>? tags,
    String? developer,
    bool? nsfw,
    double? userRating,
    String? userReview,
  }) {
    return GalgameCustomData(
      name: name ?? this.name,
      coverSource: coverSource ?? this.coverSource,
      aliases: aliases ?? this.aliases,
      summary: summary ?? this.summary,
      tags: tags ?? this.tags,
      developer: developer ?? this.developer,
      nsfw: nsfw ?? this.nsfw,
      userRating: userRating ?? this.userRating,
      userReview: userReview ?? this.userReview,
    );
  }

  /// null 字段一律省略，空 map 表示「没有任何覆盖」。
  Map<String, Object?> toJson() {
    final Map<String, Object?> json = <String, Object?>{};
    if (name != null) json['name'] = name;
    if (coverSource != null) json['coverSource'] = coverSource!.key;
    if (aliases.isNotEmpty) json['aliases'] = aliases;
    if (summary != null) json['summary'] = summary;
    if (tags.isNotEmpty) json['tags'] = tags;
    if (developer != null) json['developer'] = developer;
    if (nsfw != null) json['nsfw'] = nsfw;
    if (userRating != null) json['userRating'] = userRating;
    if (userReview != null) json['userReview'] = userReview;
    return json;
  }

  /// 容错解析：字段类型不对就当没有，**绝不抛**。
  static GalgameCustomData fromJson(Map<Object?, Object?> json) {
    return GalgameCustomData(
      name: draftString(json['name']),
      coverSource: GalgameMetadataSource.fromKey(json['coverSource']),
      aliases: draftStringList(json['aliases']),
      summary: draftString(json['summary']),
      tags: draftStringList(json['tags']),
      developer: draftString(json['developer']),
      nsfw: draftBool(json['nsfw']),
      userRating: draftDouble(json['userRating']),
      userReview: draftString(json['userReview']),
    );
  }

  /// 从 `customDataJson` 列解析；空串 / 非法 JSON / 非对象 → 空覆盖层。
  static GalgameCustomData decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const GalgameCustomData();
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const GalgameCustomData();
      }
      return fromJson(Map<Object?, Object?>.from(decoded));
    } catch (_) {
      return const GalgameCustomData();
    }
  }

  /// 序列化成 `customDataJson` 列的值。
  String encode() => jsonEncode(toJson());
}

/// 按契约 §2.4 的逐字段优先级合并多源 draft，再叠加 [custom] 覆盖层（§1.3）。
///
/// | 字段 | 优先级 |
/// |---|---|
/// | name / nameCn / summary / releaseDate / score / nsfw | bgm → vndb |
/// | developer | **vndb → bgm** |
/// | coverUrl | `custom.coverSource` 手选优先，否则 bgm → vndb |
/// | rank | 仅 bgm |
/// | averageHours | 仅 vndb |
/// | tags / aliases / allTitles | 各源并集（去重保序，按枚举声明顺序） |
///
/// 合并结果的 `externalId` 恒为 null：多源合并不存在单一外部 ID，要取某源的 ID 请直接读
/// [bySource]。空输入 + 空 custom → 空 draft（不抛）。纯函数。
GalgameMetadataDraft mergeDrafts(
  Map<GalgameMetadataSource, GalgameMetadataDraft> bySource, {
  GalgameCustomData? custom,
}) {
  final GalgameMetadataDraft? bgm = bySource[GalgameMetadataSource.bgm];
  final GalgameMetadataDraft? vndb = bySource[GalgameMetadataSource.vndb];

  // 未来新增源时，未在上表点名的字段沿枚举声明顺序回退，无需改这里。
  final List<GalgameMetadataDraft> inOrder = <GalgameMetadataDraft>[
    for (final GalgameMetadataSource s in GalgameMetadataSource.values)
      if (bySource[s] != null) bySource[s]!,
  ];

  T? pick<T>(T? Function(GalgameMetadataDraft draft) get) {
    for (final GalgameMetadataDraft d in inOrder) {
      final T? value = get(d);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  List<String> union(List<String> Function(GalgameMetadataDraft d) get) {
    return draftStringList(<Object?>[
      for (final GalgameMetadataDraft d in inOrder) ...get(d),
    ]);
  }

  final GalgameCustomData overlay = custom ?? const GalgameCustomData();

  // 封面：手选源优先；手选源没封面时不能空着，退回默认优先级链。
  final GalgameMetadataSource? preferred = overlay.coverSource;
  final String? coverUrl =
      (preferred == null ? null : bySource[preferred]?.coverUrl) ??
          pick<String>((GalgameMetadataDraft d) => d.coverUrl);

  return GalgameMetadataDraft(
    name: overlay.name ?? pick<String>((GalgameMetadataDraft d) => d.name),
    nameCn: pick<String>((GalgameMetadataDraft d) => d.nameCn),
    aliases: draftStringList(<Object?>[
      ...union((GalgameMetadataDraft d) => d.aliases),
      ...overlay.aliases,
    ]),
    allTitles: union((GalgameMetadataDraft d) => d.allTitles),
    summary:
        overlay.summary ?? pick<String>((GalgameMetadataDraft d) => d.summary),
    tags: draftStringList(<Object?>[
      ...union((GalgameMetadataDraft d) => d.tags),
      ...overlay.tags,
    ]),
    // developer 是唯一反向优先的字段：vndb 的开发商数据比 bgm infobox 干净。
    developer: overlay.developer ?? vndb?.developer ?? bgm?.developer,
    releaseDate: pick<String>((GalgameMetadataDraft d) => d.releaseDate),
    score: pick<double>((GalgameMetadataDraft d) => d.score),
    rank: bgm?.rank,
    nsfw: overlay.nsfw ?? pick<bool>((GalgameMetadataDraft d) => d.nsfw),
    averageHours: vndb?.averageHours,
    coverUrl: coverUrl,
  );
}
