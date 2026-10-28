import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_disc_meta_files.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

export 'package:fushi_engine/media/video/bluray/bluray_disc_meta_files.dart'
    show blurayLanguageCodes, orderBlurayDiscMetadataFiles;

/// One image a disclib document declares: `BDMV/META/DL/bdmt_<lang>.xml`
/// names images that sit beside it, e.g.
/// `<di:thumbnail href="./L.jpg" size="640x360"/>` (the element name is the
/// spec's). The declared size is untrusted; [readBlurayDiscArtwork] measures
/// the image itself.
class BlurayDiscArtworkRef {
  const BlurayDiscArtworkRef({required this.href});

  /// Relative to `BDMV/META/DL`, already checked to stay inside it.
  final String href;
}

/// A disc artwork image with its measured pixel size.
class BlurayDiscArtwork {
  const BlurayDiscArtwork({
    required this.path,
    required this.width,
    required this.height,
  });

  final String path;
  final int width;
  final int height;

  double get aspect => width / height;
  int get area => width * height;
}

/// Every image one disclib document declares, in document order.
List<BlurayDiscArtworkRef> parseBlurayDiscArtworkRefs(String xmlSource) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xmlSource);
  } on XmlException {
    return const <BlurayDiscArtworkRef>[];
  }
  return <BlurayDiscArtworkRef>[
    for (final XmlElement element
        in document.descendants.whereType<XmlElement>())
      if (element.name.local == 'thumbnail')
        if (_containedHref(element.getAttribute('href')) case final String href)
          BlurayDiscArtworkRef(href: href),
  ];
}

/// Disc metadata is untrusted: only plain names inside `META/DL` qualify.
String? _containedHref(String? raw) {
  if (raw == null) return null;
  final String trimmed = raw.trim().replaceAll('\\', '/');
  if (trimmed.isEmpty || trimmed.contains(':')) return null;
  final String normalized = p.posix.normalize(trimmed);
  if (p.posix.isAbsolute(normalized) ||
      normalized == '.' ||
      normalized.split('/').contains('..')) {
    return null;
  }
  return normalized;
}

/// How much of the file one read pulls in. A PNG's IHDR sits in the first 24
/// bytes and a JPEG's SOF follows the APPn segments, which almost always fit;
/// a larger APPn (embedded EXIF preview, ICC profile) only costs one more
/// read at the segment's end.
const int _kHeaderWindowBytes = 64 * 1024;

/// JPEG segments walked before giving up on finding a SOF.
const int _kMaxJpegSegments = 256;

/// Pixel size read from [file]'s header only (PNG IHDR / JPEG SOFn), never
/// decoding the image. Null when it is neither format or the header is
/// malformed: disc files are untrusted input.
Future<({int width, int height})?> readImageHeaderSize(File file) async {
  final RandomAccessFile raf;
  try {
    raf = await file.open();
  } on FileSystemException {
    return null;
  }
  try {
    final _HeaderReader reader = _HeaderReader(raf, await raf.length());
    final ({int width, int height})? size =
        await _pngSize(reader) ?? await _jpegSize(reader);
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    return size;
  } on FileSystemException {
    return null;
  } finally {
    await raf.close();
  }
}

const List<int> _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

Future<({int width, int height})?> _pngSize(_HeaderReader r) async {
  for (int i = 0; i < _pngSignature.length; i++) {
    if (await r.u8(i) != _pngSignature[i]) return null;
  }
  // Signature, then the first chunk must be IHDR: length(4) type(4) w(4) h(4).
  if (await r.u32(12) != 0x49484452) return null;
  final int? width = await r.u32(16);
  final int? height = await r.u32(20);
  if (width == null || height == null) return null;
  return (width: width, height: height);
}

