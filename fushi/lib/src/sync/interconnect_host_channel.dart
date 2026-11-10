/// 互联 client 到**某一台已配对 host** 的共享请求通道。
///
/// 此前每个互联功能 client（代下载、订阅、AI 助手、任务、漫画 OCR…）各自复制一份
/// 传输层：自己筛候选、取 token、选钉扎、解析错误；超时只包住 `client.send`（响应
/// 体读取不受约束）、自建的 `http.Client` 没有关闭路径、候选按存储顺序试而不选路。
/// 这里把这些收成一份：
///
/// - **成员**：按 [InterconnectHostRef]（hostId；老条目按持久 URL）筛已启用地址，
///   可再叠一层会话绑定 [InterconnectHostBinding]（凭据 / 指纹必须与会话开始时一致）。
/// - **选路**：[rankInterconnectCandidatesDetailed]（可达者优先、未核对的明文地址扣下）。
/// - **凭据**：per-peer token（[interconnectTokenFor]）。
/// - **钉扎**：host 有指纹时，https 只走钉扎 client，明文只放行本进程的 P2P 转发口；
///   被拒的地址一个字节都不发。
/// - **整段超时**：建连 → 响应头 → 读完响应体共用一个 deadline。
/// - **生命周期**：通道建的 client 归通道所有，[InterconnectHostChannel.close] 一并关掉，
///   在途请求以 [InterconnectChannelFailure.cancelled] 收尾。
/// - **错误分型**：[InterconnectChannelException] 的 kind + `mayHaveDelivered`。
///   非幂等请求只发一次，传输失败不换地址重发。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart'
    show InterconnectPostTransport, kInterconnectConnectTimeout;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_engine/sync/interconnect_device_name.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:meta/meta.dart';

/// 一台已配对 host 的身份。选路、凭据、钉扎都按它，不按某一条 URL。
@immutable
final class InterconnectHostRef {
  /// [row] 所属 host：有 hostId 按 hostId；老条目按该行的持久 URL。
  factory InterconnectHostRef.ofRow(FushiClientUrl row) {
    final String anchor = interconnectPersistedUrl(row.url);
    final String? hostId = row.hostId;
    if (hostId == null || hostId.isEmpty) {
      return InterconnectHostRef.legacyUrl(anchor);
    }
    return InterconnectHostRef._(hostId, anchor);
  }

  /// 老条目 ref（仅 URL）。
  const InterconnectHostRef.legacyUrl(this.anchorUrl) : hostId = null;

  const InterconnectHostRef._(this.hostId, this.anchorUrl);

  final String? hostId;

  /// 持久 URL（`p2p://` 而非本次的本地转发口）。
  final String anchorUrl;

  /// `host:<id>` | `url:<anchorUrl>`，与 [groupInterconnectPeers] 的分组键同口径。
  String get key => hostId != null ? 'host:$hostId' : 'url:$anchorUrl';

  /// [row] 是否属于这台 host：hostId 相等；或都无 hostId 且持久 URL 相等。
  bool matches(FushiClientUrl row) {
    final String? rowHostId = row.hostId;
    final bool rowHasId = rowHostId != null && rowHostId.isNotEmpty;
    if (hostId != null) return rowHasId && rowHostId == hostId;
    return !rowHasId && interconnectPersistedUrl(row.url) == anchorUrl;
  }

  @override
  bool operator ==(Object other) =>
      other is InterconnectHostRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'InterconnectHostRef($key)';
}

/// 会话绑定：成员除了属于 [InterconnectHostRef] 之外，有效凭据必须等于 `token`，
/// 老条目（无 hostId）的指纹还必须等于 `fingerprint`。不满足 → notPaired。
typedef InterconnectHostBinding = ({String? token, String? fingerprint});

/// 偏好里存的某条地址 → 那台 host（不在列表 → null）。URL 在列表里唯一。
InterconnectHostRef? interconnectHostRefForUrl(
  Iterable<FushiClientUrl> rows,
  String url,
) {
  final String persisted = interconnectPersistedUrl(url);
  final FushiClientUrl? rep = interconnectPeerRepresentativeOf(rows, persisted);
  return rep == null ? null : InterconnectHostRef.ofRow(rep);
}

