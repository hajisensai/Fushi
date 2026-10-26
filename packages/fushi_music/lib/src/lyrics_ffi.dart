import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';
import 'lyric_timeline.dart';

typedef _VersionC = Uint32 Function();
typedef _VersionDart = int Function();
typedef _ParseC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Int64,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _EmbeddedC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Int64,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _EmbeddedDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _MergeC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _MergeDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Bin2C =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Bin2Dart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

typedef _Bin1C =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Bin1Dart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// ASS 原样渲染（设计 §6.3）要喂给 libass 的脚本：已统一成 UTF-8，带画布尺寸
/// （`PlayResX/Y`，缺省按 libass 的规则补齐）。
class AssRawScript {
  const AssRawScript({
    required this.text,
    required this.playResX,
    required this.playResY,
  });

  final String text;
  final int playResX;
  final int playResY;
}

/// 歌词解析失败（格式不对 / 不支持的加密变体）。业务层失败：界面提示「这份歌词读不了」。
final class LyricsParseException implements Exception {
  const LyricsParseException(this.message);

  final String message;

  @override
  String toString() => 'LyricsParseException: $message';
}

/// 一条文件内嵌歌词。
class EmbeddedLyrics {
  const EmbeddedLyrics({
    required this.key,
    required this.format,
    required this.raw,
    required this.timeline,
  });

  /// 来源键：`lyrics`（USLT / Vorbis LYRICS / ©lyr）/ `unsyncedlyrics` / `sylt`。
  final String key;

  /// 解析出的格式（内嵌文本常常是一整份 LRC）。
  final String format;

  /// 可回存 `music_lyrics.raw` 的原文（SYLT 导出成增强 LRC）。
  final Uint8List raw;
  final LyricTimeline timeline;
}

class _LyricsBindings {
  _LyricsBindings(this._lib) {
    try {
      version = _lib.library.lookupFunction<_VersionC, _VersionDart>(
        'ffm_lyrics_parser_version',
      );
      parse = _lib.library.lookupFunction<_ParseC, _ParseDart>(
        'ffm_lyrics_parse',
      );
      embedded = _lib.library.lookupFunction<_EmbeddedC, _EmbeddedDart>(
        'ffm_lyrics_embedded',
      );
      merge = _lib.library.lookupFunction<_MergeC, _MergeDart>(
        'ffm_lyrics_merge',
      );
      export = _lib.library.lookupFunction<_Bin2C, _Bin2Dart>(
        'ffm_lyrics_export',
      );
      assRaw = _lib.library.lookupFunction<_Bin1C, _Bin1Dart>(
        'ffm_lyrics_ass_raw',
      );
    } on ArgumentError catch (e) {
      throw _lib.missingSymbols('lyrics', e);
    }
  }

  final FushiMusic _lib;
  late final _VersionDart version;
  late final _ParseDart parse;
  late final _EmbeddedDart embedded;
  late final _MergeDart merge;
  late final _Bin2Dart export;
  late final _Bin1Dart assRaw;

  static _LyricsBindings? _instance;
  static _LyricsBindings get instance =>
      _instance ??= _LyricsBindings(FushiMusic.instance);

  /// 跑一次调用：分配输出指针、取回并释放 Rust 缓冲区。
  ({int status, Uint8List bytes}) call(
    int Function(Arena arena, Pointer<Pointer<Uint8>> out, Pointer<Size> len)
    body,
  ) => using((Arena arena) {
    final Pointer<Pointer<Uint8>> out = arena<Pointer<Uint8>>();
    final Pointer<Size> len = arena<Size>();
    out.value = nullptr;
    len.value = 0;
    final int rc = body(arena, out, len);
    final Uint8List bytes = out.value == nullptr
        ? Uint8List(0)
        : Uint8List.fromList(out.value.asTypedListOutOfLine(len.value));
    if (out.value != nullptr) _lib.freeBytes(out.value, len.value);
    return (status: rc, bytes: bytes);
  });
}

Pointer<Uint8> _copyIn(Uint8List bytes, Allocator alloc) {
  final Pointer<Uint8> p = alloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  return p;
}

/// 歌词胖核心（native/fushi_music/src/lyrics）的同步入口。每个方法 = 一次 FFI 调用、整首处理。
///
/// 解析一般远小于 1 ms，但大文件 / 内嵌读取（IO）会更久：UI isolate 用 [FushiLyricsAsync]。
abstract final class FushiLyrics {
  /// 解析器版本：`music_lyrics.timeline_version` 不等于它的缓存要重建。
  static int get parserVersion => _LyricsBindings.instance.version();

