/// 自动备份用户文件夹的平台半边（docs/specs/2026-11-25-auto-backup-restore-points.md 第三期）。
///
/// - **Android：SAF 树 URI + 持久授权**（原生 `BackupFolderChannel.java`，channel
///   [FushiChannels.backupFolder]）。不借全文件访问：用户在系统选择器里挑一个文件夹（内部存储、SD 卡、
///   支持树的文档提供者），`takePersistableUriPermission` 记住读写授权，重启后照样能写；读写全在原生
///   用 `DocumentsContract` / `ContentResolver` 做（SAF 文件夹没有 `dart:io` 能用的路径）。
/// - **iOS：用户挑的文件夹 + 安全作用域书签**（复用常驻来源文件夹那条 `app.fushi.reader/saf` 书签
///   能力，原生 `FushiDirectoryImport.swift`）。没选「把 app 自己的 Documents 露给『文件』」：那个目录
///   随卸载一起删、也不离开这台设备，恰恰挡不住这一期要防的事；挑的文件夹可以在 iCloud Drive / 第三方
///   提供者里，卸载后仍在、能被别的设备看到。用前解析书签、激活访问，`dart:io` 直接读写那个路径，
///   用完停掉。
/// - 桌面端不走这里：第二期的自定义文件夹就是还原点存储根（真实路径；macOS 已去沙盒，见 spec）。
///
/// 不 import AppModel（import 大环守卫）。
library;

import 'dart:io' show InternetAddressType, NetworkInterface;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:fushi/src/media/source_library/source_folder_access.dart'
    show
        MethodChannelSourceFolderBookmarks,
        SourceFolderAccessException,
        SourceFolderBookmarkPick,
        SourceFolderBookmarks,
        SourceFolderGrant;
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 打开着的文件夹：用完必须 [close]（iOS 停掉安全作用域访问）。
class BackupFolderSession {
  BackupFolderSession({
    required this.mirror,
    Future<void> Function()? close,
    this.refreshedFolder,
  }) : _close = close;

  final BackupFolderMirror mirror;
  final Future<void> Function()? _close;

  /// 书签过期、系统在访问窗口内重建了一份：调用方应把它存回设置。
  final AutoBackupMirrorFolder? refreshedFolder;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _close?.call();
  }
}

/// 一个平台上「用户文件夹」的全部能力。
abstract interface class BackupFolderPlatform {
  /// 这个平台有没有用户文件夹（第三期：Android / iOS）。
  bool get supported;

  /// 弹系统文件夹选择器；取消返回 null。
  Future<AutoBackupMirrorFolder?> pick();

  /// 不再用 [folder]（改回不复制 / 换了文件夹）：Android 放掉持久授权。
  Future<void> forget(AutoBackupMirrorFolder folder);

  /// 打开 [folder]；不可用时抛 [BackupFolderUnavailableException]。
  Future<BackupFolderSession> open(AutoBackupMirrorFolder folder);
}

/// 当前平台的实现。
BackupFolderPlatform currentBackupFolderPlatform() {
  if (kIsWeb) return const UnsupportedBackupFolderPlatform();
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => const AndroidSafBackupFolderPlatform(),
    TargetPlatform.iOS => const IosBookmarkBackupFolderPlatform(),
    _ => const UnsupportedBackupFolderPlatform(),
  };
}

/// 没有用户文件夹的平台（桌面端走自定义存储根）。
class UnsupportedBackupFolderPlatform implements BackupFolderPlatform {
  const UnsupportedBackupFolderPlatform();

  @override
  bool get supported => false;

  @override
  Future<AutoBackupMirrorFolder?> pick() async => null;

  @override
  Future<void> forget(AutoBackupMirrorFolder folder) async {}

  @override
  Future<BackupFolderSession> open(AutoBackupMirrorFolder folder) =>
      throw const BackupFolderUnavailableException('unsupported platform');
}

// ── iOS：安全作用域书签 ─────────────────────────────────────────────────────

/// iOS：挑文件夹时建书签，用前激活、用完停掉。
class IosBookmarkBackupFolderPlatform implements BackupFolderPlatform {
  const IosBookmarkBackupFolderPlatform([this._bookmarks]);

