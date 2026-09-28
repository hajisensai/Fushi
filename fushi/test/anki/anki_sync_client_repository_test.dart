import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/sync_client/anki_sync_client_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假 helper：只记录收到的加卡请求，库内容 = [local]。
class _FakeHelper implements FushiAnkiSyncClient {
  @override
  bool isDead = false;

  @override
  Future<Set<int>> existingNotes(List<(int, String)> notes) async => <int>{
    for (final (int id, String guid) in notes)
      if (id >= 1 && id <= local.length && guid == 'g$id') id,
  };

  final List<List<String>> local = <List<String>>[];
  final List<
    ({
      String notetype,
      String deck,
      List<String> fields,
      List<String> tags,
      List<(String, String)> media,
    })
  >
  added = [];

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
      AnkiSyncNotetype(
        name: 'Vocab',
        fields: <String>['Expression', 'Meaning'],
      ),
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
  }) async => <AnkiSyncNoteHit>[
    for (int i = local.length - 1; i >= 0; i--)
      if (local[i].first == firstField)
        AnkiSyncNoteHit(noteId: i + 1, preview: firstField),
  ];

  @override
  Future<(int, String)> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async {
    added.add((
      notetype: notetype,
      deck: deck,
      fields: fields,
      tags: tags,
      media: media,
    ));
    local.add(fields);
    return (local.length, 'g${local.length}');
  }

  @override
  Future<AnkiSyncResult> sync({required String hkey, String? endpoint}) async =>
      const AnkiSyncResult(status: AnkiSyncStatus.ok);

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeHelper helper;
  late AnkiSyncSession session;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('anki_sync_repo_');
    helper = _FakeHelper();
    session = AnkiSyncSession(
      root: () async => root,
      startClient: () async => helper,
      syncDelay: const Duration(days: 1),
    );
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'p');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await session.close();
    root.deleteSync(recursive: true);
  });

  Future<AnkiSyncClientRepository> configured() async {
    final AnkiSyncClientRepository repo = AnkiSyncClientRepository(
      session: session,
    );
    await repo.updateSettings(
      (AnkiSettings s) => s.copyWith(
        fieldMappings: const <String, String>{
          'Expression': '{expression}',
          'Meaning': '{glossary}',
        },
        tags: 'mine',
      ),
    );
    expect(await repo.fetchConfiguration(), isA<AnkiFetchSuccess>());
    return repo;
  }

  test('刷新：牌组 / 笔记类型来自同步下来的库，id 由名字派生、稳定', () async {
    final AnkiSyncClientRepository repo = await configured();
    final AnkiSettings s = await repo.loadSettings();
    expect(s.availableDecks.map((AnkiDeck d) => d.name), <String>[
      'Default',
      'Mining',
    ]);
    expect(
      s.availableDecks.last.id,
      AnkiSyncClientRepository.stableIdFor('Mining'),
    );
    expect(s.selectedDeckName, 'Mining', reason: '不默认选 Default');
    expect(s.selectedNoteTypeName, 'Vocab');
  });

  test('制卡：按字段映射渲染、按笔记类型字段顺序排好、带标签，写进本地库', () async {
    final AnkiSyncClientRepository repo = await configured();
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(<String, String>{
        'expression': '猫',
        'glossary': 'cat',
      }),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(
      outcome.result,
      MineResult.success,
      reason: '${outcome.errorDetail}',
    );
    expect(outcome.deckName, 'Mining');
    expect(helper.added.single.notetype, 'Vocab');
    expect(helper.added.single.deck, 'Mining');
    expect(helper.added.single.fields.first, '猫');
    expect(helper.added.single.fields.last, contains('cat'));
    expect(helper.added.single.tags, contains('mine'));
    expect(session.state.unsynced, 1, reason: '同步前卡留在日志里');
  });

  test('重复：库里已有就不加，回 duplicate', () async {
    final AnkiSyncClientRepository repo = await configured();
    helper.local.add(<String>['猫', 'x']);
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(<String, String>{'expression': '猫'}),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(outcome.result, MineResult.duplicate);
    expect(helper.added, isEmpty);
    expect(await repo.isDuplicate('猫', ''), isTrue);
    expect((await repo.findMatchingNotes('猫', '')).single.noteId, 1);
  });

  test('没登录：制卡报稳定错误码，不抛', () async {
    final AnkiSyncClientRepository repo = await configured();
    await session.signOut();
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: jsonEncode(<String, String>{'expression': '猫'}),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(outcome.result, MineResult.error);
    expect(outcome.errorCode, AnkiErrorCode.syncClientSignedOut);
  });

  test('本机没有 helper：制卡与刷新都报 syncClientUnavailable', () async {
    final AnkiSyncClientRepository repo = AnkiSyncClientRepository(
      session: null,
    );
    final AnkiFetchResult fetch = await repo.fetchConfiguration();
    expect(fetch, isA<AnkiFetchError>());
    expect((fetch as AnkiFetchError).code, AnkiErrorCode.syncClientUnavailable);
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: '{}',
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(outcome.errorCode, AnkiErrorCode.syncClientUnavailable);
  });
}
