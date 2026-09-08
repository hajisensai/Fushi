/// `fushi_server` 命令行。
///
/// ```
/// fushi_server init   [--config fushi_server.yaml] [--data-dir data]
/// fushi_server serve  [--config …] [--no-scan] [--verbose]
/// fushi_server scan   [--config …]
/// fushi_server status [--config …]
/// fushi_server pair   ls | revoke <peerId>            [--config …]
/// fushi_server admin  reset-token                     [--config …]
/// fushi_server models pull|status --language ja        [--config …]
/// fushi_server transcribe <audio> --language ja [--out x.srt] [--config …]
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:asr_core/asr_core.dart' as asr;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;

const String kDefaultConfigFileName = 'fushi_server.yaml';

class _Runtime {
  _Runtime({
    required this.config,
    required this.configFile,
    required this.paths,
    required this.log,
    required this.db,
    required this.prefs,
    required this.identity,
  });

  final ServerConfig config;
  final File configFile;
  final ServerPaths paths;
  final ServerLog log;
  final FushiDatabase db;
  final ServerPrefs prefs;
  final ServerIdentity identity;

  Future<void> dispose() async {
    await db.close();
    await log.close();
  }
}

ArgParser _buildParser() {
  final ArgParser parser = ArgParser()
    ..addOption('config', abbr: 'c', help: '配置文件路径', defaultsTo: kDefaultConfigFileName)
    ..addFlag('verbose', abbr: 'v', negatable: false, help: '调试日志')
    ..addFlag('help', abbr: 'h', negatable: false);
  parser.addCommand('init')
    ..addOption('data-dir', help: '数据目录（默认配置文件旁的 data/）')
    ..addOption('port', help: '监听端口', defaultsTo: '${ServerConfig.defaultPort}')
    ..addOption('device-name', help: '广播给对端的设备名');
  parser
      .addCommand('serve')
      .addFlag('scan', help: '启动后扫描一次库', defaultsTo: true);
  parser.addCommand('scan');
  parser.addCommand('status');
  parser.addCommand('pair');
  parser.addCommand('admin');
  parser
      .addCommand('models')
      .addOption('language', abbr: 'l', help: 'ASR 语言 tag（ja / en / zh …）');
  parser.addCommand('transcribe')
    ..addOption('language', abbr: 'l', help: 'ASR 语言 tag', defaultsTo: 'ja')
    ..addOption('out', abbr: 'o', help: '输出 .srt 路径（默认与音频同名）')
    ..addFlag('cpu', negatable: false, help: '只用 CPU');
  return parser;
}

void _usage(ArgParser parser) {
  stdout.writeln('fushi_server <command> [options]\n');
  stdout.writeln('commands: init | serve | scan | status | pair ls|revoke <peerId> | '
      'admin reset-token | models pull|status -l <lang> | transcribe <audio> -l <lang>\n');
  stdout.writeln(parser.usage);
}

Future<int> runFushiServerCli(List<String> args) async {
  final ArgParser parser = _buildParser();
  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _usage(parser);
    return 64;
  }
  final ArgResults? command = results.command;
  if (results['help'] as bool || command == null) {
    _usage(parser);
    return command == null ? 64 : 0;
  }
  final File configFile = File(p.absolute(results['config'] as String));
  final bool verbose = results['verbose'] as bool;
  switch (command.name) {
    case 'init':
      return _init(configFile, command);
    case 'serve':
      return _withRuntime(configFile, verbose, (_Runtime rt) => _serve(rt, scan: command['scan'] as bool));
    case 'scan':
      return _withRuntime(configFile, verbose, _scan);
    case 'status':
      return _withRuntime(configFile, verbose, _status);
    case 'pair':
      return _withRuntime(configFile, verbose, (_Runtime rt) => _pair(rt, command.rest));
    case 'admin':
      return _withRuntime(configFile, verbose, (_Runtime rt) => _admin(rt, command.rest));
    case 'models':
      return _withRuntime(configFile, verbose, (_Runtime rt) => _models(rt, command));
    case 'transcribe':
      return _withRuntime(configFile, verbose, (_Runtime rt) => _transcribe(rt, command));
  }
  _usage(parser);
  return 64;
}

