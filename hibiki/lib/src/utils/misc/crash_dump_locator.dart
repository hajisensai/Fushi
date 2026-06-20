import 'dart:io';

import 'package:flutter/foundation.dart';

/// TODO-607 P0-3：定位 native runner 写出的 Windows minidump（崩溃转储）。
///
/// native 侧（`hibiki/windows/runner/crash_dump.cpp` 的 `WriteDumpFilter`）在进程
/// 未捕获异常时，经 `SetUnhandledExceptionFilter` 把 minidump 写进应用自有目录
/// `%LOCALAPPDATA%\Hibiki\crashdumps\`，文件名 `hibiki-<pid>-<tickcount>.dmp`
/// （两边硬钉同一确定路径，与 `wgc_capture.log` 同根，无 bundle id 推测）。
///
/// 纯 native 闪退（访问违例 / 栈溢出 / 跨线程 teardown 竞态）会绕过 Dart 的
/// `FlutterError.onError` / `runZonedGuarded` / `PlatformDispatcher.onError`，错误
/// 日志里一片空白——这些 `.dmp` 是定位此类崩溃的唯一二进制证据（cdb `!analyze -v`
/// 能解出崩溃帧偏移）。本类把它们暴露给「诊断区 → 崩溃转储」，用户即可一键打开
/// 目录 / 分享给开发者，不必再手动翻 `%LOCALAPPDATA%`。
///
/// 设计成纯函数（注入目录），与 `WgcCaptureLog.resolveLogFile` 同一可测范式：
/// 列目录 + 解析路径都不绑死真实环境，便于在临时目录里单测。
class CrashDumpLocator {
  CrashDumpLocator._();

  /// dump 目录相对 `%LOCALAPPDATA%` 的子路径（native 端 crash_dump.cpp 用同一
  /// `%LOCALAPPDATA%\Hibiki\crashdumps` 常量——两边硬钉，无 bundle id 推测）。
  static const String _relativePath = r'Hibiki\crashdumps';

  /// minidump 文件扩展名（小写，匹配不区分大小写）。
  static const String dumpExtension = '.dmp';

  /// 解析 crashdumps 目录（仅 Windows）。非 Windows、或 `LOCALAPPDATA` 缺失/为空
  /// 时返回 null（上层据此隐藏整个崩溃转储项）。
  ///
  /// 纯函数：[isWindows] / [localAppData] 由调用方注入（生产传
  /// `Platform.isWindows` / `Platform.environment['LOCALAPPDATA']`，诊断页「打开
  /// 文件夹」也用它解析目录），单测注入临时目录。
  static Directory? resolveDumpDirectory({
    bool isWindows = false,
    String? localAppData,
  }) {
    if (!isWindows) return null;
    final String? base = localAppData;
    if (base == null || base.isEmpty) return null;
    return Directory('$base\\$_relativePath');
  }

  /// 列出 [dir] 下的所有 `.dmp` 文件，按修改时间**降序**（最近的崩溃在前）。
  ///
  /// 目录不存在 / 读失败 / 无 dump 返回空列表（绝不抛——诊断 UI 不该因列目录失败
  /// 而崩）。纯文件操作，便于单测注入临时目录。
  @visibleForTesting
  static List<File> listDumps(Directory dir) {
    if (!dir.existsSync()) return <File>[];
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false);
    } catch (_) {
      return <File>[];
    }
    final List<File> dumps = <File>[];
    for (final FileSystemEntity entity in entities) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith(dumpExtension)) continue;
      dumps.add(entity);
    }
    dumps.sort((File a, File b) {
      DateTime aTime;
      DateTime bTime;
      try {
        aTime = a.statSync().modified;
      } catch (_) {
        aTime = DateTime.fromMillisecondsSinceEpoch(0);
      }
      try {
        bTime = b.statSync().modified;
      } catch (_) {
        bTime = DateTime.fromMillisecondsSinceEpoch(0);
      }
      return bTime.compareTo(aTime);
    });
    return dumps;
  }

  /// 便捷封装：用当前进程环境（Windows + `LOCALAPPDATA`）解析并列出 dump。
  /// 非 Windows / 解析失败返回空列表。诊断区直接调它取列表。
  static List<File> listCurrentPlatformDumps() {
    final Directory? dir = resolveDumpDirectory(
      isWindows: Platform.isWindows,
      localAppData: Platform.environment['LOCALAPPDATA'],
    );
    if (dir == null) return <File>[];
    return listDumps(dir);
  }
}
