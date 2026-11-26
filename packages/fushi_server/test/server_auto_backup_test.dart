// 服务端自动整机备份（第 4B 期，D14–D16）：文件名与保留规则、到期 / 跳过 / 中断、作业锁、更新前备份、计时器停机、
// 配置段与 admin API。备份写入换成假的（写一个小文件），admin API 那组走真的 createServerBackup。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_backups.dart'
    show adminBackupStartResponse, adminBackupStartedResponse;
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/backup/server_backup.dart'
    show serverBackupSizeEstimate, serverBackupWalkFiles;
import 'package:fushi_server/src/backup/server_backup_scheduler.dart';
import 'package:fushi_server/src/backup/server_backup_service.dart';
import 'package:fushi_server/src/backup/server_backup_status.dart';
import 'package:fushi_server/src/backup/server_backup_store.dart';
import 'package:fushi_server/src/commands/backup_commands.dart';
import 'package:fushi_server/src/config/server_backup_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'command_harness.dart';
import 'support/fake_rwkv.dart';

void _write(String path, String content) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

ServerBackupEntry _e(ServerBackupKind kind, DateTime at, [int bytes = 10]) =>
    ServerBackupEntry(
      name: serverBackupFileNameFor(kind, at),
      kind: kind,
      createdAt: at,
      bytes: bytes,
    );

/// 可控的时钟 + 假写入（写一个小文件；[gate] 给了就等它再写完，模拟慢备份）。
class _Rig {
  _Rig(this.dataDir, {ServerBackupConfig settings = const ServerBackupConfig()})
    : _settings = settings;

  final String dataDir;
  ServerBackupConfig _settings;
  DateTime now = DateTime(2026, 11, 25, 4, 30);
  Completer<void>? gate;
  Exception? failWith;
  bool srsMigrating = false;

  /// 卷的可用空间（第五期）；null = 不知道（照常写）。
  int? Function(String path)? freeBytes;

  /// 卷身份（第五期）；null = 拿不到（保守地全部合计）。
  int? Function(String path)? volumeId;

  /// 给了就让指纹（遍历数据目录）抛它，模拟读不了的子目录。
  FileSystemException? fingerprintFails;
  int writes = 0;
  int holdsReleased = 0;
  final List<bool> documentsFlags = <bool>[];

  set settings(ServerBackupConfig s) => _settings = s;

  late final ServerBackupService service = ServerBackupService(
    dataDir: dataDir,
    settings: () => _settings,
    now: () => now,
    holdSrs: () => srsMigrating ? null : () => holdsReleased++,
    freeBytes: (String path) => freeBytes?.call(path),
    volumeId: (String path) => volumeId?.call(path),
    fingerprinter: ({required bool includeDocuments}) {
      final FileSystemException? fail = fingerprintFails;
      return fail == null ? null : Future<String>.error(fail);
    },
    write: ({required File output, required bool includeDocuments}) async {
      writes++;
      documentsFlags.add(includeDocuments);
      final File partial = File('${output.path}.partial');
      await partial.writeAsString('zip');
      if (gate != null) await gate!.future;
      if (failWith != null) {
        await partial.delete();
        throw failWith!;
      }
      return partial.rename(output.path);
    },
  );

  Directory get dir => service.dir;
  List<String> names() =>
      service.list().map((ServerBackupEntry e) => e.name).toList();
}

