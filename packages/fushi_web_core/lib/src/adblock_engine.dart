import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi/fushi_web_core_bindings.dart';
import 'fushi_web_core_library.dart';

/// 子资源请求类型（adblock-rust 的资源类型名，决定 `$script` / `$image` 等选项是否生效）。
enum AdblockRequestType {
  document('document'),
  subdocument('subdocument'),
  script('script'),
  image('image'),
  stylesheet('stylesheet'),
  xmlhttprequest('xmlhttprequest'),
  font('font'),
  media('media'),
  websocket('websocket'),
  ping('ping'),
  other('other');

  const AdblockRequestType(this.wireName);

  /// 传给原生层的类型名。
  final String wireName;
}

/// 一次请求检查的结论（与 C ABI 的 `FWC_*` 返回码一一对应）。
enum AdblockDecision {
  /// 没有规则命中：放行。
  allow,

  /// 命中拦截规则：拦截。
  block,

  /// 拦截，并应以替身资源应答（见 [AdblockCheckResult.redirect]）。
  redirect,

  /// 命中拦截规则但被 `@@` 例外规则抵消：放行。
  exception,

  /// 参数无效（URL 解析失败等）：调用方按放行处理。
  error;

  /// 是否应阻止该请求真正发出。
  bool get shouldBlock =>
      this == AdblockDecision.block || this == AdblockDecision.redirect;

  static AdblockDecision fromCode(int code) {
    switch (code) {
      case 0:
        return AdblockDecision.allow;
      case 1:
        return AdblockDecision.block;
      case 2:
        return AdblockDecision.redirect;
      case 3:
        return AdblockDecision.exception;
      default:
        return AdblockDecision.error;
    }
  }
}

/// [FushiAdblockEngine.checkDetailed] 的完整结论。
class AdblockCheckResult {
  const AdblockCheckResult({
    required this.decision,
    this.redirect,
    this.rewrittenUrl,
    this.filter,
    this.exceptionFilter,
    this.important = false,
  });

  factory AdblockCheckResult.fromJson(Map<String, Object?> json) {
    return AdblockCheckResult(
      decision: AdblockDecision.fromCode((json['code'] as num?)?.toInt() ?? -1),
      redirect: json['redirect'] as String?,
      rewrittenUrl: json['rewrittenUrl'] as String?,
      filter: json['filter'] as String?,
      exceptionFilter: json['exceptionFilter'] as String?,
      important: json['important'] == true,
    );
  }

  final AdblockDecision decision;

  /// `$redirect` 替身资源，`data:<mime>;base64,...` 形态；没加载资源时为 null。
  final String? redirect;

  /// `$removeparam` 改写后的 URL（未拦截时才有意义）。
  final String? rewrittenUrl;

  /// 命中的拦截规则 / 例外规则（非 debug 引擎里信息有限，只供日志）。
  final String? filter;
  final String? exceptionFilter;
  final bool important;
}

/// 页面级 cosmetic 资源（[FushiAdblockEngine.cosmetic]）。
class AdblockCosmeticResources {
  const AdblockCosmeticResources({
    this.hideSelectors = const <String>[],
    this.proceduralActions = const <String>[],
    this.exceptions = const <String>[],
    this.injectedScript = '',
    this.generichide = false,
  });

  factory AdblockCosmeticResources.fromJson(Map<String, Object?> json) {
    List<String> strings(Object? v) => v is List
        ? v.whereType<String>().toList(growable: false)
        : const <String>[];
    return AdblockCosmeticResources(
      hideSelectors: strings(json['hideSelectors']),
      proceduralActions: strings(json['proceduralActions']),
      exceptions: strings(json['exceptions']),
      injectedScript: (json['injectedScript'] as String?) ?? '',
      generichide: json['generichide'] == true,
    );
  }

  /// 空结论（引擎不可用 / 白名单站点）。
  static const AdblockCosmeticResources empty = AdblockCosmeticResources();

  /// 站点专属 hide 选择器（`example.com##.ad`）。
  final List<String> hideSelectors;

  /// 过程式 / 带动作的 cosmetic 规则（JSON 串，`:has-text()` 等）；本接线暂不执行。
  final List<String> proceduralActions;

  /// 不应套用通用规则的 class / id 选择器；原样交给 [FushiAdblockEngine.genericSelectors]。
  final List<String> exceptions;