  final SourceFolderBookmarks? _bookmarks;

  SourceFolderBookmarks get _b =>
      _bookmarks ?? const MethodChannelSourceFolderBookmarks();

  @override
  bool get supported => true;

  @override
  Future<AutoBackupMirrorFolder?> pick() async {
    final SourceFolderBookmarkPick? picked = await _b.pickDirectoryBookmark();
    if (picked == null) return null;
    return AutoBackupMirrorFolder(
      handle: picked.bookmark,
      label: p.basename(picked.path),
    );
  }

  @override
  Future<void> forget(AutoBackupMirrorFolder folder) async {}

  @override
  Future<BackupFolderSession> open(AutoBackupMirrorFolder folder) async {
    final SourceFolderGrant grant;
    try {
      grant = await _b.startAccessingBookmark(folder.handle);
    } on SourceFolderAccessException catch (e) {
      throw BackupFolderUnavailableException('${e.code}: ${e.message}');
    }
    final String? refreshed = grant.refreshedBookmark;
    return BackupFolderSession(
      mirror: IoBackupFolderMirror(grant.path),
      close: () => _b.stopAccessingBookmark(grant.path),
      refreshedFolder: refreshed == null
          ? null
          : AutoBackupMirrorFolder(handle: refreshed, label: folder.label),
    );
  }
}

// ── Android：SAF 树 ────────────────────────────────────────────────────────

/// Android：原生 `BackupFolderChannel.java` 管选择、持久授权与全部读写。
class AndroidSafBackupFolderPlatform implements BackupFolderPlatform {
  const AndroidSafBackupFolderPlatform([this._channel]);

  final MethodChannel? _channel;

  MethodChannel get _ch => _channel ?? FushiChannels.backupFolder;

  @override
  bool get supported => true;

  @override
  Future<AutoBackupMirrorFolder?> pick() async {
    final Object? raw = await _ch.invokeMethod<Object?>('pick');
    if (raw is! Map<Object?, Object?> || raw['tree'] is! String) return null;
    final String tree = raw['tree']! as String;
    final Object? label = raw['label'];
    return AutoBackupMirrorFolder(
      handle: tree,
      label: label is String && label.isNotEmpty ? label : tree,
    );
  }

  @override
  Future<void> forget(AutoBackupMirrorFolder folder) async {
    try {
      await _ch.invokeMethod<Object?>('release', <String, Object?>{
        'tree': folder.handle,
      });
    } on PlatformException {
      // 授权早就没了：本来就是要放掉它。
    }
  }

  @override
  Future<BackupFolderSession> open(AutoBackupMirrorFolder folder) async {
    final Object? ok = await _invoke('check', <String, Object?>{
      'tree': folder.handle,
    });
    if (ok != true) {
      throw BackupFolderUnavailableException(folder.label);
    }
    return BackupFolderSession(
      mirror: SafBackupFolderMirror(folder.handle, channel: _ch),
    );
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) =>
      _invokeSaf(_ch, method, args);
}

Future<Object?> _invokeSaf(
  MethodChannel channel,
  String method,
  Map<String, Object?> args,
) async {
  try {
    return await channel.invokeMethod<Object?>(method, args);
  } on PlatformException catch (e) {
    // 原生错误码（`BackupFolderChannel.java` 类注释）→ 已知原因；原文（可能带 URI / 路径）只进调试日志。
    debugPrint(
      'AutoBackup: backup folder $method failed: ${e.code} ${e.message}',
    );
    throw switch (e.code) {
      'UNAVAILABLE' => BackupFolderUnavailableException(e.code),
      'NOT_FOUND' => const BackupMirrorException(kBackupMirrorErrorNotFound),
      'LOCAL_IO' => const BackupMirrorException(kBackupMirrorErrorLocalIo),
      'UNSUPPORTED' => const BackupMirrorException(
        kBackupMirrorErrorUnsupported,
      ),
      'RENAMED' => const BackupMirrorException(kBackupMirrorErrorRenamed),
      'LOADING' => const BackupMirrorException(kBackupMirrorErrorLoading),
      _ => const BackupMirrorException(kBackupMirrorErrorFailed),
    };
  } on MissingPluginException catch (e) {
    throw BackupFolderUnavailableException('$e');
  }
}

