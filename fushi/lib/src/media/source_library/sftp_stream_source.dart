// SFTP 来源库视频的原地流播（与 WebDAV / AList 来源同等待遇）。
//
// WebDAV / AList 的条目路径本身就是 http(s) URL，播放内核直接能开；SFTP 条目是
// 远端绝对路径，内核开不了。做法与云盘视频流播同一条链：
// - 入库：`videoPath` 存不带凭据的稳定地址 `sftp://<host>:<port><远端路径>`
//   （[SftpUrlNamespaceFileSystem] 在扫描时把整份列表换进这个命名空间，下游的
//   同名字幕关联、作品归组、m3u8 清单解析都不用知道 SFTP 的存在）。路径保持解码态，
//   与 WebDAV 行同一口径（[sourceEntryBasename] 取末段即标题）。
// - 起播：[SftpStreamUrlResolver] 把这类地址登记进进程内回环中继
//   [CloudVideoStreamRelay]，交给内核的是 `http://127.0.0.1:<port>/cloud/<token>/…`；
//   字节经 [NetworkSourceFileSystem.openSftpRange] 按偏移读，seek / 时长与本地同语义。
//   凭据只活在这一层，不进行级数据、不进 libmpv 参数。
//
// FTP 不在此列：所用 ftpconnect 只有整文件下载、没有按偏移读，拖进度条做不到。
library;

import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/video/stream_url_resolver.dart';
import 'package:fushi/src/sync/cloud_video_stream_relay.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';

/// SFTP 来源条目在库里的地址前缀（不带尾斜杠、不带凭据）。
String sftpSourceUrlRoot({required String host, required int port}) =>
    'sftp://$host:$port';

/// 按来源行的 configJson（已解码）取 [sftpSourceUrlRoot]；端口缺省 22，与
/// `SourceLibraryScanner.buildNetworkFileSystem` 同口径。扫描写入与起播解析必须
/// 走这同一处，否则改不改端口两边会对不上前缀。
String sftpSourceUrlRootForConfig(Map<String, Object?> config) =>
    sftpSourceUrlRoot(
      host: (config['host'] as String?) ?? '',
      port: (config['port'] as num?)?.toInt() ?? 22,
    );

/// [url] 落在 [urlRoot] 之下时还原出远端绝对路径，否则 null。
///
/// 不经 [Uri] 解析：路径是解码态，真名里的 `%` / 空格经 [Uri] 往返会被改写。
String? sftpRemotePathOf(String url, String urlRoot) {
  if (!url.startsWith('$urlRoot/')) return null;
  return url.substring(urlRoot.length);
}

/// 把远端绝对路径（`/srv/video/a.mkv`）映射成 `<urlRoot>/srv/video/a.mkv`。
String sftpSourceUrlOf(String remotePath, String urlRoot) =>
    remotePath.startsWith('/') ? '$urlRoot$remotePath' : '$urlRoot/$remotePath';

/// 扫描期的命名空间换装：对外一律是 `sftp://` 地址，对内转回远端路径交给 [inner]。
///
/// 只给视频来源用——书 / 漫画是下载后复制进库的，库里不存远端地址，换不换没有区别。
class SftpUrlNamespaceFileSystem implements SourceFileSystem {
  SftpUrlNamespaceFileSystem(this.inner, {required this.urlRoot});

  final SourceFileSystem inner;

  /// [sftpSourceUrlRoot] 的结果。
  final String urlRoot;

  @override
  bool get isLocal => false;

  String _remote(String path) => sftpRemotePathOf(path, urlRoot) ?? path;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async =>
      <SourceFileEntry>[
        for (final SourceFileEntry e
            in await inner.listFiles(_remote(dirPath), recursive: recursive))
          SourceFileEntry(
            name: e.name,
            path: sftpSourceUrlOf(e.path, urlRoot),
            isDirectory: e.isDirectory,
            sizeBytes: e.sizeBytes,
          ),
      ];

  @override
  Future<List<String>> listSiblingNames(String filePath) =>
      inner.listSiblingNames(_remote(filePath));

  @override
  Future<String> readText(String filePath) => inner.readText(_remote(filePath));

  @override
  Future<String> copyToLocal(String filePath, String destDir) =>
      inner.copyToLocal(_remote(filePath), destDir);
}

/// [NetworkSourceFileSystem.openSftpRange] 的 [SyncAssetRangeReader] 视图；
/// `assetId` 即远端绝对路径。
class SftpSourceRangeReader implements SyncAssetRangeReader {
  SftpSourceRangeReader(this.fs);

  final NetworkSourceFileSystem fs;

  @override
  Future<SyncAssetRange> openAssetRange(
    String assetId, {
    required int start,
    int? end,
  }) async {
    try {
      final ({
        int totalBytes,
        int start,
        int end,
        Stream<List<int>> bytes
      }) range = await fs.openSftpRange(assetId, start: start, end: end);
      return SyncAssetRange(
        start: range.start,
        end: range.end,
        totalBytes: range.totalBytes,
        bytes: range.bytes,
      );
    } on RangeError {
      throw const SyncAssetRangeNotSatisfiable(null);
    }
  }
}

/// 起播期把 `sftp://` 条目地址（视频与 sidecar 字幕）换成回环中继地址。
class SftpStreamUrlResolver implements StreamUrlResolver {
  SftpStreamUrlResolver({
    required this.sourceId,
    required this.urlRoot,
    required NetworkSourceFileSystem fs,
    Future<CloudVideoStreamRelay> Function()? relay,
  })  : _fs = fs,
        _reader = SftpSourceRangeReader(fs),
        _relay = relay ?? CloudVideoStreamRelay.instance;

  final int sourceId;
  final String urlRoot;
  final NetworkSourceFileSystem _fs;
  final SftpSourceRangeReader _reader;
  final Future<CloudVideoStreamRelay> Function() _relay;

  @override
  Future<String> resolve(String url) async {
    final String? remotePath = sftpRemotePathOf(url, urlRoot);
    if (remotePath == null) return url;
    final CloudVideoStreamRelay relay = await _relay();
    return relay
        .register(
          reader: _reader,
          source: 'source-library:$sourceId',
          assetId: remotePath,
          fileName: p.posix.basename(remotePath),
        )
        .toString();
  }

  /// 关掉 SSH 连接。中继里仍挂着本 reader 的登记项在下一次请求时会自动重连——
  /// 播放页已关时内核不会再来要字节，所以不会留下常驻连接。
  @override
  void close() {
    unawaited(_fs.close());
  }
}
