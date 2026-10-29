import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin_ffi.dart';
import 'plugin_models.dart';

/// 插件日志出口（宿主接到 app 日志；插件日志是不可信文本，只当诊断看）。
typedef MusicPluginLogSink =
    void Function(String pluginId, String level, String message);

/// 出站 HTTP 客户端工厂：app 传 `createAppHttpClient`（走全应用代理装配）。
typedef MusicPluginHttpClientFactory = HttpClient Function();

/// 替换整个 HTTP 执行（测试用：本地假服务在回环地址上，正常路径会按私网拒绝）。参数与返回值同
/// [performMusicPluginHttp]。
typedef MusicPluginHttpPerformer =
    Future<Map<String, Object?>> Function(Map<String, Object?> args);

/// 一个运行中的插件实例：把 Rust 的步进式驱动（docs/specs/2026-10-28-music-plugins.md §3）
/// 包成 `Future` 调用，并执行插件发出的宿主调用（http / storage）。
///
/// 同一实例的 FFI 调用严格串行（[_pump] 单线推进）；能力调用之间可以交错等待网络。
/// 运行时被终止（CPU 超预算等）后实例作废：未完成与之后的调用都以 [MusicPluginException] 失败，
/// 由 [MusicPluginManager] 丢弃并在下次使用时重建。
class MusicPluginInstance {
  MusicPluginInstance._({
    required this.info,
    required int handle,
    required MusicPluginHttpClientFactory httpClientFactory,
    required File storageFile,
    required MusicPluginLogSink log,
    required String vaultRoot,
    MusicPluginHttpPerformer? httpPerformer,
  }) : _handle = handle,
       _vaultRoot = vaultRoot,
       _httpPerformer = httpPerformer,
       _httpClientFactory = httpClientFactory,
       _storageFile = storageFile,
       _log = log;

  /// 打开已安装目录 [dir]（重新哈希校验 + 建 JS 实例）。失败抛 [MusicPluginException]。
  static Future<MusicPluginInstance> open({
    required String dir,
    required File storageFile,
    required MusicPluginHttpClientFactory httpClientFactory,
    required MusicPluginLogSink log,
    required String vaultRoot,
    int budgetMs = 2000,
    MusicPluginHttpPerformer? httpPerformer,
  }) async {
    final ({int handle, Map<String, Object?> summary}) r =
        await MusicPluginNativeAsync.open(dir, budgetMs);
    final Object? error = r.summary['error'];
    if (error is String || r.handle == 0) {
      throw MusicPluginException('$error');
    }
    return MusicPluginInstance._(
      info: MusicPluginPackageInfo.fromJson(r.summary),
      handle: r.handle,
      httpClientFactory: httpClientFactory,
      storageFile: storageFile,
      log: log,
      vaultRoot: vaultRoot,
      httpPerformer: httpPerformer,
    );
  }

  final MusicPluginPackageInfo info;
  int _handle;
  final MusicPluginHttpClientFactory _httpClientFactory;
  final File _storageFile;
  final MusicPluginLogSink _log;
  final MusicPluginHttpPerformer? _httpPerformer;

  /// 凭据保险库根目录（插件根目录；文件在其下 `.credentials/`）。
  final String _vaultRoot;

  int _nextInv = 0;
  final Map<int, Completer<Object?>> _invocations = <int, Completer<Object?>>{};
  final List<Map<String, Object?>> _queue = <Map<String, Object?>>[];
  bool _pumping = false;
  String? _fatal;
  Map<String, String>? _storage;

  String get id => info.manifest.id;
  bool get isAlive => _fatal == null && _handle != 0;

  /// 本实例复用的出站客户端（同一插件连续请求同一主机时复用连接）。
  HttpClient? _client;

