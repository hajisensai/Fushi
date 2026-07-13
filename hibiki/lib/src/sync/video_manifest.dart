import 'dart:convert';

import 'package:path/path.dart' as p;

/// 云视频资产目录清单（多端库联合视图 §2.6 / 任务12）。
///
/// 开启「上传视频文件」开关的设备把本地视频文件推到 sync 根 `__videos__/` 命名空间，
/// 并在 `__videos__/videos.json` 存一份共享清单：每条记录一个视频的跨端身份（uid）、
/// 标题、命名空间下的视频资产名、字节大小、导入时间戳，以及可选的封面资产名。其它端
/// 读清单渲染云视频占位卡、按 uid 下载入库（[CloudRemoteVideoClient]）。
///
/// 清单是**知识的并集**（upload-only：删除不传播）：各端读远端清单 → 合入本地在库
/// 视频条目 → 回写。输出**确定性排序**（视频按 uid），使「内容相等 ⇒ 字节相等」成立，
/// 编排器靠 canonical JSON 比对决定要不要回写，避免反复同步产生写放大。
///
/// 纯 Dart：零 IO、零 Flutter 依赖，便于 roundtrip 单测。
class RemoteVideoManifest {
  const RemoteVideoManifest({
    this.version = currentVersion,
    this.videos = const <RemoteVideoManifestEntry>[],
  });

  /// 清单格式版本（向后兼容判据；解码只认 <= [currentVersion]）。
  static const int currentVersion = 1;

  /// 空清单（远端尚无 `videos.json` 时的合并起点）。
  static const RemoteVideoManifest empty = RemoteVideoManifest();

  final int version;

  /// 全部云视频条目，无序输入、编码时按 uid 排序。
  final List<RemoteVideoManifestEntry> videos;

  /// 解码。[json] 是 `jsonDecode` 的产物（Map）。结构非法抛 [FormatException]
  /// （编排器捕获后计入 report.errors，不让一份坏清单毁掉整轮同步）。
  factory RemoteVideoManifest.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('video manifest: not a JSON object');
    }
    final Object? version = json['version'];
    if (version is! int || version < 1) {
      throw const FormatException('video manifest: bad version');
    }
    if (version > currentVersion) {
      // 更新版 app 写的清单：拒绝解析（宁可跳过本轮云视频同步，也不能按旧语义误读
      // 新字段后把降级结果写回，破坏新端数据——与合集清单 / DB 降级保护同一律）。
      throw FormatException('video manifest: version $version is newer than '
          'supported $currentVersion');
    }
    final Object? rawVideos = json['videos'];
    if (rawVideos is! List) {
      throw const FormatException('video manifest: bad videos');
    }
    return RemoteVideoManifest(
      version: version,
      videos: <RemoteVideoManifestEntry>[
        for (final Object? v in rawVideos) RemoteVideoManifestEntry.fromJson(v),
      ],
    );
  }

  /// 编码为确定性排序（按 uid）的 JSON 结构。
  Map<String, dynamic> toJson() {
    final List<RemoteVideoManifestEntry> sorted =
        List<RemoteVideoManifestEntry>.of(videos)
          ..sort((RemoteVideoManifestEntry a, RemoteVideoManifestEntry b) =>
              a.uid.compareTo(b.uid));
    return <String, dynamic>{
      'version': version,
      'videos': <Map<String, dynamic>>[
        for (final RemoteVideoManifestEntry v in sorted) v.toJson(),
      ],
    };
  }

  /// 规范化 JSON 字符串（确定性排序 ⇒ 内容相等则字节相等，供变更检测）。
  String canonicalJson() => jsonEncode(toJson());
}

/// 清单里的一个云视频条目。
class RemoteVideoManifestEntry {
  const RemoteVideoManifestEntry({
    required this.uid,
    required this.title,
    required this.videoAsset,
    required this.sizeBytes,
    this.importedAtMs = 0,
    this.coverAsset,
  });

  /// 跨端身份：`VideoBooks.bookUid`（内容派生、跨端/重导入稳定）。
  final String uid;

  final String title;

  /// 视频文件在 `__videos__/` 命名空间下的资产名（[videoAssetName] 产出）。
  final String videoAsset;

  /// 视频文件字节大小（「远端已存在同尺寸跳过」的判据）。
  final int sizeBytes;

