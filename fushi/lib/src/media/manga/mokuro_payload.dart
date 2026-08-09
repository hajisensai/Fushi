import 'dart:convert';
import 'dart:ui';

/// Parameters that define a series of images and metadata about each image.
///
/// This is the in-memory shape shared by both producers of manga OCR data
/// (`.mokuro` file import and the app's own OCR engine) and the single source
/// of truth the reader overlay renders from. Both [parseMokuro] (raw
/// `.mokuro` JSON) and [parseMangaJson] (the internal `manga.json` format)
/// produce this type; [mangaPayloadToJson] serialises it back to `manga.json`.
class MokuroPayload {
  /// Initialise this object.
  const MokuroPayload({
    required this.images,
    this.ocr,
  });

  /// All images in sequential order.
  final List<MokuroImage> images;

  /// Optional producer metadata. Older manga.json files omit it.
  final MangaOcrMetadata? ocr;

  @override
  String toString() {
    return '$runtimeType(images: '
        '[${images.map((MokuroImage e) => e.toString()).join(', ')}])';
  }
}

class MangaOcrMetadata {
  const MangaOcrMetadata({
    required this.engine,
    required this.engineSignature,
    required this.schemaVersion,
  });

  final String engine;
  final String engineSignature;
  final int schemaVersion;
}

/// Contains all information needed to render an image, including any text
/// coordinate information and the display image itself.
class MokuroImage {
  /// Initialise this object.
  const MokuroImage({
    required this.url,
    required this.size,
    required this.blocks,
  });

  /// The image file pertaining to this image.
  ///
  /// Always a forward-slash relative URL that preserves the source's
  /// sub-directory structure (e.g. `vol1/p001.jpg`), so two identically named
  /// pages under different sub-directories never collide (see design §5).
  final String url;

  /// Dimensions of the image (pixels, as reported by the OCR producer — never
  /// decoded from the image file).
  final Size size;

  /// The blocks of text for this image.
  final List<MokuroBlock> blocks;

  @override
  String toString() {
    return '$runtimeType(url: $url, size: $size, blocks: '
        '[${blocks.map((MokuroBlock e) => e.toString()).join(', ')}])';
  }
}

/// Coordinate information for a single group of text that can have multiple
/// lines.
class MokuroBlock {
  /// Initialise this object.
  const MokuroBlock({
    required this.rectangle,
    required this.isVertical,
    required this.fontSize,
    required this.zIndex,
    required this.lines,
    this.linesCoords,
    this.regions,
  });

  /// Coordinates for this block (the `box` = `[x1, y1, x2, y2]`).
  final Rect rectangle;

  /// Whether or not the text for this block should be rendered as vertical
  /// text.
  final bool isVertical;

  /// The font size that this block should be rendered with.
  final double fontSize;

  /// The z-index of this block, to allow prioritising which block should
  /// come first in a stack.
  final int zIndex;

  /// The individual lines to be rendered.
  final List<String> lines;

  /// Optional per-line polygon coordinates (`lines_coords`), when the producer
  /// provides them. Each line is a list of `[x, y]` points. mokuro emits these
  /// via ctd; the app's own detector does not, so this is `null` for internal
  /// OCR. Preserved verbatim through parse → serialise round-trips but not
  /// required for overlay rendering (which only needs the block `box`).
  final List<List<List<double>>>? linesCoords;

  /// Optional character-level hit regions.
  ///
  /// Google Lens only exposes line geometry. The Lens adapter follows
  /// Niratan and subdivides each line into approximate character rectangles,
  /// retaining UTF-16 offsets into [lines] joined without separators. Other
  /// OCR producers may omit this field and keep using the block-level overlay.
  final List<MangaOcrTextRegion>? regions;

  @override
  String toString() {
    return '$runtimeType(rectangle: $rectangle, isVertical: $isVertical, '
        'fontSize: $fontSize, lines: '
        '[${lines.join(', ')}])';
  }
}

/// A character or grapheme hit target inside a [MokuroBlock].
///
/// Coordinates use original page pixels, matching [MokuroBlock.rectangle].
/// [utf16Start] and [utf16End] index the block sentence
/// (`block.lines.join()`), so the WebView can keep the existing dictionary
/// selection payload without embedding OCR text in JavaScript attributes.
class MangaOcrTextRegion {
  const MangaOcrTextRegion({
    required this.rectangle,
    required this.utf16Start,
    required this.utf16End,
  });

  final Rect rectangle;
  final int utf16Start;
  final int utf16End;
}