  /// 调一个能力。插件抛错 / 返回值无法解析 / 实例被终止都抛 [MusicPluginException]；超过
  /// [timeout]（缺省按能力取 [musicPluginInvokeTimeout]）抛 [MusicPluginTimeoutException]，
  /// 该次调用作废（之后插件再 settle 也只是被丢弃）。
  Future<Object?> invoke(
    String method,
    Map<String, Object?> args, {
    Duration? timeout,
  }) {
    if (!isAlive) {
      return Future<Object?>.error(
        MusicPluginException(_fatal ?? '插件已关闭', pluginId: id),
      );
    }
    final int inv = ++_nextInv;
    final Completer<Object?> c = Completer<Object?>();
    _invocations[inv] = c;
    final Duration limit = timeout ?? musicPluginInvokeTimeout(method);
    final Timer timer = Timer(limit, () {
      // 只作废仍在途的这一次：已 settle / 实例已死时 Completer 早已移出。
      if (!identical(_invocations[inv], c)) return;
      _invocations.remove(inv);
      _log(id, 'warn', '$method 超过 ${limit.inSeconds} 秒未返回，已作废');
      c.completeError(
        MusicPluginTimeoutException(
          '插件 $method 超时（${limit.inSeconds} 秒）',
          pluginId: id,
          method: method,
          timeout: limit,
        ),
      );
    });
    _queue.add(<String, Object?>{
      'op': 'invoke',
      'inv': inv,
      'method': method,
      'args': args,
    });
    unawaited(_pump());
    return c.future.whenComplete(timer.cancel);
  }

  /// 按插件网络授权核对登录页 / App 确认链接（与插件自己的请求同一判据）。返回
  /// 「原地址 → 规范化地址」，不在授权内的不出现在结果里。
  Map<String, String> checkRequestUrls(Iterable<String> urls) {
    if (!isAlive) return const <String, String>{};
    final List<String> list = urls.toSet().toList();
    final List<String?> checked = MusicPluginNative.checkUrls(
      _handle,
      list,
      media: false,
    );
    return <String, String>{
      for (int i = 0; i < list.length; i++)
        if (checked[i] case final String ok) list[i]: ok,
    };
  }

