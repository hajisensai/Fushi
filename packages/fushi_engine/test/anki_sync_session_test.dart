import 'dart:io';

import 'package:fushi_engine/anki_sync/anki_sync_journal.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务器上的库。
class _Server {
  final List<String> notes = <String>[];

  /// 下一次 sync 服务器要求什么。
  String nextSync = 'normal'; // normal | fullDownload | blocked | fail
}

/// 内存里的 helper：本地库 = [local]，[pushed] 标记哪些已推上服务器。
class _FakeHelper implements FushiAnkiSyncClient {
  _FakeHelper(this.server);

  final _Server server;
  bool existingCollection = false;
  final List<String> local = <String>[];
  final Set<String> pushed = <String>{};
  final List<String> calls = <String>[];
  int _nextId = 1;

  @override
  Future<String> login({
    String? endpoint,
    required String username,
    required String password,
  }) async {
    calls.add('login');
    if (password != 'pw') throw const FushiAnkiSyncException('bad password');
    return 'hkey-$username';
  }

  @override
  Future<bool> open(String path) async {
    calls.add('open');
    final bool created = !existingCollection;
    existingCollection = true;
    return created;
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> fullDownload({required String hkey, String? endpoint}) async {
    calls.add('fullDownload');
    local
      ..clear()
      ..addAll(server.notes);
    pushed
      ..clear()
      ..addAll(server.notes);
  }

  @override
  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) async => <AnkiSyncNoteHit>[
    if (local.contains(firstField)) AnkiSyncNoteHit(noteId: 99, preview: ''),
  ];

  @override
  Future<bool> isDuplicate({
    required String notetype,
    required String firstField,
  }) async => local.contains(firstField);

  @override
  Future<int> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async {
    calls.add('add:${fields.first}');
    for (final (String _, String path) in media) {
      if (!File(path).existsSync()) {
        throw FushiAnkiSyncException('cannot read media file $path');
      }
    }
    local.add(fields.first);
    return _nextId++;
  }

  @override
  Future<AnkiSyncResult> sync({required String hkey, String? endpoint}) async {
    calls.add('sync');
    final String mode = server.nextSync;
    server.nextSync = 'normal';
    switch (mode) {
      case 'fail':
        throw const FushiAnkiSyncException('network down');
      case 'blocked':
        return const AnkiSyncResult(status: AnkiSyncStatus.fullSyncBlocked);
      case 'fullDownload':
        await fullDownload(hkey: hkey, endpoint: endpoint);
        return const AnkiSyncResult(
          status: AnkiSyncStatus.ok,
          fullDownload: true,
        );
    }
    for (final String n in local) {
      if (pushed.add(n)) server.notes.add(n);
    }
    return const AnkiSyncResult(status: AnkiSyncStatus.ok);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AnkiSyncNote _note(String word, {List<(String, String)> media = const []}) =>
    AnkiSyncNote(
      notetype: 'Basic',
      deck: 'Mining',
      fields: <String>[word, 'meaning'],
      media: media,
    );

void main() {
  late Directory root;
  late _Server server;
  late _FakeHelper helper;
  late AnkiSyncSession session;

  AnkiSyncSession newSession() => AnkiSyncSession(
    root: () async => root,
    startClient: () async => helper,
    syncDelay: const Duration(days: 1),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('anki_sync_session_');
    server = _Server()..notes.add('既存');
    helper = _FakeHelper(server);
    session = newSession();
  });

  tearDown(() async {
    await session.close();
    root.deleteSync(recursive: true);
  });

  Future<int> unsynced() =>
      AnkiSyncJournal(Directory(p.join(root.path, 'journal'))).count();

  test('没登录时加卡报 AnkiSyncNotSignedIn，什么都不写', () async {
    await expectLater(
      session.addNote(_note('猫')),
      throwsA(isA<AnkiSyncNotSignedIn>()),
    );
    expect(await unsynced(), 0);
  });

  test('登录：新库先整库下载，再加卡；同步成功才出日志', () async {
    await session.signIn(
      endpoint: 'http://nas/',
      username: 'u',
      password: 'pw',
    );
    expect(helper.calls, <String>['login', 'open', 'fullDownload']);
    expect(helper.local, <String>['既存']);

    await session.addNote(_note('猫'));
    expect(await unsynced(), 1, reason: '只进了本地库，还没同步');

    final AnkiSyncState s = await session.syncNow();
    expect(s.phase, AnkiSyncPhase.idle);
    expect(server.notes, contains('猫'));
    expect(await unsynced(), 0);
  });

  test('同步失败：卡留在日志，状态 failed', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    server.nextSync = 'fail';
    await expectLater(
      session.syncNow(),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    expect(session.state.phase, AnkiSyncPhase.failed);
    expect(await unsynced(), 1);
  });

  test('服务器要整库上传：绝不上传，停在 blocked，卡留在日志', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    server.nextSync = 'blocked';
    final AnkiSyncState s = await session.syncNow();
    expect(s.phase, AnkiSyncPhase.blocked);
    expect(server.notes, isNot(contains('猫')));
    expect(await unsynced(), 1);
  });

