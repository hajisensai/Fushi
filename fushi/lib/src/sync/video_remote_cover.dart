import 'dart:typed_data';
import 'dart:ui' as ui;

/// A cover preview as the phone remote receives it (`cover` operation).
typedef VideoRemoteCoverPreview = ({String mime, Uint8List bytes});

/// Covers up to this size go out as stored; larger ones are re-encoded.
const int kVideoRemoteCoverPassThroughBytes = 300 * 1024;

/// Width (px) larger covers are scaled down to before going to the phone.
const int kVideoRemoteCoverPreviewWidth = 360;

/// Turns stored cover bytes into what the phone receives: small JPEG / PNG /
/// WebP covers pass through untouched, anything larger is decoded, scaled to
/// [kVideoRemoteCoverPreviewWidth] wide and re-encoded as PNG so a 4K poster
/// never crosses the link whole. Null when the bytes are not a decodable
/// image.
Future<VideoRemoteCoverPreview?> videoRemoteCoverPreview(
  Uint8List bytes,
) async {
  if (bytes.isEmpty) return null;
  final String? mime = videoRemoteCoverMime(bytes);
  if (mime != null && bytes.length <= kVideoRemoteCoverPassThroughBytes) {
    return (mime: mime, bytes: bytes);
  }
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: kVideoRemoteCoverPreviewWidth,
    );
    image = (await codec.getNextFrame()).image;
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (png == null) return null;
    return (mime: 'image/png', bytes: png.buffer.asUint8List());
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// The image type of [bytes] by its magic number (JPEG / PNG / WebP / GIF);
/// null for anything else.
String? videoRemoteCoverMime(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (int i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const <int>[0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const <int>[0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(const <int>[0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(const <int>[0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const <int>[0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
