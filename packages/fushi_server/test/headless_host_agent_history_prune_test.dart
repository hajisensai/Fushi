import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/dictionary_host.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-4067：服务端当互联 host 时存远端 AI 助手会话；[HeadlessHost.start] 要接上
/// 保留期清理（管理页 / 手机上写的「保留 30 天」），否则 `ai_agent_sessions` 无限长。
void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_host_ai_prune_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> archived(String id, Duration age) =>
      db.saveAiAgentSessionSnapshot(
        id: id,
        title: id,
        scene: 'remote',
        payloadJson: '{"entries":[]}',
        totalTokens: 0,
        createdAt: 1,
        updatedAt: DateTime.now().subtract(age).millisecondsSinceEpoch,
        profileUid: '',
        originPeerId: 'phone',
      );

  test('服务端起来就清掉超过保留期的远端 AI 助手会话', () async {
    await archived('old', const Duration(days: 45));
    await archived('fresh', const Duration(days: 2));

    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(port: 0, bind: '127.0.0.1', tls: false);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
      dictionaryHost: ServerDictionaryHost(
        db: db,
        dictionaryResourceRoot: paths.dictionaryResources,
        libraryPath: p.join(tmp.path, 'missing', 'libfushidicts_ffi.so'),
        transformsDir: Directory(
          p.join('..', '..', 'fushi', 'assets', 'transforms'),
        ),
      ),
    );
    await host.start();
    addTearDown(host.stop);

    expect(
      <String>[
        for (final AiAgentSessionSummary s
            in await db.listAiAgentSessionSummaries())
          s.id,
      ],
      <String>['fresh'],
    );
  });
}
