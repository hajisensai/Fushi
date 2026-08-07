// 阶段1b 真实网络手动冒烟 harness（真机验收用；自动化走
// test/embedded_pipeline_test.dart 的本地 rig，不连外网）。
//
// 用法：
//   dart run tool/download_harness.dart <hibiki_torrent_ffi.dll 路径> \
//       "<magnet 链接>" <保存目录>
//
// 开 DHT + 监听 0.0.0.0:6881，顺序下载 + 元数据就绪后首尾 piece 提优，
// 每秒打印一行进度；下载完成（或 Ctrl+C）退出。

import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
        'usage: dart run tool/download_harness.dart <dll> <magnet> <saveDir>');
    exit(2);
  }
  final String libPath = args[0];
  final String magnet = args[1];
  final Directory saveDir = Directory(args[2])..createSync(recursive: true);

  final EmbeddedTorrentEngine engine =
      EmbeddedTorrentEngine.open(libraryPath: libPath);
  stdout.writeln('libtorrent ${engine.libtorrentVersion()}');

  final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(engine,
      listenInterfaces: '0.0.0.0:6881', enableDht: true);
  if (session == null) {
    stderr.writeln('FAIL: cannot create session');
    exit(1);
  }

  final FtAddResult added =
      session.addMagnet(magnet, savePath: saveDir.path, sequential: true);
  if (!added.ok || added.id == null) {
    stderr.writeln('FAIL: addMagnet: ${added.error}');
    session.close();
    exit(1);
  }
  final String id = added.id!;
  stdout.writeln('added $id (sequential), listen port ${session.listenPort}');

  bool flppApplied = false;
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final FtTorrentStatus? t = session
        .listTorrents()
        .where((FtTorrentStatus e) => e.id == id)
        .firstOrNull;
    if (t == null) {
      stderr.writeln('FAIL: torrent disappeared');
      break;
    }
    if (!flppApplied && t.hasMetadata) {
      flppApplied = session.applyFirstLastPriority(id) == 1;
      stdout.writeln('metadata ready: ${t.name}; first/last piece '
          'priority ${flppApplied ? 'applied' : 'FAILED'}');
      final List<FtFileEntry>? files = session.torrentFiles(id);
      for (final FtFileEntry f in files ?? const <FtFileEntry>[]) {
        stdout.writeln('  [${f.index}] ${f.path} (${f.size} bytes)');
      }
    }
    final String pct = (t.progress * 100).toStringAsFixed(1);
    stdout.writeln('[${t.state}] $pct%  '
        'down ${(t.downRate / 1024).toStringAsFixed(0)} KiB/s  '
        'up ${(t.upRate / 1024).toStringAsFixed(0)} KiB/s  '
        'peers ${t.numPeers}  left ${t.left}');
    if (t.isFinished && t.progress >= 1.0) {
      stdout.writeln('PASS: download complete → ${t.contentPath}');
      break;
    }
  }
  session.close();
}