/// Normalise a relative path into a forward-slash `manga.json` URL.
///
/// Converts Windows back-slashes to forward slashes and trims a leading slash
/// so URLs stay relative and portable across platforms/sync. Sub-directory
/// structure is preserved (never flattened to a basename).
String normalizeMangaUrl(String raw) {
  final String forward = raw.replaceAll('\\', '/');
  return forward.startsWith('/') ? forward.substring(1) : forward;
}

/// Parse a modern mokuro (v0.2+) `.mokuro` JSON document into a
/// [MokuroPayload]. Tolerant of missing fields: `font_size` defaults to 0,
/// `vertical` defaults to false, `lines` defaults to empty, and `zIndex`
/// (which has no mokuro field) is assigned from the block's array index.
/// `img_path` is normalised to a forward-slash relative URL via
/// [normalizeMangaUrl]. `lines_coords` is preserved when present.
MokuroPayload parseMokuro(String jsonStr) {
  final Object? decoded = jsonDecode(jsonStr);
  if (decoded is! Map) {
    return const MokuroPayload(images: <MokuroImage>[]);
  }

  final Object? rawPages = decoded['pages'];
  if (rawPages is! List) {
    return const MokuroPayload(images: <MokuroImage>[]);
  }

  final List<MokuroImage> images = <MokuroImage>[];
  for (final Object? rawPage in rawPages) {
    if (rawPage is! Map) {
      continue;
    }

    final double width = _asDouble(rawPage['img_width']);
    final double height = _asDouble(rawPage['img_height']);
    final String url =
        normalizeMangaUrl((rawPage['img_path'] as String?) ?? '');

    final List<MokuroBlock> blocks = <MokuroBlock>[];
    final Object? rawBlocks = rawPage['blocks'];
    if (rawBlocks is List) {
      for (int i = 0; i < rawBlocks.length; i++) {
        final Object? rawBlock = rawBlocks[i];
        if (rawBlock is! Map) {
          continue;
        }
        blocks.add(_parseBlock(rawBlock, i, zIndexKey: null));
      }
    }

    images.add(
      MokuroImage(
        url: url,
        size: Size(width, height),
        blocks: blocks,
      ),
    );
  }

  return MokuroPayload(images: images);
}

/// Parse the internal `manga.json` format
/// (`{pages:[{url,width,height,blocks:[{box,vertical,font_size,z_index,lines,
/// lines_coords?}]}]}`) back into a [MokuroPayload]. This is the inverse of
/// [mangaPayloadToJson]. Unlike [parseMokuro], the block z-index is read from
/// the explicit `z_index` field (falling back to the array index when absent).
MokuroPayload parseMangaJson(String jsonStr) {
  final Object? decoded = jsonDecode(jsonStr);
  if (decoded is! Map) {
    return const MokuroPayload(images: <MokuroImage>[]);
  }

  final Object? rawPages = decoded['pages'];
  if (rawPages is! List) {
    return const MokuroPayload(images: <MokuroImage>[]);
  }

  final List<MokuroImage> images = <MokuroImage>[];
  for (final Object? rawPage in rawPages) {
    if (rawPage is! Map) {
      continue;
    }

    final double width = _asDouble(rawPage['width']);
    final double height = _asDouble(rawPage['height']);
    final String url = normalizeMangaUrl((rawPage['url'] as String?) ?? '');

    final List<MokuroBlock> blocks = <MokuroBlock>[];
    final Object? rawBlocks = rawPage['blocks'];
    if (rawBlocks is List) {
      for (int i = 0; i < rawBlocks.length; i++) {
        final Object? rawBlock = rawBlocks[i];
        if (rawBlock is! Map) {
          continue;
        }
        blocks.add(_parseBlock(rawBlock, i, zIndexKey: 'z_index'));
      }
    }

    images.add(
      MokuroImage(
        url: url,
        size: Size(width, height),
        blocks: blocks,
      ),
    );
  }

  return MokuroPayload(
    images: images,
    ocr: _parseOcrMetadata(decoded['ocr']),
  );
}

