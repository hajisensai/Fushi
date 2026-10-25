import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../ffi/fushi_web_core_bindings.dart';
import '../fushi_web_core_library.dart';
import 'adblock_snapshot.dart';

/// 子资源请求类型（adblock-rust 的资源类型，决定 `$script` / `$image` 等选项是否生效）。
/// [code] 与 Rust `request_type_name` 一一对应。
enum AdblockRequestType {
  other(0),
  document(1),
  subdocument(2),
  script(3),
  image(4),
  stylesheet(5),
  xmlhttprequest(6),
  font(7),
  media(8),
  websocket(9),
  ping(10);

  const AdblockRequestType(this.code);

  final int code;
}

/// 一次请求检查的结论（`fwc_adblock_check` 的返回码）。
enum AdblockDecision {
  /// 放行（没命中 / 总开关关 / 白名单 / 引擎未就绪）。
  allow,

  /// 拦截。
  block,

  /// 命中拦截规则但被 `@@` 例外规则抵消：放行。
  exception,

  /// 参数无效（URL 解析失败等）：按放行处理。
  error;

  bool get shouldBlock => this == AdblockDecision.block;

  static AdblockDecision fromCode(int code) => switch (code) {
    0 => AdblockDecision.allow,
    1 => AdblockDecision.block,
    3 => AdblockDecision.exception,
    _ => AdblockDecision.error,
  };
}

/// [AdblockCore.beginSync] 的取数清单里的一项。
class AdblockFetchItem {
  const AdblockFetchItem({
    required this.id,
    required this.url,
    this.etag,
    this.lastModified,
  });

  final String id;
  final Uri url;

  /// 非空时请求要带 `If-None-Match`。
  final String? etag;

  /// 非空时请求要带 `If-Modified-Since`。
  final String? lastModified;
}

/// [AdblockCore.beginSync] 的结果。
class AdblockSyncPlan {
  const AdblockSyncPlan({required this.run, required this.fetch});

  /// false：什么也不用做（总开关关 / 已有同步在跑 / 缓存新鲜且引擎已是最新）。
  final bool run;
  final List<AdblockFetchItem> fetch;
}

/// Rust 广告拦截核心的 Dart 句柄（一个数据目录一个，全应用共用）。
///
/// 状态（订阅集、总开关、白名单、列表缓存 / ETag / 过期、引擎）全在 Rust 侧并落盘；
/// 这里只把粗粒度命令转过去，改状态的命令都返回新的 [AdblockSnapshot]。
/// 原生句柄是 `Send + Sync`：[finishSyncInBackground] 把地址带进后台 isolate 做慢的编译，
/// 主 isolate 同时照常 [check]。
class AdblockCore implements ffi.Finalizable {
  AdblockCore._(this._library, this._handle) {
    _finalizerFor(_library).attach(this, _handle.cast(), detach: this);
  }

  /// 打开 [dataDir] 下的状态（快：只读 `state.json`）。[wantContentBlocking]：本平台需要
  /// WebKit 内容拦截规则（iOS / macOS）。原生库缺失抛 [FushiWebCoreLibraryMissing]。
  factory AdblockCore.open(
    String dataDir, {
    bool wantContentBlocking = false,
    FushiWebCoreLibrary? library,
  }) {
    final FushiWebCoreLibrary lib = library ?? FushiWebCoreLibrary.instance;
    final Uint8List dir = utf8.encode(dataDir);
    final ffi.Pointer<ffi.Uint8> buf = malloc<ffi.Uint8>(
      dir.isEmpty ? 1 : dir.length,
    );
    try {
      buf.asTypedListOutOfLine(dir.length).setAll(0, dir);
      final ffi.Pointer<FwcAdblockCore> handle = lib.bindings.fwc_adblock_open(
        buf,
        dir.length,
        wantContentBlocking ? 1 : 0,
      );
      if (handle == ffi.nullptr) {
        throw StateError(lib.lastError() ?? 'fwc adblock open failed');
      }
      return AdblockCore._(lib, handle);
    } finally {
      malloc.free(buf);
    }
  }

