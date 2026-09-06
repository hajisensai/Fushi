import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 单词音频短命 token：`/api/lookup/audio` 存字节、返回免鉴权的
/// `/api/lookup/audio/file?id=` URL；命中即续期，TTL 内无访问后 prune。
///
/// `createdAt` 不是 final——每次被 [RemoteAudioTokenStore.take] 命中都刷新，重置
/// 过期窗口，使「正在被访问」的音频 token 不会在使用途中过期（TODO-766）。
class RemoteAudioToken {
  RemoteAudioToken({
    required this.bytes,
    required this.contentType,
    required this.createdAt,
  });

  final Uint8List bytes;
  final String contentType;
  DateTime createdAt;
}

/// 音频 token 的签发 / 取用 / 过期 / 上限，[FushiSyncServer] 与 [YomitanApiServer]
/// 共用一份（原本两边各一份「同款模型」，且只有前者修了 BUG-908(a) 的上限）。
///
/// * TTL prune：[ttl] 内无访问的 token 被清掉；签发与取用前都先 prune。
/// * 上限（BUG-908(a)）：prune 后仍达到 [maxTokens] 时按 createdAt 淘汰最旧者，
///   使插入新 token 后总数 <= [maxTokens]。只 POST 不 GET 的调用者再也撑不爆内存。
/// * [now] 可注入，测试用固定时钟验证 TTL 与逐出。
class RemoteAudioTokenStore {
  RemoteAudioTokenStore({
    DateTime Function()? now,
    this.maxTokens = 128,
    this.ttl = const Duration(minutes: 5),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final int maxTokens;
  final Duration ttl;
  final Map<String, RemoteAudioToken> _tokens = <String, RemoteAudioToken>{};

  /// 当前驻留的 token 数（验证 cap 逐出行为的测试钩子）。
  int get count => _tokens.length;

  /// 签发一个不可猜的 id 并存入字节；先 prune 再收束上限。
  String mint(Uint8List bytes, String contentType) {
    prune();
    _enforceCap();
    final String id = _generateId();
    _tokens[id] = RemoteAudioToken(
      bytes: bytes,
      contentType: contentType,
      createdAt: _now(),
    );
    return id;
  }

  /// 取 [id] 对应的 token；命中即续期。未命中 / [id] 为空返回 null。
  RemoteAudioToken? take(String? id) {
    prune();
    final RemoteAudioToken? token = id == null ? null : _tokens[id];
    if (token != null) token.createdAt = _now();
    return token;
  }

  /// 清掉 [ttl] 之前最后一次被访问的 token。
  void prune() {
    final DateTime cutoff = _now().subtract(ttl);
    _tokens.removeWhere(
      (String _, RemoteAudioToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  void _enforceCap() {
    while (_tokens.length >= maxTokens) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, RemoteAudioToken> e in _tokens.entries) {
        if (oldestAt == null || e.value.createdAt.isBefore(oldestAt)) {
          oldestAt = e.value.createdAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _tokens.remove(oldestKey);
    }
  }

  static String _generateId() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}

/// 读请求体为 JSON object；非法 JSON / 空体 / 非 object 一律 null，由调用方回 400。
Future<Map<String, dynamic>?> readJsonObjectBody(shelf.Request request) async {
  try {
    final String raw = await request.readAsString();
    if (raw.isEmpty) return null;
    final dynamic decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    // 客户端请求体非法 JSON：当作无 body 处理。
  }
  return null;
}

/// 200 + `application/json; charset=utf-8`。
///
/// TODO-752a：必须带 charset=utf-8。否则远程查词 client 用 package:http 的 `.body`
/// 读取时按 latin1 默认解码，CJK 词典义项/书名直接乱码。[extraHeaders] 铺在前面，
/// Content-Type 不可被覆盖。
shelf.Response jsonRawResponse(
  String body, {
  Map<String, String> extraHeaders = const <String, String>{},
}) =>
    shelf.Response.ok(
      body,
      headers: <String, String>{
        ...extraHeaders,
        'Content-Type': 'application/json; charset=utf-8',
      },
    );

shelf.Response jsonResponse(Object body) => jsonRawResponse(jsonEncode(body));

/// 两台 HTTP 服务器（互联 host [FushiSyncServer]、浏览器扩展 [YomitanApiServer]）
/// 共同服务的查词/制卡端点的 handler 正文。payload 契约本就共享在
/// `fushi_remote_api_handlers.dart`（BUG-530 单一真相源）；这里再把「读体 → 404/400
/// 门 → 调 builder → JSON 信封」这层壳也收成一份。
///
/// **不在这里的东西**（两边有真实差异，各留各的）：路由分发与 405 门、鉴权、
/// `/api/lookup/dictionary`（扩展侧多下发主题/音频源/自动朗读/扩展版本/弹窗 CSS）、
/// `/api/extension/status`（扩展侧上报扩展版本）、互联独有的 `/api/anki/media/dedup/*`
/// 与 `/api/media/dictionary`。
class RemoteLookupRoutes {
  RemoteLookupRoutes({
    required this.audioTokens,
    this.lookup,
    this.mining,
  });

  final RemoteAudioTokenStore audioTokens;
  final FushiRemoteLookupService? lookup;
  final FushiRemoteMiningService? mining;

  /// 单词音频①：查到字节就签发 token，返回免鉴权的取字节 URL；未命中返回
  /// `{url:null}`（弹窗降级为 ✕）。
  Future<shelf.Response> handleAudioLookup(shelf.Request request) async {
    final FushiRemoteLookupService? service = lookup;
    if (service == null) return shelf.Response.notFound('Remote lookup off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');

    final String expression = body['expression']?.toString() ?? '';
    final String reading = body['reading']?.toString() ?? '';
    if (expression.trim().isEmpty) return _audioMissResponse();

    final RemoteAudioLookup? found = await service.lookupAudio(
      expression: expression,
      reading: reading,
    );
    if (found == null) return _audioMissResponse();

    final String id = audioTokens.mint(found.bytes, found.contentType);
    final Uri url = request.requestedUri.replace(
      path: '/api/lookup/audio/file',
      queryParameters: <String, String>{'id': id},
    );
    return jsonResponse(<String, dynamic>{
      'type': 'audioResult',
      'url': url.toString(),
      'contentType': found.contentType,
    });
  }

  /// 单词音频②：GET/HEAD `?id=` 取字节（免鉴权，靠不可猜 id）；命中即续期。
  shelf.Response handleAudioFile(shelf.Request request,
      {required bool headOnly}) {
    final RemoteAudioToken? token =
        audioTokens.take(request.url.queryParameters['id']);
    if (token == null) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      headOnly ? null : token.bytes,
      headers: <String, String>{
        'Content-Type': token.contentType,
        'Content-Length': '${token.bytes.length}',
      },
    );
  }

  shelf.Response _audioMissResponse() => jsonResponse(<String, dynamic>{
        'type': 'audioResult',
        'url': null,
        'contentType': null,
      });

  /// 制卡（BUG-530）。未注入挖词 service → 404；fields 缺失/类型错 → 400。
  Future<shelf.Response> handleMine(shelf.Request request) async {
    final FushiRemoteMiningService? svc = mining;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    try {
      return jsonResponse(await buildRemoteMineResponse(
        body,
        mining: svc,
        wordAudio: _resolveMineWordAudio,
      ));
    } on FormatException {
      return shelf.Response(400, body: 'Missing fields');
    }
  }

  /// BUG-2189：制卡时把 `fields.audio` 里本机签发的短命 token 换成自包含 `data:` URI
  /// （见 [resolveRemoteMineWordAudio]）。token 仍活 → 直接取字节；已被 prune（批量
  /// 队列几十分钟后才生成）→ 按 expression/reading 重走同一条 [lookupAudio]。
  /// 音频库没这个词 → null，调用方保留原引用让既有 404 诊断浮出。
  Future<String?> _resolveMineWordAudio(
    String tokenId, {
    required String expression,
    required String reading,
  }) async {
    final RemoteAudioToken? token = audioTokens.take(tokenId);
    if (token != null) {
      return remoteAudioLookupToDataUri(RemoteAudioLookup(
        bytes: token.bytes,
        contentType: token.contentType,
      ));
    }
    final FushiRemoteLookupService? service = lookup;
    if (service == null || expression.trim().isEmpty) return null;
    final RemoteAudioLookup? found = await service.lookupAudio(
      expression: expression,
      reading: reading,
    );
    return found == null ? null : remoteAudioLookupToDataUri(found);
  }

  /// 「制卡到服务端」：客户端转发未渲染的制卡请求 + 全部媒体字节，本机用自己的
  /// Anki 配置落卡。rawPayloadJson 缺失/类型错 → 400；未注入挖词 service → 404。
  Future<shelf.Response> handleMineForward(shelf.Request request) async {
    final FushiRemoteMiningService? svc = mining;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    try {
      return jsonResponse(await buildForwardedMineResponse(body, mining: svc));
    } on FormatException {
      return shelf.Response(400, body: 'Missing rawPayloadJson');
    }
  }

  /// Lapis 客制化：客户端（手机 AnkiDroid 等无模板 API 的平台）读写本机 Anki 的
  /// note type（读定义 / 写 styling / 写卡模板）。未注入挖词 service → 404（旧版主机
  /// 对新客户端返回 404 → 客户端按「后端不支持」降级）；modelName/css/templates
  /// 缺失或类型错 → 400；[path] 不是三者之一 → 404。
  Future<shelf.Response> handleAnkiNoteType(
    shelf.Request request,
    String path,
  ) async {
    final FushiRemoteMiningService? svc = mining;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    try {
      switch (path) {
        case '/api/anki/note-type/read':
          return jsonResponse(
              await buildAnkiNoteTypeReadResponse(body, mining: svc));
        case '/api/anki/note-type/styling':
          return jsonResponse(
              await buildAnkiNoteTypeStylingResponse(body, mining: svc));
        case '/api/anki/note-type/templates':
          return jsonResponse(
              await buildAnkiNoteTypeTemplatesResponse(body, mining: svc));
        default:
          return shelf.Response.notFound('Unknown endpoint');
      }
    } on FormatException catch (e) {
      return shelf.Response(400, body: e.message);
    }
  }

  /// TODO-1176：查词弹窗制卡按钮真查重（`+`→`✓`）。未注入挖词 service 时返回
  /// `{duplicate:false}`（弹窗降级为「+」，绝不阻断查词）；读体在判 service 之前，
  /// 故非法 JSON 的 400 优先于降级。
  Future<shelf.Response> handleDuplicate(shelf.Request request) async {
    final FushiRemoteMiningService? svc = mining;
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    if (svc == null) {
      return jsonResponse(<String, dynamic>{'duplicate': false});
    }
    return jsonResponse(await buildRemoteDuplicateResponse(body, mining: svc));
  }
}