/// 每台已启用 host 一个 ref，按组首次出现的顺序。
List<InterconnectHostRef> interconnectPairedHostRefs(
  Iterable<FushiClientUrl> rows,
) => <InterconnectHostRef>[
  for (final FushiClientUrl rep in interconnectPeerRepresentatives(
    rows.where((FushiClientUrl u) => u.enabled),
  ))
    InterconnectHostRef.ofRow(rep),
];

/// 展示名：组内第一个非空 deviceName（同 [interconnectPeerRowName] 口径），
/// 没有 → anchorUrl。
String interconnectHostLabel(
  Iterable<FushiClientUrl> rows,
  InterconnectHostRef host,
) {
  for (final FushiClientUrl u in rows) {
    if (!host.matches(u)) continue;
    final String? name = u.deviceName;
    if (name == null) continue;
    final String readable = interconnectPeerDisplayName(name);
    if (readable.isNotEmpty) return readable;
  }
  return host.anchorUrl;
}

enum InterconnectChannelFailure {
  /// 没有属于这台 host（且满足会话绑定、带凭据）的已启用地址。
  notPaired,

  /// 没有任何地址给出 HTTP 回答（含被扣下的明文地址、整段超时）。
  unreachable,

  /// 能到达的地址全部 401。
  authRejected,

  /// 能到达的地址全部证书不符（或明文地址撞上钉扎），一个请求字节都没发。
  certificateMismatch,

  /// 通道已关闭（调用方 dispose）。
  cancelled,
}

final class InterconnectChannelException implements Exception {
  const InterconnectChannelException(
    this.kind, {
    this.mayHaveDelivered = false,
  });

  final InterconnectChannelFailure kind;

  /// 请求可能已经到达 host 并被执行（写出后传输中断 / 等应答超时）。只有它为
  /// false 时失败才是「确定没送到」，非幂等请求可以放心重发。
  final bool mayHaveDelivered;

  /// no_host / unreachable / auth_rejected / certificate_mismatch / cancelled
  String get code => switch (kind) {
    InterconnectChannelFailure.notPaired => 'no_host',
    InterconnectChannelFailure.unreachable => 'unreachable',
    InterconnectChannelFailure.authRejected => 'auth_rejected',
    InterconnectChannelFailure.certificateMismatch => 'certificate_mismatch',
    InterconnectChannelFailure.cancelled => 'cancelled',
  };

  /// 换地址、过一会儿再试都不会好（凭据 / 证书 / 未配对）。cancelled 与 unreachable
  /// 不算。
  bool get permanent => switch (kind) {
    InterconnectChannelFailure.notPaired ||
    InterconnectChannelFailure.authRejected ||
    InterconnectChannelFailure.certificateMismatch => true,
    InterconnectChannelFailure.unreachable ||
    InterconnectChannelFailure.cancelled => false,
  };

  @override
  String toString() => mayHaveDelivered ? '$code (may have delivered)' : code;
}

/// 本地拒绝：请求会绕过 host 的钉扎。
class InterconnectPinRefused implements Exception {
  const InterconnectPinRefused();
  @override
  String toString() => 'certificate_mismatch';
}

sealed class InterconnectRequestBody {
  const InterconnectRequestBody();

  const factory InterconnectRequestBody.json(Object? value) = _JsonBody;

  const factory InterconnectRequestBody.bytes(
    Uint8List bytes, {
    String contentType,
  }) = _BytesBody;

  /// 流式上传：请求体真正开始写出时才调用 [open] 取流。同一次 [InterconnectHostChannel.send]
  /// 最多调用一次——流一旦打开，通道就不再换地址（大文件上传不重放）。
  const factory InterconnectRequestBody.stream(
    Stream<List<int>> Function() open, {
    int? contentLength,
    String contentType,
  }) = _StreamBody;
}

final class _JsonBody extends InterconnectRequestBody {
  const _JsonBody(this.value);
  final Object? value;
}

final class _BytesBody extends InterconnectRequestBody {
  const _BytesBody(this.bytes, {this.contentType = 'application/octet-stream'});
  final Uint8List bytes;
  final String contentType;
}

