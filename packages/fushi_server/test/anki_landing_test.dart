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
    for (final (int id, String guid) in notes)
      if (id >= 1 && id <= local.length && guid == 'g$id') id,
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
  Future<(int, String)> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async {
    local.add(fields);
    return (local.length, 'g${local.length}');
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

  // 登录、刷新后牌组 / 笔记类型都有了，用户从没配过字段映射。cd732f10c7 起
  // `AnkiSettings.fromJson` 对「一个字段都没映射到所选笔记类型」的设置按字段名套默认
  // 映射（首字段必为 `{expression}`，见 note_type_default_mappings.dart；反馈
  // AGLC0BuaKB：空映射让每张卡都是空卡被拒收）。所以这里不再「等配置」，卡直接按默认
  // 映射落进 Anki；「等配置」只剩笔记类型还不知道（没登录 / 没刷新）这一种，见上一条。
  test('已登录但从没配过字段映射：按字段名套默认映射，卡直接落进 Anki', () async {
    await anki.setLandingEnabled(true);
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    await anki.refreshMeta();
    expect(anki.settings.selectedNoteTypeName, 'Vocab');
    expect(anki.settings.fieldMappings, const <String, String>{
      'Word': '{expression}',
      'Meaning': '{glossary}',
    });

    phoneUploads('a1', '猫');
    final r = await anki.runNow();
    expect(r!.delivered, 1);
    expect(r.waiting, 0);
    expect(r.failed, 0);
    expect(helper.local.single.first, '猫');
    expect(helper.local.single.last, contains('meaning of 猫'));
    expect(files(), contains('a1.landed.json'));
  });

  // 审查第 9 项：映射里只有旧笔记类型的字段名（换了笔记类型没清）——「映射全空」
  // 判断会被旧键骗过。按所选笔记类型的字段判断：一个都没覆盖到 = 没配过，同样套
  // 默认映射落卡，不会渲染出空卡被标失败。
  test('映射只有别的笔记类型的字段：按所选笔记类型套默认映射，照常落卡', () async {
    await anki.setLandingEnabled(true);
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    await anki.refreshMeta();
    await anki.saveSettings(
      anki.settings.copyWith(
        fieldMappings: const <String, String>{'Front': '{expression}'},
      ),
    );
    expect(anki.settings.fieldMappings, const <String, String>{
      'Word': '{expression}',
      'Meaning': '{glossary}',
    });
    phoneUploads('a1', '猫');
    final r = await anki.runNow();
    expect(r!.delivered, 1);
    expect(r.failed, 0);
    expect(helper.local.single.first, '猫');
    expect(helper.local.single.last, contains('meaning of 猫'));
  });

  // 用户自己配过（覆盖到所选笔记类型的字段）就原样尊重，不被默认映射盖掉。
  test('自己配过的映射不被默认映射覆盖', () async {
    await anki.setLandingEnabled(true);
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    await anki.refreshMeta();
    await anki.saveSettings(
      anki.settings.copyWith(
        fieldMappings: const <String, String>{'Word': '{expression}'},
      ),
    );
    expect(anki.settings.fieldMappings, const <String, String>{
      'Word': '{expression}',
    });
    phoneUploads('a1', '猫');
    final r = await anki.runNow();
    expect(r!.delivered, 1);
    expect(helper.local.single.first, '猫');
    expect(helper.local.single.last, isEmpty, reason: '没映射的字段保持空');
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
