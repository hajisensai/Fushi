/// `fushi_server backup create|restore|status|run|settings`：整机备份 / 还原（格式见 `backup/server_backup.dart`），
/// 自动备份的状态 / 立即跑 / 计划（`backup/server_backup_service.dart`，D14–D16）。
///
/// `create` / `restore` / `run` 是离线命令（拿数据目录锁）：serve 在跑时 `create` / `run` 改用
/// `fushi_server ctl backup create|run`（经 admin API，在运行中的进程里做快照）；`restore`
/// 必须先停服。`status` 只读文件，serve 在不在跑都能用；`settings` 改配置文件，serve 在跑时拒绝
/// （改用 WebUI 或 `ctl backup schedule`，否则 serve 下次保存设置会把它盖掉）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart' show NotEnoughSpaceException;
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/backup/server_backup_service.dart';
import 'package:fushi_server/src/backup/server_backup_status.dart';
import 'package:fushi_server/src/backup/server_backup_store.dart';
import 'package:fushi_server/src/config/server_backup_config.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_data_lock.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

class BackupModule extends CliModule {
  const BackupModule({this.out, this.err});

  final StringSink? out;
  final StringSink? err;

  @override
  List<String> get commands => const <String>['backup'];

  @override
  void register(ArgParser parser) {
    parser.addCommand('backup')
      ..addOption(
        'out',
        abbr: 'o',
        help: tr('create：输出文件路径（必填）', 'create: output file path (required)'),
      )
      ..addFlag(
        'documents',
        defaultsTo: true,
        help: tr(
          'create：带上 documents/（书 / 封面 / 有声书 / 下载；--no-documents 只备份设置与状态）',
          'create: include documents/ (books / covers / audiobooks / downloads; --no-documents backs up only settings and state)',
        ),
      )
      ..addFlag(
        'force',
        negatable: false,
        help: tr(
          'create：覆盖已存在的输出文件',
          'create: overwrite an existing output file',
        ),
      )
      ..addFlag(
        'yes',
        negatable: false,
        help: tr(
          'restore：确认用备份替换当前数据（旧数据挪到 <data_dir>.pre-restore-<时间>/）',
          'restore: confirm replacing the current data with the backup (old data is moved to <data_dir>.pre-restore-<time>/)',
        ),
      )
      // 不能叫 `config`（可取反 flag）：子命令自己的同名项会盖住顶层的 `--config <路径>`，
      // `backup restore x.zip --yes --config my.yaml` 就成了用法错误。拼写仍是 `--no-config`。
      ..addFlag(
        'no-config',
        negatable: false,
        help: tr(
          'restore：不还原配置文件，只还原数据',
          'restore: do not restore the config file, only the data',
        ),
      )
      ..addFlag(
        'if-due',
        negatable: false,
        help: tr(
          'run：只在到期时跑，没变化就跳过（给 cron 用；不加 = 立即跑一份）',
          'run: only run when due and skip when nothing changed (for cron; without it a backup is written now)',
        ),
      )
      ..addOption(
        'interval',
        allowed: <String>[
          for (final ServerBackupInterval v in ServerBackupInterval.values)
            v.name,
        ],
        help: tr('settings：自动备份间隔', 'settings: automatic backup interval'),
      )
      ..addOption(
        'time',
        help: tr(
          'settings：偏好时刻 HH:MM（服务端本地时间）',
          'settings: preferred time HH:MM (server local time)',
        ),
      )
      ..addFlag(
        'auto-documents',
        defaultsTo: null,
        help: tr(
          'settings：自动备份带上 documents/（--no-auto-documents 不带）',
          'settings: include documents/ in automatic backups (--no-auto-documents to leave them out)',
        ),
      )
      ..addOption(
        'max-gb',
        help: tr(
          'settings：自动备份总大小上限 GB（0 = 不限）',
          'settings: total size cap for automatic backups in GB (0 = no limit)',
        ),
      )
      ..addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
  }

