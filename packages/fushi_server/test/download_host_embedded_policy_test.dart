// BUG-5071 回归：无头服务端的内置 libtorrent 引擎必须真的执行上传 / 做种策略，
// 且 `torrent:` 段的会话设置要铺到会话、改了保存即生效 —— **不需要 native 库**。
//
// 事故本体（线上 develop 2026-11-19 构建）：服务端只在起引擎时下发一次会话级设置，
// 从不 setUploadPolicy、也没有维护 tick —— unchoke 槽位停在 libtorrent 默认值、
// 已完成的种子从不按「关上传」暂停，默认 uploadEnabled=false 时实测仍上传
// 15～18 MB/s；同时活跃名额停在 libtorrent 默认 3，其余未完成种子被队列挂成
// pausedDL、0 连接。
//
// 这里给 [ServerDownloadHost] 注入工作 isolate 里的宿主工厂（顶层函数），用
// `Pointer.fromFunction` 伪造 C ABI（与 fushi/test/media/torrent/
// embedded_torrent_worker_test 同范式）。工作 isolate 的内存主 isolate 读不到，
// 调用记录落盘到 resume 目录下的 calls.log。

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_worker.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/config/server_torrent_session_config.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:fushi_torrent/fushi_torrent.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── 以下全局状态都活在**工作 isolate**里。──────────────────────────────────

final Pointer<Void> _fakeSession = Pointer<Void>.fromAddress(0xF00D);

const String _seedId = 'aa11';
const String _downloadingId = 'bb22';

/// 一个已完成在做种、一个还在下载。
const String _torrentsJson =
    '[{"id":"$_seedId","name":"done","progress":1.0,"state":"seeding",'
    '"save_path":"/tmp/content","content_path":"","total":100,"done":100,'
    '"left":0,"down_rate":0,"up_rate":5000,"uploaded":300,"downloaded":100,'
    '"num_peers":3,"has_metadata":true,"is_finished":true,"is_seeding":true,'
    '"sequential":false},'
    '{"id":"$_downloadingId","name":"ep02","progress":0.5,'
    '"state":"downloading","save_path":"/tmp/content","content_path":"",'
    '"total":100,"done":50,"left":50,"down_rate":0,"up_rate":0,"uploaded":0,'
    '"downloaded":50,"num_peers":0,"has_metadata":true,"is_finished":false,'
    '"is_seeding":false,"sequential":false}]';

String? _callLog;

void _record(String call) {
  final String? path = _callLog;
  if (path == null) return;
  File(path).writeAsStringSync('$call\n', mode: FileMode.append, flush: true);
}

Pointer<Void> _sessionCreate(Pointer<Char> listen, int enableDht) =>
    _fakeSession;

void _sessionDestroy(Pointer<Void> session) {}

Pointer<Char> _listTorrents(Pointer<Void> session) =>
    _torrentsJson.toNativeUtf8().cast<Char>();

void _freeString(Pointer<Char> s) {
  if (s != nullptr) malloc.free(s);
}

int _setUploadMode(Pointer<Void> session, Pointer<Char> infoHash, int on) => 1;

int _setUnchokeSlots(Pointer<Void> session, int slots) {
  _record('unchoke($slots)');
  return 1;
}

int _pauseTorrent(Pointer<Void> session, Pointer<Char> infoHash, int pause) {
  _record('pause(${infoHash.cast<Utf8>().toDartString()},$pause)');
  return 1;
}

int _applyLimits(Pointer<Void> session, int down, int up, int connections) {
  _record('limits($down,$up,$connections)');
  return 1;
}

int _applyMemory(Pointer<Void> s, int connections, int disk, int send, int pl) {
  _record('memory($connections)');
  return 1;
}

int _applySession(
  Pointer<Void> session,
  int port,
  int dht,
  int lsd,
  int upnp,
  int natpmp,
  int enc,
  int anonymous,
  int activeDownloads,
  int activeSeeds,
  int uploadSlots,
) {
  _record('session($activeDownloads,$activeSeeds,$uploadSlots)');
  return 1;
}

Pointer<Char> _saveResumeData(
  Pointer<Void> session,
  Pointer<Char> dir,
  int timeoutMs,
) => '{"ok":true,"saved":0,"failed":0}'.toNativeUtf8().cast<Char>();