final class _StreamBody extends InterconnectRequestBody {
  const _StreamBody(
    this.open, {
    this.contentLength,
    this.contentType = 'application/octet-stream',
  });
  final Stream<List<int>> Function() open;
  final int? contentLength;
  final String contentType;
}

final class InterconnectChannelResponse {
  InterconnectChannelResponse({
    required this.statusCode,
    required this.bodyBytes,
    required this.headers,
    required this.via,
  });

  final int statusCode;
  final Uint8List bodyBytes;
  final Map<String, String> headers;

  /// 本次实际走的地址（可能是 P2P 本地转发口）。
  final FushiClientUrl via;

  String get text => utf8.decode(bodyBytes, allowMalformed: true);

  /// 响应体是 JSON 对象时返回它；空体 / 非 JSON / 非对象 → null。
  Map<String, dynamic>? get jsonObject {
    if (bodyBytes.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// JSON 对象里 [field] 的字符串形式（没有 / 非 JSON → null）。
  String? jsonString(String field) => jsonObject?[field]?.toString();
}

/// 明文请求能否发往钉扎 host：只有本进程存活的 P2P 转发口可以（隧道认 NodeId）。
bool interconnectPlaintextAllowed(Uri uri, {String? pin}) {
  if (pin == null || pin.isEmpty) return true;
  return interconnectPersistedUrl(uri.origin).startsWith('p2p://');
}

/// [baseUrl] + [path] + [query] → 请求 URI（同 `interconnectEndpointUri`，但保留
/// 查询串）。基址畸形或不是 http(s) → null（调用方跳过该候选）。
Uri? interconnectRequestUri(
  String baseUrl,
  String path, [
  Map<String, String> query = const <String, String>{},
]) {
  try {
    final Uri base = Uri.parse(WebDavOps.normalizeUrl(baseUrl));
    if (!base.isScheme('http') && !base.isScheme('https')) return null;
    return base.replace(
      path: path,
      queryParameters: query.isEmpty ? const <String, String>{} : query,
    );
  } on FormatException {
    return null;
  }
}

/// [interconnectRankedCandidates] 的结局：[members] 是筛出的已启用成员（选路前），
/// [ranked] / [withheld] 同 [InterconnectRankedCandidates]，[fallbackToken] 是
/// 全局回落凭据（取 per-peer token 用）。
typedef InterconnectCandidateSelection = ({
  List<FushiClientUrl> members,
  List<FushiClientUrl> ranked,
  int withheld,
  String? fallbackToken,
});

/// 互联 client 的**唯一**候选来源：已启用地址 → 成员筛选 → 组内选路
/// （[rankInterconnectCandidatesDetailed]：可达者优先、未核对的明文地址扣下）。
/// [InterconnectHostChannel]（到某一台 host）与 [InterconnectPostTransport]
/// （跨 host 逐台 fallback）都从这里取候选，不再各写一份筛选。
///
/// - [onlyCandidate]：只留这台 host 的地址（带 hostId 按 host 认，否则按 URL +
///   指纹认），且有效凭据必须等于它的 token——吊销 / 重新配对让会话失效，绝不
///   换到另一个媒体库。
/// - [member]：额外的成员判据（通道按 [InterconnectHostRef] + 会话绑定筛）。
Future<InterconnectCandidateSelection> interconnectRankedCandidates(
  SyncRepository repo, {
  FushiClientUrl? onlyCandidate,
  bool Function(FushiClientUrl row, String? fallbackToken)? member,
  InterconnectAddressProbe? probe,
}) async {
  final List<FushiClientUrl> rows = await repo.getFushiClientUrls();
  final String? fallback = await repo.getFushiClientToken();
  final String? onlyHost = onlyCandidate?.hostId;
  bool keep(FushiClientUrl u) {
    if (!u.enabled) return false;
    if (member != null && !member(u, fallback)) return false;
    if (onlyCandidate == null) return true;
    // 带 hostId 时「只发给这台」认的是 host（凭据仍须一致）：同一台 host 的任一
    // 地址都行，出门后不会因为当初那条 LAN 地址不通就失败。
    final bool sameHost = onlyHost != null
        ? u.hostId == onlyHost
        : u.url == onlyCandidate.url &&
              u.fingerprintSha256 == onlyCandidate.fingerprintSha256;
    return sameHost && interconnectTokenFor(u, fallback) == onlyCandidate.token;
  }

  final List<FushiClientUrl> members = rows.where(keep).toList();
  final InterconnectRankedCandidates ranked =
      await rankInterconnectCandidatesDetailed(
        members,
        probe: probe ?? defaultInterconnectAddressProbe,
      );
  return (
    members: members,
    ranked: ranked.ranked,
    withheld: ranked.withheld,
    fallbackToken: fallback,
  );
}

class InterconnectHostChannel {
  InterconnectHostChannel({
    required SyncRepository repo,
    required this.host,
    InterconnectHostBinding? binding,
    http.Client? plainClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    InterconnectAddressProbe? probe,
  }) : _repo = repo,
       _binding = binding,
       _borrowedPlain = plainClient,
       _pinnedFactory = pinnedClientFactory,
       _probe = probe;

  final SyncRepository _repo;
  final InterconnectHostRef host;
  final InterconnectHostBinding? _binding;

  /// 借用的明文 client：通道不关它。null → 通道首次需要时自建并负责关闭。
  final http.Client? _borrowedPlain;
  http.Client? _ownedPlain;

  /// 建出的 client 归通道所有。null → 默认钉扎 client（能识别证书不符）。
  final http.Client Function(String expectedFingerprint)? _pinnedFactory;
  final InterconnectAddressProbe? _probe;

  /// 按规范化指纹缓存的钉扎 client（全部归通道所有）。
  final Map<String, http.Client> _pinned = <String, http.Client>{};

  /// 默认钉扎 client 的证书回调拒绝过的 `host:port`：握手异常时据此判定「证书
  /// 不符」，与握手中断等传输失败区分开。
  final Set<String> _certRejected = <String>{};

  /// 在途等待的取消回调：[close] 逐个触发；等待结束即注销，长寿通道不攒闭包。
  final Set<void Function()> _onClose = <void Function()>{};
  bool _closed = false;

  bool get isClosed => _closed;

  /// 关掉本通道建的全部 client；在途与之后的 send 一律抛 cancelled。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final void Function() cancel in List<void Function()>.of(_onClose)) {
      cancel();
    }
    _onClose.clear();
    for (final http.Client c in _pinned.values) {
      c.close();
    }
    _pinned.clear();
    _ownedPlain?.close();
    _ownedPlain = null;
  }

