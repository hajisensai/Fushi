import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../ffi/fushi_web_core_bindings.dart';
import '../fushi_web_core_library.dart';

/// 章末广告页判定规则（Rust `ComicAdRules`；默认值由 Rust 给，见 [ComicAdRules.defaults]）。
class ComicAdRules {
  const ComicAdRules({
    required this.tailWindow,
    required this.protectedLeadingPages,
    required this.colorfulThreshold,
    required this.analysisMaxSide,
  });

  /// 原生库内置的默认规则（最后 10 张、前 3 张永不判、彩色占比 0.12、长边缩到 900）。
  factory ComicAdRules.defaults({FushiWebCoreLibrary? library}) {
    final FwcComicAdRules r = (library ?? FushiWebCoreLibrary.instance).bindings
        .fwc_comic_ad_default_rules();
    return ComicAdRules(
      tailWindow: r.tailWindow,
      protectedLeadingPages: r.protectedLeadingPages,
      colorfulThreshold: r.colorfulThreshold,
      analysisMaxSide: r.analysisMaxSide,
    );
  }

  /// 只判一章最后这么多张。
  final int tailWindow;

  /// 一章开头永不判广告的张数。
  final int protectedLeadingPages;

  /// 彩色像素占比阈值。
  final double colorfulThreshold;

  /// 判定前把长边缩到这么多像素。
  final int analysisMaxSide;

  void _writeTo(ffi.Pointer<FwcComicAdRules> p) {
    p.ref
      ..tailWindow = tailWindow
      ..protectedLeadingPages = protectedLeadingPages
      ..colorfulThreshold = colorfulThreshold
      ..analysisMaxSide = analysisMaxSide;
  }
}

/// 单张图的结论。
enum ComicAdVerdict {
  /// 正文页。
  content,

  /// 广告页。
  ad,

  /// 解码失败 / 太小：按正文保留（判广告只许漏判，不许误删）。
  undecodable;

  static ComicAdVerdict fromCode(int code) => switch (code) {
    1 => ComicAdVerdict.ad,
    0 => ComicAdVerdict.content,
    _ => ComicAdVerdict.undecodable,
  };
}

/// 网页漫画章末广告页识别（只用于网页漫画来源；判据在 Rust `comic_ad` 模块）。
class ComicAdDetector {
  ComicAdDetector({FushiWebCoreLibrary? library, ComicAdRules? rules})
    : _library = library ?? FushiWebCoreLibrary.instance,
      _rules = rules;

  final FushiWebCoreLibrary _library;
  ComicAdRules? _rules;

  /// 生效规则（默认取原生库内置值）。
  ComicAdRules get rules => _rules ??= ComicAdRules.defaults(library: _library);

  /// 一章 [pageCount] 张里要判定的页序（升序，区间 `[start, pageCount)`）。
  List<int> candidateIndices(int pageCount) {
    final ffi.Pointer<FwcComicAdRules> r = calloc<FwcComicAdRules>();
    try {
      rules._writeTo(r);
      final int start = _library.bindings.fwc_comic_ad_candidate_start(
        pageCount,
        r,
      );
      return <int>[for (int i = start; i < pageCount; i++) i];
    } finally {
      calloc.free(r);
    }
  }

  /// 批量判定（一章末尾的若干张）：在**当前 isolate** 把每张字节拷一次进原生内存，
  /// 后台 isolate 里一次 FFI 调用判完整批（Rust 内部多线程），只把指针地址带过去，
  /// 不经 isolate 消息拷贝图片。结果与 [images] 一一对应。
  Future<List<ComicAdVerdict>> detect(List<Uint8List> images) async {
    final int count = images.length;
    if (count == 0) return const <ComicAdVerdict>[];
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> ptrs =
        malloc<ffi.Pointer<ffi.Uint8>>(count);
    final ffi.Pointer<ffi.Size> lens = malloc<ffi.Size>(count);
    final ffi.Pointer<ffi.Uint8> out = malloc<ffi.Uint8>(count);
    final ffi.Pointer<FwcComicAdRules> r = malloc<FwcComicAdRules>();
    final List<ffi.Pointer<ffi.Uint8>> owned = <ffi.Pointer<ffi.Uint8>>[];
    try {
      rules._writeTo(r);
      for (int i = 0; i < count; i++) {
        final Uint8List bytes = images[i];
        final ffi.Pointer<ffi.Uint8> p = malloc<ffi.Uint8>(
          bytes.isEmpty ? 1 : bytes.length,
        );
        owned.add(p);
        p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
        ptrs[i] = p;
        lens[i] = bytes.length;
      }
      final String? path = _library.libraryPath;
      final int rAddr = r.address;
      final int pAddr = ptrs.address;
      final int lAddr = lens.address;
      final int oAddr = out.address;
      final int rc = await Isolate.run<int>(() {
        final FushiWebCoreLibrary lib = FushiWebCoreLibrary.load(
          libraryPath: path,
        );
        return lib.bindings.fwc_comic_ad_detect_batch(
          ffi.Pointer<FwcComicAdRules>.fromAddress(rAddr),
          ffi.Pointer<ffi.Pointer<ffi.Uint8>>.fromAddress(pAddr),
          ffi.Pointer<ffi.Size>.fromAddress(lAddr),
          count,
          ffi.Pointer<ffi.Uint8>.fromAddress(oAddr),
        );
      });
      if (rc != 0) {
        throw StateError('fwc_comic_ad_detect_batch failed');
      }
      return <ComicAdVerdict>[
        for (int i = 0; i < count; i++) ComicAdVerdict.fromCode(out[i]),
      ];
    } finally {
      for (final ffi.Pointer<ffi.Uint8> p in owned) {
        malloc.free(p);
      }
      malloc
        ..free(ptrs)
        ..free(lens)
        ..free(out)
        ..free(r);
    }
  }
}
