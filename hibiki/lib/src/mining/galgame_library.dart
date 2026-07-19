import 'dart:convert';

/// galgame 游戏库（首页「游戏」tab）里的一条已添加游戏。
///
/// 用户从游戏库添加一个 galgame 的 `.exe`，点击即经引擎-hook launch 路径拉起并注入、
/// 进入制卡（复用 texthooker 的 galgame 一键制卡逻辑）。持久化走偏好表单一 JSON key
/// （[encodeGalgameLibrary] / [decodeGalgameLibrary]），不新建 Drift 表——避免与并发
/// schema 版本相撞，且这是一份轻量本机列表。
class GalgameEntry {
  const GalgameEntry({
    required this.id,
    required this.name,
    required this.exePath,
    required this.workdir,
    required this.addedAt,
    this.coverPath,
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

  GalgameEntry copyWith({
    String? name,
    String? exePath,
    String? workdir,
    String? coverPath,
  }) {
    return GalgameEntry(
      id: id,
      name: name ?? this.name,
      exePath: exePath ?? this.exePath,
      workdir: workdir ?? this.workdir,
      coverPath: coverPath ?? this.coverPath,
      addedAt: addedAt,
    );
  }

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
