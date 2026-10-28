import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// One thumbnail a disclib document declares: `BDMV/META/DL/bdmt_<lang>.xml`
/// names images that sit beside it, e.g.
/// `<di:thumbnail href="./L.jpg" size="640x360"/>`. The declared size is
/// untrusted; [readBlurayDiscArtwork] measures the image itself.
class BlurayDiscThumbnail {
  const BlurayDiscThumbnail({required this.href});

  /// Relative to `BDMV/META/DL`, already checked to stay inside it.
  final String href;
}

/// A disc artwork image with its decoded pixel size.
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

/// Every thumbnail one disclib document declares, in document order.
List<BlurayDiscThumbnail> parseBlurayDiscThumbnails(String xmlSource) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xmlSource);
  } on XmlException {
    return const <BlurayDiscThumbnail>[];
  }
  return <BlurayDiscThumbnail>[
    for (final XmlElement element
        in document.descendants.whereType<XmlElement>())
      if (element.name.local == 'thumbnail')
        if (_containedHref(element.getAttribute('href')) case final String href)
          BlurayDiscThumbnail(href: href),
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

/// ISO 639-2 codes (bibliographic and terminology forms) a disc may use in
/// `bdmt_<lang>.xml` for a UI language given as an ISO 639-1 code. Unknown
/// languages map to nothing, so the disc's own order decides.
List<String> blurayLanguageCodes(String languageCode) =>
    switch (languageCode.toLowerCase()) {
      'ar' => const <String>['ara'],
      'de' => const <String>['ger', 'deu'],
      'en' => const <String>['eng'],
      'es' => const <String>['spa'],
      'fr' => const <String>['fre', 'fra'],
      'id' => const <String>['ind'],
      'it' => const <String>['ita'],
      'ja' => const <String>['jpn'],
      'ko' => const <String>['kor'],
      'nl' => const <String>['dut', 'nld'],
      'pt' => const <String>['por'],
      'ru' => const <String>['rus'],
      'th' => const <String>['tha'],
      'tr' => const <String>['tur'],
      'vi' => const <String>['vie'],
      'zh' => const <String>['chi', 'zho'],
      _ => const <String>[],
    };

/// Orders `bdmt_<lang>.xml` names: [preferredLanguages] first, in order, then
/// the rest by file name (libbluray likewise falls back to the first entry
/// when the player language has none).
List<String> orderBlurayDiscMetadataFiles(
  Iterable<String> fileNames, {
  required List<String> preferredLanguages,
}) {
  int rank(String name) {
    final String lang = name.substring(5, name.length - 4).toLowerCase();
    final int index = preferredLanguages.indexOf(lang);
    return index < 0 ? preferredLanguages.length : index;
  }

  final List<String> names = <String>[
    for (final String name in fileNames)
      if (RegExp(r'^bdmt_[A-Za-z]{3}\.xml$').hasMatch(name)) name,
  ];
  names.sort((String a, String b) {
    final int byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.compareTo(b);
  });
  return names;
}

/// Pixel size read from the image header, or null when it is not an image.
/// Disc files are untrusted, and the decoders throw assorted errors on
/// malformed headers: any failure means "not an image".
({int width, int height})? decodeImageSize(Uint8List bytes) {
  final img.DecodeInfo? info;
  try {
    info = img.findDecoderForData(bytes)?.startDecode(bytes);
  } on Object {
    return null;
  }
  if (info == null || info.width <= 0 || info.height <= 0) return null;
  return (width: info.width, height: info.height);
}

const int _kMaxMetadataBytes = 256 * 1024;
const int _kMaxArtworkBytes = 16 * 1024 * 1024;

/// The disc's own artwork under [discRootPath], measured by decoding each
/// image: the first metadata language (see [orderBlurayDiscMetadataFiles])
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
      for (final BlurayDiscThumbnail t in parseBlurayDiscThumbnails(
        await xml.readAsString(),
      )) {
        final File file = File(
          p.joinAll(<String>[dl.path, ...t.href.split('/')]),
        );
        if (!await file.exists() || await file.length() > _kMaxArtworkBytes) {
          continue;
        }
        final ({int width, int height})? size = decodeImageSize(
          await file.readAsBytes(),
        );
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