Future<int> _init(File configFile, ArgResults command) async {
  if (await configFile.exists()) {
    stderr.writeln('已存在: ${configFile.path}（不覆盖）');
    return 1;
  }
  final String dataDir = command['data-dir'] as String? ??
      p.join(configFile.parent.path, 'data');
  ServerConfig config = ServerConfig.defaults(dataDir: p.absolute(dataDir));
  config = config.copyWith(
    port: int.tryParse(command['port'] as String) ?? ServerConfig.defaultPort,
    deviceName: command['device-name'] as String? ?? config.deviceName,
    adminToken: FushiSyncServer.generateToken(),
  );
  await config.save(configFile);
  stdout.writeln('已写入 ${configFile.path}');
  stdout.writeln('data_dir: ${config.dataDir}');
  stdout.writeln('admin_token: ${config.adminToken}（WebUI / admin API 凭据，别泄露）');
  stdout.writeln('下一步：编辑 libraries[] 填扫描目录，然后 fushi_server serve');
  return 0;
}

Future<int> _withRuntime(
  File configFile,
  bool verbose,
  Future<int> Function(_Runtime rt) body,
) async {
  if (!await configFile.exists()) {
    stderr.writeln('找不到配置文件 ${configFile.path}；先跑 fushi_server init');
    return 66;
  }
  ServerConfig config;
  try {
    config = await ServerConfig.load(configFile);
  } on FormatException catch (e) {
    stderr.writeln('配置文件解析失败: ${e.message}');
    return 65;
  }
  if (config.adminToken == null) {
    config = config.copyWith(adminToken: FushiSyncServer.generateToken());
    await config.save(configFile);
  }
  final ServerPaths paths = ServerPaths(config.dataDir);
  await paths.ensureLayout();
  final ServerLog log = ServerLog(
    file: File(p.join(paths.logs.path, 'fushi_server.log')),
    verbose: verbose,
  );
  await log.open();
  installServerHostBindings(config: config, paths: paths, log: log);
  final String? ffmpegProblem = await validateFfmpeg(config);
  if (ffmpegProblem != null) log.info(ffmpegProblem);
  final FushiDatabase db = FushiDatabase(paths.support.path);
  final ServerPrefs prefs = ServerPrefs(db);
  await prefs.warmUp();
  final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
  final _Runtime rt = _Runtime(
    config: config,
    configFile: configFile,
    paths: paths,
    log: log,
    db: db,
    prefs: prefs,
    identity: identity,
  );
  try {
    return await body(rt);
  } finally {
    await rt.dispose();
  }
}

Future<int> _serve(_Runtime rt, {required bool scan}) async {
  final HeadlessHost host = HeadlessHost(
    config: rt.config,
    paths: rt.paths,
    db: rt.db,
    prefs: rt.prefs,
    identity: rt.identity,
  );
  try {
    await host.start();
  } on SyncServerPortInUseException catch (e) {
    stderr.writeln('端口被占用: $e');
    return 75;
  }
  stdout.writeln('fushi_server 已启动: ${rt.config.bind}:${host.port} '
      '${rt.config.tls ? '(https, fingerprint ${host.hostFingerprint})' : '(http)'}');
  stdout.writeln('设备名: ${rt.config.deviceName}   设备 id: ${rt.identity.deviceId}');
  stdout.writeln('配对：在 Fushi 里添加互联设备，输入本机地址；PIN 会打印在这里。');
  if (scan && rt.config.libraries.isNotEmpty) {
    unawaited(_scanInBackground(rt));
  }
  final Completer<void> stop = Completer<void>();
  void onSignal(ProcessSignal s) {
    if (!stop.isCompleted) stop.complete();
  }

  final StreamSubscription<ProcessSignal> sigint =
      ProcessSignal.sigint.watch().listen(onSignal);
  StreamSubscription<ProcessSignal>? sigterm;
  if (!Platform.isWindows) {
    sigterm = ProcessSignal.sigterm.watch().listen(onSignal);
  }
  await stop.future;
  stdout.writeln('正在停止…');
  await sigint.cancel();
  await sigterm?.cancel();
  await host.stop();
  return 0;
}

