import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    this.lastSyncAt,
    this.message,
  });

  final AnkiSyncPhase phase;

  /// 还在日志里、没被同步确认的卡数。
  final int unsynced;

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
/// - `collection/`：本地库（可以随时删掉重新下载）+ `generation`（本地库代号）
///   + `sync.inflight`（同步进行中标记）
/// - `journal/`：[AnkiSyncJournal]，真相源
///
/// 数据安全规则（docs/specs/2026-09-28-anki-pending-mining-and-sync.md）：
/// - 永不整库上传（helper 保证）。
/// - 本地库**代号**：只有整库下载成功才写 `generation`；没有代号的库（新建、或上次
///   下载失败留下的空库）一律先整库下载。每次整库下载换一个新代号，并且**先落盘代号、
///   再重放**。日志条目记着自己写进的是哪一代；只有「在当前代里」的条目，同步成功后
///   才出日志，其余的都要重放——整库下载冲掉的卡、重放中途失败的卡都不会被误删。
/// - 同步前先落 `sync.inflight`：同步中途进程被杀（helper 可能已经整库下载了），
///   下次打开时把所有条目当成「不确定在不在」，查重后重放。
/// - 单条重放 / 加卡失败只标这一条（`lastError`），不挡住会话；加卡失败回滚日志条目。
/// - helper 死了（panic / 被杀）自动丢弃，下次重新拉起。
/// - 同步 / 登录 / 下载进行中（可能要拉几个 GB 媒体）：查重直接放行、加卡只写日志，
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
  static final Random _random = Random.secure();

  FushiAnkiSyncClient? _client;
  bool _opened = false;
  String? _generation;
  bool _long = false;
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
    await _publish(
      (await account()) == null
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
    await _publish(AnkiSyncPhase.busy);
    _long = true;
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
      await _ensureOpen();
      await _publish(AnkiSyncPhase.idle);
    } catch (e) {
      await _publish(
        (await account()) == null
            ? AnkiSyncPhase.signedOut
            : AnkiSyncPhase.failed,
        message: '$e',
      );
      rethrow;
    } finally {
      _long = false;
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
    if (await account() == null) throw const AnkiSyncNotSignedIn();
    if (_long) {
      await (await _journal()).append(note);
      await _publish(_state.phase);
      return null;
    }
    final int id = await _serial(() async {
      final FushiAnkiSyncClient client = await _ensureOpen();
      final AnkiSyncJournal journal = await _journal();
      final AnkiSyncJournalEntry entry = await journal.append(note);
      final int noteId;
      try {
        noteId = await _guard(_add(client, entry.note));
      } catch (_) {
        await journal.remove(<String>[entry.id]);
        rethrow;
      }
      await journal.markAdded(entry, noteId, _generation!);
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

  /// 立即同步。
  ///
  /// 先把不在当前代里的条目补进本地库；同步成功后，只有同步前就确认在当前代里的
  /// 条目出日志。服务器要求整库下载时（helper 在同一条命令里下载）：先换代落盘，
  /// 再按日志重放、再同步一次。要求整库上传时停在 [AnkiSyncPhase.blocked]。
  Future<AnkiSyncState> syncNow() => _serial(() async {
    final AnkiSyncAccount? acct = await account();
    if (acct == null) throw const AnkiSyncNotSignedIn();
    await _publish(AnkiSyncPhase.busy);
    _long = true;
    try {
      final FushiAnkiSyncClient client = await _ensureOpen();
      await _replayStale(client);
      final AnkiSyncJournal journal = await _journal();
      List<String> confirmed = <String>[
        for (final AnkiSyncJournalEntry e in await journal.entries())
          if (e.inGeneration(_generation)) e.id,
      ];
      await _setInflight(true);
      AnkiSyncResult r = await _guard(
        client.sync(hkey: acct.hkey, endpoint: acct.endpoint),
      );
      AnkiSyncAccount current = await _adoptEndpoint(acct, r);
      if (r.status == AnkiSyncStatus.ok && r.fullDownload) {
        // 本地库已被整个换掉：先落新代号，任何条目都不再「在当前代里」。
        await _newGeneration();
        await _setInflight(false);
        await _replayStale(client);
        confirmed = <String>[
          for (final AnkiSyncJournalEntry e in await journal.entries())
            if (e.inGeneration(_generation)) e.id,
        ];
        await _setInflight(true);
        r = await _guard(
          client.sync(hkey: current.hkey, endpoint: current.endpoint),
        );
        current = await _adoptEndpoint(current, r);
        if (r.fullDownload) {
          // 连着两次整库下载（极少见）：这一轮什么都不算确认，下次再来。
          await _newGeneration();
          await _setInflight(false);
          await _publish(AnkiSyncPhase.failed, message: r.serverMessage);
          return _state;
        }
      }
      await _setInflight(false);
      if (r.status == AnkiSyncStatus.fullSyncBlocked) {
        await _publish(AnkiSyncPhase.blocked, message: r.serverMessage);
        return _state;
      }
      await journal.remove(confirmed);
      _lastSyncAt = _clock();
      // 同步期间只进了日志的卡：现在补进本地库，下一轮同步推上去。
      if (await _replayStale(client) > 0) scheduleSync();
      await _publish(AnkiSyncPhase.idle, message: r.serverMessage);
      return _state;
    } catch (e) {
      await _publish(AnkiSyncPhase.failed, message: '$e');
      rethrow;
    } finally {
      _long = false;
    }
  });

  /// 关 helper。未同步的卡留在日志里，下次打开时还在。
  Future<void> close() {
    _closed = true;
    _syncTimer?.cancel();
    return _serial(() async {
      final FushiAnkiSyncClient? client = _client;
      _client = null;
      _opened = false;
      await client?.dispose();
    });
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

  /// 打开本地库。没有代号（新库 / 上次下载失败留下的空库）先整库下载并落代号；
  /// 上次同步中途被打断就换代（所有条目都要查重后重放）。之后把不在当前代里的条目
  /// 补进本地库。
  Future<FushiAnkiSyncClient> _ensureOpen() async {
    final AnkiSyncAccount? acct = await account();
    if (acct == null) throw const AnkiSyncNotSignedIn();
    final FushiAnkiSyncClient client = await _ensureClient();
    if (_opened) return client;
    final File collection = await _collectionFile();
    await collection.parent.create(recursive: true);
    await _guard(client.open(collection.path));
    _generation = await _readGeneration();
    if (_generation == null) {
      final bool wasLong = _long;
      _long = true;
      try {
        await _guard(
          client.fullDownload(hkey: acct.hkey, endpoint: acct.endpoint),
        );
      } finally {
        _long = wasLong;
      }
      await _newGeneration();
      await _setInflight(false);
    } else if (await _inflight()) {
      await _newGeneration();
      await _setInflight(false);
    }
    _opened = true;
    await _replayStale(client);
    return client;
  }

  /// 把不在当前代里的条目写进本地库，返回写进去的条数。查重兜底：库里已经有（上次
  /// 其实写进去了、或已同步过来）就只记 id；用户明确要重复卡的条目不查。单条失败只
  /// 标这一条；helper 死了才整体中断。
  Future<int> _replayStale(FushiAnkiSyncClient client) async {
    final String generation = _generation!;
    final AnkiSyncJournal journal = await _journal();
    int added = 0;
    for (final AnkiSyncJournalEntry e in await journal.entries()) {
      if (e.inGeneration(generation)) continue;
      try {
        final String first = e.note.fields.isEmpty ? '' : e.note.fields.first;
        if (!e.note.allowDuplicate) {
          final List<AnkiSyncNoteHit> hits = await _guard(
            client.findNotes(notetype: e.note.notetype, firstField: first),
          );
          if (hits.isNotEmpty) {
            await journal.markAdded(e, hits.first.noteId, generation);
            continue;
          }
        }
        await journal.markAdded(
          e,
          await _guard(_add(client, e.note)),
          generation,
        );
        added++;
      } catch (err) {
        if (client.isDead) rethrow;
        await journal.markFailed(e, '$err');
      }
    }
    return added;
  }

  Future<int> _add(FushiAnkiSyncClient client, AnkiSyncNote note) =>
      client.addNote(
        notetype: note.notetype,
        deck: note.deck,
        fields: note.fields,
        tags: note.tags,
        media: note.media,
      );

  Future<void> _discardCollection() async {
    final FushiAnkiSyncClient? client = _client;
    if (_opened && client != null && !client.isDead) await client.close();
    _opened = false;
    _generation = null;
    final Directory dir = (await _collectionFile()).parent;
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  AnkiSyncPhase _idleOr() => switch (_state.phase) {
    AnkiSyncPhase.blocked => AnkiSyncPhase.blocked,
    AnkiSyncPhase.failed => AnkiSyncPhase.failed,
    _ => AnkiSyncPhase.idle,
  };

  Future<void> _publish(AnkiSyncPhase phase, {String? message}) async {
    _state = AnkiSyncState(
      phase: phase,
      unsynced: await (await _journal()).count(),
      lastSyncAt: _lastSyncAt,
      message: message ?? (phase == _state.phase ? _state.message : null),
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

  Future<File> _generationFile() async =>
      File(p.join((await _collectionFile()).parent.path, 'generation'));

  Future<File> _inflightFile() async =>
      File(p.join((await _collectionFile()).parent.path, 'sync.inflight'));

  Future<String?> _readGeneration() async {
    final File f = await _generationFile();
    if (!f.existsSync()) return null;
    final String v = (await f.readAsString()).trim();
    return v.isEmpty ? null : v;
  }

  /// 换一代并落盘（整库下载成功之后、重放之前）。
  Future<void> _newGeneration() async {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 8; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    final File f = await _generationFile();
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(b.toString(), flush: true);
    await tmp.rename(f.path);
    _generation = b.toString();
  }

  Future<bool> _inflight() async => (await _inflightFile()).existsSync();

  Future<void> _setInflight(bool on) async {
    final File f = await _inflightFile();
    if (on) {
      await f.writeAsString('1', flush: true);
    } else if (f.existsSync()) {
      await f.delete();
    }
  }

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
