import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/anki_sync/anki_sync_journal.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';

/// 登录后记住的账号。`hkey` 是同步服务器发的登录凭据（不是密码），只落在本机
/// `<root>/account.json`——不进偏好、不进备份、不跨设备同步。
class AnkiSyncAccount {
  const AnkiSyncAccount({
    required this.server,
    required this.endpoint,
    required this.username,
    required this.hkey,
  });

  factory AnkiSyncAccount.fromJson(Map<String, Object?> json) =>
      AnkiSyncAccount(
        server: json.containsKey('server')
            ? json['server'] as String?
            : json['endpoint'] as String?,
        endpoint: json['endpoint'] as String?,
        username: json['username']! as String,
        hkey: json['hkey']! as String,
      );

  /// 用户填的服务器（自建服务器根地址；null = AnkiWeb）。判断「是不是同一个账号」
  /// 只看它和用户名。
  final String? server;

  /// 当前实际同步用的地址。AnkiWeb 会把客户端换到 `syncN.ankiweb.net` 这类分片
  /// （308），换过之后与 [server] 不同。
  final String? endpoint;
  final String username;
  final String hkey;

  bool get isAnkiWeb => server == null;

  bool sameServerAndUser(String? server, String username) =>
      this.server == server && this.username == username;

  AnkiSyncAccount withEndpoint(String? endpoint) => AnkiSyncAccount(
    server: server,
    endpoint: endpoint,
    username: username,
    hkey: hkey,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'server': server,
    'endpoint': endpoint,
    'username': username,
    'hkey': hkey,
  };
}

enum AnkiSyncPhase {
  /// 没登录。
  signedOut,

  /// 空闲（可能还有没同步的卡，见 [AnkiSyncState.unsynced]）。
  idle,

  /// 正在登录 / 下载 / 同步。
  busy,

  /// 服务器要求整库**上传**，Fushi 不做；卡留在日志里，等用户在官方 Anki 里处理。
  blocked,

  /// 上一次同步失败（网络等），卡留在日志里，下次再试。
  failed,
}

class AnkiSyncState {
  const AnkiSyncState({
    required this.phase,
    this.unsynced = 0,
    this.failing = 0,
    this.lastError,
    this.lastSyncAt,
    this.message,
  });

  final AnkiSyncPhase phase;

  /// 还在日志里、没被同步确认的卡数。
  final int unsynced;

  /// 其中写进本地库失败、在等下次重试的卡数（例如服务器上的笔记类型被删了）。
  final int failing;

  /// 最早那张写入失败的卡的原因。
  final String? lastError;

  /// 最近一次同步成功的时刻（毫秒）。
  final int? lastSyncAt;

  /// [AnkiSyncPhase.failed] / [AnkiSyncPhase.blocked] 的原因（服务器 / helper 原文）。
  final String? message;
}

/// 没登录时的加卡 / 查询。
class AnkiSyncNotSignedIn implements Exception {
  const AnkiSyncNotSignedIn();

  @override
  String toString() => 'AnkiSyncNotSignedIn';
}

/// 还有没同步的卡时换账号 / 退出：先同步，否则那些卡没地方去。
class AnkiSyncHasUnsyncedNotes implements Exception {
  const AnkiSyncHasUnsyncedNotes(this.count);

  final int count;

  @override
  String toString() => 'AnkiSyncHasUnsyncedNotes($count)';
}

