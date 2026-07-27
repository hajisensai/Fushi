// Chromium Lens protobuf interoperability follows the Google OCR approach
// used by 1Selxo/Mangatan (GPL-3.0), adapted through W1ght/Niratan's
// MangaOCRService.swift for Hibiki's Dart manga overlay.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:characters/characters.dart';
import 'package:image/image.dart' as img;

const int kGoogleLensMaximumImageDimension = 1500;
const int kGoogleLensMaximumResponseBytes = 12 * 1024 * 1024;
const int kGoogleLensMaximumCachedPageBytes = 32 * 1024 * 1024;
const int kGoogleLensMaximumRegionsPerPage = 100000;
const String kGoogleLensEngineSignature = 'google-lens-v1-ja';

class GoogleLensProtocolException implements Exception {
  const GoogleLensProtocolException([this.message = 'invalid Lens protobuf']);

  final String message;

  @override
  String toString() => 'GoogleLensProtocolException: $message';
}

class GoogleLensPreparedImage {
  const GoogleLensPreparedImage({
    required this.data,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
  });

  final Uint8List data;
  final int width;
  final int height;
  final int originalWidth;
  final int originalHeight;
}

class GoogleLensTextRegion {
  const GoogleLensTextRegion({
    required this.normalizedBounds,
    required this.utf16Start,
    required this.utf16End,
  });

  final Rect normalizedBounds;
  final int utf16Start;
  final int utf16End;
}

class GoogleLensParagraph {
  const GoogleLensParagraph({
    required this.sentence,
    required this.isVertical,
    required this.normalizedBounds,
    required this.regions,
  });

  final String sentence;
  final bool isVertical;
  final Rect normalizedBounds;
  final List<GoogleLensTextRegion> regions;
}

class GoogleLensProtocol {
  const GoogleLensProtocol._();

  static GoogleLensPreparedImage prepareImage(
    Uint8List source, {
    int maximumDimension = kGoogleLensMaximumImageDimension,
  }) {
    final img.Image? decoded = img.decodeImage(source);
    if (decoded == null) {
      throw const GoogleLensProtocolException('image could not be decoded');
    }
    final img.Image oriented = img.bakeOrientation(decoded);
    final int longest = math.max(oriented.width, oriented.height);
    final img.Image resized;
    if (longest > maximumDimension) {
      final double scale = maximumDimension / longest;
      resized = img.copyResize(
        oriented,
        width: math.max(1, (oriented.width * scale).round()),
        height: math.max(1, (oriented.height * scale).round()),
        interpolation: img.Interpolation.average,
      );
    } else {
      resized = oriented;
    }
    return GoogleLensPreparedImage(
      data: Uint8List.fromList(img.encodeJpg(resized, quality: 92)),
      width: resized.width,
      height: resized.height,
      originalWidth: oriented.width,
      originalHeight: oriented.height,
    );
  }

  static Uint8List makeRequest({
    required Uint8List imageData,
    required int width,
    required int height,
    String language = 'ja',
    int? requestId,
  }) {
    final int resolvedRequestId = requestId ?? _randomRequestId();
    final _ProtobufWriter root = _ProtobufWriter();
    root.message(1, (_ProtobufWriter objects) {
      objects.message(1, (_ProtobufWriter context) {
        context.message(3, (_ProtobufWriter id) {
          id.uint(1, resolvedRequestId);
          id.uint(2, 1);
          id.uint(3, 1);
        });
        context.message(4, (_ProtobufWriter client) {
          client.uint(1, 3);
          client.uint(2, 4);
          client.message(4, (_ProtobufWriter locale) {
            locale.string(1, language);
            locale.string(2, 'US');
            locale.string(3, 'America/New_York');
          });
        });
      });
      objects.message(3, (_ProtobufWriter image) {
        image.message(1, (_ProtobufWriter payload) {
          payload.bytes(1, imageData);
        });
        image.message(3, (_ProtobufWriter metadata) {
          metadata.uint(1, width);
          metadata.uint(2, height);
        });
      });
    });
    return root.takeBytes();
  }

