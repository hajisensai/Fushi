import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../ffi/fushi_web_core_bindings.dart';
import '../fushi_web_core_library.dart';

/// 正文里图片的占位 src 前缀：第 i 张写作 `src="fushi-web-image:i"`，对应
/// [WebArticle.images] 的第 i 项（与 Rust `IMAGE_PLACEHOLDER_PREFIX` 一致）。
const String kWebArticleImagePlaceholderPrefix = 'fushi-web-image:';

/// 一页的提取结果（Rust `article::Article`）。只读数据，Dart 不再加工判据。
class WebArticle {
  const WebArticle({
    required this.url,
    required this.title,
    required this.workKey,
    required this.images,
    required this.excerpt,
    required this.paragraphs,
    required this.chars,
    required this.method,
    required this.charset,
    required this.contentHash,
    required this.xhtml,
    this.workTitle,
    this.author,
    this.lang,
    this.siteRule,
    this.next,
    this.prev,
    this.toc,
  });

  factory WebArticle._fromJson(Map<String, Object?> json, String xhtml) {
    String? opt(String key) {
      final Object? v = json[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    return WebArticle(
      url: json['url']! as String,
      title: (json['title'] ?? '') as String,
      workTitle: opt('workTitle'),
      author: opt('author'),
      lang: opt('lang'),
      siteRule: opt('siteRule'),
      workKey: (json['workKey'] ?? '') as String,
      next: opt('next'),
      prev: opt('prev'),
      toc: opt('toc'),
      images: <String>[
        for (final Object? i
            in (json['images'] as List<Object?>?) ?? <Object?>[])
          i! as String,
      ],
      excerpt: (json['excerpt'] ?? '') as String,
      paragraphs: (json['paragraphs'] ?? 0) as int,
      chars: (json['chars'] ?? 0) as int,
      method: (json['method'] ?? '') as String,
      charset: (json['charset'] ?? '') as String,
      contentHash: (json['contentHash'] ?? '') as String,
      xhtml: xhtml,
    );
  }

  /// 页面 URL（去掉片段）。
  final String url;

  /// 章节标题。
  final String title;
  final String? workTitle;
  final String? author;

  /// BCP 47 主语言子标签（`ja` / `zh`…）；判不出为 null。
  final String? lang;

  /// 命中的站点规则 id（`syosetu` / `kakuyomu` / `hameln` / `jjwxc`）；通用算法为 null。
  final String? siteRule;

  /// 作品身份键（同一部作品的各章相同）。
  final String workKey;
  final String? next;
  final String? prev;
  final String? toc;

  /// 正文图片的绝对 URL（正文里按序号占位，见 [kWebArticleImagePlaceholderPrefix]）。
  final List<String> images;

  /// 第一段正文（纯文本，≤ 160 字）。
  final String excerpt;
  final int paragraphs;

  /// 可见字数（不含注音）。
  final int chars;

  /// `site` / `readability` / `density`。
  final String method;
  final String charset;
  final String contentHash;

  /// 清洗后的正文 XHTML 片段（`<section>` 内部）。
  final String xhtml;
}

/// [WebNovelSession.ingest] 的结论（Rust `IngestStatus`）。
enum WebNovelIngestStatus {
  /// 新章，已插入会话。
  added,

  /// 已有的章：元数据已更新。
  updated,

  /// 正文没取到（导航页 / 验证页 / 目录页）。
  empty,

  /// 不是这部作品的页。
  otherWork;

  static WebNovelIngestStatus parse(String raw) => switch (raw) {
    'added' => added,
    'updated' => updated,
    'otherWork' => otherWork,
    _ => empty,
  };

  /// 这一页进了会话（新增或更新）。
  bool get accepted => this == added || this == updated;
}

/// 喂一页的结果：提取结果 + 会话里的结论。
class WebNovelIngest {
  const WebNovelIngest({
    required this.article,
    required this.status,
    required this.chapterCount,
    this.index,
    this.tailNext,
  });

  final WebArticle article;
  final WebNovelIngestStatus status;

  /// 这一章在会话里的序号（[WebNovelIngestStatus.accepted] 时有）。
  final int? index;
  final int chapterCount;

  /// 末章的下一章（追更取它）；没有为 null。
  final String? tailNext;
}

/// 会话快照里的一章（只有元数据，正文在书的解压树里）。
class WebNovelChapter {
  const WebNovelChapter({
    required this.url,
    required this.title,
    this.next,
    this.prev,
    this.chars = 0,
    this.hash = '',
  });

  final String url;
  final String title;
  final String? next;
  final String? prev;
  final int chars;
  final String hash;
}

/// 连载会话快照（Rust `SessionState` 的 JSON）。[raw] 原样持久化，下次
/// [WebNovelSession.open] 交回去恢复；其余字段只供 UI 渲染。
class WebNovelSnapshot {
  const WebNovelSnapshot._({
    required this.raw,
    required this.chapters,
    required this.queue,
    this.workKey,
    this.siteRule,
    this.workTitle,
    this.author,
    this.lang,
    this.toc,
    this.tailNext,
  });

  /// 快照 JSON 的类型标记（书行 `sourceMetadata` 里按它认网页小说书）。
  static const String type = 'fushi_web_novel';

  final String raw;
  final String? workKey;
  final String? siteRule;
  final String? workTitle;
  final String? author;
  final String? lang;
  final String? toc;
  final List<WebNovelChapter> chapters;
  final List<String> queue;
  final String? tailNext;

  /// 不是网页小说快照（普通书 / 在线漫画 / 损坏）返回 null。
  static WebNovelSnapshot? tryParse(String? raw) {
    if (raw == null || !raw.contains(type)) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['type'] != type) {
      return null;
    }
    String? opt(Map<String, Object?> m, String key) {
      final Object? v = m[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    return WebNovelSnapshot._(
      raw: raw,
      workKey: opt(decoded, 'workKey'),
      siteRule: opt(decoded, 'siteRule'),
      workTitle: opt(decoded, 'workTitle'),
      author: opt(decoded, 'author'),
      lang: opt(decoded, 'lang'),
      toc: opt(decoded, 'toc'),
      tailNext: opt(decoded, 'tailNext'),
      chapters: <WebNovelChapter>[
        for (final Object? c
            in (decoded['chapters'] as List<Object?>?) ?? <Object?>[])
          if (c is Map<String, Object?>)
            WebNovelChapter(
              url: (c['url'] ?? '').toString(),
              title: (c['title'] ?? '').toString(),
              next: opt(c, 'next'),
              prev: opt(c, 'prev'),
              chars: c['chars'] is int ? c['chars']! as int : 0,
              hash: (c['hash'] ?? '').toString(),
            ),
      ],
      queue: <String>[
        for (final Object? q
            in (decoded['queue'] as List<Object?>?) ?? <Object?>[])
          if (q is String) q,
      ],
    );
  }
}

/// 把帧 `[u32 LE 头长度][JSON 头][正文 UTF-8]` 拆开（正文直接按 UTF-8 解码，不经 JSON）。
({Map<String, Object?> header, String body}) _splitFrame(Uint8List frame) {
  if (frame.length < 4) throw const FormatException('short frame');
  final int headerLength = ByteData.sublistView(
    frame,
    0,
    4,
  ).getUint32(0, Endian.little);
  if (4 + headerLength > frame.length) {
    throw const FormatException('truncated frame');
  }
  final Object? header = const Utf8Decoder()
      .fuse(const JsonDecoder())
      .convert(Uint8List.sublistView(frame, 4, 4 + headerLength));
  final String body = const Utf8Decoder().convert(
    Uint8List.sublistView(frame, 4 + headerLength),
  );
  return (header: header! as Map<String, Object?>, body: body);
}

/// 无状态正文提取（预览 / 测量用）与 URL → 作品身份键。
abstract final class WebArticleExtractor {
  /// 提取一页。整页字节在当前 isolate 拷进原生内存一次，后台 isolate 一次 FFI 调用做完，
  /// 结果帧经 `Isolate.exit` 移交回来。失败抛 [StateError]（带 Rust 的原因）。
  static Future<WebArticle> extract(
    Uint8List html,
    Uri url, {
    FushiWebCoreLibrary? library,
  }) async {
    final FushiWebCoreLibrary lib = library ?? FushiWebCoreLibrary.instance;
    final Uint8List frame = await _runOnNativeCopy(
      lib,
      html,
      url,
      (
        FushiWebCoreLibrary l,
        ffi.Pointer<ffi.Uint8> h,
        int hl,
        ffi.Pointer<ffi.Uint8> u,
        int ul,
        ffi.Pointer<ffi.Size> out,
      ) => l.bindings.fwc_article_extract(h, hl, u, ul, out),
    );
    final ({Map<String, Object?> header, String body}) parts = _splitFrame(
      frame,
    );
    return WebArticle._fromJson(parts.header, parts.body);
  }

  /// 只从章节 URL 推作品身份键（快调用，当前 isolate）。不是 http(s) 返回 null。
  static String? workKeyForUrl(Uri url, {FushiWebCoreLibrary? library}) {
    final FushiWebCoreLibrary lib = library ?? FushiWebCoreLibrary.instance;
    final Uint8List encoded = utf8.encode(url.toString());
    final ffi.Pointer<ffi.Uint8> u = malloc<ffi.Uint8>(encoded.length + 1);
    try {
      u.asTypedListOutOfLine(encoded.length).setAll(0, encoded);
      final Uint8List? bytes = lib.takeBytes(
        (ffi.Pointer<ffi.Size> out) =>
            lib.bindings.fwc_article_work_key(u, encoded.length, out),
      );
      return bytes == null ? null : utf8.decode(bytes);
    } finally {
      malloc.free(u);
    }
  }
}

typedef _FrameCall =
    ffi.Pointer<ffi.Uint8> Function(
      FushiWebCoreLibrary lib,
      ffi.Pointer<ffi.Uint8> html,
      int htmlLength,
      ffi.Pointer<ffi.Uint8> url,
      int urlLength,
      ffi.Pointer<ffi.Size> outLength,
    );

/// 整页字节拷进原生内存（唯一一次拷贝），后台 isolate 调 [call] 取帧。
Future<Uint8List> _runOnNativeCopy(
  FushiWebCoreLibrary lib,
  Uint8List html,
  Uri url,
  _FrameCall call,
) async {
  final Uint8List urlBytes = utf8.encode(url.toString());
  final ffi.Pointer<ffi.Uint8> h = malloc<ffi.Uint8>(
    html.isEmpty ? 1 : html.length,
  );
  final ffi.Pointer<ffi.Uint8> u = malloc<ffi.Uint8>(urlBytes.length + 1);
  try {
    h.asTypedListOutOfLine(html.length).setAll(0, html);
    u.asTypedListOutOfLine(urlBytes.length).setAll(0, urlBytes);
    final String? path = lib.libraryPath;
    final int hAddr = h.address;
    final int hLen = html.length;
    final int uAddr = u.address;
    final int uLen = urlBytes.length;
    final ({Uint8List? frame, String? error}) result = await Isolate.run(() {
      final FushiWebCoreLibrary l = FushiWebCoreLibrary.load(libraryPath: path);
      final Uint8List? frame = l.takeBytes(
        (ffi.Pointer<ffi.Size> out) => call(
          l,
          ffi.Pointer<ffi.Uint8>.fromAddress(hAddr),
          hLen,
          ffi.Pointer<ffi.Uint8>.fromAddress(uAddr),
          uLen,
          out,
        ),
      );
      // 失败原因是线程局部的：必须在调用它的这个 isolate（线程）上取。
      return (frame: frame, error: frame == null ? l.lastError() : null);
    });
    final Uint8List? frame = result.frame;
    if (frame == null) {
      throw StateError(result.error ?? 'fushi_web_core returned no data');
    }
    return frame;
  } finally {
    malloc
      ..free(h)
      ..free(u);
  }
}

/// 连载会话（状态全在 Rust）：开会话 → 喂页 → 取快照。快照原样持久化，下次交回来恢复。
///
/// 句柄挂了 [ffi.NativeFinalizer]，忘记 [close] 也不会漏；显式 [close] 后不可再用。
class WebNovelSession implements ffi.Finalizable {
  WebNovelSession._(this._library, this._handle) {
    _finalizerFor(_library).attach(this, _handle.cast(), detach: this);
  }

  /// 开会话。[snapshot] 为 null / 空 = 新会话；快照坏了抛 [FormatException]。
  factory WebNovelSession.open({
    String? snapshot,
    FushiWebCoreLibrary? library,
  }) {
    final FushiWebCoreLibrary lib = library ?? FushiWebCoreLibrary.instance;
    final Uint8List bytes = snapshot == null || snapshot.isEmpty
        ? Uint8List(0)
        : utf8.encode(snapshot);
    final ffi.Pointer<ffi.Uint8> p = malloc<ffi.Uint8>(
      bytes.isEmpty ? 1 : bytes.length,
    );
    try {
      p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
      final ffi.Pointer<FwcNovelSession> handle = lib.bindings
          .fwc_novel_session_open(p, bytes.length);
      if (handle == ffi.nullptr) {
        throw FormatException(lib.lastError() ?? 'bad web novel snapshot');
      }
      return WebNovelSession._(lib, handle);
    } finally {
      malloc.free(p);
    }
  }

  static final Map<FushiWebCoreLibrary, ffi.NativeFinalizer> _finalizers =
      <FushiWebCoreLibrary, ffi.NativeFinalizer>{};

  static ffi.NativeFinalizer _finalizerFor(FushiWebCoreLibrary lib) =>
      _finalizers.putIfAbsent(
        lib,
        () => ffi.NativeFinalizer(
          lib.bindings.fwc_novel_session_close_ptr.cast(),
        ),
      );

  final FushiWebCoreLibrary _library;
  ffi.Pointer<FwcNovelSession> _handle;

  /// 后台 isolate 里还在用句柄的 [ingest] 数；>0 时 [close] 推迟到最后一个结束。
  int _inflight = 0;
  bool _closeRequested = false;

  bool get isClosed => _handle == ffi.nullptr || _closeRequested;

  ffi.Pointer<FwcNovelSession> get _live {
    if (isClosed) throw StateError('WebNovelSession is closed');
    return _handle;
  }

  /// 喂一页：提取 + 并进会话（后台 isolate，一次 FFI 调用）。
  Future<WebNovelIngest> ingest(Uint8List html, Uri url) async {
    final int session = _live.address;
    _inflight++;
    final Uint8List frame;
    try {
      frame = await _runOnNativeCopy(
        _library,
        html,
        url,
        (
          FushiWebCoreLibrary l,
          ffi.Pointer<ffi.Uint8> h,
          int hl,
          ffi.Pointer<ffi.Uint8> u,
          int ul,
          ffi.Pointer<ffi.Size> out,
        ) => l.bindings.fwc_novel_session_ingest(
          ffi.Pointer<FwcNovelSession>.fromAddress(session),
          h,
          hl,
          u,
          ul,
          out,
        ),
      );
    } finally {
      _inflight--;
      if (_inflight == 0 && _closeRequested) _release();
    }
    final ({Map<String, Object?> header, String body}) parts = _splitFrame(
      frame,
    );
    final Map<String, Object?> ingest =
        parts.header['ingest']! as Map<String, Object?>;
    return WebNovelIngest(
      article: WebArticle._fromJson(
        parts.header['article']! as Map<String, Object?>,
        parts.body,
      ),
      status: WebNovelIngestStatus.parse((ingest['status'] ?? '') as String),
      index: ingest['index'] as int?,
      chapterCount: (ingest['chapterCount'] ?? 0) as int,
      tailNext: ingest['tailNext'] as String?,
    );
  }

  /// 当前快照（几 KB，当前 isolate）。
  WebNovelSnapshot snapshot() {
    final Uint8List? bytes = _library.takeBytes(
      (ffi.Pointer<ffi.Size> out) =>
          _library.bindings.fwc_novel_session_snapshot(_live, out),
    );
    if (bytes == null) {
      throw StateError(_library.lastError() ?? 'snapshot failed');
    }
    return WebNovelSnapshot.tryParse(utf8.decode(bytes))!;
  }

  /// 关闭。还有 [ingest] 在后台 isolate 里跑时推迟到它结束（句柄不会在用着时被释放）。
  void close() {
    if (isClosed) return;
    _closeRequested = true;
    if (_inflight == 0) _release();
  }

  void _release() {
    if (_handle == ffi.nullptr) return;
    _finalizerFor(_library).detach(this);
    _library.bindings.fwc_novel_session_close(_handle);
    _handle = ffi.nullptr;
  }
}