Future<({int width, int height})?> _jpegSize(_HeaderReader r) async {
  if (await r.u8(0) != 0xFF || await r.u8(1) != 0xD8) return null;
  int offset = 2;
  for (int segment = 0; segment < _kMaxJpegSegments; segment++) {
    if (await r.u8(offset) != 0xFF) return null;
    // Fill bytes: any number of 0xFF may precede the marker code.
    int? marker = await r.u8(offset + 1);
    while (marker == 0xFF) {
      offset++;
      marker = await r.u8(offset + 1);
    }
    if (marker == null) return null;
    offset += 2;
    // Standalone markers carry no length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    // End of image / start of scan before any frame header: no size.
    if (marker == 0xD9 || marker == 0xDA) return null;
    final int? length = await r.u16(offset);
    if (length == null || length < 2) return null;
    final bool isFrameHeader =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrameHeader) {
      // length(2) precision(1) height(2) width(2)
      final int? height = await r.u16(offset + 3);
      final int? width = await r.u16(offset + 5);
      if (width == null || height == null) return null;
      return (width: width, height: height);
    }
    offset += length;
  }
  return null;
}

/// Random access over a file through one [_kHeaderWindowBytes] window,
/// re-read only when an offset falls outside it.
class _HeaderReader {
  _HeaderReader(this._raf, this._length);

  final RandomAccessFile _raf;
  final int _length;
  int _windowStart = 0;
  Uint8List _window = Uint8List(0);

  Future<int?> u8(int offset) async {
    if (offset < 0 || offset >= _length) return null;
    if (offset < _windowStart || offset >= _windowStart + _window.length) {
      await _raf.setPosition(offset);
      _window = await _raf.read(
        math.min(_kHeaderWindowBytes, _length - offset),
      );
      _windowStart = offset;
      if (_window.isEmpty) return null;
    }
    return _window[offset - _windowStart];
  }

  Future<int?> u16(int offset) async {
    final int? hi = await u8(offset);
    final int? lo = await u8(offset + 1);
    if (hi == null || lo == null) return null;
    return (hi << 8) | lo;
  }

  Future<int?> u32(int offset) async {
    final int? hi = await u16(offset);
    final int? lo = await u16(offset + 2);
    if (hi == null || lo == null) return null;
    return (hi << 16) | lo;
  }
}

const int _kMaxMetadataBytes = 256 * 1024;
const int _kMaxArtworkBytes = 16 * 1024 * 1024;

/// The disc's own artwork under [discRootPath], each image measured from its
/// header: the first metadata language (see [orderBlurayDiscMetadataFiles])
/// that yields at least one readable image wins, and all of its images are
/// returned. Empty when the disc declares none.
Future<List<BlurayDiscArtwork>> readBlurayDiscArtwork(
  String discRootPath, {
  required List<String> preferredLanguages,
}) async {
  final Directory dl = Directory(p.join(discRootPath, 'BDMV', 'META', 'DL'));
  final List<String> names;
  try {
    names = <String>[
      await for (final FileSystemEntity e in dl.list(followLinks: false))
        if (e is File) p.basename(e.path),
    ];
  } on FileSystemException {
    return const <BlurayDiscArtwork>[];
  }
  for (final String name in orderBlurayDiscMetadataFiles(
    names,
    preferredLanguages: preferredLanguages,
  )) {
    final List<BlurayDiscArtwork> artwork = <BlurayDiscArtwork>[];
    try {
      final File xml = File(p.join(dl.path, name));
      // Bound allocation for malformed/untrusted disc metadata.
      if (await xml.length() > _kMaxMetadataBytes) continue;
      for (final BlurayDiscArtworkRef ref in parseBlurayDiscArtworkRefs(
        await xml.readAsString(),
      )) {
        final File file = File(
          p.joinAll(<String>[dl.path, ...ref.href.split('/')]),
        );
        // The chosen image is copied into the cover directory later: bound it.
        if (!await file.exists() || await file.length() > _kMaxArtworkBytes) {
          continue;
        }
        final ({int width, int height})? size = await readImageHeaderSize(file);
        if (size == null) continue;
        artwork.add(
          BlurayDiscArtwork(
            path: file.path,
            width: size.width,
            height: size.height,
          ),
        );
      }
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
    if (artwork.isNotEmpty) return artwork;
  }
  return const <BlurayDiscArtwork>[];
}