  /// 任意格式 → 统一时间轴。[hint] 是扩展名或格式名（可空，空时按内容嗅探）；
  /// [durationMs] 是曲长（补最后一行终点），未知传 null。失败抛 [LyricsParseException]。
  static LyricTimeline parse(
    Uint8List bytes, {
    String hint = '',
    int? durationMs,
  }) {
    final _LyricsBindings b = _LyricsBindings.instance;
    final Uint8List h = utf8.encode(hint);
    final ({int status, Uint8List bytes}) r = b.call(
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) => b.parse(
        _copyIn(bytes, a),
        bytes.length,
        _copyIn(h, a),
        h.length,
        durationMs ?? -1,
        out,
        len,
      ),
    );
    if (r.status == FfmStatus.badInput) {
      throw LyricsParseException(utf8.decode(r.bytes, allowMalformed: true));
    }
    if (r.status != FfmStatus.ok) {
      throw StateError('ffm_lyrics_parse failed with status ${r.status}');
    }
    return decodeLyricTimeline(r.bytes);
  }

  /// 读音频文件的内嵌歌词（可能多条）。文件读不了抛 [LyricsParseException]。
  static List<EmbeddedLyrics> embedded(String path, {int? durationMs}) {
    final _LyricsBindings b = _LyricsBindings.instance;
    final Uint8List p = utf8.encode(path);
    final ({int status, Uint8List bytes}) r = b.call(
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) =>
          b.embedded(_copyIn(p, a), p.length, durationMs ?? -1, out, len),
    );
    if (r.status == FfmStatus.badInput) {
      throw LyricsParseException(utf8.decode(r.bytes, allowMalformed: true));
    }
    if (r.status != FfmStatus.ok) {
      throw StateError('ffm_lyrics_embedded failed with status ${r.status}');
    }
    final ByteData v = ByteData.sublistView(r.bytes);
    int pos = 0;
    int u32() {
      final int x = v.getUint32(pos, Endian.little);
      pos += 4;
      return x;
    }

    Uint8List bytes() {
      final int n = u32();
      final Uint8List s = Uint8List.sublistView(r.bytes, pos, pos + n);
      pos += n;
      return s;
    }

    final int count = u32();
    return <EmbeddedLyrics>[
      for (int i = 0; i < count; i++)
        EmbeddedLyrics(
          key: utf8.decode(bytes()),
          format: utf8.decode(bytes()),
          raw: Uint8List.fromList(bytes()),
          timeline: decodeLyricTimeline(Uint8List.fromList(bytes())),
        ),
    ];
  }

  /// 原文 + 翻译按时间配对（≤ 300 ms 同行；对不上的成独立行）。
  static LyricTimeline mergeTranslation(
    LyricTimeline primary,
    LyricTimeline secondary,
    String lang,
  ) {
    final _LyricsBindings b = _LyricsBindings.instance;
    final Uint8List p = encodeLyricTimeline(primary);
    final Uint8List s = encodeLyricTimeline(secondary);
    final Uint8List l = utf8.encode(lang);
    final ({int status, Uint8List bytes}) r = b.call(
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) => b.merge(
        _copyIn(p, a),
        p.length,
        _copyIn(s, a),
        s.length,
        _copyIn(l, a),
        l.length,
        out,
        len,
      ),
    );
    if (r.status != FfmStatus.ok) {
      throw StateError('ffm_lyrics_merge failed with status ${r.status}');
    }
    return decodeLyricTimeline(r.bytes);
  }

  /// 导出成 `ttml`（无损）或 `lrc`（丢声部 / 和声 / 注音）。
  static Uint8List export(LyricTimeline timeline, String format) {
    final _LyricsBindings b = _LyricsBindings.instance;
    final Uint8List t = encodeLyricTimeline(timeline);
    final Uint8List f = utf8.encode(format);
    final ({int status, Uint8List bytes}) r = b.call(
      (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) =>
          b.export(_copyIn(t, a), t.length, _copyIn(f, a), f.length, out, len),
    );
    if (r.status != FfmStatus.ok) {
      throw StateError('ffm_lyrics_export($format) failed: ${r.status}');
    }
    return r.bytes;
  }
}

/// ASS 原样渲染的准备（任意编码 → UTF-8 + 画布尺寸），整份一次 FFI。
AssRawScript prepareAssRawScript(Uint8List bytes) {
  final _LyricsBindings b = _LyricsBindings.instance;
  final ({int status, Uint8List bytes}) r = b.call(
    (Arena a, Pointer<Pointer<Uint8>> out, Pointer<Size> len) =>
        b.assRaw(_copyIn(bytes, a), bytes.length, out, len),
  );
  if (r.status != FfmStatus.ok || r.bytes.length < 8) {
    throw StateError('ffm_lyrics_ass_raw failed with status ${r.status}');
  }
  final ByteData v = ByteData.sublistView(r.bytes);
  return AssRawScript(
    playResX: v.getUint32(0, Endian.little),
    playResY: v.getUint32(4, Endian.little),
    text: utf8.decode(Uint8List.sublistView(r.bytes, 8), allowMalformed: true),
  );
}

/// 后台 isolate 版本（UI isolate 用这些）：每次调用在 [Isolate.run] 里加载库并执行。
abstract final class FushiLyricsAsync {
  static Future<LyricTimeline> parse(
    Uint8List bytes, {
    String hint = '',
    int? durationMs,
  }) => Isolate.run(
    () => FushiLyrics.parse(bytes, hint: hint, durationMs: durationMs),
  );

  static Future<List<EmbeddedLyrics>> embedded(
    String path, {
    int? durationMs,
  }) => Isolate.run(() => FushiLyrics.embedded(path, durationMs: durationMs));

  static Future<AssRawScript> assRaw(Uint8List bytes) =>
      Isolate.run(() => prepareAssRawScript(bytes));
}
