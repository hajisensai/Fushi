import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi/src/utils/misc/word_audio_resolver.dart';
import 'package:sqlite3/sqlite3.dart';

/// BUG-1413（BUG-1365 同族的残留边界）：本地音频库「这次没答上」曾与「库里真没
/// 这个词」压成同一个 `null`。
///
/// BUG-1365 只修了**绑定期**那半——同 isolate 内用 `waitForPendingIndexing` 把读
/// 排在自家写之后。它没有、也修不了另一半：`local_audio_db.dart` 的
/// `catch → return null` 依然把 `SQLITE_BUSY` 压成与真·未命中同形的 null，而查词
/// 侧 500ms 的查询预算比库自己的 `busy_timeout = 3000` 更短，超时也 `return null`
/// 且**一条日志都不记**。两条路的终点都是用户看到「暂无发音」，无从知道库在忙。
///
/// 这里用「另一个 isolate 持 `BEGIN EXCLUSIVE`」制造**确定性** BUSY（不靠时间赛跑）。
void _holdExclusiveLock(List<Object?> args) {
  final String dbPath = args[0] as String;
  final SendPort ready = args[1] as SendPort;
  final Database db = sqlite3.open(dbPath, mode: OpenMode.readWrite);
  db.execute('PRAGMA busy_timeout = 30000');
  // EXCLUSIVE 立刻拿独占锁：其它连接连读都拿不到 shared 锁 → 必 SQLITE_BUSY。
  db.execute('BEGIN EXCLUSIVE');
  final ReceivePort release = ReceivePort();
  ready.send(release.sendPort);
  release.listen((Object? msg) {
    db.execute('ROLLBACK');
    db.dispose();
    release.close();
    if (msg is SendPort) msg.send('released');
  });
}

/// 在另一个 isolate 上持有 [dbPath] 的独占锁，直到调用返回的释放回调。
Future<Future<void> Function()> _lockExclusively(String dbPath) async {
  final ReceivePort ready = ReceivePort();
  final Isolate isolate = await Isolate.spawn(
      _holdExclusiveLock, <Object?>[dbPath, ready.sendPort]);
  final SendPort release = await ready.first as SendPort;
  ready.close();
  return () async {
    final ReceivePort done = ReceivePort();
    release.send(done.sendPort);
    await done.first; // 等锁真的放掉再往下（Windows 上占用中的文件删不掉）
    done.close();
    isolate.kill(priority: Isolate.immediate);
  };
}

