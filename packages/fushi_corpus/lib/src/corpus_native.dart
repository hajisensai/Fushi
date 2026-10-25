import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'corpus_models.dart';
import 'fushi_corpus_library.dart';

/// `fcorp_*` 调用返回了失败码（语料目录读写失败 / 输入格式不对）。
///
/// 与 [FushiCorpusUnavailableError] 不同：这是一次具体调用的失败，调用方可以按业务处理
/// （记日志、下次重建），不是部署缺陷。
class FushiCorpusException implements Exception {
  FushiCorpusException(this.operation, this.status);

  final String operation;
  final int status;

  @override
  String toString() => 'FushiCorpusException: $operation failed ($status)';
}

typedef _OpenC = Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _PutC =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef _PutDart =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _RemoveC =
    Int32 Function(Pointer<Void>, Uint8, Pointer<Uint8>, Size, Int32, Uint8);
typedef _RemoveDart =
    int Function(Pointer<Void>, int, Pointer<Uint8>, int, int, int);
typedef _RemoveKindsC = Int32 Function(Pointer<Void>, Uint32);
typedef _RemoveKindsDart = int Function(Pointer<Void>, int);
typedef _DocsC =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _DocsDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ExportC =
    Int32 Function(
      Pointer<Void>,
      Uint8,
      Pointer<Uint8>,
      Size,
      Int32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ExportDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _BytesOutC =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _BytesOutDart =
    int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _QueryC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _QueryDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _SplitC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _SplitDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// fushi_corpus 的 `fcorp_*` 绑定（每个 isolate 一份，首次访问时 lookup）。
final class CorpusNative {
  CorpusNative._(this._lib)
    : _open = _lib.library.lookupFunction<_OpenC, _OpenDart>('fcorp_open'),
      _close = _lib.library.lookupFunction<_CloseC, _CloseDart>('fcorp_close'),
      _put = _lib.library.lookupFunction<_PutC, _PutDart>('fcorp_put'),
      _remove = _lib.library.lookupFunction<_RemoveC, _RemoveDart>(
        'fcorp_remove',
      ),
      _removeKinds = _lib.library
          .lookupFunction<_RemoveKindsC, _RemoveKindsDart>(
            'fcorp_remove_kinds',
          ),
      _docs = _lib.library.lookupFunction<_DocsC, _DocsDart>('fcorp_docs'),
      _export = _lib.library.lookupFunction<_ExportC, _ExportDart>(
        'fcorp_export',
      ),
      _stats = _lib.library.lookupFunction<_BytesOutC, _BytesOutDart>(
        'fcorp_stats',
      ),
      _query = _lib.library.lookupFunction<_QueryC, _QueryDart>('fcorp_query'),
      _split = _lib.library.lookupFunction<_SplitC, _SplitDart>('fcorp_split');

  final FushiCorpus _lib;
  final _OpenDart _open;
  final _CloseDart _close;
  final _PutDart _put;
  final _RemoveDart _remove;
  final _RemoveKindsDart _removeKinds;
  final _DocsDart _docs;
  final _ExportDart _export;
  final _BytesOutDart _stats;
  final _QueryDart _query;
  final _SplitDart _split;

  static CorpusNative? _instance;

  /// 本 isolate 的绑定；库或符号缺失抛 [FushiCorpusUnavailableError]。
  static CorpusNative get instance {
    final CorpusNative? existing = _instance;
    if (existing != null) return existing;
    final FushiCorpus lib = FushiCorpus.instance;
    try {
      return _instance = CorpusNative._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('corpus', e);
    }
  }
}

/// 打开着的语料库句柄。
///
/// 原生句柄自带读写锁，**可以跨 isolate 共用**：主 isolate [open] 后把 [address] 交给后台
/// isolate，那边 [FushiCorpusIndex.attach] 重建包装即可写入，UI 侧同时照常查询。句柄只在
/// 进程退出时释放（[close] 只给测试用：调用方必须保证没有别的 isolate 还在用它）。
final class FushiCorpusIndex {
  FushiCorpusIndex._(this._native, this._handle);

  final CorpusNative _native;
  final Pointer<Void> _handle;

  /// 打开（不存在则建）[directory] 并载入全部文档（整库读一遍，放后台 isolate 调）。
  static FushiCorpusIndex open(String directory) {
    final CorpusNative native = CorpusNative.instance;
    final Uint8List dir = utf8.encode(directory);
    return using((Arena arena) {
      final Pointer<Uint8> dirPtr = _copy(arena, dir);
      final Pointer<Pointer<Void>> out = arena<Pointer<Void>>();
      final int status = native._open(dirPtr, dir.length, out);
      if (status != FcorpStatus.ok) {
        throw FushiCorpusException('fcorp_open($directory)', status);
      }
      return FushiCorpusIndex._(native, out.value);
    });
  }

  /// 在另一个 isolate 里接上已打开的句柄。
  static FushiCorpusIndex attach(int address) => FushiCorpusIndex._(
    CorpusNative.instance,
    Pointer<Void>.fromAddress(address),
  );

  int get address => _handle.address;

  /// 写入（整份替换）一份文档。[terms] 是 fushidicts `corpus_terms` 的原样输出
  /// （句数必须与 [document] 一致，否则原生拒收）。
  void put(CorpusDocument document, Uint8List terms) {
    final Uint8List doc = encodeCorpusDocument(document);
    using((Arena arena) {
      final int status = _native._put(
        _handle,
        _copy(arena, doc),
        doc.length,
        _copy(arena, terms),
        terms.length,
      );
      if (status != FcorpStatus.ok) {
        throw FushiCorpusException(
          'fcorp_put(${document.kind.name}:${document.key}#${document.part})',
          status,
        );
      }
    });
  }

  /// 删除一个条目：[part] 为 null 时删它的全部 part。返回删掉的文档数。
  int remove(CorpusSourceKind kind, String key, {int? part}) {
    final Uint8List k = utf8.encode(key);
    return using((Arena arena) {
      final int status = _native._remove(
        _handle,
        kind.code,
        _copy(arena, k),
        k.length,
        part ?? -1,
        part == null ? 1 : 0,
      );
      if (status < 0) throw FushiCorpusException('fcorp_remove', status);
      return status;
    });
  }

  /// 删除这些 kind 的全部文档（「重建索引」）。返回删掉的文档数。
  int removeKinds(Iterable<CorpusSourceKind> kinds) {
    final int status = _native._removeKinds(
      _handle,
      CorpusSourceKind.maskOf(kinds),
    );
    if (status < 0) throw FushiCorpusException('fcorp_remove_kinds', status);
    return status;
  }

  /// 文档清单（[kind] / [key] 过滤）。
  List<CorpusDocInfo> docs({CorpusSourceKind? kind, String? key}) {
    final Uint8List k = utf8.encode(key ?? '');
    final String json = _bytesOut('fcorp_docs', (
      Pointer<Pointer<Uint8>> out,
      Pointer<Size> len,
      Arena arena,
    ) {
      return _native._docs(
        _handle,
        kind?.code ?? -1,
        _copy(arena, k),
        k.length,
        out,
        len,
      );
    });
    return <CorpusDocInfo>[
      for (final Object? raw in jsonDecode(json) as List<Object?>)
        CorpusDocInfo.fromJson(raw! as Map<String, Object?>),
    ];
  }

  /// 读回一份文档的原文（重新归一用：词典换了时取回原句重新分词再 [put]）。不存在返回 null。
  CorpusDocument? export(CorpusSourceKind kind, String key, int part) {
    final Uint8List k = utf8.encode(key);
    return using((Arena arena) {
      final Pointer<Pointer<Uint8>> out = arena<Pointer<Uint8>>();
      final Pointer<Size> len = arena<Size>();
      final int status = _native._export(
        _handle,
        kind.code,
        _copy(arena, k),
        k.length,
        part,
        out,
        len,
      );
      if (status != FcorpStatus.ok) {
        throw FushiCorpusException('fcorp_export', status);
      }
      try {
        if (len.value == 0) return null;
        return decodeCorpusDocument(
          Uint8List.fromList(out.value.asTypedListOutOfLine(len.value)),
        );
      } finally {
        _native._lib.freeBytes(out.value, len.value);
      }
    });
  }

  CorpusStats stats() {
    final String json = _bytesOut(
      'fcorp_stats',
      (Pointer<Pointer<Uint8>> out, Pointer<Size> len, Arena arena) =>
          _native._stats(_handle, out, len),
    );
    return CorpusStats.fromJson(jsonDecode(json) as Map<String, Object?>);
  }

  /// 按词典形 [keys] 查例句：每个模块至多 [perKind] 条、每份文档至多 [perDoc] 条
  /// （0 = 不限），只查 [kinds]（默认全部）。
  CorpusQueryResult query(
    List<String> keys, {
    int perKind = 4,
    int perDoc = 2,
    Iterable<CorpusSourceKind> kinds = CorpusSourceKind.values,
  }) {
    if (keys.isEmpty) return CorpusQueryResult.empty;
    final _LeWriter w = _LeWriter()..u32(keys.length);
    for (final String key in keys) {
      w.str(key);
    }
    w
      ..u32(perKind)
      ..u32(perDoc)
      ..u32(CorpusSourceKind.maskOf(kinds));
    final Uint8List q = w.takeBytes();
    final String json = _bytesOut(
      'fcorp_query',
      (Pointer<Pointer<Uint8>> out, Pointer<Size> len, Arena arena) =>
          _native._query(_handle, _copy(arena, q), q.length, out, len),
    );
    return CorpusQueryResult.fromJson(jsonDecode(json) as Map<String, Object?>);
  }

  /// 只给测试：释放句柄。调用方保证再没有任何 isolate 用它。
  void close() => _native._close(_handle);

  String _bytesOut(
    String op,
    int Function(Pointer<Pointer<Uint8>> out, Pointer<Size> len, Arena arena)
    call,
  ) => using((Arena arena) {
    final Pointer<Pointer<Uint8>> out = arena<Pointer<Uint8>>();
    final Pointer<Size> len = arena<Size>();
    final int status = call(out, len, arena);
    if (status != FcorpStatus.ok) throw FushiCorpusException(op, status);
    try {
      return utf8.decode(out.value.asTypedListOutOfLine(len.value));
    } finally {
      _native._lib.freeBytes(out.value, len.value);
    }
  });
}

/// 一章 / 一段正文切句（原生 `fcorp_split`）：返回各句的 UTF-16 `[start, end)`。
/// 单句超过 [maxUnits] 个 UTF-16 码元时在逗号处或硬切再拆（0 = 不限）。
List<({int start, int end})> splitCorpusSentences(
  String text, {
  int maxUnits = 240,
}) {
  if (text.isEmpty) return const <({int start, int end})>[];
  final CorpusNative native = CorpusNative.instance;
  final Uint8List bytes = utf8.encode(text);
  return using((Arena arena) {
    final Pointer<Pointer<Uint8>> out = arena<Pointer<Uint8>>();
    final Pointer<Size> len = arena<Size>();
    final int status = native._split(
      _copy(arena, bytes),
      bytes.length,
      maxUnits,
      out,
      len,
    );
    if (status != FcorpStatus.ok) {
      throw FushiCorpusException('fcorp_split', status);
    }
    try {
      final ByteData data = ByteData.sublistView(
        out.value.asTypedListOutOfLine(len.value),
      );
      final int n = data.getUint32(0, Endian.little);
      return <({int start, int end})>[
        for (int i = 0; i < n; i++)
          (
            start: data.getUint32(4 + i * 8, Endian.little),
            end: data.getUint32(8 + i * 8, Endian.little),
          ),
      ];
    } finally {
      native._lib.freeBytes(out.value, len.value);
    }
  });
}

/// 文档线格式（native/fushi_corpus/src/wire.rs 的「文档」）。
Uint8List encodeCorpusDocument(CorpusDocument doc) {
  final _LeWriter w = _LeWriter()
    ..u8(doc.kind.code)
    ..str(doc.key)
    ..i32(doc.part)
    ..str(doc.title)
    ..str(doc.fingerprint)
    ..str(doc.normalizer)
    ..i64(doc.updatedAt)
    ..u32(doc.sentences.length);
  for (final CorpusSentence s in doc.sentences) {
    w
      ..i32(s.section)
      ..i64(s.pos)
      ..i64(s.len)
      ..str(s.text);
  }
  return w.takeBytes();
}

/// [encodeCorpusDocument] 的逆（`fcorp_export` 的输出）。kind 未知时抛 [FormatException]。
CorpusDocument decodeCorpusDocument(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int at = 0;
  int u32() {
    final int v = data.getUint32(at, Endian.little);
    at += 4;
    return v;
  }

  int i32() {
    final int v = data.getInt32(at, Endian.little);
    at += 4;
    return v;
  }

  int i64() {
    final int v = data.getInt64(at, Endian.little);
    at += 8;
    return v;
  }

  String str() {
    final int n = u32();
    final String s = utf8.decode(Uint8List.sublistView(bytes, at, at + n));
    at += n;
    return s;
  }

  final int code = bytes[at++];
  final CorpusSourceKind? kind = CorpusSourceKind.fromCode(code);
  if (kind == null) throw FormatException('unknown corpus kind $code');
  final String key = str();
  final int part = i32();
  final String title = str();
  final String fingerprint = str();
  final String normalizer = str();
  final int updatedAt = i64();
  final int n = u32();
  final List<CorpusSentence> sentences = <CorpusSentence>[
    for (int i = 0; i < n; i++)
      CorpusSentence(section: i32(), pos: i64(), len: i64(), text: str()),
  ];
  return CorpusDocument(
    kind: kind,
    key: key,
    part: part,
    title: title,
    fingerprint: fingerprint,
    normalizer: normalizer,
    updatedAt: updatedAt,
    sentences: sentences,
  );
}

Pointer<Uint8> _copy(Arena arena, Uint8List bytes) {
  // 至少分配 1 字节：空数据也传有效指针（原生侧 null 只在长度为 0 时才合法，这里统一不传 null）。
  final Pointer<Uint8> p = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  return p;
}

/// 小端写入器（一次编码一整份文档：可增长的单块缓冲，不逐字段分配）。
class _LeWriter {
  Uint8List _buf = Uint8List(256);
  late ByteData _view = ByteData.sublistView(_buf);
  int _len = 0;

  void _reserve(int n) {
    if (_len + n <= _buf.length) return;
    int next = _buf.length * 2;
    while (next < _len + n) {
      next *= 2;
    }
    final Uint8List grown = Uint8List(next)..setRange(0, _len, _buf);
    _buf = grown;
    _view = ByteData.sublistView(_buf);
  }

  void u8(int v) {
    _reserve(1);
    _buf[_len++] = v & 0xFF;
  }

  void u32(int v) {
    _reserve(4);
    _view.setUint32(_len, v, Endian.little);
    _len += 4;
  }

  void i32(int v) {
    _reserve(4);
    _view.setInt32(_len, v, Endian.little);
    _len += 4;
  }

  void i64(int v) {
    _reserve(8);
    _view.setInt64(_len, v, Endian.little);
    _len += 8;
  }

  void str(String s) {
    final Uint8List bytes = utf8.encode(s);
    u32(bytes.length);
    _reserve(bytes.length);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);
}