Future<void> _scanInBackground(_Runtime rt) async {
  try {
    final ScanSummary summary = await LibraryScanner(
      db: rt.db,
      subtitleLanguage: rt.config.subtitleLanguage,
    ).scanAll(rt.config.libraries);
    stdout.writeln('库扫描完成: $summary');
  } catch (e, stack) {
    rt.log.log('serve.scan', e, stack);
  }
}

Future<int> _scan(_Runtime rt) async {
  if (rt.config.libraries.isEmpty) {
    stderr.writeln('配置里没有 libraries[]，无事可扫。');
    return 0;
  }
  final ScanSummary summary = await LibraryScanner(
    db: rt.db,
    subtitleLanguage: rt.config.subtitleLanguage,
  ).scanAll(rt.config.libraries);
  stdout.writeln('库扫描完成: $summary');
  for (final String err in summary.errors) {
    stdout.writeln('  ! $err');
  }
  return summary.errors.isEmpty ? 0 : 1;
}

Future<int> _status(_Runtime rt) async {
  final List<FushiPairedPeerRow> peers = await rt.db.getPairedPeers();
  final int videos = (await rt.db.allVideoBooks()).length;
  stdout.writeln('config:      ${rt.configFile.path}');
  stdout.writeln('data_dir:    ${rt.config.dataDir}');
  stdout.writeln('listen:      ${rt.config.bind}:${rt.config.port} tls=${rt.config.tls}');
  stdout.writeln('device:      ${rt.config.deviceName} (${rt.identity.deviceId})');
  stdout.writeln('libraries:   ${rt.config.libraries.length}');
  stdout.writeln('videos:      $videos');
  stdout.writeln('paired:      ${peers.length}');
  return 0;
}

Future<int> _pair(_Runtime rt, List<String> rest) async {
  final String sub = rest.isEmpty ? 'ls' : rest.first;
  switch (sub) {
    case 'ls':
      final List<FushiPairedPeerRow> peers = await rt.db.getPairedPeers();
      if (peers.isEmpty) {
        stdout.writeln('（尚无已配对设备）');
        return 0;
      }
      for (final FushiPairedPeerRow peer in peers) {
        final String at =
            DateTime.fromMillisecondsSinceEpoch(peer.pairedAtMs).toIso8601String();
        stdout.writeln('${peer.peerId}  ${peer.deviceName ?? '-'}  '
            '${peer.lastSeenIp ?? '-'}  paired $at');
      }
      return 0;
    case 'revoke':
      if (rest.length < 2) {
        stderr.writeln('用法: pair revoke <peerId>');
        return 64;
      }
      final int n = await rt.db.revokePairedPeer(rest[1]);
      stdout.writeln(n == 0 ? '没有这个对端' : '已吊销 ${rest[1]}');
      return n == 0 ? 1 : 0;
    default:
      stderr.writeln('用法: pair ls | pair revoke <peerId>');
      return 64;
  }
}

Future<int> _admin(_Runtime rt, List<String> rest) async {
  final String sub = rest.isEmpty ? '' : rest.first;
  switch (sub) {
    case 'reset-token':
      final ServerConfig next =
          rt.config.copyWith(adminToken: FushiSyncServer.generateToken());
      await next.save(rt.configFile);
      stdout.writeln('新的 admin_token: ${next.adminToken}');
      return 0;
    default:
      stderr.writeln('用法: admin reset-token');
      return 64;
  }
}

asr.AsrLanguage? _languageArg(ArgResults command) {
  final String? tag = command['language'] as String?;
  final asr.AsrLanguage? language = asr.AsrLanguage.fromTag(tag);
  if (language == null) {
    stderr.writeln('未知语言 "$tag"；可用: '
        '${asr.AsrLanguage.registered.map((asr.AsrLanguage l) => l.tag).join(', ')}');
  }
  return language;
}

