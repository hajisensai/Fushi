import 'package:xml/xml.dart';

import '../notification_parts.dart';

/// Converts a [WindowsImage] to XML
extension ImageToXml on WindowsImage {
  /// Serializes this image to Windows-compatible XML.
  ///
  /// See: https://learn.microsoft.com/en-us/uwp/schemas/tiles/toastschema/element-image
  void buildXml(XmlBuilder builder) {
    builder.element(
      'image',
      attributes: <String, String>{
        'src': imageSource,
        'alt': altText,
        'addImageQuery': addQueryParams.toString(),
        if (placement != null) 'placement': placement!.name,
        if (crop != null) 'hint-crop': crop!.name,
      },
    );
  }

  /// Hibiki patch (BUG-2499): the Windows toast renderer does **not** decode
  /// percent-encoded non-ASCII characters in a `file:///` `src` — a cover at
  /// `D:\...\video_グロウアップショウ.jpg` serialised by `Uri.file` becomes
  /// `file:///D:/.../video_%E3%82%B0....jpg` and the image is silently dropped
  /// (ASCII-only paths render fine, so this only bites non-ASCII paths). The
  /// renderer accepts a plain Windows path (`D:\...\日本.jpg`) verbatim, so
  /// local files are emitted as native paths; every other scheme (`ms-appx`,
  /// `http`) keeps the URI form. Upstream fix pending; drop this patch once
  /// the package emits file paths itself.
  String get imageSource =>
      uri.isScheme('file') ? uri.toFilePath(windows: true) : uri.toString();
}
