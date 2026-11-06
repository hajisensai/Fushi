import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _ScanC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Uint16>,
      Size,
      Pointer<Pointer<Uint16>>,
      Pointer<Size>,
    );
typedef _ScanDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Uint16>,
      int,
      Pointer<Pointer<Uint16>>,
      Pointer<Size>,
    );
typedef _FreeUnitsC = Void Function(Pointer<Uint16>, Size);
typedef _FreeUnitsDart = void Function(Pointer<Uint16>, int);

/// [EpubChapterScanner.scan] 的请求位（与 `native/fushi_compute/src/parse/epub.rs` 的
/// `flags` 同值）。
abstract final class EpubScanRequest {
  /// 纯文本 + 学习字数。
  static const int text = 1;

  /// ruby 读音轨（块尾 / 场景分隔）；必须与 [text] 同时请求。
  static const int ruby = 2;

  /// 目录锚点偏移（需要 wantedIds）。
  static const int anchors = 4;

  /// body 内带位置的插图扫描。
  static const int images = 8;

  /// 整份文档的图片引用（纯图片章判定）。
  static const int imageRefs = 16;

  /// 全书搜索坐标系的原始文本（只跳过 rt/rp、不折叠空白）。
  static const int searchText = 32;
}

/// 一处 ruby：基底在纯文本里的 UTF-16 区间与读音。
final class EpubScanRuby {
  const EpubScanRuby(this.start, this.end, this.reading);
  final int start;
  final int end;
  final String reading;
}

/// body 内的一处图片引用。
final class EpubScanImageHit {
  const EpubScanImageHit({
    required this.src,
    required this.charsBefore,
    required this.sharesLineWithText,
    required this.leadingAnchorIds,
  });
  final String src;
  final int charsBefore;
  final bool sharesLineWithText;
  final List<String> leadingAnchorIds;
}

/// 一次章节扫描的结果；没请求的部分为 null。
final class EpubChapterScan {
  EpubChapterScan._();

  /// 纯文本（ruby 已剥离、`\s+` 折叠、`trim`）。
  String? text;

  /// [text] 的学习字数。
  int? studyChars;
  List<EpubScanRuby>? rubies;
  List<int>? blockEnds;
  List<int>? sceneBreaks;

  /// wantedIds 下标 → 章内学习字数偏移（找不到的不在表里）。
  Map<int, int>? anchorOffsets;
  int? imageTotalChars;
  List<EpubScanImageHit>? imageHits;
  List<String>? imageRefs;

  /// 见 [EpubScanRequest.searchText]。
  String? searchText;
}

/// EPUB 章节 XHTML 的 DOM 派生量（`ffc_parse_epub_chapter`）。唯一实现在 Rust，没有
/// Dart 回退；原生库或符号缺失时 [instance] 抛 [FushiComputeUnavailableError]。
final class EpubChapterScanner implements Finalizable {
  EpubChapterScanner._(this._scan, this._freeUnits);

  final _ScanDart _scan;
  final _FreeUnitsDart _freeUnits;

  /// 固定输出槽：outPtr（指针）+ outLen（size_t），由 [NativeScratch] 持有、isolate 退出时释放。
  final NativeScratch _slots = NativeScratch.fixed(16);
  Pointer<Pointer<Uint16>> get _outPtr =>
      _slots.pointer.cast<Pointer<Uint16>>();
  Pointer<Size> get _outLen => (_slots.pointer + 8).cast<Size>();

  static EpubChapterScanner? _instance;

  /// 本 isolate 的实例。
  static EpubChapterScanner get instance => _instance ??= _load();