  static List<GoogleLensParagraph> decodeResponse(
    Uint8List data, {
    String language = 'ja',
  }) {
    final _ProtobufMessage root = _ProtobufMessage(data);
    final List<_ProtobufMessage> paragraphs =
        root.firstMessage(2)?.firstMessage(3)?.firstMessage(1)?.messages(1) ??
            <_ProtobufMessage>[];
    final List<GoogleLensParagraph> result = <GoogleLensParagraph>[];
    int regionCount = 0;
    for (final _ProtobufMessage paragraph in paragraphs) {
      final List<_RecognizedLine> lines = <_RecognizedLine>[];
      final List<_ProtobufMessage> rawLines = paragraph.messages(2);
      for (int lineIndex = 0; lineIndex < rawLines.length; lineIndex++) {
        final _ProtobufMessage line = rawLines[lineIndex];
        final String rawText = line
            .messages(1)
            .map(
                (_ProtobufMessage word) => '${word.string(2)}${word.string(3)}')
            .join();
        final String text = _normalize(rawText, language);
        final _LensGeometry? geometry =
            line.firstMessage(2)?.let(_readGeometry);
        if (text.isEmpty || geometry == null) {
          continue;
        }
        lines.add(
          _RecognizedLine(
            sourceIndex: lineIndex,
            text: text,
            geometry: geometry,
          ),
        );
      }
      if (lines.isEmpty) {
        continue;
      }
      final _LensGeometry? paragraphGeometry =
          paragraph.firstMessage(3)?.let(_readGeometry);
      final bool isVertical = paragraphGeometry?.isVertical == true ||
          lines
                      .where((_RecognizedLine line) => line.geometry.isVertical)
                      .length *
                  2 >
              lines.length;
      lines.sort((_RecognizedLine a, _RecognizedLine b) {
        if (isVertical) {
          if ((a.geometry.rect.center.dx - b.geometry.rect.center.dx).abs() >
              0.002) {
            return b.geometry.rect.center.dx
                .compareTo(a.geometry.rect.center.dx);
          }
          return a.geometry.rect.top.compareTo(b.geometry.rect.top);
        }
        if ((a.geometry.rect.top - b.geometry.rect.top).abs() > 0.002) {
          return a.geometry.rect.top.compareTo(b.geometry.rect.top);
        }
        return a.geometry.rect.left.compareTo(b.geometry.rect.left);
      });
      final String sentence =
          lines.map((_RecognizedLine line) => line.text).join();
      final List<GoogleLensTextRegion> regions = <GoogleLensTextRegion>[];
      int utf16Base = 0;
      Rect? paragraphRect;
      for (final _RecognizedLine line in lines) {
        paragraphRect = paragraphRect == null
            ? line.geometry.rect
            : paragraphRect.expandToInclude(line.geometry.rect);
        final List<GoogleLensTextRegion> lineRegions = _characterRegions(
          lineText: line.text,
          utf16Base: utf16Base,
          geometry: line.geometry,
        );
        regionCount += lineRegions.length;
        if (regionCount > kGoogleLensMaximumRegionsPerPage) {
          throw const GoogleLensProtocolException('too many text regions');
        }
        regions.addAll(lineRegions);
        utf16Base += line.text.length;
      }
      if (regions.isEmpty || paragraphRect == null) {
        continue;
      }
      result.add(
        GoogleLensParagraph(
          sentence: sentence,
          isVertical: isVertical,
          normalizedBounds: paragraphRect,
          regions: regions,
        ),
      );
    }
    return result;
  }

