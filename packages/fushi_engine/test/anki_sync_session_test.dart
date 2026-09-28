import 'dart:async';
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
  String? movedTo;
}

/// 内存里的 helper：本地库 = [local]，[pushed] 标记哪些已推上服务器。
class _FakeHelper implements FushiAnkiSyncClient {
  _FakeHelper(this.server);

  final _Server server;
  final List<String> local = <String>[];
  final Set<String> pushed = <String>{};
  final List<String> calls = <String>[];
  final Set<String> failOn = <String>{};
  int fullDownloadFailures = 0;
  Completer<void>? holdSync;
  int _nextId = 1;

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
    pushed
      ..clear()
      ..addAll(server.notes);
  }

  @override
  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) async => <AnkiSyncNoteHit>[
    if (local.contains(firstField))
      const AnkiSyncNoteHit(noteId: 99, preview: ''),
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
    if (failOn.contains(fields.first)) {
      throw FushiAnkiSyncException('cannot add ${fields.first}');
    }
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
    }
    for (final String n in local) {
      if (pushed.add(n)) server.notes.add(n);
    }
    return AnkiSyncResult(status: AnkiSyncStatus.ok, newEndpoint: moved);
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
    server = _Server()..notes.add('既存');
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

  test('没登录时加卡报 AnkiSyncNotSignedIn，什么都不写', () async {
    await expectLater(
      session.addNote(_note('猫')),
      throwsA(isA<AnkiSyncNotSignedIn>()),
    );
    expect(await unsynced(), 0);
  });

  test('登录：新库先整库下载，再加卡；同步成功才出日志', () async {
    await session.signIn(endpoint: 'http://nas/', username: 'u', password: 'pw');
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

  // 审查阻断项：整库下载后重放中途失败，失败的条目带着旧库的 note id，
  // 旧实现下一次普通同步就把它当「已落地」出日志——卡两边都没有。
  test('整库下载后重放中途失败：失败的卡留在日志，下次补进去，不会被误删', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await session.addNote(_note('犬'));
    server.nextSync = 'fullDownload';
    helper.failOn.add('犬');
    await session.syncNow();
    expect(server.notes, contains('猫'));
    expect(server.notes, isNot(contains('犬')));
    expect(await unsynced(), 1);
    expect((await journal().entries()).single.lastError, contains('犬'));

    // 又一次普通同步（旧实现在这里静默删掉犬）。失败原因还在时照样不能删。
    await session.syncNow();
    expect(await unsynced(), 1, reason: '不在当前代里的卡不能出日志');

    helper.failOn.clear();
    await session.syncNow();
    await session.syncNow();
    expect(server.notes, contains('犬'));
    expect(await unsynced(), 0);
  });

  test('重放查重：卡其实已经在库里就不重复加', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await session.syncNow();
    // 模拟上一次同步推上去了、但响应丢了：日志还在，服务器已有。
    await journal().append(_note('猫'));
    server.nextSync = 'fullDownload';
    await session.syncNow();
    expect(server.notes.where((String n) => n == '猫'), hasLength(1));
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
    expect(server.notes, contains('犬'));
    expect(await unsynced(), 0);
    expect(
      Directory(p.join(root.path, 'journal', 'media')).listSync(),
      isEmpty,
      reason: '出日志后没人引用的媒体要清掉',
    );
  });

  // 审查重要项 2：open 建出空库后整库下载失败，旧实现下一次按「库已存在」跳过下载。
  test('首次整库下载失败：同账号重登时重新下载，不把空库当成已初始化', () async {
    helper.fullDownloadFailures = 1;
    await expectLater(
      session.signIn(username: 'u', password: 'pw'),
      throwsA(isA<FushiAnkiSyncException>()),
    );
    await session.signIn(username: 'u', password: 'pw');
    expect(helper.calls.where((String c) => c == 'fullDownload'), hasLength(2));
    expect(helper.local, <String>['既存']);
  });

  // 审查重要项 3：加卡失败留下 noteId 为空的毒条目，重启后挡住整个会话。
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

    // 同一个假 helper = 磁盘上的本地库还在（只是进程重开）。
    session = newSession();
    expect(
      await session.isDuplicate(notetype: 'Basic', firstField: '猫'),
      isTrue,
      reason: '会话打得开，查得到刚才那张',
    );
    await session.syncNow();
    expect(server.notes, contains('猫'));
  });

  // 审查重要项 4：helper 死了之后永远不恢复。
  test('helper 死了：下一次调用自动换一个新进程', () async {
    await session.signIn(username: 'u', password: 'pw');
    expect(started, 1);
    helper.isDead = true;
    final _FakeHelper fresh = _FakeHelper(server);
    helper = fresh;
    await session.addNote(_note('猫'));
    expect(started, 2);
    expect(fresh.calls, containsAllInOrder(<String>['open', 'add:猫']));
  });

  // 审查重要项 5：AnkiWeb 把客户端换到分片地址后，同账号重登被当成换账号。
  test('换了分片地址后同账号重新登录：不算换账号，保留本地库与分片地址', () async {
    await session.signIn(username: 'u', password: 'pw');
    server.movedTo = 'https://sync7.ankiweb.net/';
    await session.syncNow();
    expect((await session.account())!.endpoint, 'https://sync7.ankiweb.net/');
    await session.addNote(_note('猫'));

    await session.signIn(username: 'u', password: 'pw');
    expect((await session.account())!.endpoint, 'https://sync7.ankiweb.net/');
    expect(helper.local, contains('猫'), reason: '同账号重登不丢本地库');
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

  // 审查重要项 7：同步（可能拉几个 GB 媒体）期间查词查重 / 制卡不排队。
  test('同步进行中：查重直接放行，加卡只进日志，同步结束补进本地库', () async {
    await session.signIn(username: 'u', password: 'pw');
    helper.holdSync = Completer<void>();
    final Future<AnkiSyncState> running = session.syncNow();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      await session.isDuplicate(notetype: 'Basic', firstField: '既存'),
      isFalse,
    );
    expect(await session.addNote(_note('猫')), isNull);
    expect(helper.local, isNot(contains('猫')));
    expect(await unsynced(), 1);

    helper.holdSync!.complete();
    helper.holdSync = null;
    await running;
    expect(helper.local, contains('猫'), reason: '同步结束时补进本地库');
    await session.syncNow();
    expect(server.notes, contains('猫'));
    expect(await unsynced(), 0);
  });

  test('同步中途进程被杀：重开后所有条目查重后重放，不产生重复卡', () async {
    await session.signIn(username: 'u', password: 'pw');
    await session.addNote(_note('猫'));
    await session.close();
    File(
      p.join(root.path, 'collection', 'sync.inflight'),
    ).writeAsStringSync('1');

    session = newSession();
    await session.syncNow();
    expect(helper.calls.where((String c) => c == 'add:猫'), hasLength(1));
    expect(server.notes.where((String n) => n == '猫'), hasLength(1));
    expect(await unsynced(), 0);
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