Future<int> _models(_Runtime rt, ArgResults command) async {
  final String sub = command.rest.isEmpty ? 'status' : command.rest.first;
  final asr.AsrTranscriptionService service = createServerAsrTranscriptionService();
  if (sub == 'status') {
    for (final asr.AsrLanguage language in asr.AsrLanguage.registered) {
      final asr.AsrTranscribePlan plan = await service.plan(
        language: language,
        preference: asr.AsrAccelerationPreference.auto,
      );
      stdout.writeln('${language.tag.padRight(4)} ${plan.modelReady ? 'ready  ' : 'missing'} '
          '${plan.variant.name} ${plan.expectedProvider.name} '
          '${plan.modelStatus.obtainedBytes}/${plan.modelStatus.totalBytes} bytes');
    }
    return 0;
  }
  if (sub == 'pull') {
    final asr.AsrLanguage? language = _languageArg(command);
    if (language == null) return 64;
    final asr.AsrTranscribePlan plan = await service.plan(
      language: language,
      preference: asr.AsrAccelerationPreference.auto,
    );
    if (plan.modelReady) {
      stdout.writeln('${language.tag}: 模型已就绪');
      return 0;
    }
    String last = '';
    await for (final asr.ModelDownloadEvent e
        in service.downloadModel(language: language, variant: plan.variant)) {
      final String line = '${e.fileName} ${e.receivedBytes}/${e.totalBytes}${e.done ? ' done' : ''}';
      if (line != last) {
        stdout.writeln(line);
        last = line;
      }
    }
    stdout.writeln('${language.tag}: 下载完成');
    return 0;
  }
  stderr.writeln('用法: models status | models pull --language <tag>');
  return 64;
}

/// 离线直转：不经 HTTP，方便脚本与排障（与 `/api/jobs` 的 asr runner 同一条链路）。
Future<int> _transcribe(_Runtime rt, ArgResults command) async {
  if (command.rest.isEmpty) {
    stderr.writeln('用法: transcribe <audio> --language <tag> [--out x.srt]');
    return 64;
  }
  final String audio = p.absolute(command.rest.first);
  if (!await File(audio).exists()) {
    stderr.writeln('找不到文件: $audio');
    return 66;
  }
  final asr.AsrLanguage? language = _languageArg(command);
  if (language == null) return 64;
  final asr.AsrAccelerationPreference preference = command['cpu'] as bool
      ? asr.AsrAccelerationPreference.cpuOnly
      : asr.AsrAccelerationPreference.auto;
  final asr.AsrTranscriptionService service = createServerAsrTranscriptionService();
  final asr.AsrTranscribePlan plan =
      await service.plan(language: language, preference: preference);
  if (!plan.modelReady) {
    stderr.writeln('${language.tag} 模型未下载：先跑 fushi_server models pull -l ${language.tag}');
    return 69;
  }
  final asr.AsrRunningTranscription running = await service.start(
    audioPaths: <String>[audio],
    language: language,
    variant: plan.variant,
    preference: preference,
  );
  asr.AsrTranscribeResult? result;
  try {
    await for (final asr.AsrTranscribeEvent e in running.run()) {
      switch (e) {
        case asr.AsrTranscribeProgressEvent(progress: final asr.AsrTranscribeProgress pr):
          final double? f = pr.fraction;
          if (f != null) stderr.write('\r${(f * 100).toStringAsFixed(1)}%   ');
        case asr.AsrTranscribePausedEvent():
          break;
        case asr.AsrTranscribeFinishedEvent(result: final asr.AsrTranscribeResult r):
          result = r;
      }
    }
  } finally {
    await running.dispose();
  }
  stderr.writeln();
  if (result == null) {
    stderr.writeln('转录未产生结果');
    return 1;
  }
  final String out = command['out'] as String? ?? p.setExtension(audio, '.srt');
  await File(result.srtPath).copy(out);
  final File tokens = File(p.join(p.dirname(result.srtPath), asr.AsrJobFiles.cueTokens));
  if (await tokens.exists()) {
    await tokens.copy(p.setExtension(out, '.tokens.jsonl'));
  }
  stdout.writeln('已写入 $out（${result.cueCount} 条字幕）');
  return 0;
}
