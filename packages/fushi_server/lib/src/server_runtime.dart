/// 离线命令共用的运行时：配置 + 数据目录 + 数据库 + 宿主装配。
///
/// 从 `cli.dart` 抽出，供 `lib/src/commands/` 下各命令模块复用同一套前置
/// （宿主绑定只装一次、数据库开关成对）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;

class ServerRuntime {
  ServerRuntime({
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

/// 打开配置 / 数据目录 / 数据库 / 宿主装配，跑完 [body] 后统一释放。
///
/// 离线命令（`scan` / `status` / `import` …）的共同前置：找不到配置 → 66，
/// 配置解析失败 → 65；缺 admin_token 时补一个写回配置。
Future<int> withServerRuntime(File configFile, bool verbose, Future<int> Function(ServerRuntime rt) body) async {
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
  final ServerLog log = ServerLog(file: File(p.join(paths.logs.path, 'fushi_server.log')), verbose: verbose);
  await log.open();
  installServerHostBindings(config: config, paths: paths, log: log);
  // 与 app 侧 `AppModel.initialise()` 对偶：`createAppHttpClient()` 的 auto 模式
  // 要读这份缓存，不 prime 的话服务端只认 HTTP(S)_PROXY 环境变量，系统代理设置
  // 一律看不见（装在有桌面环境的 Linux / macOS 上就会莫名其妙地直连）。
  // 无头机器上解析不出系统代理是正常情况：`primeAppProxy` 约定失败即空 map、
  // 绝不抛，等价于此前的直连行为。
  await primeAppProxy();
  final String? ffmpegProblem = await validateFfmpeg(config);
  if (ffmpegProblem != null) log.info(ffmpegProblem);
  final FushiDatabase db = FushiDatabase(paths.support.path);
  final ServerPrefs prefs = ServerPrefs(db);
  await prefs.warmUp();
  final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
  final ServerRuntime rt = ServerRuntime(
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
