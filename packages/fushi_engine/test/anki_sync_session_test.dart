import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/anki_sync/anki_sync_journal.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务器上的库：note id → 首字段。
class _Server {
  final Map<int, String> notes = <int, String>{1000: '既存'};

  /// 下一次 sync 服务器要求什么。
  /// normal | fullDownload | fullDownloadThenFail | blocked | fail
  String nextSync = 'normal';
  String? movedTo;

  List<String> get words => notes.values.toList();
}

/// 内存里的 helper：本地库 = [local]（note id → 首字段）。整库下载把本地库整个换成
/// 服务器那份（本地没推上去的卡随之消失，与 rslib 行为一致）。
class _FakeHelper implements FushiAnkiSyncClient {
  _FakeHelper(this.server);

  final _Server server;
  final Map<int, String> local = <int, String>{};
  final List<String> calls = <String>[];
  final Set<String> failOn = <String>{};
  int fullDownloadFailures = 0;
  Completer<void>? holdSync;
  static int _nextId = 1;

  List<String> get words => local.values.toList();

  @override
  bool isDead = false;

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
    return true;
  }

  @override
  Future<void> close() async => calls.add('close');

  @override
  Future<void> fullDownload({required String hkey, String? endpoint}) async {
    calls.add('fullDownload');
    if (fullDownloadFailures > 0) {
      fullDownloadFailures--;
      throw const FushiAnkiSyncException('network down');
    }
    _download();
  }

  void _download() {
    local
      ..clear()
      ..addAll(server.notes);
  }

  @override
  Future<Set<int>> existingNotes(List<(int, String)> notes) async => <int>{
    for (final (int id, String first) in notes)
      if (local[id] == first) id,
  };

  @override
  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) async => <AnkiSyncNoteHit>[
    for (final MapEntry<int, String> e in local.entries)
      if (e.value == firstField) AnkiSyncNoteHit(noteId: e.key, preview: ''),
  ];

  @override
  Future<bool> isDuplicate({
    required String notetype,
    required String firstField,
  }) async => local.containsValue(firstField);

  @override
  Future<int> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async {
    calls.add('add:${fields.first}');
    if (failOn.contains(fields.first)) {
      throw FushiAnkiSyncException('cannot add ${fields.first}');
    }
    for (final (String _, String path) in media) {
      if (!File(path).existsSync()) {
        throw FushiAnkiSyncException('cannot read media file $path');
      }
    }
    final int id = _nextId++;
    local[id] = fields.first;
    return id;
  }

  @override
  Future<AnkiSyncResult> sync({required String hkey, String? endpoint}) async {
    calls.add('sync:$endpoint');
    final Completer<void>? hold = holdSync;
    if (hold != null) await hold.future;
    final String mode = server.nextSync;
    server.nextSync = 'normal';
    final String? moved = server.movedTo;
    server.movedTo = null;
    switch (mode) {
      case 'fail':
        throw const FushiAnkiSyncException('network down');
      case 'blocked':
        return const AnkiSyncResult(status: AnkiSyncStatus.fullSyncBlocked);
      case 'fullDownload':
        _download();
        return const AnkiSyncResult(
          status: AnkiSyncStatus.ok,
          fullDownload: true,
        );
      case 'fullDownloadThenFail':
        // helper 已经换掉本地库，之后媒体同步失败：Dart 只看到一个错误。
        _download();
        throw const FushiAnkiSyncException('media sync failed');
    }
    server.notes.addAll(local);
    return AnkiSyncResult(status: AnkiSyncStatus.ok, newEndpoint: moved);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AnkiSyncNote _note(
  String word, {
  List<(String, String)> media = const [],
  bool allowDuplicate = false,
}) => AnkiSyncNote(
  notetype: 'Basic',
  deck: 'Mining',
  fields: <String>[word, 'meaning'],
  media: media,
  allowDuplicate: allowDuplicate,
);

void main() {
  late Directory root;
  late _Server server;
  late _FakeHelper helper;
  late AnkiSyncSession session;
  late int started;

  AnkiSyncSession newSession() => AnkiSyncSession(
    root: () async => root,
    startClient: () async {
      started++;
      return helper;
    },
    syncDelay: const Duration(days: 1),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('anki_sync_session_');
    server = _Server();
    helper = _FakeHelper(server);
    started = 0;
    session = newSession();
  });

  tearDown(() async {
    await session.close();
    root.deleteSync(recursive: true);
  });

  AnkiSyncJournal journal() =>
      AnkiSyncJournal(Directory(p.join(root.path, 'journal')));
  Future<int> unsynced() => journal().count();
  int onServer(String word) =>
      server.words.where((String w) => w == word).length;

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
    expect(helper.calls, <String>['login', 'close', 'open', 'fullDownload']);
    expect(helper.words, <String>['既存']);

    await session.addNote(_note('猫'));
    expect(await unsynced(), 1, reason: '只进了本地库，还没同步');

    final AnkiSyncState s = await session.syncNow();
    expect(s.phase, AnkiSyncPhase.idle);
    expect(onServer('猫'), 1);
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
    expect(onServer('猫'), 0);
    expect(await unsynced(), 1);
  });

  test('整库下载丢了本地卡：同一次同步里写回去、再推，服务器拿到卡', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    server.nextSync = 'fullDownload';
    final AnkiSyncState s = await session.syncNow();
    expect(s.phase, AnkiSyncPhase.idle);
    expect(helper.calls.where((String c) => c == 'add:猫'), hasLength(2));
    expect(onServer('猫'), 1);
    expect(await unsynced(), 0);
  });

  // 复审阻断 B1：helper 已经整库下载、之后媒体同步失败，Dart 只看到错误。
  // 旧实现下一次同步按「记账说在库里」把卡出日志——卡两边都没有。
  test('整库下载后媒体同步失败：下一次同步发现卡不在库里，写回去再推，不丢', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    server.nextSync = 'fullDownloadThenFail';
    await expectLater(
      session.syncNow(),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    expect(helper.words, isNot(contains('猫')), reason: '本地库已被换掉');
    expect(await unsynced(), 1);

    await session.syncNow();
    expect(onServer('猫'), 1);
    expect(await unsynced(), 0);
  });

  test('整库下载后写回失败的卡：留在日志（带原因），之后补进去，不会被误删', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await session.addNote(_note('犬'));
    server.nextSync = 'fullDownload';
    helper.failOn.add('犬');
    await session.syncNow();
    expect(onServer('猫'), 1);
    expect(onServer('犬'), 0);
    expect(await unsynced(), 1);
    expect(session.state.failing, 1);
    expect(session.state.lastError, contains('犬'));

    await session.syncNow();
    expect(await unsynced(), 1, reason: '不在库里的卡不能出日志');

    helper.failOn.clear();
    await session.syncNow();
    expect(onServer('犬'), 1);
    expect(await unsynced(), 0);
  });

  // 复审重要 I1：同步失败后重开，允许重复的卡不能靠首字段查重判断——它本来就在库里。
  test('允许重复的卡：同步失败、重开后不会再写一遍', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('既存', allowDuplicate: true));
    server.nextSync = 'fail';
    await expectLater(
      session.syncNow(),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    await session.close();

    session = newSession(); // 同一个 helper = 磁盘上的本地库还在
    await session.syncNow();
    expect(helper.calls.where((String c) => c == 'add:既存'), hasLength(1));
    expect(onServer('既存'), 2, reason: '原有的一张 + 用户要的重复卡一张');
    expect(await unsynced(), 0);
  });

  test('重放查重：卡其实已经在库里就不重复加', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await session.syncNow();
    // 模拟上一次同步推上去了、但响应丢了：日志里多一条同词卡（没有 note id）。
    await journal().append(_note('猫'));
    server.nextSync = 'fullDownload';
    await session.syncNow();
    expect(onServer('猫'), 1);
    expect(await unsynced(), 0);
  });

  test('本地库被删（换机 / 清理）：重开后整库下载并按日志重放（媒体从日志目录读）', () async {
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
    Directory(p.join(root.path, 'collection')).deleteSync(recursive: true);

    helper = _FakeHelper(server);
    session = newSession();
    await session.syncNow();
    expect(helper.calls, containsAllInOrder(<String>['fullDownload', 'add:犬']));
    expect(onServer('犬'), 1);
    expect(await unsynced(), 0);
    expect(
      Directory(p.join(root.path, 'journal', 'media')).listSync(),
      isEmpty,
      reason: '出日志后没人引用的媒体要清掉',
    );
  });

  test('首次整库下载失败：同账号重登时重新下载，不把空库当成已初始化', () async {
    helper.fullDownloadFailures = 1;
    await expectLater(
      session.signIn(username: 'u', password: 'pw'),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    await session.signIn(username: 'u', password: 'pw');
    expect(helper.calls.where((String c) => c == 'fullDownload'), hasLength(2));
    expect(helper.words, <String>['既存']);
  });

  // 复审重要 I2：下载失败时 helper 已经打开了库，退出要先关掉它（Windows 删不掉目录）。
  test('首次整库下载失败后退出：先让 helper 关库再删目录', () async {
    helper.fullDownloadFailures = 1;
    await expectLater(
      session.signIn(username: 'u', password: 'pw'),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    helper.calls.clear();
    await session.signOut();
    expect(helper.calls, contains('close'));
    expect(Directory(p.join(root.path, 'collection')).existsSync(), isFalse);
  });

  test('加卡失败：回滚日志条目；会话照常可用，重启也打得开', () async {
    await session.signIn(username: 'u', password: 'pw');
    helper.failOn.add('坏');
    await expectLater(
      session.addNote(_note('坏')),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    expect(await unsynced(), 0);
    await session.addNote(_note('猫'));
    await session.close();

    session = newSession();
    expect(
      await session.isDuplicate(notetype: 'Basic', firstField: '猫'),
      isTrue,
    );
    await session.syncNow();
    expect(onServer('猫'), 1);
  });

  test('helper 死了：下一次调用自动换一个新进程', () async {
    await session.signIn(username: 'u', password: 'pw');
    expect(started, 1);
    helper.isDead = true;
    final _FakeHelper fresh = _FakeHelper(server)..local.addAll(helper.local);
    helper = fresh;
    await session.addNote(_note('猫'));
    expect(started, 2);
    expect(fresh.calls, containsAllInOrder(<String>['open', 'add:猫']));
  });

  test('换了分片地址后同账号重新登录：不算换账号，保留本地库与分片地址', () async {
    await session.signIn(username: 'u', password: 'pw');
    server.movedTo = 'https://sync7.ankiweb.net/';
    await session.syncNow();
    expect((await session.account())!.endpoint, 'https://sync7.ankiweb.net/');
    await session.addNote(_note('猫'));

    await session.signIn(username: 'u', password: 'pw');
    expect((await session.account())!.endpoint, 'https://sync7.ankiweb.net/');
    expect(helper.words, contains('猫'), reason: '同账号重登不丢本地库');
    await session.syncNow();
    expect(helper.calls.last, 'sync:https://sync7.ankiweb.net/');
  });

  test('还有未同步的卡时拒绝换账号 / 退出；确认放弃后可以退出', () async {
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
    await session.signOut(discardUnsynced: true);
    expect(await session.account(), isNull);
    expect(await unsynced(), 0);
  });

  test('同步进行中：查重直接放行，加卡只进日志，同步结束补进本地库；状态不卡在 busy', () async {
    await session.signIn(username: 'u', password: 'pw');
    helper.holdSync = Completer<void>();
    final Future<AnkiSyncState> running = session.syncNow();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      await session.isDuplicate(notetype: 'Basic', firstField: '既存'),
      isFalse,
    );
    expect(await session.addNote(_note('猫')), isNull);
    expect(helper.words, isNot(contains('猫')));
    expect(await unsynced(), 1);

    helper.holdSync!.complete();
    helper.holdSync = null;
    await running;
    expect(helper.words, contains('猫'), reason: '同步结束时补进本地库');
    expect(session.state.phase, AnkiSyncPhase.idle);
    await session.refresh();
    expect(session.state.phase, AnkiSyncPhase.idle);
    await session.syncNow();
    expect(onServer('猫'), 1);
    expect(await unsynced(), 0);
  });

  test('关闭后：不再拉起 helper', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.close();
    await expectLater(session.syncNow(), throwsA(isA<StateError>()));
    expect(started, 1);
    session = newSession(); // tearDown 关的是这个
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