/// Fushi 作为 Anki 同步客户端的会话：一个 helper 进程、一个本地 collection、
/// 一份未同步日志。碰本地库的操作串行（加卡与同步、重放不交错）。
///
/// 目录布局（`<root>` 跟着应用数据根走）：
/// - `account.json`：[AnkiSyncAccount]
/// - `collection/`：本地库（可以随时删掉重新下载）+ `downloaded`（整库下载完成标记）
/// - `journal/`：[AnkiSyncJournal]，真相源
///
/// 数据安全规则（docs/specs/2026-09-28-anki-pending-mining-and-sync.md）：
/// - 永不整库上传（helper 保证）。
/// - 没有 `downloaded` 标记的本地库（新建、或上次下载失败留下的空库）先整库下载。
/// - **出日志的唯一判据**：一次同步成功之后，立刻向 helper 核对这张卡的 note id（连同
///   首字段）确实在本地库里——同步成功意味着本地库里的一切都已在服务器上（或本来就是从
///   服务器拉下来的）。不在的（被整库下载冲掉、helper 中途出错、从没写进去）一律重新
///   写进本地库再同步；不靠「我以为写进去了」的记账。
/// - 同步出错（包括 helper 已经整库下载、之后媒体同步才失败）：什么都不出日志，并把
///   本地库当成「需要重开核对」。
/// - 单条写入失败只标这一条（`lastError`），不挡住会话；加卡失败回滚日志条目。
/// - helper 死了（panic / 被杀）自动丢弃，下次重新拉起。
/// - 同步 / 登录 / 下载进行中（首次可能要拉整个媒体库）：查重直接放行、加卡只写日志，
///   结束时补进本地库再同步——查词和制卡不排队等同步。
class AnkiSyncSession {
  AnkiSyncSession({
    required Future<Directory> Function() root,
    required Future<FushiAnkiSyncClient> Function() startClient,
    Duration syncDelay = const Duration(seconds: 5),
    int Function()? clock,
  }) : _root = root,
       _startClient = startClient,
       _syncDelay = syncDelay,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Future<Directory> Function() _root;
  final Future<FushiAnkiSyncClient> Function() _startClient;
  final Duration _syncDelay;
  final int Function() _clock;

  FushiAnkiSyncClient? _client;
  bool _opened = false;
  bool _long = false;
  bool _changingAccount = false;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();
  Timer? _syncTimer;
  AnkiSyncJournal? _journalInstance;
  int? _lastSyncAt;
  final StreamController<AnkiSyncState> _states =
      StreamController<AnkiSyncState>.broadcast();
  AnkiSyncState _state = const AnkiSyncState(phase: AnkiSyncPhase.signedOut);

  AnkiSyncState get state => _state;
  Stream<AnkiSyncState> get states => _states.stream;