  /// 内置列表目录（不需要句柄；设置页用来排行）。
  static List<AdblockCatalogEntry> catalog({FushiWebCoreLibrary? library}) {
    final FushiWebCoreLibrary lib = library ?? FushiWebCoreLibrary.instance;
    final Object? json = lib.takeJson(lib.bindings.fwc_adblock_catalog);
    return json is List
        ? json
              .whereType<Map<String, Object?>>()
              .map(AdblockCatalogEntry.fromJson)
              .toList(growable: false)
        : const <AdblockCatalogEntry>[];
  }

  static final Map<FushiWebCoreLibrary, ffi.NativeFinalizer> _finalizers =
      <FushiWebCoreLibrary, ffi.NativeFinalizer>{};

  static ffi.NativeFinalizer _finalizerFor(FushiWebCoreLibrary lib) =>
      _finalizers.putIfAbsent(
        lib,
        () => ffi.NativeFinalizer(lib.bindings.fwc_adblock_close_ptr.cast()),
      );

  final FushiWebCoreLibrary _library;
  ffi.Pointer<FwcAdblockCore> _handle;

  bool get isClosed => _handle == ffi.nullptr;

  ffi.Pointer<FwcAdblockCore> _live() {
    if (_handle == ffi.nullptr) {
      throw StateError('AdblockCore used after close()');
    }
    return _handle;
  }

