// TODO-817 M1a / TODO-1274 来源库文件系统抽象。
//
// 网络/本地来源库（local / sftp / ftp / webdav transport，见 hibiki_core
// MediaSources.transport）共用一套扫描契约：列目录、找同名 sidecar、读文本、
// 把网络文件落到本地临时盘。M1b 扫描器据此实现 local，TODO-1274 接入 SFTP/FTP/WebDAV。
//
// 🔴 命名红线（守卫测试钉死：test/media/source_library/source_file_system_test.dart）：
// 「来源库」域（本目录 media/source_library/）与 jidoujisho 血统的 UI 媒体源
// `abstract class MediaSource`（媒体源/标签页概念，hibiki/lib/src/media/media_source.dart，
// 实现在 media/sources/）是两个语义无关的体系。本域类型一律用 SourceLibrary* /
// Source* 前缀（SourceLibraryScanner / SourceLibraryCredentialStore /
// [SourceFileSystem]），**绝不能再声明 MediaSource* 前缀的新类型**，重名会撞符号。
// 唯一例外是 drift 生成行类 MediaSourceRow（DB 层 @DataClassName，表名/列名/落库值
// 不动），消费侧统一用别名 SourceLibraryRow（source_library_row.dart）。
//
// [NetworkSourceFileSystem] 复用 sync 子系统同款传输栈（dartssh2 for SFTP,
// ftpconnect for FTP, WebDavOps for WebDAV）；凭据不落 configJson，由
// SourceLibraryCredentialStore 解析后经 [NetworkSourceConfig] 注入（凭据红线）。

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/sync/webdav_ops.dart';

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
/// 一套契约，使扫描器与具体传输（本地磁盘 vs 网络盘）解耦。
///
/// 实现见 [LocalSourceFileSystem]（M1a 落地）与 [NetworkSourceFileSystem]
/// （TODO-1274 SFTP/FTP 实连）。
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
  /// 网络传输负责下载到 [destDir]。扫描需要把远端文件喂给只吃本地路径的
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

/// 网络来源连接配置（运行时值对象）。密码/私钥由 SourceLibraryCredentialStore 解析后
/// 注入，绝不落 configJson（凭据红线）。
@immutable
class NetworkSourceConfig {
  const NetworkSourceConfig({
    required this.transport,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    this.useTls = false,
  });

  /// 'sftp' | 'ftp' | 'webdav'。
  final String transport;

  /// 远端主机名/IP。
  final String host;

  /// 端口（SFTP 默认 22，FTP 默认 21）。
  final int port;

  /// 登录用户名。
  final String username;

  /// 登录密码；SFTP 可用私钥替代。
  final String? password;

  /// SFTP 私钥 PEM；无则用密码。
  final String? privateKey;

  /// FTP 是否走 FTPS（TLS）。SFTP 忽略此项。
  final bool useTls;

  bool get isSftp => transport == 'sftp';

  bool get isWebDav => transport == 'webdav';
}

/// 网络传输实现（SFTP via dartssh2 / FTP via ftpconnect / WebDAV via [WebDavOps]）。
///
/// 连接惰性建立（首个列目录/下载时才连），跨调用复用同一连接，扫描结束由调用方
/// [close]。SFTP/FTP 远端路径统一用正斜杠拼接（[_joinRemote]），WebDAV 直接以完整
/// URL（PROPFIND 返回的 href）作路径，二者都与本地平台分隔符无关。
class NetworkSourceFileSystem implements SourceFileSystem {
  NetworkSourceFileSystem(this.config);

  final NetworkSourceConfig config;

  // SFTP 连接状态。
  SSHClient? _ssh;
  SftpClient? _sftp;

  // FTP 连接状态。
  FTPConnect? _ftp;
  bool _ftpConnected = false;
  String _ftpHome = '/';

  // WebDAV 连接状态（惰性建立，按首个访问路径的 origin 派生 baseUrl）。
  WebDavOps? _dav;

  @override
  bool get isLocal => false;

  // ── 远端路径工具（恒正斜杠，与宿主平台无关） ─────────────────────────

