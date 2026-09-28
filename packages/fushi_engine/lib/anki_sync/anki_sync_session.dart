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
    required this.endpoint,
    required this.username,
    required this.hkey,
  });

  factory AnkiSyncAccount.fromJson(Map<String, Object?> json) =>
      AnkiSyncAccount(
        endpoint: json['endpoint'] as String?,
        username: json['username']! as String,
        hkey: json['hkey']! as String,
      );

  /// 自建服务器根地址；null = AnkiWeb。
  final String? endpoint;
  final String username;
  final String hkey;

  bool get isAnkiWeb => endpoint == null;

  bool sameServerAndUser(String? endpoint, String username) =>
      this.endpoint == endpoint && this.username == username;

  AnkiSyncAccount withEndpoint(String? endpoint) =>
      AnkiSyncAccount(endpoint: endpoint, username: username, hkey: hkey);

  Map<String, Object?> toJson() => <String, Object?>{
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
/// 一份未同步日志。所有操作串行（加卡与同步、重放不交错）。
///
/// 目录布局（`<root>` 跟着应用数据根走）：
/// - `account.json`：[AnkiSyncAccount]
/// - `collection/collection.anki2`（+ 媒体）：本地库，可以随时删掉重新下载
/// - `journal/`：[AnkiSyncJournal]，真相源
///
/// 数据安全规则（docs/specs/2026-09-28-anki-pending-mining-and-sync.md）：
/// 永不整库上传（helper 保证）；新建的本地库先整库下载再加卡；同步成功才出日志；
/// 整库下载后按日志重放（查重兜底，避免重复）。
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
  Future<void> _tail = Future<void>.value();
  Timer? _syncTimer;
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

  /// 读盘刷新 [state]（设置页打开时调）。
  Future<AnkiSyncState> refresh() => _serial(() async {
    await _publish(
      (await account()) == null ? AnkiSyncPhase.signedOut : _idleOr(),
    );
    return _state;
  });

  /// 登录并把服务器上的库完整下载到本地。
  ///
  /// 换到另一个服务器 / 账号时本地库整个换掉——所以那时日志里还有卡就拒绝
  /// （[AnkiSyncHasUnsyncedNotes]）；同一账号重新登录（凭据过期）保留本地库。
  Future<void> signIn({
    String? endpoint,
    required String username,
    required String password,
  }) => _serial(() async {
    final AnkiSyncAccount? old = await account();
    final List<AnkiSyncJournalEntry> pending = await _journalEntries();
    final bool sameAccount =
        old != null && old.sameServerAndUser(endpoint, username);
    if (pending.isNotEmpty && !sameAccount) {
      throw AnkiSyncHasUnsyncedNotes(pending.length);
    }
    await _publish(AnkiSyncPhase.busy);
    try {
      final FushiAnkiSyncClient client = await _ensureClient();
      final String hkey = await client.login(
        endpoint: endpoint,
        username: username,
        password: password,
      );
      if (!sameAccount) await _discardCollection();
      await _writeAccount(
        AnkiSyncAccount(endpoint: endpoint, username: username, hkey: hkey),
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
    }
  });

  /// 退出登录并删掉本地库。日志里还有卡时拒绝。
  Future<void> signOut() => _serial(() async {
    final int pending = (await _journalEntries()).length;
    if (pending > 0) throw AnkiSyncHasUnsyncedNotes(pending);
    await _discardCollection();
    final File f = await _accountFile();
    if (f.existsSync()) await f.delete();
    await _publish(AnkiSyncPhase.signedOut);
  });

  Future<AnkiSyncMeta> meta() =>
      _serial(() async => (await _ensureOpen()).listMeta());

  Future<bool> isDuplicate({
    required String notetype,
    required String firstField,
  }) => _serial(
    () async => (await _ensureOpen()).isDuplicate(
      notetype: notetype,
      firstField: firstField,
    ),
  );

  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) => _serial(
    () async => (await _ensureOpen()).findNotes(
      notetype: notetype,
      firstField: firstField,
    ),
  );

  /// 加一张卡到本地库（先写日志），返回 note id；之后自动排一次同步。
  Future<int> addNote(AnkiSyncNote note) async {
    final int id = await _serial(() async {
      final FushiAnkiSyncClient client = await _ensureOpen();
      final AnkiSyncJournalEntry entry = await (await _journal()).append(note);
      final int noteId = await _add(client, entry.note);
      await (await _journal()).markAdded(entry, noteId);
      await _publish(_idleOr());
      return noteId;
    });
    scheduleSync();
    return id;
  }

  /// [_syncDelay] 后同步一次（连续制卡只同步一次）。
  void scheduleSync() {
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

  /// 立即同步。成功才把这次之前的卡出日志；服务器要求整库下载时，下载后重放日志
  /// 再同步一次；要求整库上传时停在 [AnkiSyncPhase.blocked]。
  Future<AnkiSyncState> syncNow() => _serial(() async {
    final AnkiSyncAccount? acct = await account();
    if (acct == null) throw const AnkiSyncNotSignedIn();
    await _publish(AnkiSyncPhase.busy);
    try {
      final FushiAnkiSyncClient client = await _ensureOpen();
      final List<AnkiSyncJournalEntry> before = await _journalEntries();
      AnkiSyncResult r = await client.sync(
        hkey: acct.hkey,
        endpoint: acct.endpoint,
      );
      AnkiSyncAccount current = await _adoptEndpoint(acct, r);
      if (r.status == AnkiSyncStatus.ok && r.fullDownload) {
        await _replay(client, before);
        r = await client.sync(hkey: current.hkey, endpoint: current.endpoint);
        current = await _adoptEndpoint(current, r);
      }
      if (r.status == AnkiSyncStatus.fullSyncBlocked) {
        await _publish(AnkiSyncPhase.blocked, message: r.serverMessage);
        return _state;
      }
      await (await _journal()).remove(<String>[
        for (final AnkiSyncJournalEntry e in before) e.id,
      ]);
      _lastSyncAt = _clock();
      await _publish(AnkiSyncPhase.idle, message: r.serverMessage);
      return _state;
    } catch (e) {
      await _publish(AnkiSyncPhase.failed, message: '$e');
      rethrow;
    }
  });

  /// 关 helper。未同步的卡留在日志里，下次打开时还在。
  Future<void> close() => _serial(() async {
    _syncTimer?.cancel();
    final FushiAnkiSyncClient? client = _client;
    _client = null;
    _opened = false;
    await client?.dispose();
  });

  int? _lastSyncAt;

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

  Future<FushiAnkiSyncClient> _ensureClient() async =>
      _client ??= await _startClient();

  /// 打开本地库。新建的库先整库下载，再按日志重放；已有的库只补「写了日志、
  /// 没写进库」的那几条（进程在两步之间退出）。
  Future<FushiAnkiSyncClient> _ensureOpen() async {
    final AnkiSyncAccount? acct = await account();
    if (acct == null) throw const AnkiSyncNotSignedIn();
    final FushiAnkiSyncClient client = await _ensureClient();
    if (_opened) return client;
    final File collection = await _collectionFile();
    await collection.parent.create(recursive: true);
    final bool created = await client.open(collection.path);
    final List<AnkiSyncJournalEntry> pending = await _journalEntries();
    if (created) {
      await client.fullDownload(hkey: acct.hkey, endpoint: acct.endpoint);
      await _replay(client, pending);
    } else {
      await _replay(client, <AnkiSyncJournalEntry>[
        for (final AnkiSyncJournalEntry e in pending)
          if (e.noteId == null) e,
      ]);
    }
    _opened = true;
    return client;
  }

  /// 把日志条目重新写进本地库。查重兜底：库里已经有（上次其实写进去了、或已同步
  /// 过来）就只记 id，不重复加；用户明确要重复卡的条目不查。
  Future<void> _replay(
    FushiAnkiSyncClient client,
    List<AnkiSyncJournalEntry> entries,
  ) async {
    final AnkiSyncJournal journal = await _journal();
    for (final AnkiSyncJournalEntry e in entries) {
      final String first = e.note.fields.isEmpty ? '' : e.note.fields.first;
      if (!e.note.allowDuplicate) {
        final List<AnkiSyncNoteHit> hits = await client.findNotes(
          notetype: e.note.notetype,
          firstField: first,
        );
        if (hits.isNotEmpty) {
          await journal.markAdded(e, hits.first.noteId);
          continue;
        }
      }
      await journal.markAdded(e, await _add(client, e.note));
    }
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
    if (_opened && client != null) await client.close();
    _opened = false;
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
      unsynced: (await _journalEntries()).length,
      lastSyncAt: _lastSyncAt,
      message: message ?? (phase == _state.phase ? _state.message : null),
    );
    _states.add(_state);
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

  Future<List<AnkiSyncJournalEntry>> _journalEntries() async =>
      (await _journal()).entries();

  Future<AnkiSyncJournal> _journal() async =>
      AnkiSyncJournal(Directory(p.join((await _root()).path, 'journal')));

  Future<File> _collectionFile() async =>
      File(p.join((await _root()).path, 'collection', 'collection.anki2'));

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