FushiTorrentBindings _bindings() {
  Pointer<T> lookup<T extends NativeType>(String symbol) {
    switch (symbol) {
      case 'ht_session_create':
        return Pointer.fromFunction<Pointer<Void> Function(Pointer<Char>, Int)>(
          _sessionCreate,
        ).cast<T>();
      case 'ht_session_destroy':
        return Pointer.fromFunction<Void Function(Pointer<Void>)>(
          _sessionDestroy,
        ).cast<T>();
      case 'ht_list_torrents':
        return Pointer.fromFunction<Pointer<Char> Function(Pointer<Void>)>(
          _listTorrents,
        ).cast<T>();
      case 'ht_free_string':
        return Pointer.fromFunction<Void Function(Pointer<Char>)>(
          _freeString,
        ).cast<T>();
      case 'ht_set_upload_mode':
        return Pointer.fromFunction<
              Int Function(Pointer<Void>, Pointer<Char>, Int)
            >(_setUploadMode, 0)
            .cast<T>();
      case 'ht_set_unchoke_slots':
        return Pointer.fromFunction<Int Function(Pointer<Void>, Int)>(
          _setUnchokeSlots,
          0,
        ).cast<T>();
      case 'ht_pause_torrent':
        return Pointer.fromFunction<
              Int Function(Pointer<Void>, Pointer<Char>, Int)
            >(_pauseTorrent, 0)
            .cast<T>();
      case 'ht_apply_limits':
        return Pointer.fromFunction<Int Function(Pointer<Void>, Int, Int, Int)>(
          _applyLimits,
          0,
        ).cast<T>();
      case 'ht_apply_memory_settings':
        return Pointer.fromFunction<
              Int Function(Pointer<Void>, Int, Int, Int, Int)
            >(_applyMemory, 0)
            .cast<T>();
      case 'ht_apply_session_settings':
        return Pointer.fromFunction<
              Int Function(
                Pointer<Void>,
                Int,
                Int,
                Int,
                Int,
                Int,
                Int,
                Int,
                Int,
                Int,
                Int,
              )
            >(_applySession, 0)
            .cast<T>();
      case 'ht_save_resume_data':
        return Pointer.fromFunction<
              Pointer<Char> Function(Pointer<Void>, Pointer<Char>, Int)
            >(_saveResumeData)
            .cast<T>();
    }
    throw ArgumentError("Failed to lookup symbol '$symbol'");
  }

  return FushiTorrentBindings.fromLookup(lookup);
}

/// 工厂（顶层函数，送进工作 isolate 执行）。
EmbeddedTorrentHost? _fakeHostFactory(EmbeddedTorrentHostOpenArgs args) {
  _callLog = p.join(args.resumeDir, 'calls.log');
  final EmbeddedTorrentEngine engine = EmbeddedTorrentEngine.fromBindings(
    _bindings(),
  );
  return EmbeddedTorrentHost.forTesting(
    engine: engine,
    session: EmbeddedTorrentSession.open(engine)!,
    baseSavePath: args.baseSavePath,
    resumeDir: args.resumeDir,
    clockMs: () => 1000,
  );
}