  /// `##+js()` scriptlet 合成的脚本（没加载资源时为空串）。
  final String injectedScript;

  /// 站点有 `$generichide` 例外：不要再取通用选择器。
  final bool generichide;

  Map<String, Object?> toJson() => <String, Object?>{
    'hideSelectors': hideSelectors,
    'proceduralActions': proceduralActions,
    'exceptions': exceptions,
    'injectedScript': injectedScript,
    'generichide': generichide,
  };
}

/// 原生层返回的错误（创建 / 反序列化失败、参数非法）。
class AdblockEngineException implements Exception {
  AdblockEngineException(this.message);

  final String message;

  @override
  String toString() => 'AdblockEngineException: $message';
}

/// 拦截判定的抽象：WebView 接线只依赖它，测试可以注入假实现，不必加载原生库。
abstract interface class AdblockMatcher {
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    AdblockRequestType type = AdblockRequestType.other,
  });

  AdblockCheckResult checkDetailed(
    String url, {
    String? sourceUrl,
    AdblockRequestType type = AdblockRequestType.other,
  });

  AdblockCosmeticResources cosmetic(String url);

  List<String> genericSelectors({
    Iterable<String> classes = const <String>[],
    Iterable<String> ids = const <String>[],
    Iterable<String> exceptions = const <String>[],
  });
}

/// adblock-rust 引擎的 Dart 封装。
///
/// 生命周期：[load] 编译过滤列表（大列表几百毫秒，放后台 isolate）；[serialize] 的产物落盘，
/// 下次用 [deserialize] 秒开。用完 [dispose]；忘了 dispose 也有 `NativeFinalizer` 兜底释放。
/// 原生引擎是 `Send + Sync`，同一实例可在任意线程调用，但一个 Dart 对象只属于创建它的 isolate。
class FushiAdblockEngine implements AdblockMatcher, ffi.Finalizable {
  FushiAdblockEngine._(this._library, this._handle) {
    _finalizerFor(_library).attach(this, _handle.cast(), detach: this);
  }

  /// 从过滤列表文本（ABP / uBO 语法）编译引擎。原生库不可用时抛 [StateError]（先查
  /// [FushiWebCoreLibrary.isAvailable]）；编译失败抛 [AdblockEngineException]。
  factory FushiAdblockEngine.load(
    List<String> filterLists, {
    FushiWebCoreLibrary? library,
  }) {
    final FushiWebCoreLibrary lib = _requireLibrary(library);
    final ffi.Pointer<FwcAdblockEngine> handle = _withCStringArray(
      filterLists,
      (ffi.Pointer<ffi.Pointer<ffi.Char>> arr, int count) =>
          lib.bindings.fwc_engine_create(arr, count),
    );
    if (handle == ffi.nullptr) {
      throw AdblockEngineException(_lastError(lib) ?? 'engine create failed');
    }
    return FushiAdblockEngine._(lib, handle);
  }

