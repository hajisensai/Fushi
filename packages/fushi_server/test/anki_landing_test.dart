import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:fushi_engine/anki_sync/pending_mine_relay.dart';
import 'package:fushi_server/src/anki_landing.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 内存里的 helper：本地库 = [local]，服务器 = [server]。
class _FakeHelper implements FushiAnkiSyncClient {
  @override
  bool isDead = false;

  @override
  Future<Set<int>> existingNotes(List<(int, String)> notes) async => <int>{
    for (final (int id, String first) in notes)
      if (id >= 1 && id <= local.length && local[id - 1].first == first) id,
  };

  final List<List<String>> local = <List<String>>[];
  final List<List<String>> server = <List<String>>[];

  @override
  Future<String> login({
    String? endpoint,
    required String username,
    required String password,
  }) async => 'hkey';

  @override
  Future<bool> open(String path) async => true;

  @override
  Future<void> fullDownload({required String hkey, String? endpoint}) async {}

  @override
  Future<AnkiSyncMeta> listMeta() async => const AnkiSyncMeta(
    decks: <String>['Default', 'Mining'],
    notetypes: <AnkiSyncNotetype>[
      AnkiSyncNotetype(name: 'Vocab', fields: <String>['Word', 'Meaning']),
    ],
  );

  @override
  Future<bool> isDuplicate({
    required String notetype,
    required String firstField,
  }) async => local.any((List<String> f) => f.first == firstField);

  @override
  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) async => const <AnkiSyncNoteHit>[];

  @override
  Future<int> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async {
    local.add(fields);
    return local.length;
  }

  @override
  Future<AnkiSyncResult> sync({required String hkey, String? endpoint}) async {
    server
      ..clear()
      ..addAll(local);
    return const AnkiSyncResult(status: AnkiSyncStatus.ok);
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPrefs prefs;
  late _FakeHelper helper;
  late AnkiSyncSession session;
  late ServerAnkiLanding anki;
  int now = 1000;

  Directory ns() => Directory(
    p.join(
      tmp.path,
      'interconnect',
      'sync-data',
      'fushi-data',
      PendingMineRelay.namespace,
    ),
  );

  Set<String> files() => ns().existsSync()
      ? <String>{
          for (final FileSystemEntity e in ns().listSync()) p.basename(e.path),
        }
      : <String>{};

  /// 手机经互联 WebDAV 写进来的一张卡（与 PendingMineRelay 上传的记录同形）。
  void phoneUploads(String id, String word) {
    ns().createSync(recursive: true);
    File(p.join(ns().path, '$id.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'id': id,
        'createdAt': 1,
        'expression': word,
        'reading': '',
        'originDeviceId': 'phone',
        'payload': <String, Object?>{
          'rawPayloadJson': jsonEncode(<String, String>{
            'expression': word,
            'glossary': 'meaning of $word',
          }),
          'sentence': '',
        },
      }),
    );
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('server_anki_landing_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = ServerPrefs(db);
    await prefs.warmUp();
    helper = _FakeHelper();
    session = AnkiSyncSession(
      root: () async => Directory(p.join(tmp.path, 'support', 'anki_sync')),
      startClient: () async => helper,
      syncDelay: const Duration(milliseconds: 10),
    );
    anki = ServerAnkiLanding(
      prefs: prefs,
      db: db,
      support: Directory(p.join(tmp.path, 'support')),
      syncData: Directory(p.join(tmp.path, 'interconnect')),
      deviceId: 'srv',
      deviceName: 'NAS',
      session: session,
      clock: () => now,
    );
  });

  tearDown(() async {
    await anki.stop();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('落地没开：不认领、不收卡', () async {
    phoneUploads('a1', '猫');
    expect(await anki.runNow(), isNull);
    expect(files(), <String>{'a1.json'});
  });

  test('开落地 → 登录 → 配映射：卡落进 Anki、写回执、同步上去', () async {
    await anki.setLandingEnabled(true);
    await anki.runNow();
    expect(files(), contains('landing.srv.json'));

    phoneUploads('a1', '猫');
    // 还没登录、没配映射：卡留着等，不算失败。
    final waiting = await anki.runNow();
    expect(waiting!.received, 1);
    expect(waiting.waiting, 1);
    expect(waiting.failed, 0);
    expect(files(), isNot(contains('a1.landed.json')));

    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    expect(await anki.refreshMeta(), isTrue);
    expect(anki.settings.selectedDeckName, 'Mining');
    await anki.saveSettings(
      anki.settings.copyWith(
        fieldMappings: const <String, String>{
          'Word': '{expression}',
          'Meaning': '{glossary}',
        },
      ),
    );

    final done = await anki.runNow();
    expect(done!.delivered, 1);
    expect(helper.local.single.first, '猫');
    expect(helper.local.single.last, contains('meaning of 猫'));
    expect(files(), contains('a1.landed.json'));
    expect(files(), isNot(contains('a1.json')));

    // 加卡后会话自己排一次同步。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(helper.server.single.first, '猫');
    expect(session.state.unsynced, 0);
  });

  // 登录、刷新后牌组 / 笔记类型都有了，唯独字段映射空：卡渲染不出任何字段。
  // 这必须是「等配置」而不是「失败」——失败的卡要人工重试，等配置的卡配好就自动落。
  test('已登录但字段映射空：卡留着等，不标失败', () async {
    await anki.setLandingEnabled(true);
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    await anki.refreshMeta();
    expect(anki.settings.selectedNoteTypeName, 'Vocab');
    expect(anki.settings.fieldMappings, isEmpty);

    phoneUploads('a1', '猫');
    final r = await anki.runNow();
    expect(r!.waiting, 1);
    expect(r.failed, 0);
    expect(helper.local, isEmpty);
  });

  // 审查第 9 项：映射里只有旧笔记类型的字段名（换了笔记类型没清）——「映射全空」
  // 判断会被旧键骗过，卡被标成失败要手动重试。按所选笔记类型的字段判断。
  test('映射只有别的笔记类型的字段：同样按没配置处理，不标失败', () async {
    await anki.setLandingEnabled(true);
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    await anki.refreshMeta();
    await anki.saveSettings(
      anki.settings.copyWith(
        fieldMappings: const <String, String>{'Front': '{expression}'},
      ),
    );
    phoneUploads('a1', '猫');
    final r = await anki.runNow();
    expect(r!.waiting, 1);
    expect(r.failed, 0);
  });

  test('关落地：立刻撤认领', () async {
    await anki.setLandingEnabled(true);
    await anki.runNow();
    expect(files(), contains('landing.srv.json'));
    await anki.setLandingEnabled(false);
    expect(files(), isNot(contains('landing.srv.json')));
    expect(anki.landingEnabled, isFalse);
  });

  test('设置存在服务端偏好表里，重建实例后还在', () async {
    await anki.saveSettings(anki.settings.copyWith(tags: 'mine server'));
    final ServerPrefs again = ServerPrefs(db);
    await again.warmUp();
    final ServerAnkiLanding reloaded = ServerAnkiLanding(
      prefs: again,
      db: db,
      support: Directory(p.join(tmp.path, 'support')),
      syncData: Directory(p.join(tmp.path, 'interconnect')),
      deviceId: 'srv',
      deviceName: 'NAS',
      resolveHelper: false,
    );
    expect(reloaded.settings.tags, 'mine server');
    expect(reloaded.available, isFalse);
  });
}
