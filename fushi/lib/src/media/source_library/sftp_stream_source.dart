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

/// 相对远端路径在地址里的标记段：`<urlRoot>/~/<相对路径>`。
///
/// SFTP 的相对路径由服务端按登录目录解析（来源根填 `Videos` 即登录目录下的
/// `Videos`），书 / 漫画来源一直把它原样交给 SFTP 客户端。地址里若直接拼成
/// `<urlRoot>/Videos/a.mkv`，还原时就成了绝对路径 `/Videos/a.mkv`、起播读错文件，
/// 所以相对路径必须带一个可区分的标记段。
const String _sftpRelativeMarker = '/~';

/// [url] 落在 [urlRoot] 之下时还原出远端路径，否则 null。与 [sftpSourceUrlOf]
/// 互逆：相对路径还原成相对路径，绝对路径还原成绝对路径。
///
/// 不经 [Uri] 解析：路径是解码态，真名里的 `%` / 空格经 [Uri] 往返会被改写。
String? sftpRemotePathOf(String url, String urlRoot) {
  if (!url.startsWith('$urlRoot/')) return null;
  final String rest = url.substring(urlRoot.length);
  if (rest == _sftpRelativeMarker) return '';
  if (rest.startsWith('$_sftpRelativeMarker/')) {
    return rest.substring(_sftpRelativeMarker.length + 1);
  }
  // 转义过的绝对路径（见 [sftpSourceUrlOf]）：去掉补上的那一道斜杠。
  if (rest.startsWith('//')) return rest.substring(1);
  return rest;
}

/// 把远端路径映射成条目地址，[sftpRemotePathOf] 可无损还原：
/// - 绝对路径 `/srv/video/a.mkv` → `<urlRoot>/srv/video/a.mkv`；
/// - 相对路径 `Videos/a.mkv` → `<urlRoot>/~/Videos/a.mkv`（空串 → `<urlRoot>/~`）；
/// - 会与上面两种撞形的绝对路径（`/~`、`/~/…`、以 `//` 开头）前面再补一道
///   斜杠，还原时去掉。
String sftpSourceUrlOf(String remotePath, String urlRoot) {
  if (!remotePath.startsWith('/')) {
    return remotePath.isEmpty
        ? '$urlRoot$_sftpRelativeMarker'
        : '$urlRoot$_sftpRelativeMarker/$remotePath';
  }
  final bool collides =
      remotePath == _sftpRelativeMarker ||
      remotePath.startsWith('$_sftpRelativeMarker/') ||
      remotePath.startsWith('//');
  return collides ? '$urlRoot/$remotePath' : '$urlRoot$remotePath';
}

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
  }) async => <SourceFileEntry>[
    for (final SourceFileEntry e in await inner.listFiles(
      _remote(dirPath),
      recursive: recursive,
    ))
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

  bool _revoked = false;

  /// 拥有者（[SftpStreamUrlResolver]）已关闭：之后的区间读一律拒绝。中继登记项
  /// 还挂着本 reader 时，若照常读就会经 [NetworkSourceFileSystem] 自动重连出一条
  /// 再也没人关的 SSH 连接。
  void revoke() => _revoked = true;

  @override
  Future<SyncAssetRange> openAssetRange(
    String assetId, {
    required int start,
    int? end,
  }) async {
    if (_revoked) {
      throw StateError('SFTP stream reader was closed');
    }
    try {
      final ({int totalBytes, int start, int end, Stream<List<int>> bytes})
      range = await fs.openSftpRange(assetId, start: start, end: end);
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
  }) : _fs = fs,
       _reader = SftpSourceRangeReader(fs),
       _relay = relay ?? CloudVideoStreamRelay.instance;

  final int sourceId;
  final String urlRoot;
  final NetworkSourceFileSystem _fs;
  final SftpSourceRangeReader _reader;
  final Future<CloudVideoStreamRelay> Function() _relay;
  bool _closed = false;

  @override
  Future<String> resolve(String url) async {
    final String? remotePath = sftpRemotePathOf(url, urlRoot);
    if (remotePath == null) return url;
    if (_closed) {
      throw StateError('SftpStreamUrlResolver used after close');
    }
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

  /// 关掉 SSH 连接，并作废本解析器登记进中继的 reader：之后指向它的请求直接
  /// 失败，不会再经 [NetworkSourceFileSystem] 自动重连出一条无人关闭的连接。
  /// 同一条目被新的解析器（播放页刷新）重新登记时，中继换用新 reader，不受影响。
  @override
  void close() {
    _closed = true;
    _reader.revoke();
    unawaited(_fs.close());
  }
}
