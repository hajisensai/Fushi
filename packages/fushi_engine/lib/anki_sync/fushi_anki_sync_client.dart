import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// `fushi-anki-sync` 报的错（或进程意外退出）。[message] 是 helper 的原文诊断。
class FushiAnkiSyncException implements Exception {
  const FushiAnkiSyncException(this.message);

  final String message;

  @override
  String toString() => 'FushiAnkiSyncException: $message';
}

/// 一个笔记类型及其字段名。
class AnkiSyncNotetype {
  const AnkiSyncNotetype({required this.name, required this.fields});

  final String name;
  final List<String> fields;
}

/// collection 里的牌组与笔记类型（配置界面用）。
class AnkiSyncMeta {
  const AnkiSyncMeta({required this.decks, required this.notetypes});

  final List<String> decks;
  final List<AnkiSyncNotetype> notetypes;
}

/// [FushiAnkiSyncClient.findNotes] 的一条命中。
class AnkiSyncNoteHit {
  const AnkiSyncNoteHit({
    required this.noteId,
    required this.preview,
    required this.guid,
  });

  final int noteId;

  /// 笔记的 guid（跨同步不变）。
  final String guid;

  /// 去 HTML 后的第一字段。
  final String preview;
}

/// 一次同步的结局。
enum AnkiSyncStatus {
  /// 同步完成（含必要时的整库下载与媒体同步）。
  ok,

  /// 服务器要求整库**上传**才能继续——Fushi 永远不做（那会覆盖用户的整个库）。
  /// 需要用户在官方 Anki 客户端里处理（先同步那边，或在那边选「上传」）。
  fullSyncBlocked,
}

class AnkiSyncResult {
  const AnkiSyncResult({
    required this.status,
    this.fullDownload = false,
    this.newEndpoint,
    this.serverMessage,
    this.mediaError,
  });

  final AnkiSyncStatus status;

  /// 这次同步做了整库下载。本地尚未推上去的卡已被丢弃，调用方必须从自己的队列重放。
  final bool fullDownload;

  /// 服务器通知换地址（308），调用方应持久化。
  final String? newEndpoint;
  final String? serverMessage;

  /// 牌组集合已同步好，但媒体同步失败（下次同步再补）。集合同步的结果照常有效。
  final String? mediaError;
}