void _seedDb(String path) {
  final Database db = sqlite3.open(path);
  db.execute('CREATE TABLE entries '
      '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
  db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
  db.execute("INSERT INTO entries VALUES ('勉強','べんきょう','a.mp3','src1')");
  final PreparedStatement stmt =
      db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
  stmt.execute(<Object?>[
    'a.mp3',
    'src1',
    Uint8List.fromList(<int>[1, 2])
  ]);
  stmt.dispose();
  db.dispose();
}

void main() {
  group('BUG-1413: 库忙 vs 库里真没这个词（LocalAudioDb 层）', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_busy_vs_miss');
      dbPath = '${tmp.path}/audio.db';
      _seedDb(dbPath);
    });

    tearDown(() async {
      await LocalAudioDb.waitForPendingIndexing();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('queryMeta：真·未命中仍是 null，撞锁改抛 busy（两者不再同形）', () async {
      // 无锁基线：命中 = 记录，未命中 = null。
      expect(LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう')?.file, 'a.mp3');
      expect(LocalAudioDb.queryMeta(dbPath, 'ないよ', ''), isNull,
          reason: '库读得好好的、里面确实没有 → 权威 miss，保持 null');

      final Future<void> Function() unlock = await _lockExclusively(dbPath);
      try {
        // 修复前：这里返回 null —— 与上面那个「真没这个词」的 null **完全同形**，
        // 调用方无从区分，用户只看到「暂无发音」。
        expect(
          () => LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう'),
          throwsA(isA<LocalAudioUnavailableError>().having(
            (LocalAudioUnavailableError e) => e.reason,
            'reason',
            LocalAudioUnavailableReason.busy,
          )),
          reason: '库被独占＝这次没查出来，不等于库里没有这个词',
        );
      } finally {
        await unlock();
      }

      // 放锁后立刻恢复正常，证明这是瞬态、不该被当成「没有」。
      expect(LocalAudioDb.queryMeta(dbPath, '勉強', 'べんきょう')?.file, 'a.mp3');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('extractBlob：撞锁改抛 busy，不再吞成「这个词条没有音频」', () async {
      final Directory cache = Directory('${tmp.path}/cache')
        ..createSync(recursive: true);
      final Future<void> Function() unlock = await _lockExclusively(dbPath);
      try {
        expect(
          () => LocalAudioDb.extractBlob(
            dbPath: dbPath,
            file: 'a.mp3',
            source: 'src1',
            cacheDir: cache,
          ),
          throwsA(isA<LocalAudioUnavailableError>().having(
            (LocalAudioUnavailableError e) => e.reason,
            'reason',
            LocalAudioUnavailableReason.busy,
          )),
        );
      } finally {
        await unlock();
      }
      expect(
        LocalAudioDb.extractBlob(
          dbPath: dbPath,
          file: 'a.mp3',
          source: 'src1',
          cacheDir: cache,
        ),
        isNotNull,
        reason: '放锁后照常取得到 blob',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('TtsChannel.queryLocalAudio 把 busy 穿透 Isolate.run 边界', () async {
      await TtsChannel.instance.setLocalAudioDbs(
          <LocalAudioDbConfig>[LocalAudioDbConfig(path: dbPath)]);
      // 先让绑定期的建索引跑完，再上锁：这样测的是**查询**撞锁，而不是建索引撞锁。
      await LocalAudioDb.waitForPendingIndexing();
      expect(
          await TtsChannel.instance.queryLocalAudio('勉強', 'べんきょう'), isNotNull);
      expect(await TtsChannel.instance.queryLocalAudio('ないよ', ''), isNull,
          reason: '真·未命中仍是 null');

      final Future<void> Function() unlock = await _lockExclusively(dbPath);
      try {
        // 修复前：TtsChannel 的 catch-all 会把它记一条日志后 `return null`，
        // 与上一行的真·未命中同形。
        await expectLater(
          TtsChannel.instance.queryLocalAudio('勉強', 'べんきょう'),
          throwsA(isA<LocalAudioUnavailableError>()),
        );
      } finally {
        await unlock();
        await TtsChannel.instance
            .setLocalAudioDbs(const <LocalAudioDbConfig>[]);
      }
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('BUG-1413: WordAudioResolver 分开处置「没答上」与「没有这个词」', () {
    tearDown(() {
      WordAudioResolver.debugResetRemoteFailureCooldown();
      WordAudioResolver.debugSetNowProvider(null);
    });

    List<AudioSourceConfig> sourcesLocalThenRemote() => <AudioSourceConfig>[
          AudioSourceConfig.localAudio(
            label: 'local',
            path: '/db/first.db',
            enabled: true,
          ),
          AudioSourceConfig.remoteAudio(
              url: 'https://remote.test/?term={term}'),
        ];

    test('本地库没答上：记一条用户可见错误日志，并继续下一源（不当成 miss）', () async {
      final int before = ErrorLogService.instance.entries.length;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        queryLocalAudioByDbIndex: (_, __, ___) async =>
            throw const LocalAudioUnavailableError(
          reason: LocalAudioUnavailableReason.busy,
          dbPath: '/db/first.db',
        ),
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (_) async =>
            const <String>['https://cdn.test/remote.mp3'],
      );

      final String? result = await resolver.resolveConfigured(
        expression: '勉強',
        reading: 'べんきょう',
        sources: sourcesLocalThenRemote(),
      );

      expect(result, 'https://cdn.test/remote.mp3',
          reason: '本地库没答上不得中断解析，要继续走下一个音源');
      final List<ErrorLogEntry> added =
          ErrorLogService.instance.entries.skip(before).toList();
      expect(added, isNotEmpty,
          reason: 'BUG-1413：库在忙必须留下用户可见的痕迹，'
              '否则用户看到「暂无发音」永远不知道是数据库忙');
      expect(added.map((ErrorLogEntry e) => e.source).join('\n'),
          contains('WordAudioResolver.localAudio'));
    });

    test('本地库真·未命中：安静跳到下一源，不污染错误日志', () async {
      final int before = ErrorLogService.instance.entries.length;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        queryLocalAudioByDbIndex: (_, __, ___) async => null,
        extractLocalAudio: (_, __, {dbIndex = 0}) async => null,
        fetchAudioSourceList: (_) async =>
            const <String>['https://cdn.test/remote.mp3'],
      );

      final String? result = await resolver.resolveConfigured(
        expression: '勉強',
        reading: 'べんきょう',
        sources: sourcesLocalThenRemote(),
      );

      expect(result, 'https://cdn.test/remote.mp3');
      expect(ErrorLogService.instance.entries.length, before,
          reason: '「库里真没这个词」是正常结果，不是错误，不该进错误日志');
    });

    test('blob 提取阶段没答上同样被分开处置', () async {
      final int before = ErrorLogService.instance.entries.length;
      final resolver = WordAudioResolver(
        queryLocalAudio: (_, __) async => null,
        queryLocalAudioByDbIndex: (_, __, dbIndex) async => <String, dynamic>{
          'file': 'a.mp3',
          'source': 'src1',
          'dbIndex': dbIndex,
        },
        extractLocalAudio: (_, __, {dbIndex = 0}) async =>
            throw const LocalAudioUnavailableError(
          reason: LocalAudioUnavailableReason.busy,
        ),
        fetchAudioSourceList: (_) async =>
            const <String>['https://cdn.test/remote.mp3'],
      );

      final String? result = await resolver.resolveConfigured(
        expression: '勉強',
        reading: 'べんきょう',
        sources: sourcesLocalThenRemote(),
      );

      expect(result, 'https://cdn.test/remote.mp3');
      expect(ErrorLogService.instance.entries.length, greaterThan(before));
    });
  });

  group('BUG-1413 源码守卫：查询预算耗尽不得再被吞成同形 null', () {
    final String playbackSrc =
        File('lib/src/utils/misc/lookup_audio_playback.dart')
            .readAsStringSync();
    final String dbSrc =
        File('lib/src/utils/misc/local_audio_db.dart').readAsStringSync();

    test(
        'lookup_audio_playback 的 TimeoutException 分支抛 unavailable 而非 return null',
        () {
      // 500ms 预算比库自己的 busy_timeout=3000 更短，所以库一忙**永远**是这里
      // 先到点；这里 return null 就等于把「没查出来」写成「没有这个词」。
      expect(playbackSrc, contains('on TimeoutException {'));
      final int firstTimeout = playbackSrc.indexOf('on TimeoutException {');
      expect(firstTimeout, greaterThanOrEqualTo(0));
      for (final Match m in 'on TimeoutException {'.allMatches(playbackSrc)) {
        final String block = playbackSrc.substring(m.start, m.start + 200);
        expect(block, contains('throw const LocalAudioUnavailableError('),
            reason: 'BUG-1413：预算耗尽必须归成可区分的 unavailable');
        expect(block.contains('return null;'), isFalse,
            reason: 'BUG-1413：不得再返回与真·未命中同形的 null');
      }
    });

    test('查询预算是共享常量，不再各处手写 500ms 魔数', () {
      expect(playbackSrc, contains('const Duration kLocalAudioQueryBudget'));
      final String enhancement =
          File('lib/src/creator/enhancements/local_audio_enhancement.dart')
              .readAsStringSync();
      expect(enhancement, contains('kLocalAudioQueryBudget'),
          reason: '制卡链与查词链必须用同一个预算，否则两边行为会漂开');
      expect(enhancement, contains('LocalAudioUnavailableError'),
          reason: '制卡链也要接住 unavailable，否则新抛的异常会崩制卡');
    });

    test('local_audio_db 对 BUSY 分类，且不靠调大 busy_timeout 掩盖', () {
      expect(dbSrc, contains('bool _isBusy(SqliteException e)'));
      expect(dbSrc, contains('LocalAudioUnavailableReason.busy'));
      // 查询路径的 busy_timeout 保持 3000：本条修的是「BUSY 被吞成同形 null」，
      // 调大超时只会让撞上的概率变小，同形问题一点没变（典型假修复）。
      expect('PRAGMA busy_timeout = 3000'.allMatches(dbSrc).length, 2,
          reason: 'queryMeta / extractBlob 两条只读查询路径的 busy_timeout 不得被调大');
    });
  });
}