/// Serialise a [MokuroPayload] into the internal `manga.json` structure
/// (`{pages:[{url,width,height,blocks:[{box,vertical,font_size,z_index,lines,
/// lines_coords?}]}]}`). URLs are kept as-is (already forward-slash by
/// construction); `lines_coords` is only emitted when present. Callers that
/// need a string call `jsonEncode(mangaPayloadToJson(payload))`.
Map<String, Object?> mangaPayloadToJson(MokuroPayload payload) {
  return <String, Object?>{
    if (payload.ocr != null)
      'ocr': <String, Object?>{
        'engine': payload.ocr!.engine,
        'engine_signature': payload.ocr!.engineSignature,
        'schema_version': payload.ocr!.schemaVersion,
      },
    'pages': <Map<String, Object?>>[
      for (final MokuroImage image in payload.images)
        <String, Object?>{
          'url': image.url,
          'width': image.size.width,
          'height': image.size.height,
          'blocks': <Map<String, Object?>>[
            for (final MokuroBlock block in image.blocks)
              <String, Object?>{
                'box': <double>[
                  block.rectangle.left,
                  block.rectangle.top,
                  block.rectangle.right,
                  block.rectangle.bottom,
                ],
                'vertical': block.isVertical,
                'font_size': block.fontSize,
                'z_index': block.zIndex,
                'lines': block.lines,
                if (block.linesCoords != null)
                  'lines_coords': block.linesCoords,
                if (block.regions != null)
                  'regions': <Map<String, Object?>>[
                    for (final MangaOcrTextRegion region in block.regions!)
                      <String, Object?>{
                        'box': <double>[
                          region.rectangle.left,
                          region.rectangle.top,
                          region.rectangle.right,
                          region.rectangle.bottom,
                        ],
                        'utf16_start': region.utf16Start,
                        'utf16_end': region.utf16End,
                      },
                  ],
              },
          ],
        },
    ],
  };
}

MangaOcrMetadata? _parseOcrMetadata(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final String? engine = raw['engine'] as String?;
  final String? signature = raw['engine_signature'] as String?;
  final int? version = (raw['schema_version'] as num?)?.toInt();
  if (engine == null || signature == null || version == null) {
    return null;
  }
  return MangaOcrMetadata(
    engine: engine,
    engineSignature: signature,
    schemaVersion: version,
  );
}

MokuroBlock _parseBlock(
  Map<dynamic, dynamic> raw,
  int index, {
  required String? zIndexKey,
}) {
  final Object? rawBox = raw['box'];
  Rect rectangle = Rect.zero;
  if (rawBox is List && rawBox.length >= 4) {
    rectangle = Rect.fromLTRB(
      _asDouble(rawBox[0]),
      _asDouble(rawBox[1]),
      _asDouble(rawBox[2]),
      _asDouble(rawBox[3]),
    );
  }

  final bool isVertical = (raw['vertical'] as bool?) ?? false;
  final double fontSize = _asDouble(raw['font_size']);

  final int zIndex = (zIndexKey != null && raw[zIndexKey] is num)
      ? (raw[zIndexKey] as num).toInt()
      : index;

  final List<String> lines = <String>[];
  final Object? rawLines = raw['lines'];
  if (rawLines is List) {
    for (final Object? line in rawLines) {
      lines.add(line?.toString() ?? '');
    }
  }

  return MokuroBlock(
    rectangle: rectangle,
    isVertical: isVertical,
    fontSize: fontSize,
    zIndex: zIndex,
    lines: lines,
    linesCoords: _parseLinesCoords(raw['lines_coords']),
    regions: _parseRegions(raw['regions']),
  );
}

List<MangaOcrTextRegion>? _parseRegions(Object? raw) {
  if (raw is! List) {
    return null;
  }
  final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[];
  for (final Object? entry in raw) {
    if (entry is! Map) {
      continue;
    }
    final Object? rawBox = entry['box'];
    if (rawBox is! List || rawBox.length < 4) {
      continue;
    }
    final int start = (entry['utf16_start'] as num?)?.toInt() ?? -1;
    final int end = (entry['utf16_end'] as num?)?.toInt() ?? -1;
    if (start < 0 || end <= start) {
      continue;
    }
    regions.add(
      MangaOcrTextRegion(
        rectangle: Rect.fromLTRB(
          _asDouble(rawBox[0]),
          _asDouble(rawBox[1]),
          _asDouble(rawBox[2]),
          _asDouble(rawBox[3]),
        ),
        utf16Start: start,
        utf16End: end,
      ),
    );
  }
  return regions;
}

/// Parse `lines_coords` (a list of lines, each a list of `[x, y]` points) into
/// a typed nested list. Returns `null` when absent; tolerant of malformed
/// entries (non-list lines/points are skipped, short points padded with 0).
List<List<List<double>>>? _parseLinesCoords(Object? raw) {
  if (raw is! List) {
    return null;
  }
  final List<List<List<double>>> lines = <List<List<double>>>[];
  for (final Object? rawLine in raw) {
    if (rawLine is! List) {
      continue;
    }
    final List<List<double>> points = <List<double>>[];
    for (final Object? rawPoint in rawLine) {
      if (rawPoint is! List) {
        continue;
      }
      points.add(<double>[
        for (final Object? coord in rawPoint) _asDouble(coord),
      ]);
    }
    lines.add(points);
  }
  return lines;
}

double _asDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0.0;
  }
  return 0.0;
}