  Future<AnkiSyncAccount?> account() async {
    final File f = await _accountFile();
    if (!f.existsSync()) return null;
    try {
      return AnkiSyncAccount.fromJson(
        (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读盘刷新 [state]。**不排队**：同步 / 下载可能要很久，设置页与服务端 WebUI 的
  /// 状态轮询不能被它堵住。
  Future<AnkiSyncState> refresh() async {
    final bool signedIn = await account() != null;
    await _publishWith(
      () => !signedIn
          ? AnkiSyncPhase.signedOut
          : (_long ? AnkiSyncPhase.busy : _idleOr()),
    );
    return _state;
  }

  /// 登录并确保本地库是服务器那份（新库整库下载）。
  ///
  /// 同一个服务器 + 用户名重新登录（凭据过期、改了密码）只换凭据、保留本地库与分片
  /// 地址；换到另一个服务器 / 账号时本地库整个换掉——那时日志里还有卡就拒绝
  /// （[AnkiSyncHasUnsyncedNotes]）。
  Future<void> signIn({
    String? endpoint,
    required String username,
    required String password,
  }) => _serial(() async {
    final AnkiSyncAccount? old = await account();
    final List<AnkiSyncJournalEntry> pending = await (await _journal())
        .entries();
    final bool sameAccount =
        old != null && old.sameServerAndUser(endpoint, username);
    if (pending.isNotEmpty && !sameAccount) {
      throw AnkiSyncHasUnsyncedNotes(pending.length);
    }
    _long = true;
    // 换账号期间制的卡不能进日志：它们会被重放进新账号的库。
    _changingAccount = !sameAccount;
    await _publish(AnkiSyncPhase.busy);
    try {
      final FushiAnkiSyncClient client = await _ensureClient();
      final String hkey = await _guard(
        client.login(
          endpoint: endpoint,
          username: username,
          password: password,
        ),
      );
      if (!sameAccount) await _discardCollection();
      await _writeAccount(
        AnkiSyncAccount(
          server: endpoint,
          endpoint: sameAccount ? old.endpoint : endpoint,
          username: username,
          hkey: hkey,
        ),
      );
      _changingAccount = false;
      await _ensureOpen();
      _long = false;
      await _publish(AnkiSyncPhase.idle);
    } catch (e) {
      _long = false;
      _changingAccount = false;
      await _publish(
        (await account()) == null
            ? AnkiSyncPhase.signedOut
            : AnkiSyncPhase.failed,
        message: '$e',
      );
      rethrow;
    }
    if ((await (await _journal()).entries()).isNotEmpty) scheduleSync();
  });

  /// 退出登录并删掉本地库。日志里还有卡时拒绝；[discardUnsynced] 为 true 时连同
  /// 这些卡一起放弃（用户在界面上明确确认过）。
  Future<void> signOut({bool discardUnsynced = false}) => _serial(() async {
    final AnkiSyncJournal journal = await _journal();
    final List<AnkiSyncJournalEntry> pending = await journal.entries();
    if (pending.isNotEmpty && !discardUnsynced) {
      throw AnkiSyncHasUnsyncedNotes(pending.length);
    }
    await journal.remove(<String>[
      for (final AnkiSyncJournalEntry e in pending) e.id,
    ]);
    await _discardCollection();
    final File f = await _accountFile();
    if (f.existsSync()) await f.delete();
    await _publish(AnkiSyncPhase.signedOut);
  });

  Future<AnkiSyncMeta> meta() =>
      _serial(() async => _guard((await _ensureOpen()).listMeta()));

  /// 查重。同步 / 下载进行中直接回「不重复」（不排队等几分钟）：真正加卡时如果
  /// 撞上同步，卡只进日志，补进本地库时会再查一次重。
  Future<bool> isDuplicate({
    required String notetype,
    required String firstField,
  }) async {
    if (_long) return false;
    return _serial(
      () async => _guard(
        (await _ensureOpen()).isDuplicate(
          notetype: notetype,
          firstField: firstField,
        ),
      ),
    );
  }

  /// 反查同词卡。同步 / 下载进行中回空（同 [isDuplicate]）。
  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) async {
    if (_long) return const <AnkiSyncNoteHit>[];
    return _serial(
      () async => _guard(
        (await _ensureOpen()).findNotes(
          notetype: notetype,
          firstField: firstField,
        ),
      ),
    );
  }

  /// 加一张卡：先写日志，再写本地库，返回 note id，之后排一次同步。
  ///
  /// 同步 / 下载进行中只写日志、返回 null（卡没丢，同步结束时补进本地库）。
  /// 写本地库失败时回滚日志条目并抛出——调用方告诉用户「没制成」，日志里也就没有它。
  Future<int?> addNote(AnkiSyncNote note) async {
    final bool signedIn = await account() != null;
    // 在 await 之后同步地判断：换账号可能恰好在上面那次 await 期间开始。
    if (_changingAccount || !signedIn) throw const AnkiSyncNotSignedIn();
    if (_long) {
      await (await _journal()).append(note);
      await refresh();
      // 正在跑的那一轮结束时会补进本地库；万一它已经过了补的那一步，这里兜一次。
      scheduleSync();
      return null;
    }
    final int id = await _serial(() async {
      final FushiAnkiSyncClient client = await _ensureOpen();
      final AnkiSyncJournal journal = await _journal();
      final AnkiSyncJournalEntry entry = await journal.append(note);
      final (int, String) added;
      try {
        added = await _guard(_add(client, entry.note));
      } catch (_) {
        await journal.remove(<String>[entry.id]);
        rethrow;
      }
      final (int noteId, String guid) = added;
      await journal.markAdded(entry, noteId, guid);
      await _publish(_idleOr());
      return noteId;
    });
    scheduleSync();
    return id;
  }

  /// [_syncDelay] 后同步一次（连续制卡只同步一次）。
  void scheduleSync() {
    if (_closed) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(_syncDelay, () => unawaited(_syncQuietly()));
  }

  Future<void> _syncQuietly() async {
    try {
      await syncNow();
    } catch (_) {
      // 失败已经写进 state；日志还在，下次再同步。
    }
  }

  /// 立即同步：先把日志里不在本地库的卡写进去，同步，成功后出日志「确实在本地库里」
  /// 的那些。服务器触发了整库下载时，被冲掉的卡再写一次、再同步一次。要求整库上传时
  /// 停在 [AnkiSyncPhase.blocked]。
  Future<AnkiSyncState> syncNow() => _serial(() async {
    AnkiSyncAccount? acct = await account();
    if (acct == null) throw const AnkiSyncNotSignedIn();
    _long = true;
    await _publish(AnkiSyncPhase.busy);
    try {
      final FushiAnkiSyncClient client = await _ensureOpen();
      String? serverMessage;

      for (int round = 0; round < 2; round++) {
        await _reconcile(client, write: true);
        final AnkiSyncResult r = await _guard(
          client.sync(hkey: acct!.hkey, endpoint: acct.endpoint),
        );
        acct = await _adoptEndpoint(acct, r);
        // 牌组集合同步好了；媒体失败只作提示，下次同步再补。
        serverMessage = r.mediaError ?? r.serverMessage;
        if (r.status == AnkiSyncStatus.fullSyncBlocked) {
          _long = false;
          await _publish(AnkiSyncPhase.blocked, message: r.serverMessage);
          return _state;
        }
        // 同步成功：此刻本地库里的一切都在服务器上。
        final Set<String> confirmed = (await _reconcile(
          client,
          write: false,
        )).present;
        await (await _journal()).remove(confirmed);
        _lastSyncAt = _clock();
        // 整库下载冲掉的卡：下一轮写回去再推。
        if (!r.fullDownload) break;
      }
      // 同步期间只进了日志的卡：补进本地库，下一轮推上去。
      final int written = (await _reconcile(client, write: true)).added;
      if (written > 0) scheduleSync();
      _long = false;
      await _publish(AnkiSyncPhase.idle, message: serverMessage);
      return _state;
    } catch (e) {
      // helper 可能已经换掉了本地库、甚至没能重新打开它：下次重开、重新核对。
      _opened = false;
      _long = false;
      await _publish(AnkiSyncPhase.failed, message: '$e');
      rethrow;
    }
  });

  /// 关 helper（立即，不排在长同步后面）。未同步的卡留在日志里，下次打开时还在；
  /// 正在进行的同步随 helper 退出而失败，什么都不会出日志。
  Future<void> close() async {
    _closed = true;
    _syncTimer?.cancel();
    final FushiAnkiSyncClient? client = _client;
    _client = null;
    _opened = false;
    await client?.dispose();
    await _states.close();
  }

  Future<AnkiSyncAccount> _adoptEndpoint(
    AnkiSyncAccount acct,
    AnkiSyncResult r,
  ) async {
    final String? moved = r.newEndpoint;
    if (moved == null || moved.isEmpty || moved == acct.endpoint) return acct;
    final AnkiSyncAccount updated = acct.withEndpoint(moved);
    await _writeAccount(updated);
    return updated;
  }

  /// 拿一个活着的 helper：上一个死了（panic / 被杀 / 管道断）就丢掉重开。
  Future<FushiAnkiSyncClient> _ensureClient() async {
    // 关闭之后（服务端停机、app 退出）还在排队的操作不能再拉起一个没人管的进程。
    if (_closed) throw StateError('AnkiSyncSession is closed');
    final FushiAnkiSyncClient? existing = _client;
    if (existing != null && !existing.isDead) return existing;
    _client = null;
    _opened = false;
    return _client = await _startClient();
  }

  /// helper 调用的统一出口：调用失败且 helper 已经死了，标记要重开。
  Future<T> _guard<T>(Future<T> call) async {
    try {
      return await call;
    } catch (_) {
      if (_client?.isDead ?? false) _opened = false;
      rethrow;
    }
  }

  /// 打开本地库。没有 `downloaded` 标记（新库 / 上次下载失败留下的空库）先整库下载；
  /// 之后把日志里不在本地库的卡写进去。
  Future<FushiAnkiSyncClient> _ensureOpen() async {
    final AnkiSyncAccount? acct = await account();
    if (acct == null) throw const AnkiSyncNotSignedIn();
    final FushiAnkiSyncClient client = await _ensureClient();
    if (_opened) return client;
    final File collection = await _collectionFile();
    await collection.parent.create(recursive: true);
    await _guard(client.open(collection.path));
    final File downloaded = await _downloadedFile();
    if (!downloaded.existsSync()) {
      final bool wasLong = _long;
      _long = true;
      try {
        await _guard(
          client.fullDownload(hkey: acct.hkey, endpoint: acct.endpoint),
        );
      } finally {
        _long = wasLong;
      }
      await downloaded.writeAsString('1', flush: true);
    }
    _opened = true;
    await _reconcile(client, write: true);
    return client;
  }

  /// 核对日志与本地库：[present] 是「note id + guid 此刻确实在本地库里」的条目 id，
  /// [added] 是这次新写进本地库的条数。
  ///
  /// [write] 为 true 时把不在的写进去。没有 note id 的（撞上同步只进了日志、写日志后
  /// 进程被杀）先查重：同词卡已经在库里就只记 id；用户明确要重复卡的不查。有 note id
  /// 却不在的（整库下载冲掉了）直接重写。单条失败只标这一条；helper 死了才整体中断。
  Future<({Set<String> present, int added})> _reconcile(
    FushiAnkiSyncClient client, {
    required bool write,
  }) async {
    final AnkiSyncJournal journal = await _journal();
    final List<AnkiSyncJournalEntry> entries = await journal.entries();
    final Set<int> existing = await _guard(
      client.existingNotes(<(int, String)>[
        for (final AnkiSyncJournalEntry e in entries)
          if (e.noteId != null && e.guid != null) (e.noteId!, e.guid!),
      ]),
    );
    final Set<String> present = <String>{};
    int added = 0;
    for (final AnkiSyncJournalEntry e in entries) {
      if (e.noteId != null && existing.contains(e.noteId)) {
        present.add(e.id);
        continue;
      }
      if (!write) continue;
      try {
        if (e.noteId == null && !e.note.allowDuplicate) {
          final List<AnkiSyncNoteHit> hits = await _guard(
            client.findNotes(
              notetype: e.note.notetype,
              firstField: e.firstField,
            ),
          );
          if (hits.isNotEmpty) {
            await journal.markAdded(e, hits.first.noteId, hits.first.guid);
            present.add(e.id);
            continue;
          }
        }
        final (int noteId, String guid) = await _guard(_add(client, e.note));
        await journal.markAdded(e, noteId, guid);
        present.add(e.id);
        added++;
      } catch (err) {
        if (client.isDead) rethrow;
        await journal.markFailed(e, '$err');
      }
    }
    return (present: present, added: added);
  }

  Future<(int, String)> _add(FushiAnkiSyncClient client, AnkiSyncNote note) =>
      client.addNote(
        notetype: note.notetype,
        deck: note.deck,
        fields: note.fields,
        tags: note.tags,
        media: note.media,
      );

  Future<void> _discardCollection() async {
    final FushiAnkiSyncClient? client = _client;
    // 不看 _opened：下载失败时 helper 已经打开了库、_opened 却是 false，不关的话
    // Windows 上删不掉目录。helper 的 close 对没开库是空操作。
    if (client != null && !client.isDead) await client.close();
    _opened = false;
    final Directory dir = (await _collectionFile()).parent;
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  AnkiSyncPhase _idleOr() => switch (_state.phase) {
    AnkiSyncPhase.blocked => AnkiSyncPhase.blocked,
    AnkiSyncPhase.failed => AnkiSyncPhase.failed,
    _ => AnkiSyncPhase.idle,
  };

  Future<void> _publish(AnkiSyncPhase phase, {String? message}) =>
      _publishWith(() => phase, message: message);

  /// 先把要 await 的都读完，再**同步地**决定阶段并写入——并发的发布者不会拿一个
  /// await 之前算好的旧阶段覆盖别人刚写的新阶段。
  Future<void> _publishWith(
    AnkiSyncPhase Function() phase, {
    String? message,
  }) async {
    final List<AnkiSyncJournalEntry> entries = await (await _journal())
        .entries();
    final List<AnkiSyncJournalEntry> failing = <AnkiSyncJournalEntry>[
      for (final AnkiSyncJournalEntry e in entries)
        if (e.lastError != null) e,
    ];
    final AnkiSyncPhase next = phase();
    _state = AnkiSyncState(
      phase: next,
      unsynced: entries.length,
      failing: failing.length,
      lastError: failing.isEmpty ? null : failing.first.lastError,
      lastSyncAt: _lastSyncAt,
      message: message ?? (next == _state.phase ? _state.message : null),
    );
    if (!_states.isClosed) _states.add(_state);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<AnkiSyncJournal> _journal() async => _journalInstance ??=
      AnkiSyncJournal(Directory(p.join((await _root()).path, 'journal')));

  Future<File> _collectionFile() async =>
      File(p.join((await _root()).path, 'collection', 'collection.anki2'));

  Future<File> _downloadedFile() async =>
      File(p.join((await _collectionFile()).parent.path, 'downloaded'));

  Future<File> _accountFile() async =>
      File(p.join((await _root()).path, 'account.json'));

  Future<void> _writeAccount(AnkiSyncAccount acct) async {
    final File target = await _accountFile();
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(acct.toJson()), flush: true);
    await tmp.rename(target.path);
  }
}