  /// 按插件网络授权批量核对插件交给宿主的媒体地址（流 / 封面），一次 FFI。返回
  /// 「原地址 → 规范化地址」，不在授权内的不出现在结果里。
  Map<String, String> checkMediaUrls(Iterable<String> urls) {
    if (!isAlive) return const <String, String>{};
    final List<String> list = urls.toSet().toList();
    final List<String?> checked = MusicPluginNative.checkUrls(
      _handle,
      list,
      media: true,
    );
    return <String, String>{
      for (int i = 0; i < list.length; i++)
        if (checked[i] case final String ok) list[i]: ok,
    };
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && isAlive) {
        final List<Map<String, Object?>> ops = List<Map<String, Object?>>.of(
          _queue,
        );
        _queue.clear();
        final Map<String, Object?> out = await MusicPluginNativeAsync.step(
          _handle,
          jsonEncode(ops),
        );
        _consume(out);
      }
    } catch (e) {
      _die('插件运行时出错：$e');
    } finally {
      _pumping = false;
      _releaseIfIdle();
    }
  }

  void _consume(Map<String, Object?> out) {
    for (final Object? l
        in (out['logs'] as List<Object?>?) ?? const <Object?>[]) {
      final Map<Object?, Object?> m = l! as Map<Object?, Object?>;
      _log(id, '${m['level']}', '${m['message']}');
    }
    for (final Object? s
        in (out['settled'] as List<Object?>?) ?? const <Object?>[]) {
      final Map<Object?, Object?> m = s! as Map<Object?, Object?>;
      final Completer<Object?>? c = _invocations.remove(
        (m['inv']! as num).toInt(),
      );
      if (c == null) continue;
      if (m['ok'] == true) {
        c.complete(m['value']);
      } else {
        // 完整错误（含 JS 堆栈）只进日志；异常里只留给用户看的第一行。
        final String full = '${m['error']}';
        _log(id, 'error', full);
        c.completeError(
          MusicPluginException(musicPluginErrorSummary(full), pluginId: id),
        );
      }
    }
    for (final Object? call
        in (out['calls'] as List<Object?>?) ?? const <Object?>[]) {
      final Map<String, Object?> m = (call! as Map<Object?, Object?>)
          .cast<String, Object?>();
      unawaited(_runHostCall(m));
    }
    final Object? fatal = out['fatal'] ?? out['error'];
    if (fatal is String) _die(fatal);
  }

  Future<void> _runHostCall(Map<String, Object?> call) async {
    final int id = (call['id']! as num).toInt();
    final Map<String, Object?> args = (call['args']! as Map<Object?, Object?>)
        .cast<String, Object?>();
    Map<String, Object?> op;
    try {
      final Object? value = switch (call['op']) {
        'http' => await _http(args),
        'storage.get' => await _serialStorage(
          () async => (await _loadStorage())[args['key']],
        ),
        'storage.set' => await _serialStorage(
          () => _storageWrite(args['key']! as String, args['value']! as String),
        ),
        'storage.remove' => await _serialStorage(
          () => _storageWrite(args['key']! as String, null),
        ),
        'credentials.get' => await _vault('get', args),
        'credentials.set' => await _vault('set', args),
        'credentials.remove' => await _vault('remove', args),
        final Object? other => throw StateError('未知宿主调用 $other'),
      };
      op = <String, Object?>{
        'op': 'complete',
        'call': id,
        'ok': true,
        'value': value,
      };
    } catch (e) {
      op = <String, Object?>{
        'op': 'complete',
        'call': id,
        'ok': false,
        'error': e is MusicPluginHttpException ? e.message : '$e',
      };
    }
    if (!isAlive) return;
    _queue.add(op);
    unawaited(_pump());
  }

  Future<Map<String, Object?>> _http(Map<String, Object?> args) =>
      _httpPerformer?.call(args) ??
      performMusicPluginHttp(
        args,
        client: _client ??= _httpClientFactory(),
        checkRedirect: (String url) => MusicPluginNative.checkUrls(
          _handle,
          <String>[url],
          media: false,
        ).single,
      );

  Future<Object?> _vault(String op, Map<String, Object?> args) async {
    final Map<String, Object?> r = await MusicPluginNativeAsync.vault(
      _vaultRoot,
      // 显式取字段，绝不展开插件给的参数：`op` / `plugin` 必须是宿主自己的值，否则插件在参数里
      // 塞 `plugin: <别的插件 id>` 就能读写别人的凭据（Rust 侧 check_credentials 也只放行
      // key / value，这里再守一道）。
      <String, Object?>{
        'op': op,
        'plugin': id,
        'key': args['key'],
        if (op == 'set') 'value': args['value'],
      },
    );
    if (r['error'] case final String e) throw StateError(e);
    return r['value'];
  }

  /// 插件存储操作串行化：宿主调用并发执行（插件可以一次发出多个 storage 调用），首次加载
  /// 与写盘若交错，会出现两份内存副本互相覆盖、同一个 .tmp 被并发写 / rename 的竞态。
  Future<Object?> _storageTail = Future<Object?>.value();
  int _storageWrites = 0;

  Future<Object?> _serialStorage(Future<Object?> Function() op) {
    final Future<Object?> run = _storageTail.then<Object?>((_) => op());
    // 链尾只用来排队：本次失败不传给下一次（失败照样经 [run] 交回插件）。
    _storageTail = run.then<Object?>((_) => null, onError: (Object _) => null);
    return run;
  }

  Future<Map<String, String>> _loadStorage() async {
    final Map<String, String>? cached = _storage;
    if (cached != null) return cached;
    Map<String, String> data = <String, String>{};
    try {
      if (_storageFile.existsSync()) {
        data =
            (jsonDecode(await _storageFile.readAsString())
                    as Map<Object?, Object?>)
                .map(
                  (Object? k, Object? v) =>
                      MapEntry<String, String>('$k', '$v'),
                );
      }
    } on FormatException {
      data = <String, String>{};
    }
    return _storage = data;
  }

  Future<Object?> _storageWrite(String key, String? value) async {
    final Map<String, String> data = await _loadStorage();
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    // 整个插件存储上限 4 MiB：防止插件把磁盘写满。
    final String encoded = jsonEncode(data);
    if (encoded.length > 4 * 1024 * 1024) {
      if (value != null) data.remove(key);
      throw StateError('插件存储超过 4 MiB');
    }
    await _storageFile.parent.create(recursive: true);
    // 临时文件名每次唯一：同一插件的新旧实例（重建交接期）不会共用一个 .tmp。
    final File tmp = File(
      '${_storageFile.path}.$pid.${identityHashCode(this)}.${++_storageWrites}.tmp',
    );
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(_storageFile.path);
    return null;
  }

  void _die(String reason) {
    if (_fatal != null) return;
    _fatal = reason;
    for (final Completer<Object?> c in _invocations.values) {
      c.completeError(MusicPluginException(reason, pluginId: id));
    }
    _invocations.clear();
    _queue.clear();
    _releaseIfIdle();
  }

  /// 原生句柄只在没有 step 在后台执行时释放（[_pump] 结束时会再调一次）。
  void _releaseIfIdle() {
    if (_fatal == null || _pumping || _handle == 0) return;
    MusicPluginNative.close(_handle);
    _handle = 0;
    _client?.close(force: true);
    _client = null;
    final Completer<void>? idle = _idle;
    _idle = null;
    idle?.complete();
  }

  Completer<void>? _idle;

  /// 关闭实例；未完成的调用以异常结束。等正在执行的 step 返回后释放原生句柄。
  Future<void> close() {
    if (_handle == 0) return Future<void>.value();
    final Completer<void> idle = _idle ??= Completer<void>();
    _die('插件已关闭');
    return idle.future;
  }
}