  AdblockSnapshot _snapshotFrom(
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Size>) call,
  ) {
    final Object? json = _library.takeJson(call);
    return AdblockSnapshot.fromJson(
      json is Map<String, Object?> ? json : const <String, Object?>{},
    );
  }

  /// 当前快照。
  AdblockSnapshot snapshot() {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return _snapshotFrom(
      (ffi.Pointer<ffi.Size> out) =>
          _library.bindings.fwc_adblock_snapshot(h, out),
    );
  }

  /// 总开关。
  AdblockSnapshot setEnabled(bool enabled) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return _snapshotFrom(
      (ffi.Pointer<ffi.Size> out) =>
          _library.bindings.fwc_adblock_set_enabled(h, enabled ? 1 : 0, out),
    );
  }

  /// 订阅 / 取消订阅一份目录里的列表（之后发起一次同步让引擎跟上）。
  AdblockSnapshot setListEnabled(String id, bool enabled) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> p, int n) = _utf8In(arena, id);
      return _snapshotFrom(
        (ffi.Pointer<ffi.Size> out) => _library.bindings
            .fwc_adblock_set_list_enabled(h, p, n, enabled ? 1 : 0, out),
      );
    });
  }

  /// 白名单原文（逗号 / 空白分隔的域名，含子域名）。
  AdblockSnapshot setAllowlist(String raw) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> p, int n) = _utf8In(arena, raw);
      return _snapshotFrom(
        (ffi.Pointer<ffi.Size> out) =>
            _library.bindings.fwc_adblock_set_allowlist(h, p, n, out),
      );
    });
  }

  /// 开始一次同步：返回要联网取的列表（带条件请求头）。[force] = 「立即更新」。
  AdblockSyncPlan beginSync({bool force = false}) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    final Object? json = _library.takeJson(
      (ffi.Pointer<ffi.Size> out) =>
          _library.bindings.fwc_adblock_begin_sync(h, force ? 1 : 0, out),
    );
    if (json is! Map<String, Object?> || json['run'] != true) {
      return const AdblockSyncPlan(run: false, fetch: <AdblockFetchItem>[]);
    }
    final Object? fetch = json['fetch'];
    return AdblockSyncPlan(
      run: true,
      fetch: <AdblockFetchItem>[
        if (fetch is List)
          for (final Map<String, Object?> f
              in fetch.whereType<Map<String, Object?>>())
            AdblockFetchItem(
              id: f['id'] as String? ?? '',
              url: Uri.parse(f['url'] as String? ?? ''),
              etag: f['etag'] as String?,
              lastModified: f['lastModified'] as String?,
            ),
      ],
    );
  }

  /// 交回一份列表的联网结果。[statusCode] 0 = 联网失败（原因放 [error]）；[body] 是原始
  /// 响应字节（拷一次进原生内存，不解码成字符串）。
  void ingest(
    String id, {
    required int statusCode,
    Uint8List? body,
    String? etag,
    String? lastModified,
    String? error,
  }) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> idP, int idN) = _utf8In(arena, id);
      final (ffi.Pointer<ffi.Uint8> bodyP, int bodyN) = _bytesIn(arena, body);
      final (ffi.Pointer<ffi.Uint8> etP, int etN) = _utf8In(arena, etag ?? '');
      final (ffi.Pointer<ffi.Uint8> lmP, int lmN) = _utf8In(
        arena,
        lastModified ?? '',
      );
      final (ffi.Pointer<ffi.Uint8> erP, int erN) = _utf8In(arena, error ?? '');
      final int rc = _library.bindings.fwc_adblock_ingest(
        h,
        idP,
        idN,
        statusCode,
        bodyP,
        bodyN,
        etP,
        etN,
        lmP,
        lmN,
        erP,
        erN,
      );
      if (rc != 0) {
        throw StateError(_library.lastError() ?? 'fwc adblock ingest failed');
      }
    });
  }

  /// 收尾同步（同步调用，可能编译引擎、~100 ms 级）。UI isolate 请用
  /// [finishSyncInBackground]。
  AdblockSnapshot finishSync() {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return _snapshotFrom(
      (ffi.Pointer<ffi.Size> out) =>
          _library.bindings.fwc_adblock_finish_sync(h, out),
    );
  }

  /// 在后台 isolate 收尾同步：只把句柄地址与库路径带过去（零拷贝），快照 JSON 字节带回来。
  /// 调用方须保证结束前不 [close]。
  Future<AdblockSnapshot> finishSyncInBackground() async {
    final int address = _live().address;
    final String? path = _library.libraryPath;
    final Uint8List? bytes = await Isolate.run<Uint8List?>(() {
      final FushiWebCoreLibrary lib = FushiWebCoreLibrary.load(
        libraryPath: path,
      );
      final ffi.Pointer<FwcAdblockCore> h =
          ffi.Pointer<FwcAdblockCore>.fromAddress(address);
      return lib.takeBytes(
        (ffi.Pointer<ffi.Size> out) =>
            lib.bindings.fwc_adblock_finish_sync(h, out),
      );
    });
    if (bytes == null) {
      throw StateError('fwc adblock finish_sync returned no data');
    }
    final Object? json = const Utf8Decoder()
        .fuse(const JsonDecoder())
        .convert(bytes);
    return AdblockSnapshot.fromJson(
      json is Map<String, Object?> ? json : const <String, Object?>{},
    );
  }

  /// 热路径：判一个子资源请求（总开关、白名单、引擎就绪都在 Rust 里判）。
  ///
  /// 三个字符串直接编码进本对象常驻的一块原生暂存区（ASCII 逐码元写入，非 ASCII 才走
  /// `utf8.encode`），一次 leaf 调用判完：每次请求零 malloc / free、零结果分配。
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    String? pageUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    final String s = sourceUrl ?? '';
    final String p = pageUrl ?? '';
    final int a = _scratchWrite(0, url);
    final int b = _scratchWrite(a, s);
    final int c = _scratchWrite(a + b, p);
    final ffi.Pointer<ffi.Uint8> base = _scratch;
    return AdblockDecision.fromCode(
      _library.bindings.fwc_adblock_check(
        h,
        base,
        a,
        base + a,
        b,
        base + a + b,
        c,
        type.code,
      ),
    );
  }

  ffi.Pointer<ffi.Uint8> _scratch = ffi.nullptr;
  int _scratchCap = 0;

  /// 把 [s] 的 UTF-8 写到暂存区偏移 [offset] 处，返回字节数（必要时扩容，保留已写内容）。
  int _scratchWrite(int offset, String s) {
    final int n = s.length;
    _ensureScratch(offset + n);
    Uint8List view = _scratch.asTypedListOutOfLine(_scratchCap);
    for (int i = 0; i < n; i++) {
      final int cu = s.codeUnitAt(i);
      if (cu >= 0x80) {
        final Uint8List enc = utf8.encode(s);
        _ensureScratch(offset + enc.length);
        view = _scratch.asTypedListOutOfLine(_scratchCap);
        view.setAll(offset, enc);
        return enc.length;
      }
      view[offset + i] = cu;
    }
    return n;
  }

  void _ensureScratch(int need) {
    if (need <= _scratchCap && _scratch != ffi.nullptr) return;
    int cap = _scratchCap == 0 ? 4096 : _scratchCap;
    while (cap < need) {
      cap *= 2;
    }
    final ffi.Pointer<ffi.Uint8> next = malloc<ffi.Uint8>(cap);
    if (_scratch != ffi.nullptr) {
      next
          .asTypedListOutOfLine(_scratchCap)
          .setAll(0, _scratch.asTypedListOutOfLine(_scratchCap));
      malloc.free(_scratch);
    }
    _scratch = next;
    _scratchCap = cap;
  }

  /// 页面 cosmetic 载荷：Rust 直接产出的 JSON 文本
  /// （`{"hideSelectors":[..],"injectedScript":"..","generichide":b}`），原样交给页内 JS
  /// （JS 端 `JSON.parse`）；Dart 不解码。未激活 / 白名单 / 未就绪时 null。
  String? cosmeticPayload(String href, {String? pageUrl}) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> hp, int hn) = _utf8In(arena, href);
      final (ffi.Pointer<ffi.Uint8> pp, int pn) = _utf8In(arena, pageUrl ?? '');
      final Uint8List? bytes = _library.takeBytes(
        (ffi.Pointer<ffi.Size> out) =>
            _library.bindings.fwc_adblock_cosmetic(h, hp, hn, pp, pn, out),
      );
      return bytes == null ? null : utf8.decode(bytes);
    });
  }

  /// 通用 hide 选择器载荷：JSON 数组文本，原样交给页内 JS。[classes] / [ids] 是页内 JS
  /// 收集好的换行分隔原文（一次传整批，不逐个跨 FFI）。未激活 / 白名单时 null。
  String? genericPayload(
    String href, {
    String? pageUrl,
    required String classes,
    required String ids,
  }) {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> hp, int hn) = _utf8In(arena, href);
      final (ffi.Pointer<ffi.Uint8> pp, int pn) = _utf8In(arena, pageUrl ?? '');
      final (ffi.Pointer<ffi.Uint8> cp, int cn) = _utf8In(arena, classes);
      final (ffi.Pointer<ffi.Uint8> ip, int iN) = _utf8In(arena, ids);
      final Uint8List? bytes = _library.takeBytes(
        (ffi.Pointer<ffi.Size> out) => _library.bindings.fwc_adblock_generic(
          h,
          hp,
          hn,
          pp,
          pn,
          cp,
          cn,
          ip,
          iN,
          out,
        ),
      );
      return bytes == null ? null : utf8.decode(bytes);
    });
  }

  /// 当前引擎的 WebKit 内容拦截规则 JSON 字节（已在 Rust 里筛选、截断）；没有就 null。
  Uint8List? contentBlockersJson() {
    final ffi.Pointer<FwcAdblockCore> h = _live();
    return _library.takeBytes(
      (ffi.Pointer<ffi.Size> out) =>
          _library.bindings.fwc_adblock_content_blockers(h, out),
    );
  }

  /// 释放原生核心。重复调用无害；之后再调其它方法抛 [StateError]。
  void close() {
    if (_handle == ffi.nullptr) return;
    _finalizerFor(_library).detach(this);
    _library.bindings.fwc_adblock_close(_handle);
    _handle = ffi.nullptr;
    if (_scratch != ffi.nullptr) {
      malloc.free(_scratch);
      _scratch = ffi.nullptr;
      _scratchCap = 0;
    }
  }

  static (ffi.Pointer<ffi.Uint8>, int) _utf8In(Arena arena, String s) =>
      _bytesIn(arena, s.isEmpty ? null : utf8.encode(s));

  static (ffi.Pointer<ffi.Uint8>, int) _bytesIn(Arena arena, Uint8List? b) {
    if (b == null || b.isEmpty) return (ffi.nullptr, 0);
    final ffi.Pointer<ffi.Uint8> p = arena<ffi.Uint8>(b.length);
    p.asTypedListOutOfLine(b.length).setAll(0, b);
    return (p, b.length);
  }
}