// ── 主 isolate 侧 ───────────────────────────────────────────────────────

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPaths paths;
  late ServerTorrentSessionConfig session;
  late ServerDownloadHost host;

  File callLog() => File(p.join(paths.torrentResume.path, 'calls.log'));

  List<String> calls() =>
      callLog().existsSync() ? callLog().readAsLinesSync() : const <String>[];

  Future<void> waitForCall(bool Function(List<String> calls) done) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (done(calls())) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('expected native call never arrived; got ${calls()}');
  }

  Future<ServerDownloadHost> build() async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    );
    paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerDownloadHost built = ServerDownloadHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: await ServerIdentity.loadOrCreate(prefs),
      scrape: ServerVideoScrape(
        db: db,
        prefs: prefs,
        config: () => config,
        ledger: VideoScrapeSweepLedger(),
        coordinatorFactory: (scrapeConfig) => VideoSourceScrapeCoordinator(
          database: db,
          config: scrapeConfig,
          registry: VideoMetadataProviderRegistry(
            const <VideoMetadataProvider>[],
          ),
        ),
      ),
      pollInterval: const Duration(milliseconds: 50),
      maintenanceInterval: const Duration(milliseconds: 50),
      subtitleRegistryFactory: () =>
          VideoSubtitleRegistry(const <VideoSubtitleProvider>[]),
      torrentSession: () => session,
      embeddedEngineProbe: () => true,
      embeddedHostFactory: _fakeHostFactory,
    );
    await built.start();
    return built;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_dl_policy_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    session = const ServerTorrentSessionConfig();
  });

  tearDown(() async {
    await host.stop();
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // best-effort（Windows 上工作 isolate 刚关时文件可能还被占着）
    }
  });

  test('默认关上传：起引擎即会话级 unchoke 清零，维护 tick 暂停已完成种子、不碰下载中的', () async {
    host = await build();
    expect(host.resolvedBackend, ServerConfig.torrentEngineEmbedded);
    // 远程引擎路由第一次用到后端时懒建 session。
    expect(await host.withPeerBackend((TorrentBackend b) async => true), true);

    await waitForCall((List<String> c) => c.contains('unchoke(0)'));
    await waitForCall((List<String> c) => c.contains('pause($_seedId,1)'));
    expect(
      calls(),
      isNot(contains('pause($_downloadingId,1)')),
      reason: '下载中的种子绝不 pause（那会掐死下载）',
    );
    // 服务端默认不限同时下载数：未完成种子不会被队列挂起。
    expect(
      calls(),
      contains('session(${0x7fffffff},0,0)'),
      reason: 'max_active_downloads 默认 -1 → int32 最大值下发',
    );
    // 限速默认不限；内存预算的连接数照常下发。
    expect(calls(), contains('limits(0,0,0)'));
    expect(calls().any((String c) => c.startsWith('memory(')), isTrue);
  });

  test('会话设置改了 → applyTorrentSessionSettings 立即重铺：限速 / 上传开关 / 名额', () async {
    host = await build();
    await host.withPeerBackend((TorrentBackend b) async => true);
    await waitForCall((List<String> c) => c.contains('unchoke(0)'));

    session = const ServerTorrentSessionConfig(
      uploadEnabled: true,
      uploadLimitKbps: 100,
      downloadLimitKbps: 2000,
      maxActiveDownloads: 8,
      maxActiveSeeds: 4,
    );
    expect(host.applyTorrentSessionSettings(), isTrue);

    await waitForCall(
      (List<String> c) => c.contains('limits(${2000 * 1024},${100 * 1024},0)'),
    );
    // 开上传：会话级 unchoke 还原成 libtorrent 默认（-1），已完成种子恢复做种。
    await waitForCall((List<String> c) => c.contains('unchoke(-1)'));
    await waitForCall((List<String> c) => c.contains('pause($_seedId,0)'));
    expect(calls(), contains('session(8,4,0)'));
  });

  test('_qbConfig 映射：torrent 段的会话设置逐项进下发给引擎的配置', () async {
    session = const ServerTorrentSessionConfig(
      uploadEnabled: true,
      uploadLimitKbps: 100,
      downloadLimitKbps: 300,
      limitLocalPeers: true,
      maxActiveDownloads: 6,
      maxActiveSeeds: -1,
      maxConnections: 120,
      seedRatioLimit: 1.5,
      seedTimeLimitMinutes: 90,
    );
    host = await build();
    final QbConnectionConfig c = host.torrentBackendConfig;
    expect(c.backend, 'embedded');
    expect(c.uploadEnabled, isTrue);
    expect(c.uploadLimitKbps, 100);
    expect(c.downloadLimitKbps, 300);
    expect(c.limitLocalPeers, isTrue);
    expect(c.maxActiveDownloads, 6);
    expect(c.maxActiveSeeds, -1);
    expect(c.maxConnections, 120);
    expect(c.seedRatioLimit, 1.5);
    expect(c.seedTimeLimitMinutes, 90);
    // 引擎没起时只换配置，不为它拉起 session。
    expect(host.applyTorrentSessionSettings(), isFalse);
    expect(host.embeddedEngineActive, isFalse);
  });
}
