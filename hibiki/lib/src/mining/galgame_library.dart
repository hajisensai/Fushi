import 'dart:convert';

import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart';

/// 游玩状态（契约 §1.5）。数值**故意对齐 Bangumi 收藏 type**，省掉一层映射；
/// [value] 直接落 `galgames.playStatus` 列，**不可随意改**。
enum GalgamePlayStatus {
  /// 未设置（Hibiki 新增，旧数据迁移后的默认值）。
  unset(0),

  /// 想玩。
  wantToPlay(1),

  /// 玩过。
  played(2),

  /// 在玩。
  playing(3),

  /// 搁置。
  onHold(4),

  /// 弃坑。
  dropped(5);

  const GalgamePlayStatus(this.value);

  /// 持久化数值（DB 列值）。
  final int value;

  /// 容错解析：未知值一律回落 [unset]（脏数据不崩）。
  static GalgamePlayStatus fromValue(int? value) {
    for (final GalgamePlayStatus status in GalgamePlayStatus.values) {
      if (status.value == value) {
        return status;
      }
    }
    return GalgamePlayStatus.unset;
  }
}

/// 状态菜单/筛选的展示顺序（契约 §1.5：想玩 → 在玩 → 玩过 → 搁置 → 弃坑）。
/// [GalgamePlayStatus.unset] 不在菜单里（它是「没设过」而不是一个可选状态），
/// 但作为筛选项由 UI 单独提供。
const List<GalgamePlayStatus> kGalgamePlayStatusMenuOrder = <GalgamePlayStatus>[
  GalgamePlayStatus.wantToPlay,
  GalgamePlayStatus.playing,
  GalgamePlayStatus.played,
  GalgamePlayStatus.onHold,
  GalgamePlayStatus.dropped,
];

/// galgame 游戏库（首页「游戏」tab）里的一条已添加游戏——**UI 消费的视图模型**。
///
/// 用户从游戏库添加一个 galgame 的 `.exe`，点击即经引擎-hook launch 路径拉起并注入、
/// 进入制卡（复用 texthooker 的 galgame 一键制卡逻辑）。
///
/// 真相源自 v55 起是 Drift 表 `galgames` / `galgame_sources` / `galgame_sessions`
/// （构造走 `galgame_repository.dart` 的 `galgameEntryFromRow`）；本类是把「行 + 多源
/// 快照 + 用户覆盖层 + 游玩聚合」合成一个不可变对象给 UI 读的视图，本身不含 IO。
/// [toJson] / [encodeGalgameLibrary] 只覆盖 v55 之前的 6 个基础字段，纯粹是旧偏好
/// key `galgame_library` 的 legacy 编解码（迁移读一次 + 单测），新代码不要再用。
class GalgameEntry {
  const GalgameEntry({
    required this.id,
    required this.name,
    required this.exePath,
    required this.workdir,
    required this.addedAt,
    this.coverPath,
    this.playStatus = GalgamePlayStatus.unset,
    this.primarySource,
    this.releaseDate,
    this.customData = const GalgameCustomData(),
    this.metadata = const GalgameMetadataDraft(),
    this.sortOrder = 0,
    this.totalPlaySeconds = 0,
    this.sessionCount = 0,
    this.lastPlayedMs = 0,
  });

  /// 稳定标识（用于列表 key 与增删定位）。默认取添加时刻的微秒时间戳字符串。
  final String id;

  /// 显示名称（默认取 exe 文件名去扩展名，用户可改）。
  final String name;

  /// 游戏可执行文件绝对路径（launch 注入的目标）。
  final String exePath;

  /// 工作目录（默认为 exe 所在目录）。多数 KiriKiri 等引擎按 exe 目录解析资源，
  /// 由 injector 拉起游戏时设定；此处随条目持久化，供未来按需使用。
  final String workdir;

  /// 可选封面图绝对路径（null = 用默认游戏图标）。
  final String? coverPath;

  /// 添加时间。
  final DateTime addedAt;

  /// 游玩状态（契约 §1.5）。
  final GalgamePlayStatus playStatus;

  /// 主显示源：`bgm` / `vndb` / `mixed` / `custom`；null = 未刮削。
  final String? primarySource;

  /// 刮削上提的发行日 `YYYY-MM-DD`（为排序建列）；null = 未知。
  final String? releaseDate;