/// SAF 树上的副本操作（按名字寻址，原生每次在树根下按显示名找子目录）。
class SafBackupFolderMirror implements BackupFolderMirror {
  SafBackupFolderMirror(this.tree, {MethodChannel? channel})
    : _channel = channel ?? FushiChannels.backupFolder;

  final String tree;
  final MethodChannel _channel;

  Future<Object?> _invoke(String method, Map<String, Object?> args) =>
      _invokeSaf(_channel, method, <String, Object?>{'tree': tree, ...args});

  @override
  Future<MirrorFolderListing> list() async {
    final Object? raw = await _invoke('list', const <String, Object?>{});
    final List<MirroredRestorePoint> points = <MirroredRestorePoint>[];
    if (raw is List<Object?>) {
      for (final Object? e in raw) {
        if (e is! Map<Object?, Object?>) continue;
        final Object? name = e['name'];
        final Object? meta = e['meta'];
        // 名字来自提供者（显示名），按它拼路径前先认形状：`..`、带分隔符的一律不要。
        if (name is! String || meta is! String) continue;
        if (!isScheduledRestorePointId(name)) continue;
        final RestorePoint? point = RestorePoint.tryParse(
          meta,
          id: name,
          directory: '$tree/$name',
        );
        if (point == null || point.kind != RestorePointKind.scheduled) {
          continue;
        }
        points.add(MirroredRestorePoint(point: point, metaText: meta));
      }
    }
    points.sort(
      (MirroredRestorePoint a, MirroredRestorePoint b) =>
          b.point.createdAtMs.compareTo(a.point.createdAtMs),
    );
    return MirrorFolderListing(points: points);
  }

  @override
  Future<void> upload(RestorePoint local, {required String metaText}) =>
      _invoke('upload', <String, Object?>{
        'dir': local.id,
        'files': <Map<String, Object?>>[
          for (final RestorePointFile f in local.files)
            <String, Object?>{
              'name': f.name,
              'path': p.join(local.directory, f.name),
            },
        ],
        'metaName': kRestorePointMetaFileName,
        'metaText': metaText,
      });

  @override
  Future<void> download(MirroredRestorePoint copy, String destDirectory) =>
      _invoke('download', <String, Object?>{
        'dir': copy.id,
        'files': <String>[
          for (final RestorePointFile f in copy.point.files) f.name,
        ],
        'destDir': destDirectory,
      });

  @override
  Future<void> delete(String id) {
    if (!isScheduledRestorePointId(id)) {
      throw ArgumentError.value(id, 'id', 'not a restore point id');
    }
    return _invoke('delete', <String, Object?>{'dir': id});
  }
}

// ── 网络：云端副本只在不计流量的网络上传（D10） ──────────────────────────────

/// 当前网络是不是不计流量（Wi-Fi / 以太网）。
///
/// - Android：`ConnectivityManager.isActiveNetworkMetered()`（原生 `networkUnmetered`；按流量计费的
///   Wi-Fi 热点也算计流量）。
/// - iOS：Wi-Fi 接口 `en0` 有可路由的 IPv4 地址就算在 Wi-Fi 上（有 Wi-Fi 时系统默认走 Wi-Fi）。
/// - 桌面：一律算不计流量（有线 / Wi-Fi）。
/// 查不出来时按计流量处理（宁可晚传，不偷用移动数据）。
Future<bool> currentNetworkUnmetered({MethodChannel? channel}) async {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      try {
        final Object? raw = await (channel ?? FushiChannels.backupFolder)
            .invokeMethod<Object?>('networkUnmetered');
        return raw == true;
      } on PlatformException {
        return false;
      } on MissingPluginException {
        return false;
      }
    case TargetPlatform.iOS:
      try {
        final List<NetworkInterface> interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        return interfaces.any(
          (NetworkInterface i) =>
              i.name == 'en0' &&
              i.addresses.any((a) => !a.isLinkLocal && !a.isLoopback),
        );
      } on Object {
        return false;
      }
    case TargetPlatform.fuchsia:
      return false;
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return true;
  }
}