  /// 用正斜杠把目录与子项拼成远端路径（避免 Windows 宿主下 p.join 混入反斜杠）。
  static String _joinRemote(String dir, String name) {
    if (dir.isEmpty) {
      return name;
    }
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  /// 远端路径的父目录（正斜杠语义）。
  static String _remoteDirname(String path) {
    final int slash = path.lastIndexOf('/');
    if (slash < 0) {
      return '';
    }
    if (slash == 0) {
      return '/';
    }
    return path.substring(0, slash);
  }

  /// 远端路径的 basename（正斜杠语义）。
  static String _remoteBasename(String path) {
    final int slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  // ── SFTP ─────────────────────────────────────────────────────────

  Future<SftpClient> _ensureSftp() async {
    if (_sftp != null && _ssh != null && !_ssh!.isClosed) {
      return _sftp!;
    }
    _sftp = null;
    _ssh = null;
    final String? key = config.privateKey;
    final String? pass = config.password;
    _ssh = SSHClient(
      await SSHSocket.connect(config.host, config.port),
      username: config.username,
      onPasswordRequest: (pass != null && pass.isNotEmpty) ? () => pass : null,
      identities:
          (key != null && key.isNotEmpty) ? SSHKeyPair.fromPem(key) : null,
    );
    _sftp = await _ssh!.sftp();
    return _sftp!;
  }

  Future<List<SourceFileEntry>> _listSftp(
    String dirPath,
    bool recursive,
  ) async {
    final SftpClient sftp = await _ensureSftp();
    final List<SourceFileEntry> result = <SourceFileEntry>[];

    Future<void> walk(String dir) async {
      final List<SftpName> entries = await sftp.listdir(dir);
      for (final SftpName e in entries) {
        if (e.filename == '.' || e.filename == '..') {
          continue;
        }
        final String childPath = _joinRemote(dir, e.filename);
        final bool isDir = e.attr.isDirectory;
        if (isDir) {
          if (recursive) {
            await walk(childPath);
          } else {
            result.add(SourceFileEntry(
              name: e.filename,
              path: childPath,
              isDirectory: true,
            ));
          }
        } else {
          result.add(SourceFileEntry(
            name: e.filename,
            path: childPath,
            isDirectory: false,
            sizeBytes: e.attr.size,
          ));
        }
      }
    }

    await walk(dirPath);
    return result;
  }

  Future<String> _copySftp(String filePath, String destDir) async {
    final SftpClient sftp = await _ensureSftp();
    final String local = p.join(destDir, _remoteBasename(filePath));
    final SftpFile handle =
        await sftp.open(filePath, mode: SftpFileOpenMode.read);
    final IOSink sink = File(local).openWrite();
    try {
      await for (final Uint8List chunk in handle.read()) {
        sink.add(chunk);
      }
    } finally {
      await handle.close();
      await sink.close();
    }
    return local;
  }

  Future<String> _readTextSftp(String filePath) async {
    final SftpClient sftp = await _ensureSftp();
    final SftpFile handle =
        await sftp.open(filePath, mode: SftpFileOpenMode.read);
    try {
      final Uint8List bytes = await handle.readBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await handle.close();
    }
  }

  // ── FTP ──────────────────────────────────────────────────────────

  Future<FTPConnect> _ensureFtp() async {
    if (_ftp != null && _ftpConnected) {
      return _ftp!;
    }
    _ftp = FTPConnect(
      config.host,
      port: config.port,
      user: config.username,
      pass: config.password ?? '',
      securityType: config.useTls ? SecurityType.ftps : SecurityType.ftp,
      timeout: 30,
    );
    final bool ok = await _ftp!.connect();
    if (!ok) {
      _ftp = null;
      throw const FileSystemException('FTP authentication failed');
    }
    _ftpConnected = true;
    try {
      _ftpHome = _normalizeFtpDir(await _ftp!.currentDirectory());
    } catch (_) {
      _ftpHome = '/';
    }
    return _ftp!;
  }

  static String _normalizeFtpDir(String raw) {
    String dir = raw.trim();
    if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
      dir = dir.substring(1, dir.length - 1);
    }
    dir = dir.replaceAll(RegExp(r'/+$'), '');
    return dir.isEmpty ? '/' : dir;
  }

  /// 把可能相对的远端路径锚定为绝对路径（FTP 递归需绝对路径，避免 cwd 漂移）。
  String _absFtp(String path) {
    if (path.startsWith('/')) {
      return path;
    }
    final String home = _ftpHome == '/' ? '' : _ftpHome;
    return _joinRemote(home.isEmpty ? '/' : home, path);
  }

  Future<List<SourceFileEntry>> _listFtp(
    String dirPath,
    bool recursive,
  ) async {
    final FTPConnect ftp = await _ensureFtp();
    final List<SourceFileEntry> result = <SourceFileEntry>[];

    Future<void> walk(String dir) async {
      // dir 恒绝对路径：changeDirectory 用绝对路径消除 cwd 漂移。
      await ftp.changeDirectory(dir);
      final List<FTPEntry> entries = await ftp.listDirectoryContent();
      for (final FTPEntry e in entries) {
        final String name = e.name;
        if (name == '.' || name == '..' || name.isEmpty) {
          continue;
        }
        final String childPath = _joinRemote(dir, name);
        final bool isDir = e.type == FTPEntryType.dir;
        if (isDir) {
          if (recursive) {
            await walk(childPath);
          } else {
            result.add(SourceFileEntry(
              name: name,
              path: childPath,
              isDirectory: true,
            ));
          }
        } else {
          result.add(SourceFileEntry(
            name: name,
            path: childPath,
            isDirectory: false,
            sizeBytes: e.size,
          ));
        }
      }
    }

    await walk(_absFtp(dirPath));
    return result;
  }

  Future<String> _copyFtp(String filePath, String destDir) async {
    final FTPConnect ftp = await _ensureFtp();
    final String abs = _absFtp(filePath);
    final String dir = _remoteDirname(abs);
    final String name = _remoteBasename(abs);
    if (dir.isNotEmpty) {
      await ftp.changeDirectory(dir);
    }
    final String local = p.join(destDir, name);
    final bool ok = await ftp.downloadFile(name, File(local));
    if (!ok) {
      throw FileSystemException('FTP download failed', filePath);
    }
    return local;
  }

  // ── WebDAV ───────────────────────────────────────────────────────

  /// 惰性建 [WebDavOps]：baseUrl 取首个访问路径的 origin（scheme://host[:port]），
  /// 用户名/密码来自注入的 [config]。WebDAV 走 Basic 认证，认证头与具体 URL 无关，
  /// 故整个来源复用同一 ops（连接池），扫描结束由 [close] 释放。
  WebDavOps _ensureDav(String anyUrl) {
    final WebDavOps? existing = _dav;
    if (existing != null) {
      return existing;
    }
    final Uri u = Uri.parse(anyUrl);
    final bool defaultPort =
        (u.scheme == 'https' && (!u.hasPort || u.port == 443)) ||
            (u.scheme == 'http' && (!u.hasPort || u.port == 80));
    final String portSuffix = defaultPort ? '' : ':${u.port}';
    final String origin = '${u.scheme}://${u.host}$portSuffix';
    return _dav = WebDavOps(
      baseUrl: origin,
      username: config.username,
      password: config.password ?? '',
    );
  }

  /// 确保 WebDAV 集合路径以正斜杠结尾（PROPFIND 集合多需尾斜杠，否则部分服务器
  /// 301 重定向；[WebDavOps] 关掉了 followRedirects）。
  static String _ensureTrailingSlash(String url) =>
      url.endsWith('/') ? url : '$url/';

  static String _stripTrailingSlash(String url) =>
      (url.length > 1 && url.endsWith('/'))
          ? url.substring(0, url.length - 1)
          : url;

  /// 从完整 URL 取解码后的末段文件名（PROPFIND href 可能是百分号编码的）。
  static String _urlBasename(String url) {
    final Uri u = Uri.parse(url);
    final List<String> segs =
        u.pathSegments.where((String s) => s.isNotEmpty).toList();
    return segs.isEmpty ? _remoteBasename(url) : segs.last;
  }

  Future<List<SourceFileEntry>> _listDav(
    String dirPath,
    bool recursive,
  ) async {
    final WebDavOps dav = _ensureDav(dirPath);
    final List<SourceFileEntry> result = <SourceFileEntry>[];

    Future<void> walk(String dirUrl) async {
      final String dir = _ensureTrailingSlash(dirUrl);
      final List<DavEntry> children = await dav.propfindChildren(dir);
      final String dirKey = _stripTrailingSlash(dir);
      for (final DavEntry e in children) {
        // Depth:1 的 PROPFIND 会把集合自身也列出来，跳过（尾斜杠归一后相等）。
        if (_stripTrailingSlash(e.href) == dirKey) {
          continue;
        }
        if (e.isCollection) {
          if (recursive) {
            await walk(e.href);
          } else {
            result.add(SourceFileEntry(
              name: e.displayName,
              path: _stripTrailingSlash(e.href),
              isDirectory: true,
            ));
          }
        } else {
          result.add(SourceFileEntry(
            name: e.displayName,
            path: e.href,
            isDirectory: false,
          ));
        }
      }
    }

    await walk(dirPath);
    return result;
  }

  Future<String> _copyDav(String filePath, String destDir) async {
    final WebDavOps dav = _ensureDav(filePath);
    final String local = p.join(destDir, _urlBasename(filePath));
    final HttpClientRequest req = await dav.buildRequest('GET', filePath);
    final HttpClientResponse resp = await req.close();
    dav.checkStatus(resp.statusCode, 'GET $filePath');
    final IOSink sink = File(local).openWrite();
    bool ok = false;
    try {
      await for (final List<int> chunk in resp) {
        sink.add(chunk);
      }
      ok = true;
    } finally {
      await sink.close();
      if (!ok) {
        try {
          File(local).deleteSync();
        } catch (_) {}
      }
    }
    return local;
  }

  Future<String> _readTextDav(String filePath) async {
    final WebDavOps dav = _ensureDav(filePath);
    final HttpClientRequest req = await dav.buildRequest('GET', filePath);
    final HttpClientResponse resp = await req.close();
    dav.checkStatus(resp.statusCode, 'GET $filePath');
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in resp) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ── SourceFileSystem 契约 ────────────────────────────────────────

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) {
    if (config.isSftp) {
      return _listSftp(dirPath, recursive);
    }
    if (config.isWebDav) {
      return _listDav(dirPath, recursive);
    }
    return _listFtp(dirPath, recursive);
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async {
    try {
      final String dir = _remoteDirname(filePath);
      final List<SourceFileEntry> entries = await listFiles(dir);
      return entries
          .where((SourceFileEntry e) => !e.isDirectory)
          .map((SourceFileEntry e) => e.name)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<String> readText(String filePath) async {
    if (config.isSftp) {
      return _readTextSftp(filePath);
    }
    if (config.isWebDav) {
      return _readTextDav(filePath);
    }
    // FTP 无随机读文本原语：下载到临时盘再读。
    final Directory tmp =
        Directory.systemTemp.createTempSync('net_src_ftp_read_');
    try {
      final String local = await _copyFtp(filePath, tmp.path);
      return utf8.decode(
        await File(local).readAsBytes(),
        allowMalformed: true,
      );
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<String> copyToLocal(String filePath, String destDir) {
    if (config.isSftp) {
      return _copySftp(filePath, destDir);
    }
    if (config.isWebDav) {
      return _copyDav(filePath, destDir);
    }
    return _copyFtp(filePath, destDir);
  }

  /// 关闭底层连接（扫描结束调用，幂等）。
  Future<void> close() async {
    try {
      _dav?.close();
    } catch (_) {}
    _dav = null;
    try {
      _sftp?.close();
    } catch (_) {}
    try {
      _ssh?.close();
    } catch (_) {}
    _sftp = null;
    _ssh = null;
    if (_ftp != null && _ftpConnected) {
      try {
        await _ftp!.disconnect();
      } catch (_) {}
    }
    _ftp = null;
    _ftpConnected = false;
  }
}