  @override
  String get usage => tr(
    '''
backup create -o <file> [--no-documents] [--force] [--json]
    整机备份：数据库快照 + 配置 + 数据目录（serve 在跑时用 ctl backup create）
backup restore <file> --yes [--no-config] [--json]
    从备份还原（须先停服）；旧数据挪到 <data_dir>.pre-restore-<时间>/，不删除；backups/、设备复制来的备份、
    以及备份不含 documents/ 时的 documents/ 原地留着。回到旧版：先用当前程序还原「更新前」备份，再装回旧版
backup status [--json]
    自动备份的计划、上次结果与 <data>/backups/ 里的备份（手动 / 自动 / 更新前）
backup run [--if-due] [--json]
    立即写一份自动备份并按保留规则修剪（serve 在跑时用 ctl backup run）
backup settings [--interval off|daily|every3Days|weekly] [--time HH:MM] [--[no-]auto-documents] [--max-gb N]
    看 / 改自动备份计划（须先停服；serve 在跑时用 WebUI 或 ctl backup schedule）''',
    '''
backup create -o <file> [--no-documents] [--force] [--json]
    Full backup: database snapshot + config + data directory (use ctl backup create while serve is running)
backup restore <file> --yes [--no-config] [--json]
    Restore from a backup (stop the server first); old data is moved to <data_dir>.pre-restore-<time>/ and not deleted;
    backups/, backups copied by devices and (when the backup has no documents/) documents/ stay in place.
    To go back to an older version: restore the pre-update backup with the current program, then reinstall the old one
backup status [--json]
    Automatic backup schedule, last result and the backups in <data>/backups/ (manual / automatic / pre-update)
backup run [--if-due] [--json]
    Write an automatic backup now and prune by the retention rules (use ctl backup run while serve is running)
backup settings [--interval off|daily|every3Days|weekly] [--time HH:MM] [--[no-]auto-documents] [--max-gb N]
    Show / change the automatic backup schedule (stop the server first; use the WebUI or ctl backup schedule while it runs)''',
  );

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final List<String> rest = command.rest;
    final String verb = rest.isEmpty ? '' : rest.first;
    switch (verb) {
      case 'create':
        return _create(command, ctx, o, e);
      case 'restore':
        return _restore(command, ctx, o, e);
      case 'status':
        return _status(command, ctx, o, e);
      case 'run':
        return _run(command, ctx, o, e);
      case 'settings':
        return _settings(command, ctx, o, e);
      default:
        e.writeln(
          tr(
            '用法: backup create -o <file> | backup restore <file> --yes | backup status | backup run | backup settings',
            'Usage: backup create -o <file> | backup restore <file> --yes | backup status | backup run | backup settings',
          ),
        );
        return kExitUsage;
    }
  }

  Future<int> _create(
    ArgResults command,
    CliContext ctx,
    StringSink o,
    StringSink e,
  ) async {
    final String? outPath = command['out'] as String?;
    if (command.rest.length != 1 || outPath == null || outPath.isEmpty) {
      e.writeln(
        tr(
          '用法: backup create -o <file> [--no-documents] [--force]',
          'Usage: backup create -o <file> [--no-documents] [--force]',
        ),
      );
      return kExitUsage;
    }
    final File output = File(p.absolute(outPath));
    if (output.existsSync() && !(command['force'] as bool)) {
      e.writeln(
        tr(
          '已存在: ${output.path}（加 --force 覆盖）',
          'Already exists: ${output.path} (add --force to overwrite)',
        ),
      );
      return kExitFailure;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      if (p.isWithin(rt.config.dataDir, output.path)) {
        e.writeln(
          tr(
            '输出文件不能放在数据目录里: ${output.path}',
            'The output file cannot be inside the data directory: ${output.path}',
          ),
        );
        return kExitUsage;
      }
      try {
        await ensureServerBackupSpace(
          dataDir: rt.config.dataDir,
          outputDir: output.parent.path,
          includeDocuments: command['documents'] as bool,
          configPath: rt.configFile.path,
        );
      } on NotEnoughSpaceException catch (x) {
        e.writeln(
          tr(
            '磁盘空间不够，没有开始备份（${x.detail}）',
            'Not enough free disk space; the backup was not started (${x.detail})',
          ),
        );
        return kExitFailure;
      }
      final File written = await createServerBackup(
        db: rt.db,
        dataDir: rt.config.dataDir,
        configFile: rt.configFile,
        output: output,
        includeDocuments: command['documents'] as bool,
      );
      final int bytes = await written.length();
      if (command['json'] as bool) {
        o.writeln(
          jsonEncode(<String, Object?>{'file': written.path, 'bytes': bytes}),
        );
      } else {
        o.writeln(
          tr(
            '已备份 → ${written.path}（$bytes 字节）',
            'Backed up -> ${written.path} ($bytes bytes)',
          ),
        );
        o.writeln(
          tr(
            '备份里有配置文件（admin_token / 凭据），请当密钥保管。',
            'The backup contains the config file (admin_token / credentials); keep it as a secret.',
          ),
        );
      }
      return kExitOk;
    });
  }

  Future<int> _restore(
    ArgResults command,
    CliContext ctx,
    StringSink o,
    StringSink e,
  ) async {
    if (command.rest.length != 2) {
      e.writeln(
        tr(
          '用法: backup restore <file> --yes [--no-config]',
          'Usage: backup restore <file> --yes [--no-config]',
        ),
      );
      return kExitUsage;
    }
    final File backup = File(p.absolute(command.rest[1]));
    if (!backup.existsSync()) {
      e.writeln(
        tr('找不到备份文件: ${backup.path}', 'Backup file not found: ${backup.path}'),
      );
      return kExitNoInput;
    }
    if (!(command['yes'] as bool)) {
      e.writeln(
        tr(
          '还原会用备份替换当前数据目录与配置（旧的会挪到旁边保留）。确认无误后加 --yes 再跑。',
          'Restoring replaces the current data directory and config with the backup (the old ones are moved aside and kept). Re-run with --yes once you are sure.',
        ),
      );
      return kExitUsage;
    }
    if (!ctx.configFile.existsSync()) {
      e.writeln(
        tr(
          '找不到配置文件 ${ctx.configFile.path}；先跑 fushi_server init',
          'Config file not found: ${ctx.configFile.path}; run fushi_server init first',
        ),
      );
      return kExitNoInput;
    }
    final ServerConfig config;
    try {
      config = await ServerConfig.load(ctx.configFile);
    } on FormatException catch (x) {
      e.writeln(
        tr(
          '配置文件解析失败: ${x.message}',
          'Failed to parse the config file: ${x.message}',
        ),
      );
      return kExitDataError;
    }
    // 不走 withRuntime：那会打开数据库（还原期间库必须关着），只拿锁。
    final ServerDataLock lock;
    try {
      lock = await ServerDataLock.acquire(
        config.dataDir,
        mode: 'offline',
        command: 'backup restore',
      );
    } on ServerDataLockedException catch (x) {
      e.writeln(
        tr(
          '${x.describe()}\n还原前先停掉 serve。',
          '${x.describe()}\nStop serve before restoring.',
        ),
      );
      return kExitConflict;
    }
    try {
      final ServerRestoreResult r = await restoreServerBackup(
        backup: backup,
        dataDir: config.dataDir,
        configFile: (command['no-config'] as bool) ? null : ctx.configFile,
      );
      if (command['json'] as bool) {
        o.writeln(
          jsonEncode(<String, Object?>{
            'createdAt': r.manifest.createdAt.toUtc().toIso8601String(),
            'schemaVersion': r.manifest.schemaVersion,
            'includesDocuments': r.manifest.includesDocuments,
            'previousData': r.previousData?.path,
            'previousConfig': r.previousConfig?.path,
            'keptDocuments': r.keptDocuments,
            'keptDeviceBackups': r.keptDeviceBackups,
          }),
        );
      } else {
        o.writeln(
          tr(
            '已还原（备份时间 ${r.manifest.createdAt.toLocal()}）。',
            'Restored (backup time ${r.manifest.createdAt.toLocal()}).',
          ),
        );
        if (r.previousData != null) {
          o.writeln(
            tr(
              '原数据保留在 ${r.previousData!.path}，确认无误后可删除。',
              'The previous data is kept at ${r.previousData!.path}; delete it once you are sure.',
            ),
          );
        }
        if (r.previousConfig != null) {
          o.writeln(
            tr(
              '原配置保留在 ${r.previousConfig!.path}。',
              'The previous config is kept at ${r.previousConfig!.path}.',
            ),
          );
        }
        if (r.keptDocuments) {
          o.writeln(
            tr(
              '这份备份不含 documents/：现有的 documents/（书 / 封面 / 有声书 / 下载）原地留着，没有挪走。',
              'This backup does not contain documents/: the existing documents/ (books / covers / audiobooks / downloads) stays in place and was not moved.',
            ),
          );
        } else if (!r.manifest.includesDocuments) {
          o.writeln(
            tr(
              '这份备份不含 documents/：书 / 封面 / 下载需重新扫描或下载。',
              'This backup does not contain documents/: books / covers / downloads need to be rescanned or downloaded again.',
            ),
          );
        }
        if (r.keptDeviceBackups) {
          o.writeln(
            tr(
              '已配对设备复制来的备份留在数据目录里，没有挪走。',
              'Backups copied here by paired devices stay in the data folder and were not moved.',
            ),
          );
        }
      }
      return kExitOk;
    } on ServerBackupException catch (x) {
      e.writeln(tr('还原失败: ${x.message}', 'Restore failed: ${x.message}'));
      return kExitDataError;
    } finally {
      await lock.release();
    }
  }

  /// 读配置（不拿锁）；失败时写错误并返回退出码。
  Future<(ServerConfig?, int)> _loadConfig(CliContext ctx, StringSink e) async {
    if (!ctx.configFile.existsSync()) {
      e.writeln(
        tr(
          '找不到配置文件 ${ctx.configFile.path}；先跑 fushi_server init',
          'Config file not found: ${ctx.configFile.path}; run fushi_server init first',
        ),
      );
      return (null, kExitNoInput);
    }
    try {
      return (await ServerConfig.load(ctx.configFile), kExitOk);
    } on FormatException catch (x) {
      e.writeln(
        tr(
          '配置文件解析失败: ${x.message}',
          'Failed to parse the config file: ${x.message}',
        ),
      );
      return (null, kExitDataError);
    }
  }

  Future<int> _status(
    ArgResults command,
    CliContext ctx,
    StringSink o,
    StringSink e,
  ) async {
    final (ServerConfig? config, int code) = await _loadConfig(ctx, e);
    if (config == null) return code;
    final Directory dir = Directory(
      p.join(config.dataDir, kServerBackupDirName),
    );
    final ServerBackupStatus status = ServerBackupStatus.load(dir);
    final List<ServerBackupEntry> items = listServerBackups(dir);
    if (command['json'] as bool) {
      o.writeln(
        jsonEncode(<String, Object?>{
          'schedule': config.backup.toJson(),
          'status': status.toJson(),
          'backupsDir': dir.path,
          'items': <Map<String, Object?>>[
            for (final ServerBackupEntry i in items) i.toJson(),
          ],
        }),
      );
      return kExitOk;
    }
    writeServerBackupSchedule(o, config.backup);
    writeServerBackupStatus(o, status);
    o.writeln(tr('备份目录: ${dir.path}', 'Backup folder: ${dir.path}'));
    if (items.isEmpty) o.writeln(tr('（没有备份）', '(no backups)'));
    for (final ServerBackupEntry i in items) {
      o.writeln('  ${i.name}  ${_kindLabel(i.kind)}  ${i.bytes} B');
    }
    return kExitOk;
  }

  Future<int> _run(
    ArgResults command,
    CliContext ctx,
    StringSink o,
    StringSink e,
  ) async {
    final bool ifDue = command['if-due'] as bool;
    return ctx.withRuntime((ServerRuntime rt) async {
      final ServerBackupService service = ServerBackupService.forServer(
        db: rt.db,
        dataDir: rt.config.dataDir,
        configFile: rt.configFile,
        settings: () => rt.config.backup,
      );
      await service.recoverInterrupted();
      final ServerBackupResult r = await service.runAutomatic(force: !ifDue);
      if (command['json'] as bool) {
        o.writeln(
          jsonEncode(<String, Object?>{
            'outcome': r.outcome?.name,
            'refusal': r.refusal?.name,
            'name': r.name,
            'error': r.error,
            'pruned': r.pruned,
          }),
        );
      } else {
        switch (r.outcome) {
          case ServerBackupOutcome.succeeded:
            o.writeln(
              tr(
                '已备份 → ${p.join(service.dir.path, r.name!)}（按保留规则删了 ${r.pruned.length} 份）',
                'Backed up -> ${p.join(service.dir.path, r.name!)} (retention removed ${r.pruned.length})',
              ),
            );
          case ServerBackupOutcome.skippedUnchanged:
            o.writeln(
              tr(
                '跳过：与上次成功的备份相比没有变化',
                'Skipped: nothing changed since the last successful backup',
              ),
            );
          case ServerBackupOutcome.failed:
            e.writeln(tr('备份失败: ${r.error}', 'Backup failed: ${r.error}'));
          case null:
            o.writeln(switch (r.refusal) {
              ServerBackupRefusal.disabled => tr(
                '自动备份已关闭（backup settings --interval daily 打开）',
                'Automatic backups are off (turn on with backup settings --interval daily)',
              ),
              ServerBackupRefusal.notDue => tr('还没到期', 'Not due yet'),
              _ => tr(
                '没有开始: ${r.refusal?.name}',
                'Not started: ${r.refusal?.name}',
              ),
            });
        }
      }
      return r.outcome == ServerBackupOutcome.failed ? kExitFailure : kExitOk;
    });
  }

  Future<int> _settings(
    ArgResults command,
    CliContext ctx,
    StringSink o,
    StringSink e,
  ) async {
    final (ServerConfig? config, int code) = await _loadConfig(ctx, e);
    if (config == null) return code;
    final String? interval = command['interval'] as String?;
    final String? time = command['time'] as String?;
    final bool? docs = command['auto-documents'] as bool?;
    final String? maxGb = command['max-gb'] as String?;
    ServerBackupConfig next = config.backup;
    try {
      next = next.copyWith(
        interval: ServerBackupInterval.tryParse(interval),
        minuteOfDay: ServerBackupConfig.parseTime(time),
        includeDocuments: docs,
        maxTotalGb: ServerBackupConfig.parseMaxTotalGb(maxGb),
      );
    } on FormatException catch (x) {
      e.writeln(x.message);
      return kExitUsage;
    }
    if (next != config.backup) {
      // 改配置文件要停服：serve 内存里有一份配置，WebUI 下次保存会把这里的改动盖掉。
      final ServerDataLock lock;
      try {
        lock = await ServerDataLock.acquire(
          config.dataDir,
          mode: 'offline',
          command: 'backup settings',
        );
      } on ServerDataLockedException catch (x) {
        e.writeln(
          tr(
            '${x.describe()}\nserve 在跑时用 WebUI「备份」页或 fushi_server ctl backup schedule 改。',
            '${x.describe()}\nWhile serve is running, use the WebUI Backups page or fushi_server ctl backup schedule.',
          ),
        );
        return kExitConflict;
      }
      try {
        // 拿到锁之后重读一次，别盖掉期间别人写进去的改动。
        final ServerConfig fresh = await ServerConfig.load(ctx.configFile);
        await fresh.copyWith(backup: next).save(ctx.configFile);
      } finally {
        await lock.release();
      }
    }
    if (command['json'] as bool) {
      o.writeln(jsonEncode(next.toJson()));
    } else {
      writeServerBackupSchedule(o, next);
    }
    return kExitOk;
  }
}