  static const InterconnectChannelException _cancelled =
      InterconnectChannelException(InterconnectChannelFailure.cancelled);

  http.Client get _plain => _borrowedPlain ?? (_ownedPlain ??= http.Client());

  http.Client _pinnedClientFor(String fingerprint) {
    final String key = canonicalSha256Fingerprint(fingerprint) ?? fingerprint;
    return _pinned.putIfAbsent(key, () {
      final http.Client Function(String)? factory = _pinnedFactory;
      if (factory != null) return factory(fingerprint);
      final HttpClient inner = createPinnedHttpClient(
        expectedFingerprint: fingerprint,
        connectionTimeout: kInterconnectConnectTimeout,
      );
      inner.badCertificateCallback =
          (X509Certificate cert, String certHost, int port) {
            final bool ok = certificateMatchesFingerprint(cert, fingerprint);
            if (!ok) _certRejected.add('$certHost:$port');
            return ok;
          };
      return IOClient(inner);
    });
  }

  /// 发一次请求。[timeout] 覆盖「建连 → 响应头 → 读完响应体」整段（跨候选共用）。
  /// [idempotent] 缺省 = method 是 GET / HEAD。
  ///
  /// 任何 HTTP 回答（401 除外）都原样返回：那是 host 的回答，换同一台 host 的
  /// 另一条地址只会得到同样的回答。401 换下一条地址（per-peer 凭据）。
  Future<InterconnectChannelResponse> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    InterconnectRequestBody? body,
    required Duration timeout,
    bool? idempotent,
  }) async {
    if (_closed) throw _cancelled;
    final Stopwatch clock = Stopwatch()..start();
    final String upper = method.toUpperCase();
    final bool isIdempotent = idempotent ?? (upper == 'GET' || upper == 'HEAD');

    final InterconnectHostBinding? binding = _binding;
    final InterconnectCandidateSelection ranked =
        await interconnectRankedCandidates(
          _repo,
          member: (FushiClientUrl u, String? fallback) =>
              host.matches(u) &&
              (binding == null ||
                  (interconnectTokenFor(u, fallback) == binding.token &&
                      (host.hostId != null ||
                          u.fingerprintSha256 == binding.fingerprint))),
          probe: _probe,
        );
    if (_closed) throw _cancelled;
    final List<FushiClientUrl> members = ranked.members;
    final String? fallback = ranked.fallbackToken;
    if (members.isEmpty) {
      throw const InterconnectChannelException(
        InterconnectChannelFailure.notPaired,
      );
    }
    // 会话绑定了指纹时以它为准（会话开始时配对的那张证书）：同组学到的另一张
    // 证书的地址一律本地拒绝，不能借选路换掉会话的钉扎。
    String? pin = binding?.fingerprint;
    if (pin == null || pin.isEmpty) {
      pin = null;
      for (final FushiClientUrl u in members) {
        final String? fp = u.fingerprintSha256;
        if (fp != null && fp.isNotEmpty) {
          pin = fp;
          break;
        }
      }
    }

    bool hadCredential = false;
    bool authRejected = false;
    bool sentTimedOut = false;
    bool bodyFailed = false;
    int certMismatch = 0;
    int localPinRefusal = 0;
    // 流式请求体一旦打开就不再换地址（见 [InterconnectRequestBody.stream]）。
    bool streamOpened = false;

    for (final FushiClientUrl c in ranked.ranked) {
      if (_closed) throw _cancelled;
      final Duration remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) break;
      final Uri? uri = interconnectRequestUri(c.url, path, query);
      final String? token = interconnectTokenFor(c, fallback);
      if (uri == null || token == null) continue;
      hadCredential = true;

      // 本地钉扎闸：不发出任何字节。
      final String? fp = c.fingerprintSha256;
      final http.Client client;
      if (uri.isScheme('https') && fp != null && fp.isNotEmpty) {
        if (pin != null && !fingerprintEquals(fp, pin)) {
          localPinRefusal++;
          continue;
        }
        client = _pinnedClientFor(fp);
      } else {
        if (!interconnectPlaintextAllowed(uri, pin: pin)) {
          localPinRefusal++;
          continue;
        }
        client = _plain;
      }

      final Completer<void> abort = Completer<void>();
      final http.BaseRequest req = _buildRequest(
        upper,
        uri,
        token,
        body,
        abort.future,
        onStreamOpened: () => streamOpened = true,
      );

      final http.StreamedResponse streamed;
      try {
        streamed = await _guard(client.send(req), remaining, abort);
      } on Object catch (e) {
        if (_closed) throw _cancelled;
        final String endpoint = '${uri.host}:${uri.port}';
        if (e is InterconnectPinRefused ||
            (e is TlsException && _certRejected.remove(endpoint))) {
          // 握手阶段被拒：一个请求字节都没发出，幂等与否都可以换下一条。
          certMismatch++;
          if (streamOpened) break;
          continue;
        }
        if (!isIdempotent) {
          throw const InterconnectChannelException(
            InterconnectChannelFailure.unreachable,
            mayHaveDelivered: true,
          );
        }
        if (e is TimeoutException) sentTimedOut = true;
        continue;
      }

      final Uint8List bytes;
      try {
        bytes = await _readBody(streamed.stream, timeout - clock.elapsed);
      } on Object {
        if (!abort.isCompleted) abort.complete();
        if (_closed) throw _cancelled;
        if (!isIdempotent) {
          throw const InterconnectChannelException(
            InterconnectChannelFailure.unreachable,
            mayHaveDelivered: true,
          );
        }
        bodyFailed = true;
        continue;
      }
      if (_closed) throw _cancelled;

      if (streamed.statusCode == 401) {
        // 401 在处理器之前就拒绝了：非幂等也可以换下一条（per-peer 凭据）。
        authRejected = true;
        if (streamOpened) break;
        continue;
      }
      return InterconnectChannelResponse(
        statusCode: streamed.statusCode,
        bodyBytes: bytes,
        headers: streamed.headers,
        via: c,
      );
    }

    if (authRejected) {
      throw const InterconnectChannelException(
        InterconnectChannelFailure.authRejected,
      );
    }
    if (certMismatch + localPinRefusal > 0) {
      throw const InterconnectChannelException(
        InterconnectChannelFailure.certificateMismatch,
      );
    }
    if (!hadCredential && ranked.withheld == 0) {
      // 有成员但没有一条带得出凭据 / 拼得出地址：等同未配对。
      throw const InterconnectChannelException(
        InterconnectChannelFailure.notPaired,
      );
    }
    throw InterconnectChannelException(
      InterconnectChannelFailure.unreachable,
      mayHaveDelivered: sentTimedOut || bodyFailed,
    );
  }

  http.BaseRequest _buildRequest(
    String method,
    Uri uri,
    String token,
    InterconnectRequestBody? body,
    Future<void> abortTrigger, {
    required void Function() onStreamOpened,
  }) {
    final Map<String, String> headers = <String, String>{
      'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
    };
    switch (body) {
      case _StreamBody(:final open, :final contentLength, :final contentType):
        return _LazyStreamRequest(
            method,
            uri,
            abortTrigger: abortTrigger,
            open: () {
              onStreamOpened();
              return open();
            },
          )
          ..followRedirects = false
          ..contentLength = contentLength
          ..headers.addAll(headers)
          ..headers['Content-Type'] = contentType;
      case _JsonBody(:final value):
        return http.AbortableRequest(method, uri, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(value);
      case _BytesBody(:final bytes, :final contentType):
        return http.AbortableRequest(method, uri, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..headers['Content-Type'] = contentType
          ..bodyBytes = bytes;
      case null:
        return http.AbortableRequest(method, uri, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..headers.addAll(headers);
    }
  }

  /// [future] 限时 [remaining]，并与通道关闭赛跑。超时 / 关闭时触发 [abort]
  /// （支持 Abortable 的 client 会真的中止连接），被丢下的 future 的错误吞掉不外溢。
  Future<T> _guard<T>(
    Future<T> future,
    Duration remaining,
    Completer<void> abort,
  ) {
    final Completer<T> out = Completer<T>();
    late final Timer timer;
    late final void Function() onClose;
    void settle(void Function() complete) {
      if (out.isCompleted) return;
      timer.cancel();
      _onClose.remove(onClose);
      complete();
    }

    void interrupt(Object error) => settle(() {
      if (!abort.isCompleted) abort.complete();
      out.completeError(error);
    });

    onClose = () => interrupt(_cancelled);
    _onClose.add(onClose);
    timer = Timer(
      remaining,
      () => interrupt(TimeoutException('interconnect request', remaining)),
    );
    future.then(
      (T value) {
        if (out.isCompleted) {
          // 已超时 / 已取消后才到的响应：丢掉它的响应体，释放连接。
          if (value is http.StreamedResponse) {
            value.stream.listen(null).cancel().ignore();
          }
          return;
        }
        settle(() => out.complete(value));
      },
      onError: (Object e, StackTrace st) =>
          settle(() => out.completeError(e, st)),
    );
    return out.future;
  }

  /// 读完响应体，受剩余 deadline 与通道关闭约束；超时 / 关闭时取消订阅释放连接。
  Future<Uint8List> _readBody(Stream<List<int>> stream, Duration remaining) {
    if (remaining <= Duration.zero) {
      stream.listen(null).cancel().ignore();
      return Future<Uint8List>.error(
        TimeoutException('interconnect response body', remaining),
      );
    }
    final Completer<Uint8List> out = Completer<Uint8List>();
    final BytesBuilder builder = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> sub;
    late final Timer timer;
    late final void Function() onClose;
    void settle(void Function() complete) {
      if (out.isCompleted) return;
      timer.cancel();
      _onClose.remove(onClose);
      complete();
    }

    void fail(Object error, [StackTrace? st]) => settle(() {
      sub.cancel().ignore();
      out.completeError(error, st);
    });

    onClose = () => fail(_cancelled);
    _onClose.add(onClose);
    timer = Timer(
      remaining,
      () => fail(TimeoutException('interconnect response body', remaining)),
    );
    sub = stream.listen(
      builder.add,
      onError: fail,
      onDone: () => settle(() => out.complete(builder.takeBytes())),
    );
    return out.future;
  }
}

/// 请求体在 client 真正开始写出时才调用 [open] 取流（握手被拒的候选不会打开流）。
final class _LazyStreamRequest extends http.BaseRequest with http.Abortable {
  _LazyStreamRequest(
    super.method,
    super.url, {
    required this.abortTrigger,
    required Stream<List<int>> Function() open,
  }) : _open = open;

  @override
  final Future<void>? abortTrigger;

  final Stream<List<int>> Function() _open;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_deferred());
  }

  Stream<List<int>> _deferred() async* {
    yield* _open();
  }
}