/// 取流的墙钟时限：播放路径在等它，超时即按取流失败处理（跳下一首）。
const Duration kMusicPluginStreamTimeout = Duration(seconds: 30);

/// 其余能力调用的墙钟时限（搜索 / 详情 / 登录轮询一步等）。
const Duration kMusicPluginInvokeTimeout = Duration(seconds: 60);

/// 能力 → 墙钟时限。
Duration musicPluginInvokeTimeout(String method) =>
    method == 'stream' ? kMusicPluginStreamTimeout : kMusicPluginInvokeTimeout;

/// 插件抛出的错误 → 给用户看的一句话：只取第一行，去掉 `Error: ` 一类的 JS 错误类型前缀。
String musicPluginErrorSummary(String raw) {
  final String first = raw.split('\n').first.trim();
  final String stripped = first.replaceFirst(
    RegExp(r'^(Error|TypeError|RangeError|SyntaxError|ReferenceError): '),
    '',
  );
  return stripped.isEmpty ? raw.trim() : stripped;
}

/// 插件 HTTP 请求失败（网络 / 超时 / 授权 / 超限）；[message] 原样交给插件。
final class MusicPluginHttpException implements Exception {
  const MusicPluginHttpException(this.message);

  final String message;

  @override
  String toString() => message;
}

const int _kMaxResponseBytes = 8 * 1024 * 1024;
const int _kMaxRedirects = 5;