  /// 从 [serialize] 的产物恢复。格式版本不符 / 数据损坏抛 [AdblockEngineException]
  /// （调用方删缓存重编即可）。
  factory FushiAdblockEngine.deserialize(
    Uint8List bytes, {
    FushiWebCoreLibrary? library,
  }) {
    final FushiWebCoreLibrary lib = _requireLibrary(library);
    if (bytes.isEmpty) {
      throw AdblockEngineException('serialized engine is empty');
    }
    final ffi.Pointer<ffi.Uint8> buf = malloc<ffi.Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final ffi.Pointer<FwcAdblockEngine> handle = lib.bindings
          .fwc_engine_deserialize(buf, bytes.length);
      if (handle == ffi.nullptr) {
        throw AdblockEngineException(
          _lastError(lib) ?? 'engine deserialize failed',
        );
      }
      return FushiAdblockEngine._(lib, handle);
    } finally {
      malloc.free(buf);
    }
  }

  /// 过滤列表 → Apple / WebKit 内容拦截规则（`[{"trigger":{...},"action":{...}}]`），给
  /// 不能逐请求拦截的 WebView（iOS / macOS WKWebView、Linux WPE）当 contentBlockers。
  /// 与编译引擎是两条独立路径，不需要引擎实例。
  static List<Map<String, Object?>> contentBlockingRules(
    List<String> filterLists, {
    FushiWebCoreLibrary? library,
  }) {
    final FushiWebCoreLibrary lib = _requireLibrary(library);
    final Map<String, Object?> json = _takeJson(
      lib,
      _withCStringArray(
        filterLists,
        (ffi.Pointer<ffi.Pointer<ffi.Char>> arr, int count) =>
            lib.bindings.fwc_content_blocking_rules(arr, count),
      ),
    );
    final Object? rules = json['rules'];
    if (rules is! List) return const <Map<String, Object?>>[];
    return rules
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
        .toList(growable: false);
  }

  static final Map<FushiWebCoreLibrary, ffi.NativeFinalizer> _finalizers =
      <FushiWebCoreLibrary, ffi.NativeFinalizer>{};

  static ffi.NativeFinalizer _finalizerFor(FushiWebCoreLibrary lib) =>
      _finalizers.putIfAbsent(
        lib,
        () => ffi.NativeFinalizer(lib.bindings.fwc_engine_free_ptr.cast()),
      );

  final FushiWebCoreLibrary _library;
  ffi.Pointer<FwcAdblockEngine> _handle;

  bool get isDisposed => _handle == ffi.nullptr;

  /// 序列化引擎（落盘缓存用）。
  Uint8List serialize() {
    final ffi.Pointer<FwcAdblockEngine> h = _live();
    final ffi.Pointer<ffi.Size> lenOut = malloc<ffi.Size>();
    try {
      final ffi.Pointer<ffi.Uint8> buf = _library.bindings.fwc_engine_serialize(
        h,
        lenOut,
      );
      final int len = lenOut.value;
      if (buf == ffi.nullptr) {
        throw AdblockEngineException('engine serialize failed');
      }
      try {
        return Uint8List.fromList(buf.asTypedList(len));
      } finally {
        _library.bindings.fwc_bytes_free(buf, len);
      }
    } finally {
      malloc.free(lenOut);
    }
  }

  /// 加载 `$redirect` / scriptlet 资源（adblock-rust 的 Resource JSON 数组）。返回资源条数。
  int useResources(String resourcesJson) {
    final ffi.Pointer<FwcAdblockEngine> h = _live();
    final ffi.Pointer<Utf8> arg = resourcesJson.toNativeUtf8();
    try {
      final Map<String, Object?> json = _takeJson(
        _library,
        _library.bindings.fwc_engine_use_resources(h, arg.cast()),
      );
      return (json['count'] as num?)?.toInt() ?? 0;
    } finally {
      malloc.free(arg);
    }
  }

  @override
  AdblockDecision check(
    String url, {
    String? sourceUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) {
    final ffi.Pointer<FwcAdblockEngine> h = _live();
    final ffi.Pointer<Utf8> u = url.toNativeUtf8();
    final ffi.Pointer<Utf8> s = (sourceUrl ?? '').toNativeUtf8();
    final ffi.Pointer<Utf8> t = type.wireName.toNativeUtf8();
    try {
      return AdblockDecision.fromCode(
        _library.bindings.fwc_engine_check(h, u.cast(), s.cast(), t.cast()),
      );
    } finally {
      malloc
        ..free(u)
        ..free(s)
        ..free(t);
    }
  }

  @override
  AdblockCheckResult checkDetailed(
    String url, {
    String? sourceUrl,
    AdblockRequestType type = AdblockRequestType.other,
  }) {
    final ffi.Pointer<FwcAdblockEngine> h = _live();
    final ffi.Pointer<Utf8> u = url.toNativeUtf8();
    final ffi.Pointer<Utf8> s = (sourceUrl ?? '').toNativeUtf8();
    final ffi.Pointer<Utf8> t = type.wireName.toNativeUtf8();
    try {
      final Map<String, Object?> json = _takeJson(
        _library,
        _library.bindings.fwc_engine_check_json(
          h,
          u.cast(),
          s.cast(),
          t.cast(),
        ),
        throwOnError: false,
      );
      if (json['ok'] != true) {
        return const AdblockCheckResult(decision: AdblockDecision.error);
      }
      return AdblockCheckResult.fromJson(json);
    } finally {
      malloc
        ..free(u)
        ..free(s)
        ..free(t);
    }
  }

  @override
  AdblockCosmeticResources cosmetic(String url) {
    final ffi.Pointer<FwcAdblockEngine> h = _live();
    final ffi.Pointer<Utf8> u = url.toNativeUtf8();
    try {
      final Map<String, Object?> json = _takeJson(
        _library,
        _library.bindings.fwc_engine_cosmetic(h, u.cast()),
        throwOnError: false,
      );
      if (json['ok'] != true) return AdblockCosmeticResources.empty;
      return AdblockCosmeticResources.fromJson(json);
    } finally {
      malloc.free(u);
    }
  }

  @override
  List<String> genericSelectors({
    Iterable<String> classes = const <String>[],
    Iterable<String> ids = const <String>[],
    Iterable<String> exceptions = const <String>[],
  }) {
    final ffi.Pointer<FwcAdblockEngine> h = _live();
    final ffi.Pointer<Utf8> c = jsonEncode(classes.toList()).toNativeUtf8();
    final ffi.Pointer<Utf8> i = jsonEncode(ids.toList()).toNativeUtf8();
    final ffi.Pointer<Utf8> e = jsonEncode(exceptions.toList()).toNativeUtf8();
    try {
      final Map<String, Object?> json = _takeJson(
        _library,
        _library.bindings.fwc_engine_generic_selectors(
          h,
          c.cast(),
          i.cast(),
          e.cast(),
        ),
        throwOnError: false,
      );
      final Object? selectors = json['selectors'];
      return selectors is List
          ? selectors.whereType<String>().toList(growable: false)
          : const <String>[];
    } finally {
      malloc
        ..free(c)
        ..free(i)
        ..free(e);
    }
  }

  /// 释放原生引擎。重复调用无害；之后再调其它方法抛 [StateError]。
  void dispose() {
    if (_handle == ffi.nullptr) return;
    _finalizerFor(_library).detach(this);
    _library.bindings.fwc_engine_free(_handle);
    _handle = ffi.nullptr;
  }

  ffi.Pointer<FwcAdblockEngine> _live() {
    if (_handle == ffi.nullptr) {
      throw StateError('FushiAdblockEngine used after dispose()');
    }
    return _handle;
  }

  static FushiWebCoreLibrary _requireLibrary(FushiWebCoreLibrary? library) {
    final FushiWebCoreLibrary? lib = library ?? FushiWebCoreLibrary.instance;
    if (lib == null) {
      throw StateError('fushi_web_core native library is not available');
    }
    return lib;
  }

  static String? _lastError(FushiWebCoreLibrary lib) {
    final ffi.Pointer<ffi.Char> p = lib.bindings.fwc_last_error();
    if (p == ffi.nullptr) return null;
    try {
      return p.cast<Utf8>().toDartString();
    } finally {
      lib.bindings.fwc_string_free(p);
    }
  }

  /// 取走原生返回的 JSON 串并释放。`{"ok":false}` 时按 [throwOnError] 抛或原样返回。
  static Map<String, Object?> _takeJson(
    FushiWebCoreLibrary lib,
    ffi.Pointer<ffi.Char> p, {
    bool throwOnError = true,
  }) {
    if (p == ffi.nullptr) {
      if (throwOnError) throw AdblockEngineException('native returned NULL');
      return const <String, Object?>{'ok': false};
    }
    final String text;
    try {
      text = p.cast<Utf8>().toDartString();
    } finally {
      lib.bindings.fwc_string_free(p);
    }
    final Object? decoded = jsonDecode(text);
    final Map<String, Object?> json = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{'ok': false, 'error': 'not a JSON object'};
    if (throwOnError && json['ok'] != true) {
      throw AdblockEngineException((json['error'] as String?) ?? text);
    }
    return json;
  }

  static T _withCStringArray<T>(
    List<String> values,
    T Function(ffi.Pointer<ffi.Pointer<ffi.Char>> arr, int count) body,
  ) {
    final int count = values.length;
    final ffi.Pointer<ffi.Pointer<ffi.Char>> arr =
        malloc<ffi.Pointer<ffi.Char>>(count == 0 ? 1 : count);
    final List<ffi.Pointer<Utf8>> owned = <ffi.Pointer<Utf8>>[];
    try {
      for (int i = 0; i < count; i++) {
        final ffi.Pointer<Utf8> s = values[i].toNativeUtf8();
        owned.add(s);
        arr[i] = s.cast();
      }
      return body(arr, count);
    } finally {
      for (final ffi.Pointer<Utf8> s in owned) {
        malloc.free(s);
      }
      malloc.free(arr);
    }
  }
}