/// Anki 官方 rslib 的子进程封装（`native/fushi_anki_sync`）：加卡、同步到用户自建的
/// Anki 同步服务器（或用户显式开启的 AnkiWeb），设备上不需要装 Anki。
///
/// 协议：每行一个 JSON 请求 `{"id", "cmd", ...}`，每行一个回复
/// `{"id", "ok", "result" | "error"}`。helper 串行处理，这里也严格一次一个请求。
///
/// 数据安全规则由 helper 与调用方分担（见 docs/specs/2026-09-28-anki-pending-mining-and-sync.md）：
/// helper 永不整库上传；[open] 报 `created` 的新库必须先 [fullDownload] 再加卡；
/// [sync] 报 [AnkiSyncResult.fullDownload] 时调用方从自己的队列重放未推送的卡。
class FushiAnkiSyncClient {
  FushiAnkiSyncClient.fromStreams({
    required IOSink stdin,
    required Stream<List<int>> stdout,
    Future<int>? exitCode,
  }) : _stdin = stdin {
    _lines = stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () => _failAll('fushi-anki-sync exited'));
    exitCode?.then((int code) => _failAll('fushi-anki-sync exited ($code)'));
  }

  /// 启动 [executable]。
  static Future<FushiAnkiSyncClient> start(String executable) async {
    final Process p = await Process.start(executable, const <String>[]);
    // stderr 只是诊断；不读会在管道写满后把 helper 卡住。
    unawaited(p.stderr.drain<void>());
    return FushiAnkiSyncClient.fromStreams(
      stdin: p.stdin,
      stdout: p.stdout,
      exitCode: p.exitCode,
    ).._process = p;
  }

  Process? _process;

  final IOSink _stdin;
  late final StreamSubscription<String> _lines;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  Future<void> _tail = Future<void>.value();
  String? _dead;

  /// helper 已退出 / 已 dispose：之后每个请求都会立刻失败，调用方应换一个新进程。
  bool get isDead => _dead != null;

  /// 上报给同步服务器的客户端身份（例如 `fushi,0.1.0 (anki 26.09.3),windows`）。
  Future<String> version() async =>
      (await _call(<String, Object?>{'cmd': 'version'}) as Map)['client']
          as String;

  /// 登录，返回 hkey。[endpoint] 为 null 表示 AnkiWeb。
  Future<String> login({
    String? endpoint,
    required String username,
    required String password,
  }) async =>
      (await _call(<String, Object?>{
                'cmd': 'login',
                'endpoint': endpoint,
                'username': username,
                'password': password,
              })
              as Map)['hkey']
          as String;

  /// 打开（不存在则新建）collection。返回 true = 刚新建：加卡前必须先 [fullDownload]。
  Future<bool> open(String path) async =>
      (await _call(<String, Object?>{'cmd': 'open', 'path': path})
          as Map)['created'] ==
      true;

  Future<void> close() => _call(<String, Object?>{'cmd': 'close'});

  Future<AnkiSyncMeta> listMeta() async {
    final Map<Object?, Object?> r =
        await _call(<String, Object?>{'cmd': 'list_meta'}) as Map;
    return AnkiSyncMeta(
      decks: <String>[for (final Object? d in r['decks'] as List) d as String],
      notetypes: <AnkiSyncNotetype>[
        for (final Object? n in r['notetypes'] as List)
          AnkiSyncNotetype(
            name: (n as Map)['name'] as String,
            fields: <String>[
              for (final Object? f in n['fields'] as List) f as String,
            ],
          ),
      ],
    );
  }

  /// 第一字段在该笔记类型下是否已存在。
  Future<bool> isDuplicate({
    required String notetype,
    required String firstField,
  }) async =>
      (await _call(<String, Object?>{
            'cmd': 'is_duplicate',
            'notetype': notetype,
            'first_field': firstField,
          })
          as Map)['duplicate'] ==
      true;

  /// 与 [isDuplicate] 同一判据（去 HTML、保留媒体名后第一字段相等）命中的卡，
  /// 新卡在前。
  Future<List<AnkiSyncNoteHit>> findNotes({
    required String notetype,
    required String firstField,
  }) async {
    final Map<Object?, Object?> r =
        await _call(<String, Object?>{
              'cmd': 'find_notes',
              'notetype': notetype,
              'first_field': firstField,
            })
            as Map;
    return <AnkiSyncNoteHit>[
      for (final Object? n in r['notes'] as List)
        AnkiSyncNoteHit(
          noteId: ((n as Map)['note_id'] as num).toInt(),
          guid: _requireGuid(n['guid']),
          preview: n['preview']?.toString() ?? '',
        ),
    ];
  }

  /// [notes]（note id, guid）里此刻确实在本地库、且 guid 对得上的 id。
  ///
  /// 按 guid 而不是字段内容核对：rslib 写库时会规范化字段（去控制字符、NFC），内容
  /// 比较会把确实在库里的卡认成不在。
  Future<Set<int>> existingNotes(List<(int, String)> notes) async {
    if (notes.isEmpty) return <int>{};
    final Map<Object?, Object?> r =
        await _call(<String, Object?>{
              'cmd': 'existing_notes',
              'notes': <List<Object>>[
                for (final (int id, String first) in notes) <Object>[id, first],
              ],
            })
            as Map;
    return <int>{
      for (final Object? id in r['existing'] as List) (id! as num).toInt(),
    };
  }

  /// 加一张卡，返回（note id, guid）。[media] 为（期望文件名, 本地源路径）。
  Future<(int, String)> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async {
    final Map<Object?, Object?> r =
        await _call(<String, Object?>{
              'cmd': 'add_note',
              'notetype': notetype,
              'deck': deck,
              'fields': fields,
              'tags': tags,
              'media': <List<String>>[
                for (final (String name, String path) in media)
                  <String>[name, path],
              ],
            })
            as Map;
    return ((r['note_id']! as num).toInt(), _requireGuid(r['guid']));
  }

  Future<AnkiSyncResult> sync({required String hkey, String? endpoint}) async {
    final Map<Object?, Object?> r =
        await _call(<String, Object?>{
              'cmd': 'sync',
              'hkey': hkey,
              'endpoint': endpoint,
            })
            as Map;
    if (r['status'] == 'full_sync_blocked') {
      return const AnkiSyncResult(status: AnkiSyncStatus.fullSyncBlocked);
    }
    return AnkiSyncResult(
      status: AnkiSyncStatus.ok,
      fullDownload: r['full_download'] == true,
      newEndpoint: r['new_endpoint'] as String?,
      serverMessage: r['server_message'] as String?,
      mediaError: r['media_error'] as String?,
    );
  }

  /// 整库下载（丢弃本地未推送内容）。
  Future<void> fullDownload({required String hkey, String? endpoint}) =>
      _call(<String, Object?>{
        'cmd': 'full_download',
        'hkey': hkey,
        'endpoint': endpoint,
      });

  /// 结束 helper。空闲时发 `close` 让它关库、读到 EOF 自行退出；有请求在飞（同步 /
  /// 整库下载可能要很久）时直接结束进程——不排在它们后面。杀进程不会损坏数据：
  /// 整库下载是先下到临时文件再原子替换，加卡在 SQLite 事务里。
  Future<void> dispose() async {
    if (_pending.isNotEmpty) {
      _process?.kill();
      _failAll('fushi-anki-sync disposed');
    } else {
      try {
        await close();
      } catch (_) {
        // 没开库 / helper 已经退出：没有东西要关，照样往下关管道。
      }
    }
    try {
      await _stdin.close();
    } catch (_) {
      // 进程已经没了，管道早断了。
    }
    await _lines.cancel();
    _failAll('fushi-anki-sync disposed');
  }

  Future<Object?> _call(Map<String, Object?> request) {
    final Completer<Object?> done = Completer<Object?>();
    _tail = _tail.then((_) async {
      if (_dead != null) {
        done.completeError(FushiAnkiSyncException(_dead!));
        return;
      }
      final int id = _nextId++;
      _pending[id] = done;
      try {
        _stdin.writeln(jsonEncode(<String, Object?>{'id': id, ...request}));
        await _stdin.flush();
      } catch (e) {
        // helper 刚退出、退出事件还没到：管道已断。整条队列都要失败，不能卡死。
        _failAll('fushi-anki-sync exited ($e)');
        return;
      }
      try {
        await done.future;
      } catch (_) {
        // 错误由调用方处理；这里只等它结束以保持串行。
      }
    });
    return done.future;
  }

  /// guid 是「这张卡还在不在库里」的唯一凭据：缺了不能拿空串顶上（空串永远核对不上，
  /// 卡会被每轮同步重写一次）。缺了说明 helper 与这份代码版本不配套，直接报错。
  static String _requireGuid(Object? raw) {
    if (raw is String && raw.isNotEmpty) return raw;
    throw const FushiAnkiSyncException(
      'fushi-anki-sync did not return a note guid; the helper binary is '
      'older than this version of Fushi',
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (json is! Map) return;
    final Object? id = json['id'];
    final Completer<Object?>? done = id is int ? _pending.remove(id) : null;
    if (done == null) return;
    if (json['ok'] == true) {
      done.complete(json['result']);
    } else {
      done.completeError(
        FushiAnkiSyncException(json['error']?.toString() ?? 'unknown error'),
      );
    }
  }

  void _failAll(String reason) {
    _dead ??= reason;
    for (final Completer<Object?> c in _pending.values) {
      if (!c.isCompleted) c.completeError(FushiAnkiSyncException(reason));
    }
    _pending.clear();
  }
}
