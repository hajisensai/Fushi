import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin_ffi.dart';
import 'plugin_models.dart';
import 'plugin_net_guard.dart';

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
    MusicPluginResolver? resolver,
    MusicPluginAddressBlocker? addressBlocker,
    MusicPluginMediaProbe? mediaProbe,
  }) : _handle = handle,
       _resolver = resolver,
       _addressBlocker = addressBlocker,
       _mediaProbe = mediaProbe,
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
    MusicPluginResolver? resolver,
    MusicPluginAddressBlocker? addressBlocker,
    MusicPluginMediaProbe? mediaProbe,
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
      resolver: resolver,
      addressBlocker: addressBlocker,
      mediaProbe: mediaProbe,
    );
  }

  final MusicPluginPackageInfo info;
  int _handle;
  final MusicPluginHttpClientFactory _httpClientFactory;
  final File _storageFile;
  final MusicPluginLogSink _log;
  final MusicPluginHttpPerformer? _httpPerformer;

  /// 出站解析 / 私网判据（测试注入；缺省系统 DNS + [isMusicPluginPrivateAddress]）。
  final MusicPluginResolver? _resolver;
  final MusicPluginAddressBlocker? _addressBlocker;
  final MusicPluginMediaProbe? _mediaProbe;

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

  /// 本实例复用的出站客户端（同一插件连续请求同一主机时复用连接）：每次请求先解析并核对
  /// 目标主机，连接只连核对过的 IP（[MusicPluginGuardedHttp]）。
  MusicPluginGuardedHttp? _net;

  MusicPluginGuardedHttp get _guarded => _net ??= MusicPluginGuardedHttp(
    _httpClientFactory(),
    resolve: _resolver ?? InternetAddress.lookup,
    isBlocked: _addressBlocker ?? isMusicPluginPrivateAddress,
  );

  /// 本实例在途响应体的合计缓冲上限（单条 8 MiB × Rust 侧在途上限 32 条仍可到 256 MiB）。
  final MusicPluginResponseBudget _responseBudget = MusicPluginResponseBudget(
    kMusicPluginInflightResponseBytes,
  );

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

  /// 插件交给宿主播放的媒体地址（音频流 / MV）：按授权核对 → 请求头白名单 → 解析并核对主机、
  /// 逐跳跟随重定向（每一跳都按授权核对、解析核对），交回最终地址给播放器。播放器拿到的是
  /// 已经走完重定向的地址；它自己再解析 DNS 的那一步是已知边界（播放器不经本层建连）。
  Future<({String url, Map<String, String> headers})> resolveMediaStream(
    String url,
    Map<String, String> headers,
  ) async {
    final Map<String, String> checkedHeaders = checkMusicPluginMediaHeaders(
      headers,
    );
    String? current = checkMediaUrls(<String>[url])[url];
    if (current == null) {
      throw MusicPluginHttpException('媒体地址 $url 不在插件网络授权内');
    }
    final MusicPluginMediaProbe probe = _mediaProbe ?? _guarded.probeRedirect;
    for (int hop = 0; ; hop++) {
      final Uri uri = Uri.parse(current!);
      final String? location = await probe(uri, checkedHeaders);
      if (location == null) return (url: current, headers: checkedHeaders);
      if (hop >= _kMaxRedirects) {
        throw const MusicPluginHttpException('媒体地址重定向次数过多');
      }
      final String target = uri.resolve(location).toString();
      current = checkMediaUrls(<String>[target])[target];
      if (current == null) {
        throw MusicPluginHttpException('媒体地址重定向到 $target，不在插件网络授权内');
      }
    }
  }

  /// 封面地址批量核对：按授权核对 + 按主机解析核对（每个主机解析一次、并发）。解析失败或落在
  /// 私网的主机下的地址不出现在结果里。封面由图片加载器自己取（含重定向），不逐张探测。
  Future<Map<String, String>> checkCoverUrls(Iterable<String> urls) async {
    final Map<String, String> ok = checkMediaUrls(urls);
    final Set<String> hosts = <String>{
      for (final String u in ok.values) Uri.parse(u).host,
    };
    final Map<String, bool> publicHost = <String, bool>{};
    await Future.wait(<Future<void>>[
      for (final String h in hosts)
        resolveMusicPluginPublicAddress(
          h,
          resolve: _resolver ?? InternetAddress.lookup,
          isBlocked: _addressBlocker ?? isMusicPluginPrivateAddress,
        ).then(
          (_) => publicHost[h] = true,
          onError: (Object _) => publicHost[h] = false,
        ),
    ]);
    return <String, String>{
      for (final MapEntry<String, String> e in ok.entries)
        if (publicHost[Uri.parse(e.value).host] ?? false) e.key: e.value,
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
        net: _guarded,
        budget: _responseBudget,
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
    _net?.close(force: true);
    _net = null;
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

const int _kMaxResponseBytes = 8 * 1024 * 1024;

/// 一个插件实例所有在途响应体合计可缓冲的字节数。
const int kMusicPluginInflightResponseBytes = 32 * 1024 * 1024;

/// 在途响应体的合计缓冲预算：每收到一块先占额度，请求结束（成功或失败）归还。超额的那条请求
/// 以 [MusicPluginHttpException] 失败交回插件，不静默截断。
final class MusicPluginResponseBudget {
  MusicPluginResponseBudget(this.maxBytes);

  final int maxBytes;
  int _used = 0;

  int get used => _used;

  /// 占 [n] 字节；超额返回 false 且不占。
  bool tryReserve(int n) {
    if (_used + n > maxBytes) return false;
    _used += n;
    return true;
  }

  void release(int n) => _used -= n;
}

const int _kMaxRedirects = 5;

/// 执行一次插件 HTTP 请求（参数已由 Rust 按授权核对并规范化），[net] 由调用方持有。重定向不交给
/// HttpClient 自动跟随：每一跳先经 [checkRedirect]（Rust 授权核对）、再经 [MusicPluginGuardedHttp.pin]
/// 解析核对（解析失败 / 私网都拒绝），连接只连核对过的 IP。
Future<Map<String, Object?>> performMusicPluginHttp(
  Map<String, Object?> args, {
  required MusicPluginGuardedHttp net,
  required String? Function(String url) checkRedirect,
  MusicPluginResponseBudget? budget,
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
  final HttpClient client = net.client
    ..connectionTimeout = timeout
    ..autoUncompress = true;
  try {
    for (int hop = 0; ; hop++) {
      await net.pin(uri);
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
      int reserved = 0;
      try {
        await for (final List<int> chunk in res.timeout(timeout)) {
          if (budget != null) {
            if (!budget.tryReserve(chunk.length)) {
              throw MusicPluginHttpException(
                '插件在途响应合计超过 ${budget.maxBytes ~/ (1024 * 1024)} MiB',
              );
            }
            reserved += chunk.length;
          }
          buf.add(chunk);
          if (buf.length > _kMaxResponseBytes) {
            throw const MusicPluginHttpException('响应体超过 8 MiB');
          }
        }
      } finally {
        budget?.release(reserved);
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
