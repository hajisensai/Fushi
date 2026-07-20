import 'dart:io';
import 'dart:typed_data';

import '../embedded_torrent_engine.dart';

/// 本地做种 rig：确定性、零外网的端到端下载测试脚手架。
///
/// 生成伪随机内容文件（固定种子，逐次运行字节一致）→ `ht_make_torrent`
/// 生成 .torrent → 起一个只绑 127.0.0.1 的做种 session 并等它进入做种态。
/// 被测方随后 `addMagnet("magnet:?xt=urn:btih:<infoHash>")` +
/// `connectPeer(infoHash, '127.0.0.1', seederPort)` 即可从它拉元数据 + 数据。
class LocalSeedRig {
  LocalSeedRig._({
    required this.seeder,
    required this.infoHash,
    required this.seederPort,
    required this.torrentPath,
    required this.contentFile,
  });

  /// 做种 session（rig 拥有；[dispose] 关闭）。
  final EmbeddedTorrentSession seeder;

  /// 内容种子的 infohash（小写十六进制）。
  final String infoHash;

  /// 做种 session 实际监听端口（127.0.0.1）。
  final int seederPort;

  /// 生成的 .torrent 文件路径。
  final String torrentPath;

  /// 内容文件（被测方下载完成后逐字节比对用）。
  final File contentFile;

  /// 供被测方直接添加的磁力链接。
  String get magnetUri => 'magnet:?xt=urn:btih:$infoHash&dn=rig-content';

  /// 生成确定性伪随机字节（xorshift32，固定种子）。
  static Uint8List deterministicBytes(int length, {int seed = 0x9e3779b9}) {
    final Uint8List out = Uint8List(length);
    int state = seed;
    for (int i = 0; i < length; i++) {
      state ^= (state << 13) & 0xffffffff;
      state ^= state >> 17;
      state ^= (state << 5) & 0xffffffff;
      out[i] = state & 0xff;
    }
    return out;
  }

  /// 起 rig：在 [workDir] 下建内容文件与 .torrent，并等做种就绪。
  /// 失败（建 session / 做种超时等）抛 [StateError]，测试直接红。
  static Future<LocalSeedRig> start({
    required EmbeddedTorrentEngine engine,
    required Directory workDir,
    int contentBytes = 8 * 1024 * 1024,
  }) async {
    final Directory seedDir = Directory('${workDir.path}/seed')
      ..createSync(recursive: true);
    final File content = File('${seedDir.path}/rig-content')
      ..writeAsBytesSync(deterministicBytes(contentBytes));

    final String torrentPath = '${workDir.path}/rig-content.torrent';
    final HtAddResult made = engine.makeTorrent(
        contentPath: content.path, outTorrentPath: torrentPath);
    if (!made.ok || made.id == null) {
      throw StateError('make_torrent failed: ${made.error}');
    }

    // 端口 0 = 系统分配；拿不到实际端口视为环境异常。
    final EmbeddedTorrentSession? seeder =
        EmbeddedTorrentSession.open(engine, listenInterfaces: '127.0.0.1:0');
    if (seeder == null) throw StateError('cannot create seeder session');
    try {
      final int port = await _waitFor<int>(
        () async {
          final int p = seeder.listenPort;
          return p > 0 ? p : null;
        },
        timeout: const Duration(seconds: 10),
        what: 'seeder listen port',
      );

      final HtAddResult added =
          seeder.addTorrentFile(torrentPath, savePath: seedDir.path);
      if (!added.ok) throw StateError('seeder add failed: ${added.error}');

      // 等 hash 校验完、进入做种/完成态。
      await _waitFor<bool>(
        () async {
          final List<HtTorrentStatus> ts = seeder.listTorrents();
          if (ts.isEmpty) return null;
          return (ts.first.isSeeding || ts.first.isFinished) ? true : null;
        },
        timeout: const Duration(seconds: 30),
        what: 'seeder to finish checking',
      );

      return LocalSeedRig._(
        seeder: seeder,
        infoHash: made.id!,
        seederPort: port,
        torrentPath: torrentPath,
        contentFile: content,
      );
    } catch (_) {
      seeder.close();
      rethrow;
    }
  }

  /// 轮询直到 [probe] 返回非 null；超时抛 [StateError]。
  static Future<T> _waitFor<T>(
    Future<T?> Function() probe, {
    required Duration timeout,
    required String what,
    Duration interval = const Duration(milliseconds: 100),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      final T? result = await probe();
      if (result != null) return result;
      await Future<void>.delayed(interval);
    }
    throw StateError('timeout waiting for $what');
  }

  void dispose() {
    seeder.close();
  }
}