  /// 用户覆盖层（契约 §1.3）。展示名/我的评分/我的评价等都在这里。
  final GalgameCustomData customData;

  /// **已合并**的展示元数据：多源按契约 §2.4 优先级合并后再叠加 [customData]。
  /// 未刮削时是空 draft（各字段为 null / 空表），展示层一律回落本地字段。
  final GalgameMetadataDraft metadata;

  /// 手动排序位（预留，M1 不做拖拽）。
  final int sortOrder;

  /// 累计游玩秒数（`galgame_sessions` 现算合计）。
  final int totalPlaySeconds;

  /// 游玩会话次数。
  final int sessionCount;

  /// 最后一次游玩的结束毫秒戳；0 = 从未游玩。
  final int lastPlayedMs;

  /// 卡片/详情页的显示名：用户改名 > 中文名 > 原名 > 本地默认名（exe 文件名）。
  ///
  /// 用户改名必须压过 `nameCn`——[metadata] 里的 `name` 已被 [customData] 覆盖，
  /// 但 `nameCn` 不受覆盖层影响，若不在这里优先取 [GalgameCustomData.name]，
  /// 用户改完名字看到的还是刮削中文名。
  String get displayName {
    final String? custom = customData.name;
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return metadata.nameCn ?? metadata.name ?? name;
  }

  /// 开发商（合并结果已含用户覆盖）。
  String? get developer => metadata.developer;

  /// 站点评分（0-10）；未刮削为 null。
  double? get siteScore => metadata.score;

  /// 我的评分（0-10）；未评分为 null。
  double? get userRating => customData.userRating;

  /// 展示用标签（源标签 ∪ 用户标签）。
  List<String> get tags => metadata.tags;

  /// 是否成人向（缺省视作否）。
  bool get isNsfw => metadata.nsfw ?? false;

  /// 发行日：列上提值优先，回落合并元数据。
  String? get effectiveReleaseDate => releaseDate ?? metadata.releaseDate;

  /// 是否有本地可执行文件（筛选「有本地 exe」/「仅元数据」的判据）。
  /// 只看路径是否为空，**不碰磁盘**——筛选必须是纯函数。
  bool get hasLocalExe => exePath.trim().isNotEmpty;

  /// 参与搜索匹配的全部标题：本地名 + 原名 + 中文名 + 别名 + all_titles。
  /// 去重保序，供 `galgame_library_query.dart` 归一化子串匹配。
  List<String> get searchTitles => <String>[
        for (final String? title in <String?>[
          name,
          customData.name,
          metadata.name,
          metadata.nameCn,
          ...metadata.aliases,
          ...metadata.allTitles,
        ])
          if (title != null && title.isNotEmpty) title,
      ];

  GalgameEntry copyWith({
    String? name,
    String? exePath,
    String? workdir,
    String? coverPath,
    GalgamePlayStatus? playStatus,
    String? primarySource,
    String? releaseDate,
    GalgameCustomData? customData,
    GalgameMetadataDraft? metadata,
    int? sortOrder,
    int? totalPlaySeconds,
    int? sessionCount,
    int? lastPlayedMs,
  }) {
    return GalgameEntry(
      id: id,
      name: name ?? this.name,
      exePath: exePath ?? this.exePath,
      workdir: workdir ?? this.workdir,
      coverPath: coverPath ?? this.coverPath,
      addedAt: addedAt,
      playStatus: playStatus ?? this.playStatus,
      primarySource: primarySource ?? this.primarySource,
      releaseDate: releaseDate ?? this.releaseDate,
      customData: customData ?? this.customData,
      metadata: metadata ?? this.metadata,
      sortOrder: sortOrder ?? this.sortOrder,
      totalPlaySeconds: totalPlaySeconds ?? this.totalPlaySeconds,
      sessionCount: sessionCount ?? this.sessionCount,
      lastPlayedMs: lastPlayedMs ?? this.lastPlayedMs,
    );
  }

