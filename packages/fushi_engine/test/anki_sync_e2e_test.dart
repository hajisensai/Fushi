import 'dart:io';

import 'package:fushi_engine/anki_sync/anki_sync_journal.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 端到端：正式代码（[AnkiSyncSession] + 真实 `fushi-anki-sync`）对一台真实的官方
/// Anki 同步服务器。设了两个环境变量才跑：
/// - `FUSHI_ANKI_SYNC_BIN`：helper 路径
/// - `FUSHI_ANKI_SYNC_E2E_ENDPOINT`：服务器根地址（账号 u / 密码 p，空库起步）
///
/// 起服务器：`SYNC_USER1=u:p SYNC_BASE=<空目录> SYNC_PORT=27745 anki-sync-server`
/// （anki 仓库 `cargo build --release --bin anki-sync-server`）。
void main() {
  final String? bin = Platform.environment['FUSHI_ANKI_SYNC_BIN'];
  final String? endpoint = Platform.environment['FUSHI_ANKI_SYNC_E2E_ENDPOINT'];
  final String? skip = bin == null || endpoint == null
      ? 'FUSHI_ANKI_SYNC_BIN / FUSHI_ANKI_SYNC_E2E_ENDPOINT 未设置'
      : null;

  test(
    '设备 A 登录 → 下载 → 加卡（带媒体）→ 同步；设备 B 从零登录拉到同一张卡与媒体',
    () async {
      final Directory work = Directory.systemTemp.createTempSync('anki_e2e_');
      AnkiSyncSession device(String name) => AnkiSyncSession(
        root: () async => Directory(p.join(work.path, name)),
        startClient: () => FushiAnkiSyncClient.start(bin!),
        syncDelay: const Duration(days: 1),
      );
      final AnkiSyncSession a = device('a');
      final AnkiSyncSession b = device('b');
      try {
        final File audio = File(p.join(work.path, 'fushi_audio_e2e.mp3'))
          ..writeAsBytesSync(List<int>.generate(64, (int i) => i));

        await a.signIn(endpoint: endpoint, username: 'u', password: 'p');
        final AnkiSyncMeta meta = await a.meta();
        expect(
          meta.notetypes.map((AnkiSyncNotetype n) => n.name),
          contains('Basic'),
        );
        final String word = '猫${DateTime.now().microsecondsSinceEpoch}';
        await a.addNote(
          AnkiSyncNote(
            notetype: 'Basic',
            deck: 'Fushi::Mining',
            fields: <String>[word, '[sound:fushi_audio_e2e.mp3]'],
            tags: const <String>['fushi'],
            media: <(String, String)>[('fushi_audio_e2e.mp3', audio.path)],
          ),
        );
        audio.deleteSync(); // 同步时只能从日志目录 / 本地库读媒体
        expect(a.state.unsynced, 1);

        final AnkiSyncState synced = await a.syncNow();
        expect(synced.phase, AnkiSyncPhase.idle, reason: synced.message);
        expect(synced.unsynced, 0, reason: '同步成功才出日志');

        await b.signIn(endpoint: endpoint, username: 'u', password: 'p');
        final List<AnkiSyncNoteHit> hits = await b.findNotes(
          notetype: 'Basic',
          firstField: word,
        );
        expect(hits, hasLength(1), reason: 'B 从服务器拉到了 A 的卡');
        expect((await b.meta()).decks, contains('Fushi::Mining'));
        final AnkiSyncState bSynced = await b.syncNow();
        expect(bSynced.phase, AnkiSyncPhase.idle, reason: bSynced.message);
        expect(
          File(
            p.join(
              work.path,
              'b',
              'collection',
              'collection.media',
              'fushi_audio_e2e.mp3',
            ),
          ).existsSync(),
          isTrue,
          reason: '媒体经服务器同步到了 B',
        );
      } finally {
        await a.close();
        await b.close();
        work.deleteSync(recursive: true);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
