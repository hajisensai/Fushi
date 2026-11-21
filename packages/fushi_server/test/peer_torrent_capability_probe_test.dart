import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/peer_torrent_engine.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `/api/pairing` 的 `torrentEngine` 能力位是任何已配对设备（手机也算）都会探的：
/// 回答它不得在本机拉起内置 BT 引擎。引擎没起时运行期能力位如实报「未知」。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerDownloadHost host;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_peer_probe_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    );
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final ServerPrefs prefs = ServerPrefs(db);
    host = ServerDownloadHost(
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
      // 钉住「内置引擎可用」：本机有没有 fushi_torrent_ffi 都走同一条路径。
      embeddedEngineProbe: () => true,
    );
    await host.start();
  });

  tearDown(() async {
    await host.stop();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('探测能力不拉起内置引擎', () async {
    final TorrentEngineCapability cap = await ServerPeerTorrentEngine(
      host,
    ).capability();
    expect(host.embeddedEngineActive, isFalse);
    expect(host.resolvedBackend, ServerConfig.torrentEngineEmbedded);
    expect(cap.supported, isTrue);
    expect(cap.features, kAllTorrentEngineFeatures);
    // 引擎没起：运行期能力位未知，而不是谎报 false 把对端的暂停 / 详情锁死。
    expect(cap.pauseControlAvailable, isNull);
    expect(cap.detailAvailable, isNull);
    final TorrentEngineCapability? wire = TorrentEngineCapability.fromJson(
      cap.toJson(),
    );
    expect(wire!.pauseControlAvailable, isNull);
  });
}
