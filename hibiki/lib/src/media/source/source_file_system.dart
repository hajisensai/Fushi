// TODO-817 M1a 来源库文件系统抽象。
//
// 网络/本地来源库（local / sftp / ftp / http transport，见 hibiki_core
// MediaSources.transport）共用一套扫描契约：列目录、找同名 sidecar、读文本、
// 把网络文件落到本地临时盘。M1b 扫描器据此实现 local，M2/M3 接网络传输。
//
// 🔴 命名红线：本接口必须叫 [SourceFileSystem]，绝不能叫 MediaSource*——仓库已有
// `abstract class MediaSource`（UI 源/标签页概念，hibiki/lib/src/media/media_source.dart）
// 和 drift 生成行类 MediaSourceRow，重名会撞符号。守卫测试钉死。
//
// M1a 只新增本文件 + LocalSourceFileSystem（dart:io，复用 sidecar_finder 语义）+
// NetworkSourceFileSystem 占位（全部抛 UnimplementedError）。不改任何现有导入器/
// 对话框调用，零行为变化。

import 'dart:io';

import 'package:path/path.dart' as p;

/// 来源文件系统列目录返回的单个条目（文件或子目录）。
///
/// 纯数据类。[path] 是该来源命名空间下的完整路径（本地=绝对磁盘路径；网络=
/// 远端路径），[name] 是 basename，[isDirectory] 区分文件/目录，[sizeBytes]
/// 仅文件可用（目录或无法获取时为 null）。
class SourceFileEntry {
  const SourceFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.sizeBytes,
  });

  /// 条目 basename（不含父目录）。
  final String name;

  /// 该来源命名空间下的完整路径（本地绝对路径 / 网络远端路径）。
  final String path;

  /// 是否为目录。
  final bool isDirectory;

  /// 文件字节大小；目录或不可知时为 null。
  final int? sizeBytes;
}

/// 来源库文件系统抽象：把「列目录 / 找 sidecar / 读文本 / 拉到本地」统一成
/// 一套契约，使 M1b 扫描器与具体传输（本地磁盘 vs 网络盘）解耦。
///
/// 实现见 [LocalSourceFileSystem]（M1a 落地）与 [NetworkSourceFileSystem]
/// （M1a 占位，M2/M3 实连）。
abstract class SourceFileSystem {
  /// 是否为本地传输（true=磁盘直读，无需 [copyToLocal] 下载）。
  bool get isLocal;

  /// 列出 [dirPath] 下的条目。[recursive] 为 true 时深度遍历返回所有后代文件
  /// （递归模式下目录条目不单列，只返回文件，便于扫描器直接消费）。
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  });

  /// 列出 [filePath] 同目录下所有**文件**的 basename（含 [filePath] 自身）。
  ///
  /// 供 sidecar 自动挂载用（同目录同名字幕/音频），喂给 sidecar_finder 的
  /// `selectSidecarNames`。失败（目录不可读 / IO 异常）返回空列表，绝不抛。
  Future<List<String>> listSiblingNames(String filePath);

  /// 读取 [filePath] 的全文文本（UTF-8）。字幕/元数据解析用。
  Future<String> readText(String filePath);

  /// 把 [filePath] 复制/下载到本地目录 [destDir]，返回落地后的本地绝对路径。
  ///
  /// 本地传输（[isLocal]==true）原样返回 [filePath]（已在本地，无需复制）。
  /// 网络传输负责下载到 [destDir]。M1b 扫描需要把远端文件喂给只吃本地路径的
  /// 导入器（epub/视频）时调用。
  Future<String> copyToLocal(String filePath, String destDir);
}

/// 本地磁盘实现：用 `dart:io` 直读，[isLocal] 恒 true。
///
/// 复用 sidecar_finder 的扫描语义（[listSiblingNames] 返回同目录所有文件
/// basename，由调用方喂 `selectSidecarNames`），不重复造 sidecar 匹配规则。
class LocalSourceFileSystem implements SourceFileSystem {
  const LocalSourceFileSystem();

  @override
  bool get isLocal => true;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    final Directory dir = Directory(dirPath);
    if (!await dir.exists()) {
      return const <SourceFileEntry>[];
    }
    final List<SourceFileEntry> entries = <SourceFileEntry>[];
    await for (final FileSystemEntity e
        in dir.list(recursive: recursive, followLinks: false)) {
      if (e is File) {
        int? size;
        try {
          size = await e.length();
        } catch (_) {
          size = null;
        }
        entries.add(SourceFileEntry(
          name: p.basename(e.path),
          path: e.path,
          isDirectory: false,
          sizeBytes: size,
        ));
      } else if (e is Directory && !recursive) {
        // 递归模式只回文件（供扫描器直接消费），非递归才单列子目录。
        entries.add(SourceFileEntry(
          name: p.basename(e.path),
          path: e.path,
          isDirectory: true,
        ));
      }
    }
    return entries;
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async {
    try {
      final Directory dir = File(filePath).parent;
      if (!await dir.exists()) {
        return const <String>[];
      }
      final List<String> names = <String>[];
      await for (final FileSystemEntity e in dir.list(followLinks: false)) {
        if (e is File) {
          names.add(p.basename(e.path));
        }
      }
      return names;
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<String> readText(String filePath) => File(filePath).readAsString();

  @override
  Future<String> copyToLocal(String filePath, String destDir) async {
    // 已在本地，无需复制：原样返回。
    return filePath;
  }
}

/// 网络传输实现占位（sftp/ftp/http）。M1a 不实连任何网络、不碰凭据；所有方法
/// 抛 [UnimplementedError]，待 M2/M3 接入真实传输层后实现。
class NetworkSourceFileSystem implements SourceFileSystem {
  const NetworkSourceFileSystem();

  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    throw UnimplementedError('network transport 待 M2/M3');
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async {
    throw UnimplementedError('network transport 待 M2/M3');
  }

  @override
  Future<String> readText(String filePath) async {
    throw UnimplementedError('network transport 待 M2/M3');
  }

  @override
  Future<String> copyToLocal(String filePath, String destDir) async {
    throw UnimplementedError('network transport 待 M2/M3');
  }
}