void main() {
  group('文件名', () {
    test('三种来源各一个前缀；只认这三种形状，路径逃逸 / 别的名字一律不认', () {
      final DateTime t = DateTime(2026, 11, 25, 4, 0, 7);
      expect(
        serverBackupFileNameFor(ServerBackupKind.auto, t),
        'fushi_server-auto-20261125-040007.zip',
      );
      expect(
        serverBackupFileNameFor(ServerBackupKind.preUpdate, t),
        'fushi_server-pre_update-20261125-040007.zip',
      );
      for (final String ok in <String>[
        'fushi_server-backup-20261125-040007.zip',
        'fushi_server-auto-20261125-040007-2.zip',
        'fushi_server-pre_update-20261125-040007.zip',
      ]) {
        expect(isServerBackupFileName(ok), isTrue, reason: ok);
      }
      for (final String bad in <String>[
        '../fushi_server-auto-20261125-040007.zip',
        'x/fushi_server-auto-20261125-040007.zip',
        r'x\fushi_server-auto-20261125-040007.zip',
        'fushi_server-auto-20261125-040007.zip:stream',
        'fushi_server-auto-20261125-040007.zip.partial',
        'fushi_server-other-20261125-040007.zip',
        'auto_backup_status.json',
        '',
      ]) {
        expect(isServerBackupFileName(bad), isFalse, reason: bad);
      }
      final parsed = parseServerBackupFileName(
        'fushi_server-pre_update-20261125-040007-3.zip',
      )!;
      expect(parsed.kind, ServerBackupKind.preUpdate);
      expect(parsed.createdAt, t);
    });
  });

  group('保留（D15 / D16）', () {
    final DateTime now = DateTime(2026, 11, 25, 12);

    test('自动备份按分层留；手动备份再旧再多也不删', () {
      final List<ServerBackupEntry> list = <ServerBackupEntry>[
        for (int d = 0; d < 120; d++)
          _e(ServerBackupKind.auto, now.subtract(Duration(days: d, hours: 1))),
        for (int d = 0; d < 400; d += 40)
          _e(
            ServerBackupKind.manual,
            now.subtract(Duration(days: d, hours: 2)),
          ),
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final Set<String> doomed = planServerBackupPrune(
        list,
        now: now,
        maxTotalBytes: null,
      ).map((ServerBackupEntry e) => e.name).toSet();
      expect(
        list.where(
          (e) => e.kind == ServerBackupKind.manual && doomed.contains(e.name),
        ),
        isEmpty,
      );
      final List<ServerBackupEntry> keptAuto = list
          .where(
            (e) => e.kind == ServerBackupKind.auto && !doomed.contains(e.name),
          )
          .toList();
      // 48 h（第 0、1 天）+ 7 天每天 + 4 周每周 + 3 个月每月，桶重叠后大约十几份。
      expect(keptAuto.length, inInclusiveRange(10, 16));
      expect(keptAuto.first.createdAt, list.first.createdAt, reason: '最新一份留');
      expect(
        keptAuto.last.createdAt.isAfter(now.subtract(const Duration(days: 91))),
        isTrue,
      );
    });

    test('总大小上限只删自动备份，最新一份与刚写好的那份不删', () {
      final List<ServerBackupEntry> list = <ServerBackupEntry>[
        _e(ServerBackupKind.auto, now.subtract(const Duration(hours: 1)), 600),
        _e(
          ServerBackupKind.manual,
          now.subtract(const Duration(hours: 2)),
          5000,
        ),
        _e(ServerBackupKind.auto, now.subtract(const Duration(hours: 3)), 600),
        _e(ServerBackupKind.auto, now.subtract(const Duration(hours: 4)), 600),
      ];
      final List<String> doomed = planServerBackupPrune(
        list,
        now: now,
        maxTotalBytes: 1000,
        protect: <String>{list[2].name},
      ).map((ServerBackupEntry e) => e.name).toList();
      expect(doomed, <String>[list[3].name]);
    });

    test('更新前备份只留最新 3 份', () {
      final List<ServerBackupEntry> list = <ServerBackupEntry>[
        for (int d = 0; d < 5; d++)
          _e(ServerBackupKind.preUpdate, now.subtract(Duration(days: d * 30))),
      ];
      expect(
        planServerBackupPrune(list, now: now, maxTotalBytes: 1),
        <ServerBackupEntry>[list[3], list[4]],
      );
    });
  });

  group('配置段 backup:', () {
    test('缺省 = 每日 04:00、不带 documents、5 GB；yaml 往返', () {
      final ServerConfig d = ServerConfig.defaults(dataDir: '/tmp/x');
      expect(d.backup, const ServerBackupConfig());
      expect(d.backup.enabled, isTrue);
      expect(d.backup.time, '04:00');
      final ServerConfig changed = d.copyWith(
        backup: const ServerBackupConfig(
          interval: ServerBackupInterval.weekly,
          minuteOfDay: 3 * 60 + 5,
          includeDocuments: true,
          maxTotalGb: 0,
        ),
      );
      final ServerConfig back = ServerConfig.parse(
        changed.toYaml(),
        configDir: '/tmp',
      );
      expect(back.backup, changed.backup);
      expect(back.backup.maxTotalBytes, isNull);
    });

    test('写错了拒绝启动并点名', () {
      for (final String bad in <String>[
        'backup:\n  interval: hourly\n',
        'backup:\n  time: "25:00"\n',
        'backup:\n  time: "4am"\n',
        'backup:\n  max_total_gb: -1\n',
      ]) {
        expect(
          () => ServerConfig.parse('data_dir: d\n$bad', configDir: '/tmp'),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('ServerBackupService', () {
    late Directory tmp;
    late _Rig rig;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_auto_backup_');
      final String data = p.join(tmp.path, 'data');
      _write(p.join(data, 'support', 'fushi.db'), 'db v1');
      _write(p.join(data, 'dicts', 'a.zip'), 'dict');
      _write(p.join(data, 'documents', 'book.epub'), 'book');
      rig = _Rig(data);
    });

    tearDown(() => tmp.delete(recursive: true));

    test('到期就跑：写出 auto 包、记成功；同一时段再查不到期', () async {
      final ServerBackupResult r = await rig.service.runAutomatic();
      expect(r.outcome, ServerBackupOutcome.succeeded);
      expect(r.name, 'fushi_server-auto-20261125-043000.zip');
      expect(rig.documentsFlags, <bool>[false], reason: '默认不带 documents/');
      final ServerBackupStatus st = rig.service.status;
      expect(st.lastSuccessName, r.name);
      expect(st.runningSinceMs, isNull);
      expect(st.fingerprint, isNotNull);
      rig.now = DateTime(2026, 11, 25, 23);
      expect(
        (await rig.service.runAutomatic()).refusal,
        ServerBackupRefusal.notDue,
      );
      // 次日 04:00 之后再到期。
      rig.now = DateTime(2026, 11, 26, 4, 1);
      expect(rig.service.isDue(), isTrue);
    });

    test('遍历数据目录失败（权限）→ 记成这一轮失败；不走作业的 future 也不冒成没人接的异步错误', () async {
      rig.fingerprintFails = const FileSystemException(
        'Directory listing failed',
        'data/locked',
      );
      // 计划任务路径：等结果。
      final ServerBackupResult r = await rig.service.runAutomatic();
      expect(r.outcome, ServerBackupOutcome.failed);
      expect(r.error, contains('Directory listing failed'));
      ServerBackupStatus st = rig.service.status;
      expect(st.lastFailureAtMs, rig.now.millisecondsSinceEpoch);
      expect(st.lastError, contains('Directory listing failed'));
      expect(st.runningSinceMs, isNull);
      expect(rig.service.running, isNull, reason: '作业锁放掉了');
      expect(rig.holdsReleased, 1);

      // admin API「立即跑」路径：只看 started、不接 done。测试 zone 里冒出没人接的错误会让这条用例失败。
      rig.now = DateTime(2026, 11, 25, 5);
      final ServerBackupStart start = rig.service.startAutomatic(force: true);
      expect(start.started, isTrue);
      await rig.service.idle();
      st = rig.service.status;
      expect(st.lastFailureAtMs, rig.now.millisecondsSinceEpoch);
      expect(rig.writes, 0);
      expect(rig.service.running, isNull);
    });

    test('数据目录遍历：起点（或途中的子目录）已经不在 → 跳过，不抛', () {
      expect(
        serverBackupWalkFiles(Directory(p.join(tmp.path, 'gone'))),
        isEmpty,
      );
      expect(
        serverBackupWalkFiles(
          Directory(p.join(tmp.path, 'data')),
        ).map((File f) => p.basename(f.path)).toSet(),
        <String>{'fushi.db', 'a.zip', 'book.epub'},
      );
    });

    test('开始回执 → HTTP：关着 / 没到期照实回，不报成「在跑」', () async {
      Future<Map<String, Object?>> body(shelf.Response r) async =>
          jsonDecode(await r.readAsString()) as Map<String, Object?>;
      rig.settings = const ServerBackupConfig(
        interval: ServerBackupInterval.off,
      );
      shelf.Response r = adminBackupStartResponse(
        rig.service.startAutomatic(),
        running: null,
      );
      expect(r.statusCode, 409);
      expect((await body(r))['error'], 'automatic_backup_disabled');
      rig.settings = const ServerBackupConfig();
      await rig.service.runAutomatic();
      r = adminBackupStartResponse(rig.service.startAutomatic(), running: null);
      expect(r.statusCode, 409);
      expect((await body(r))['error'], 'automatic_backup_not_due');
      rig.gate = Completer<void>();
      final ServerBackupStart first = rig.service.startManual(
        includeDocuments: false,
      );
      r = adminBackupStartResponse(
        rig.service.startManual(includeDocuments: false),
        running: rig.service.running,
      );
      expect(r.statusCode, 409);
      expect(await body(r), <String, Object?>{
        'error': 'backup in progress',
        'running': first.name,
      });
      rig.gate!.complete();
      await first.done;
    });

    test('关着不跑；强制（立即跑）照跑', () async {
      rig.settings = const ServerBackupConfig(
        interval: ServerBackupInterval.off,
      );
      expect(
        (await rig.service.runAutomatic()).refusal,
        ServerBackupRefusal.disabled,
      );
      expect(
        (await rig.service.runAutomatic(force: true)).outcome,
        ServerBackupOutcome.succeeded,
      );
    });

    test('没变化就跳过（算满足）；上次那份被删了 / 数据变了 / 开了 documents → 照常备份', () async {
      await rig.service.runAutomatic();
      rig.now = DateTime(2026, 11, 26, 4, 30);
      final ServerBackupResult skipped = await rig.service.runAutomatic();
      expect(skipped.outcome, ServerBackupOutcome.skippedUnchanged);
      expect(rig.writes, 1);
      final ServerBackupStatus st = rig.service.status;
      expect(st.lastSkipReason, kServerBackupSkipUnchanged);
      expect(st.lastSatisfiedAtMs, rig.now.millisecondsSinceEpoch);
      expect(rig.service.isDue(), isFalse, reason: '跳过也算满足');

      // 上次成功的那份被删了：不能只凭指纹跳过。
      await rig.service.delete(st.lastSuccessName!);
      rig.now = DateTime(2026, 11, 27, 4, 30);
      expect(
        (await rig.service.runAutomatic()).outcome,
        ServerBackupOutcome.succeeded,
      );

      // 数据变了。
      rig.now = DateTime(2026, 11, 28, 4, 30);
      _write(p.join(rig.dataDir, 'dicts', 'b.zip'), 'new dict');
      expect(
        (await rig.service.runAutomatic()).outcome,
        ServerBackupOutcome.succeeded,
      );

      // 没变化，但 documents 开关变了。
      rig.now = DateTime(2026, 11, 29, 4, 30);
      rig.settings = const ServerBackupConfig(includeDocuments: true);
      expect(
        (await rig.service.runAutomatic()).outcome,
        ServerBackupOutcome.succeeded,
      );
      expect(rig.documentsFlags.last, isTrue);
    });

    test('指纹不看 tmp/、logs/、backups/ 与 -shm', () async {
      final String a = await rig.service.fingerprint(includeDocuments: false);
      _write(p.join(rig.dataDir, 'tmp', 'x'), 'x');
      _write(p.join(rig.dataDir, 'logs', 'fushi_server.log'), 'log');
      _write(p.join(rig.dataDir, 'backups', 'auto_backup_status.json'), '{}');
      _write(p.join(rig.dataDir, 'support', 'fushi.db-shm'), 'shm');
      _write(p.join(rig.dataDir, 'documents', 'other.epub'), 'b');
      expect(await rig.service.fingerprint(includeDocuments: false), a);
      _write(p.join(rig.dataDir, 'support', 'fushi.db-wal'), 'wal');
      expect(await rig.service.fingerprint(includeDocuments: false), isNot(a));
    });

    test('复习库正在换代迁移：跳过（不算满足，不是失败），下次检查重试', () async {
      rig.srsMigrating = true;
      final ServerBackupResult r = await rig.service.runAutomatic();
      expect(r.refusal, ServerBackupRefusal.srsMigration);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final ServerBackupStatus st = rig.service.status;
      expect(st.lastSkipReason, kServerBackupSkipSrsMigration);
      expect(st.lastFailureAtMs, isNull);
      expect(st.lastSatisfiedAtMs, isNull);
      expect(rig.service.isDue(), isTrue);
      rig.srsMigrating = false;
      expect(
        (await rig.service.runAutomatic()).outcome,
        ServerBackupOutcome.succeeded,
      );
      expect(rig.holdsReleased, 1, reason: '复习库占位用完就放');
    });

    test('写失败：记失败与原因，不留半截，下次检查重试', () async {
      rig.failWith = const FileSystemException('No space left on device');
      final ServerBackupResult r = await rig.service.runAutomatic();
      expect(r.outcome, ServerBackupOutcome.failed);
      final ServerBackupStatus st = rig.service.status;
      expect(st.lastError, contains('No space left'));
      expect(st.runningSinceMs, isNull);
      expect(
        rig.dir.listSync().whereType<File>().map((f) => p.basename(f.path)),
        <String>[kServerBackupStatusFileName],
      );
      expect(rig.service.isDue(), isTrue);
    });

    test('中断检测：状态里留着「在跑」= 上次进程没了 → 记 interrupted、清半截，这一时段不重跑', () async {
      final DateTime started = DateTime(2026, 11, 25, 4, 1);
      await ServerBackupStatus(
        runningSinceMs: started.millisecondsSinceEpoch,
        runningName: 'fushi_server-auto-20261125-040100.zip',
        runningKind: 'auto',
        lastSatisfiedAtMs: DateTime(2026, 11, 24, 4, 1).millisecondsSinceEpoch,
      ).save(rig.dir);
      _write(
        p.join(rig.dir.path, 'fushi_server-auto-20261125-040100.zip.partial'),
        'half',
      );
      _write(p.join(rig.dir.path, 'notes.txt.partial'), 'not ours');
      expect(await rig.service.recoverInterrupted(), isTrue);
      final ServerBackupStatus st = rig.service.status;
      expect(st.lastError, kServerBackupErrorInterrupted);
      expect(st.lastInterruptedAtMs, started.millisecondsSinceEpoch);
      expect(st.runningSinceMs, isNull);
      expect(
        File(
          p.join(rig.dir.path, 'fushi_server-auto-20261125-040100.zip.partial'),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(rig.dir.path, 'notes.txt.partial')).existsSync(),
        isTrue,
        reason: '只清认得的备份半截',
      );
      expect(rig.service.isDue(), isFalse, reason: '同一时段不在同一处再被杀');
      rig.now = DateTime(2026, 11, 26, 4, 1);
      expect(rig.service.isDue(), isTrue);
      expect(await rig.service.recoverInterrupted(), isFalse);
    });

    test('一把作业锁：手动在跑时自动回 busy；更新前备份等它写完再开始', () async {
      rig.gate = Completer<void>();
      final ServerBackupStart manual = rig.service.startManual(
        includeDocuments: true,
      );
      expect(manual.started, isTrue);
      expect(manual.name, startsWith('fushi_server-backup-'));
      expect(
        rig.service.startAutomatic(force: true).refusal,
        ServerBackupRefusal.busy,
      );
      expect(
        rig.service.startManual(includeDocuments: false).refusal,
        ServerBackupRefusal.busy,
      );
      expect(rig.service.list(), isEmpty, reason: '正在写的那份不列出');
      final Future<ServerBackupResult> pre = rig.service.runPreUpdate();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.writes, 1, reason: '更新前备份还在等');
      final Completer<void> g = rig.gate!;
      rig.gate = null;
      g.complete();
      final ServerBackupResult r = await pre;
      expect(r.outcome, ServerBackupOutcome.succeeded);
      expect(rig.documentsFlags, <bool>[
        true,
        false,
      ], reason: '更新前备份不带 documents/');
      expect(rig.service.status.preUpdateName, r.name);
      expect(rig.service.running, isNull);
    });

    test('更新前备份：留最新 3 份；失败只记状态，不抛', () async {
      for (int i = 0; i < 5; i++) {
        rig.now = DateTime(2026, 11, 20 + i, 10);
        expect(
          (await rig.service.runPreUpdate()).outcome,
          ServerBackupOutcome.succeeded,
        );
      }
      expect(rig.names(), <String>[
        'fushi_server-pre_update-20261124-100000.zip',
        'fushi_server-pre_update-20261123-100000.zip',
        'fushi_server-pre_update-20261122-100000.zip',
      ]);
      rig.failWith = const FileSystemException('boom');
      final ServerBackupResult r = await rig.service.runPreUpdate();
      expect(r.outcome, ServerBackupOutcome.failed);
      expect(rig.service.status.preUpdateError, contains('boom'));
      rig.failWith = null;
      rig.srsMigrating = true;
      final ServerBackupResult refused = await rig.service.runPreUpdate();
      expect(refused.refusal, ServerBackupRefusal.srsMigration);
      expect(rig.service.status.preUpdateError, kServerBackupSkipSrsMigration);
    });

    test('自动备份成功后修剪：手动备份与更新前备份不受上限影响', () async {
      for (final String n in <String>[
        'fushi_server-backup-20250101-000000.zip',
        'fushi_server-pre_update-20250101-000000.zip',
        'fushi_server-auto-20250101-000000.zip',
        'fushi_server-auto-20261124-120000.zip',
      ]) {
        _write(p.join(rig.dir.path, n), 'x' * 100);
      }
      rig.settings = const ServerBackupConfig(maxTotalGb: 0);
      final ServerBackupResult r = await rig.service.runAutomatic(force: true);
      expect(r.pruned, <String>['fushi_server-auto-20250101-000000.zip']);
      expect(
        rig.names(),
        containsAll(<String>[
          'fushi_server-backup-20250101-000000.zip',
          'fushi_server-pre_update-20250101-000000.zip',
          'fushi_server-auto-20261124-120000.zip',
          r.name!,
        ]),
      );
    });

    test('delete：只认备份文件名，正在写的那份不删', () async {
      _write(p.join(rig.dataDir, 'secret.txt'), 's');
      expect(await rig.service.delete('../secret.txt'), isFalse);
      expect(await rig.service.delete('auto_backup_status.json'), isFalse);
      rig.gate = Completer<void>();
      final ServerBackupStart s = rig.service.startManual(
        includeDocuments: false,
      );
      expect(await rig.service.delete(s.name!), isFalse);
      rig.gate!.complete();
      await s.done;
      expect(await rig.service.delete(s.name!), isTrue);
    });
  });

  group('写之前查空间（第五期）', () {
    late Directory tmp;
    late _Rig rig;
    late String data;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_backup_space_');
      data = p.join(tmp.path, 'data');
      _write(p.join(data, 'support', 'fushi.db'), 'x' * 1000);
      _write(p.join(data, 'support', 'srs4.db'), 'y' * 500);
      _write(p.join(data, 'dicts', 'a.zip'), 'd' * 200);
      _write(p.join(data, 'documents', 'book.epub'), 'b' * 5000);
      _write(p.join(data, 'tmp', 'junk.bin'), 'j' * 9000);
      rig = _Rig(data);
    });

    tearDown(() => tmp.delete(recursive: true));

    test('估算：库 + 数据目录（documents 只在带上时）+ 配置；tmp/ 不算', () {
      final String config = p.join(tmp.path, 'fushi_server.yaml');
      _write(config, 'c' * 30);
      final ({int databases, int total}) noDocs = serverBackupSizeEstimate(
        data,
        configPath: config,
        includeDocuments: false,
      );
      expect(noDocs.databases, 1500);
      expect(noDocs.total, 1500 + 200 + 30);
      expect(
        serverBackupSizeEstimate(data, includeDocuments: true).total,
        1500 + 200 + 5000,
      );
    });

    test('自动：空间不够 → 记失败 not_enough_space，不写；腾出空间后照常', () async {
      rig.freeBytes = (String _) => 1 << 20;
      final ServerBackupResult r = await rig.service.runAutomatic(force: true);
      expect(r.outcome, ServerBackupOutcome.failed);
      expect(r.error, kNotEnoughSpaceError);
      expect(rig.writes, 0);
      expect(rig.names(), isEmpty);
      final ServerBackupStatus st = rig.service.status;
      expect(st.lastError, kNotEnoughSpaceError);
      expect(st.runningSinceMs, isNull);
      expect(st.lastSatisfiedAtMs, isNull, reason: '失败不算满足，下次检查重试');

      rig.freeBytes = (String _) => 1 << 40;
      final ServerBackupResult ok = await rig.service.runAutomatic(force: true);
      expect(ok.outcome, ServerBackupOutcome.succeeded);
      expect(rig.writes, 1);
    });

    test('不知道可用空间（探针给 null）→ 照常写', () async {
      rig.freeBytes = (String _) => null;
      final ServerBackupResult r = await rig.service.runAutomatic(force: true);
      expect(r.outcome, ServerBackupOutcome.succeeded);
    });

    test('documents 只在带上时算进去：不带刚好够，带上就不够', () async {
      // 余量 64 MiB + 估算；不带 documents 时估算 1700，带上 6700。
      rig.freeBytes = (String _) => kBackupSpaceMarginBytes + 1700 + 1500 + 10;
      final ServerBackupStart small = rig.service.startManual(
        includeDocuments: false,
      );
      expect(await small.preflight, isNull);
      expect((await small.done).outcome, ServerBackupOutcome.succeeded);
      final ServerBackupStart big = rig.service.startManual(
        includeDocuments: true,
      );
      expect(await big.preflight, kNotEnoughSpaceError);
      expect((await big.done).outcome, ServerBackupOutcome.failed);
      expect(rig.service.lastManualError, kNotEnoughSpaceError);
      expect(rig.writes, 1);
    });

    test('备份目录与 tmp/ 在不同的卷：各自只要放下自己那份', () async {
      final String backups = rig.dir.path;
      rig.volumeId = (String path) =>
          p.isWithin(backups, path) || p.equals(backups, path) ? 1 : 2;
      // 备份卷放得下整份（1700 + 余量）但放不下「整份 + 库快照」；tmp 卷是另一个读数。
      rig.freeBytes = (String path) =>
          p.isWithin(backups, path) || p.equals(backups, path)
          ? kBackupSpaceMarginBytes + 1700 + 10
          : kBackupSpaceMarginBytes + 1500 + 20;
      final ServerBackupResult r = await rig.service.runAutomatic(force: true);
      expect(r.outcome, ServerBackupOutcome.succeeded, reason: '${r.error}');
    });

    test('同一个卷但两次读数不同（中间有写入）：按卷身份合计，读数相同与否不影响', () async {
      final String backups = rig.dir.path;
      rig.volumeId = (String _) => 7;
      // 两个读数各自都够放自己那份，合起来不够：以前按读数分组会放行。
      rig.freeBytes = (String path) =>
          p.isWithin(backups, path) || p.equals(backups, path)
          ? kBackupSpaceMarginBytes + 1700 + 10
          : kBackupSpaceMarginBytes + 1500 + 20;
      final ServerBackupResult r = await rig.service.runAutomatic(force: true);
      expect(r.error, kNotEnoughSpaceError);
    });

    test('立即跑（强制自动备份）也有动笔前检查：空间不够 → preflight 给出错误码', () async {
      rig.freeBytes = (String _) => 1;
      final ServerBackupStart start = rig.service.startAutomatic(force: true);
      expect(start.started, isTrue);
      expect(await start.preflight, kNotEnoughSpaceError);
      expect((await start.done).error, kNotEnoughSpaceError);
      final shelf.Response resp = await adminBackupStartedResponse(
        rig.service.startAutomatic(force: true),
        running: null,
      );
      expect(resp.statusCode, 507);
      await rig.service.pending;
    });

    test('写之前就失败（遍历数据目录读不了）→ preflight_failed，回应 500 且不带原文', () async {
      rig.fingerprintFails = const FileSystemException(
        'secret path C:/x',
        'C:/x',
      );
      final ServerBackupStart start = rig.service.startAutomatic(force: true);
      final shelf.Response resp = await adminBackupStartedResponse(
        start,
        running: null,
      );
      expect(resp.statusCode, 500);
      final String body = await resp.readAsString();
      expect(jsonDecode(body)['error'], kServerBackupErrorPreflightFailed);
      expect(body, isNot(contains('secret')));
      await start.done;
      expect(rig.writes, 0);
    });

    test('没变化跳过的那轮：preflight 放行（202），不当成失败', () async {
      expect(
        (await rig.service.runAutomatic()).outcome,
        ServerBackupOutcome.succeeded,
      );
      rig.now = rig.now.add(const Duration(days: 2));
      final ServerBackupStart again = rig.service.startAutomatic();
      expect(again.started, isTrue);
      expect(await again.preflight, isNull);
      expect((await again.done).outcome, ServerBackupOutcome.skippedUnchanged);
    });

    test('更新前：空间不够 → 记 preUpdateError，不抛（更新照样进行）', () async {
      rig.freeBytes = (String _) => 1;
      final ServerBackupResult r = await rig.service.runPreUpdate();
      expect(r.outcome, ServerBackupOutcome.failed);
      expect(r.error, kNotEnoughSpaceError);
      expect(rig.writes, 0);
      final ServerBackupStatus st = rig.service.status;
      expect(st.preUpdateError, kNotEnoughSpaceError);
      expect(st.preUpdateName, isNull);
      expect(rig.service.running, isNull, reason: '作业锁放掉了');
    });
  });

  group('ServerBackupScheduler', () {
    late Directory tmp;
    late _Rig rig;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_auto_backup_sched_');
      rig = _Rig(p.join(tmp.path, 'data'));
      _write(p.join(rig.dataDir, 'support', 'fushi.db'), 'db');
    });

    tearDown(() => tmp.delete(recursive: true));

    test('启动查一次并跑；stop 取消计时器、等在跑的那轮写完，之后不再跑', () async {
      final ServerBackupScheduler s = ServerBackupScheduler(
        rig.service,
        initialDelay: Duration.zero,
        checkInterval: const Duration(milliseconds: 20),
      );
      rig.gate = Completer<void>();
      await s.start();
      for (int i = 0; i < 100 && rig.writes == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(rig.writes, 1);
      bool stopped = false;
      final Future<void> stopping = s.stop().then((_) => stopped = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(stopped, isFalse, reason: '等写到一半的备份');
      rig.gate!.complete();
      await stopping;
      expect(rig.service.running, isNull);
      expect(rig.service.status.lastSuccessName, isNotNull);
      // 停了之后：时间推进到下一个时段，计时器也不会再跑。
      rig.now = DateTime(2026, 11, 30, 5);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(rig.writes, 1);
      await s.check();
      expect(rig.writes, 1);
    });

    test('start 先做中断检测', () async {
      await const ServerBackupStatus(
        runningSinceMs: 1,
        runningName: 'x',
        runningKind: 'auto',
      ).save(rig.dir);
      final ServerBackupScheduler s = ServerBackupScheduler(
        rig.service,
        initialDelay: const Duration(hours: 1),
      );
      await s.start();
      expect(rig.service.status.lastError, kServerBackupErrorInterrupted);
      await s.stop();
    });
  });

  group('admin API /api/admin/backups（计划与自动备份）', () {
    late Directory tmp;
    late FushiDatabase db;
    late AdminApi api;
    late AdminContext ctx;
    late File configFile;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fushi_admin_auto_backup_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
      final ServerConfig config = ServerConfig.defaults(
        dataDir: p.join(tmp.path, 'data'),
      ).copyWith(adminToken: 'tok');
      await config.save(configFile);
      final ServerPrefs prefs = ServerPrefs(db);
      final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
      final ServerPaths paths = ServerPaths(config.dataDir);
      await paths.ensureLayout();
      ctx = AdminContext(
        config: config,
        configFile: configFile,
        paths: paths,
        log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
        db: db,
        identity: identity,
        host: HeadlessHost(
          srsRwkvHttpClient: noNetworkHttpClient,
          config: config,
          paths: paths,
          db: db,
          prefs: prefs,
          identity: identity,
          p2pAvailable: () => false,
        ),
        startedAt: DateTime.now(),
      );
      api = AdminApi(ctx);
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<(int, Map<String, dynamic>)> call(
      String method,
      String path, [
      Object? body,
    ]) async {
      final shelf.Response r = await api.handle(
        shelf.Request(
          method,
          Uri.parse('http://localhost/api/admin/$path'),
          body: body == null ? null : jsonEncode(body),
        ),
      );
      final String text = await r.readAsString();
      return (
        r.statusCode,
        text.isEmpty
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(text) as Map),
      );
    }

    test('GET 带计划与状态；PUT 改计划写回配置文件；非法值 400 且不改', () async {
      var (int code, Map<String, dynamic> body) = await call('GET', 'backups');
      expect(code, 200);
      expect(body['schedule'], <String, Object?>{
        'interval': 'daily',
        'time': '04:00',
        'documents': false,
        'maxTotalGb': 5,
      });
      expect(body['status'], isA<Map<String, dynamic>>());
      expect(body['backupsDir'], p.join(ctx.config.dataDir, 'backups'));

      (code, body) = await call('PUT', 'backups/schedule', <String, Object?>{
        'interval': 'weekly',
        'time': '03:15',
        'maxTotalGb': 2,
      });
      expect(code, 200, reason: '$body');
      expect((body['schedule'] as Map)['interval'], 'weekly');
      expect((body['schedule'] as Map)['documents'], isFalse, reason: '缺的项不变');
      final ServerConfig saved = await ServerConfig.load(configFile);
      expect(saved.backup.interval, ServerBackupInterval.weekly);
      expect(saved.backup.minuteOfDay, 3 * 60 + 15);
      expect(saved.backup.maxTotalGb, 2);

      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{'interval': 'hourly'},
        <String, Object?>{'time': '24:00'},
        <String, Object?>{'maxTotalGb': -3},
        <String, Object?>{'maxTotalGb': '5'},
        <String, Object?>{'documents': 'yes'},
      ]) {
        (code, body) = await call('PUT', 'backups/schedule', bad);
        expect(code, 400, reason: '$bad');
      }
      expect((await ServerConfig.load(configFile)).backup, saved.backup);
      (code, body) = await call('GET', 'backups/schedule');
      expect((body['schedule'] as Map)['time'], '03:15');
    });

    test(
      'POST run → 202，写出 auto 包（真 createServerBackup），状态记成功；再开 409',
      () async {
        var (int code, Map<String, dynamic> body) = await call(
          'POST',
          'backups/run',
        );
        expect(code, 202, reason: '$body');
        final String name = body['name'] as String;
        expect(name, startsWith('fushi_server-auto-'));
        (code, body) = await call('POST', 'backups');
        expect(code, 409);
        await api.backups.pending;
        (code, body) = await call('GET', 'backups');
        final List<dynamic> items = body['items'] as List<dynamic>;
        expect(items.single['name'], name);
        expect(items.single['kind'], 'auto');
        expect((body['status'] as Map)['lastSuccessName'], name);
        expect((body['status'] as Map)['runningSinceMs'], isNull);
      },
    );

    test('POST run（立即跑）空间不够 → 507，不写', () async {
      registerVolumeFreeBytes((String _) => 1);
      try {
        var (int code, Map<String, dynamic> body) = await call(
          'POST',
          'backups/run',
        );
        expect(code, 507, reason: '$body');
        expect(body['error'], kNotEnoughSpaceError);
        await api.backups.pending;
        (code, body) = await call('GET', 'backups');
        expect(body['items'], isEmpty);
        expect((body['status'] as Map)['lastError'], kNotEnoughSpaceError);
      } finally {
        registerVolumeFreeBytes(null);
      }
    });

    test('POST（手动）空间不够 → 507 not_enough_space，不写；状态里记下原因', () async {
      registerVolumeFreeBytes((String _) => 1);
      try {
        var (int code, Map<String, dynamic> body) = await call(
          'POST',
          'backups',
        );
        expect(code, 507, reason: '$body');
        expect(body['error'], kNotEnoughSpaceError);
        await api.backups.pending;
        (code, body) = await call('GET', 'backups');
        expect(body['items'], isEmpty);
        expect(body['lastError'], kNotEnoughSpaceError);
        expect(body['running'], isNull);
      } finally {
        registerVolumeFreeBytes(null);
      }
    });

    test('下载 / 删除只认备份文件名：越界与状态文件一律 404', () async {
      final String dir = p.join(ctx.config.dataDir, 'backups');
      _write(p.join(dir, 'fushi_server-pre_update-20261125-040000.zip'), 'z');
      _write(p.join(dir, kServerBackupStatusFileName), '{}');
      for (final String bad in <String>[
        kServerBackupStatusFileName,
        Uri.encodeComponent('../fushi_server.yaml'),
        Uri.encodeComponent('..\\fushi_server.yaml'),
        'schedule.zip',
      ]) {
        expect((await call('GET', 'backups/$bad')).$1, 404, reason: bad);
        expect((await call('DELETE', 'backups/$bad')).$1, 404, reason: bad);
      }
      final (int code, Map<String, dynamic> body) = await call(
        'GET',
        'backups',
      );
      expect(code, 200);
      expect((body['items'] as List).single['kind'], 'pre_update');
      expect(
        (await call(
          'DELETE',
          'backups/fushi_server-pre_update-20261125-040000.zip',
        )).$1,
        200,
      );
      expect(
        File(p.join(dir, kServerBackupStatusFileName)).existsSync(),
        isTrue,
      );
    });
  });

  group('CLI backup status / run / settings', () {
    late CommandHarness h;
    late BackupModule module;

    setUp(() async {
      h = await CommandHarness.create();
      module = BackupModule(out: h.out, err: h.err);
    });
    tearDown(() => h.dispose());

    test('settings 改配置；run 写出 auto 包；status 列出来源', () async {
      expect(
        await h.run(module, <String>[
          'backup',
          'settings',
          '--interval',
          'every3Days',
          '--time',
          '02:30',
          '--auto-documents',
          '--json',
        ]),
        0,
        reason: '${h.err}',
      );
      final ServerConfig cfg = await ServerConfig.load(h.configFile);
      expect(cfg.backup.interval, ServerBackupInterval.every3Days);
      expect(cfg.backup.time, '02:30');
      expect(cfg.backup.includeDocuments, isTrue);
      expect(
        await h.run(module, <String>['backup', 'settings', '--time', '7pm']),
        64,
      );

      _write(
        p.join(h.dataDir, 'backups', 'fushi_server-backup-20250101-000000.zip'),
        'm',
      );
      expect(
        await h.run(module, <String>['backup', 'run', '--json']),
        0,
        reason: '${h.err}',
      );
      final Map<String, Object?> run = h.json();
      expect(run['outcome'], 'succeeded');
      expect(run['name'], startsWith('fushi_server-auto-'));
      // 到期规则：刚跑过，--if-due 不跑。
      expect(
        await h.run(module, <String>['backup', 'run', '--if-due', '--json']),
        0,
      );
      expect(h.json()['refusal'], 'notDue');

      expect(await h.run(module, <String>['backup', 'status', '--json']), 0);
      final Map<String, Object?> st = h.json();
      final List<Object?> items = st['items']! as List<Object?>;
      expect(items.map((Object? i) => (i! as Map)['kind']).toSet(), <String>{
        'auto',
        'manual',
      });
      expect((st['status']! as Map)['lastSuccessName'], run['name']);
    });
  });
}