  test('整库下载丢了本地卡：按日志重放、再同步，服务器拿到卡', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    server.nextSync = 'fullDownload';
    final AnkiSyncState s = await session.syncNow();
    expect(s.phase, AnkiSyncPhase.idle);
    expect(helper.calls.where((String c) => c == 'add:猫'), hasLength(2));
    expect(server.notes.where((String n) => n == '猫'), hasLength(1));
    expect(await unsynced(), 0);
  });

  test('重放查重：卡其实已经在库里就不重复加', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await session.syncNow();
    // 模拟上一次同步推上去了、但响应丢了：日志还在，服务器已有。
    final AnkiSyncJournal journal = AnkiSyncJournal(
      Directory(p.join(root.path, 'journal')),
    );
    await journal.append(_note('猫'));
    server.nextSync = 'fullDownload';
    await session.syncNow();
    expect(server.notes.where((String n) => n == '猫'), hasLength(1));
    expect(await unsynced(), 0);
  });

  test('重开 app：新库下载后重放日志（媒体从日志目录读，临时文件已不在）', () async {
    final File tmpMedia = File(p.join(root.path, 'fushi_audio_abc.mp3'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(
      _note(
        '犬',
        media: <(String, String)>[('fushi_audio_abc.mp3', tmpMedia.path)],
      ),
    );
    tmpMedia.deleteSync();
    await session.close();

    // 本地库被删（换机 / 用户清理）：下次打开是新库。
    helper = _FakeHelper(server);
    session = newSession();
    await session.syncNow();
    expect(helper.calls, containsAllInOrder(<String>['fullDownload', 'add:犬']));
    expect(server.notes, contains('犬'));
    expect(await unsynced(), 0);
    expect(
      Directory(p.join(root.path, 'journal', 'media')).listSync(),
      isEmpty,
      reason: '出日志后没人引用的媒体要清掉',
    );
  });

  test('还有未同步的卡时拒绝换账号 / 退出；同一账号重新登录可以', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await expectLater(
      session.signIn(username: 'other', password: 'pw'),
      throwsA(isA<AnkiSyncHasUnsyncedNotes>()),
    );
    await expectLater(
      session.signOut(),
      throwsA(isA<AnkiSyncHasUnsyncedNotes>()),
    );
    await session.signIn(username: 'u', password: 'pw');
    expect(helper.local, contains('猫'), reason: '同账号重登不丢本地库');
    expect((await session.account())!.hkey, 'hkey-u');
  });

  test('密码错：不写账号文件', () async {
    await expectLater(
      session.signIn(username: 'u', password: 'wrong'),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    expect(await session.account(), isNull);
    expect(session.state.phase, AnkiSyncPhase.signedOut);
  });
}
