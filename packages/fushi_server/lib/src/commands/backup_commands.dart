/// `fushi_server backup create|restore`：整机备份 / 还原（格式见 `backup/server_backup.dart`）。
///
/// 两条都是离线命令（拿数据目录锁）：serve 在跑时 `create` 改用
/// `fushi_server ctl backup create`（经 admin API，在运行中的进程里做快照）；`restore`
/// 必须先停服。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_data_lock.dart';
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
      ..addOption('out', abbr: 'o', help: 'create：输出文件路径（必填）')
      ..addFlag(
        'documents',
        defaultsTo: true,
        help: 'create：带上 documents/（书 / 封面 / 有声书 / 下载；--no-documents 只备份设置与状态）',
      )
      ..addFlag('force', negatable: false, help: 'create：覆盖已存在的输出文件')
      ..addFlag(
        'yes',
        negatable: false,
        help: 'restore：确认用备份替换当前数据（旧数据挪到 <data_dir>.pre-restore-<时间>/）',
      )
      // 不能叫 `config`（可取反 flag）：子命令自己的同名项会盖住顶层的 `--config <路径>`，
      // `backup restore x.zip --yes --config my.yaml` 就成了用法错误。拼写仍是 `--no-config`。
      ..addFlag('no-config', negatable: false, help: 'restore：不还原配置文件，只还原数据')
      ..addFlag('json', negatable: false, help: '输出 JSON');
  }

  @override
  String get usage => '''
backup create -o <file> [--no-documents] [--force] [--json]
    整机备份：数据库快照 + 配置 + 数据目录（serve 在跑时用 ctl backup create）
backup restore <file> --yes [--no-config] [--json]
    从备份还原（须先停服）；旧数据挪到 <data_dir>.pre-restore-<时间>/，不删除''';

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
      default:
        e.writeln('用法: backup create -o <file> | backup restore <file> --yes');
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
      e.writeln('用法: backup create -o <file> [--no-documents] [--force]');
      return kExitUsage;
    }
    final File output = File(p.absolute(outPath));
    if (output.existsSync() && !(command['force'] as bool)) {
      e.writeln('已存在: ${output.path}（加 --force 覆盖）');
      return kExitFailure;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      if (p.isWithin(rt.config.dataDir, output.path)) {
        e.writeln('输出文件不能放在数据目录里: ${output.path}');
        return kExitUsage;
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
        o.writeln('已备份 → ${written.path}（$bytes 字节）');
        o.writeln('备份里有配置文件（admin_token / 凭据），请当密钥保管。');
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
      e.writeln('用法: backup restore <file> --yes [--no-config]');
      return kExitUsage;
    }
    final File backup = File(p.absolute(command.rest[1]));
    if (!backup.existsSync()) {
      e.writeln('找不到备份文件: ${backup.path}');
      return kExitNoInput;
    }
    if (!(command['yes'] as bool)) {
      e.writeln('还原会用备份替换当前数据目录与配置（旧的会挪到旁边保留）。确认无误后加 --yes 再跑。');
      return kExitUsage;
    }
    if (!ctx.configFile.existsSync()) {
      e.writeln('找不到配置文件 ${ctx.configFile.path}；先跑 fushi_server init');
      return kExitNoInput;
    }
    final ServerConfig config;
    try {
      config = await ServerConfig.load(ctx.configFile);
    } on FormatException catch (x) {
      e.writeln('配置文件解析失败: ${x.message}');
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
      e.writeln('${x.describe()}\n还原前先停掉 serve。');
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
          }),
        );
      } else {
        o.writeln('已还原（备份时间 ${r.manifest.createdAt.toLocal()}）。');
        if (r.previousData != null) {
          o.writeln('原数据保留在 ${r.previousData!.path}，确认无误后可删除。');
        }
        if (r.previousConfig != null) {
          o.writeln('原配置保留在 ${r.previousConfig!.path}。');
        }
        if (!r.manifest.includesDocuments) {
          o.writeln('这份备份不含 documents/：书 / 封面 / 下载需重新扫描或下载。');
        }
      }
      return kExitOk;
    } on ServerBackupException catch (x) {
      e.writeln('还原失败: ${x.message}');
      return kExitDataError;
    } finally {
      await lock.release();
    }
  }
}
