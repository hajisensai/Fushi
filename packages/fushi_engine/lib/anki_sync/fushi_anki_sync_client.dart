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
  const AnkiSyncNoteHit({required this.noteId, required this.preview});

  final int noteId;

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
  });

  final AnkiSyncStatus status;

  /// 这次同步做了整库下载。本地尚未推上去的卡已被丢弃，调用方必须从自己的队列重放。
  final bool fullDownload;

  /// 服务器通知换地址（308），调用方应持久化。
  final String? newEndpoint;
  final String? serverMessage;
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
    );
  }

  final IOSink _stdin;
  late final StreamSubscription<String> _lines;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  Future<void> _tail = Future<void>.value();
  String? _dead;

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
          preview: n['preview']?.toString() ?? '',
        ),
    ];
  }

  /// 加一张卡，返回 note id。[media] 为（期望文件名, 本地源路径）。
  Future<int> addNote({
    required String notetype,
    required String deck,
    required List<String> fields,
    List<String> tags = const <String>[],
    List<(String, String)> media = const <(String, String)>[],
  }) async =>
      ((await _call(<String, Object?>{
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
                  as Map)['note_id']
              as num)
          .toInt();

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
    );
  }

  /// 整库下载（丢弃本地未推送内容）。
  Future<void> fullDownload({required String hkey, String? endpoint}) =>
      _call(<String, Object?>{
        'cmd': 'full_download',
        'hkey': hkey,
        'endpoint': endpoint,
      });

  /// 关库、关闭 helper 的 stdin（helper 读到 EOF 后自行退出）。
  Future<void> dispose() async {
    try {
      await close();
    } catch (_) {
      // 没开库 / helper 已经退出：没有东西要关，照样往下关管道。
    }
    await _stdin.close();
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
      _stdin.writeln(jsonEncode(<String, Object?>{'id': id, ...request}));
      await _stdin.flush();
      try {
        await done.future;
      } catch (_) {
        // 错误由调用方处理；这里只等它结束以保持串行。
      }
    });
    return done.future;
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
