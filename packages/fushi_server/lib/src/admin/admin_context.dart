/// admin API 看到的服务端全貌（一个对象，路由不再各自持有一堆引用）。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';

class AdminContext {
  AdminContext({
    required ServerConfig config,
    required this.configFile,
    required this.paths,
    required this.log,
    required this.db,
    required this.identity,
    required this.host,
    required this.startedAt,
  }) : _config = config;

  ServerConfig _config;
  final File configFile;
  final ServerPaths paths;
  final ServerLog log;
  final FushiDatabase db;
  final ServerIdentity identity;
  final HeadlessHost host;
  final DateTime startedAt;

  ServerConfig get config => _config;

  /// 改配置 = 改内存 + 写回文件 + 推给正在跑的 host。端口/TLS/绑定这类要重启才
  /// 生效，WebUI 会提示；公网地址 / P2P / 中继由 [HeadlessHost.applyConfig] 即时
  /// 生效（返回时 P2P 起停已落地）。
  Future<void> updateConfig(ServerConfig next) async {
    _config = next;
    await next.save(configFile);
    await host.applyConfig(next);
  }

  // ── 扫描：同一时刻只跑一次 ────────────────────────────────────────
  Future<ScanSummary>? _scanInFlight;
  ScanSummary? lastScan;
  DateTime? lastScanAt;

  bool get scanning => _scanInFlight != null;

  Future<ScanSummary> scanLibraries({bool? prune}) {
    final Future<ScanSummary>? running = _scanInFlight;
    if (running != null) return running;
    final Future<ScanSummary> f = LibraryScanner(
      db: db,
      subtitleLanguage: config.subtitleLanguage,
      // 缺省读配置里的 `scan_prune`（默认开）；请求里显式给了就按请求。
      pruneMissing: prune ?? config.scanPrune,
    ).scanAll(config.libraries).then((ScanSummary s) {
      lastScan = s;
      lastScanAt = DateTime.now();
      return s;
    }).whenComplete(() => _scanInFlight = null);
    _scanInFlight = f;
    return f;
  }
}