  static EpubChapterScanner _load() {
    final FushiCompute compute = FushiCompute.require();
    try {
      return EpubChapterScanner._(
        compute.library.lookupFunction<_ScanC, _ScanDart>(
          'ffc_parse_epub_chapter',
        ),
        compute.library.lookupFunction<_FreeUnitsC, _FreeUnitsDart>(
          'ffc_parse_free_units',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 扫描一章。[html] 必须已经过 `normalizeSelfClosingRawTextTags`。
  EpubChapterScan scan(
    String html,
    int request, {
    List<String> wantedIds = const <String>[],
  }) {
    final Uint8List bytes = utf8.encode(html);
    final Pointer<Uint8> htmlPtr = calloc<Uint8>(
      bytes.isEmpty ? 1 : bytes.length,
    );
    Pointer<Uint16> wantedPtr = nullptr;
    int wantedLen = 0;
    try {
      htmlPtr.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
      if (wantedIds.isNotEmpty) {
        for (final String id in wantedIds) {
          wantedLen += 2 + id.length;
        }
        wantedPtr = calloc<Uint16>(wantedLen);
        final Uint16List w = wantedPtr.asTypedListOutOfLine(wantedLen);
        int o = 0;
        for (final String id in wantedIds) {
          w[o++] = id.length & 0xFFFF;
          w[o++] = id.length >> 16;
          for (int i = 0; i < id.length; i++) {
            w[o++] = id.codeUnitAt(i);
          }
        }
      }
      final int status = _scan(
        htmlPtr,
        bytes.length,
        request,
        wantedPtr,
        wantedLen,
        _outPtr,
        _outLen,
      );
      if (status == FfcStatus.badInput) {
        // 旧 `package:html` 的 `parse()` 在这类输入上抛异常（数字字符引用溢出 64 位
        // 等），这里同样抛，调用方的「这一章解析失败」分支照旧生效。
        throw const FormatException(
          'ffc_parse_epub_chapter: chapter HTML cannot be parsed',
        );
      }
      if (status != FfcStatus.ok) {
        throw StateError('ffc_parse_epub_chapter failed with status $status');
      }
      final Pointer<Uint16> out = _outPtr.value;
      final int len = _outLen.value;
      try {
        return _decode(out.asTypedListOutOfLine(len), request);
      } finally {
        _freeUnits(out, len);
      }
    } finally {
      calloc.free(htmlPtr);
      if (wantedPtr != nullptr) calloc.free(wantedPtr);
    }
  }

  static EpubChapterScan _decode(Uint16List u, int request) {
    int o = 0;
    int u32() {
      final int v = u[o] | (u[o + 1] << 16);
      o += 2;
      return v;
    }

    String str() {
      final int n = u32();
      final String s = String.fromCharCodes(
        Uint16List.sublistView(u, o, o + n),
      );
      o += n;
      return s;
    }

    final EpubChapterScan r = EpubChapterScan._();
    if (request & EpubScanRequest.text != 0) {
      r.studyChars = u32();
      r.text = str();
      if (request & EpubScanRequest.ruby != 0) {
        final int n = u32();
        r.rubies = <EpubScanRuby>[
          for (int i = 0; i < n; i++) EpubScanRuby(u32(), u32(), str()),
        ];
        final int b = u32();
        r.blockEnds = <int>[for (int i = 0; i < b; i++) u32()];
        final int s = u32();
        r.sceneBreaks = <int>[for (int i = 0; i < s; i++) u32()];
      }
    }
    if (request & EpubScanRequest.anchors != 0) {
      final int n = u32();
      final Map<int, int> m = <int, int>{};
      for (int i = 0; i < n; i++) {
        final int w = u32();
        m[w] = u32();
      }
      r.anchorOffsets = m;
    }
    if (request & EpubScanRequest.images != 0) {
      r.imageTotalChars = u32();
      final int n = u32();
      final List<EpubScanImageHit> hits = <EpubScanImageHit>[];
      for (int i = 0; i < n; i++) {
        final String src = str();
        final int before = u32();
        final bool line = u32() != 0;
        final int k = u32();
        hits.add(
          EpubScanImageHit(
            src: src,
            charsBefore: before,
            sharesLineWithText: line,
            leadingAnchorIds: List<String>.unmodifiable(<String>[
              for (int j = 0; j < k; j++) str(),
            ]),
          ),
        );
      }
      r.imageHits = hits;
    }
    if (request & EpubScanRequest.imageRefs != 0) {
      final int n = u32();
      r.imageRefs = <String>[for (int i = 0; i < n; i++) str()];
    }
    if (request & EpubScanRequest.searchText != 0) {
      r.searchText = str();
    }
    return r;
  }
}
