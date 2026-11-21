// BUG-5158 回归：一次 saveResumeData 面对的种子数远超 libtorrent alert 队列
// 上限（alert_queue_size 默认 2000；critical 档的 save_resume_data_alert 到
// 3 倍）时，旧实现既不先腾空队列、又一口气对所有种子发 save_resume_data：
// 加种子时堆下的 add_torrent / 状态 alert 早把队列顶满，回执一到就被
// libtorrent 丢弃（只留一条 alerts_dropped_alert），桥接层毫不知情地等满
// 超时 —— 生产上种子 >2000 时 resume 落盘缺失，重启即丢种子。旧实现在本测试
// 上是 saved=0 / timed_out=全部。
//
// 本测试在一个 session 里放进 5000 颗种子（加完不做任何 drain，正是宿主
// 启动加回大量种子后的状态），断言一轮保存就全部落盘、没有一颗靠「超时」
// 糊过去，且盘上的 .resume 与加进去的种子一一对应。
//
// 库路径解析同其它 native 测试：FUSHI_TORRENT_LIB 指向 DLL；缺库整组 skip。

import 'dart:io';

import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:test/test.dart';

/// 远多于 libtorrent 默认 alert_queue_size（2000）的种子数。
const int _torrentCount = 5000;

String? _resolveLibPath() {
  final String? env = Platform.environment['FUSHI_TORRENT_LIB'];
  if (env != null && env.isNotEmpty) {
    return File(env).existsSync() ? env : null;
  }
  return null;
}

void main() {
  final String? explicit = _resolveLibPath();

  EmbeddedTorrentEngine? tryOpen() {
    try {
      return EmbeddedTorrentEngine.open(libraryPath: explicit);
    } on ArgumentError {
      return null;
    }
  }

  final EmbeddedTorrentEngine? engine = tryOpen();
  final String? skip = engine == null
      ? 'fushi_torrent_ffi native lib not built'
      : null;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ht_resume_many_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄未释放；留给系统临时目录清理。
    }
  });

  test(
    'one saveResumeData round persists every torrent even when the count '
    'exceeds the libtorrent alert queue size',
    () {
      final Directory contentDir = Directory('${tempDir.path}/content')
        ..createSync();
      final Directory torrentDir = Directory('${tempDir.path}/torrents')
        ..createSync();
      final Directory resumeDir = Directory('${tempDir.path}/resume');

      final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(
        engine!,
      );
      expect(session, isNotNull);
      addTearDown(session!.close);

      final Set<String> ids = <String>{};
      for (int i = 0; i < _torrentCount; i++) {
        // 内容各不相同 → infohash 各不相同。
        final File content = File('${contentDir.path}/f$i.bin')
          ..writeAsStringSync('fushi resume overflow payload #$i');
        final String torrentPath = '${torrentDir.path}/t$i.torrent';
        final FtAddResult made = engine.makeTorrent(
          contentPath: content.path,
          outTorrentPath: torrentPath,
        );
        expect(made.ok, isTrue, reason: 'makeTorrent #$i: ${made.error}');
        final FtAddResult added = session.addTorrentFile(
          torrentPath,
          savePath: contentDir.path,
        );
        expect(added.ok, isTrue, reason: 'addTorrentFile #$i: ${added.error}');
        ids.add(added.id!);
      }
      expect(ids, hasLength(_torrentCount));

      final FtResumeSaveResult result = session.saveResumeData(
        resumeDir.path,
        timeoutMs: 120000,
      );
      expect(
        (result.saved, result.failed, result.timedOut),
        (_torrentCount, 0, 0),
        reason:
            'every torrent must be persisted in one round '
            '(saved=${result.saved}, failed=${result.failed}, '
            'timedOut=${result.timedOut})',
      );

      final Set<String> onDisk = resumeDir
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .where((String name) => name.endsWith('.resume'))
          .map((String name) => name.substring(0, name.length - 7))
          .toSet();
      expect(onDisk, ids);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
