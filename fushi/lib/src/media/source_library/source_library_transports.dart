/// 来源库的传输层常量与网络文件系统工厂。
///
/// 只依赖 `source_file_system.dart`，故意不进 [SourceLibraryScanner]：音乐远程播放
/// （`music_remote_media.dart`）与流地址解析（`source_stream_headers.dart`）只要
/// 这两样，经扫描器 import 会把它们连同整个音乐播放层拖进 AppModel 大环
/// （`test/build/import_cycle_guard_test.dart`）。
library;

import 'package:fushi/src/media/source_library/source_file_system.dart';

/// 视频域允许的网络传输：条目可原地流播（WebDAV / AList 条目就是 http(s) URL；
/// SFTP 条目入库为 `sftp://` 稳定地址、起播时经回环中继按偏移读，见
/// sftp_stream_source.dart）。FTP 不在其中：读不了区间，拖不了进度条。
const Set<String> kStreamableVideoSourceTransports = <String>{
  'sftp',
  'webdav',
  'alist',
};

/// 纯构造：把 transport + 连接参数 + 凭据组装成 [SourceFileSystem]（无 I/O）。
/// 扫描与 SFTP 视频的播放期解析器（source_stream_headers.dart）共用这一处，测试也
/// 借它断言路由正确。WebDAV 的 host/port/useTls 不参与传输（URL 即 rootPath，
/// 自带 scheme/host/端口），此处仍原样填入仅为字段对齐，NetworkSourceFileSystem 忽略。
SourceFileSystem buildSourceFileSystem({
  required String transport,
  required Map<String, Object?> config,
  String? password,
  String? privateKey,
}) {
  if (transport == 'local') {
    return const LocalSourceFileSystem();
  }
  final int port =
      (config['port'] as num?)?.toInt() ?? (transport == 'sftp' ? 22 : 21);
  return NetworkSourceFileSystem(
    NetworkSourceConfig(
      transport: transport,
      host: (config['host'] as String?) ?? '',
      port: port,
      username: (config['username'] as String?) ?? '',
      password: (password != null && password.isNotEmpty) ? password : null,
      privateKey: (privateKey != null && privateKey.isNotEmpty)
          ? privateKey
          : null,
      useTls: (config['useTls'] as bool?) ?? false,
      baseUrl: (config['baseUrl'] as String?),
    ),
  );
}
