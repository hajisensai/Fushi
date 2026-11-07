/// 服务端的 AnkiConnect v6 兼容监听（docs/specs/2026-11-05-server-srs-design.md §4.5）：Yomitan 一类工具把卡加进
/// 服务端的复习库。
///
/// - 默认关；开了也默认只听本机（`ankiconnect.bind: 127.0.0.1`）。非回环地址没配 key 时拒绝起（不在局域网裸开）。
/// - AnkiConnect 没有 profile 字段，**按 key 选 profile**：`profile_keys` 里的 key → 那份；共用 `api_key`、
///   或本机来的不带 key 的请求 → 默认 profile。key 不对 → 交给默认那份的处理器，按 AnkiConnect 语义回错。
/// - 每份 profile 一个 [SrsAnkiConnectEndpoint]（引擎同一份实现：Origin 白名单、回环限制、包体上限）；写入后
///   服务端把这份 profile 发出去（[ServerSrs.notifyWrite]）。
/// - 没有界面：`guiBrowse` / `guiEditNote` 回「不支持」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

/// 包体上限（与引擎端点同）：先读进来按 key 分派，再原样交给那份 profile 的端点。
const int kServerAnkiConnectMaxBody = 128 * 1024 * 1024;

/// 这一次请求经分派认定的 key（交给处理器的 `apiKey`，让它按 AnkiConnect 语义核对 body 里的 `key`）。
final Object _matchedKeyZone = Object();

class ServerAnkiConnect {
  ServerAnkiConnect({
    required ServerSrs srs,
    required ServerAnkiConnectConfig Function() config,
  }) : _srs = srs,
       _config = config;

  final ServerSrs _srs;
  final ServerAnkiConnectConfig Function() _config;

  /// `fushiIdentify` 的实例 id（Fushi 自己的 AnkiConnect 客户端据此认出「指向了自己」）。
  final String instanceId = srsAnkiConnectNewInstanceId();

  HttpServer? _http;
  ServerAnkiConnectConfig? _running;
  final Map<String, SrsAnkiConnectEndpoint> _endpoints =
      <String, SrsAnkiConnectEndpoint>{};

  /// 起不来 / 拒绝起的原因（WebUI / admin 状态显示）；在跑或关着为 null。
  String? lastError;

  bool get listening => _http != null;
  int? get port => _http?.port;

  /// 按当前配置起 / 停 / 换端口（WebUI 改了 `ankiconnect.*` 即调，不重启）。
  Future<void> apply() async {
    final ServerAnkiConnectConfig cfg = _config();
    final ServerAnkiConnectConfig? running = _running;
    final bool sameSocket =
        running != null && running.bind == cfg.bind && running.port == cfg.port;
    if (!cfg.enabled) {
      lastError = null;
      await _close();
      return;
    }
    final String? problem = cfg.startProblem;
    if (problem != null) {
      lastError = problem;
      engineLog.log('ServerAnkiConnect', StateError(problem));
      await _close();
      return;
    }
    if (_http != null && sameSocket) {
      // key / 来源白名单现读，不必重开端口。
      _running = cfg;
      return;
    }
    await _close();
    try {
      _http = await shelf_io.serve(handle, cfg.bind, cfg.port);
      _running = cfg;
      lastError = null;
      engineLog.logDiagnostic(
        'ServerAnkiConnect',
        'AnkiConnect listening on ${cfg.bind}:${_http!.port}',
      );
    } catch (e, stack) {
      lastError = '$e';
      engineLog.log('ServerAnkiConnect.listen', e, stack);
    }
  }

  Future<void> stop() => _close();

  Future<void> _close() async {
    final HttpServer? http = _http;
    _http = null;
    _running = null;
    await http?.close(force: true);
    for (final SrsAnkiConnectEndpoint e in _endpoints.values) {
      try {
        await e.handler.close();
      } catch (err, stack) {
        engineLog.log('ServerAnkiConnect.close', err, stack);
      }
    }
    _endpoints.clear();
  }