  /// 导入毫秒戳；0 = 未知（旧数据无 importedAt）。
  final int importedAtMs;

  /// 封面在 `__videos__/` 下的资产名（[videoCoverAssetName] 产出）；null = 无封面。
  final String? coverAsset;

  factory RemoteVideoManifestEntry.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('video entry: not a JSON object');
    }
    final Object? uid = json['uid'];
    final Object? title = json['title'];
    final Object? videoAsset = json['videoAsset'];
    if (uid is! String ||
        uid.isEmpty ||
        title is! String ||
        videoAsset is! String ||
        videoAsset.isEmpty) {
      throw const FormatException('video entry: bad required fields');
    }
    final Object? sizeBytes = json['sizeBytes'];
    final Object? importedAtMs = json['importedAtMs'];
    final Object? coverAsset = json['coverAsset'];
    return RemoteVideoManifestEntry(
      uid: uid,
      title: title,
      videoAsset: videoAsset,
      sizeBytes: sizeBytes is int ? sizeBytes : 0,
      importedAtMs: importedAtMs is int ? importedAtMs : 0,
      coverAsset:
          (coverAsset is String && coverAsset.isNotEmpty) ? coverAsset : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'uid': uid,
        'title': title,
        'videoAsset': videoAsset,
        'sizeBytes': sizeBytes,
        'importedAtMs': importedAtMs,
        if (coverAsset != null) 'coverAsset': coverAsset,
      };
}

/// FNV-1a 32-bit 稳定哈希（确定性、无外部依赖，仅用于资产名去歧义，非安全用途）。
/// 逐码元混入高低字节，保证不同 Unicode 码元不塌缩到同值。
String _stableHashHex(String s) {
  int hash = 0x811c9dc5;
  for (final int c in s.codeUnits) {
    hash = (hash ^ (c & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
    hash = (hash ^ ((c >> 8) & 0xff)) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 把 [uid]（`VideoBooks.bookUid`，可含 `/`、空格、中文等）安全编码成后端资产文件名
/// 基名：非 `[A-Za-z0-9._-]` 字符替换为 `_`，长度截到 60，再追加 uid 全串的稳定哈希。
///
/// 追加哈希消除「不同 uid 清洗后同名」的碰撞（视频 uid 多为 `video/<标题>` 形态，仅差
/// 特殊字符的两条会清洗成同名）；清单按真 uid 索引并记录完整资产名，故本函数无需可逆，
/// 只需确定性 + 各后端（Drive 名 / WebDAV href / FTP·SFTP 路径）文件系统安全。
String _sanitizeAssetBase(String uid) {
  String cleaned = uid.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (cleaned.isEmpty) cleaned = 'video';
  if (cleaned.length > 60) cleaned = cleaned.substring(0, 60);
  return '${cleaned}_${_stableHashHex(uid)}';
}

/// 清洗扩展名到文件系统安全形态：合法扩展名 = 点 + 纯 ASCII 字母数字（如 `.mkv`）。
/// 任何脏扩展名（含中文 / 空格 / 多点，如 `movie.第1話` 的 `.第1話`）或缺扩展名整体
/// 回退 [fallback]——绝不把非 ASCII 字节拼进资产名（FTP/SFTP 路径、WebDAV href 会炸）。
/// 不做部分清洗（避免产出 `.1` 之类的怪扩展名），与基名一套「非法即回退」策略一致。
String _cleanVideoExt(String rawExt, String fallback) {
  if (RegExp(r'^\.[A-Za-z0-9]+$').hasMatch(rawExt)) return rawExt;
  return fallback;
}

/// 视频文件在 `__videos__/` 下的资产名：`<safeUid><清洗后扩展名>`（脏/缺扩展名回退 `.mp4`）。
String videoAssetName(String uid, String videoPath) {
  return '${_sanitizeAssetBase(uid)}${_cleanVideoExt(p.extension(videoPath), '.mp4')}';
}

/// 视频封面在 `__videos__/` 下的资产名：`<safeUid>.cover<清洗后扩展名>`（脏/缺扩展名回退 `.jpg`）。
String videoCoverAssetName(String uid, String coverPath) {
  return '${_sanitizeAssetBase(uid)}.cover${_cleanVideoExt(p.extension(coverPath), '.jpg')}';
}