/// 一次 HTTP 抓取的结果：[body] 是原始响应字节（200 才有），不转字符串。
class AdblockFetchResponse {
  const AdblockFetchResponse({
    required this.statusCode,
    this.body,
    this.etag,
    this.lastModified,
  });

  final int statusCode;
  final Uint8List? body;
  final String? etag;
  final String? lastModified;
}

/// 可注入的下载函数：app 侧传经全应用代理装配的 client（`createAppHttpClient`），
/// 测试传假实现。[etag] / [lastModified] 非空时应带条件请求头。
typedef AdblockHttpFetcher =
    Future<AdblockFetchResponse> Function(
      Uri url, {
      String? etag,
      String? lastModified,
    });

/// 用 `dart:io` [HttpClient] 实现的下载器（只搬字节）。[clientFactory] 缺省
/// `HttpClient.new`；app 必须传自己的工厂，否则下载绕过全应用代理设置。
AdblockHttpFetcher httpClientAdblockFetcher({
  HttpClient Function()? clientFactory,
  Duration timeout = const Duration(seconds: 60),
}) {
  return (Uri url, {String? etag, String? lastModified}) async {
    final HttpClient client = (clientFactory ?? HttpClient.new)();
    try {
      final HttpClientRequest req = await client.getUrl(url).timeout(timeout);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      if (etag != null && etag.isNotEmpty) {
        req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      if (lastModified != null && lastModified.isNotEmpty) {
        req.headers.set(HttpHeaders.ifModifiedSinceHeader, lastModified);
      }
      final HttpClientResponse resp = await req.close().timeout(timeout);
      Uint8List? body;
      if (resp.statusCode == HttpStatus.ok) {
        final BytesBuilder sink = BytesBuilder(copy: false);
        await resp.forEach(sink.add).timeout(timeout);
        body = sink.takeBytes();
      } else {
        await resp.drain<void>();
      }
      return AdblockFetchResponse(
        statusCode: resp.statusCode,
        body: body,
        etag: resp.headers.value(HttpHeaders.etagHeader),
        lastModified: resp.headers.value(HttpHeaders.lastModifiedHeader),
      );
    } finally {
      client.close(force: true);
    }
  };
}

/// 跑一次完整同步：问 Rust 要清单 → 逐条联网 → 原始字节交回 → 后台 isolate 收尾。
/// 联网失败不抛（交给 Rust 记成 staleCache / missing）。返回最新快照。
Future<AdblockSnapshot> runAdblockSync(
  AdblockCore core, {
  required AdblockHttpFetcher fetcher,
  bool force = false,
}) async {
  final AdblockSyncPlan plan = core.beginSync(force: force);
  if (!plan.run) return core.snapshot();
  try {
    for (final AdblockFetchItem item in plan.fetch) {
      AdblockFetchResponse? resp;
      Object? failure;
      try {
        resp = await fetcher(
          item.url,
          etag: item.etag,
          lastModified: item.lastModified,
        );
      } on Object catch (error) {
        failure = error;
      }
      core.ingest(
        item.id,
        statusCode: resp?.statusCode ?? 0,
        body: resp?.body,
        etag: resp?.etag,
        lastModified: resp?.lastModified,
        error: failure?.toString(),
      );
    }
  } finally {
    // 无论如何都要收尾，否则 Rust 侧一直处于 syncing、后续同步都被拒。
    await core.finishSyncInBackground();
  }
  return core.snapshot();
}