  /// 一个打到监听口的请求（测试直接驱动）。
  Future<shelf.Response> handle(shelf.Request request) async {
    final String method = request.method.toUpperCase();
    Uint8List raw = Uint8List(0);
    if (method == 'POST' || method == 'GET') {
      final Uint8List? body = await _readBody(request);
      if (body == null) {
        return shelf.Response(413, body: 'Payload Too Large');
      }
      raw = body;
    }
    final ({String uid, String? key})? route = _route(_keyOf(raw));
    if (route == null) {
      return shelf.Response(
        503,
        body: 'Fushi review is not available on this server',
      );
    }
    final SrsAnkiConnectEndpoint endpoint = _endpointFor(route.uid);
    final int? before = _srs.storeFor(route.uid)?.revision;
    final shelf.Response response = await runZoned(
      () => endpoint.handle(request.change(body: raw)),
      zoneValues: <Object, Object?>{_matchedKeyZone: route.key},
    );
    // 这次请求改了库（addNote / updateNote / 改标签……）：去抖后发出去，别的设备收得到。
    if (_srs.storeFor(route.uid)?.revision != before) {
      _srs.notifyWrite(route.uid);
    }
    return response;
  }

  /// body 里的 `key`（没有 / 不是 JSON → null）。
  static String? _keyOf(Uint8List raw) {
    if (raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(utf8.decode(raw));
      if (decoded is Map) {
        final Object? k = decoded['key'];
        if (k is String && k.isNotEmpty) return k;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// [key] → 去哪份 profile、交给处理器核对的 key。没有可用的 profile → null。
  ({String uid, String? key})? _route(String? key) {
    final ServerAnkiConnectConfig cfg = _config();
    if (key != null) {
      for (final MapEntry<String, String> e in cfg.profileKeys.entries) {
        if (e.value.isNotEmpty && e.value == key) {
          if (_srs.storeFor(e.key) == null) return null;
          return (uid: e.key, key: key);
        }
      }
    }
    final String? def = _srs.defaultProfile?.uid;
    if (def == null) return null;
    // 共用 key 或者不带 key（端点自己限回环）；key 不对时交给处理器按 AnkiConnect 语义回错。
    if (cfg.apiKey.isNotEmpty) return (uid: def, key: cfg.apiKey);
    if (key != null && cfg.hasAnyKey) return (uid: def, key: _kNoSuchKey);
    return (uid: def, key: null);
  }

  /// 配了 profile key 却没有共用 key 时，带了不认识的 key 的请求：处理器拿它核对，必然不等，按 AnkiConnect 回错。
  static const String _kNoSuchKey = '\u0000no-such-key';

  SrsAnkiConnectEndpoint _endpointFor(String uid) =>
      _endpoints[uid] ??= SrsAnkiConnectEndpoint(
        corsOrigins: () {
          final List<String> extra = _config().corsOrigins;
          return extra.isEmpty
              ? kSrsAnkiDefaultCorsOrigins
              : <String>[...kSrsAnkiDefaultCorsOrigins, ...extra];
        },
        handler: SrsAnkiConnectHandler(
          store: () async {
            final SrsDbStore? store = _srs.storeFor(uid);
            if (store == null) {
              throw StateError('Fushi review is not available');
            }
            return store;
          },
          instanceId: instanceId,
          apiKey: () => Zone.current[_matchedKeyZone] as String?,
          profileName: () {
            final String name = _srs.profile(uid)?.name ?? '';
            return name.isEmpty ? uid : name;
          },
          onSync: () => unawaited(_srs.syncNow(uid)),
          mediaSink: (String filename, Uint8List bytes) async {
            final SrsMediaStore? media = _srs.profile(uid)?.media;
            if (media == null) {
              throw StateError('Fushi review is not available');
            }
            final String stored = await media.store(filename, bytes);
            _srs.notifyWrite(uid);
            return stored;
          },
        ),
      );

  static Future<Uint8List?> _readBody(shelf.Request request) async {
    final BytesBuilder b = BytesBuilder(copy: false);
    await for (final List<int> chunk in request.read()) {
      b.add(chunk);
      if (b.length > kServerAnkiConnectMaxBody) return null;
    }
    return b.takeBytes();
  }
}