  /// legacy：v55 之前的偏好 JSON 形状（只有 6 个基础字段）。
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'exePath': exePath,
        'workdir': workdir,
        'coverPath': coverPath,
        'addedAt': addedAt.millisecondsSinceEpoch,
      };

  /// 从持久化 map 解析一条；缺关键字段（id/name/exePath）返回 null（跳过脏数据）。
  static GalgameEntry? fromJson(Map<Object?, Object?> m) {
    final Object? id = m['id'];
    final Object? name = m['name'];
    final Object? exePath = m['exePath'];
    if (id is! String ||
        name is! String ||
        exePath is! String ||
        id.isEmpty ||
        exePath.isEmpty) {
      return null;
    }
    final Object? workdir = m['workdir'];
    final Object? cover = m['coverPath'];
    final Object? addedAtMs = m['addedAt'];
    return GalgameEntry(
      id: id,
      name: name,
      exePath: exePath,
      workdir: workdir is String && workdir.isNotEmpty
          ? workdir
          : _defaultWorkdirForExe(exePath),
      coverPath: cover is String && cover.isNotEmpty ? cover : null,
      addedAt: addedAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(addedAtMs)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 取 exe 所在目录作默认工作目录（兼容 `\` 与 `/` 分隔）；无分隔符时回退空串。
String _defaultWorkdirForExe(String exePath) {
  final int slash = exePath.lastIndexOf(RegExp(r'[\\/]'));
  return slash <= 0 ? '' : exePath.substring(0, slash);
}

/// 由 exe 路径构造一条新游戏条目：id 用当前微秒时间戳，name 默认取文件名去扩展名，
/// workdir 默认取 exe 所在目录。纯函数，便于单测。
GalgameEntry newGalgameEntryFromExe(
  String exePath, {
  DateTime? now,
  String? name,
}) {
  final DateTime added = now ?? DateTime.now();
  return GalgameEntry(
    id: added.microsecondsSinceEpoch.toString(),
    name:
        (name != null && name.isNotEmpty) ? name : galgameNameFromExe(exePath),
    exePath: exePath,
    workdir: _defaultWorkdirForExe(exePath),
    addedAt: added,
  );
}

/// 从 exe 路径推导默认游戏名：取文件名去掉扩展名；为空回退整路径。纯函数。
String galgameNameFromExe(String exePath) {
  final int slash = exePath.lastIndexOf(RegExp(r'[\\/]'));
  final String base = slash < 0 ? exePath : exePath.substring(slash + 1);
  final int dot = base.lastIndexOf('.');
  final String stem = dot <= 0 ? base : base.substring(0, dot);
  return stem.isEmpty ? exePath : stem;
}

/// 路径归一成大小写无关的比较键（Windows 路径大小写不敏感、分隔符 `\\`/`/` 等价）。
String _exePathKey(String path) => path.replaceAll('/', '\\').toLowerCase();

/// 从一批拖入的文件路径里筛出**可新增**的游戏 exe：只认 `.exe` 扩展名
/// （大小写无关），去掉批内重复与已在 [existing] 库里的路径。保序。纯函数。
List<String> filterDroppedGameExes(
  List<GalgameEntry> existing,
  List<String> dropped,
) {
  final Set<String> seen = <String>{
    for (final GalgameEntry g in existing) _exePathKey(g.exePath),
  };
  final List<String> out = <String>[];
  for (final String path in dropped) {
    if (path.isEmpty || !path.toLowerCase().endsWith('.exe')) {
      continue;
    }
    if (seen.add(_exePathKey(path))) {
      out.add(path);
    }
  }
  return out;
}

/// 把游戏库列表编码成偏好表存的 JSON 字符串（空列表 -> 空串，读回即空）。纯函数。
String encodeGalgameLibrary(List<GalgameEntry> games) {
  if (games.isEmpty) {
    return '';
  }
  return jsonEncode(
    games.map((GalgameEntry g) => g.toJson()).toList(growable: false),
  );
}

/// 从偏好 JSON 字符串解析游戏库列表；空串 / 解析失败 / 非数组 -> 空列表（容错，
/// 与其它 JSON 偏好同款：坏数据不崩，回退空）。纯函数。
List<GalgameEntry> decodeGalgameLibrary(String raw) {
  if (raw.isEmpty) {
    return const <GalgameEntry>[];
  }
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <GalgameEntry>[];
    }
    final List<GalgameEntry> out = <GalgameEntry>[];
    for (final Object? e in decoded) {
      if (e is Map) {
        final GalgameEntry? entry =
            GalgameEntry.fromJson(Map<Object?, Object?>.from(e));
        if (entry != null) {
          out.add(entry);
        }
      }
    }
    return out;
  } catch (_) {
    return const <GalgameEntry>[];
  }
}