/// 判断解析出的地址是否落在本机 / 局域网段（与 Rust `policy::check_ip` 同一判据）。
bool isMusicPluginPrivateAddress(InternetAddress a) {
  final Uint8List b = a.rawAddress;
  if (a.isLoopback || a.isLinkLocal) return true;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 100 && (b[1] & 0xc0) == 64) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && (b[1] & 0xf0) == 16) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 255 && b[1] == 255 && b[2] == 255 && b[3] == 255);
  }
  if (a.type == InternetAddressType.IPv6) {
    final bool unspecified = b.every((int x) => x == 0);
    final bool uniqueLocal = (b[0] & 0xfe) == 0xfc;
    final bool mapped =
        b.sublist(0, 10).every((int x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff;
    if (mapped) {
      return isMusicPluginPrivateAddress(
        InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
      );
    }
    return unspecified || uniqueLocal;
  }
  return false;
}

/// 执行一次插件 HTTP 请求（参数已由 Rust 按授权核对并规范化），[client] 由调用方持有。重定向不交给 HttpClient 自动跟随：
/// 每一跳先经 [checkRedirect]（Rust 授权核对）再请求；DNS 解析结果落在私网段的直接拒绝。
Future<Map<String, Object?>> performMusicPluginHttp(
  Map<String, Object?> args, {
  required HttpClient client,
  required String? Function(String url) checkRedirect,
}) async {
  String method = args['method']! as String;
  Uri uri = Uri.parse(args['url']! as String);
  final Map<String, String> headers = <String, String>{
    for (final MapEntry<Object?, Object?> e
        in ((args['headers'] as Map<Object?, Object?>?) ??
                const <Object?, Object?>{})
            .entries)
      '${e.key}': '${e.value}',
  };
  final String? bodyB64 = args['bodyBase64'] as String?;
  List<int>? body = bodyB64 == null ? null : base64.decode(bodyB64);
  final Duration timeout = Duration(
    milliseconds: (args['timeoutMs'] as num?)?.toInt() ?? 20000,
  );
  client
    ..connectionTimeout = timeout
    ..autoUncompress = true;
  try {
    for (int hop = 0; ; hop++) {
      await _rejectPrivateHost(uri.host);
      final HttpClientRequest req = await client
          .openUrl(method, uri)
          .timeout(timeout);
      req.followRedirects = false;
      req.persistentConnection = true;
      headers.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final HttpClientResponse res = await req.close().timeout(timeout);
      final String? location = res.headers.value(HttpHeaders.locationHeader);
      if (res.isRedirect && location != null) {
        await res.drain<void>();
        if (hop >= _kMaxRedirects) {
          throw const MusicPluginHttpException('重定向次数过多');
        }
        final String target = uri.resolve(location).toString();
        final String? next = checkRedirect(target);
        if (next == null) {
          throw MusicPluginHttpException('重定向到 $target 不在插件网络授权内');
        }
        uri = Uri.parse(next);
        if (res.statusCode == 303 ||
            ((res.statusCode == 301 || res.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = null;
          headers.removeWhere(
            (String k, _) => k.toLowerCase() == 'content-type',
          );
        }
        continue;
      }
      final BytesBuilder buf = BytesBuilder(copy: false);
      await for (final List<int> chunk in res.timeout(timeout)) {
        buf.add(chunk);
        if (buf.length > _kMaxResponseBytes) {
          throw const MusicPluginHttpException('响应体超过 8 MiB');
        }
      }
      final Map<String, String> outHeaders = <String, String>{};
      res.headers.forEach((String name, List<String> values) {
        outHeaders[name.toLowerCase()] = values.join(', ');
      });
      return <String, Object?>{
        'status': res.statusCode,
        'url': uri.toString(),
        'headers': outHeaders,
        // Set-Cookie 原样逐条给（Expires 里有逗号，拼接后插件无法拆回）。
        'setCookies':
            res.headers[HttpHeaders.setCookieHeader] ?? const <String>[],
        'bodyBase64': base64.encode(buf.takeBytes()),
      };
    }
  } on TimeoutException {
    throw const MusicPluginHttpException('请求超时');
  } on SocketException catch (e) {
    throw MusicPluginHttpException('网络错误：${e.message}');
  } on HttpException catch (e) {
    throw MusicPluginHttpException('HTTP 错误：${e.message}');
  } on HandshakeException catch (e) {
    throw MusicPluginHttpException('TLS 握手失败：${e.message}');
  }
}

Future<void> _rejectPrivateHost(String host) async {
  List<InternetAddress> addresses;
  try {
    addresses = await InternetAddress.lookup(host);
  } on SocketException {
    // 解析失败交给连接阶段报（经代理时本机可能根本解析不了）。
    return;
  }
  for (final InternetAddress a in addresses) {
    if (isMusicPluginPrivateAddress(a)) {
      throw MusicPluginHttpException('$host 解析到本机 / 局域网地址，已拒绝');
    }
  }
}