  static List<GoogleLensTextRegion> _characterRegions({
    required String lineText,
    required int utf16Base,
    required _LensGeometry geometry,
  }) {
    final List<({String text, int start, int end})> characters =
        <({String text, int start, int end})>[];
    int offset = utf16Base;
    for (final String character in lineText.characters) {
      final int end = offset + character.length;
      if (character.trim().isNotEmpty) {
        characters.add((text: character, start: offset, end: end));
      }
      offset = end;
    }
    if (characters.isEmpty) {
      return const <GoogleLensTextRegion>[];
    }
    final double cosine = math.cos(geometry.rotation);
    final double sine = math.sin(geometry.rotation);
    final double characterWidth = geometry.width / characters.length;
    return <GoogleLensTextRegion>[
      for (int i = 0; i < characters.length; i++)
        GoogleLensTextRegion(
          // Split the original rotated Lens rectangle along its baseline, then
          // take the AABB of each small glyph cell. Splitting the line's large
          // AABB (the old implementation) makes every character cover most of
          // a diagonal title and returns a neighbouring/reversed character.
          normalizedBounds: _orientedCharacterBounds(
            geometry,
            along: (i + 0.5) / characters.length - 0.5,
            characterWidth: characterWidth,
            cosine: cosine,
            sine: sine,
          ),
          utf16Start: characters[i].start,
          utf16End: characters[i].end,
        ),
    ];
  }

