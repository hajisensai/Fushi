import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 一条互联视频下载的**续传清单**：进程被杀（Android 切后台被回收、桌面崩溃/
/// 退出）后，内存里的 [InterconnectDownloadManager] 任务表整张消失，只剩磁盘上的
/// `.part`。这份清单与 `.part` 同目录同名并排落盘，记下「这个 part 属于哪个远端
/// 视频、来自哪个来源、是不是用户主动暂停的」，下次视频页拿到远端清单时据此把
/// 任务接回来——自动续传或以暂停态出现在下载中心。
///
/// 清单只描述**意图**，不描述字节进度：已下多少永远以 `.part` 的真实长度为准，
/// 两份真相会漂。
@immutable
class InterconnectVideoResumeRecord {
  const InterconnectVideoResumeRecord({
    required this.videoId,
    required this.title,
    required this.sourceId,
    required this.destPath,
    this.paused = false,
    this.totalBytes,
  });

  /// 远端视频 id（= 管理器任务键 = 落库 bookUid）。
  final String videoId;
  final String title;

  /// 下载发起时的来源身份（`RemoteLibrarySource.remoteLibrarySourceId`）。换了来源
  /// 的清单不自动续：同一个 id 在另一个来源下不保证是同一个文件。
  final String sourceId;

  /// 最终落点（`.part` = `$destPath.part`）。
  final String destPath;

  /// 用户主动暂停（下载中心「暂停」）。暂停的任务重启后只以暂停态出现，不自动续。
  final bool paused;

  /// 已知的总大小（字节）；首次拿到 Content-Length 之前为 null。仅用于重启后在
  /// 暂停态里画进度，不参与续传判据。
  final int? totalBytes;

  File get dest => File(destPath);
  File get partFile => File('$destPath.part');

  InterconnectVideoResumeRecord copyWith({bool? paused, int? totalBytes}) {
    return InterconnectVideoResumeRecord(
      videoId: videoId,
      title: title,
      sourceId: sourceId,
      destPath: destPath,
      paused: paused ?? this.paused,
      totalBytes: totalBytes ?? this.totalBytes,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'videoId': videoId,
        'title': title,
        'sourceId': sourceId,
        'destPath': destPath,
        'paused': paused,
        if (totalBytes != null) 'totalBytes': totalBytes,
      };

  static InterconnectVideoResumeRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? videoId = json['videoId'];
    final Object? sourceId = json['sourceId'];
    final Object? destPath = json['destPath'];
    if (videoId is! String || videoId.isEmpty) return null;
    if (sourceId is! String || sourceId.isEmpty) return null;
    if (destPath is! String || destPath.isEmpty) return null;
    final Object? title = json['title'];
    final Object? total = json['totalBytes'];
    return InterconnectVideoResumeRecord(
      videoId: videoId,
      title: title is String ? title : videoId,
      sourceId: sourceId,
      destPath: destPath,
      paused: json['paused'] == true,
      totalBytes: total is int && total > 0 ? total : null,
    );
  }
}

/// [InterconnectVideoResumeRecord] 的落盘读写。清单路径由落点派生
/// （`$dest.resume.json`），不另建索引：扫目录就是全部真相。
class InterconnectVideoResumeStore {
  const InterconnectVideoResumeStore._();

  static const String manifestSuffix = '.resume.json';

  static File manifestFor(String destPath) => File('$destPath$manifestSuffix');

  /// 写（覆盖）一条清单。先写临时文件再 rename，杀进程时不留半截 JSON。
  static Future<void> write(InterconnectVideoResumeRecord record) async {
    final File manifest = manifestFor(record.destPath);
    await manifest.parent.create(recursive: true);
    final File staged = File('${manifest.path}.tmp');
    await staged.writeAsString(jsonEncode(record.toJson()), flush: true);
    await staged.rename(manifest.path);
  }

  static Future<InterconnectVideoResumeRecord?> read(String destPath) async {
    final File manifest = manifestFor(destPath);
    try {
      if (!await manifest.exists()) return null;
      return InterconnectVideoResumeRecord.fromJson(
        jsonDecode(await manifest.readAsString()),
      );
    } catch (e) {
      debugPrint('[interconnect-resume] unreadable manifest $destPath: $e');
      return null;
    }
  }

  /// 就地改一条清单（不存在则什么也不做）。
  static Future<void> update(
    String destPath,
    InterconnectVideoResumeRecord Function(InterconnectVideoResumeRecord) edit,
  ) async {
    final InterconnectVideoResumeRecord? record = await read(destPath);
    if (record == null) return;
    await write(edit(record));
  }

  /// 下载完成 / 用户放弃：删清单（`.part` 由下载器自己管）。
  static Future<void> clear(String destPath) async {
    try {
      final File manifest = manifestFor(destPath);
      if (await manifest.exists()) await manifest.delete();
    } catch (e) {
      debugPrint('[interconnect-resume] clear manifest failed: $e');
    }
  }

  /// 扫 [dir] 下全部可续的清单。
  ///
  /// 可续 = 清单可解析、且 `.part` 还在、且最终文件还不存在。`.part` 已不在（用户
  /// 手删 / 清缓存）或最终文件已落地（完成后清单没来得及删就被杀）的清单是孤儿，
  /// 顺手删掉，不让它永远冒出来。
  static Future<List<InterconnectVideoResumeRecord>> scan(Directory dir) async {
    final List<InterconnectVideoResumeRecord> records =
        <InterconnectVideoResumeRecord>[];
    if (!await dir.exists()) return records;
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith(manifestSuffix)) continue;
      final String destPath =
          entity.path.substring(0, entity.path.length - manifestSuffix.length);
      final InterconnectVideoResumeRecord? record = await read(destPath);
      // 路径分隔符写法不同（Windows 上 `/` 与 `\` 混用）不算搬家，按规范化后比。
      if (record == null || !p.equals(record.destPath, destPath)) {
        // 解析不了、或清单被搬了目录（destPath 指向别处）：都当孤儿。
        await _deleteQuietly(entity);
        continue;
      }
      if (!await record.partFile.exists() || await record.dest.exists()) {
        await _deleteQuietly(entity);
        continue;
      }
      records.add(record);
    }
    return records;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // 删不掉的孤儿清单下次扫描再试，不影响任何下载。
    }
  }
}