/// host 上某项能力的探测失败原因。
enum InterconnectHostFailure {
  notPaired,
  unreachable,
  authRejected,
  certificateMismatch,

  /// host 没宣告该能力（老 host / 能力关着）。
  unsupported,

  /// host 回了非 200 / 非 JSON 的能力表。
  httpError,
}

sealed class InterconnectCapabilityOutcome<T> {
  const InterconnectCapabilityOutcome({
    required this.host,
    required this.label,
  });
  final InterconnectHostRef host;
  final String label;
}

final class InterconnectCapabilityAvailable<T>
    extends InterconnectCapabilityOutcome<T> {
  const InterconnectCapabilityAvailable({
    required super.host,
    required super.label,
    required this.target,
  });
  final T target;
}

final class InterconnectCapabilityUnavailable<T>
    extends InterconnectCapabilityOutcome<T> {
  const InterconnectCapabilityUnavailable({
    required super.host,
    required super.label,
    required this.failure,
    this.statusCode,
  });
  final InterconnectHostFailure failure;
  final int? statusCode;
}

/// `GET /api/capabilities`；[parse] 返回 null = host 没宣告该能力 → unsupported。
/// 通道已关闭（cancelled）原样重抛。
Future<InterconnectCapabilityOutcome<T>> probeInterconnectCapability<T>(
  InterconnectHostChannel channel, {
  required String label,
  required T? Function(Map<String, dynamic> caps, FushiClientUrl via) parse,
  required Duration timeout,
}) async {
  InterconnectCapabilityOutcome<T> unavailable(
    InterconnectHostFailure failure, [
    int? statusCode,
  ]) => InterconnectCapabilityUnavailable<T>(
    host: channel.host,
    label: label,
    failure: failure,
    statusCode: statusCode,
  );

  final InterconnectChannelResponse response;
  try {
    response = await channel.send('GET', '/api/capabilities', timeout: timeout);
  } on InterconnectChannelException catch (e) {
    return switch (e.kind) {
      InterconnectChannelFailure.cancelled => throw e,
      InterconnectChannelFailure.notPaired => unavailable(
        InterconnectHostFailure.notPaired,
      ),
      InterconnectChannelFailure.unreachable => unavailable(
        InterconnectHostFailure.unreachable,
      ),
      InterconnectChannelFailure.authRejected => unavailable(
        InterconnectHostFailure.authRejected,
      ),
      InterconnectChannelFailure.certificateMismatch => unavailable(
        InterconnectHostFailure.certificateMismatch,
      ),
    };
  }
  final int status = response.statusCode;
  if (status == 404 || status == 405) {
    return unavailable(InterconnectHostFailure.unsupported);
  }
  if (status != 200) {
    return unavailable(InterconnectHostFailure.httpError, status);
  }
  final Map<String, dynamic>? caps = response.jsonObject;
  if (caps == null) return unavailable(InterconnectHostFailure.httpError, 200);
  final T? target = parse(caps, response.via);
  if (target == null) return unavailable(InterconnectHostFailure.unsupported);
  return InterconnectCapabilityAvailable<T>(
    host: channel.host,
    label: label,
    target: target,
  );
}