  static Rect _orientedCharacterBounds(
    _LensGeometry geometry, {
    required double along,
    required double characterWidth,
    required double cosine,
    required double sine,
  }) {
    final double centerX = geometry.centerX + along * geometry.width * cosine;
    // Lens and the overlay both use a top-left origin, so positive baseline
    // rotation moves down as X increases.
    final double centerY = geometry.centerYTop + along * geometry.width * sine;
    final double halfWidth =
        (characterWidth * cosine.abs() + geometry.height * sine.abs()) / 2;
    final double halfHeight =
        (characterWidth * sine.abs() + geometry.height * cosine.abs()) / 2;
    final double left = math.max(0, centerX - halfWidth);
    final double top = math.max(0, centerY - halfHeight);
    final double right = math.min(1, centerX + halfWidth);
    final double bottom = math.min(1, centerY + halfHeight);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static _LensGeometry? _readGeometry(_ProtobufMessage message) {
    final _ProtobufMessage? box = message.firstMessage(1);
    final double? centerX = box?.float32(1);
    final double? centerY = box?.float32(2);
    final double? width = box?.float32(3);
    final double? height = box?.float32(4);
    if (centerX == null ||
        centerY == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      return null;
    }
    final double rotation = box?.float32(5) ?? 0;
    final double cosine = math.cos(rotation).abs();
    final double sine = math.sin(rotation).abs();
    final double halfWidth = (width * cosine + height * sine) / 2;
    final double halfHeight = (width * sine + height * cosine) / 2;
    final double left = math.max(0, centerX - halfWidth);
    final double top = math.max(0, centerY - halfHeight);
    final double right = math.min(1, centerX + halfWidth);
    final double bottom = math.min(1, centerY + halfHeight);
    if (right <= left || bottom <= top) {
      return null;
    }
    return _LensGeometry(
      // Chromium Lens already reports normalized image coordinates in the
      // browser's top-left coordinate system. Flipping Y here mirrors every
      // hit target vertically (top article text points at the bottom article).
      rect: Rect.fromLTWH(left, top, right - left, bottom - top),
      rotation: rotation,
      centerX: centerX,
      centerYTop: centerY,
      width: width,
      height: height,
    );
  }

  static String _normalize(String text, String language) {
    final String trimmed = text.trim();
    if (language == 'ja' || language == 'zh') {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    return trimmed.split(RegExp(r'\s+')).join(' ');
  }

  static int _randomRequestId() {
    final math.Random random = math.Random.secure();
    final int high = random.nextInt(0x3fffffff);
    final int low = random.nextInt(0xffffffff);
    return math.max(1, (high << 32) | low);
  }
}

class _LensGeometry {
  const _LensGeometry({
    required this.rect,
    required this.rotation,
    required this.centerX,
    required this.centerYTop,
    required this.width,
    required this.height,
  });

  final Rect rect;
  final double rotation;
  final double centerX;
  final double centerYTop;
  final double width;
  final double height;

  bool get isVertical =>
      ((rotation.abs() - math.pi / 2).abs() < 0.5) ||
      rect.height > rect.width * 1.25;
}

class _RecognizedLine {
  const _RecognizedLine({
    required this.sourceIndex,
    required this.text,
    required this.geometry,
  });

  final int sourceIndex;
  final String text;
  final _LensGeometry geometry;
}

extension _NullableLet<T> on T {
  R let<R>(R Function(T value) convert) => convert(this);
}

class _ProtobufWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void uint(int field, int value) {
    _writeVarint(field << 3);
    _writeVarint(value);
  }

  void string(int field, String value) =>
      bytes(field, Uint8List.fromList(utf8.encode(value)));

  void bytes(int field, Uint8List value) {
    _writeVarint((field << 3) | 2);
    _writeVarint(value.length);
    _builder.add(value);
  }

  void message(int field, void Function(_ProtobufWriter writer) build) {
    final _ProtobufWriter nested = _ProtobufWriter();
    build(nested);
    bytes(field, nested.takeBytes());
  }

  Uint8List takeBytes() => _builder.takeBytes();

  void _writeVarint(int value) {
    int remaining = value;
    while (remaining > 0x7f) {
      _builder.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _builder.addByte(remaining);
  }
}

class _ProtobufField {
  const _ProtobufField(this.wireType, this.value);

  final int wireType;
  final Uint8List value;
}

class _ProtobufMessage {
  _ProtobufMessage(Uint8List data) : _fields = _decode(data);

  final Map<int, List<_ProtobufField>> _fields;

  List<_ProtobufMessage> messages(int field) =>
      (_fields[field] ?? const <_ProtobufField>[])
          .where((_ProtobufField value) => value.wireType == 2)
          .map((_ProtobufField value) => _ProtobufMessage(value.value))
          .toList();

  _ProtobufMessage? firstMessage(int field) {
    final List<_ProtobufMessage> values = messages(field);
    return values.isEmpty ? null : values.first;
  }

  String string(int field) {
    final _ProtobufField? value = (_fields[field] ?? const <_ProtobufField>[])
        .where((_ProtobufField value) => value.wireType == 2)
        .firstOrNull;
    if (value == null) {
      return '';
    }
    try {
      return utf8.decode(value.value);
    } on FormatException {
      throw const GoogleLensProtocolException('invalid UTF-8');
    }
  }

  double? float32(int field) {
    final _ProtobufField? value = (_fields[field] ?? const <_ProtobufField>[])
        .where((_ProtobufField value) => value.wireType == 5)
        .firstOrNull;
    if (value == null || value.value.length != 4) {
      return null;
    }
    return ByteData.sublistView(value.value).getFloat32(0, Endian.little);
  }

  static Map<int, List<_ProtobufField>> _decode(Uint8List data) {
    final _ProtobufCursor cursor = _ProtobufCursor(data);
    final Map<int, List<_ProtobufField>> decoded =
        <int, List<_ProtobufField>>{};
    while (!cursor.isAtEnd) {
      final int tag = cursor.varint();
      final int field = tag >> 3;
      final int wireType = tag & 7;
      if (field <= 0) {
        throw const GoogleLensProtocolException();
      }
      final Uint8List value;
      switch (wireType) {
        case 0:
          cursor.varint();
          value = Uint8List(0);
          break;
        case 1:
          value = cursor.read(8);
          break;
        case 2:
          value = cursor.read(cursor.varint());
          break;
        case 5:
          value = cursor.read(4);
          break;
        default:
          throw const GoogleLensProtocolException('unsupported wire type');
      }
      decoded.putIfAbsent(field, () => <_ProtobufField>[]).add(
            _ProtobufField(wireType, value),
          );
    }
    return decoded;
  }
}

class _ProtobufCursor {
  _ProtobufCursor(this.data);

  final Uint8List data;
  int offset = 0;

  bool get isAtEnd => offset >= data.length;

  int varint() {
    int result = 0;
    int shift = 0;
    while (offset < data.length && shift < 70) {
      final int byte = data[offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return result;
      }
      shift += 7;
    }
    throw const GoogleLensProtocolException();
  }

  Uint8List read(int count) {
    if (count < 0 || offset > data.length - count) {
      throw const GoogleLensProtocolException();
    }
    final Uint8List result =
        Uint8List.sublistView(data, offset, offset + count);
    offset += count;
    return result;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> values = iterator;
    return values.moveNext() ? values.current : null;
  }
}