String _kindLabel(ServerBackupKind k) => switch (k) {
  ServerBackupKind.manual => tr('手动', 'manual'),
  ServerBackupKind.auto => tr('自动', 'automatic'),
  ServerBackupKind.preUpdate => tr('更新前', 'pre-update'),
};

/// 计划的一行说明（CLI 用）。
void writeServerBackupSchedule(StringSink o, ServerBackupConfig s) {
  final String interval = switch (s.interval) {
    ServerBackupInterval.off => tr('关', 'off'),
    ServerBackupInterval.daily => tr('每天', 'daily'),
    ServerBackupInterval.every3Days => tr('每 3 天', 'every 3 days'),
    ServerBackupInterval.weekly => tr('每周', 'weekly'),
  };
  final String cap = s.maxTotalGb == 0
      ? tr('不限', 'none')
      : '${s.maxTotalGb} GB';
  o.writeln(
    tr(
      '自动备份: $interval，${s.time}，${s.includeDocuments ? '带' : '不带'} documents/，上限 $cap',
      'Automatic backups: $interval at ${s.time}, documents/ ${s.includeDocuments ? 'included' : 'excluded'}, cap $cap',
    ),
  );
}

/// 状态的几行说明（CLI 用）。
void writeServerBackupStatus(StringSink o, ServerBackupStatus st) {
  String at(int? ms) => ms == null
      ? '-'
      : DateTime.fromMillisecondsSinceEpoch(ms).toLocal().toString();
  if (st.runningSinceMs != null) {
    o.writeln(
      tr(
        '进行中（或上次被中断，serve 下次启动时清理）: ${st.runningName}，开始于 ${at(st.runningSinceMs)}',
        'In progress (or interrupted; serve cleans up on its next start): ${st.runningName}, started ${at(st.runningSinceMs)}',
      ),
    );
  }
  o.writeln(
    tr(
      '上次成功: ${at(st.lastSuccessAtMs)} ${st.lastSuccessName ?? ''}',
      'Last success: ${at(st.lastSuccessAtMs)} ${st.lastSuccessName ?? ''}',
    ),
  );
  if (st.lastFailureAtMs != null) {
    o.writeln(
      tr(
        '上次失败: ${at(st.lastFailureAtMs)} ${st.lastError ?? ''}',
        'Last failure: ${at(st.lastFailureAtMs)} ${st.lastError ?? ''}',
      ),
    );
  }
  if (st.lastSkippedAtMs != null) {
    o.writeln(
      tr(
        '上次跳过: ${at(st.lastSkippedAtMs)} ${st.lastSkipReason ?? ''}',
        'Last skipped: ${at(st.lastSkippedAtMs)} ${st.lastSkipReason ?? ''}',
      ),
    );
  }
  if (st.preUpdateAtMs != null) {
    o.writeln(
      st.preUpdateError == null
          ? tr(
              '上次更新前备份: ${at(st.preUpdateAtMs)} ${st.preUpdateName ?? ''}',
              'Last pre-update backup: ${at(st.preUpdateAtMs)} ${st.preUpdateName ?? ''}',
            )
          : tr(
              '上次更新前备份失败（更新照样进行了）: ${at(st.preUpdateAtMs)} ${st.preUpdateError}',
              'Last pre-update backup failed (the update went ahead): ${at(st.preUpdateAtMs)} ${st.preUpdateError}',
            ),
    );
  }
}
